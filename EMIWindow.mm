/* EMIWindow.mm — EMI 主窗口 (配方/变体面板+创造栏窗口+网格+快捷栏) */
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import "EMI.h"
#import "EMIViews.h"
#import "EMIWindow.h"
#import "MWBUI.h"
#import "MWBCommon.h" // MWB010SpawnMob / MWB010Only（刷怪 tab）
#define kEMIMobTab 4    // 第 5 个 tab = 刷怪（不是物品分类）

#pragma mark - 配方查看面板 (长按物品弹出)

@interface MWBRecipePanel : UIView
@property (nonatomic, copy) void (^onClose)(void);
- (instancetype)initWithFrame:(CGRect)frame resultId:(int)resultId;
@end

@implementation MWBRecipePanel
// 物品小图标 (方块用立方体, 物品用平面图)
- (UIView *)iconForId:(int)itemId size:(CGFloat)sz center:(CGPoint)c {
    UIView *wrap = [[UIView alloc] initWithFrame:(CGRect){{c.x - sz/2, c.y - sz/2},{sz, sz}}];
    wrap.backgroundColor = [UIColor clearColor];
    wrap.userInteractionEnabled = NO;
    const MWBItemDef *def = MWBItemDefForId(itemId);
    if (!def) {
        UILabel *q = [[UILabel alloc] initWithFrame:wrap.bounds];
        q.text = @"?"; q.textAlignment = NSTextAlignmentCenter;
        q.font = [UIFont boldSystemFontOfSize:sz * 0.6];
        q.textColor = EMIColor(0x6b,0x66,0x68);
        [wrap addSubview:q];
        return wrap;
    }
    UIView *icon;
    if (def->isBlock) {
        MWBCubeView *cube = [[MWBCubeView alloc] initWithSize:sz];
        const char *top = def->topTile ?: def->tile;
        const char *front = def->frontTile ?: def->tile;
        const char *side = def->sideTile ?: def->tile;
        [cube setTopTile:[NSString stringWithUTF8String:top]
               frontTile:[NSString stringWithUTF8String:front]
                sideTile:[NSString stringWithUTF8String:side]
                topIndex:def->topTile ? def->topIdx : def->idx
              frontIndex:def->frontTile ? def->frontIdx : def->idx
               sideIndex:def->sideTile ? def->sideIdx : def->idx];
        icon = cube;
    } else {
        MWBItemIconView *iv = [[MWBItemIconView alloc] initWithSize:sz];
        [iv setItemTile:[NSString stringWithUTF8String:def->tile] index:def->idx];
        icon = iv;
    }
    icon.frame = wrap.bounds;
    [wrap addSubview:icon];
    return wrap;
}

// 一行材料标签 (图标下方 名称×数量)
- (UILabel *)ingLabel:(int)itemId count:(int)count frame:(CGRect)f {
    UILabel *l = [[UILabel alloc] initWithFrame:f];
    l.text = count > 1 ? [NSString stringWithFormat:@"%@×%d", MWBItemName(itemId), count] : MWBItemName(itemId);
    l.font = [UIFont systemFontOfSize:26 * kEMIScale];
    l.textAlignment = NSTextAlignmentCenter;
    l.textColor = EMIColor(0x34,0x31,0x32);
    return l;
}

- (instancetype)initWithFrame:(CGRect)frame resultId:(int)resultId {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
        CGFloat s = kEMIScale;

        // 从游戏 Recipes 单例读配方 (每条 = @[9格id数组, 产物数量])
        NSArray *recipes = MWBGameRecipesForItem(resultId);
        BOOL none = recipes.count == 0;
        NSString *name = MWBItemName(resultId);

        // 布局: 每条配方一行 = 3x3 九宫格 + 箭头 + 产物格
        CGFloat pw = 1180 * s;
        CGFloat cell = 108 * s;              // 九宫格格子尺寸
        CGFloat gridPad = 10 * s;            // 格子间距
        CGFloat gridW = 3 * cell + 2 * gridPad;
        CGFloat rowH = gridW + 60 * s;
        CGFloat titleH = 120 * s;
        CGFloat ph = titleH + (none ? 140 * s : (CGFloat)recipes.count * rowH + 30 * s) + 50 * s;
        UIView *panel = [[UIView alloc] initWithFrame:(CGRect){{(frame.size.width - pw) / 2, (frame.size.height - ph) / 2},{pw, ph}}];
        panel.backgroundColor = EMIColor(0xc8,0xc0,0xb8);
        panel.layer.borderWidth = 10 * s;
        panel.layer.borderColor = EMIColor(0x9c,0x91,0x89).CGColor;
        [self addSubview:panel];

        UILabel *title = [[UILabel alloc] initWithFrame:(CGRect){{40 * s, 16 * s},{pw - 80 * s, 70 * s}}];
        title.text = [NSString stringWithFormat:@"%@%@", name, MWBTr("recipe_of")];
        title.font = [UIFont boldSystemFontOfSize:44 * s];
        title.textColor = EMIColor(0x34,0x31,0x32);
        [panel addSubview:title];

        if (none) {
            UILabel *l = [[UILabel alloc] initWithFrame:(CGRect){{40 * s, titleH},{pw - 80 * s, 90 * s}}];
            l.text = MWBTr("recipe_none");
            l.font = [UIFont systemFontOfSize:34 * s];
            l.textColor = EMIColor(0x6b,0x66,0x68);
            [panel addSubview:l];
        }

        for (NSInteger rIdx = 0; rIdx < (NSInteger)recipes.count; rIdx++) {
            NSArray *entry = recipes[rIdx];
            NSArray *cells = entry[0];           // 9 个 id (0=空), 按行排列
            int rcount = [entry[1] intValue];
            CGFloat gy = titleH + rIdx * rowH + 30 * s;
            CGFloat gx = 70 * s;

            // 九宫格底板 (创造物品栏同款深灰)
            UIView *grid = [[UIView alloc] initWithFrame:(CGRect){{gx, gy},{gridW, gridW}}];
            grid.backgroundColor = EMIColor(0x8e,0x87,0x80);
            [panel addSubview:grid];

            for (int i = 0; i < 9; i++) {
                int cid = [cells[i] intValue];
                if (cid <= 0) continue;
                CGFloat cx = gx + (i % 3) * (cell + gridPad);
                CGFloat cy = gy + (i / 3) * (cell + gridPad);
                UIView *slot = [[UIView alloc] initWithFrame:(CGRect){{cx, cy},{cell, cell}}];
                slot.backgroundColor = EMIColor(0x3a,0x3a,0x39);
                slot.layer.borderWidth = 4 * s;
                slot.layer.borderColor = EMIColor(0x1b,0x1b,0x1a).CGColor;
                [panel addSubview:slot];
                [slot addSubview:[self iconForId:cid size:cell * 0.78 center:(CGPoint){cell / 2, cell / 2}]];
            }

            // 箭头
            CGFloat ax = gx + gridW + 50 * s;
            UILabel *arrow = [[UILabel alloc] initWithFrame:(CGRect){{ax, gy + gridW / 2 - 40 * s},{80 * s, 80 * s}}];
            arrow.text = @"→";
            arrow.font = [UIFont boldSystemFontOfSize:64 * s];
            arrow.textColor = EMIColor(0x34,0x31,0x32);
            [panel addSubview:arrow];

            // 产物格 (稍大, 数量标在角上)
            CGFloat rx = ax + 110 * s;
            CGFloat resSize = cell * 1.15;
            UIView *resSlot = [[UIView alloc] initWithFrame:(CGRect){{rx, gy + (gridW - resSize) / 2},{resSize, resSize}}];
            resSlot.backgroundColor = EMIColor(0x3a,0x3a,0x39);
            resSlot.layer.borderWidth = 4 * s;
            resSlot.layer.borderColor = EMIColor(0x1b,0x1b,0x1a).CGColor;
            [panel addSubview:resSlot];
            [resSlot addSubview:[self iconForId:resultId size:resSize * 0.78 center:(CGPoint){resSize / 2, resSize / 2}]];
            UILabel *cnt = [[UILabel alloc] initWithFrame:(CGRect){{resSize - 70 * s, resSize - 56 * s},{66 * s, 52 * s}}];
            cnt.text = [NSString stringWithFormat:@"×%d", rcount];
            cnt.font = [UIFont boldSystemFontOfSize:36 * s];
            cnt.textColor = [UIColor whiteColor];
            cnt.shadowColor = [UIColor blackColor];
            cnt.shadowOffset = (CGSize){2 * s, 2 * s};
            [resSlot addSubview:cnt];
        }

        UILabel *hint = [[UILabel alloc] initWithFrame:(CGRect){{0, ph - 38 * s},{pw, 32 * s}}];
        hint.text = MWBTr("recipe_hint");
        hint.font = [UIFont systemFontOfSize:24 * s];
        hint.textAlignment = NSTextAlignmentCenter;
        hint.textColor = EMIColor(0x9c,0x91,0x89);
        [panel addSubview:hint];

        // 点任意处关闭
        [self addGestureRecognizer:[[UITapGestureRecognizer alloc]
            initWithTarget:self action:@selector(dismiss)]];
    }
    return self;
}
- (void)dismiss {
    if (self.onClose) self.onClose();
}
@end

#pragma mark - 变体选择面板 (多变体物品单击弹出)

@interface MWBVariantPanel : UIView
@property (nonatomic, copy) void (^onClose)(void);
- (instancetype)initWithFrame:(CGRect)frame itemId:(int)itemId;
@end

@implementation MWBVariantPanel {
    int _itemId, _selAux;
    NSMutableArray<UIControl *> *_optBtns;
    UIControl *_giveOne, *_giveStack;
}
- (void)styleBtn:(UIControl *)b title:(NSString *)t selected:(BOOL)sel fontSize:(CGFloat)fs {
    CGFloat s = kEMIScale;
    b.backgroundColor = sel ? EMIColor(0xf1,0xeb,0xe5) : EMIColor(0xcf,0xc8,0xc1);
    b.layer.borderWidth = 5 * s;
    b.layer.borderColor = sel ? EMIColor(0x2c,0x76,0x07).CGColor : EMIColor(0x8e,0x85,0x7e).CGColor;
    UILabel *l = [b viewWithTag:1];
    if (!l) {
        l = [[UILabel alloc] initWithFrame:b.bounds];
        l.tag = 1; l.textAlignment = NSTextAlignmentCenter;
        l.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [b addSubview:l];
    }
    l.font = [UIFont systemFontOfSize:fs];
    l.textColor = EMIColor(0x34,0x31,0x32);
    l.text = t;
}
- (void)pickVariant:(UIControl *)b {
    _selAux = (int)b.tag;
    [self refreshVariantSelection];
}
- (void)refreshVariantSelection {
    for (UIControl *b in _optBtns)
        [self styleBtn:b title:MWBVariantName(_itemId, (int)b.tag) selected:((int)b.tag == _selAux) fontSize:30 * kEMIScale];
}
- (void)giveTapped:(UIControl *)b {
    int n = b.tag == 101 ? 64 : 1;
    MWBDLog(@"[EMI调试] 变体面板给予 %s id=%d aux=%d", b.tag == 101 ? "1组" : "1个", _itemId, _selAux);
    MWBGiveItem(_itemId, n, _selAux);
    if (self.onClose) self.onClose();
}
- (instancetype)initWithFrame:(CGRect)frame itemId:(int)itemId {
    if ((self = [super initWithFrame:frame])) {
        _itemId = itemId; _selAux = 0;
        _optBtns = [NSMutableArray new];
        CGFloat s = kEMIScale;

        // 背景层: 半透明 + 点击关闭 (面板加在其上, 互不干扰)
        UIControl *backdrop = [[UIControl alloc] initWithFrame:self.bounds];
        backdrop.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
        [backdrop addTarget:self action:@selector(dismiss) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:backdrop];

        int n = MWBVariantCount(itemId);
        int cols = n <= 4 ? n : (n <= 6 ? 3 : 8);
        int rows = (n + cols - 1) / cols;
        CGFloat cellW = 190 * s, cellH = 110 * s, gap = 16 * s;
        CGFloat pw = cols * (cellW + gap) + gap + 20 * s;
        CGFloat topH = 120 * s;
        CGFloat btnH = 100 * s;
        CGFloat ph = topH + rows * (cellH + gap) + btnH + 50 * s;
        UIView *panel = [[UIView alloc] initWithFrame:(CGRect){{(frame.size.width - pw) / 2, MAX(20 * s, (frame.size.height - ph) / 2)},{pw, ph}}];
        panel.backgroundColor = EMIColor(0xc8,0xc0,0xb8);
        panel.layer.borderWidth = 10 * s;
        panel.layer.borderColor = EMIColor(0x9c,0x91,0x89).CGColor;
        [self addSubview:panel];

        UILabel *title = [[UILabel alloc] initWithFrame:(CGRect){{30 * s, 20 * s},{pw - 60 * s, 70 * s}}];
        title.text = [NSString stringWithFormat:@"%@ · %@", MWBItemName(itemId), MWBTr("variant_sel")];
        title.font = [UIFont boldSystemFontOfSize:44 * s];
        title.textColor = EMIColor(0x34,0x31,0x32);
        [panel addSubview:title];

        for (int i = 0; i < n; i++) {
            UIControl *b = [[UIControl alloc] initWithFrame:(CGRect){{gap + (i % cols) * (cellW + gap), topH + (i / cols) * (cellH + gap)},{cellW, cellH}}];
            b.tag = i;
            [b addTarget:self action:@selector(pickVariant:) forControlEvents:UIControlEventTouchUpInside];
            [panel addSubview:b];
            [_optBtns addObject:b];
        }
        [self refreshVariantSelection];

        for (int i = 0; i < 2; i++) {
            UIControl *b = [[UIControl alloc] initWithFrame:(CGRect){{pw / 2 + (i == 0 ? -280 * s : 30 * s), ph - btnH - 26 * s},{250 * s, btnH}}];
            b.tag = 100 + i;
            [b addTarget:self action:@selector(giveTapped:) forControlEvents:UIControlEventTouchUpInside];
            [panel addSubview:b];
            [self styleBtn:b title:(i == 0 ? MWBTr("give1") : MWBTr("give64")) selected:NO fontSize:36 * s];
            if (i == 0) _giveOne = b; else _giveStack = b;
        }
    }
    return self;
}
@end

#pragma mark - EMI 主窗口

@implementation MWBEMIWindow {
    UIView *_tabStrip, *_gridWrap;
    UIScrollView *_gridScroll;
    NSArray<MWBEMITab *> *_tabs;
    int _currentCategory;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor clearColor];
        _currentCategory = 0;
        [self buildWindow];
    }
    return self;
}

// 背景点透: 透明边距不吞触摸, 与悬浮窗 overlay 一致 (面板/格子照常响应)
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self) return nil;
    return hit;
}

// 合并布局: 无内窗无边栏无快捷栏, 格子直接铺在菜单页上;
// 分类改顶部横排 (与菜单侧栏不再重叠), 关闭走菜单 Back/侧栏 (X 按钮已删)
- (void)buildWindow {
    CGFloat s = kEMIScale;
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height;

    _tabStrip = [[UIView alloc] initWithFrame:(CGRect){{0,0},{W,116*s}}];
    _tabStrip.backgroundColor = [UIColor clearColor];
    _tabStrip.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [self addSubview:_tabStrip];

    // 分类图标: 全部用游戏图集切 (与 0.10 分类对齐: 小麦种子/铁剑/书架/砖头,
    // 名出自游戏自带 terrain.meta/items.meta, 不手写坐标; 找不到回整图, 不崩)
    MWBItemIconView *seedsIcon = [[MWBItemIconView alloc] initWithSize:64*kEMIScale];
    [seedsIcon setItemTile:@"seeds_wheat" index:0];
    MWBItemIconView *swordIcon = [[MWBItemIconView alloc] initWithSize:64*kEMIScale];
    [swordIcon setItemTile:@"sword" index:2];   // 0木1石2铁: 铁剑
    MWBCubeView *shelfIcon = [[MWBCubeView alloc] initWithSize:64*kEMIScale];
    [shelfIcon setTopTile:@"planks" frontTile:@"bookshelf" sideTile:@"planks"
                 topIndex:0 frontIndex:0 sideIndex:0];
    MWBCubeView *brickIcon = [[MWBCubeView alloc] initWithSize:64*kEMIScale];
    [brickIcon setTopTile:@"brick" frontTile:@"brick" sideTile:@"brick"
                topIndex:0 frontIndex:0 sideIndex:0];
    // 第 5 个 tab：刷怪（刷怪蛋，items-opaque 第 192 行；从菜单第 5 项迁来，那里改成了 YSM 模型设置）
    UIImageView *eggIcon = [[UIImageView alloc] initWithImage:MWBGameIcon(@"items-opaque.png", (CGRect){{16,192},{16,16}})];
    eggIcon.frame = (CGRect){{0,0},{64*kEMIScale,64*kEMIScale}};
    eggIcon.contentMode = UIViewContentModeScaleAspectFit;
    eggIcon.layer.magnificationFilter = kCAFilterNearest;
    NSArray *icons = @[seedsIcon, swordIcon, shelfIcon, brickIcon, eggIcon];
    NSMutableArray *tabs = [NSMutableArray new];
    int nt = (int)icons.count;
    CGFloat gap = 10*s, tw = (W - gap * (nt + 1)) / nt, th = 100*s;
    for (int i = 0; i < nt; i++) {
        MWBEMITab *tab = [[MWBEMITab alloc] initWithIcon:icons[i]];
        tab.frame = (CGRect){{gap + i * (tw + gap),8*s},{tw,th}};
        tab.tag = i; tab.active = (i == 0);
        [tab addTarget:self action:@selector(switchTab:) forControlEvents:UIControlEventTouchUpInside];
        [_tabStrip addSubview:tab]; [tabs addObject:tab];
    }
    _tabs = tabs;

    CGFloat gy = 116*s + 8*s;
    _gridWrap = [[UIView alloc] initWithFrame:(CGRect){{0,gy},{W,H-gy}}];
    _gridWrap.backgroundColor = EMIColor(0x1a,0x1a,0x19);
    _gridWrap.layer.borderWidth = 8*s;
    _gridWrap.layer.borderColor = EMIColor(0x17,0x17,0x16).CGColor;
    _gridWrap.autoresizingMask = UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    [self addSubview:_gridWrap];

    _gridScroll = [[UIScrollView alloc] initWithFrame:_gridWrap.bounds];
    _gridScroll.tag = 999;
    _gridScroll.autoresizingMask = UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    _gridScroll.backgroundColor = [UIColor clearColor];
    _gridScroll.showsVerticalScrollIndicator = NO;
    // 格子点击立刻响应: 同悬浮窗菜单, 关滚动触摸延迟
    _gridScroll.delaysContentTouches = NO;
    [_gridWrap addSubview:_gridScroll];

    [self buildItemGrid];
}

#pragma mark - 物品网格

- (void)buildItemGrid {
    // 清空旧格子
    for (UIView *v in [_gridScroll.subviews copy]) [v removeFromSuperview];
    __weak typeof(self) ws = self;

    CGFloat s = kEMIScale;
    CGFloat cellSize = 159*s;
    // 列数随合并后的整宽自适应 (原来写死 10 列是按旧内窗 1590 宽算的)
    int cols = (int)(_gridScroll.bounds.size.width / cellSize);
    if (cols < 4) cols = 4;
    if (_currentCategory == kEMIMobTab) { [self buildMobGrid:cellSize cols:cols]; return; }
    NSMutableArray *visible = [NSMutableArray new];
    for (int i = 0; i < gItemCount; i++) {
        if (_currentCategory == 0 || gItems[i].category == _currentCategory)
            [visible addObject:@(i)];
    }
    int rows = ((int)visible.count + cols - 1) / cols;
    _gridScroll.contentSize = (CGSize){cols*cellSize, rows*cellSize};

    for (int i = 0; i < (int)visible.count; i++) {
        int defIdx = [visible[i] intValue];
        MWBItemDef def = gItems[defIdx];
        int r = i/cols, c = i%cols;
        MWBEMICell *cell = [[MWBEMICell alloc] initWithFrame:(CGRect){{c*cellSize,r*cellSize},{cellSize,cellSize}}];
        UIView *icon;
        CGFloat iconSize = cellSize*0.78;
        if (def.isBlock) {
            MWBCubeView *cube = [[MWBCubeView alloc] initWithSize:iconSize];
            const char *top = def.topTile ?: def.tile;
            const char *front = def.frontTile ?: def.tile;
            const char *side = def.sideTile ?: def.tile;
            [cube setTopTile:[NSString stringWithUTF8String:top]
                   frontTile:[NSString stringWithUTF8String:front]
                    sideTile:[NSString stringWithUTF8String:side]
                    topIndex:def.topTile ? def.topIdx : def.idx
                  frontIndex:def.frontTile ? def.frontIdx : def.idx
                   sideIndex:def.sideTile ? def.sideIdx : def.idx];
            icon = cube;
        } else {
            MWBItemIconView *iv = [[MWBItemIconView alloc] initWithSize:iconSize];
            [iv setItemTile:[NSString stringWithUTF8String:def.tile] index:def.idx];
            icon = iv;
        }
        cell.content = icon;
        NSString *cn = [NSString stringWithUTF8String:def.cnName];
        NSInteger stack = def.maxStack;
        NSInteger itemId = def.itemId;
        cell.onTap = ^{
            if (MWBVariantCount((int)itemId) > 0) {
                MWBDLog(@"[EMI调试] 单击 %@ (多变体, 打开选择面板)", cn);
                [ws showVariantForId:(int)itemId];
            } else {
                MWBDLog(@"[EMI调试] 单击 %@ (给予1个, id=%ld)", cn, (long)itemId);
                MWBGiveItem((int)itemId, 1, 0);
            }
        };
        cell.onDoubleTap = ^{
            MWBDLog(@"[EMI调试] 双击 %@ (给予%ld个, id=%ld)", cn, (long)stack, (long)itemId);
            MWBGiveItem((int)itemId, (int)stack, 0);
        };
        cell.onLongPress = ^{
            MWBDLog(@"[EMI调试] 长按 %@ (查看配方)", cn);
            [ws showRecipeForId:(int)itemId];
        };
        [_gridScroll addSubview:cell];
    }
}

// 刷怪 tab：15 个刷怪蛋，点按直调 MWB010SpawnMob 在玩家旁边刷怪（仅 0.10，其余版本置灰）
// 蛋序 ↔ 实体 id（MobFactory::CreateMob 实锤映射）：鸡/牛/猪/羊/狼/村民/哞菇/僵尸/爬行者/骷髅/蜘蛛/猪人/史莱姆/末影人/蠹虫
- (void)buildMobGrid:(CGFloat)cellSize cols:(int)cols {
    static const int kMobIds[15] = {10, 11, 12, 13, 14, 15, 16, 32, 33, 34, 35, 36, 37, 38, 39};
    int rows = (15 + cols - 1) / cols;
    _gridScroll.contentSize = (CGSize){cols*cellSize, rows*cellSize};
    BOOL ok = MWB010Only();
    for (int i = 0; i < 15; i++) {
        int r = i / cols, c = i % cols;
        MWBEMICell *cell = [[MWBEMICell alloc] initWithFrame:(CGRect){{c*cellSize,r*cellSize},{cellSize,cellSize}}];
        UIView *box = [[UIView alloc] initWithFrame:(CGRect){{0,0},{cellSize*0.78,cellSize*0.78}}];
        UIImageView *egg = [[UIImageView alloc] initWithImage:MWBGameIcon(@"items-opaque.png",
            (CGRect){{(CGFloat)(16 + (i + 1) * 16), 192},{16,16}})];
        egg.frame = (CGRect){{box.bounds.size.width*0.15,0},{box.bounds.size.width*0.7,box.bounds.size.width*0.7}};
        egg.contentMode = UIViewContentModeScaleAspectFit;
        egg.layer.magnificationFilter = kCAFilterNearest;
        [box addSubview:egg];
        UILabel *nm = [[UILabel alloc] initWithFrame:(CGRect){{0,box.bounds.size.height*0.72},{box.bounds.size.width,box.bounds.size.height*0.28}}];
        nm.text = MWBTr([NSString stringWithFormat:@"egg%d", i].UTF8String);
        nm.font = [UIFont systemFontOfSize:cellSize*0.13];
        nm.adjustsFontSizeToFitWidth = YES; nm.minimumScaleFactor = 0.6;
        nm.textColor = EMIColor(0xcf,0xcc,0xc6);
        nm.textAlignment = NSTextAlignmentCenter;
        [box addSubview:nm];
        cell.content = box;
        if (!ok) { cell.alpha = 0.35; cell.userInteractionEnabled = NO; }
        int mid = kMobIds[i];
        NSString *name = nm.text;
        cell.onTap = ^{ MWB010SpawnMob(mid); MWBDLog(@"[EMI] 刷怪 %@ id=%d", name, mid); };
        [_gridScroll addSubview:cell];
    }
}

#pragma mark - 交互

- (void)switchTab:(MWBEMITab *)sender {
    for (MWBEMITab *t in _tabs) t.active = NO;
    sender.active = YES;
    _currentCategory = (int)sender.tag;
    NSLog(@"[EMI] 切换分类 %d", _currentCategory);
    [self buildItemGrid];
}
- (void)close { if (self.onClose) self.onClose(); }
- (void)showInView:(UIView *)view {
    // 第三项打开动画已去: 直接贴上, 无缩放无淡入 (关闭动画保留不动)
    self.frame = view.bounds; [view addSubview:self];
    self.alpha = 1; self.transform = CGAffineTransformIdentity;
}
- (void)hide {
    [UIView animateWithDuration:0.12 animations:^{
        self.alpha = 0; self.transform = CGAffineTransformMakeScale(0.95, 0.95);
    } completion:^(BOOL f){ [self removeFromSuperview]; }];
}

#pragma mark - 配方查看

- (void)showRecipeForId:(int)itemId {
    MWBRecipePanel *p = [[MWBRecipePanel alloc] initWithFrame:self.bounds resultId:itemId];
    __weak typeof(self) ws = self;
    __weak MWBRecipePanel *wp = p;
    p.onClose = ^{ [ws finishedWithPanel:wp]; };
    [self addSubview:p];
}

#pragma mark - 变体选择

- (void)showVariantForId:(int)itemId {
    MWBVariantPanel *p = [[MWBVariantPanel alloc] initWithFrame:self.bounds itemId:itemId];
    __weak typeof(self) ws = self;
    __weak MWBVariantPanel *wp = p;
    p.onClose = ^{ [ws finishedWithPanel:wp]; };
    [self addSubview:p];
}
// 面板关闭回调 (异步, 避免在手势回调栈里移除视图)
- (void)finishedWithPanel:(UIView *)p {
    [p removeFromSuperview];
}
@end
