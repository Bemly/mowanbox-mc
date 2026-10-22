/* MWBHooks1133.mm — 1.13.3 hook + 大件 */
#import "MWBCommon.h"

#pragma mark - 1.13.3 版本适配 (静态VA+slide,无需符号)
// 逆向结论: Player::normalTick @0x101D5CAC8 (2636B,可hook)
// Level::tick @0x101FAAC70, 背包 Player+4416,
// abilities Player+2376 (12B步长x18条目,使能位+8,值+12),
// dayTime Level+0x510 (int32), gameTime Level+0x4E8
#define V1133_PLAYERNORMALTICK_VA 0x101D5CAC8UL
#define V1133_LEVELTICK_VA        0x101FAAC70UL
#define V1133_PLAYER_ABILITIES_OFF 2376
#define V1133_PLAYER_INV_OFF       4416
#define V1133_LEVEL_DAYTIME_OFF    0x510
#define V1133_LEVEL_SHARED_OFF     0x1e8
#define V1133_UNWRAP_VA            0x1024ECE84UL
#define V1133_SETRAIN_VA           0x1024EC9E0UL
#define V1133_SETRAINTIME_VA       0x1024EC9F0UL
#define V1133_SETLIGHT_VA          0x1024EC9B0UL
#define V1133_SETLIGHTTIME_VA      0x1024EC9C0UL
#define V1133_MOBEFFECT_GET_VA     0x101E40170UL
#define V1133_WEATHERWRAP_VA       0x101FB32F4UL

static int gTick1133 = 0;
typedef void (*V1133TickFn)(void *self);
static V1133TickFn orig_1133_playerTick = NULL;
static V1133TickFn orig_1133_levelTick = NULL;

// 能力表探测: 18条目x12B,附名字表(静态0x10340F230)和12字节hex,用于定位无敌下标
#define V1133_ABIL_NAMES_VA 0x10340F230UL
static void MWB1133LogAbilities(void *player, NSFileHandle *fh) {
    char *base = (char *)player + V1133_PLAYER_ABILITIES_OFF;
    char **names = (char **)(MWBMainSlide() + V1133_ABIL_NAMES_VA);
    NSMutableString *m = [NSMutableString stringWithFormat:@"[1133能力表] player=%p\n", player];
    for (int i = 0; i < 18; i++) {
        char *e = base + i * 12;
        const char *nm = "??";
        @try {
            char *np = names[i];
            if (np && (uintptr_t)np > 0x100000000UL) nm = np;
        } @catch (NSException *ex) { nm = "bad"; }
        [m appendFormat:@" [%d]%-12s", i, nm];
        for (int b = 0; b < 12; b++) [m appendFormat:@" %02x", (unsigned char)e[b]];
        [m appendString:@"\n"];
    }
    [fh writeData:[m dataUsingEncoding:NSUTF8StringEncoding]];
}

static void hooked_1133_playerTick(void *self) {
    orig_1133_playerTick(self);
    MWBMarkWorldTick();
    gPlayer1133 = self;
    gTick1133++;
    // 无敌: entry[8]invulnerable 值=Player+2480 (Base2376+12+8*12, 逆向分队实锤)
    // 旧双写 base[8*12]/[9*12] 实为 teleport/invulnerable, 现改为单写去副作用
    char *ab = (char *)self + V1133_PLAYER_ABILITIES_OFF + 12;
    // 开关边沿清零: 能力表写 1 后一直粘着, 关了必须写回 0 (同 0.10 根因)
    static BOOL sWasInv = NO, sWasFly = NO, sWasBreak = NO, sWasClip = NO;
    if (gInvincible) { ab[8 * 12] = 1; sWasInv = YES; }
    else if (sWasInv) { ab[8 * 12] = 0; sWasInv = NO; }
    if (gFly) { ab[9 * 12] = 1; ab[10 * 12] = 1; sWasFly = YES; }
    else if (sWasFly) { ab[9 * 12] = 0; ab[10 * 12] = 0; sWasFly = NO; }
    if (gFastBreak) { ab[11 * 12] = 1; sWasBreak = YES; }
    else if (sWasBreak) { ab[11 * 12] = 0; sWasBreak = NO; }
    if (gSpeed) {
        *(float *)(ab + 14 * 12) = 1.0f;                // walkSpeed
        *(float *)(ab + 13 * 12) = 1.0f;                // flySpeed
    }
    if (gNoclip) { ab[17 * 12] = 1; sWasClip = YES; }
    else if (sWasClip) { ab[17 * 12] = 0; sWasClip = NO; }
    if (gKillAura) MWB1133_KillAuraTick();
    if (gMinimap && (gTick1133 % 40) == 1) {
        if (MWB1133_SampleMinimap() >= 0) MWBMinimapRefresh();
    }
    MWBPollCmdFile();
    // 夜视药水探测: getById(速度1/跳跃8/夜视16) 回读指针, 非空即药水系统可达
    if (gNightVision && gMWBDebug && (gTick1133 % 200) == 1) {
        void *(*getById)(int) = (void *(*)(int))(MWBMainSlide() + V1133_MOBEFFECT_GET_VA);
        void *e1 = getById(1), *e8 = getById(8), *e16 = getById(16);
        NSURL *logURL = [NSURL fileURLWithPath:@"/var/mobile/Documents/mowanbox.log"];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingToURL:logURL error:nil];
        if (fh) {
            [fh seekToEndOfFile];
            NSString *line = [NSString stringWithFormat:@"%@ [1133药水] speed=%p jump=%p nightvision=%p\n",
                              [NSDate date], e1, e8, e16];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    }
    if (gMWBDebug && (gTick1133 % 200) == 1) {
        NSURL *logURL = [NSURL fileURLWithPath:@"/var/mobile/Documents/mowanbox.log"];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingToURL:logURL error:nil];
        if (fh) {
            [fh seekToEndOfFile];
            NSString *line = [NSString stringWithFormat:@"%@ [1133] tick #%d player=%p\n",
                              [NSDate date], gTick1133, self];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            MWB1133LogAbilities(self, fh);
            [fh closeFile];
        }
    }
}

static void hooked_1133_levelTick(void *self) {
    orig_1133_levelTick(self);
    MWBMarkWorldTick();
    gLevel1133 = self;
    if (gTimeMode == 1) *(int32_t *)((char *)self + V1133_LEVEL_DAYTIME_OFF) = TICK_TIME_DAY;
    else if (gTimeMode == 2) *(int32_t *)((char *)self + V1133_LEVEL_DAYTIME_OFF) = TICK_TIME_NIGHT;
    // 天气: 调 Level wrapper (自带变更检测+同步广播, 比裸写setter靠谱)
    // void wrapper(Level*, float rain, int rainTime, float lightning, int lightningTime)
    if (gWeatherMode >= 1 && gWeatherMode <= 3) {
        void (*wfn)(void *, float, int, float, int) =
            (void (*)(void *, float, int, float, int))(MWBMainSlide() + V1133_WEATHERWRAP_VA);
        if (gWeatherMode == 1) wfn(self, 0.0f, 0, 0.0f, 0);
        else if (gWeatherMode == 2) wfn(self, 1.0f, 12000, 0.0f, 0);
        else wfn(self, 1.0f, 12000, 1.0f, 12000);
    }
    static int s_lvTick = 0;
    if (gMWBDebug && ((++s_lvTick % 200) == 1)) {
        NSURL *logURL = [NSURL fileURLWithPath:@"/var/mobile/Documents/mowanbox.log"];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingToURL:logURL error:nil];
        if (fh) {
            [fh seekToEndOfFile];
            void *(*uw)(void *) = (void *(*)(void *))(MWBMainSlide() + V1133_UNWRAP_VA);
            void *dbgLd = uw((char *)self + V1133_LEVEL_SHARED_OFF);
            float rain = dbgLd ? *(float *)((char *)dbgLd + 0x354) : -9.0f;
            NSString *line = [NSString stringWithFormat:
                @"%@ [1133关卡] tick #%d level=%p dayTime=%d gTimeMode=%d ld=%p rain=%.2f wmode=%d\n",
                [NSDate date], s_lvTick, self,
                *(int32_t *)((char *)self + V1133_LEVEL_DAYTIME_OFF), gTimeMode,
                dbgLd, rain, gWeatherMode];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    }
}

#pragma mark - 1.13.3 大件 (药水应用/传送/治疗/遍历/WorldEdit/KillAura/小地图)
// 收尾逆向结论, 静态VA+slide
#define V1133_EFFECT_CTOR_VA   0x101E401CCUL
#define V1133_ADDEFFECT_SLOT   0x5F8
#define V1133_TELEPORT_SLOT    0x88
#define V1133_GETPOS_SLOT      0x60
#define V1133_GETATTR_VA       0x101119404UL
#define V1133_LEVEL_ACTORS_OFF 0x58
#define V1133_GETBLOCK_VA      0x101F87334UL
#define V1133_SETBLOCK_VA      0x101F88950UL
#define V1133_BLOCKBASE_VA     0x1034C8870UL
#define V1133_STONESLOT_OFF    0x38  // 重推导结论: base+8是map, 真石头在base+0x38
#define V1133_ACTOR_BS_OFF     0x338
#define V1133_KILLAURA_RANGE   4.0f
#define V1133_VT_MELEE_SLOT    0x9e8

// 药水应用 (实例0xE8: id@8/amp@C/dur@38, +0x78恒1)
bool MWB1133_ApplyEffect(void *actor, int fxId, int amplifier, int durTicks) {
    if (!actor) return false;
    uintptr_t s = MWBMainSlide();
    void *(*getById)(int) = (void *(*)(int))(s + V1133_MOBEFFECT_GET_VA);
    void *fx = getById(fxId);
    if (!fx) return false;
    char e1[24] = {0}, e2[24] = {0}, e3[24] = {0};
    void *buf = malloc(0xE8);
    if (!buf) return false;
    memset(buf, 0, 0xE8);
    ((void (*)(void *, int, void *, void *, int, int, int, void *))(s + V1133_EFFECT_CTOR_VA))(
        buf, fxId, e1, e2, amplifier, 0, durTicks, e3);
    *(uint8_t *)((char *)buf + 0x78) = 1;
    NSURL *lurl = [NSURL fileURLWithPath:@"/var/mobile/Documents/mowanbox.log"];
    NSFileHandle *lfh = [NSFileHandle fileHandleForWritingToURL:lurl error:nil];
    if (lfh) {
        [lfh seekToEndOfFile];
        NSMutableString *m = [NSMutableString stringWithFormat:@"%@ [1133实例] id=%d fx=%p inst:",
                             [NSDate date], fxId, fx];
        for (int i = 0; i < 0x40; i += 8)
            [m appendFormat:@" +%x=%02x%02x%02x%02x%02x%02x%02x%02x", i,
             ((uint8_t *)fx)[i], ((uint8_t *)fx)[i+1], ((uint8_t *)fx)[i+2], ((uint8_t *)fx)[i+3],
             ((uint8_t *)fx)[i+4], ((uint8_t *)fx)[i+5], ((uint8_t *)fx)[i+6], ((uint8_t *)fx)[i+7]];
        [m appendString:@" buf:"];
        for (int i = 0; i < 0xE8; i += 8)
            [m appendFormat:@" +%x=%02x%02x%02x%02x%02x%02x%02x%02x", i,
             ((uint8_t *)buf)[i], ((uint8_t *)buf)[i+1], ((uint8_t *)buf)[i+2], ((uint8_t *)buf)[i+3],
             ((uint8_t *)buf)[i+4], ((uint8_t *)buf)[i+5], ((uint8_t *)buf)[i+6], ((uint8_t *)buf)[i+7]];
        [m appendString:@"\n"];
        [lfh writeData:[m dataUsingEncoding:NSUTF8StringEncoding]];
        [lfh closeFile];
    }
    void *vt = *(void **)actor;
    bool r = ((bool (*)(void *, void *))(*(void **)((char *)vt + V1133_ADDEFFECT_SLOT)))(actor, buf);
    return r;
}
// 传送: getPos槽读当前(+10Y)→teleportTo槽 (不碰raw偏移, 避三pos之争)
bool MWB1133_TeleportUp10(void *actor) {
    NSURL *lurl = [NSURL fileURLWithPath:@"/var/mobile/Documents/mowanbox.log"];
    NSFileHandle *lfh = [NSFileHandle fileHandleForWritingToURL:lurl error:nil];
    if (!actor) return false;
    void *vt = *(void **)actor;
    void *(*getPos)(void *) = (void *(*)(void *))(*(void **)((char *)vt + V1133_GETPOS_SLOT));
    float *p = (float *)getPos(actor);
    if (!p) {
        if (lfh) { [lfh seekToEndOfFile];
            [lfh writeData:[@"[1133传送] getPos空\n" dataUsingEncoding:NSUTF8StringEncoding]]; [lfh closeFile]; }
        return false;
    }
    float v[3] = {p[0], p[1] + 10.0f, p[2]};
    ((void (*)(void *, void *))(*(void **)((char *)vt + V1133_TELEPORT_SLOT)))(actor, v);
    if (lfh) {
        [lfh seekToEndOfFile];
        NSString *line = [NSString stringWithFormat:@"%@ [1133传送] 从(%.1f,%.1f,%.1f)+10Y\n",
                          [NSDate date], p[0], p[1], p[2]];
        [lfh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [lfh closeFile];
    }
    return true;
}
// 属性实例 (治疗/饱食/XP: 先取实例, CURR/MAX槽运行时定界)
void *MWB1133_GetAttr(void *actor, const char *name) {
    if (!actor || !name) return NULL;
    char sstr[24] = {0};
    size_t n = strlen(name);
    if (n >= 24) return NULL;
    memcpy(sstr, name, n);
    return ((void *(*)(void *, void *))(MWBMainSlide() + V1133_GETATTR_VA))(actor, sstr);
}
// 实体遍历 (Level+0x58 vector<Actor*>, 越界保护)
void MWB1133_ForEachActor(void *level, void (^blk)(void *actor)) {
    if (!level || !blk) return;
    void **begin = *(void ***)((char *)level + V1133_LEVEL_ACTORS_OFF);
    void **end = *(void ***)((char *)level + V1133_LEVEL_ACTORS_OFF + 8);
    if (!begin || !end || end < begin || (end - begin) > 10000) return;
    for (void **it = begin; it < end; it++) if (*it) blk(*it);
}
// WorldEdit: 方块读写原语
void *MWB1133BlockSource(void) {
    if (!gPlayer1133) return NULL;
    return *(void **)((char *)gPlayer1133 + V1133_ACTOR_BS_OFF);
}
void *MWB1133BlockById(int blockId) {
    if (blockId == 1) {
        // 石头走修正槽 base+0x38, 并验虚表落在TEXT段才回 (防map指针再崩)
        void *s = *(void **)(MWBMainSlide() + V1133_BLOCKBASE_VA + V1133_STONESLOT_OFF);
        if (s) {
            void *vt = *(void **)s;
            uintptr_t lo = MWBMainSlide() + 0x100000000UL, hi = lo + 0x4000000UL;
            if ((uintptr_t)vt >= lo && (uintptr_t)vt < hi) return s;
        }
        return NULL;
    }
    if (blockId < 0 || blockId > 255) return NULL;
    return ((void **)(MWBMainSlide() + V1133_BLOCKBASE_VA))[blockId];
}
int MWB1133_BlockIdOf(void *blk) {
    if (!blk) return 0;
    // base[i]轮询已证伪(base+8是map), 只认air槽与石头槽
    if (blk == MWB1133BlockById(0)) return 0;
    void *stone = MWB1133BlockById(1);
    if (stone && blk == stone) return 1;
    return -1;
}
void *MWB1133GetOne(void *bs, int x, int y, int z) {
    if (!bs) return NULL;
    MWBBlockPos p = {x, y, z};
    return ((void *(*)(void *, void *))(MWBMainSlide() + V1133_GETBLOCK_VA))(bs, &p);
}
int MWB1133SetOne(void *bs, int x, int y, int z, void *blk) {
    if (!bs || !blk || y < 0 || y > 255) return 0;
    MWBBlockPos p = {x, y, z};
    char dummy[16] = {0};
    return ((int (*)(void *, void *, void *, int, void *, int))(MWBMainSlide() + V1133_SETBLOCK_VA))(
        bs, &p, blk, 3, dummy, 0);
}
// fillCube: 以玩家脚下为中心边长n的石头立方 (分帧由调用方按tick切, 单次默认5³)
int MWB1133_FillStone(int half) {
    void *bs = MWB1133BlockSource();
    void *blk = MWB1133BlockById(1);
    NSURL *lurl = [NSURL fileURLWithPath:@"/var/mobile/Documents/mowanbox.log"];
    NSFileHandle *lfh = [NSFileHandle fileHandleForWritingToURL:lurl error:nil];
    uintptr_t slide = MWBMainSlide();
    uintptr_t lo = slide + 0x100000000UL, hi = lo + 0x4000000UL;
    BOOL bsOk = bs && (uintptr_t)bs > 0x100000000UL && *(void **)bs &&
                (uintptr_t)(*(void **)bs) >= lo && (uintptr_t)(*(void **)bs) < hi;
    if (!bs || !blk || !gPlayer1133) {
        if (lfh) { [lfh seekToEndOfFile];
            NSString *line = [NSString stringWithFormat:@"%@ [1133铺石] 缺件 bs=%p blk=%p player=%p\n",
                              [NSDate date], bs, blk, gPlayer1133];
            [lfh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [lfh closeFile]; }
        return -1;
    }
    if (!bsOk) {
        if (lfh) { [lfh seekToEndOfFile];
            NSString *line = [NSString stringWithFormat:@"%@ [1133铺石] bs虚表无效, 停写 bs=%p\n",
                              [NSDate date], bs];
            [lfh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [lfh closeFile]; }
        return -3;
    }
    float px = *(float *)((char *)gPlayer1133 + 0x41C);
    float py = *(float *)((char *)gPlayer1133 + 0x41C + 4);
    float pz = *(float *)((char *)gPlayer1133 + 0x41C + 8);
    int cx = (int)floorf(px), cy = (int)floorf(py), cz = (int)floorf(pz);
    // 先验: 读脚下方块+注册表比对, 不对就停 (避免125连写崩)
    int footId = MWB1133_BlockIdOf(MWB1133GetOne(bs, cx, cy - 1, cz));
    if (lfh) { [lfh seekToEndOfFile];
        NSString *line = [NSString stringWithFormat:
                          @"%@ [1133铺石] 玩家(%d,%d,%d) 脚下id=%d bs高度=%d\n",
                          [NSDate date], cx, cy, cz, footId, *(int16_t *)((char *)bs + 0x30)];
        [lfh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [lfh closeFile]; }
    if (footId < 0) return -2;  // 读链不通, 不写
    int n = 0;
    for (int y = cy - half; y <= cy + half; y++)
        for (int z = cz - half; z <= cz + half; z++)
            for (int x = cx - half; x <= cx + half; x++)
                n += MWB1133SetOne(bs, x, y, z, blk);
    if (lfh) { [lfh seekToEndOfFile];
        NSString *line = [NSString stringWithFormat:@"%@ [1133铺石] 写入%d块\n", [NSDate date], n];
        [lfh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [lfh closeFile]; }
    return n;
}
// KillAura: 最近敌对虚表攻击 (虚表需运行时填表, 空表时只记日志)
static void *gHostileVTs1133[16];
static int gHostileVTCount1133 = 0;
void MWB1133_KillAuraTick(void) {
    if (!gLevel1133 || !gPlayer1133) return;
    // 填表前探测: 每200tick记一次周围实体数与虚表 (填表后自动转攻击)
    if (gHostileVTCount1133 == 0) {
        if (gMWBDebug && (gTick1133 % 200) == 1) {
            __block int n = 0;
            __block int nv = 0;
            MWB1133_ForEachActor(gLevel1133, ^(void *a) {
                if (a == gPlayer1133) return;
                n++;
                if (n > 1000 || nv >= 16) return;
                void *vt = *(void **)a;
                for (int i = 0; i < nv; i++) if (gHostileVTs1133[i] == vt) return;
                gHostileVTs1133[nv++] = vt;  // 借表暂存 (count仍0, 不转攻击)
            });
            NSURL *logURL = [NSURL fileURLWithPath:@"/var/mobile/Documents/mowanbox.log"];
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingToURL:logURL error:nil];
            if (fh) {
                [fh seekToEndOfFile];
                NSMutableString *m = [NSMutableString stringWithFormat:@"%@ [1133光环探测] 实体=%d 虚表%d种:",
                                      [NSDate date], n, nv];
                for (int i = 0; i < nv; i++) [m appendFormat:@" %p", gHostileVTs1133[i]];
                [m appendString:@"\n"];
                [fh writeData:[m dataUsingEncoding:NSUTF8StringEncoding]];
                [fh closeFile];
            }
        }
        return;
    }
    __block void *best = NULL;
    __block float bestD2 = V1133_KILLAURA_RANGE * V1133_KILLAURA_RANGE;
    float *pp = (float *)((char *)gPlayer1133 + 0x41C);
    MWB1133_ForEachActor(gLevel1133, ^(void *a) {
        if (a == gPlayer1133) return;
        if (gHostileVTCount1133 == 0) return;  // 未填表只探测 (探测在debug日志)
        void *vt = *(void **)a;
        BOOL hostile = NO;
        for (int i = 0; i < gHostileVTCount1133; i++)
            if (gHostileVTs1133[i] == vt) { hostile = YES; break; }
        if (!hostile) return;
        if (*(uint8_t *)((char *)a + 0x351)) return;  // 已死跳过
        float *mp = (float *)((char *)a + 0x41C);
        float dx = mp[0] - pp[0], dy = mp[1] - pp[1], dz = mp[2] - pp[2];
        float d2 = dx * dx + dy * dy + dz * dz;
        if (d2 < bestD2) { bestD2 = d2; best = a; }
    });
    if (best) {
        void **pvt = *(void ***)gPlayer1133;
        ((void (*)(void *, void *))pvt[V1133_VT_MELEE_SLOT / 8])(gPlayer1133, best);
    }
}
// 小地图后端: 48x48单层采样 (玩家Y-2层, 矿石标红由UI侧按id着色)
int MWB1133_SampleMinimap(void) {
    void *bs = MWB1133BlockSource();
    if (!bs || !gPlayer1133) return -1;
    float px = *(float *)((char *)gPlayer1133 + 0x41C);
    float py = *(float *)((char *)gPlayer1133 + 0x41C + 4);
    float pz = *(float *)((char *)gPlayer1133 + 0x41C + 8);
    int cx = (int)floorf(px), cy = (int)floorf(py) - 2, cz = (int)floorf(pz);
    int air = 0;
    for (int dz = -24; dz < 24; dz++)
        for (int dx = -24; dx < 24; dx++) {
            int id = MWB1133_BlockIdOf(MWB1133GetOne(bs, cx + dx, cy, cz + dz));
            if (id <= 0) { air++; id = 0; }
            gMiniMap1133[(dz + 24) * 48 + (dx + 24)] = (uint8_t)(id & 0xFF);
        }
    return air;  // air数过大说明pos错层, 运行时判据
}

// 1.13.3 hook 安装: 无符号,按静态VA+slide直接hook (函数2636B/2396B,跳板安全)
void MWBInstallHooks1133(void) {
    uintptr_t slide = MWBMainSlide();
    void *pTick = (void *)(slide + V1133_PLAYERNORMALTICK_VA);
    void *lTick = (void *)(slide + V1133_LEVELTICK_VA);
    MSHookFunction(pTick, (void *)hooked_1133_playerTick, (void **)&orig_1133_playerTick);
    MSHookFunction(lTick, (void *)hooked_1133_levelTick, (void **)&orig_1133_levelTick);
    NSLog(@"[魔玩盒子] 1.13.3 hook: playerTick=%p levelTick=%p", pTick, lTick);
    MWBLogFile(@"[1133] hook 成功: playerTick=%p levelTick=%p", pTick, lTick);
}
