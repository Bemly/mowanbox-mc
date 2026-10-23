// MWBCamera010.mm — 0.10 相机四视角：设置里第三人称开关改 4 段滑条（第一/第三背面/第三正面/跟脸正面）
// 逆向实锤（kuna 反 0.10 二进制，imagebase=0x100000000）：
// - 选项表静态 0x10034dd00，条目 {int 类型@+0, string 名@+8, int id@+0x20} 步长 0x28；
//   thirdperson 条目在 0x10034ebc8（类型 0=开关，id 12），难度在 0x10034eb50（类型 3=步进滑条，id 8）。
// - 类型 0=开关createsToggle，1=连续滑条，3=步进滑条（音乐0/声音1/灵敏3是连续，距离4/难度8/界面11是步进）。
// - 相机 GameRenderer::setupCamera：Options+0x2cd==0 第一人称，否则第三人称再看 +0x2d6（0=背面，1=正面，
//   取反镜像经典写法）；开关 toggle 只翻 0x2cd（0↔1），0x2d6 恒 0，故原版根本没有正面视角。
// 做法：直接写 __DATA 里条目类型 0→3（免 vm_protect，本来就可写）；hook Slider::C1 给 {0,1,2} 步伐+初值反推；
// hook Slider::setOption 写 {0x2cd,0x2d6}；cam-N flag 直写（测试保留）。
#import "MWBCommon.h"
#import "EMI.h" // MWBMainSlide
#import <substrate.h>

#define CAM_OPT_VA 0x10034ebc8UL   // thirdperson 选项条目（MSFindSymbol 直解亦可，此处按滑块基址直算）
#define CAM_OPT_TYPE_OFF 0          // 条目+0：类型（0=开关，3=步进滑条）
#define CAM_F_THIRD 0x2cdUL         // Options+0x2cd：0=第一，1=第三
#define CAM_F_FRONT 0x2d6UL         // Options+0x2d6：0=背面，1=正面
#define CAM_MC_OPT_OFF 0x1C8       // MC+0x1C8 = Options*（gamma 夜视同路已实锤）

static void *MWBCamOpt(void) { return (void *)(MWBMainSlide() + CAM_OPT_VA); }
static void MWBCamPersist(void *opt); // 前置声明（定义在后）
static void *MWBCamOptions(void *mc) {
    if (!mc) mc = MWB010Minecraft();
    if (!mc) return NULL;
    return *(void **)((char *)mc + CAM_MC_OPT_OFF);
}

// 当前值反推：0=第一，1=第三背面，2=第三正面，3=跟脸正面（2d6==2，原版到不了的值）
int MWBCamValue(void) {
    void *opt = MWBCamOptions(NULL);
    if (!opt) return 0;
    uint8_t t = *(uint8_t *)((char *)opt + CAM_F_THIRD);
    if (!t) return 0;
    uint8_t f = *(uint8_t *)((char *)opt + CAM_F_FRONT);
    return f >= 2 ? 3 : (f ? 2 : 1);
}

// 值写入：0→第一，1→第三背面，2→第三正面，3→跟脸正面（越界钳制）
void MWBSetCamValue01(int v) {
    if (v < 0) v = 0;
    if (v > 3) v = 3;
    void *opt = MWBCamOptions(NULL);
    if (!opt) { MWBLogFile(@"[相机] Options 为空，跳过"); return; }
    if (v == 0) {
        *(uint8_t *)((char *)opt + CAM_F_THIRD) = 0;
    } else if (v == 1) {
        *(uint8_t *)((char *)opt + CAM_F_THIRD) = 1;
        *(uint8_t *)((char *)opt + CAM_F_FRONT) = 0;
    } else if (v == 2) {
        *(uint8_t *)((char *)opt + CAM_F_THIRD) = 1;
        *(uint8_t *)((char *)opt + CAM_F_FRONT) = 1;
    } else {
        *(uint8_t *)((char *)opt + CAM_F_THIRD) = 1;
        *(uint8_t *)((char *)opt + CAM_F_FRONT) = 2;
    }
    MWBLogFile(@"[相机] 视角切 %d (2cd=%d 2d6=%d)", v,
               *(uint8_t *)((char *)opt + CAM_F_THIRD),
               *(uint8_t *)((char *)opt + CAM_F_FRONT));
    MWBCamPersist(opt);
}

// （注：曾试过直接写条目类型 0→3，但游戏自家静态初始化跑在我们 %ctor 之后，每次都盖回 0，
// 故此路不通；真正起作用的是下面的 createToggle 改道。rescue 位保留只读诊断。）

// Slider::C1 hook：thirdperson 进来把步伐换成自家 {0,1,2,3}，初值从 Options 反推
typedef void *(*SliderCtorFn)(void *thiz, void *mc, void *opt, void *vec);
static SliderCtorFn orig_cam_ctor = NULL;
static void *hooked_cam_ctor(void *thiz, void *mc, void *opt, void *vec) {
    if (opt && opt == MWBCamOpt()) {
        static int sSteps[4] = {0, 1, 2, 3};
        struct { void *b, *e, *c; } v = {sSteps, sSteps + 4, sSteps + 4};
        thiz = orig_cam_ctor(thiz, mc, opt, &v);
        // 初值反推（照抄原构造尾巴的查表逻辑：值→下标→位置）
        void *o = MWBCamOptions(mc);
        int val = 0;
        if (o) {
            uint8_t t = *(uint8_t *)((char *)o + CAM_F_THIRD);
            uint8_t f = *(uint8_t *)((char *)o + CAM_F_FRONT);
            val = t ? (f >= 2 ? 3 : (f ? 2 : 1)) : 0;
        }
        int idx = (val >= 0 && val <= 3) ? val : 0;
        *(int *)((char *)thiz + 0x128) = idx;          // [0x4a] 当前值
        *(int *)((char *)thiz + 0x12c) = idx;          // [0x4b] 下标
        *(float *)((char *)thiz + 0x124) = idx / 3.0f; // [0x49] knob 位置
        MWBLogFile(@"[相机] 滑条创建 初值=%d", idx);
        return thiz;
    }
    return orig_cam_ctor(thiz, mc, opt, vec);
}

// Slider::setOption hook：thirdperson 写 {0x2cd,0x2d6}，其余走原逻辑
typedef void (*SliderSetFn)(void *thiz, void *mc);
static SliderSetFn orig_cam_set = NULL;
static void hooked_cam_set(void *thiz, void *mc) {
    void *opt = *(void **)((char *)thiz + 0x140); // [0x28] 选项
    if (opt && opt == MWBCamOpt()) {
        int v = *(int *)((char *)thiz + 0x128);   // [0x4a] 当前值
        if (v < 0) v = 0;
        if (v > 3) v = 3;
        void *o = MWBCamOptions(mc);
        if (!o) return;
        if (v == 0) *(uint8_t *)((char *)o + CAM_F_THIRD) = 0;
        else if (v == 1) { *(uint8_t *)((char *)o + CAM_F_THIRD) = 1; *(uint8_t *)((char *)o + CAM_F_FRONT) = 0; }
        else if (v == 2) { *(uint8_t *)((char *)o + CAM_F_THIRD) = 1; *(uint8_t *)((char *)o + CAM_F_FRONT) = 1; }
        else { *(uint8_t *)((char *)o + CAM_F_THIRD) = 1; *(uint8_t *)((char *)o + CAM_F_FRONT) = 2; }
        MWBLogFile(@"[相机] 滑条写 %d (2cd=%d 2d6=%d)", v,
                   *(uint8_t *)((char *)o + CAM_F_THIRD),
                   *(uint8_t *)((char *)o + CAM_F_FRONT));
        MWBCamPersist(o);
        return;
    }
    orig_cam_set(thiz, mc);
}

// 正面位持久化（NSUserDefaults，跟 options.txt 互不干扰）：读档由 update hook 接回
// 前值是三态 0=背面/1=正面/2=跟脸正面，必须原值存（存成布尔会把 2 压成 1，跟脸档重进就丢）
static void MWBCamPersist(void *opt) {
    int f = opt ? *(uint8_t *)((char *)opt + CAM_F_FRONT) : 0;
    if (f < 0) f = 0;
    if (f > 2) f = 2;
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setInteger:f forKey:@"MWBCamFront"];
    [d synchronize];
    MWBLogFile(@"[相机] 正面位已存 %d", f);
}

// Options::update hook：读档后把正面位接回（原版只读 2cd，2d6 会丢；三态原值接回，2=跟脸不许压成 1）
typedef unsigned long (*OptionsUpdateFn)(void *thiz);
static OptionsUpdateFn orig_cam_update = NULL;
static unsigned long hooked_cam_update(void *thiz) {
    unsigned long r = orig_cam_update(thiz);
    int f = (int)[[NSUserDefaults standardUserDefaults] integerForKey:@"MWBCamFront"];
    if (f < 0) f = 0;
    if (f > 2) f = 2;
    if (thiz) *(uint8_t *)((char *)thiz + CAM_F_FRONT) = (uint8_t)f;
    MWBLogFile(@"[相机] 读档接回正面位=%d", f);
    return r;
}

// 第 4 档（跟脸正面，2d6==2）：镜像背面活路。
// 机理（setupCamera @0x100205bb8 反汇编实锤）：
// - 背面档（2d6=0）走活路：每帧按插值读玩家 +0x78/+0x7c（旧值 +0x80/+0x84），8 向 TileSource::clip 碰撞收距；
// - 正面档（2d6!=0）走缓存 +0x38..+0x44 且无碰撞——旧做法往缓存灌 tick 值：不插值→抖，无 clip→穿墙；
//   且旧 hook 按 (void*,void*) 声明，真签名是 (GameRenderer*, float 插值, int)，hook 内浮点载入踩坏 s0，更抖。
// 现做法：调原函数期间临时 2d6=0，并把视角伪装成反方向（yaw+180、pitch 取反，新旧值一起改），
// 原版背面活路即把机位摆到脸前、带插值与碰撞；返回后原样恢复（模型/输入/身体读的仍是真视角）。
#define CAM_YAW_PREV_OFF 0x80    // 视角 yaw 旧值（Mob::baseTick 每 tick 拷贝，插值用）
#define CAM_PITCH_PREV_OFF 0x84  // 俯仰旧值
typedef void (*SetupCamFn)(void *self, float a, int b);
static SetupCamFn orig_setupcam = NULL;
static void hooked_setupcam(void *self, float a, int b) {
    void *o = MWBCamOptions(NULL);
    char *lp = (char *)gLocalPlayer;
    if (!o || !lp || *(uint8_t *)((char *)o + CAM_F_FRONT) != 2 || !*(uint8_t *)((char *)o + CAM_F_THIRD)) {
        orig_setupcam(self, a, b);
        return;
    }
    float y0 = *(float *)(lp + ENTITY_YAW_OFF), y1 = *(float *)(lp + CAM_YAW_PREV_OFF);
    float p0 = *(float *)(lp + ENTITY_PITCH_OFF), p1 = *(float *)(lp + CAM_PITCH_PREV_OFF);
    *(float *)(lp + ENTITY_YAW_OFF) = y0 + 180.0f; *(float *)(lp + CAM_YAW_PREV_OFF) = y1 + 180.0f;
    *(float *)(lp + ENTITY_PITCH_OFF) = -p0;       *(float *)(lp + CAM_PITCH_PREV_OFF) = -p1;
    *(uint8_t *)((char *)o + CAM_F_FRONT) = 0;
    orig_setupcam(self, a, b);
    *(uint8_t *)((char *)o + CAM_F_FRONT) = 2;
    *(float *)(lp + ENTITY_YAW_OFF) = y0; *(float *)(lp + CAM_YAW_PREV_OFF) = y1;
    *(float *)(lp + ENTITY_PITCH_OFF) = p0; *(float *)(lp + CAM_PITCH_PREV_OFF) = p1;
}

// 诊断：条目类型 + 双字段 + 相机实体身份（caminfo flag 打）
// v20 = *(MC+0x1b0) 是 setupCamera 读 yaw 的实体，对比它是不是 gLocalPlayer
void MWBCamDiag(void) {
    void *o = MWBCamOptions(NULL);
    void *mc = MWB010Minecraft();
    void *v20 = mc ? *(void **)((char *)mc + 0x1b0) : NULL;
    MWBLogFile(@"[相机] 诊断 条目类型=%d 值=%d 2cd=%d 2d6=%d",
               *(uint8_t *)MWBCamOpt(), MWBCamValue(),
               o ? *(uint8_t *)((char *)o + CAM_F_THIRD) : -1,
               o ? *(uint8_t *)((char *)o + CAM_F_FRONT) : -1);
    MWBLogFile(@"[相机] 实体 mc=%p v20(MC+0x1b0)=%p lp=%p 同体=%d v20+0x3c=%.1f lp+0x3c=%.1f lp+0x78=%.1f lp+0x150=%.1f lp+0x158=%.1f",
               mc, v20, gLocalPlayer, (v20 && v20 == gLocalPlayer) ? 1 : 0,
               v20 ? *(float *)((char *)v20 + 0x3c) : 9999.0f,
               gLocalPlayer ? *(float *)((char *)gLocalPlayer + 0x3c) : 9999.0f,
               gLocalPlayer ? *(float *)((char *)gLocalPlayer + ENTITY_YAW_OFF) : 9999.0f,
               gLocalPlayer ? *(float *)((char *)gLocalPlayer + ENTITY_BODY_YAW_OFF) : 9999.0f,
               gLocalPlayer ? *(float *)((char *)gLocalPlayer + 0x158) : 9999.0f);
}

// createToggle hook：Game 组里第三人称原来写死走开关，在此改道步进滑条（步伐由 C1 hook 填）。
// 其余选项照旧；每个路过的开关记 id（只在设置构建时跑，不刷屏）。
typedef void (*CreateToggleFn)(void *grp, void *opt, void *mc);
static CreateToggleFn orig_cam_toggle = NULL;
typedef void (*CreateStepFn)(void *grp, void *opt, void *mc);
static CreateStepFn real_cam_step = NULL;
static void hooked_cam_toggle(void *grp, void *opt, void *mc) {
    if (opt) {
        int oid = *(int *)((char *)opt + 0x20); // 条目+0x20 = id
        MWBLogFile(@"[相机] createToggle 路过 id=%d", oid);
        if (opt == MWBCamOpt()) {
            MWBLogFile(@"[相机] thirdperson 改道步进滑条");
            if (!real_cam_step) real_cam_step = (CreateStepFn)MSFindSymbol(NULL,
                "__ZN12OptionsGroup16createStepSliderEPKN7Options6OptionEP15MinecraftClient");
            if (real_cam_step) { real_cam_step(grp, opt, mc); return; }
        }
    }
    orig_cam_toggle(grp, opt, mc);
}

// 0.10 才安装（Tweak.xm %ctor 调用，版本不对直接返回）
void MWBInstallCamera010(void) {
    if (gGV != (int)MWBGameV0_10) return;
    MWB_HOOK("__ZN6SliderC1EP15MinecraftClientPKN7Options6OptionERKNSt3__16vectorIiNS6_9allocatorIiEEEE",
             hooked_cam_ctor, orig_cam_ctor);
    MWB_HOOK("__ZN6Slider9setOptionEP15MinecraftClient",
             hooked_cam_set, orig_cam_set);
    MWB_HOOK("__ZN12OptionsGroup12createToggleEPKN7Options6OptionEP15MinecraftClient",
             hooked_cam_toggle, orig_cam_toggle);
    MWB_HOOK("__ZN7Options6updateEv",
             hooked_cam_update, orig_cam_update);
    MWB_HOOK("__ZN12GameRenderer11setupCameraEfi",
             hooked_setupcam, orig_setupcam);
    MWBLogFile(@"[相机] 三视角滑条挂载就绪（开关 cam-N/caminfo 调试保留）");
}
