/* MWBHooks120.mm — 1.20.62 ECS hook */
#import "MWBCommon.h"

#pragma mark - 1.20.62 版本适配 (EnTT ECS, systemBody为主hook)
// 逆向纠正: 旧tick@0x105D03F74打偏(事件路径非常驻); 换ECS system body@0x101F5CD20
// +wrapper@0x101F5D8B4+abilWrite@0x1040AA2B0; abilities无固定偏移, 运行时探测
#define V120_TICK_SENDINPUT_VA 0x105D03F74UL
#define V120_SYS_BODY_VA    0x101F5CD20UL
#define V120_SYS_WRAP_VA    0x101F5D8B4UL
#define V120_ABILWRITE_VA   0x1040AA2B0UL
#define V120_MOBGETBYID_VA  0x105D14BC8UL
#define V120_LEVELDATA_TIME_OFF 0x388
#define V120_LEVELDATA_GAME_OFF 0x370
#define V120_GETTIME_VA 0x1026D2DD8UL
#define V120_SETTIME_VA 0x106D30960UL
#define V120_UNWRAP_VA  0x106D31750UL

typedef void (*V120TickFn)(void *self);
typedef void (*V120SysBodyFn)(void *registry, uint64_t entity);
typedef void (*V120WrapFn)(void *actorLike);
typedef void (*V120AbilWriteFn)(void *pkt, void *stream, void *ctx);
typedef int (*V120GetTimeFn)(void *levelData);
typedef void (*V120SetTimeFn)(void *levelData, int t);
typedef void *(*V120UnwrapFn)(void *smartptr);
static V120TickFn orig_120_tick = NULL;
static V120SysBodyFn orig_120_sysBody = NULL;
static V120WrapFn orig_120_wrapper = NULL;
static V120AbilWriteFn orig_120_abilWrite = NULL;
static int gTick120 = 0;
static int gTick120b = 0;

static void hooked_120_tick(void *self) {
    orig_120_tick(self);
    MWBMarkWorldTick();
    gTick120++;
    if (!gLevelData120 && self) {
        V120UnwrapFn unwrap = (V120UnwrapFn)(MWBMainSlide() + V120_UNWRAP_VA);
        void *cand = unwrap((char *)self + 0x9D0);
        if (!cand) cand = unwrap(*(void **)((char *)self + 8));
        gLevelData120 = cand;
    }
    if (gLevelData120) {
        V120SetTimeFn setTime = (V120SetTimeFn)(MWBMainSlide() + V120_SETTIME_VA);
        if (gTimeMode == 1) setTime(gLevelData120, TICK_TIME_DAY);
        else if (gTimeMode == 2) setTime(gLevelData120, TICK_TIME_NIGHT);
    }
    if (gMWBDebug && (gTick120 % 200) == 1) {
        NSURL *logURL = [NSURL fileURLWithPath:@"/var/mobile/Documents/mowanbox.log"];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingToURL:logURL error:nil];
        if (fh) {
            [fh seekToEndOfFile];
            V120GetTimeFn getTime = (V120GetTimeFn)(MWBMainSlide() + V120_GETTIME_VA);
            int dayTime = gLevelData120 ? getTime(gLevelData120) : -1;
            NSString *line = [NSString stringWithFormat:@"%@ [120] tick #%d self=%p dayTime=%d\n",
                              [NSDate date], gTick120, self, dayTime];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    }
}

// ECS system body: x0=registry, x1=entity (每tick跑, 本地受控才进body)
static void hooked_120_sysBody(void *registry, uint64_t entity) {
    orig_120_sysBody(registry, entity);
    if (gMWBDebug && ((++gTick120b % 200) == 1)) {
        NSURL *logURL = [NSURL fileURLWithPath:@"/var/mobile/Documents/mowanbox.log"];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingToURL:logURL error:nil];
        if (fh) {
            [fh seekToEndOfFile];
            int flag = gActor120 ? ((unsigned char *)gActor120)[0x1ED8] : -1;
            NSString *line = [NSString stringWithFormat:@"%@ [120sys] #%d reg=%p ent=0x%llx actor=%p flag=%d\n",
                              [NSDate date], gTick120b, registry, entity, gActor120, flag];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    }
    if (gLevelData120 && (gTimeMode == 1 || gTimeMode == 2)) {
        V120SetTimeFn setTime = (V120SetTimeFn)(MWBMainSlide() + V120_SETTIME_VA);
        setTime(gLevelData120, (gTimeMode == 1 ? TICK_TIME_DAY : TICK_TIME_NIGHT));
    }
}
// wrapper: x0=Actor-like (+0x1ED8本地标志, +0xB90实体)
static void hooked_120_wrapper(void *self) {
    orig_120_wrapper(self);
    gActor120 = self;
}
// abilWrite: 只记包指针 (读链回推用, 不改包)
static void hooked_120_abilWrite(void *pkt, void *stream, void *ctx) {
    orig_120_abilWrite(pkt, stream, ctx);
    if (gMWBDebug && (gTick120b % 200) == 1) {
        NSURL *logURL = [NSURL fileURLWithPath:@"/var/mobile/Documents/mowanbox.log"];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingToURL:logURL error:nil];
        if (fh) {
            [fh seekToEndOfFile];
            NSString *line = [NSString stringWithFormat:@"%@ [120abil] pkt=%p stream=%p ctx=%p\n",
                              [NSDate date], pkt, stream, ctx];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    }
}
// 1.20 药水直调验有效性 (纯函数): 1=速度 8=跳跃 16=夜视
void MWB120ProbeMobEffect(void) {
    void *(*getById)(int) = (void *(*)(int))(MWBMainSlide() + V120_MOBGETBYID_VA);
    void *e1 = getById(1), *e8 = getById(8), *e16 = getById(16);
    NSURL *logURL = [NSURL fileURLWithPath:@"/var/mobile/Documents/mowanbox.log"];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingToURL:logURL error:nil];
    if (fh) {
        [fh seekToEndOfFile];
        NSString *line = [NSString stringWithFormat:@"%@ [120药水] speed=%p jump=%p nightvision=%p\n",
                          [NSDate date], e1, e8, e16];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
}

// 1.20.62 hook 安装: ECS systemBody为主hook (旧sendInput打偏, 保留但不再依赖)
void MWBInstallHooks120(void) {
    uintptr_t s120 = MWBMainSlide();
    MSHookFunction((void *)(s120 + V120_TICK_SENDINPUT_VA), (void *)hooked_120_tick, (void **)&orig_120_tick);
    MSHookFunction((void *)(s120 + V120_SYS_BODY_VA), (void *)hooked_120_sysBody, (void **)&orig_120_sysBody);
    MSHookFunction((void *)(s120 + V120_SYS_WRAP_VA), (void *)hooked_120_wrapper, (void **)&orig_120_wrapper);
    MSHookFunction((void *)(s120 + V120_ABILWRITE_VA), (void *)hooked_120_abilWrite, (void **)&orig_120_abilWrite);
    NSLog(@"[魔玩盒子] 1.20.62 hook: tick+sysBody+wrapper+abilWrite");
    MWBLogFile(@"[120] hook 成功: tick+sysBody+wrapper+abilWrite");
}
