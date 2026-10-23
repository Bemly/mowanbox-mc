// MWBSkin4D.mm — 4D皮肤：GLB 直画替换史蒂夫（旧手搓立方体烘焙模型已删，只走 GLB）
// 逻辑与 web/js/plugin-glb.js 逐行一致（web 先行验证，插件照抄）：
//  GLB 解析零换算（米制直用）＋姿势 slerp/lerp＋vis 叠加＋自家 shader（MVP=WVP·T玩家·节点世界，Nearest/Clamp/alphaTest/双面）。
// 落位 T 只在 iPad 侧加（web SIM 相机直视原点模型，不需要；节点世界数学两边逐元一致）。
// 原版六件套显隐照旧（藏原版防重影）；均匀桩 P1 已证死留桩不动。
#import "MWBSkin4D.h"
#import "MWBCommon.h"
#import "MWBGLBModel.h" // GLB 直画（唯一模型），同一 render hook 在 orig 之后画
#import <string.h>
#import <math.h>

#define MINI4D_SCALE 0.5f // P1 均匀桩倍率（已证死，留着不动）

BOOL gMiniDrawScope = NO; // P1 均匀桩窗口（不再置位，恒 NO，均匀分支自然 dormant）

// 原版六件套显隐（HumanoidModel::render hook 内调，self 即 model；
// 偏移 HumanoidModel::render 反编译实锤：model+0x108 起步进 0xC0 六个）
static void MWBSkinSetVanilla(void *model, BOOL hide) {
    if (!model) return;
    static const size_t kOff[6] = {0x108, 0x1C8, 0x288, 0x348, 0x408, 0x4C8};
    for (int i = 0; i < 6; i++)
        ((char *)model)[kOff[i] + 0x80] = hide ? 1 : 0;
}

// HumanoidModel::render 真签名：后六参是 16 字节向量（v0-v5），不是 float！
// 反编译实锤：入口 mov v8,v5，且喂 part 的矩阵就是 v5（lane0 即 f6=0.0625）。
// 按 float 声明转发会丢每个向量的高 12 字节，且自家 render 拿不到真矩阵（-168 隐身 bug 的根因）。
// 故 hook 与原函数一律用向量类型全量透传，自家树直接用游戏的 v5 矩阵画。
typedef float M16Skin __attribute__((vector_size(16)));
typedef void (*HModelRenderFn)(void *self, void *entity,
                               M16Skin p1, M16Skin p2, M16Skin p3,
                               M16Skin p4, M16Skin p5, M16Skin p6);
static HModelRenderFn orig_mini_render = NULL;

static void hooked_mini_render(void *self, void *entity,
                               M16Skin p1, M16Skin p2, M16Skin p3,
                               M16Skin p4, M16Skin p5, M16Skin p6) {
    // 先把六个向量存局部（无调用，v0-v5 原样落栈），之后随便调函数，透传时再全量装回去。
    M16Skin s1 = p1, s2 = p2, s3 = p3, s4 = p4, s5 = p5, s6 = p6;
    // 本地玩家：GLB 能画才藏原版（防隐身；解析失败/未开时原版照常画）。
    // WVP 快照必须在 orig 之前抓：此时绑定的正是给本实体上传的 program，post-orig 会拿到别的 pass。
    // 只在第三人称画（第一人称相机在头里，鱼盖脸；且与 web SIM 第三人称视角对齐验证）。
    BOOL showFish = (entity && entity == gLocalPlayer && (gSkin4D || gGLBModel) && MWBCamValue() != 0);
    if (showFish) {
        MWBGLBSnapshotWVP();
        MWBSkinSetVanilla(self, MWBGLBCanDraw());
    }
    orig_mini_render(self, entity, s1, s2, s3, s4, s5, s6);
    // GLB 直画（唯一模型）：同一 hook 内 orig 之后画，自家 shader，不碰游戏状态机（内部保存/恢复）
    if (showFish) {
        MWBGLBDraw();
    }
}

// 上层透传（占位不断链）
typedef void (*MobRenderFn)(void *self, void *entity, const void *pos, float f1, float f2);
static MobRenderFn orig_mob_render = NULL;
static void hooked_mob_render(void *self, void *entity, const void *pos, float f1, float f2) {
    orig_mob_render(self, entity, pos, f1, f2);
}

// 外层透传（建树与绘制已搬进 HumanoidModel::render hook 内，那里栈顶有实体变换）
typedef void (*HMobRenderFn)(void *self, void *entity, const void *pos, float f1, float f2);
static HMobRenderFn orig_hmob_render = NULL;
static void hooked_hmob_render(void *self, void *entity, const void *pos, float f1, float f2) {
    orig_hmob_render(self, entity, pos, f1, f2);
}

// P1 均匀桩（已证死，留桩不动，恒不命中因为窗口不再置位）
BOOL MWBMini4DScaleMatrix(const float *m, float *out) {
    if (!gSkin4D || !gMiniDrawScope || !m || !out) return NO;
    if (fabsf(m[3]) > 1e-6f || fabsf(m[7]) > 1e-6f || fabsf(m[11]) > 1e-6f) return NO;
    if (fabsf(m[15] - 1.0f) > 1e-6f) return NO;
    memcpy(out, m, sizeof(float) * 16);
    static const int kCols[] = {0, 1, 2, 4, 5, 6, 8, 9, 10};
    for (int i = 0; i < 9; i++) out[kCols[i]] *= MINI4D_SCALE;
    return YES;
}

// 0.10 才安装（%ctor 调用，版本不对直接返回）
void MWBSkin4DInstall(void) {
    if (gGV != (int)MWBGameV0_10) return;
    MWB_HOOK("__ZN13HumanoidModel6renderER6Entityffffff",
             hooked_mini_render, orig_mini_render);
    MWB_HOOK("__ZN11MobRenderer6renderER6EntityRK4Vec3ff",
             hooked_mob_render, orig_mob_render);
    MWB_HOOK("__ZN19HumanoidMobRenderer6renderER6EntityRK4Vec3ff",
             hooked_hmob_render, orig_hmob_render);
    MWBLogFile(@"[4D皮肤] GLB 挂载就绪（菜单 skin4d / flag glb，模型唯一）");
}
