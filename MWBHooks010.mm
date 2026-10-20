/* MWBHooks010.mm — 0.10 hook (normalTick/levelTick/加速常量) */
#import "MWBCommon.h"
#import <mach/mach.h>
#import <math.h>

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
// 时间跳变后锻造已加载区块的存储天光 (IDA 定案):
// 香草存储天光恒为几何量 (种子恒15, 全二进制无按时间重算的调用),
// 网格烘焙读存储且渲染链无实时因子, 故只能把"当前亮度"直接锻进存储值:
// 目标值 = 15 - Level+0x90 (白天15/夜晚4), 逐列高度图以上逐格比对写入,
// 再 allChanged 重建。自然模式同样锻一次 (之后随自然漂移, 与香草一致)。
void MWB010RelightLoadedChunks(void) {
    if (!gLocalPlayer || !gLevel) return;
    void *ts = *(void **)((char *)gLocalPlayer + 0x48);
    if (!ts) return;
    void *cs = *(void **)((char *)ts + 32);  // ChunkSource (getRawBrightness 同款取法)
    if (!cs) return;
    typedef void *(*GetChunkFn)(void *, void *);
    GetChunkFn getChunk = (GetChunkFn)*(void **)((char *)*(void **)cs + 0x10);
    if (!getChunk) return;
    float px = *(float *)((char *)gLocalPlayer + 0x28);
    float pz = *(float *)((char *)gLocalPlayer + 0x28 + 8);
    int pcx = ((int)floorf(px)) >> 4, pcz = ((int)floorf(pz)) >> 4;
    // 结构校验: 脚下区块的存储坐标必须==请求坐标 (LevelChunk+0x20/+0x24);
    // 若查找口不是 getExistingChunk 直接放弃 (防错调崩溃)
    int selfPos[2] = {pcx, pcz};
    void *selfChunk = getChunk(cs, selfPos);
    if (!selfChunk || *(int *)((char *)selfChunk + 0x20) != pcx ||
        *(int *)((char *)selfChunk + 0x24) != pcz) {
        MWBLogFile(@"[010] 锻造中止: 脚下区块校验失败 (chunk=%p)", selfChunk);
        return;
    }
    uint8_t dark = *(uint8_t *)((char *)gLevel + 0x90);
    uint8_t target = dark >= 15 ? 0 : 15 - dark;
    NSDate *t0 = [NSDate date];
    int n = 0, cells = 0;
    for (int dz = -8; dz <= 8 && n < 512; dz++) {
        for (int dx = -8; dx <= 8 && n < 512; dx++) {
            int pos[2] = {pcx + dx, pcz + dz};  // ChunkPos{x,z}
            void *chunk = getChunk(cs, pos);
            if (!chunk) continue;
            n++;
            // 高度图 +0x14478 (256字节, 索引 x|z<<4); 天光数组 +0xc078
            for (int lz = 0; lz < 16; lz++) {
                for (int lx = 0; lx < 16; lx++) {
                    int h = *(uint8_t *)((char *)chunk + 0x14478 + (lx | (lz << 4)));
                    if (h < 0) h = 0; if (h > 126) continue;
                    int wx = (pos[0] << 4) + lx, wz = (pos[1] << 4) + lz;
                    for (int y = h + 1; y <= 127; y++) {
                        unsigned long off = (unsigned long)((((wz & 15) << 7) | ((wx & 15) << 11) | (y & 0xfe)) >> 1);
                        uint8_t *bp = (uint8_t *)chunk + 0xc078 + off;
                        uint8_t cur = (y & 1) ? (*bp >> 4) : (*bp & 0xf);
                        if (cur == target) continue;
                        if (y & 1) *bp = (*bp & 0x0f) | (target << 4);
                        else *bp = (*bp & 0xf0) | target;
                        cells++;
                    }
                }
            }
        }
    }
    MWBLogFile(@"[010] 锻造区块天光 %d块 %d格 (dark=%d->%d, %.1fs)", n, cells, dark, target, -[t0 timeIntervalSinceNow]);
}
// 时间跳变后全量重刷区块: 先重算存储光照, 再调 LevelRenderer::allChanged 让网格按新光照重建
void MWB010RefreshChunks(void) {
    if (!gRenderer010 || !gLevel) return;
    if (gRendererLevel010 && gRendererLevel010 != gLevel) return;  // 世界已切换, 旧指针不用
    void *vt = *(void **)gRenderer010;
    uintptr_t s = MWBMainSlide();
    if ((uintptr_t)vt < s + 0x100000000UL || (uintptr_t)vt >= s + 0x100400000UL) return;  // 虚表不在TEXT段, 不调
    // 重算放后台 (地形生成调同款函数本就是后台线程干的活, 主线程几百块会卡几秒),
    // 建完回主线程重建网格; 回来时若已退世界则跳过 (防野指针)
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        MWB010RelightLoadedChunks();
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!MWBIsInWorld()) return;
            void (*allChanged)(void *) = (void (*)(void *))MSFindSymbol(NULL, "__ZN13LevelRenderer10allChangedEv");
            if (!allChanged) return;
            allChanged(gRenderer010);
            MWBLogFile(@"[010] 已刷新区块 (allChanged renderer=%p)", gRenderer010);
        });
    });
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
    // 自动重算已停用 (多次验证无效且卡顿, 切时间只改逻辑+天空, 和改前一致);
    // 重算/重建只走手动 refresh flag, 供诊断时用
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
