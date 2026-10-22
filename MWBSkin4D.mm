// MWBSkin4D.mm — 4D皮肤 P1:迷你史蒂夫 (只缩放不改几何, 动画全保留)
// 原理: ES2 没有固定管线矩阵栈, 缩放放在 uniform 层做。
// render hook 认出本地玩家即举 gMiniDrawScope 旗 (作用域只包这一次原版绘制),
// MWBHooks010 的 glUniformMatrix4fv 拦截内对窗口期模型矩阵做列缩放 (M*S, 原点不动)。
// (YSM 已剥离构建, 源码留仓: MWBYSM*.mm + zstddeclib.c 不在 Makefile 里)
#import "MWBCommon.h"
#import <string.h>
#import <dlfcn.h>   // render命中调用者反查用

#define MINI4D_SCALE 0.5f   // 迷你倍率 (P1 先写死 0.5, 截图验证脚是否着地再调)

BOOL gMiniDrawScope = NO;   // 玩家自家绘制窗口 (本文件 render hook 置位, uniform 层消费)

typedef void (*HModelRenderFn)(void *self, void *entity,
                               float f1, float f2, float f3, float f4, float f5, float f6);
static HModelRenderFn orig_mini_render = NULL;

static void hooked_mini_render(void *self, void *entity,
                               float f1, float f2, float f3, float f4, float f5, float f6) {
    if (entity && entity == gLocalPlayer) {
        // 调用者反查 (只读): 已实锤 MobRenderer::render+0x458, 窗口已搬过去, 此分支只留诊断
        static BOOL sLogged = NO;
        if (!sLogged) {
            sLogged = YES;
            void *ret = __builtin_return_address(0);
            Dl_info info;
            const char *nm = "?";
            long off = 0;
            if (dladdr(ret, &info) && info.dli_sname) { nm = info.dli_sname; off = (char *)ret - (char *)info.dli_saddr; }
            MWBLogFile(@"[4D探针] render命中 self=%p entity=%p caller=%s+0x%lx", self, entity, nm, off);
        }
    }
    orig_mini_render(self, entity, f1, f2, f3, f4, f5, f6);
}

// 窗口真正的所有者: MobRenderer::render (模型矩阵在此层上传, 比 HumanoidModel 高一层)
typedef void (*MobRenderFn)(void *self, void *entity, const void *pos, float f1, float f2);
static MobRenderFn orig_mob_render = NULL;
static void hooked_mob_render(void *self, void *entity, const void *pos, float f1, float f2) {
    orig_mob_render(self, entity, pos, f1, f2);
}

// 窗口真正的所有者 (P2): HumanoidMobRenderer::render (逐实体, 矩阵上传在此层)
// P1 验证: 此窗口内应出现 uniform 矩阵上传, 缩放对玩家模型矩阵生效
typedef void (*HMobRenderFn)(void *self, void *entity, const void *pos, float f1, float f2);
static HMobRenderFn orig_hmob_render = NULL;
static void hooked_hmob_render(void *self, void *entity, const void *pos, float f1, float f2) {
    if (gMini4D && entity && entity == gLocalPlayer) {
        gMiniDrawScope = YES;
        orig_hmob_render(self, entity, pos, f1, f2);
        gMiniDrawScope = NO;
        return;
    }
    orig_hmob_render(self, entity, pos, f1, f2);
}

// uniform 层消费 (MWBHooks010 的 patched_glUniformMatrix4fv 内调):
// 是模型矩阵 (仿射: m[3]/m[7]/m[11]==0 且 m[15]==1) 才缩, 投影矩阵 (m[11]==-1) 不碰。
// 返回 YES=已代传 (调用方直接 return), NO=没命中 (调用方走原逻辑)。
BOOL MWBMini4DScaleMatrix(const float *m, float *out) {
    if (!gMiniDrawScope || !m || !out) return NO;
    if (fabsf(m[3]) > 1e-6f || fabsf(m[7]) > 1e-6f || fabsf(m[11]) > 1e-6f) return NO;
    if (fabsf(m[15] - 1.0f) > 1e-6f) return NO;
    memcpy(out, m, sizeof(float) * 16);
    static const int kCols[] = {0, 1, 2, 4, 5, 6, 8, 9, 10};
    for (int i = 0; i < 9; i++) out[kCols[i]] *= MINI4D_SCALE;
    static BOOL sLogged = NO;
    if (!sLogged) { sLogged = YES; MWBLogFile(@"[4D皮肤] uniform层缩放命中 scale=%.2f", MINI4D_SCALE); }
    return YES;
}

// 0.10 才安装 (%ctor 调用, 版本不对直接返回)
void MWBSkin4DInstall(void) {
    if (gGV != (int)MWBGameV0_10) return;
    MWB_HOOK("__ZN13HumanoidModel6renderER6Entityffffff",
             hooked_mini_render, orig_mini_render);
    MWB_HOOK("__ZN11MobRenderer6renderER6EntityRK4Vec3ff",
             hooked_mob_render, orig_mob_render);
    MWB_HOOK("__ZN19HumanoidMobRenderer6renderER6EntityRK4Vec3ff",
             hooked_hmob_render, orig_hmob_render);
    MWBLogFile(@"[4D皮肤] P1迷你挂载就绪 (flag mini-1 开, 倍率%.2f)", MINI4D_SCALE);
}
