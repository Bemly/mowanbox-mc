/* MWBHooks010.mm — 0.10 hook (normalTick/levelTick/加速常量) */
#import "MWBCommon.h"
#import <mach/mach.h>

#pragma mark - C++ 游戏函数 hook

typedef void (*NormalTickFn)(void *self);
static NormalTickFn orig_normalTick = NULL;
static int gTickCount = 0;
static void hooked_normalTick(void *self) {
    orig_normalTick(self);
    MWBMarkWorldTick();
    gLocalPlayer = self;
    gTickCount++;
    char *abil = (char *)self + PLAYER_ABILITIES_OFFSET;
    if (gInvincible) abil[ABIL_INVULNERABLE] = 1;
    if (gFly) { abil[ABIL_FLYING] = 1; abil[ABIL_MAY_FLY] = 1; }
    if (gFastBreak) abil[ABIL_INSTABUILD] = 1;
    // 超级跳跃: 检测跳跃瞬间的速度 (jumpFromGround 设为 0.42)
    if (gSuperJump) {
        float *vy = (float *)((char *)self + ENTITY_VELOCITY_Y_OFFSET);
        if (*vy > 0.40f && *vy < 0.44f) *vy = 0.85f;
    }
    // 调试日志: 每 200 tick 输出一次状态
    if (gMWBDebug && (gTickCount % 200) == 1) {
        NSString *m = [NSString stringWithFormat:
            @"%@ [Toolbox调试] tick #%d player=%p abil=[%d,%d,%d,%d] vy=%.3f speed=%s fly=%s inv=%s fast=%s jump=%s\n",
            [NSDate date], gTickCount, self,
            abil[0], abil[1], abil[2], abil[3],
            *(float *)((char *)self + ENTITY_VELOCITY_Y_OFFSET),
            gSpeed ? "开" : "关", gFly ? "开" : "关",
            gInvincible ? "开" : "关", gFastBreak ? "开" : "关",
            gSuperJump ? "开" : "关"];
        NSURL *logURL = [NSURL fileURLWithPath:@"/var/mobile/Documents/mowanbox.log"];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingToURL:logURL error:nil];
        if (fh) { [fh seekToEndOfFile]; [fh writeData:[m dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
    }
    MWBPollCmdFile();   // 0.10 也接 flag 文件通道 (time/reactor/diff/mob/explode)
}

typedef void (*LevelTickFn)(void *self);
static LevelTickFn orig_levelTick = NULL;

// 0.10 渲染器捕获 (LevelRenderer::setLevel 在世界加载时调, 932B, hook 安全)
static void *gRenderer010 = NULL;
static void *gRendererLevel010 = NULL;
typedef void (*SetLevelFn)(void *self, void *level);
static SetLevelFn orig_010_setLevel = NULL;
static void hooked_010_setLevel(void *self, void *level) {
    orig_010_setLevel(self, level);
    gRenderer010 = self;
    gRendererLevel010 = level;
    MWBLogFile(@"[010] 捕获渲染器 %p (level=%p)", self, level);
}
// 时间跳变后全量重刷区块: 地面光照烘焙在区块网格里, 只写 dayTime 不会重算,
// 必须调 LevelRenderer::allChanged 让所有区块按当前亮度重建 (相当于自然过夜的重刷路径)
void MWB010RefreshChunks(void) {
    if (!gRenderer010 || !gLevel) return;
    if (gRendererLevel010 && gRendererLevel010 != gLevel) return;  // 世界已切换, 旧指针不用
    void *vt = *(void **)gRenderer010;
    uintptr_t s = MWBMainSlide();
    if ((uintptr_t)vt < s + 0x100000000UL || (uintptr_t)vt >= s + 0x100400000UL) return;  // 虚表不在TEXT段, 不调
    void (*allChanged)(void *) = (void (*)(void *))MSFindSymbol(NULL, "__ZN13LevelRenderer10allChangedEv");
    if (!allChanged) return;
    allChanged(gRenderer010);
    MWBLogFile(@"[010] 已刷新区块 (allChanged renderer=%p)", gRenderer010);
}
static void hooked_levelTick(void *self) {
    orig_levelTick(self);
    MWBMarkWorldTick();
    gLevel = self;
    // 白天/夜晚: 写 dayTime 的同时清掉天空覆写 (+0x15F0>=0 时渲染只认覆写, 逻辑只认 dayTime)
    if (gTimeMode == 1) {
        *(int64_t *)((char *)self + LEVEL_TIME_OFFSET) = TICK_TIME_DAY;
        *(int64_t *)((char *)self + LEVEL_TIME_OVERRIDE_OFF) = -1;
    } else if (gTimeMode == 2) {
        *(int64_t *)((char *)self + LEVEL_TIME_OFFSET) = TICK_TIME_NIGHT;
        *(int64_t *)((char *)self + LEVEL_TIME_OVERRIDE_OFF) = -1;
    }
    // 时间模式一切换就全量刷新一次 (含切回自然), 让地面光跟上天空; 只在变化边沿触发
    static int s_lastTimeMode = -1;
    if (gTimeMode != s_lastTimeMode) {
        s_lastTimeMode = gTimeMode;
        dispatch_async(dispatch_get_main_queue(), ^{ MWB010RefreshChunks(); });
    }
}
#pragma mark - 0.10 生存/创造切换后端
void MWB010SetCreative(void *player, bool creative) {
    if (!player) player = gLocalPlayer;
    if (!player) return;
    char *a = (char *)player + PLAYER_ABILITIES_OFFSET;
    if (creative) { a[0] = 1; a[2] = 1; a[3] = 1; }
    else *(uint32_t *)a = 0;
}

// 0.10 gMinecraft 捕获 (Minecraft::tick 首参即this) + 完整版切换 + 传送直调
static void *gMinecraft010 = NULL;
typedef void (*MinecraftTick010Fn)(void *self, int a, int b);
static MinecraftTick010Fn orig_mc010Tick = NULL;
static void hooked_mc010Tick(void *self, int a, int b) {
    orig_mc010Tick(self, a, b);
    gMinecraft010 = self;
}
void MWB010SetCreativeFull(bool creative) {
    void (*setC)(void *, bool) = (void (*)(void *, bool))MSFindSymbol(NULL, "__ZN9Minecraft17setIsCreativeModeEb");
    if (setC && gMinecraft010) { setC(gMinecraft010, creative); return; }
    MWB010SetCreative(NULL, creative);
}
bool MWB010Teleport(void *player, float x, float y, float z) {
    typedef void (*TpFn)(void *, float, float, float);
    TpFn tp = (TpFn)MSFindSymbol(NULL, "__ZN3Mob10teleportToEfff");
    if (!tp || !player) player = gLocalPlayer;
    if (!tp || !player) return false;
    tp(player, x, y, z);
    return true;
}
// 加速奔跑: Player::getBaseSpeed 只有 12 字节 (adrp+ldr+ret, 返回全局常量 0.1f),
// Substrate 的 arm64 跳板需要 16 字节, hook 它会踩坏紧随其后的
// Player::getEntityTypeId, 进世界后首次移动即 SIGILL 闪退 (2026-08-28 崩溃日志)。
// 反汇编确认该常量位于 __TEXT,__const 静态地址 0x1002ab79c,
// 全二进制仅 getBaseSpeed 一处引用, 因此不 hook 函数, 直接用
// vm_protect(VM_PROT_COPY) 改写常量, 只影响玩家速度, 不影响怪物
#define PLAYER_BASESPEED_VMADDR 0x1002ab79c
#define MWB_SPEED_MULT 2.5f

static float gOrigBaseSpeed = 0.0f;   // 原始基础速度 (首次改写前缓存)

// 按开关改写/恢复玩家基础速度常量
void MWBApplySpeed(BOOL on) {
    float *p = (float *)(MWBMainSlide() + PLAYER_BASESPEED_VMADDR);
    if (!gOrigBaseSpeed) gOrigBaseSpeed = *p;
    vm_address_t page = ((vm_address_t)p) & ~(vm_page_size - 1);
    kern_return_t kr = vm_protect(mach_task_self(), page, vm_page_size, 0,
                                  VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) {
        NSLog(@"[魔玩盒子] 加速奔跑失败: vm_protect 改写权限被拒 (%d)", kr);
        return;
    }
    *p = on ? gOrigBaseSpeed * MWB_SPEED_MULT : gOrigBaseSpeed;
    // 写完恢复只读可执行
    vm_protect(mach_task_self(), page, vm_page_size, 0, VM_PROT_READ | VM_PROT_EXECUTE);
    NSLog(@"[魔玩盒子] 加速奔跑 %@ (基础速度 %.1f → %.2f)",
          on ? @"已开启" : @"已关闭", gOrigBaseSpeed, *p);
}

// 0.10 hook 安装 (%ctor 调用)
void MWBInstallHooks010(void) {
    MWB_HOOK("__ZN11LocalPlayer10normalTickEv", hooked_normalTick, orig_normalTick);
    MWB_HOOK("__ZN5Level4tickEv", hooked_levelTick, orig_levelTick);
    MWB_HOOK("__ZN9Minecraft4tickEii", hooked_mc010Tick, orig_mc010Tick);
    MWB_HOOK("__ZN13LevelRenderer8setLevelEP5Level", hooked_010_setLevel, orig_010_setLevel);
}
