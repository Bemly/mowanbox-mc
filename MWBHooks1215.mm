/* MWBHooks1215.mm — 1.2.15 hook + one-shot */
#import "MWBCommon.h"

#pragma mark - 1.2.15 版本适配 (本机未安装, 只合入不验证)
// 逆向纠正: instabuild=idx2(旧idx3实为lightning); LevelData内联Level+0xF8不解引用
// 能力表: 0=invulnerable 1=flying 2=instabuild 3=lightning 4=flySpeed 5=walkSpeed
//         6=noclip 7=mayfly 8=worldbuilder 9=mute
#define V1215_PLAYER_TICK   0x100376F78UL
#define V1215_LEVEL_TIMETICK 0x1005D41A4UL
#define V1215_SET_BOOL      0x100E97BF0UL
#define V1215_SET_FLOAT     0x100E97C88UL
#define V1215_ABIL_BASE     0x101F112D8UL
#define V1215_ABIL_FLYING   1
#define V1215_ABIL_INSTABUILD 2
#define V1215_ABIL_FLYSPEED 4
#define V1215_ABIL_WALKSPEED 5
#define V1215_ABIL_NOCLIP   6
#define V1215_ABIL_MAYFLY   7
#define V1215_PLAYER_ABIL_OFF 0x370
#define V1215_ACTOR_INVULN_OFF 0x24E
#define V1215_LD_OFF        0xF8
#define V1215_LD_TIME_OFF   0x12C
#define V1215_LD_RAIN_OFF   0x188
#define V1215_LD_LIGHT_OFF  0x18C
#define V1215_GET_SELECT    0x100E9F314UL
#define V1215_ST_FILL       0x100F11D64UL
#define V1215_ST_BLANK      0x100F125A8UL
#define V1215_CONT_ADD      0x100C36B50UL
#define V1215_CONT_FLAG     0x101F14B50UL
#define V1215_EQUIP_OFF     0x1820
#define V1215_ENCH_APPLY    0x100F54D30UL
#define V1215_FX_LOOKUP     0x100D4D6A4UL
#define V1215_FX_MAKE       0x100D4F114UL
#define V1215_FX_ADD        0x100DB8BE4UL
#define V1215_TP_SLOT       208
#define V1215_XP_PTS_SLOT   3024
#define V1215_XP_LVL_SLOT   3032
#define V1215_SET_SPAWN     0x100E9DB84UL

typedef void (*V1215TickFn)(void *self);
typedef void (*V1215SetBoolFn)(void *abil, void *entry, unsigned char v);
typedef void (*V1215SetFloatFn)(void *abil, void *entry, float v);
static V1215TickFn orig_1215_playerTick = NULL, orig_1215_timeTick = NULL;

static void hooked_1215_playerTick(void *self) {
    orig_1215_playerTick(self);
    MWBMarkWorldTick();
    gPlayer1215 = self;
    if (gInvincible) ((unsigned char *)self)[V1215_ACTOR_INVULN_OFF] = 1;
    void *abil = (char *)self + V1215_PLAYER_ABIL_OFF;
    uintptr_t slide = MWBMainSlide();
    V1215SetBoolFn setB = (V1215SetBoolFn)(slide + V1215_SET_BOOL);
    V1215SetFloatFn setF = (V1215SetFloatFn)(slide + V1215_SET_FLOAT);
    if (gFastBreak) setB(abil, (void *)(slide + V1215_ABIL_BASE + V1215_ABIL_INSTABUILD * 0x18), 1);
    if (gFly) {
        setB(abil, (void *)(slide + V1215_ABIL_BASE + V1215_ABIL_FLYING * 0x18), 1);
        setB(abil, (void *)(slide + V1215_ABIL_BASE + V1215_ABIL_MAYFLY * 0x18), 1);
    }
    if (gNoclip) setB(abil, (void *)(slide + V1215_ABIL_BASE + V1215_ABIL_NOCLIP * 0x18), 1);
    if (gSpeed) setF(abil, (void *)(slide + V1215_ABIL_BASE + V1215_ABIL_WALKSPEED * 0x18), 0.25f);
}
static void hooked_1215_timeTick(void *level) {
    orig_1215_timeTick(level);
    MWBMarkWorldTick();
    if (gTimeMode == 1 || gTimeMode == 2) {
        // LevelData内联, 直接加偏移 (旧代码多一次解引用是野指针bug)
        *(int32_t *)((char *)level + V1215_LD_OFF + V1215_LD_TIME_OFF) =
            (gTimeMode == 1 ? 1000 : 13000);
    }
    if (gWeatherMode == 1 || gWeatherMode == 2) {
        char *ld = (char *)level + V1215_LD_OFF;
        if (gWeatherMode == 1) { *(float *)(ld + V1215_LD_RAIN_OFF) = 0.0f; *(int *)(ld + V1215_LD_LIGHT_OFF) = 0; }
        else { *(float *)(ld + V1215_LD_RAIN_OFF) = 1.0f; *(int *)(ld + V1215_LD_LIGHT_OFF) = 0; }
    }
}
// 1.2.15 one-shot: 方块给予/附魔/药水/传送/XP/出生点 (静态结论, 待真机验)
bool MWB1215_GiveBlock(void *player, int blkId, int count) {
    if (!player || blkId < 0 || blkId > 255 || count < 1) return false;
    uintptr_t s = MWBMainSlide();
    char proto[120], one[120];
    memset(proto, 0, sizeof(proto));
    ((void (*)(void *))(s + V1215_ST_BLANK))(proto);
    ((void (*)(void *, int, int, int))(s + V1215_ST_FILL))(proto, blkId, count, 0);
    if (*(uint8_t *)(proto + 0x13) == 0) return false;
    ((void (*)(void *, void *, void *))(s + V1215_CONT_ADD))(
        (char *)player + V1215_EQUIP_OFF, (void *)(s + V1215_CONT_FLAG), proto);
    (void)one;
    return true;
}
bool MWB1215_EnchantHeld(void *player, int enchId, int level) {
    if (!player) return false;
    uintptr_t s = MWBMainSlide();
    void *st = ((void *(*)(void *))(s + V1215_GET_SELECT))(player);
    if (!st) return false;
    ((void (*)(void *, int, int))(s + V1215_ENCH_APPLY))(st, enchId, level);
    return true;
}
bool MWB1215_Effect(void *player, int fxId, int seconds, int ampl) {
    if (!player) return false;
    uintptr_t s = MWBMainSlide();
    void *fx = ((void *(*)(int))(s + V1215_FX_LOOKUP))(fxId);
    if (!fx) return false;
    char inst[16];
    memset(inst, 0, sizeof(inst));
    ((void (*)(void *, void *, int, int, int, int))(s + V1215_FX_MAKE))(inst, fx, seconds * 20, ampl, 0, 1);
    ((void (*)(void *, void *))(s + V1215_FX_ADD))(player, inst);
    return true;
}
bool MWB1215_Teleport(void *player, float x, float y, float z) {
    if (!player) return false;
    float v[3] = {x, y, z};
    ((void (*)(void *, float *, int, int, int))(*(void **)((char *)player + V1215_TP_SLOT)))(player, v, 1, 3, 1);
    return true;
}
bool MWB1215_AddXP(void *player, int pts) {
    if (!player || !pts) return false;
    ((void (*)(void *, int))(*(void **)((char *)player + V1215_XP_PTS_SLOT)))(player, pts);
    return true;
}

// 1.2.15 hook 安装: 本机未安装, 合入待验 (Actor无敌位+能力setter+时间tick)
void MWBInstallHooks1215(void) {
    uintptr_t s1215 = MWBMainSlide();
    MSHookFunction((void *)(s1215 + V1215_PLAYER_TICK), (void *)hooked_1215_playerTick, (void **)&orig_1215_playerTick);
    MSHookFunction((void *)(s1215 + V1215_LEVEL_TIMETICK), (void *)hooked_1215_timeTick, (void **)&orig_1215_timeTick);
    NSLog(@"[魔玩盒子] 1.2.15 hook: playerTick+timeTick");
    MWBLogFile(@"[1215] hook 成功: playerTick+timeTick");
}
