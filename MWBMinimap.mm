/* MWBMinimap.mm — 小地图 (0.10 表面扫描/洞穴视角/原版风着色/羊皮纸框/夜暗/转向箭头 + 1133 单层采样显示) */
#import "MWBCommon.h"
#import <UIKit/UIKit.h>
#import "MWBUI.h"

#pragma mark - 小地图拖动 (位置记忆, 存自家 Documents/mwbminimap.plist, 与游戏存档无关)

static NSString *MWBMinimapPrefPath(void) {
    return @"/var/mobile/Documents/mwbminimap.plist";
}

@interface MWBMinimapDragHelper : NSObject
+ (instancetype)shared;
- (void)handlePan:(UIPanGestureRecognizer *)pan;
@end

@implementation MWBMinimapDragHelper
+ (instancetype)shared {
    static MWBMinimapDragHelper *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[self alloc] init]; });
    return inst;
}
- (void)handlePan:(UIPanGestureRecognizer *)pan {
    UIView *box = pan.view;
    if (!box) return;
    if (pan.state == UIGestureRecognizerStateChanged) {
        CGPoint t = [pan translationInView:box.superview];
        CGPoint c = box.center;
        c.x += t.x; c.y += t.y;
        // 钳制在父窗口内, 半个框都不许出屏
        UIView *sup = box.superview;
        if (sup) {
            CGFloat hw = box.bounds.size.width / 2, hh = box.bounds.size.height / 2;
            c.x = MAX(hw, MIN(sup.bounds.size.width - hw, c.x));
            c.y = MAX(hh, MIN(sup.bounds.size.height - hh, c.y));
        }
        box.center = c;
        [pan setTranslation:CGPointZero inView:box.superview];
    } else if (pan.state == UIGestureRecognizerStateEnded ||
               pan.state == UIGestureRecognizerStateCancelled) {
        // 松手落盘, 下次开小地图回到这次的位置
        NSMutableDictionary *d = [NSMutableDictionary new];
        d[@"x"] = @(box.frame.origin.x);
        d[@"y"] = @(box.frame.origin.y);
        [d writeToURL:[NSURL fileURLWithPath:MWBMinimapPrefPath()] atomically:YES];
    }
}
@end

// 0.10 小地图采样: 以玩家为中心 48x48, 每列从 y=127 往下找首个非空方块
// 读块走 TileSource::getTile (kuna 反编译: id 经隐藏首参回写, y>=128 回默认)
// TileSource::getTile 用 C++ sret 传回 (x8=回写地址, x0=this, x1=pos),
// 普通 C 调用放错寄存器会崩 (-79 教训), 必须手写 x8
// (kuna 反调用点实锤: add x8,sp,#..; mov x0,ts; mov x1,pos; bl)
// (渲染线程也调: 只读世界, 安全; 穿墙近平面判断共用, 见 MWBHooks010)
uint8_t MWB010GetTile(void *ts, MWBBlockPos *pos) {
    static void *fn = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fn = MSFindSymbol(NULL, "__ZN10TileSource7getTileERK7TilePos");
        if (!fn) fn = (void *)(MWBMainSlide() + 0x100102128UL);
    });
    uint8_t outbuf[16] = {0};
    if (!fn || !ts || !pos) return 0;
    register void *r0 __asm__("x0") = ts;
    register void *r1 __asm__("x1") = pos;
    register void *r8 __asm__("x8") = outbuf;
    __asm__ volatile (
        "blr %[fn]\n"
        : "+r" (r0), "+r" (r1), "+r" (r8)
        : [fn] "r" (fn)
        : "memory", "cc", "x2", "x3", "x4", "x5", "x6", "x7",
          "x9", "x10", "x11", "x12", "x13", "x14", "x15", "x16", "x17");
    return outbuf[0];
}
// 洞穴判定: 头顶到天空有无遮挡 (树叶/玻璃/水/雪不算遮挡)
static BOOL MWB010HasSky(void *ts, int x, int y, int z) {
    for (int yy = y + 2; yy <= 127; yy++) {
        MWBBlockPos bp = {x, yy, z};
        uint8_t c = MWB010GetTile(ts, &bp);
        if (c != 0 && c != 20 && c != 78 && c != 18 && c != 8 && c != 9) return NO;
    }
    return YES;
}
static BOOL gMiniMapCave010 = NO;   // 当前是否洞穴视角 (边框颜色/日志用)
int MWB010_SampleMinimap(void) {
    if (gGV != (int)MWBGameV0_10 || !gLocalPlayer) return -1;
    void *ts = *(void **)((char *)gLocalPlayer + 0x48);
    if (!ts) return -1;
    float px = *(float *)((char *)gLocalPlayer + 0x28);
    float py = *(float *)((char *)gLocalPlayer + 0x28 + 4);
    float pz = *(float *)((char *)gLocalPlayer + 0x28 + 8);
    int cx = (int)floorf(px), cz = (int)floorf(pz), cy = (int)floorf(py);
    BOOL sky = MWB010HasSky(ts, cx, cy, cz);
    if (sky != !gMiniMapCave010) {
        gMiniMapCave010 = !sky;
        MWBLogFile(@"[010小地图] 视角切换: %@", gMiniMapCave010 ? @"洞穴" : @"表面");
    }
    int air = 0;
    for (int dz = -24; dz < 24; dz++) {
        for (int dx = -24; dx < 24; dx++) {
            int id = 0, sy = 0, depth = 0;
            if (gMiniMapCave010) {
                // 洞穴视角: 取眼睛高度层, 空气则往下找8格内地板 (矿道=空气路+石头墙, 矿石可见)
                for (int y = cy + 2; y >= cy - 8 && y >= 0; y--) {
                    MWBBlockPos bp = {cx + dx, y, cz + dz};
                    uint8_t cur = MWB010GetTile(ts, &bp);
                    if (cur == 0 || cur == 20 || cur == 78) continue;
                    id = cur; sy = y;
                    break;
                }
            } else
            for (int y = 127; y >= 0; y--) {
                MWBBlockPos bp = {cx + dx, y, cz + dz};
                uint8_t cur = MWB010GetTile(ts, &bp);
                if (cur == 0 || cur == 20 || cur == 78) {  // 空气/玻璃/雪层: 透过去
                    if (y == 0) air++;
                    continue;
                }
                id = cur; sy = y;
                if (cur == 8 || cur == 9) {  // 水: 继续往下量水深 (最多12)
                    for (int d = 1; d <= 12 && y - d >= 0; d++) {
                        MWBBlockPos bd = {cx + dx, y - d, cz + dz};
                        uint8_t c2 = MWB010GetTile(ts, &bd);
                        if (c2 == 8 || c2 == 9) depth++;
                        else break;
                    }
                }
                break;
            }
            int i = (dz + 24) * 48 + (dx + 24);
            gMiniMap010[i] = (uint8_t)(id & 0xFF);
            gMiniMap010H[i] = (uint8_t)(sy & 0xFF);
            gMiniMap010D[i] = (uint8_t)(depth & 0xFF);
        }
    }
    return air;
}

// 史莱姆区块判定: 复刻游戏 Slime::canSpawn@0x10021382c 区块分支
// chunkHash=(chunkX*0x1F1F1F1F)^chunkZ(不掺世界种子) → MT19937 重播种 → 首输出%10==0
// 游戏 Random 即标准 MT19937 (乘子 0x6c078965=1812433253, 状态624, 反编译 init 循环实锤)
static uint32_t sMT010[624];
static void MWBMTSeed010(uint32_t s) {
    sMT010[0] = s;
    for (int i = 1; i < 624; i++)
        sMT010[i] = 1812433253U * (sMT010[i - 1] ^ (sMT010[i - 1] >> 30)) + (uint32_t)i;
}
// 新种子后首次 genrand_int32: 整表 twist 一次 + 取首输出 temper (标准 MT19937)
static uint32_t MWBMTNext010(void) {
    for (int i = 0; i < 624; i++) {
        uint32_t y = (sMT010[i] & 0x80000000U) | (sMT010[(i + 1) % 624] & 0x7fffffffU);
        sMT010[i] = sMT010[(i + 397) % 624] ^ (y >> 1);
        if (y & 1U) sMT010[i] ^= 0x9908b0dfU;
    }
    uint32_t y = sMT010[0];
    y ^= (y >> 11);
    y ^= (y << 7) & 0x9d2c5680U;
    y ^= (y << 15) & 0xefc60000U;
    y ^= (y >> 18);
    return y;
}
BOOL MWBIsSlimeChunk(int chunkX, int chunkZ) {
    // 与游戏一致: (int)截断取整后再算术右移 (同 arch/同编译器, 语义相同)
    uint32_t h = (uint32_t)((int32_t)chunkX * (int32_t)0x1f1f1f1f) ^ (uint32_t)chunkZ;
    MWBMTSeed010(h);
    return MWBMTNext010() % 10 == 0;
}

// 原版地图风配色 (Map Atlases 即原版渲染): 方块基色 x 明暗(255/220/180) , 水按深度加深
static UIColor *MWBMapVanilla(int blockId, int depth, float shade) {
    CGFloat r = 128, g = 128, b = 128;
    switch (blockId) {
        case 0: r = 0; g = 0; b = 0; break;                        // 未知/虚空: 黑
        case 1: case 4: case 7: case 14: case 15: case 16:         // 石/圆石/基岩/矿石: 石灰
        case 21: case 56: case 73: case 129: r = 128; g = 128; b = 128; break;
        case 2: r = 127; g = 178; b = 56; break;                  // 草方块
        case 3: r = 134; g = 96; b = 67; break;                   // 泥土
        case 5: case 53: r = 168; g = 126; b = 46; break;         // 木板/楼梯
        case 12: case 24: r = 219; g = 207; b = 163; break;       // 沙/砂岩
        case 8: case 9: {                                         // 水: 深加深
            float dk = 1.0f - MIN(depth, 10) * 0.06f;
            r = 56 * dk; g = 93 * dk; b = 201 * dk; break; }
        case 17: r = 102; g = 81; b = 50; break;                  // 原木
        case 18: r = 48; g = 116; b = 40; break;                  // 树叶
        case 35: r = 220; g = 220; b = 220; break;                // 羊毛
        case 41: r = 250; g = 238; b = 77; break;                 // 金块
        case 42: r = 230; g = 230; b = 230; break;                // 铁块
        case 46: r = 220; g = 60; b = 20; break;                 // TNT
        case 57: r = 93; g = 236; b = 231; break;                 // 钻石块
        case 79: r = 200; g = 225; b = 235; break;                // 冰
        case 80: r = 240; g = 245; b = 245; break;                // 雪块
        default: r = 128; g = 128; b = 128; break;
    }
    return [UIColor colorWithRed:r/255.0*shade green:g/255.0*shade blue:b/255.0*shade alpha:1];
}

// ---- 0.10 小地图 Map Atlases 风格 (A: 采样只动 0.10, 框/坐标行为全版本共用, 1.13.3 像素仍走旧糖果色) ----
// 框 = 羊皮纸底(代码手绘毛边感, 不拷 Map Atlases 原贴图, 避版权)+ 内图 192 + 下方坐标行; 洞穴切深蓝边框
#define MWB_MAP_IMG 192
#define MWB_MAP_PAD 8
#define MWB_MAP_BOX (MWB_MAP_IMG + MWB_MAP_PAD * 2)   // 208
static UIColor *MWBMapParchment(void) { return MWB_COLOR(0xE8, 0xD9, 0xA6); }
static UIColor *MWBMapFrameBrown(void) { return MWB_COLOR(0x5A, 0x45, 0x2A); }
static UIColor *MWBMapFrameCave(void) { return MWB_COLOR(0x2E, 0x3E, 0x55); }

// 夜晚变暗: 原版地图/Map Atlases 本身不分昼夜(同图); 这里按 Level+0x90 天空字节自乘变暗, 纯显示不碰游戏
// 实测: 白天 sky=0, 夜里 sky=10~11(与"亮度"字面反直觉, 以真机为准), 故 sky 越大越暗
static float MWBMinimapNightDim(void) {
    if (gGV != (int)MWBGameV0_10 || !gLevel) return 1.0f;
    int sky = *(uint8_t *)((char *)gLevel + 0x90);
    if (sky < 0) sky = 0;
    if (sky > 11) sky = 11;
    return 1.0f - 0.38f * ((float)sky / 11.0f);
}
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
        // 容器: 羊皮纸底 + 内图 + 坐标行 (A 只改 0.10 采样, 框体全版本共用)
        UIView *box = [[UIView alloc] initWithFrame:(CGRect){{8, 90}, {MWB_MAP_BOX, MWB_MAP_BOX + 24}}];
        // 恢复上次拖放位置 (无记录/越界则保持默认左上)
        {
            NSURL *u = [NSURL fileURLWithPath:MWBMinimapPrefPath()];
            NSError *e = nil;
            NSDictionary *ro = [NSDictionary dictionaryWithContentsOfURL:u error:&e];
            if ([ro isKindOfClass:[NSDictionary class]]) {
                CGFloat px = [ro[@"x"] floatValue], py = [ro[@"y"] floatValue];
                CGFloat bw = w.bounds.size.width, bh = w.bounds.size.height;
                if (px >= 0 && py >= 0 && px + MWB_MAP_BOX <= bw && py + MWB_MAP_BOX + 24 <= bh)
                    box.frame = (CGRect){{px, py}, {MWB_MAP_BOX, MWB_MAP_BOX + 24}};
            }
        }
        // 整框可拖: 子视图默认不吃触摸 (iv/label 的 userInteractionEnabled=NO), 手势落框上即走
        [box addGestureRecognizer:[[UIPanGestureRecognizer alloc]
            initWithTarget:[MWBMinimapDragHelper shared] action:@selector(handlePan:)]];
        box.tag = 0x6D62;
        box.backgroundColor = MWBMapParchment();
        box.layer.borderWidth = 3;
        box.layer.borderColor = MWBMapFrameBrown().CGColor;
        box.layer.cornerRadius = 3;
        box.clipsToBounds = YES;
        UIImageView *iv = [[UIImageView alloc] initWithFrame:(CGRect){{MWB_MAP_PAD, MWB_MAP_PAD}, {MWB_MAP_IMG, MWB_MAP_IMG}}];
        iv.tag = 0x6D63;
        iv.layer.borderWidth = 1;
        iv.layer.borderColor = MWBMapFrameBrown().CGColor;
        [box addSubview:iv];
        // 北指示: 压在地图右上角内侧(白字黑边, 地图上才看得清), 地图永远北朝上转的是箭头
        UILabel *n = [[UILabel alloc] initWithFrame:(CGRect){{MWB_MAP_PAD + MWB_MAP_IMG - 24, MWB_MAP_PAD + 2}, {20, 20}}];
        n.tag = 0x6D66;
        n.textAlignment = NSTextAlignmentCenter;
        n.attributedText = MWBPixelText(@"N", MWBPixelFont(18), [UIColor whiteColor],
                                       1, 1, [UIColor blackColor]);
        [box addSubview:n];
        // 坐标行 (Map Atlases HUD 同款: x, y, z 居中, 字随框走; 16号字防"1888, 89, -27+yaw"截断)
        UILabel *c = [[UILabel alloc] initWithFrame:(CGRect){{4, MWB_MAP_BOX}, {MWB_MAP_BOX - 8, 20}}];
        c.tag = 0x6D64;
        c.textAlignment = NSTextAlignmentCenter;
        c.attributedText = MWBPixelText(@"-, -, -", MWBPixelFont(16), MWB_COLOR(0x3A, 0x2E, 0x1E),
                                       1, 1, MWB_COLOR(0xFF, 0xFB, 0xE6));
        [box addSubview:c];
        [w addSubview:box];
        return;
    }
}
void MWBMinimapRefresh(void) {
    if (!gMinimap) return;
    BOOL is010 = (gGV == (int)MWBGameV0_10);
    if (!is010 && gGV != (int)MWBGameV1_13_3) return;
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (![NSStringFromClass([w class]) containsString:@"MWBOverlay"]) continue;
        UIView *box = [w viewWithTag:0x6D62];
        if (!box) return;
        UIImageView *iv = (UIImageView *)[box viewWithTag:0x6D63];
        if (!iv) return;   // 老版本遗留的整块 UIImageView: 下次开关重建即为新框
        UILabel *coords = (UILabel *)[box viewWithTag:0x6D64];
        float nightDim = is010 ? MWBMinimapNightDim() : 1.0f;
        float yawDeg = 0;
        float fpx = 0, fpz = 0;
        if (is010 && gLocalPlayer) {
            yawDeg = *(float *)((char *)gLocalPlayer + ENTITY_YAW_OFF);
            fpx = *(float *)((char *)gLocalPlayer + 0x28);
            fpz = *(float *)((char *)gLocalPlayer + 0x28 + 8);
        }
        // 史莱姆区块叠加: 48x48 最多跨 4x4=16 个区块, 每区块判定一次 (逐格算 MT 太贵);
        // 取整与游戏一致用 (int)截断 (canSpawn 内即 (int)强转, 非 floor)
        int slimeCC[16][2]; int slimeN = 0;
        int pcx = 0, pcz = 0, itx = 0, itz = 0;
        if (is010 && gSlimeChunk && gLocalPlayer) {
            itx = (int)fpx; itz = (int)fpz;
            pcx = itx >> 4; pcz = itz >> 4;
            int x0 = (itx - 24) >> 4, x1 = (itx + 23) >> 4;
            int z0 = (itz - 24) >> 4, z1 = (itz + 23) >> 4;
            for (int ccx = x0; ccx <= x1 && slimeN < 16; ccx++)
                for (int ccz = z0; ccz <= z1 && slimeN < 16; ccz++)
                    if (MWBIsSlimeChunk(ccx, ccz)) {
                        slimeCC[slimeN][0] = ccx; slimeCC[slimeN][1] = ccz;
                        slimeN++;
                    }
        }
        // block 内不可引用 C 数组: 预压成像素矩形(堆上, block 同步执行完即 free)
        int *slimePx = NULL;
        if (slimeN > 0) {
            slimePx = (int *)malloc((size_t)slimeN * 4 * sizeof(int));
            if (slimePx) {
                for (int k = 0; k < slimeN; k++) {
                    int lx0 = slimeCC[k][0] * 16 - (itx - 24);
                    int lz0 = slimeCC[k][1] * 16 - (itz - 24);
                    int lx1 = lx0 + 16, lz1 = lz0 + 16;
                    if (lx0 < 0) lx0 = 0; if (lz0 < 0) lz0 = 0;
                    if (lx1 > 48) lx1 = 48; if (lz1 > 48) lz1 = 48;
                    slimePx[k * 4] = lx0; slimePx[k * 4 + 1] = lz0;
                    slimePx[k * 4 + 2] = lx1; slimePx[k * 4 + 3] = lz1;
                }
            }
        }
        uint8_t *map = is010 ? gMiniMap010 : gMiniMap1133;
        UIGraphicsImageRenderer *rr = [[UIGraphicsImageRenderer alloc] initWithSize:(CGSize){MWB_MAP_IMG, MWB_MAP_IMG}];
        UIImage *img = [rr imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
            for (int z = 0; z < 48; z++)
                for (int x = 0; x < 48; x++) {
                    if (is010) {
                        // 原版地图式明暗: 与北邻比高, 上坡亮/下坡暗/等高常
                        // (Map Atlases 即原版渲染; 亮度系数 255/220/180 原版值, 再乘夜晚系数)
                        int i = z * 48 + x;
                        int hN = (z > 0) ? gMiniMap010H[i - 48] : gMiniMap010H[i];
                        int dh = (int)gMiniMap010H[i] - hN;
                        float shade = dh > 0 ? 1.0f : (dh < 0 ? 180.0f/255.0f : 220.0f/255.0f);
                        [MWBMapVanilla(gMiniMap010[i], gMiniMap010D[i], shade * nightDim) setFill];
                    } else {
                        [MWBMapColor(map[z * 48 + x]) setFill];
                    }
                    CGContextFillRect(ctx.CGContext, (CGRect){{(CGFloat)(x * 4), (CGFloat)(z * 4)}, {4, 4}});
                }
            if (slimePx) {
                // 史莱姆区块: 半透明绿罩 + 亮绿边框 (矩形已压到 48x48 图内)
                CGContextRef c2 = ctx.CGContext;
                CGContextSetFillColorWithColor(c2, [UIColor colorWithRed:0.2 green:1.0 blue:0.3 alpha:0.30].CGColor);
                for (int k = 0; k < slimeN; k++) {
                    int lx0 = slimePx[k * 4], lz0 = slimePx[k * 4 + 1];
                    int lx1 = slimePx[k * 4 + 2], lz1 = slimePx[k * 4 + 3];
                    CGContextFillRect(c2, (CGRect){{(CGFloat)(lx0 * 4), (CGFloat)(lz0 * 4)},
                                                  {(CGFloat)((lx1 - lx0) * 4), (CGFloat)((lz1 - lz0) * 4)}});
                }
                CGContextSetStrokeColorWithColor(c2, [UIColor colorWithRed:0.3 green:1.0 blue:0.3 alpha:0.95].CGColor);
                CGContextSetLineWidth(c2, 2.0f);
                for (int k = 0; k < slimeN; k++) {
                    int lx0 = slimePx[k * 4], lz0 = slimePx[k * 4 + 1];
                    int lx1 = slimePx[k * 4 + 2], lz1 = slimePx[k * 4 + 3];
                    CGContextStrokeRect(c2, (CGRect){{(CGFloat)(lx0 * 4), (CGFloat)(lz0 * 4)},
                                                    {(CGFloat)((lx1 - lx0) * 4), (CGFloat)((lz1 - lz0) * 4)}});
                }
            }
            if (is010) {
                // 玩家箭头: 北朝上, 按 yaw 旋转; 真机标定: yaw=0朝南增量顺时针(Java 同款),
                // 屏角(视觉顺时针从正北)=(180+yaw), 经 4 组真机截图+程序量角闭环 (39/155/31/275 全对上)
                CGContextRef c = ctx.CGContext;
                CGContextSaveGState(c);
                CGContextTranslateCTM(c, 96, 96);
                CGContextRotateCTM(c, yawDeg * 3.14159265f / 180.0f + 3.14159265f);
                CGContextBeginPath(c);
                CGContextMoveToPoint(c, 0, -8);
                CGContextAddLineToPoint(c, 6, 6);
                CGContextAddLineToPoint(c, -6, 6);
                CGContextClosePath(c);
                CGContextSetFillColorWithColor(c, [UIColor whiteColor].CGColor);
                CGContextFillPath(c);
                CGContextBeginPath(c);
                CGContextMoveToPoint(c, 0, -8);
                CGContextAddLineToPoint(c, 6, 6);
                CGContextAddLineToPoint(c, -6, 6);
                CGContextClosePath(c);
                CGContextSetStrokeColorWithColor(c, [UIColor blackColor].CGColor);
                CGContextSetLineWidth(c, 1.5f);
                CGContextStrokePath(c);
                CGContextRestoreGState(c);
            }
        }];
        if (slimePx) { free(slimePx); slimePx = NULL; }   // block 已同步执行完
        int px = 0, py = 0, pz = 0;
        if (is010 && gLocalPlayer) {
            px = (int)floorf(*(float *)((char *)gLocalPlayer + 0x28));
            py = (int)floorf(*(float *)((char *)gLocalPlayer + 0x28 + 4));
            pz = (int)floorf(*(float *)((char *)gLocalPlayer + 0x28 + 8));
        } else if (!is010 && gPlayer1133) {
            px = (int)floorf(*(float *)((char *)gPlayer1133 + 0x41C));
            py = (int)floorf(*(float *)((char *)gPlayer1133 + 0x41C + 4));
            pz = (int)floorf(*(float *)((char *)gPlayer1133 + 0x41C + 8));
        }
        BOOL inSlime = (is010 && gSlimeChunk && gLocalPlayer) ? MWBIsSlimeChunk(pcx, pcz) : NO;
        NSString *pos = [NSString stringWithFormat:@"%d, %d, %d%@%@", px, py, pz,
                         (is010 && gMiniMapCave010) ? MWBTr("cave_tag") : @"",
                         inSlime ? @"·史" : @""];
        if (is010 && gMWBDebug) pos = [pos stringByAppendingFormat:@" yaw%.0f", yawDeg];
        dispatch_async(dispatch_get_main_queue(), ^{
            iv.image = img;
            if (coords) coords.attributedText = MWBPixelText(pos, MWBPixelFont(16), MWB_COLOR(0x3A, 0x2E, 0x1E),
                                                             1, 1, MWB_COLOR(0xFF, 0xFB, 0xE6));
            box.layer.borderColor = (is010 && gMiniMapCave010)
                ? MWBMapFrameCave().CGColor : MWBMapFrameBrown().CGColor;
        });
        return;
    }
}
