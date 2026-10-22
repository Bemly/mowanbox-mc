// MWBSkin4D.mm — 4D皮肤 P1: 迷你史蒂夫 (简单模型先行)
// 目标: 把史蒂夫替换为一个模型, 先拿最简单的模型试试——同一史蒂夫缩 0.5 倍。
// 原理: ES2 无固定管线矩阵栈, 缩放在 uniform 层做 (M*S, 原点不动, 脚不离地)。
// 链路: HumanoidMobRenderer::render 认出本地玩家即举 gMiniDrawScope 旗,
// MWBHooks010 的 glUniformMatrix4fv 拦截内对窗口期模型矩阵做列缩放。
// 只影响本地玩家, 他人/他实体零影响; 关开关即恢复原样。
#import "MWBSkin4D.h"
#import "MWBCommon.h"
#import <string.h>
#import <math.h>
#import <dlfcn.h> // render 命中调用者反查用

#define MINI4D_SCALE 0.5f // 迷你倍率 (P1 写死 0.5, 截图看脚是否着地再调)

BOOL gMiniDrawScope = NO; // 本地玩家自家绘制窗口 (本文件置位, 均匀层消费)

typedef void (*HModelRenderFn)(void *self, void *entity,
                               float f1, float f2, float f3, float f4, float f5, float f6);
static HModelRenderFn orig_mini_render = NULL;

static void hooked_mini_render(void *self, void *entity,
                               float f1, float f2, float f3, float f4, float f5, float f6) {
    // 诊断分支: 只在开皮肤时记一次调用者, 关着不刷屏
    if (gSkin4D && entity && entity == gLocalPlayer) {
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

// 上层透传 (模型矩阵在此层之上上传, 留着占位不断链)
typedef void (*MobRenderFn)(void *self, void *entity, const void *pos, float f1, float f2);
static MobRenderFn orig_mob_render = NULL;
static void hooked_mob_render(void *self, void *entity, const void *pos, float f1, float f2) {
    orig_mob_render(self, entity, pos, f1, f2);
}

// 窗口所有者: HumanoidMobRenderer::render (逐实体, 矩阵上传在此层之内)
typedef void (*HMobRenderFn)(void *self, void *entity, const void *pos, float f1, float f2);
static HMobRenderFn orig_hmob_render = NULL;
static void hooked_hmob_render(void *self, void *entity, const void *pos, float f1, float f2) {
    if (gSkin4D && entity && entity == gLocalPlayer) {
        gMiniDrawScope = YES;
        orig_hmob_render(self, entity, pos, f1, f2);
        gMiniDrawScope = NO;
        return;
    }
    orig_hmob_render(self, entity, pos, f1, f2);
}

// 均匀层消费: 是模型矩阵 (仿射: m[3]/m[7]/m[11]==0 且 m[15]==1) 才缩。
// 投影矩阵 (m[11]==-1) 与穿墙近平面重建互斥, 这里不碰, 交给穿墙分支。
BOOL MWBMini4DScaleMatrix(const float *m, float *out) {
    if (!gSkin4D || !gMiniDrawScope || !m || !out) return NO;
    if (fabsf(m[3]) > 1e-6f || fabsf(m[7]) > 1e-6f || fabsf(m[11]) > 1e-6f) return NO;
    if (fabsf(m[15] - 1.0f) > 1e-6f) return NO;
    memcpy(out, m, sizeof(float) * 16);
    static const int kCols[] = {0, 1, 2, 4, 5, 6, 8, 9, 10};
    for (int i = 0; i < 9; i++) out[kCols[i]] *= MINI4D_SCALE;
    static BOOL sLogged = NO;
    if (!sLogged) { sLogged = YES; MWBLogFile(@"[4D皮肤] 均匀层缩放命中 scale=%.2f", MINI4D_SCALE); }
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
    MWBLogFile(@"[4D皮肤] P1迷你挂载就绪 (开关 skin4d, 倍率%.2f)", MINI4D_SCALE);
}
