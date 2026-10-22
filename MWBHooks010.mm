/* MWBHooks010.mm — 0.10 hook (normalTick/levelTick/加速常量) */
#import "MWBCommon.h"
#import <mach/mach.h>
#import <math.h>
#import <string.h>
#import <mach-o/dyld.h>
#import <mach-o/loader.h>

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
    // 穿墙悬停: 免碰撞后重力会把人往下拉穿地心, 把下坠速度清零即悬空 (只清负值, 跳跃上升不受影响)
    if (gNoclip) {
        float *vy = (float *)((char *)self + ENTITY_VELOCITY_Y_OFFSET);
        if (*vy < 0.0f) *vy = 0.0f;
    }
    // 夜视: 0.10 无药水系统, 改游戏自家 gamma(Options+0x2D0)
    MWB010NightVisionTick();   // 开关内外都要调: 关时负责恢复原值(函数内部分支)
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

// 穿墙: Entity::move(x0=self,x1~3=dx/dy/dz) 头部 `ldrb w8,[x19,#0x12a];cbz` 即免碰撞分支
// (Java 系 noClip 同款; LocalPlayer::move 自己也在特定分支置 1 后调它).
// 0.10 能力表只有 4 项无 noclip 位, 故在 hook 内对本地玩家置位后调原函数, 零重实现、零副作用他人
typedef void (*Move010Fn)(void *self, float dx, float dy, float dz);
static Move010Fn orig_move010 = NULL;
static void hooked_move010(void *self, float dx, float dy, float dz) {
    if (gNoclip && self == gLocalPlayer) ((char *)self)[0x12A] = 1;
    orig_move010(self, dx, dy, dz);
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

// glinfo 探针要读的计数 (MWBActions.mm 的 flag 处理里调)
int MWB010GLCalls(void) { return gGLCalls; }
int MWB010GLPersp(void) { return gGLPersp; }
int MWB010GLBuried(void) { return gGLBuried; }
int MWB010GLPatched(void) { return gGLPatched; }
int MWB010GOTSlots(void) { return gGOTSlots; }

// 透视矩阵签名: 列主序 m[11]==-1, m[15]==0 (modelview 仿射矩阵 m[11]==0, 不会误伤)
static void patched_glUniformMatrix4fv(int loc, int count, unsigned char tr, const float *m) {
    gGLCalls++;
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
static void MWBRebindOne(const uint8_t *base, const uint8_t *end, uint64_t *segVA, uintptr_t slide) {
    const uint8_t *p = base;
    uint64_t segIdx = 0, segOff = 0; const char *sym = NULL; int type = 0;
    while (p < end) {
        uint8_t op = *p & 0xF0, imm = *p & 0x0F; p++;
        switch (op) {
            case BIND_OPCODE_DONE: return;
            case BIND_OPCODE_SET_DYLIB_ORDINAL_IMM: break;
            case BIND_OPCODE_SET_DYLIB_ORDINAL_ULEB: MWBReadUleb(&p, end); break;
            case BIND_OPCODE_SET_DYLIB_SPECIAL_IMM: break;
            case BIND_OPCODE_SET_SYMBOL_TRAILING_FLAGS_IMM: sym = (const char *)p; p += strlen(sym) + 1; break;
            case BIND_OPCODE_SET_TYPE_IMM: type = imm; break;
            case BIND_OPCODE_SET_ADDEND_SLEB: MWBReadUleb(&p, end); break;
            case BIND_OPCODE_SET_SEGMENT_AND_OFFSET_ULEB: segIdx = imm; segOff = MWBReadUleb(&p, end); break;
            case BIND_OPCODE_ADD_ADDR_ULEB: segOff += MWBReadUleb(&p, end); break;
            case BIND_OPCODE_DO_BIND:
                if (type == BIND_TYPE_POINTER && sym && !strcmp(sym, "_glUniformMatrix4fv")) {
                    void **slot = (void **)(segVA[segIdx] + slide + segOff);
                    vm_address_t page = ((vm_address_t)slot) & ~(vm_page_size - 1);
                    if (vm_protect(mach_task_self(), page, vm_page_size, 0, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) == KERN_SUCCESS) {
                        orig_glUniformMatrix4fv = (GLUniMat4Fn)*slot;
                        *slot = (void *)patched_glUniformMatrix4fv;
                        MWBLogFile(@"[010穿墙] GOT 改写 _glUniformMatrix4fv @ %p (原 %p)", slot, orig_glUniformMatrix4fv);
                    }
                }
                segOff += 8; break;
            case BIND_OPCODE_DO_BIND_ADD_ADDR_ULEB: segOff += 8; MWBReadUleb(&p, end); break;
            case BIND_OPCODE_DO_BIND_ADD_ADDR_IMM_SCALED: segOff += (uint64_t)imm * 8 + 8; break;
            case BIND_OPCODE_DO_BIND_ULEB_TIMES_SKIPPING_ULEB: {
                uint64_t n = MWBReadUleb(&p, end), skip = MWBReadUleb(&p, end);
                for (uint64_t i = 0; i < n; i++) {
                    if (type == BIND_TYPE_POINTER && sym && !strcmp(sym, "_glUniformMatrix4fv")) {
                        void **slot = (void **)(segVA[segIdx] + slide + segOff);
                        vm_address_t page = ((vm_address_t)slot) & ~(vm_page_size - 1);
                        if (vm_protect(mach_task_self(), page, vm_page_size, 0, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) == KERN_SUCCESS) {
                            orig_glUniformMatrix4fv = (GLUniMat4Fn)*slot;
                            *slot = (void *)patched_glUniformMatrix4fv;
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
    const char *exe = NULL;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
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
        MWBRebindOne(base, base + dyldinfo->bind_size, segVA, slide);
    }
    if (!orig_glUniformMatrix4fv && dyldinfo->lazy_bind_off) {
        const uint8_t *base = (const uint8_t *)(linkeditBase + slide + (dyldinfo->lazy_bind_off - linkeditFileOff));
        MWBRebindOne(base, base + dyldinfo->lazy_bind_size, segVA, slide);
    }
    NSLog(@"[魔玩盒子] 穿墙透视 hook: %s", orig_glUniformMatrix4fv ? "GOT 改写成功" : "未找到导入槽");
    MWBLogFile(@"[010穿墙] GOT 改写 %s", orig_glUniformMatrix4fv ? "成功" : "失败: 未找到槽位");
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
static const char *MWBStdStrC010(const void *s) {
    const unsigned char *b = (const unsigned char *)s;
    if (!s) return NULL;
    if ((b[0] & 1) == 0) return (const char *)(b + 1);   // SSO 短串(≤22 字节, 自带\0)
    return *(char *const *)s;
}
typedef void (*AddFloatFn010)(void *out, const void *key, float v);
static AddFloatFn010 orig_addFloat010 = NULL;
static void hooked_addFloat010(void *out, const void *key, float v) {
    if (gGV == (int)MWBGameV0_10 && v > 1.0f && key) {
        const char *ks = MWBStdStrC010(key);
        if (ks && !strcmp(ks, "gfx_gamma")) {
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
