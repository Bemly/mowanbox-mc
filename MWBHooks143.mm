/* MWBHooks143.mm — 1.4.3 getter 拦截 + one-shot */
#import "MWBCommon.h"

#pragma mark - 1.4.3 版本适配 (Abilities map 模型, getter 拦截)
// 逆向结论: Abilities=Player+0x1388(内嵌map), getBool/getFloat/canFly/tickTime hook,
// setGameType one-shot 切生存创造, LevelData=Level+0xf8解引用+0x12c
#define V143_GETBOOL_VA     0x100f5070cUL
#define V143_GETFLOAT_VA    0x100f5081cUL
#define V143_CANFLY_VA      0x100f506b4UL
#define V143_SETGAMETYPE_VA 0x100f60b04UL
#define V143_TICKTIME_VA    0x100620c88UL
#define V143_ABILITIES_OFF  0x1388
#define V143_AB_INVULN      0x102089b50UL
#define V143_AB_FLYING      0x102089b68UL
#define V143_AB_INSTABUILD  0x102089b80UL
#define V143_AB_WALKSPEED   0x102089bc8UL
#define V143_AB_MAYFLY      0x102089bf8UL
#define V143_GETITEM_VA     0x100FB2560UL
#define V143_TAGBYITEM_VA   0x100FD7BDCUL
#define V143_GIVEADD_VA     0x100CAB61CUL
#define V143_EMPTYTAG_VA    0x10208D4A0UL
#define V143_APPLYENCH_VA   0x10102C0B4UL
#define V143_HANDREFRESH_VA 0x100F58704UL
#define V143_HAND_OFF       0x15D0
#define V143_SETGAMETYPE2_VA 0x100703F94UL
#define V143_FXMAKE_VA      0x100DF200CUL
#define V143_FXAPPLY_VA     0x100E5F158UL
#define V143_TPFAST_VA      0x100CCE7E4UL
#define V143_PLAYER_LEVEL_OFF 0xD00
#define V143_WEATHER_RAIN_OFF 0x15C
#define V143_WEATHER_RAINT_OFF 0x160
#define V143_WEATHER_LIGHT_OFF 0x164
#define V143_WEATHER_LIGHTT_OFF 0x168

typedef unsigned char (*V143GetBoolFn)(void *abil, void *entry);
typedef float (*V143GetFloatFn)(void *abil, void *entry);
typedef int (*V143CanFlyFn)(void *abil);
typedef void (*V143TickTimeFn)(void *level);
static V143GetBoolFn orig_143_getBool = NULL;
static V143GetFloatFn orig_143_getFloat = NULL;
static V143CanFlyFn orig_143_canFly = NULL;
static V143TickTimeFn orig_143_tickTime = NULL;
static int gTick143 = 0;

static unsigned char hooked_143_getBool(void *abil, void *entry) {
    gPlayer143 = (char *)abil - V143_ABILITIES_OFF;
    uintptr_t s = MWBMainSlide();
    if (gInvincible && entry == (void *)(s + V143_AB_INVULN)) return 1;
    if (gFastBreak && entry == (void *)(s + V143_AB_INSTABUILD)) return 1;
    return orig_143_getBool(abil, entry);
}
static int hooked_143_canFly(void *abil) {
    gPlayer143 = (char *)abil - V143_ABILITIES_OFF;
    if (gFly) return 1;
    return orig_143_canFly(abil);
}
static float hooked_143_getFloat(void *abil, void *entry) {
    if (gSpeed && entry == (void *)(MWBMainSlide() + V143_AB_WALKSPEED)) return 0.25f;
    float r = orig_143_getFloat(abil, entry);
    if (gSuperJump) {  // vy=+0xc8, 起跳瞬间抬升 (三证据, 无需新hook)
        void *p = (char *)abil - V143_ABILITIES_OFF;
        float vy = *(float *)((char *)p + 0xc8);
        if (vy > 0.1f && vy < 0.6f) *(float *)((char *)p + 0xc8) = 0.9f;
    }
    return r;
}
static void hooked_143_tickTime(void *level) {
    orig_143_tickTime(level);
    MWBMarkWorldTick();
    MWBPollCmdFile();
    if (gTimeMode == 1 || gTimeMode == 2) {
        void *ld = *(void **)((char *)level + 0xf8);
        if (ld) *(int32_t *)((char *)ld + 0x12c) = (gTimeMode == 1 ? 1000 : 13000);
    }
    if (gWeatherMode == 1 || gWeatherMode == 2 || gWeatherMode == 3) {
        void *ld = *(void **)((char *)level + 0xf8);
        if (ld) {
            char *w = (char *)ld;
            if (gWeatherMode == 1) {
                *(float *)(w + V143_WEATHER_RAIN_OFF) = 0.0f;
                *(float *)(w + V143_WEATHER_LIGHT_OFF) = 0.0f;
            } else if (gWeatherMode == 2) {
                *(float *)(w + V143_WEATHER_RAIN_OFF) = 1.0f;
                *(int *)(w + V143_WEATHER_RAINT_OFF) = 6000;
                *(float *)(w + V143_WEATHER_LIGHT_OFF) = 0.0f;
            } else {
                *(float *)(w + V143_WEATHER_RAIN_OFF) = 1.0f;
                *(int *)(w + V143_WEATHER_RAINT_OFF) = 6000;
                *(float *)(w + V143_WEATHER_LIGHT_OFF) = 1.0f;
                *(int *)(w + V143_WEATHER_LIGHTT_OFF) = 6000;
            }
        }
    }
    if (gMWBDebug && ((++gTick143 % 200) == 1)) {
        NSURL *logURL = [NSURL fileURLWithPath:MWB_LOG_PATH];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingToURL:logURL error:nil];
        if (fh) {
            [fh seekToEndOfFile];
            NSString *line = [NSString stringWithFormat:@"%@ [143] tickTime #%d level=%p player=%p\n",
                              [NSDate date], gTick143, level, gPlayer143];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    }
}

// 1.4.3 one-shot: 给予钻石 (Tag布局已定死, 容器Player+0x1888)
bool MWB143_Give(void *player, int itemId, int count) {
    if (!player || itemId < 0 || itemId > 511) return false;
    uintptr_t s = MWBMainSlide();
    void *item = ((void *(*)(int))(s + V143_GETITEM_VA))(itemId);
    if (!item) return false;
    char tag[0x78];
    memset(tag, 0, sizeof(tag));
    ((void (*)(void *, void *, int))(s + V143_TAGBYITEM_VA))(tag, item, count);
    ((void (*)(void *, void *, void *))(s + V143_GIVEADD_VA))(
        (char *)player + 0x1888, (void *)(s + V143_EMPTYTAG_VA), tag);
    return true;
}
// 1.4.3 one-shot: 手持超附魔 (跳过上限校验, 例锋利id9 x255)
bool MWB143_EnchantMax(void *player, int enchId, int level) {
    if (!player) return false;
    uintptr_t s = MWBMainSlide();
    void *hand = *(void **)((char *)player + V143_HAND_OFF);
    if (!hand) return false;
    ((void (*)(void *, int, int))(s + V143_APPLYENCH_VA))(hand, enchId, level);
    ((void (*)(void *))(s + V143_HANDREFRESH_VA))(player);
    return true;
}
// 1.4.3 one-shot: 夜视/速度药水 (实例15B: id/dur/amp/+C/+E)
bool MWB143_Effect(void *player, int fxId, int seconds, int ampl) {
    if (!player) return false;
    uintptr_t s = MWBMainSlide();
    char inst[16];
    memset(inst, 0, sizeof(inst));
    ((void (*)(void *, int, int, int, int, int))(s + V143_FXMAKE_VA))(inst, fxId, seconds * 20, ampl, 0, 1);
    ((void (*)(void *, void *))(s + V143_FXAPPLY_VA))(player, inst);
    return true;
}
// 1.4.3 one-shot: 传送 (同维度快路径 sub_100CCE7E4)
bool MWB143_Teleport(void *player, float x, float y, float z) {
    if (!player) return false;
    uintptr_t s = MWBMainSlide();
    float p[3] = {x, y, z};
    ((void (*)(void *, void *, float *, int, float, float, float))(s + V143_TPFAST_VA))(
        NULL, player, p, 3, x, y, z);
    return true;
}
// 1.4.3 one-shot: 生存/创造 (0/1, 替代虚表方案)
bool MWB143_SetGameType(void *player, int type) {
    if (!player || type < 0 || type > 2) return false;
    ((void (*)(void *, int))(MWBMainSlide() + V143_SETGAMETYPE2_VA))(player, type);
    return true;
}

// 1.4.3 hook 安装: getter 拦截模型 (无需 normalTick)
void MWBInstallHooks143(void) {
    uintptr_t s143 = MWBMainSlide();
    MSHookFunction((void *)(s143 + V143_GETBOOL_VA), (void *)hooked_143_getBool, (void **)&orig_143_getBool);
    MSHookFunction((void *)(s143 + V143_CANFLY_VA), (void *)hooked_143_canFly, (void **)&orig_143_canFly);
    MSHookFunction((void *)(s143 + V143_GETFLOAT_VA), (void *)hooked_143_getFloat, (void **)&orig_143_getFloat);
    MSHookFunction((void *)(s143 + V143_TICKTIME_VA), (void *)hooked_143_tickTime, (void **)&orig_143_tickTime);
    NSLog(@"[魔玩盒子] 1.4.3 hook: getBool/canFly/getFloat/tickTime");
    MWBLogFile(@"[143] hook 成功: getBool+canFly+getFloat+tickTime");
}
