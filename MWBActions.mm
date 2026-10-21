/* MWBActions.mm — 跨版本动作分发/flag通道/小地图/日志 */
#import "MWBCommon.h"
#import <UIKit/UIKit.h>
#import <stdarg.h>
#import "MWBUI.h"
#import "MWBMenu.h"
#import "MWBFloat.h"

#pragma mark - 跨版本动作分发

// flag文件通道 (绕过cycript两次调用上限: ssh touch /tmp/mwbcmd-<动作>[-<参数>] 即可触发)
// 支持: inv-0/1 fly break speed jump noclip night aura map debug time-0/1/2 weather-0/1/2/3
//       heal enchant give117-264 give143-264 effect143-16 teleport1133 fill5 reactor diff-0/1/2/3 mob-32 explode
//       dayinfo(0.10时间三值) light010(0.10门控+光照表只读) hitmenu blkreg1133 scaninv117 held117
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
        else if ([act isEqualToString:@"dayinfo"] && gLevel) {
            // 时间三值探针: 逻辑时间 / 天空覆写 / 亮度字节 (0.10 白天不亮诊断用)
            NSURL *lurl = [NSURL fileURLWithPath:@"/var/mobile/Documents/mowanbox.log"];
            NSFileHandle *lfh = [NSFileHandle fileHandleForWritingToURL:lurl error:nil];
            if (lfh) {
                [lfh seekToEndOfFile];
                int64_t dt = *(int64_t *)((char *)gLevel + LEVEL_TIME_OFFSET);
                int64_t ov = *(int64_t *)((char *)gLevel + LEVEL_TIME_OVERRIDE_OFF);
                uint8_t sky = *(uint8_t *)((char *)gLevel + 0x90);
                NSString *line = [NSString stringWithFormat:
                    @"%@ [010时间] dayTime=%lld override=%lld sky=%d mode=%d\n",
                    [NSDate date], (long long)dt, (long long)ov, sky, gTimeMode];
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
    if (gGV != (int)MWBGameV0_10 || !gLevel) return;
    if (difficulty < 0 || difficulty > 3) return;
    typedef void (*SetDifficultyFn)(void *, int);
    SetDifficultyFn setDifficulty =
        (SetDifficultyFn)MSFindSymbol(NULL, "__ZN11ServerLevel13setDifficultyEi");
    if (!setDifficulty) setDifficulty = (SetDifficultyFn)(MWBMainSlide() + 0x1001b8f7cUL);
    if (setDifficulty) setDifficulty(gLevel, difficulty);
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
// 小地图: 192x192 overlay (tag 0x6D62), 按48x48采样着色, 矿石标红
static UIColor *MWBMapColor(int blockId) {
    switch (blockId) {
        case 0: return [UIColor blackColor];
        case 1: return [UIColor grayColor];
        case 2: return [UIColor greenColor];
        case 3: return [UIColor brownColor];
        case 8: case 9: return [UIColor blueColor];
        case 12: return [UIColor yellowColor];
        case 17: return [UIColor darkGrayColor];
        case 18: return [UIColor colorWithRed:0.1 green:0.5 blue:0.1 alpha:1];
        case 14: case 15: return [UIColor orangeColor];
        case 56: return [UIColor cyanColor];
        case 73: return [UIColor redColor];
        default: return [UIColor darkGrayColor];
    }
}
void MWBMinimapShow(BOOL on) {
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (![NSStringFromClass([w class]) containsString:@"MWBOverlay"]) continue;
        UIView *old = [w viewWithTag:0x6D62];
        if (!on) { [old removeFromSuperview]; return; }
        if (old) return;
        UIImageView *iv = [[UIImageView alloc] initWithFrame:(CGRect){{8, 90}, {192, 192}}];
        iv.tag = 0x6D62;
        iv.layer.borderWidth = 3;
        iv.layer.borderColor = [UIColor blackColor].CGColor;
        [w addSubview:iv];
        return;
    }
}
void MWBMinimapRefresh(void) {
    if (!gMinimap || gGV != (int)MWBGameV1_13_3) return;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (![NSStringFromClass([w class]) containsString:@"MWBOverlay"]) continue;
        UIImageView *iv = (UIImageView *)[w viewWithTag:0x6D62];
        if (!iv) return;
        UIGraphicsImageRenderer *rr = [[UIGraphicsImageRenderer alloc] initWithSize:(CGSize){192, 192}];
        UIImage *img = [rr imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
            for (int z = 0; z < 48; z++)
                for (int x = 0; x < 48; x++) {
                    [MWBMapColor(gMiniMap1133[z * 48 + x]) setFill];
                    CGContextFillRect(ctx.CGContext, (CGRect){{(CGFloat)(x * 4), (CGFloat)(z * 4)}, {4, 4}});
                }
        }];
        dispatch_async(dispatch_get_main_queue(), ^{ iv.image = img; });
        return;
    }
}

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
