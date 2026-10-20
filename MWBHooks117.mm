/* MWBHooks117.mm — 1.1.7 hook + Abilities/给予/附魔 */
#import "MWBCommon.h"

#pragma mark - 1.1.7 版本适配 (Abilities API 直接调用)
// 逆向结论: Abilities=Player+0x1258, setBool/getBool/setFloat 三件套+能力名bss,
// Level::tick @0x100B0398C, dayTime=Level+0x15C int32, 跳跃取值器 @0x10099CA88
#define V117_PLAYERTICK_VA     0x100439DE0UL
#define V117_LEVELTICK_VA      0x100B0398CUL
#define V117_JUMPPOWER_VA      0x10099CA88UL
#define V117_SETBOOL_VA        0x100A450F0UL
#define V117_SETFLOAT_VA       0x100A45134UL
#define V117_ABILITIES_OFF     0x1258
#define V117_LEVEL_DAYTIME_OFF 0x15C
#define V117_ABIL_INVULN       0x10178BD48UL
#define V117_ABIL_FLYING       0x10178BD60UL
#define V117_ABIL_INSTABUILD   0x10178BD78UL
#define V117_ABIL_MAYFLY       0x10178BDF0UL
#define V117_ABIL_WALKSPEED    0x10178BDC0UL
#define V117_ABIL_FLYSPEED     0x10178BDA8UL
#define V117_GETBOOL_VA        0x100A450C4UL
#define V117_HURT_VA           0x100997D40UL
#define V117_MKITEM_VA         0x1007B16F4UL
#define V117_MKENCH_VA         0x1007B1748UL
#define V117_APPLYENCH_VA      0x100AE6028UL
#define V117_HELDITEM_VA       0x100A4A110UL
#define V117_ITEMREG_VA        0x10178CCF8UL
#define V117_NIGHT_TRUE        18000  // 13000只是日落, 真夜用18000

typedef void (*V117TickFn)(void *self);
typedef void (*V117SetBoolFn)(void *abil, void *name, int v);
typedef int (*V117GetBoolFn)(void *abil, void *name);
typedef void (*V117SetFloatFn)(void *abil, void *name, float v);
typedef float (*V117JumpFn)(void *self);
static V117TickFn orig_117_playerTick = NULL, orig_117_levelTick = NULL;
static V117JumpFn orig_117_jump = NULL;
typedef int (*V117HurtFn)(void *self, void *src, int dmg, void *a, void *b);
static V117GetBoolFn orig_117_getBool = NULL;
static V117HurtFn orig_117_hurt = NULL;
static int gHurtCount117 = 0;  // hurt 调用计数 (死亡之谜诊断用)

// 无敌: 拦截 getBool 单点, 覆盖所有副本与伤害类型 (hurt/fire/helper 全走这里)
static int hooked_117_getBool(void *abil, void *entry) {
    if (gInvincible && entry == (void *)(MWBMainSlide() + V117_ABIL_INVULN)) return 1;
    return orig_117_getBool(abil, entry);
}
// 兜底: hurt 计数+诊断 (若getBool拦截后仍死, 下一步直接return 0)
static int hooked_117_hurt(void *self, void *src, int dmg, void *a, void *b) {
    gHurtCount117++;
    if (gMWBDebug && (gHurtCount117 % 5) == 1) {
        NSURL *logURL = [NSURL fileURLWithPath:@"/var/mobile/Documents/mowanbox.log"];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingToURL:logURL error:nil];
        if (fh) {
            [fh seekToEndOfFile];
            V117GetBoolFn getB = (V117GetBoolFn)(MWBMainSlide() + V117_GETBOOL_VA);
            int inv = getB((char *)self + V117_ABILITIES_OFF, (void *)(MWBMainSlide() + V117_ABIL_INVULN));
            NSString *line = [NSString stringWithFormat:@"%@ [117受伤] #%d self=%p dmg=%d inv=%d\n",
                              [NSDate date], gHurtCount117, self, dmg, inv];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    }
    return orig_117_hurt(self, src, dmg, a, b);
}
static V117SetBoolFn v117_setBool = NULL;
static V117SetFloatFn v117_setFloat = NULL;
static int gTick117 = 0;

static void hooked_117_playerTick(void *self) {
    orig_117_playerTick(self);
    MWBMarkWorldTick();
    gPlayer117 = self;
    MWBPollCmdFile();
    gTick117++;
    void *abil = (char *)self + V117_ABILITIES_OFF;
    uintptr_t s = MWBMainSlide();
    V117SetBoolFn setB = (V117SetBoolFn)(s + V117_SETBOOL_VA);
    V117SetFloatFn setF = (V117SetFloatFn)(s + V117_SETFLOAT_VA);
    if (gInvincible) setB(abil, (void *)(s + V117_ABIL_INVULN), 1);
    if (gFly) {
        setB(abil, (void *)(s + V117_ABIL_FLYING), 1);
        setB(abil, (void *)(s + V117_ABIL_MAYFLY), 1);
    }
    if (gFastBreak) setB(abil, (void *)(s + V117_ABIL_INSTABUILD), 1);
    if (gSpeed) setF(abil, (void *)(s + V117_ABIL_WALKSPEED), 0.25f);
    if (gMWBDebug && (gTick117 % 200) == 1) {
        NSURL *logURL = [NSURL fileURLWithPath:@"/var/mobile/Documents/mowanbox.log"];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingToURL:logURL error:nil];
        if (fh) {
            [fh seekToEndOfFile];
            V117GetBoolFn getB = (V117GetBoolFn)(MWBMainSlide() + V117_GETBOOL_VA);
            int inv = -1, fly = -1;
            if (getB) {
                void *abil = (char *)self + V117_ABILITIES_OFF;
                uintptr_t s = MWBMainSlide();
                inv = getB(abil, (void *)(s + V117_ABIL_INVULN));
                fly = getB(abil, (void *)(s + V117_ABIL_FLYING));
            }
            NSString *line = [NSString stringWithFormat:@"%@ [117] tick #%d player=%p inv=%d fly=%d\n",
                              [NSDate date], gTick117, self, inv, fly];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    }
}
static void hooked_117_levelTick(void *self) {
    orig_117_levelTick(self);
    MWBMarkWorldTick();
    if (gTimeMode == 1) *(int32_t *)((char *)self + V117_LEVEL_DAYTIME_OFF) = TICK_TIME_DAY;
    else if (gTimeMode == 2) *(int32_t *)((char *)self + V117_LEVEL_DAYTIME_OFF) = V117_NIGHT_TRUE;
    static int s_lv117 = 0;
    if (gMWBDebug && ((++s_lv117 % 200) == 1)) {
        NSURL *logURL = [NSURL fileURLWithPath:@"/var/mobile/Documents/mowanbox.log"];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingToURL:logURL error:nil];
        if (fh) {
            [fh seekToEndOfFile];
            NSString *line = [NSString stringWithFormat:@"%@ [117关卡] #%d level=%p dayTime=%d mode=%d\n",
                              [NSDate date], s_lv117, self,
                              *(int32_t *)((char *)self + V117_LEVEL_DAYTIME_OFF), gTimeMode];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    }
}
static float hooked_117_jump(void *self) {
    if (gSuperJump) return 0.85f;
    return orig_117_jump(self);
}

// 1.1.7 给予: 复刻 GiveCommand 内环 (描述子0x50 + 实例0x70 + mgr虚表+0x18)
bool MWB117_Give(void *player, int itemId, int count) {
    if (!player || itemId < 0 || itemId >= 0x200) return false;
    uintptr_t s = MWBMainSlide();
    void **reg = (void **)(s + V117_ITEMREG_VA);
    void *item = reg[itemId];
    NSURL *logURL = [NSURL fileURLWithPath:@"/var/mobile/Documents/mowanbox.log"];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingToURL:logURL error:nil];
    // 堆分配 (容器add可能引用传入实例, 栈内存返回即野指针, -20连给冻屏教训)
    unsigned char *inst = (unsigned char *)malloc(0x70);
    unsigned char *elem = (unsigned char *)malloc(0x50);
    if (!inst || !elem) { free(inst); free(elem); return false; }
    memset(inst, 0, 0x70);
    memset(elem, 0, 0x50);
    if (item) {
        *(uint16_t *)(elem + 0x00) = (uint16_t)itemId;
        *(int *)(elem + 0x04) = 1;
        *(void **)(elem + 0x10) = item;
        ((void (*)(void *, int, void *))(s + V117_MKITEM_VA))(inst, 0, elem);
    }
    void *mgr = *(void **)((char *)(*(void **)((char *)player + 0x40)) + 0x320);
    void *inv = (char *)player + 0x1288;
    if (fh) {
        [fh seekToEndOfFile];
        NSMutableString *m = [NSMutableString stringWithFormat:@"%@ [117给予] id=%d item=%p mgr=%p inst:",
                             [NSDate date], itemId, item, mgr];
        for (int i = 0; i < 0x70; i += 8)
            [m appendFormat:@" +%x=%02x%02x%02x%02x%02x%02x%02x%02x", i,
             inst[i], inst[i+1], inst[i+2], inst[i+3], inst[i+4], inst[i+5], inst[i+6], inst[i+7]];
        [m appendString:@"\n"];
        [fh writeData:[m dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
    if (!item) { free(inst); free(elem); return false; }
    (void)count;  // count 搬运待实例dump定界后写死
    ((void (*)(void *, void *, void *))((*(void ***)mgr)[3]))(mgr, inv, inst);
    return true;  // inst/elem 堆留给游戏 (容器可能引用, 不free)
}

// 1.1.7 超等级附魔: 跳过 0x100839D74 前置检查, 直调应用 (例: 锋利id9 x255)
bool MWB117_EnchantMax(void *player, int enchId, int level) {
    if (!player || enchId < 0 || enchId >= 0x1B) return false;
    uintptr_t s = MWBMainSlide();
    void *tbl = *(void **)(s + 0x10178E0C78UL);
    if (!tbl || !((void **)tbl)[enchId]) return false;
    void *held = ((void *(*)(void *))(s + V117_HELDITEM_VA))(player);
    if (!held) return false;
    unsigned char st = 0;
    ((void (*)(void *, int, int, unsigned char *))(s + V117_APPLYENCH_VA))(held, enchId, level, &st);
    if ((st & 0xFE) != 2) return false;
    unsigned char *einst = (unsigned char *)malloc(0x70);
    if (!einst) return false;
    memset(einst, 0, 0x70);
    ((void (*)(void *, void *, int, int))(s + V117_MKENCH_VA))(einst, held, enchId, level);
    void *mgr = *(void **)((char *)(*(void **)((char *)player + 0x40)) + 0x320);
    void *inv = (char *)player + 0x1288;
    ((void (*)(void *, void *, void *))((*(void ***)mgr)[3]))(mgr, inv, einst);
    return true;  // einst 堆留给游戏, 不free
}

// 1.1.7 hook 安装: Abilities API + tick hook + 跳跃取值器 (函数均≥32B,跳板安全)
void MWBInstallHooks117(void) {
    uintptr_t slide = MWBMainSlide();
    v117_setBool = (V117SetBoolFn)(slide + V117_SETBOOL_VA);
    v117_setFloat = (V117SetFloatFn)(slide + V117_SETFLOAT_VA);
    MSHookFunction((void *)(slide + V117_PLAYERTICK_VA), (void *)hooked_117_playerTick, (void **)&orig_117_playerTick);
    MSHookFunction((void *)(slide + V117_LEVELTICK_VA), (void *)hooked_117_levelTick, (void **)&orig_117_levelTick);
    MSHookFunction((void *)(slide + V117_JUMPPOWER_VA), (void *)hooked_117_jump, (void **)&orig_117_jump);
    MSHookFunction((void *)(slide + V117_GETBOOL_VA), (void *)hooked_117_getBool, (void **)&orig_117_getBool);
    MSHookFunction((void *)(slide + V117_HURT_VA), (void *)hooked_117_hurt, (void **)&orig_117_hurt);
    NSLog(@"[魔玩盒子] 1.1.7 hook: playerTick/levelTick/jump/getBool+hurt");
    MWBLogFile(@"[117] hook 成功: playerTick+levelTick+jump+getBool+hurt");
}
