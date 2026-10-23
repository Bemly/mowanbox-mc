/* MWBHooks010.mm — 0.10 hook (normalTick/levelTick/加速常量) */
#import "MWBCommon.h"
#import <mach/mach.h>
#import <math.h>
#import <string.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import "MWBGLBModel.h" // GLB 直画要投影/模型视图矩阵，这里只做最新一份拷贝

#pragma mark - C++ 游戏函数 hook

typedef void (*NormalTickFn)(void *self);
static NormalTickFn orig_normalTick = NULL;
static int gTickCount = 0;

// 杀戮光环: 每 tick 扫玩家周围 4 格内生物, 直调实体虚表 hurt (slot 50, 各实体自带实现)。
// 实体来源走 TileSource::getEntities(TileSource*, exclude, AABB*) @0x100103c1c (反应堆 tick 同款调用):
// AABB 是 7 个 float ([0] 不用, [1..6]=minX,minY,minZ,maxX,maxY,maxZ, 反编译比对实锤)。
// 只打生物允许表 (鸡10~哞菇16 / 僵尸32~蠹虫39): 掉落物/箭/矿车/船走自带 hurt 会坏档, 一律跳过;
// 自己必跳过 (LocalPlayer 也是 Mob, 不跳过等于自杀); 家狼也在表内, 会打死, 养狗的先关光环。
// 伤害固定 20 (僵尸/骷髅/爬行者/猪人一刀, 末影人两刀); 死怪/和平世界原函数内直接 return 0。
// 挥手: 命中时调 LocalPlayer::swing @0x100180478 (只调自己, 纯表现, 一 tick 只摆一次)。
// 计数探针: sAuraScans/targets/hurts 累计, flag aurainfo 落盘 (光环不转时看它定位)。
static int sAuraScans = 0, sAuraTargets = 0, sAuraHurts = 0;
int MWB010AuraScans(void) { return sAuraScans; }
int MWB010AuraTargets(void) { return sAuraTargets; }
int MWB010AuraHurts(void) { return sAuraHurts; }
static void MWB010KillAuraTick(void *player) {
    if (!gKillAura || !player) return;
    void *ts = *(void **)((char *)player + 0x48);
    if (!ts) return;
    float px = *(float *)((char *)player + 0x28);
    float py = *(float *)((char *)player + 0x28 + 4);
    float pz = *(float *)((char *)player + 0x28 + 8);
    float box[7] = {0, px - 4, py - 2, pz - 4, px + 4, py + 4, pz + 4};
    typedef void **(*GetEntFn)(void *, void *, float *);
    GetEntFn getEnts = (GetEntFn)(MWBMainSlide() + 0x100103c1cUL);
    if (!getEnts) return;
    void **ret = getEnts(ts, NULL, box);   // 回 {begin@0, end@8}, 复用 TileSource 内部暂存 vector
    if (!ret) return;
    void **begin = *(void ***)ret, **end = *(void ***)(ret + 1);
    if (!begin || end <= begin || (end - begin) > 256) return;
    sAuraScans++;
    // 先拷到栈上再打: hurt 会分裂史莱姆/掉东西改实体表, 边遍历边打会踩到新增节点
    void *targets[64];
    int n = 0;
    for (void **it = begin; it != end && n < 64; it++) {
        void *ent = *it;
        if (!ent || ent == player) continue;
        // 注意: getEntityTypeId 回的是运行时类型号, 不是 MobFactory 建怪号!
        // (kuna 反各 override 实锤: 僵尸0xb20/爬行者0xb21/骷髅0xb22/蜘蛛0xb23/猪人0xb24/
        // 史莱姆0xb25/末影人0xb26/蠹虫0xb27; 鸡0x170a/牛0x170b/猪0x170c/羊0x170d/
        // 哞菇0x1710/村民0x70f/狼0x570e; 玩家0x13f/掉落物0x40/箭0x50)
        // 之前按 10-16/32-39 过滤把什么都拦掉了 (targets 恒 0 的根因, aurainfo 实锤)
        int typeId = ((int (*)(void *))(*(void **)((char *)(*(void **)ent) + 0x200)))(ent);
        BOOL isMob = ((typeId >= 0xb20 && typeId <= 0xb27) ||
                      typeId == 0x170a || typeId == 0x170b || typeId == 0x170c ||
                      typeId == 0x170d || typeId == 0x1710 ||
                      typeId == 0x70f || typeId == 0x570e);
        if (!isMob) continue;
        targets[n++] = ent;
    }
    sAuraTargets += n;
    for (int i = 0; i < n; i++) {
        void *ent = targets[i];
        ((int (*)(void *, void *, int))(*(void **)((char *)(*(void **)ent) + 400)))(ent, player, 20);
        sAuraHurts++;
    }
    if (n > 0) {
        // 摆一次手臂意思下 (调多了动画状态机直接吞掉, 反正一 tick 只摆一次)
        void (*swing)(void *) = (void (*)(void *))(MWBMainSlide() + 0x100180478UL);
        if (swing) swing(player);
    }
}

static void hooked_normalTick(void *self) {
    orig_normalTick(self);
    MWBMarkWorldTick();
    gLocalPlayer = self;
    gTickCount++;
    char *abil = (char *)self + PLAYER_ABILITIES_OFFSET;
    // 开关边沿清零: tick 只置1不清0, 关了就会一直粘着 (无敌关不掉的根因);
    // 边沿检测放 tick 里, 菜单/flag/cycript 三入口自动生效
    static BOOL sWasInv = NO, sWasFly = NO, sWasBreak = NO, sWasClip = NO;
    if (gInvincible) { abil[ABIL_INVULNERABLE] = 1; sWasInv = YES; }
    else if (sWasInv) { abil[ABIL_INVULNERABLE] = 0; sWasInv = NO; }
    if (gFly) { abil[ABIL_FLYING] = 1; abil[ABIL_MAY_FLY] = 1; sWasFly = YES; }
    else if (sWasFly) { abil[ABIL_FLYING] = 0; abil[ABIL_MAY_FLY] = 0; sWasFly = NO; }
    if (gFastBreak) { abil[ABIL_INSTABUILD] = 1; sWasBreak = YES; }
    else if (sWasBreak) { abil[ABIL_INSTABUILD] = 0; sWasBreak = NO; }
    if (gNoclip) sWasClip = YES;
    else if (sWasClip) { ((char *)self)[0x12A] = 0; sWasClip = NO; }
    // 穿墙悬停: 免碰撞后重力会把人往下拉穿地心, 把下坠速度清零即悬空 (只清负值, 跳跃上升不受影响)
    // (触控板按住降时不清, 否则降键被悬停吃掉)
    if (gNoclip && !gFlyDown) {
        float *vy = (float *)((char *)self + ENTITY_VELOCITY_Y_OFFSET);
        if (*vy < 0.0f) *vy = 0.0f;
    }
    // (触控板输入位改走 TouchscreenInput::tick hook, 见 hooked_touchTick010;
    // 写在这里有帧序风险: 游戏触摸 tick 每帧先清零输入位, 写早了会被冲掉)
    if (gKillAura) MWB010KillAuraTick(self);   // 杀戮光环 (只打生物允许表, 详见函数注释)
    if ((gTickCount % 20) == 1) MWBPadSync();   // 触控板显隐同步 (切飞行/进出世界翻牌)
    // 夜视: 0.10 无药水系统, 改游戏自家 gamma(Options+0x2D0)
    MWB010NightVisionTick();   // 开关内外都要调: 关时负责恢复原值(函数内部分支)
    // (穿墙不再碰第三人称: 用户自己用游戏内按钮切换, 插件只做碰撞+近平面)
    if (gMinimap && (gTickCount % 40) == 1) {
        if (MWB010_SampleMinimap() >= 0) MWBMinimapRefresh();
    }
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
    MWBCamFaceTick();   // 跟脸正面：第 4 档时每 tick 把视角 yaw 灌进相机 yaw（+0x3c 卡死不动是正面定死的根因）
    MWBPollCmdFile();   // 0.10 也接 flag 文件通道 (time/reactor/diff/mob/explode)
}

typedef void (*LevelTickFn)(void *self);
static LevelTickFn orig_levelTick = NULL;
static void hooked_levelTick(void *self) {
    orig_levelTick(self);
    MWBMarkWorldTick();
    gLevel = self;
    // 白天/夜晚: 写 dayTime 的同时清掉天空覆写 (+0x15F0>=0 时渲染只认覆写, 逻辑只认 dayTime)
    // 点按语义是"跳过去就松手": 下一个 tick 写一次立刻清零, 时间从新时刻自然流
    // gTimeCustom010: 绝对时刻 (菜单四时段/flag tod-N), 优先于 gTimeMode
    if (gTimeCustom010 >= 0) {
        *(int64_t *)((char *)self + LEVEL_TIME_OFFSET) = gTimeCustom010;
        *(int64_t *)((char *)self + LEVEL_TIME_OVERRIDE_OFF) = -1;
        gTimeCustom010 = -1;
    } else if (gTimeMode == 1) {
        *(int64_t *)((char *)self + LEVEL_TIME_OFFSET) = TICK_TIME_DAY;
        *(int64_t *)((char *)self + LEVEL_TIME_OVERRIDE_OFF) = -1;
        gTimeMode = 0;
    } else if (gTimeMode == 2) {
        *(int64_t *)((char *)self + LEVEL_TIME_OFFSET) = TICK_TIME_NIGHT;
        *(int64_t *)((char *)self + LEVEL_TIME_OVERRIDE_OFF) = -1;
        gTimeMode = 0;
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

// 0.10 gMinecraft 捕获 (MinecraftClient::tick 首参即this; 旧 Minecraft::tickEii 主流程不跑, 只留 Client 版)
static void *gMinecraft010 = NULL;
void *MWB010Minecraft(void) { return gMinecraft010; }
int gMcTick010Count = 0;   // MinecraftClient::tick 调用计数 (client tick 存活探针用)
typedef void (*MinecraftTick010Fn)(void *self, int a, int b);
static MinecraftTick010Fn orig_mc010Tick = NULL;
static void hooked_mc010Tick(void *self, int a, int b) {
    orig_mc010Tick(self, a, b);
    gMinecraft010 = self;
    gMcTick010Count++;
    MWBPollCmdFile();   // 主菜单也接 flag (tap 进世界等), 世界 tick 里照常双调无害(共享 cooldown)
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
// (蹲/跳后端已删: 蹲是 0.10 没有的死功能; 跳用原生键, 游戏自己置输入[0x11])
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

// 穿墙: Entity::move(x0=self,x1~3=dx/dy/dz) 头部 `ldrb w8,[x19,#0x12a];cbz` 即免碰撞分支
// (Java 系 noClip 同款; LocalPlayer::move 自己也在特定分支置 1 后调它).
// 0.10 能力表只有 4 项无 noclip 位, 故在 hook 内对本地玩家置位后调原函数, 零重实现、零副作用他人
typedef void (*Move010Fn)(void *self, float dx, float dy, float dz);
static Move010Fn orig_move010 = NULL;
static void hooked_move010(void *self, float dx, float dy, float dz) {
    if (gNoclip && self == gLocalPlayer) ((char *)self)[0x12A] = 1;
    orig_move010(self, dx, dy, dz);
}

// 触控板 (1.2 式分离布局): 游戏触摸 tick 跑完后, 把自绘跳/升/降的按住状态 OR 进输入位
// ([0x11]=跳 [0x13]=上 [0x14]=下, LocalPlayer::aiStep 反编译实锤)。
// 必须 hook 在 tick 尾巴上: tick 头先清零输入位再按真实触摸重算, 写早了会被冲掉;
// 写在 orig 之后则 aiStep 消费时位都在 (原版跳跃键能跳 ⇒ aiStep 一定读得到)。
// 生存按住跳只蹦一下 (aiStep 离地闸)、飞行按住升/降按原版速率走、连击跳切飞行全是原版行为。
typedef void (*TouchTick010Fn)(void *self, void *player);
static TouchTick010Fn orig_touchTick010 = NULL;
static void hooked_touchTick010(void *self, void *player) {
    orig_touchTick010(self, player);
    if (!self) return;
    gTouchInput010 = self;   // 记下来给触控区搬迁用 (PadSync 主线程读)
    if (gPadJump) ((char *)self)[0x11] = 1;
    if (gFlyUp) ((char *)self)[0x13] = 1;
    if (gFlyDown) ((char *)self)[0x14] = 1;
}

#pragma mark - 穿墙旁观视角 (近平面外推, GL 层 fishhook 式改写)

// 眼睛是否埋进不透明方块 (空气/水/树叶/玻璃/雪层不算埋)
static BOOL MWB010EyeBlocked(void) {
    void *p = gLocalPlayer;
    if (!p) return NO;
    void *ts = *(void **)((char *)p + 0x48);
    if (!ts) return NO;
    float px = *(float *)((char *)p + 0x28);
    float py = *(float *)((char *)p + 0x28 + 4);
    float pz = *(float *)((char *)p + 0x28 + 8);
    MWBBlockPos bp = {(int)floorf(px), (int)floorf(py + 1.6f), (int)floorf(pz)};
    uint8_t id = MWB010GetTile(ts, &bp);
    return !(id == 0 || id == 8 || id == 9 || id == 18 || id == 20 || id == 78);
}

typedef void (*GLUniMat4Fn)(int, int, unsigned char, const float *);
static GLUniMat4Fn orig_glUniformMatrix4fv = NULL;
static int gGLCalls = 0, gGLPersp = 0, gGLBuried = 0, gGLPatched = 0;   // 诊断计数(只读, glinfo 打)
static int gGOTSlots = 0;   // 改写到的槽位数
static int gBindTotal = 0;    // 遍历到的 POINTER 绑定总数
static int gBindLogged = 0;   // 已打样的符号数(防刷屏)

// glinfo 探针要读的计数 (MWBActions.mm 的 flag 处理里调)
int MWB010GLCalls(void) { return gGLCalls; }
int MWB010GLPersp(void) { return gGLPersp; }
int MWB010GLBuried(void) { return gGLBuried; }
int MWB010GLPatched(void) { return gGLPatched; }
int MWB010GOTSlots(void) { return gGOTSlots; }

// 透视矩阵签名: 列主序 m[11]==-1, m[15]==0 (modelview 仿射矩阵 m[11]==0, 不会误伤)
static void patched_glUniformMatrix4fv(int loc, int count, unsigned char tr, const float *m) {
    gGLCalls++;
    if (count == 1 && !tr && m) MWBGLBCaptureMatrix(m); // GLB 直画：存最新投影/模型视图各一份
    // 4D皮肤优先: 窗口期内模型矩阵做列缩放 (与穿墙透视矩阵互斥, 各走各的分支)
    if (count == 1 && !tr && m) {
        float scaled[16];
        if (MWBMini4DScaleMatrix(m, scaled)) {
            orig_glUniformMatrix4fv(loc, count, tr, scaled);
            return;
        }
    }
    if (count == 1 && !tr && m &&
        m[3] == 0.0f && m[7] == 0.0f &&
        fabsf(m[11] + 1.0f) < 1e-6f && m[15] == 0.0f) {
        gGLPersp++;
        if (gNoclip && MWB010EyeBlocked()) {
            gGLBuried++;
            // 从矩阵反推参数重建 (fov/aspect/far 全保留, 只把 near 推到 2.5):
            // m[5]=1/tan, m[0]=1/(a*tan), m[14]=-2fn/(f-n), m[10]=-(f+n)/(f-n)
            float t = 1.0f / m[5];
            float aspect = m[5] / m[0];
            float f = m[14] / (m[10] + 1.0f);
            if (t > 0.0f && t < 10.0f && aspect > 0.1f && aspect < 10.0f && f > 10.0f && f < 100000.0f) {
                float r[16];
                memcpy(r, m, sizeof(r));
                float n = 2.5f;
                r[0] = 1.0f / (aspect * t);
                r[5] = 1.0f / t;
                r[10] = -(f + n) / (f - n);
                r[14] = -2.0f * f * n / (f - n);
                orig_glUniformMatrix4fv(loc, count, tr, r);
                gGLPatched++;
                return;
            }
        }
    }
    orig_glUniformMatrix4fv(loc, count, tr, m);
}

// fishhook 精简版: 只改写主二进制里 _glUniformMatrix4fv 一个导入槽位
// (Substrate 跳板要 16 字节, 12 字节的 dyld stub 不能 hook, 只能改 GOT)
static uint64_t MWBReadUleb(const uint8_t **pp, const uint8_t *end) {
    uint64_t v = 0; int sh = 0;
    while (*pp < end) { uint8_t b = **pp; (*pp)++; v |= (uint64_t)(b & 0x7F) << sh; if (!(b & 0x80)) break; sh += 7; }
    return v;
}
// lazy 段是"多条独立单入口流" (每条以自己的 DONE 结尾, dyld 按 stub 里存的偏移逐条解释),
// 不能像 regular 段那样见 DONE 就停, 否则只改第一条就返回 (slots=0 的根因, kuna 离线复核实锤)
static void MWBRebindOne(const uint8_t *base, const uint8_t *end, uint64_t *segVA, uintptr_t slide, BOOL isLazy) {
    const uint8_t *p = base;
    // lazy 绑定流里经常省略 SET_TYPE (类型沿用 POINTER), 默认 1 否则 lazy 段一个槽都命中不了
    uint64_t segIdx = 0, segOff = 0; const char *sym = NULL; int type = BIND_TYPE_POINTER;
    while (p < end) {
        uint8_t op = *p & 0xF0, imm = *p & 0x0F; p++;
        switch (op) {
            case BIND_OPCODE_DONE:
                if (!isLazy) return;
                segIdx = 0; segOff = 0; sym = NULL;   // 条目边界清零, 防脏状态误改错槽
                continue;
            case BIND_OPCODE_SET_DYLIB_ORDINAL_IMM: break;
            case BIND_OPCODE_SET_DYLIB_ORDINAL_ULEB: MWBReadUleb(&p, end); break;
            case BIND_OPCODE_SET_DYLIB_SPECIAL_IMM: break;
            case BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM: sym = (const char *)p; p += strlen(sym) + 1; break;
            case BIND_OPCODE_SET_TYPE_IMM: type = imm; break;
            case BIND_OPCODE_SET_ADDEND_SLEB: MWBReadUleb(&p, end); break;
            case BIND_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB: segIdx = imm; segOff = MWBReadUleb(&p, end); break;
            case BIND_OPCODE_ADD_ADDR_ULEB: segOff += MWBReadUleb(&p, end); break;
            case BIND_OPCODE_DO_BIND:
                if (type == BIND_TYPE_POINTER) {
                    gBindTotal++;
                    if (sym && gBindLogged < 30 && (strstr(sym, "_gl") == sym || strstr(sym, "GL"))) {
                        gBindLogged++;
                        MWBLogFile(@"[010noclip] bind sym=%s seg=%llu off=0x%llx", sym, (unsigned long long)segIdx, (unsigned long long)segOff);
                    }
                    if (sym && !strcmp(sym, "_glUniformMatrix4fv")) {
                        void **slot = (void **)(segVA[segIdx] + slide + segOff);
                        vm_address_t page = ((vm_address_t)slot) & ~(vm_page_size - 1);
                        if (vm_protect(mach_task_self(), page, vm_page_size, 0, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) == KERN_SUCCESS) {
                            orig_glUniformMatrix4fv = (GLUniMat4Fn)*slot;
                            *slot = (void *)patched_glUniformMatrix4fv;
                            gGOTSlots++;
                            MWBLogFile(@"[010noclip] GOT slot=%p orig=%p", slot, orig_glUniformMatrix4fv);
                        }
                    }
                }
                segOff += 8; break;
            case BIND_OPCODE_DO_BIND_ADD_ADDR_ULEB: {
                if (type == BIND_TYPE_POINTER && sym && !strcmp(sym, "_glUniformMatrix4fv")) {
                    void **slot = (void **)(segVA[segIdx] + slide + segOff);
                    vm_address_t page = ((vm_address_t)slot) & ~(vm_page_size - 1);
                    if (vm_protect(mach_task_self(), page, vm_page_size, 0, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) == KERN_SUCCESS) {
                        orig_glUniformMatrix4fv = (GLUniMat4Fn)*slot;
                        *slot = (void *)patched_glUniformMatrix4fv;
                        gGOTSlots++;
                    }
                }
                segOff += 8; MWBReadUleb(&p, end); break;
            }
            case BIND_OPCODE_DO_BIND_ADD_ADDR_IMM_SCALED: {
                if (type == BIND_TYPE_POINTER && sym && !strcmp(sym, "_glUniformMatrix4fv")) {
                    void **slot = (void **)(segVA[segIdx] + slide + segOff);
                    vm_address_t page = ((vm_address_t)slot) & ~(vm_page_size - 1);
                    if (vm_protect(mach_task_self(), page, vm_page_size, 0, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) == KERN_SUCCESS) {
                        orig_glUniformMatrix4fv = (GLUniMat4Fn)*slot;
                        *slot = (void *)patched_glUniformMatrix4fv;
                        gGOTSlots++;
                    }
                }
                segOff += (uint64_t)imm * 8 + 8; break;
            }
            case BIND_OPCODE_DO_BIND_ULEB_TIMES_SKIPPING_ULEB: {
                uint64_t n = MWBReadUleb(&p, end), skip = MWBReadUleb(&p, end);
                for (uint64_t i = 0; i < n; i++) {
                    if (type == BIND_TYPE_POINTER && sym && !strcmp(sym, "_glUniformMatrix4fv")) {
                        void **slot = (void **)(segVA[segIdx] + slide + segOff);
                        vm_address_t page = ((vm_address_t)slot) & ~(vm_page_size - 1);
                        if (vm_protect(mach_task_self(), page, vm_page_size, 0, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) == KERN_SUCCESS) {
                            orig_glUniformMatrix4fv = (GLUniMat4Fn)*slot;
                            *slot = (void *)patched_glUniformMatrix4fv;
                            gGOTSlots++;
                        }
                    }
                    segOff += skip + 8;
                }
                break;
            }
            default: return;
        }
    }
}
static void MWBRebindGLUniform(void) {
    if (orig_glUniformMatrix4fv) return;
    static int sLogged = 0;
    const char *exe = NULL;
    uint32_t nimgs = _dyld_image_count();
    for (uint32_t i = 0; i < nimgs; i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, "minecraftpe.app/minecraftpe")) { exe = name; break; }
    }
    if (!exe) return;
    uintptr_t slide = MWBMainSlide();
    struct mach_header_64 *mh = (struct mach_header_64 *)(slide + 0x100000000UL);
    if (mh->magic != MH_MAGIC_64) return;
    uint64_t segVA[8] = {0};
    struct dyld_info_command *dyldinfo = NULL;
    uint64_t linkeditBase = 0, linkeditFileOff = 0;
    struct load_command *lc = (struct load_command *)(mh + 1);
    for (uint32_t i = 0, idx = 0; i < mh->ncmds; i++) {
        if (lc->cmd == LC_SEGMENT_64) {
            struct segment_command_64 *sg = (struct segment_command_64 *)lc;
            if (idx < 8) segVA[idx++] = sg->vmaddr;
            if (!strncmp(sg->segname, "__LINKEDIT", 16)) { linkeditBase = sg->vmaddr; linkeditFileOff = sg->fileoff; }
        } else if (lc->cmd == LC_DYLD_INFO_ONLY) {
            dyldinfo = (struct dyld_info_command *)lc;
        }
        lc = (struct load_command *)((char *)lc + lc->cmdsize);
    }
    if (!dyldinfo || !linkeditBase) return;
    if (dyldinfo->bind_off) {
        const uint8_t *base = (const uint8_t *)(linkeditBase + slide + (dyldinfo->bind_off - linkeditFileOff));
        MWBRebindOne(base, base + dyldinfo->bind_size, segVA, slide, NO);
    }
    if (!orig_glUniformMatrix4fv && dyldinfo->lazy_bind_off) {
        const uint8_t *base = (const uint8_t *)(linkeditBase + slide + (dyldinfo->lazy_bind_off - linkeditFileOff));
        MWBRebindOne(base, base + dyldinfo->lazy_bind_size, segVA, slide, YES);
    }
    if (!sLogged) {
        sLogged = 1;
        MWBLogFile(@"[010noclip] walk nimgs=%u ncmds=%u bind=%u lazy=%u binds=%d slots=%d orig=%p",
                   (unsigned)nimgs, (unsigned)mh->ncmds,
                   (unsigned)(dyldinfo ? dyldinfo->bind_size : 0),
                   (unsigned)(dyldinfo ? dyldinfo->lazy_bind_size : 0),
                   gBindTotal, gGOTSlots, orig_glUniformMatrix4fv);
    }
    MWBLogFile(@"[010noclip] GOT slots=%d orig=%p", gGOTSlots, orig_glUniformMatrix4fv);
}

// 汉化: fillTranslations(AppPlatform, lang, bool) 跑完后把中文表/英文原表复写进 I18n 静态 map
// (MinecraftClient::init 内调两次, 启动期生效; 游戏内无语言切换UI, 开关走菜单/flag)
typedef void (*I18nFillFn)(void *app, const void *lang, BOOL b);
static I18nFillFn orig_fill010 = NULL;
static void hooked_fill010(void *app, const void *lang, BOOL b) {
    orig_fill010(app, lang, b);
    MWBApplyLang();
}

// 夜视防毒: 存档只活在内存, 不许落盘 (Options::save 经 float 重载写 gfx_gamma;
// 设置滑杆最高 1.0, 存档值 >1.0 只可能是我们的 5.0, 换回原值/0 再写; 480 字节函数跳板安全)
// 本游戏 libc++ 短串布局 (bool 重载反编译实锤: ((unsigned char*)a1)[0x17] 判长短):
// 数据在对象开头, 尺寸在 0x17 字节; 0x17 高位清零=短串, 置位=长串 (数据指针在首 8 字节)。
// 之前按首字节奇偶判长短是错的: 短串首字节就是字符 ('g'=0x67 为奇) 会走长串分支,
// 把 "gfx_..." 当指针解引用 —— 切任何设置触发存档即崩的根因 (崩溃日志铁证)。
// 比对带长度, 不依赖短串自带 \0。
static const char *MWBStdStrData010(const void *s, size_t *outLen) {
    if (!s) return NULL;
    const unsigned char *b = (const unsigned char *)s;
    if ((b[0x17] & 0x80) == 0) {
        if (outLen) *outLen = b[0x17];
        return (const char *)b;
    }
    if (outLen) *outLen = *(const size_t *)(b + 8);
    return *(char *const *)b;
}
typedef void (*AddFloatFn010)(void *out, const void *key, float v);
static AddFloatFn010 orig_addFloat010 = NULL;
static void hooked_addFloat010(void *out, const void *key, float v) {
    if (gGV == (int)MWBGameV0_10 && v > 1.0f && key) {
        size_t n = 0;
        const char *ks = MWBStdStrData010(key, &n);
        if (ks && n == 9 && !memcmp(ks, "gfx_gamma", 9)) {
            float w = MWB010GammaSaveValue();
            MWBLogFile(@"[010夜视] 存档拦截 gamma %.1f→%.2f", v, w);
            v = w;
        }
    }
    orig_addFloat010(out, key, v);
}

// 0.10 hook 安装 (%ctor 调用)
void MWBInstallHooks010(void) {
    MWB_HOOK("__ZN11LocalPlayer10normalTickEv", hooked_normalTick, orig_normalTick);
    MWB_HOOK("__ZN5Level4tickEv", hooked_levelTick, orig_levelTick);
    MWB_HOOK("__ZN15MinecraftClient4tickEii", hooked_mc010Tick, orig_mc010Tick);
    MWB_HOOK("__ZN4I18n16fillTranslationsEP11AppPlatformRKNSt3__112basic_stringIcNS2_11char_traitsIcEENS2_9allocatorIcEEEEb",
             hooked_fill010, orig_fill010);
    MWB_HOOK("__ZN7Options21addOptionToSaveOutputERNSt3__16vectorINS0_12basic_stringIcNS0_11char_traitsIcEENS0_9allocatorIcEEEENS5_IS7_EEEES7_f",
             hooked_addFloat010, orig_addFloat010);
    MWB_HOOK("__ZN16TouchscreenInput4tickEP6Player", hooked_touchTick010, orig_touchTick010);
    // Entity::move 0x1000 字节大函数, 跳板安全; 只拦截本地玩家的碰撞
    void *mv = MSFindSymbol(NULL, "__ZN6Entity4moveEfff");
    if (mv) { MSHookFunction(mv, (void *)hooked_move010, (void **)&orig_move010);
        NSLog(@"[魔玩盒子] 已 hook: Entity::move -> %p", mv);
        MWBLogFile(@"[Toolbox] hook 成功: Entity::move @ %p", mv); }
    else { NSLog(@"[魔玩盒子] 警告: 未找到 Entity::move");
        MWBLogFile(@"[Toolbox] hook 失败: 未找到 Entity::move"); }
    // 穿墙旁观视角: GOT 改写 glUniformMatrix4fv, 眼睛埋住时把透视近平面推到 2.5
    MWBRebindGLUniform();
}
