/* MWBActions.mm — 跨版本动作分发/flag通道/小地图/日志 */
#import "MWBCommon.h"
#import <UIKit/UIKit.h>
#import <stdarg.h>
#import "MWBUI.h"
#import "MWBMenu.h"
#import "MWBFloat.h"
#import <dlfcn.h>   // cmp010 探针 dladdr 符号反查用

// 转视角直调 (定义在 MWBDebug.mm, flag turn-N 用)
@interface MWBTouchHelper : NSObject
+ (void)dragGameFromX:(CGFloat)x1 y:(CGFloat)y1 toX:(CGFloat)x2 y:(CGFloat)y2;
@end

#pragma mark - 跨版本动作分发

// 时间按钮语义 (菜单 setTime: 与 flag dottime 共用; tag: 1=白天 2=夜晚 6=日出0 7=正午4800 8=黄昏9600 9=午夜14400 25=-233 26=+233)
void MWBApplyTimeTag(int tag) {
    if (tag >= 6 && tag <= 9) {
        static const int tods[4] = {0, 4800, 9600, 14400};
        if (MWB010Only()) gTimeCustom010 = tods[tag - 6];
    } else if (tag == 25 || tag == 26) {
        if (MWB010Only() && gLevel) {
            int64_t dt = *(int64_t *)((char *)gLevel + LEVEL_TIME_OFFSET);
            dt += (tag == 26 ? 233 : -233);
            if (dt < 0) dt += 19200;
            *(int64_t *)((char *)gLevel + LEVEL_TIME_OFFSET) = dt;
            *(int64_t *)((char *)gLevel + LEVEL_TIME_OVERRIDE_OFF) = -1;
        }
    } else {
        gTimeMode = tag;
    }
}

// flag文件通道 (绕过cycript两次调用上限: ssh touch /tmp/mwbcmd-<动作>[-<参数>] 即可触发)
// 支持: inv-0/1 fly break speed jump noclip night aura map debug time-0/1/2 weather-0/1/2/3
//       heal enchant give117-264 give143-264 effect143-16 teleport1133 fill5 reactor diff-0/1/2/3 mob-32 explode
//       dayinfo(0.10时间三值) light010(0.10门控+光照表只读) cmp010(0.10重算链三方对比) tod-N(0.10跳绝对时刻) dottime-tag(走按钮同语义) menupage-N(开菜单跳页) touchtime-tag(直调菜单时间按钮) hitmenu blkreg1133 scaninv117 held117
// 注意: 游戏调用必须在tick返回后异步执行 (tick内同步调容器函数会死锁, -19冻屏教训)
static int gPendGive117 = -1, gPendGive143 = -1, gPendEffect143 = -1, gPendEffect1133 = -1;
static int gPendDiff010 = -1, gPendMob010 = -1;
static BOOL gPendHeal = NO, gPendEnchant = NO, gPendTeleport = NO, gPendFill = NO, gPendReactor = NO, gPendExplode = NO;
static void MWBFlushPending(void) {
    NSURL *lurl = [NSURL fileURLWithPath:@"/var/mobile/Documents/mowanbox.log"];
    NSFileHandle *lfh = [NSFileHandle fileHandleForWritingToURL:lurl error:nil];
    if (lfh) {
        [lfh seekToEndOfFile];
        NSString *line = [NSString stringWithFormat:@"%@ [泻洪] heal=%d ench=%d g117=%d g143=%d e143=%d e1133=%d tp=%d fill=%d reactor=%d diff=%d mob=%d expl=%d\n",
                          [NSDate date], gPendHeal, gPendEnchant, gPendGive117, gPendGive143,
                          gPendEffect143, gPendEffect1133, gPendTeleport, gPendFill, gPendReactor, gPendDiff010, gPendMob010, gPendExplode];
        [lfh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [lfh closeFile];
    }
    if (gPendHeal) { gPendHeal = NO; MWBHealNow(); }
    if (gPendEnchant) { gPendEnchant = NO; MWBEnchantHeld255(); }
    if (gPendGive117 >= 0 && gPlayer117) { int id = gPendGive117; gPendGive117 = -1; MWB117_Give(gPlayer117, id, 1); }
    if (gPendGive143 >= 0 && gPlayer143) { int id = gPendGive143; gPendGive143 = -1; MWB143_Give(gPlayer143, id, 5); }
    if (gPendEffect143 >= 0 && gPlayer143) { int id = gPendEffect143; gPendEffect143 = -1; MWB143_Effect(gPlayer143, id, 600, 0); }
    if (gPendEffect1133 >= 0 && gPlayer1133) {
        int id = gPendEffect1133; gPendEffect1133 = -1;
        BOOL ok = MWB1133_ApplyEffect(gPlayer1133, id, 0, 6000);
        NSURL *lurl = [NSURL fileURLWithPath:@"/var/mobile/Documents/mowanbox.log"];
        NSFileHandle *lfh = [NSFileHandle fileHandleForWritingToURL:lurl error:nil];
        if (lfh) {
            [lfh seekToEndOfFile];
            NSString *line = [NSString stringWithFormat:@"%@ [1133药水应用] id=%d ok=%d\n",
                              [NSDate date], id, ok];
            [lfh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [lfh closeFile];
        }
    }
    if (gPendTeleport) { gPendTeleport = NO; MWBTeleportUp10(); }
    if (gPendFill) { gPendFill = NO; MWBFillStone5(); }
    if (gPendReactor) { gPendReactor = NO; MWB010SpawnReactor(); }
    if (gPendDiff010 >= 0) { int difficulty = gPendDiff010; gPendDiff010 = -1; MWBSetDifficulty010(difficulty); }
    if (gPendMob010 >= 0) { int typeId = gPendMob010; gPendMob010 = -1; MWB010SpawnMob(typeId); }
    if (gPendExplode) { gPendExplode = NO; MWB010Explode(); }
}
void MWBPollCmdFile(void) {
    static int cooldown = 0;
    if ((cooldown++ % 20) != 0) return;
    NSFileManager *fm = [NSFileManager defaultManager];
    NSArray *files = [fm contentsOfDirectoryAtPath:@"/tmp" error:nil];
    for (NSString *f in files) {
        if (![f hasPrefix:@"mwbcmd-"]) continue;
        NSString *full = [@"/tmp" stringByAppendingPathComponent:f];
        NSString *cmd = [f substringFromIndex:7];
        [fm removeItemAtPath:full error:nil];
        NSArray *parts = [cmd componentsSeparatedByString:@"-"];
        NSString *act = parts[0];
        int arg = parts.count > 1 ? [parts[1] intValue] : 0;
        BOOL needFlush = NO;
        if ([act isEqualToString:@"inv"]) gInvincible = arg ? YES : NO;
        else if ([act isEqualToString:@"fly"]) gFly = arg ? YES : NO;
        else if ([act isEqualToString:@"break"]) gFastBreak = arg ? YES : NO;
        else if ([act isEqualToString:@"speed"]) gSpeed = arg ? YES : NO;
        else if ([act isEqualToString:@"jump"]) gSuperJump = arg ? YES : NO;
        else if ([act isEqualToString:@"noclip"]) gNoclip = arg ? YES : NO;
        else if ([act isEqualToString:@"night"]) gNightVision = arg ? YES : NO;
        else if ([act isEqualToString:@"aura"]) gKillAura = arg ? YES : NO;
        else if ([act isEqualToString:@"map"]) { gMinimap = arg ? YES : NO; MWBMinimapShow(gMinimap); }
        else if ([act isEqualToString:@"debug"]) gMWBDebug = arg ? YES : NO;
        else if ([act isEqualToString:@"time"]) gTimeMode = arg;
        else if ([act isEqualToString:@"tod"]) { if (arg >= 0) gTimeCustom010 = arg; }
        else if ([act isEqualToString:@"weather"]) gWeatherMode = arg;
        else if ([act isEqualToString:@"heal"]) { gPendHeal = YES; needFlush = YES; }
        else if ([act isEqualToString:@"enchant"]) { gPendEnchant = YES; needFlush = YES; }
        else if ([act isEqualToString:@"give117"]) { gPendGive117 = arg; needFlush = YES; }
        else if ([act isEqualToString:@"give143"]) { gPendGive143 = arg; needFlush = YES; }
        else if ([act isEqualToString:@"effect143"]) { gPendEffect143 = arg; needFlush = YES; }
        else if ([act isEqualToString:@"teleport1133"]) { gPendTeleport = YES; needFlush = YES; }
        else if ([act isEqualToString:@"fill5"]) { gPendFill = YES; needFlush = YES; }
        else if ([act isEqualToString:@"reactor"]) { gPendReactor = YES; needFlush = YES; }
        else if ([act isEqualToString:@"diff"]) { gPendDiff010 = arg; needFlush = YES; }
        else if ([act isEqualToString:@"mob"]) { gPendMob010 = arg; needFlush = YES; }
        else if ([act isEqualToString:@"explode"]) { gPendExplode = YES; needFlush = YES; }
        else if ([act isEqualToString:@"fillnat5"] && gPlayer1133) {
            // 自然方块铺石: 从脚下往下扫首个非air方块, 用它铺5³ (绕开注册表争议)
            void *bs = MWB1133BlockSource();
            void *air = *(void **)(MWBMainSlide() + V1133_BLOCKBASE_VA);
            NSURL *lurl = [NSURL fileURLWithPath:@"/var/mobile/Documents/mowanbox.log"];
            NSFileHandle *lfh = [NSFileHandle fileHandleForWritingToURL:lurl error:nil];
            int n = -99;
            if (bs && air && gPlayer1133) {
                float px = *(float *)((char *)gPlayer1133 + 0x41C);
                float py = *(float *)((char *)gPlayer1133 + 0x41C + 4);
                float pz = *(float *)((char *)gPlayer1133 + 0x41C + 8);
                int cx = (int)floorf(px), cy = (int)floorf(py), cz = (int)floorf(pz);
                void *nat = NULL;
                for (int y = cy - 1; y > cy - 25 && y >= 0; y--) {
                    void *b = MWB1133GetOne(bs, cx, y, cz);
                    if (b && b != air) { nat = b; break; }
                }
                if (lfh) { [lfh seekToEndOfFile];
                    NSString *line = [NSString stringWithFormat:@"%@ [1133自然] nat=%p\n",
                                      [NSDate date], nat];
                    [lfh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [lfh closeFile]; }
                n = 0;
                if (nat) {
                    for (int y = cy - 2; y <= cy + 2; y++)
                        for (int z = cz - 2; z <= cz + 2; z++)
                            for (int x = cx - 2; x <= cx + 2; x++)
                                n += MWB1133SetOne(bs, x, y, z, nat);
                }
            }
            if (lfh) { [lfh seekToEndOfFile];
                NSString *line = [NSString stringWithFormat:@"%@ [1133自然] 写入%d块\n",
                                  [NSDate date], n];
                [lfh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [lfh closeFile]; }
        }
        else if ([act isEqualToString:@"scaninv117"] && gPlayer117) {
            void *inv = (char *)gPlayer117 + 0x1288;
            void **reg = (void **)(MWBMainSlide() + V117_ITEMREG_VA);
            void *diamond = reg[264];
            void *dirt = reg[3];
            NSURL *lurl = [NSURL fileURLWithPath:@"/var/mobile/Documents/mowanbox.log"];
            NSFileHandle *lfh = [NSFileHandle fileHandleForWritingToURL:lurl error:nil];
            if (lfh) {
                [lfh seekToEndOfFile];
                NSMutableString *m = [NSMutableString stringWithFormat:@"%@ [117背包扫描] inv=%p diamond=%p dirt=%p 命中:",
                                      [NSDate date], inv, diamond, dirt];
                for (int off = -0x200; off < 0x1000; off += 8) {
                    void *v = *(void **)((char *)inv + off);
                    if ((v == diamond || v == dirt) && off >= 0)
                        [m appendFormat:@" +0x%x=%@前后: %02x%02x%02x%02x|%02x%02x%02x%02x)", off,
                         v == diamond ? @"钻石" : @"泥土",
                         ((uint8_t *)inv)[off-4], ((uint8_t *)inv)[off-3],
                         ((uint8_t *)inv)[off-2], ((uint8_t *)inv)[off-1],
                         ((uint8_t *)inv)[off+8], ((uint8_t *)inv)[off+9],
                         ((uint8_t *)inv)[off+10], ((uint8_t *)inv)[off+11]];
                }
                [m appendString:@" 对象dump:"];
                for (int off = 0; off < 0x200; off += 16)
                    [m appendFormat:@" +%x=%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x%02x", off,
                     ((uint8_t *)inv)[off], ((uint8_t *)inv)[off+1], ((uint8_t *)inv)[off+2],
                     ((uint8_t *)inv)[off+3], ((uint8_t *)inv)[off+4], ((uint8_t *)inv)[off+5],
                     ((uint8_t *)inv)[off+6], ((uint8_t *)inv)[off+7], ((uint8_t *)inv)[off+8],
                     ((uint8_t *)inv)[off+9], ((uint8_t *)inv)[off+10], ((uint8_t *)inv)[off+11],
                     ((uint8_t *)inv)[off+12], ((uint8_t *)inv)[off+13], ((uint8_t *)inv)[off+14],
                     ((uint8_t *)inv)[off+15]];
                [m appendString:@"\n"];
                [lfh writeData:[m dataUsingEncoding:NSUTF8StringEncoding]];
                [lfh closeFile];
            }
        }
        else if ([act isEqualToString:@"yawscan010"] && gLocalPlayer) {
            // 转向扫内存: dump 玩家对象 +0~+0x1FF 逐字, 转视角前后各一次, diff 找真 yaw/pitch
            // (C 缓冲直拼, 不用 NSMutableString, 另记长度防吞)
            NSURL *lurl = [NSURL fileURLWithPath:@"/var/mobile/Documents/mowanbox.log"];
            NSFileHandle *lfh = [NSFileHandle fileHandleForWritingToURL:lurl error:nil];
            if (lfh) {
                [lfh seekToEndOfFile];
                char *buf = (char *)malloc(8192);
                int n = 0;
                n += snprintf(buf + n, 8192 - n, "%s [010扫] player=%p\n",
                              [[[NSDate date] description] UTF8String], gLocalPlayer);
                for (int off = 0; off < 0x200 && n < 7000; off += 16) {
                    uint32_t *w = (uint32_t *)((char *)gLocalPlayer + off);
                    float *f = (float *)((char *)gLocalPlayer + off);
                    n += snprintf(buf + n, 8192 - n, " +%x=%08x/%08x/%08x/%08x(%.1f/%.1f/%.1f/%.1f)",
                                  off, w[0], w[1], w[2], w[3], f[0], f[1], f[2], f[3]);
                }
                n += snprintf(buf + n, 8192 - n, "\n[010扫] 共%d字节\n", n);
                [lfh writeData:[NSData dataWithBytes:buf length:n]];
                [lfh closeFile];
                free(buf);
            }
        }
        else if ([act isEqualToString:@"yaw010"] && gLocalPlayer) {
            // 转向探针: 读 ENTITY_YAW_OFF/PITCH_OFF, 原地转视角后多 touch 几次对比两次日志
            NSURL *lurl = [NSURL fileURLWithPath:@"/var/mobile/Documents/mowanbox.log"];
            NSFileHandle *lfh = [NSFileHandle fileHandleForWritingToURL:lurl error:nil];
            if (lfh) {
                [lfh seekToEndOfFile];
                float yaw = *(float *)((char *)gLocalPlayer + ENTITY_YAW_OFF);
                float pitch = *(float *)((char *)gLocalPlayer + ENTITY_PITCH_OFF);
                float px = *(float *)((char *)gLocalPlayer + 0x28);
                float py = *(float *)((char *)gLocalPlayer + 0x28 + 4);
                float pz = *(float *)((char *)gLocalPlayer + 0x28 + 8);
                NSString *line = [NSString stringWithFormat:
                    @"%@ [010转向] lp=%p yaw=%.1f pitch=%.1f pos=(%.1f,%.1f,%.1f)\n",
                    [NSDate date], gLocalPlayer, yaw, pitch, px, py, pz];
                [lfh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
                [lfh closeFile];
            }
        }
        else if ([act isEqualToString:@"nightprobe"] && gLevel) {
            // 夜视探针(全只读): Level+0x1638 黑暗系数 + Options gamma 链(MC+0x178→P→+0x1c8→+0x2d0)
            NSURL *lurl = [NSURL fileURLWithPath:@"/var/mobile/Documents/mowanbox.log"];
            NSFileHandle *lfh = [NSFileHandle fileHandleForWritingToURL:lurl error:nil];
            if (lfh) {
                [lfh seekToEndOfFile];
                float dk = *(float *)((char *)gLevel + 0x1638);
                float ga = -999, ga2 = -999;
                void *mc = MWB010Minecraft();
                void *P = mc ? *(void **)((char *)mc + 0x178) : NULL;
                void *ob = P ? *(void **)((char *)P + 0x1c8) : NULL;
                if (ob) { ga = *(float *)((char *)ob + 0x2d0); ga2 = *(float *)((char *)ob + 0x2d4); }
                NSString *line = [NSString stringWithFormat:
                    @"%@ [010夜视] dark1638=%.3f gamma=%.3f gamma+4=%.3f mc=%p P=%p ob=%p\n",
                    [NSDate date], dk, ga, ga2, mc, P, ob];
                [lfh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
                [lfh closeFile];
            }
        }
        else if ([act isEqualToString:@"dayinfo"] && gLevel) {            // 时间三值探针: 逻辑时间 / 天空覆写 / 亮度字节 (0.10 白天不亮诊断用)
            NSURL *lurl = [NSURL fileURLWithPath:@"/var/mobile/Documents/mowanbox.log"];
            NSFileHandle *lfh = [NSFileHandle fileHandleForWritingToURL:lurl error:nil];
            if (lfh) {
                [lfh seekToEndOfFile];
                int64_t dt = *(int64_t *)((char *)gLevel + LEVEL_TIME_OFFSET);
                int64_t ov = *(int64_t *)((char *)gLevel + LEVEL_TIME_OVERRIDE_OFF);
                uint8_t sky = *(uint8_t *)((char *)gLevel + 0x90);
                NSString *line = [NSString stringWithFormat:
                    @"%@ [010时间] dayTime=%lld override=%lld sky=%d mode=%d mctick=%d\n",
                    [NSDate date], (long long)dt, (long long)ov, sky, gTimeMode, gMcTick010Count];
                [lfh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
                [lfh closeFile];
            }
        }
        else if ([act isEqualToString:@"light010"]) {
            // 光照门控+光照表只读探针 (0.10 夜切昼地面不亮诊断用, 全只读不调游戏函数)
            // +0x1854: 光照表重算门 (1=未 settle, 3=已 settle); +0x18B0: W20 派生速率
            // 光照表: 静态 0x10034cd98+slide, 256 项 RGBA (读 6 个下标看昼夜)
            NSURL *lurl = [NSURL fileURLWithPath:@"/var/mobile/Documents/mowanbox.log"];
            NSFileHandle *lfh = [NSFileHandle fileHandleForWritingToURL:lurl error:nil];
            if (lfh) {
                [lfh seekToEndOfFile];
                int gate = -9;
                float rate = -1.0f;
                if (gLocalPlayer) {
                    gate = *(int *)((char *)gLocalPlayer + 0x1854);
                    rate = *(float *)((char *)gLocalPlayer + 0x18B0);
                }
                uint32_t t0 = 0, t15 = 0, t16 = 0, t128 = 0, t240 = 0, t255 = 0;
                void *tbl = NULL;
                if (gGV == (int)MWBGameV0_10) {
                    tbl = *(void **)(MWBMainSlide() + 0x10034cd98UL);
                    if (tbl) {
                        uint32_t *t = (uint32_t *)tbl;
                        t0 = t[0]; t15 = t[15]; t16 = t[16];
                        t128 = t[128]; t240 = t[240]; t255 = t[255];
                    }
                }
                NSString *line = [NSString stringWithFormat:
                    @"%@ [010光照] gate=%d rate=%.3f tbl=%p [0]=%08x [15]=%08x [16]=%08x [128]=%08x [240]=%08x [255]=%08x\n",
                    [NSDate date], gate, rate, tbl, t0, t15, t16, t128, t240, t255];
                [lfh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
                [lfh closeFile];
            }
        }
        else if ([act isEqualToString:@"cmp010"]) {
            // 重算链三方指针对比 (0.10 光照表冻结诊断: gate开但表不动, 看 MC链v27 与 gLevel 是否同体)
            // MinecraftClient::tick 门内: v11=MC+0x178; P=*v11; V=*P(虚表); slot=*(V+0x158); v18=*v11; v27=*(v18+0xa0)
            // 全只读 + dladdr 符号反查, 不调任何游戏函数
            NSURL *lurl = [NSURL fileURLWithPath:@"/var/mobile/Documents/mowanbox.log"];
            NSFileHandle *lfh = [NSFileHandle fileHandleForWritingToURL:lurl error:nil];
            if (lfh) {
                [lfh seekToEndOfFile];
                void *mc = MWB010Minecraft();
                void *v11 = mc ? *(void **)((char *)mc + 0x178) : NULL;
                void *P = v11 ? *(void **)v11 : NULL;
                void *V = P ? *(void **)P : NULL;
                void *slot = V ? *(void **)((char *)V + 0x158) : NULL;
                const char *sname = "?";
                Dl_info info;
                if (slot && dladdr(slot, &info) && info.dli_sname) sname = info.dli_sname;
                void *v18 = v11 ? *(void **)v11 : NULL;
                void *v27 = v18 ? *(void **)((char *)v18 + 0xa0) : NULL;
                void *mcA0 = (mc && v18 == mc) ? *(void **)((char *)mc + 0xa0) : NULL;
                // 门全部条件: a0=a4->field_0xa0 非空; mc58==0; cp=getLocalPlayer() 非空且 +0x1854==3
                void *a0a0 = mc ? *(void **) ((char *)mc + 0xa0) : NULL;
                void *cp = NULL;
                int gate2 = -999;
                if (slot && P) {
                    typedef void *(*GetP)(void *);
                    cp = ((GetP)slot)(P);   // 与游戏内门同一调法: this=P(=mc)
                    if (cp && (uintptr_t)cp > 0x100000000UL && (uintptr_t)cp < 0x400000000UL)
                        gate2 = *(int *)((char *)cp + 0x1854);
                }
                long long dt27 = -999, dtG = -999;
                int sky27 = -9, skyG = -9, mc58 = -999;
                if (v27) {
                    dt27 = *(int64_t *)((char *)v27 + LEVEL_TIME_OFFSET);
                    sky27 = *(uint8_t *)((char *)v27 + 0x90);
                }
                if (gLevel) {
                    dtG = *(int64_t *)((char *)gLevel + LEVEL_TIME_OFFSET);
                    skyG = *(uint8_t *)((char *)gLevel + 0x90);
                }
                if (mc) mc58 = *(int *)((char *)mc + 0x58);
                NSString *line = [NSString stringWithFormat:
                    @"%@ [010对比] mc=%p v11=%p P=%p V=%p slot=%p(%s) v27=%p mcA0=%p dt27=%lld sky27=%d gLevel=%p dtG=%lld skyG=%d 同体=%d mc58=%d lp=%p a0a0=%p 同A0=%d cp=%p 同LP=%d gate2=%d\n",
                    [NSDate date], mc, v11, P, V, slot, sname, v27, mcA0, dt27, sky27,
                    gLevel, dtG, skyG, (v27 && v27 == gLevel) ? 1 : 0, mc58, gLocalPlayer,
                    a0a0, (a0a0 && a0a0 == gLevel) ? 1 : 0, cp, (cp && cp == gLocalPlayer) ? 1 : 0, gate2];
                [lfh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
                [lfh closeFile];
            }
        }
        else if ([act isEqualToString:@"dottime"]) { MWBApplyTimeTag(arg); }
        else if ([act isEqualToString:@"menuclose"]) {
            // 关菜单(恢复小地图, 验证层级用): cycript 点不到自家 UIKit 按钮, 走此通道
            dispatch_async(dispatch_get_main_queue(), ^{
                UIWindow *w = nil;
                for (UIWindow *ww in [UIApplication sharedApplication].windows)
                    if ([NSStringFromClass([ww class]) containsString:@"MWBOverlay"]) { w = ww; break; }
                if (!w) return;
                UIViewController *vc = w.rootViewController;
                if (![vc isKindOfClass:[MWBViewController class]]) return;
                MWBViewController *mvc = (MWBViewController *)vc;
                if (mvc.menu.superview) [mvc.menu close];
            });
        }
        else if ([act isEqualToString:@"menupage"]) {            // 打开菜单并跳到指定页(布局截图用): Game=0 Blocks=1 Controls=2 World=3
            dispatch_async(dispatch_get_main_queue(), ^{
                UIWindow *w = nil;
                for (UIWindow *ww in [UIApplication sharedApplication].windows)
                    if ([NSStringFromClass([ww class]) containsString:@"MWBOverlay"]) { w = ww; break; }
                if (!w) return;
                UIViewController *vc = w.rootViewController;
                if (![vc isKindOfClass:[MWBViewController class]]) return;
                MWBViewController *mvc = (MWBViewController *)vc;
                if (!mvc.menu.superview) [mvc toggleMenu];
                int page = arg;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    [mvc.menu showPage:page];
                });
            });
        }
        else if ([act isEqualToString:@"touchtime"]) {
            // 直调菜单时间按钮(验证用): 打开菜单→World页→按 tag 触发真实 setTime:, 再查菜单是否还开着
            dispatch_async(dispatch_get_main_queue(), ^{
                UIWindow *w = nil;
                for (UIWindow *ww in [UIApplication sharedApplication].windows)
                    if ([NSStringFromClass([ww class]) containsString:@"MWBOverlay"]) { w = ww; break; }
                NSURL *lurl = [NSURL fileURLWithPath:@"/var/mobile/Documents/mowanbox.log"];
                NSFileHandle *lfh = [NSFileHandle fileHandleForWritingToURL:lurl error:nil];
                void (^log)(NSString *) = ^(NSString *m){
                    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], m];
                    if (lfh) { [lfh seekToEndOfFile]; [lfh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; }
                };
                if (!w) { log(@"[touchtime] 无悬浮窗"); if (lfh) [lfh closeFile]; return; }
                UIViewController *vc = w.rootViewController;
                if (![vc isKindOfClass:[MWBViewController class]]) { log(@"[touchtime] rootVC类型不对"); if (lfh) [lfh closeFile]; return; }
                MWBViewController *mvc = (MWBViewController *)vc;
                if (!mvc.menu.superview) [mvc toggleMenu];
                int tag = arg;
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    MWBOptionsMenu *menu = mvc.menu;
                    [menu showPage:3];
                    MWBPixelButton *hit = nil;
                    for (UIView *sv in menu.pages[3].subviews)
                        if ([sv isKindOfClass:[MWBPixelButton class]] && ((MWBPixelButton *)sv).tag == tag) { hit = (MWBPixelButton *)sv; break; }
                    if (!hit) { log([NSString stringWithFormat:@"[touchtime] tag=%d 未找到按钮", tag]); if (lfh) [lfh closeFile]; return; }
                    [hit sendActionsForControlEvents:UIControlEventTouchUpInside];
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        log([NSString stringWithFormat:@"[touchtime] tag=%d 菜单还开着=%d", tag, menu.superview ? 1 : 0]);
                        if (lfh) [lfh closeFile];
                    });
                });
            });
        }
        else if ([act isEqualToString:@"turn"]) {
            // 转视角(验证小地图箭头用): 从屏幕中部向右水平拖 arg 点 (768x1024 点坐标系)
            int dx = arg ? arg : 200;
            [MWBTouchHelper dragGameFromX:512 y:500 toX:512 + dx y:500];
        }
        else if ([act isEqualToString:@"sink"]) {
            // 穿墙验证: 原地垂直传送 (sink-5 下埋 5 格 / sink--5 上浮 5 格, 双横杠解析出负数)
            NSArray *pp = [cmd componentsSeparatedByString:@"-"];
            int dy = (pp.count > 2) ? -[pp[2] intValue] : (int)[pp[1] intValue];
            if (dy != 0) MWB010Sink(dy);
        }
        else if ([act isEqualToString:@"held117"] && gPlayer117) {
            void *held = ((void *(*)(void *))(MWBMainSlide() + V117_HELDITEM_VA))(gPlayer117);
            NSURL *lurl = [NSURL fileURLWithPath:@"/var/mobile/Documents/mowanbox.log"];
            NSFileHandle *lfh = [NSFileHandle fileHandleForWritingToURL:lurl error:nil];
            if (lfh) {
                [lfh seekToEndOfFile];
                NSMutableString *m = [NSMutableString stringWithFormat:@"%@ [117手持] held=%p 实例:",
                                      [NSDate date], held];
                if (held) {
                    for (int i = 0; i < 0x70; i += 8)
                        [m appendFormat:@" +%x=%02x%02x%02x%02x%02x%02x%02x%02x", i,
                         ((uint8_t *)held)[i], ((uint8_t *)held)[i+1], ((uint8_t *)held)[i+2],
                         ((uint8_t *)held)[i+3], ((uint8_t *)held)[i+4], ((uint8_t *)held)[i+5],
                         ((uint8_t *)held)[i+6], ((uint8_t *)held)[i+7]];
                }
                [m appendString:@"\n"];
                [lfh writeData:[m dataUsingEncoding:NSUTF8StringEncoding]];
                [lfh closeFile];
            }
        }
        else if ([act isEqualToString:@"effect1133"]) { gPendEffect1133 = arg; needFlush = YES; }
        else if ([act isEqualToString:@"attr1133"] && gPlayer1133) {
            NSURL *lurl = [NSURL fileURLWithPath:@"/var/mobile/Documents/mowanbox.log"];
            NSFileHandle *lfh = [NSFileHandle fileHandleForWritingToURL:lurl error:nil];
            if (lfh) {
                [lfh seekToEndOfFile];
                NSString *line = [NSString stringWithFormat:@"%@ [1133血属性] 已禁用(GetAttr待修) player=%p\n",
                                  [NSDate date], gPlayer1133];
                [lfh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
                [lfh closeFile];
            }
        }
        else if ([act isEqualToString:@"blkreg1133"] && gPlayer1133) {
            // 全只读验证: bs虚表/TEXT检查/getBlock(高空必回air)/脚下, 结果小整数一律不解引用
            uintptr_t slide = MWBMainSlide();
            uintptr_t lo = slide + 0x100000000UL, hi = lo + 0x4000000UL;
            void **base = (void **)(slide + V1133_BLOCKBASE_VA);
            void *bs = MWB1133BlockSource();
            void *bsvt = NULL; int16_t h = -1;
            if (bs && (uintptr_t)bs > 0x100000000UL) {
                bsvt = *(void **)bs;
                h = *(int16_t *)((char *)bs + 0x30);
            }
            float px = *(float *)((char *)gPlayer1133 + 0x41C);
            float py = *(float *)((char *)gPlayer1133 + 0x41C + 4);
            float pz = *(float *)((char *)gPlayer1133 + 0x41C + 8);
            int cx = (int)floorf(px), cy = (int)floorf(py), cz = (int)floorf(pz);
            void *air = base[0];
            void *sky = NULL, *foot = NULL;
            if (bs && bsvt && (uintptr_t)bsvt >= lo && (uintptr_t)bsvt < hi) {
                MWBBlockPos ps = {cx, 300, cz}, pf = {cx, cy - 1, cz};
                sky = MWB1133GetOne(bs, ps.x, ps.y, ps.z);
                foot = MWB1133GetOne(bs, pf.x, pf.y, pf.z);
            }
            NSURL *lurl = [NSURL fileURLWithPath:@"/var/mobile/Documents/mowanbox.log"];
            NSFileHandle *lfh = [NSFileHandle fileHandleForWritingToURL:lurl error:nil];
            if (lfh) {
                [lfh seekToEndOfFile];
                NSString *line = [NSString stringWithFormat:
                                  @"%@ [1133只读] bs=%p bsvt=%p(T=%d) h=%d air=%p sky=%p(==air%d) foot=%p 玩家(%d,%d,%d)\n",
                                  [NSDate date], bs, bsvt,
                                  (bsvt && (uintptr_t)bsvt >= lo && (uintptr_t)bsvt < hi) ? 1 : 0,
                                  h, air, sky, (sky && sky == air) ? 1 : 0, foot, cx, cy, cz];
                [lfh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
                [lfh closeFile];
            }
        }
        else if ([act isEqualToString:@"hitmenu"]) {
            // 菜单命中探针(调试): 打开菜单(Game页)并实测第一颗开关中心/边缘点的命中链
            dispatch_async(dispatch_get_main_queue(), ^{
                UIWindow *w = nil;
                for (UIWindow *ww in [UIApplication sharedApplication].windows)
                    if ([NSStringFromClass([ww class]) containsString:@"MWBOverlay"]) { w = ww; break; }
                NSURL *lurl = [NSURL fileURLWithPath:@"/var/mobile/Documents/mowanbox.log"];
                NSFileHandle *lfh = [NSFileHandle fileHandleForWritingToURL:lurl error:nil];
                void (^log)(NSString *) = ^(NSString *s){
                    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], s];
                    if (lfh) { [lfh seekToEndOfFile]; [lfh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; }
                };
                if (!w) { log(@"[hitmenu] 无悬浮窗"); if (lfh) [lfh closeFile]; return; }
                UIViewController *vc = w.rootViewController;
                if (![vc isKindOfClass:[MWBViewController class]]) { log(@"[hitmenu] rootVC类型不对"); if (lfh) [lfh closeFile]; return; }
                MWBViewController *mvc = (MWBViewController *)vc;
                if (!mvc.menu.superview) [mvc toggleMenu];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                    MWBOptionsMenu *menu = mvc.menu;
                    if (!menu.superview || menu.pages.count < 1) { log(@"[hitmenu] 菜单未开"); if (lfh) [lfh closeFile]; return; }
                    MWBPixelToggle *first = nil;
                    for (UIView *sv in ((UIView *)menu.pages[0]).subviews) {
                        for (UIView *ssv in sv.subviews)
                            if ([ssv isKindOfClass:[MWBPixelToggle class]]) { first = (MWBPixelToggle *)ssv; break; }
                        if (first) break;
                    }
                    if (!first) { log(@"[hitmenu] 未找到开关"); if (lfh) [lfh closeFile]; return; }
                    CGRect tf = [first.superview convertRect:first.frame toView:w];
                    CGPoint c = (CGPoint){CGRectGetMidX(tf), CGRectGetMidY(tf)};
                    CGPoint e = (CGPoint){CGRectGetMinX(tf)+6, CGRectGetMidY(tf)};
                    UIView *hc = [w hitTest:c withEvent:nil];
                    UIView *he = [w hitTest:e withEvent:nil];
                    log([NSString stringWithFormat:
                        @"[hitmenu] page=%ld toggle=%@ center=(%.0f,%.0f)->%@ edge=(%.0f,%.0f)->%@ panelDelay=%d",
                        (long)menu.currentPage, NSStringFromCGRect(tf),
                        c.x, c.y, NSStringFromClass([hc class]),
                        e.x, e.y, NSStringFromClass([he class]),
                        (int)[[menu valueForKey:@"_panel"] delaysContentTouches]]);
                    // 翻转自验证: 直调开关两次(净效果为零), 确认行点链路通到 gVar
                    {
                        BOOL b0 = gInvincible;
                        [first toggle];
                        BOOL b1 = gInvincible;
                        [first toggle];
                        BOOL b2 = gInvincible;
                        log([NSString stringWithFormat:@"[hitmenu] 翻转验证 inv=%d->%d->%d 手势数=%lu",
                             b0, b1, b2, (unsigned long)[first.superview.gestureRecognizers count]]);
                    }
                    if (lfh) [lfh closeFile];
                });
            });
        }
        // tick返回后异步泻洪 (避免容器锁重入)
        if (needFlush) dispatch_async(dispatch_get_main_queue(), ^{ MWBFlushPending(); });
        NSURL *logURL = [NSURL fileURLWithPath:@"/var/mobile/Documents/mowanbox.log"];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingToURL:logURL error:nil];
        if (fh) {
            [fh seekToEndOfFile];
            NSString *line = [NSString stringWithFormat:@"%@ [盒子指令] %@\n", [NSDate date], cmd];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    }
    // tick返回后异步泻洪 (避免容器锁重入)
    dispatch_async(dispatch_get_main_queue(), ^{ MWBFlushPending(); });
}

void MWBHealNow(void) {
    if (gGV == (int)MWBGameV0_10 && gLocalPlayer) {
        // 0.10: Mob::heal 直接回满 (上限 20, 反编译确认只写血量不碰容器, tick 外调安全)
        typedef void (*Heal010Fn)(void *, int);
        Heal010Fn heal = (Heal010Fn)MSFindSymbol(NULL, "__ZN3Mob4healEi");
        if (heal) heal(gLocalPlayer, 20);
        return;
    }
    if (gGV == (int)MWBGameV1_13_3 && gPlayer1133) MWB1133_ApplyEffect(gPlayer1133, 6, 0, 40);
    else if (gGV == (int)MWBGameV1_4_3 && gPlayer143) MWB143_Effect(gPlayer143, 6, 2, 0);
    else if (gGV == (int)MWBGameV1_2_15 && gPlayer1215) MWB1215_Effect(gPlayer1215, 6, 2, 0);
}
void MWBEnchantHeld255(void) {
    if (gGV == (int)MWBGameV1_1_7 && gPlayer117) MWB117_EnchantMax(gPlayer117, 9, 255);
    else if (gGV == (int)MWBGameV1_4_3 && gPlayer143) MWB143_EnchantMax(gPlayer143, 9, 255);
    else if (gGV == (int)MWBGameV1_2_15 && gPlayer1215) MWB1215_EnchantHeld(gPlayer1215, 9, 255);
}
void MWBTeleportUp10(void) {
    if (gGV == (int)MWBGameV1_13_3 && gPlayer1133) MWB1133_TeleportUp10(gPlayer1133);
}
void MWBFillStone5(void) {
    if (gGV == (int)MWBGameV1_13_3 && gPlayer1133) MWB1133_FillStone(2);
    else if (gGV == (int)MWBGameV0_10 && gLocalPlayer) {
        void *ts = *(void **)((char *)gLocalPlayer + 0x48);
        float px = *(float *)((char *)gLocalPlayer + 0x28);
        float py = *(float *)((char *)gLocalPlayer + 0x28 + 4);
        float pz = *(float *)((char *)gLocalPlayer + 0x28 + 8);
        int cx = (int)floorf(px), cy = (int)floorf(py), cz = (int)floorf(pz);
        int (*setTD)(void *, void *, void *, int) =
            (int (*)(void *, void *, void *, int))MSFindSymbol(NULL, "__ZN10TileSource14setTileAndDataERK7TilePos8FullTilei");
        if (!ts || !setTD) return;
        for (int y = cy - 2; y <= cy + 2; y++)
            for (int z = cz - 2; z <= cz + 2; z++)
                for (int x = cx - 2; x <= cx + 2; x++) {
                    MWBBlockPos p = {x, y, z};
                    uint8_t ft[2] = {1, 0};  // 石头id1
                    setTD(ts, &p, ft, 3);
                }
    }
}
// 难度: 0.10 走 ServerLevel::setDifficulty (Level::setDifficulty 只是 RET 空壳, 真逻辑写 ServerLevel+0x14B8 并广播;
// 经 ServerLevel::tick→Level::tick 调用链证实, hooked Level::tick 拿到的 gLevel 即 ServerLevel*, 可直接调)
void MWBSetDifficulty010(int difficulty) {
    if (gGV != (int)MWBGameV0_10 || !gLevel) {
        MWBLogFile(@"[010难度] 跳过 gv=%d level=%p d=%d", gGV, gLevel,
                   difficulty);
        return;
    }
    if (difficulty < 0 || difficulty > 3) return;
    typedef void (*SetDifficultyFn)(void *, int);
    SetDifficultyFn setDifficulty =
        (SetDifficultyFn)MSFindSymbol(NULL, "__ZN11ServerLevel13setDifficultyEi");
    BOOL bySym = (setDifficulty != NULL);
    if (!setDifficulty) setDifficulty = (SetDifficultyFn)(MWBMainSlide() + 0x1001b8f7cUL);
    if (setDifficulty) {
        setDifficulty(gLevel, difficulty);
        // 回读 ServerLevel+0x14B8 (写难度并广播的真位置, 见 AGENTS), 立判生效
        int back = *(int *)((char *)gLevel + 0x14B8);
        MWBLogFile(@"[010难度] 置%d bySym=%d 回读+0x14B8=%d",
                   difficulty, bySym, back);
    } else {
        MWBLogFile(@"[010难度] 符号与回退地址全空, 未调用");
    }
}

// 0.10 一键反应核: 在玩家脚下按游戏校验图案搭平台+核, 再直调 NetherReactorTile::use 激活
void MWB010SpawnReactor(void) {
    if (gGV != (int)MWBGameV0_10 || !gLocalPlayer) return;
    uintptr_t slide = MWBMainSlide();
    void *ts = *(void **)((char *)gLocalPlayer + 0x48);
    int (*setTD)(void *, void *, void *, int) =
        (int (*)(void *, void *, void *, int))MSFindSymbol(NULL, "__ZN10TileSource14setTileAndDataERK7TilePos8FullTilei");
    if (!ts || !setTD) return;

    // use 按 3x3x3 校验图案; 索引 = 层*9 + x*3 + z, y 为核所在层
    // 底层: 四角 A、其余 B; 中层: 四角 B、中心核 C; 顶层: 十字 B
    uint8_t idA = 41, idB = 4, idC = 247;
    void *tileA = *(void **)(slide + 0x10034D708UL);
    void *tileB = *(void **)(slide + 0x10034D558UL);
    void *tileC = *(void **)(slide + 0x10034D860UL);
    if (tileA) idA = *(uint8_t *)((char *)tileA + 0x48);
    if (tileB) idB = *(uint8_t *)((char *)tileB + 0x48);
    if (tileC) idC = *(uint8_t *)((char *)tileC + 0x48);
    uint8_t bottom[9] = {idA, idB, idA, idB, idB, idB, idA, idB, idA};
    uint8_t middle[9] = {idB, 0, idB, 0, idC, 0, idB, 0, idB};
    uint8_t top[9] = {0, idB, 0, idB, idB, idB, 0, idB, 0};

    float px = *(float *)((char *)gLocalPlayer + 0x28);
    float py = *(float *)((char *)gLocalPlayer + 0x28 + 4);
    float pz = *(float *)((char *)gLocalPlayer + 0x28 + 8);
    int cx = (int)floorf(px), cy = (int)floorf(py), cz = (int)floorf(pz);
    int y = cy;
    if (y < 2) y = 2;
    if (y > 100) y = 100;
    for (int lx = 0; lx < 3; lx++) {
        for (int lz = 0; lz < 3; lz++) {
            MWBBlockPos p = {cx - 1 + lx, y - 1, cz - 1 + lz};
            uint8_t ft[2] = {bottom[lx * 3 + lz], 0};
            setTD(ts, &p, ft, 3);
            p = (MWBBlockPos){cx - 1 + lx, y, cz - 1 + lz};
            ft[0] = middle[lx * 3 + lz];
            setTD(ts, &p, ft, 3);
            p = (MWBBlockPos){cx - 1 + lx, y + 1, cz - 1 + lz};
            ft[0] = top[lx * 3 + lz];
            setTD(ts, &p, ft, 3);
        }
    }

    // use 在函数体内没有使用 this, 传 NULL 即可; 失败只返回 0, 不会崩溃
    typedef int (*ReactorUseFn)(void *, void *, int, int, int);
    ReactorUseFn useReactor = (ReactorUseFn)(slide + 0x10015a344UL);
    void *maybeLevel = *(void **)((char *)gLocalPlayer + 0x58);
    int launchGate = maybeLevel ? *(int *)((char *)maybeLevel + 0x15E4) : -1;
    int launched = useReactor(NULL, gLocalPlayer, cx, y, cz);
    NSURL *logURL = [NSURL fileURLWithPath:@"/var/mobile/Documents/mowanbox.log"];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingToURL:logURL error:nil];
    if (fh) {
        [fh seekToEndOfFile];
        NSString *line = [NSString stringWithFormat:@"%@ [010反应核] 图案=%d/%d/%d y=%d gate=%d use=%d\n",
                          [NSDate date], idA, idB, idC, y, launchGate, launched];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
    if (launched == 1) {
        // 激活后把玩家挪到尖塔上方: lightItUp 同步把尖塔建到核上方 +30, y+4 会埋进尖塔, 改 y+32 落到塔顶
        MWB010Teleport(gLocalPlayer, (float)cx, (float)(y + 32), (float)cz);
    }
}

// 0.10 刷怪: MobFactory::CreateMob 建怪 + addMob 入世界 (id 见 AGENTS 实体映射表)
void MWB010SpawnMob(int typeId) {
    if (gGV != (int)MWBGameV0_10 || !gLocalPlayer) return;
    if (!((typeId >= 10 && typeId <= 16) || (typeId >= 32 && typeId <= 39) ||
          typeId == 1807 || (typeId >= 2848 && typeId <= 2855) ||
          (typeId >= 5898 && typeId <= 5904) || typeId == 22286)) return;
    uintptr_t slide = MWBMainSlide();
    void *ts = *(void **)((char *)gLocalPlayer + 0x48);
    if (!ts) return;
    // MobFactory 取自 TileSource 链 (spawnEnemy 反编译同款写法: *(*(ts+24)+5680))
    void *inner = *(void **)((char *)ts + 24);
    void *mf = inner ? *(void **)((char *)inner + 5680) : NULL;
    typedef void *(*CreateMobFn)(int, void *, float *, void *);
    typedef int (*AddMobFn)(void *, void *, int);
    CreateMobFn createMob = (CreateMobFn)MSFindSymbol(NULL, "__ZN10MobFactory9CreateMobEiR10TileSourceRK4Vec3PS2_");
    if (!createMob) createMob = (CreateMobFn)(slide + 0x10024dea0UL);
    AddMobFn addMob = (AddMobFn)MSFindSymbol(NULL, "__ZN10MobFactory6addMobER3Mobb");
    if (!addMob) addMob = (AddMobFn)(slide + 0x10024e25cUL);
    if (!createMob || !addMob || !mf) return;
    float px = *(float *)((char *)gLocalPlayer + 0x28);
    float py = *(float *)((char *)gLocalPlayer + 0x28 + 4);
    float pz = *(float *)((char *)gLocalPlayer + 0x28 + 8);
    float pos[3] = {px + 2.0f, py + 1.0f, pz};
    void *mob = createMob(typeId, ts, pos, NULL);
    int ok = mob ? addMob(mf, mob, 1) : -1;
    NSURL *logURL = [NSURL fileURLWithPath:@"/var/mobile/Documents/mowanbox.log"];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingToURL:logURL error:nil];
    if (fh) {
        [fh seekToEndOfFile];
        NSString *line = [NSString stringWithFormat:@"%@ [010刷怪] id=%d mob=%p add=%d\n",
                          [NSDate date], typeId, mob, ok];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
}

// 夜视: 0.10 无药水系统, 改游戏自家 gamma (Options+0x2D0, options.txt gfx_gamma 同字段)
// kuna 实锤: Options::update 取 a0[0xb4](即+0x2D0)做 %f 解析; MinecraftClient::init 把 Options* 存 MC+0x39(即+0x1C8)
// gamma 是光照表重算输入之一, 改它即触发重算+上传, 关时恢复原值(纯显示零 gameplay 副作用)
static float gSavedGamma010 = -1.0f;   // 首次开启时捕获的原值
static void *MWB010Options(void) {
    void *mc = MWB010Minecraft();
    if (!mc) return NULL;
    void *opt = *(void **)((char *)mc + 0x1C8);
    if ((uintptr_t)opt < 0x100000000UL || (uintptr_t)opt >= 0x400000000UL) return NULL;
    return opt;
}
void MWB010NightVisionTick(void) {
    if (gGV != (int)MWBGameV0_10) return;
    if (gNightVision) {
        void *opt = MWB010Options();
        if (!opt) return;
        float *g = (float *)((char *)opt + 0x2D0);
        if (gSavedGamma010 < -0.5f) {
            if (*g < 0.0f || *g > 2.0f) return;   // 读数离谱说明链不对, 直接停手不写
            gSavedGamma010 = *g;
            MWBLogFile(@"[010夜视] 捕获原 gamma=%.2f", gSavedGamma010);
        }
        *g = 5.0f;
    } else if (gSavedGamma010 > -0.5f) {
        void *opt = MWB010Options();
        if (!opt) return;
        float *g = (float *)((char *)opt + 0x2D0);
        if (*g < 0.0f || *g > 20.0f) return;
        *g = gSavedGamma010;
    }
}

// 穿墙验证: 原地垂直传送 dy 格(正=下埋/负=上浮); noclip 开则重力穿地直掉, 关则碰撞撑住
void MWB010Sink(int dy) {
    if (gGV != (int)MWBGameV0_10 || !gLocalPlayer || dy == 0) return;
    float px = *(float *)((char *)gLocalPlayer + 0x28);
    float py = *(float *)((char *)gLocalPlayer + 0x28 + 4);
    float pz = *(float *)((char *)gLocalPlayer + 0x28 + 8);
    if (MWB010Teleport(gLocalPlayer, px, py - dy, pz))
        MWBLogFile(@"[010下沉] 传送到 (%.1f,%.1f,%.1f)", px, py - dy, pz);
}

// 0.10 定点爆炸: Level::explode 在玩家脚下引爆 (威力 4.0 约 TNT 当量, 会伤及玩家, 建议开无敌再玩)
void MWB010Explode(void) {
    if (gGV != (int)MWBGameV0_10 || !gLevel || !gLocalPlayer) return;
    typedef void (*ExplodeFn)(void *, void *, float, float, float, float);
    ExplodeFn explode = (ExplodeFn)MSFindSymbol(NULL, "__ZN5Level7explodeEP6Entityffff");
    if (!explode) explode = (ExplodeFn)(MWBMainSlide() + 0x100112714UL);
    if (!explode) return;
    float px = *(float *)((char *)gLocalPlayer + 0x28);
    float py = *(float *)((char *)gLocalPlayer + 0x28 + 4);
    float pz = *(float *)((char *)gLocalPlayer + 0x28 + 8);
    explode(gLevel, gLocalPlayer, px, py, pz, 4.0f);
    NSLog(@"[魔玩盒子] 定点爆炸 (%.0f,%.0f,%.0f)", px, py, pz);
}
// ---- 小地图 (采样/着色/框体/刷新, 见 MWBMinimap.mm) ----


// 0.10 没有动态天气系统, 只有写过天气通道的版本才开放天气按钮
BOOL MWBWeatherSupported(void) {
    return gGV == (int)MWBGameV1_2_15 || gGV == (int)MWBGameV1_4_3 || gGV == (int)MWBGameV1_13_3;
}

// 反应核点燃与难度切换目前只接了 0.10 后端
BOOL MWB010Only(void) {
    return gGV == (int)MWBGameV0_10;
}

// 文件日志 (各版本安装函数共用)
void MWBLogFile(NSString *format, ...) {
    va_list args; va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], msg];
    NSURL *logURL = [NSURL fileURLWithPath:@"/var/mobile/Documents/mowanbox.log"];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingToURL:logURL error:nil];
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } else {
        NSError *e = nil;
        [line writeToURL:logURL atomically:YES encoding:NSUTF8StringEncoding error:&e];
    }
}
