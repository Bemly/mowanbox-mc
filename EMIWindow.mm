/* EMIWindow.mm — EMI 主窗口 (配方/变体面板+创造栏窗口+网格+快捷栏) */
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import "EMI.h"
#import "EMIViews.h"
#import "EMIWindow.h"

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
        title.text = [NSString stringWithFormat:@"%@ 的配方", name];
        title.font = [UIFont boldSystemFontOfSize:44 * s];
        title.textColor = EMIColor(0x34,0x31,0x32);
        [panel addSubview:title];

        if (none) {
            UILabel *l = [[UILabel alloc] initWithFrame:(CGRect){{40 * s, titleH},{pw - 80 * s, 90 * s}}];
            l.text = @"游戏配方中没有能合成该物品的配方 (自然生成 / 怪物掉落)";
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
        hint.text = @"轻触任意处关闭";
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
        title.text = [NSString stringWithFormat:@"%@ · 选择变种", MWBItemName(itemId)];
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
            [self styleBtn:b title:(i == 0 ? @"给 1 个" : @"给 1 组") selected:NO fontSize:36 * s];
            if (i == 0) _giveOne = b; else _giveStack = b;
        }
    }
    return self;
}
@end

#pragma mark - EMI 主窗口

@implementation MWBEMIWindow {
    UIView *_window, *_rail, *_gridWrap;
    UIScrollView *_gridScroll;
    UIView *_hotbar;
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

- (void)buildWindow {
    CGFloat s = kEMIScale;
    CGFloat winW = 1879*s, winH = 923*s;
    CGFloat winX = (self.bounds.size.width-winW)/2;
    CGFloat winY = (self.bounds.size.height-winH-139*s)/2;
    _window = [[UIView alloc] initWithFrame:(CGRect){{winX,winY},{winW,winH}}];
    _window.backgroundColor = EMIColor(0xc8,0xc0,0xb8);
    _window.layer.borderWidth = 10*s;
    _window.layer.borderColor = EMIColor(0x9c,0x91,0x89).CGColor;
    _window.layer.shadowColor = [UIColor blackColor].CGColor;
    _window.layer.shadowOffset = (CGSize){8*s, 8*s};
    _window.layer.shadowRadius = 0; _window.layer.shadowOpacity = 0.28;
    [self addSubview:_window];
    [self addInsetShadow:_window light:EMIColor(0xe7,0xe0,0xda) dark:EMIColor(0x7f,0x77,0x70)
                   lightW:8 darkW:9];

    _rail = [[UIView alloc] initWithFrame:(CGRect){{6*s,20*s},{165*s,878*s}}];
    [_window addSubview:_rail];

    UIControl *closeBtn = [self makeCloseButton];
    closeBtn.frame = (CGRect){{24*s,0},{132*s,120*s}};
    [closeBtn addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];
    [_rail addSubview:closeBtn];

    NSArray *icons = @[[self makeSaplingIcon],[self makeSwordIcon],
                       [self makeBookshelfIcon],[self makeBrickCubeIcon]];
    NSMutableArray *tabs = [NSMutableArray new];
    CGFloat tabY[] = {156, 336, 516, 696};
    for (int i = 0; i < 4; i++) {
        MWBEMITab *tab = [[MWBEMITab alloc] initWithIcon:icons[i]];
        tab.frame = (CGRect){{0,tabY[i]*s},{165*s,166*s}};
        tab.tag = i; tab.active = (i == 0);
        [tab addTarget:self action:@selector(switchTab:) forControlEvents:UIControlEventTouchUpInside];
        [_rail addSubview:tab]; [tabs addObject:tab];
    }
    _tabs = tabs;

    _gridWrap = [[UIView alloc] initWithFrame:(CGRect){{233*s,37*s},{1590*s,873*s}}];
    _gridWrap.backgroundColor = EMIColor(0x1a,0x1a,0x19);
    _gridWrap.layer.borderWidth = 8*s;
    _gridWrap.layer.borderColor = EMIColor(0x17,0x17,0x16).CGColor;
    [_window addSubview:_gridWrap];

    _gridScroll = [[UIScrollView alloc] initWithFrame:_gridWrap.bounds];
    _gridScroll.tag = 999;
    _gridScroll.autoresizingMask = UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    _gridScroll.backgroundColor = [UIColor clearColor];
    _gridScroll.showsVerticalScrollIndicator = NO;
    // 格子点击立刻响应: 同悬浮窗菜单, 关滚动触摸延迟
    _gridScroll.delaysContentTouches = NO;
    [_gridWrap addSubview:_gridScroll];

    [self buildItemGrid];
    [self buildHotbar];
}

- (void)addInsetShadow:(UIView *)v light:(UIColor *)light dark:(UIColor *)dark
                lightW:(CGFloat)lw darkW:(CGFloat)dw {
    CGFloat s = kEMIScale;
    CALayer *t=[CALayer layer],*l=[CALayer layer],*b=[CALayer layer],*r=[CALayer layer];
    t.backgroundColor = light.CGColor; l.backgroundColor = light.CGColor;
    b.backgroundColor = dark.CGColor; r.backgroundColor = dark.CGColor;
    [v.layer addSublayer:t]; [v.layer addSublayer:l];
    [v.layer addSublayer:b]; [v.layer addSublayer:r];
    CGFloat o = v.layer.borderWidth, w = v.bounds.size.width, h = v.bounds.size.height;
    t.frame = (CGRect){{o,o},{w-2*o,lw*s}}; l.frame = (CGRect){{o,o},{lw*s,h-2*o}};
    b.frame = (CGRect){{o,h-o-dw*s},{w-2*o,dw*s}}; r.frame = (CGRect){{w-o-dw*s,o},{dw*s,h-2*o}};
}

- (UIControl *)makeCloseButton {
    UIControl *btn = [[UIControl alloc] init];
    btn.backgroundColor = EMIColor(0xc5,0xbd,0xb6);
    btn.layer.borderWidth = 10*kEMIScale;
    btn.layer.borderColor = EMIColor(0xc5,0xbd,0xb6).CGColor;
    btn.layer.shadowColor = [UIColor blackColor].CGColor;
    btn.layer.shadowOffset = (CGSize){8*kEMIScale, 8*kEMIScale};
    btn.layer.shadowRadius = 0; btn.layer.shadowOpacity = 0.48;
    UIView *inner = [[UIView alloc] init];
    inner.backgroundColor = EMIColor(0x35,0x35,0x35);
    inner.tag = 1; [btn addSubview:inner];
    UIView *x1 = [[UIView alloc] init]; x1.backgroundColor = EMIColor(0xf6,0xf1,0xec); x1.tag = 2;
    UIView *x2 = [[UIView alloc] init]; x2.backgroundColor = EMIColor(0xf6,0xf1,0xec); x2.tag = 3;
    [inner addSubview:x1]; [inner addSubview:x2];
    return btn;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat s = kEMIScale;
    UIControl *closeBtn = (UIControl *)_rail.subviews.firstObject;
    if (closeBtn) {
        UIView *inner = [closeBtn viewWithTag:1];
        CGFloat inset = 12*s;
        inner.frame = CGRectInset(closeBtn.bounds, inset, inset);
        CALayer *it=[CALayer layer],*il=[CALayer layer],*ib=[CALayer layer],*ir=[CALayer layer];
        it.backgroundColor = EMIColor(0x25,0x25,0x25).CGColor;
        il.backgroundColor = EMIColor(0x25,0x25,0x25).CGColor;
        ib.backgroundColor = EMIColor(0x59,0x59,0x59).CGColor;
        ir.backgroundColor = EMIColor(0x59,0x59,0x59).CGColor;
        [inner.layer addSublayer:it]; [inner.layer addSublayer:il];
        [inner.layer addSublayer:ib]; [inner.layer addSublayer:ir];
        CGFloat sh = 5*s, iw = inner.bounds.size.width, ih = inner.bounds.size.height;
        it.frame = (CGRect){{0,0},{iw,sh}}; il.frame = (CGRect){{0,0},{sh,ih}};
        ib.frame = (CGRect){{0,ih-sh},{iw,sh}}; ir.frame = (CGRect){{iw-sh,0},{sh,ih}};
        UIView *x1 = [inner viewWithTag:2], *x2 = [inner viewWithTag:3];
        CGFloat xw = 60*s, xh = 19*s;
        x1.frame = (CGRect){{(iw-xw)/2,(ih-xh)/2},{xw,xh}};
        x2.frame = (CGRect){{(iw-xw)/2,(ih-xh)/2},{xw,xh}};
        x1.transform = CGAffineTransformMakeRotation(M_PI_4);
        x2.transform = CGAffineTransformMakeRotation(-M_PI_4);
    }
}

#pragma mark - 分类图标

- (UIView *)makeSaplingIcon {
    UIView *v = [[UIView alloc] init]; v.backgroundColor = [UIColor clearColor];
    CGFloat s = kEMIScale, sz = 78*s;
    v.bounds = (CGRect){{0,0},{sz,sz}};
    UIView *trunk = [[UIView alloc] initWithFrame:(CGRect){{sz*0.42,sz*0.65},{sz*0.12,sz*0.3}}];
    trunk.backgroundColor = EMIColor(0x6b,0x3b,0x12);
    UIView *leaves = [[UIView alloc] initWithFrame:(CGRect){{sz*0.15,sz*0.1},{sz*0.7,sz*0.6}}];
    leaves.backgroundColor = EMIColor(0x2c,0x76,0x07);
    [v addSubview:trunk]; [v addSubview:leaves];
    return v;
}
- (UIView *)makeSwordIcon {
    UIView *v = [[UIView alloc] init]; v.backgroundColor = [UIColor clearColor];
    CGFloat s = kEMIScale, sz = 92*s;
    v.bounds = (CGRect){{0,0},{sz,sz}};
    UIView *blade = [[UIView alloc] initWithFrame:(CGRect){{sz*0.42,sz*0.02},{sz*0.18,sz*0.7}}];
    blade.backgroundColor = EMIColor(0xc2,0xcb,0xce);
    blade.layer.borderWidth = 4*s; blade.layer.borderColor = EMIColor(0x2f,0x34,0x34).CGColor;
    UIView *guard = [[UIView alloc] initWithFrame:(CGRect){{sz*0.22,sz*0.68},{sz*0.6,sz*0.13}}];
    guard.backgroundColor = EMIColor(0x5d,0x44,0x2d);
    guard.layer.borderWidth = 4*s; guard.layer.borderColor = EMIColor(0x2a,0x21,0x18).CGColor;
    UIView *handle = [[UIView alloc] initWithFrame:(CGRect){{sz*0.45,sz*0.78},{sz*0.15,sz*0.27}}];
    handle.backgroundColor = EMIColor(0x5e,0x44,0x2f);
    handle.layer.borderWidth = 4*s; handle.layer.borderColor = EMIColor(0x2a,0x21,0x18).CGColor;
    [v addSubview:blade]; [v addSubview:guard]; [v addSubview:handle];
    v.transform = CGAffineTransformMakeRotation(-M_PI_4*0.97);
    return v;
}
- (UIView *)makeBookshelfIcon {
    UIView *v = [[UIView alloc] init]; v.backgroundColor = [UIColor clearColor];
    CGFloat s = kEMIScale, sz = 80*s;
    v.bounds = (CGRect){{0,0},{sz,sz}};
    UIView *front = [[UIView alloc] initWithFrame:(CGRect){{sz*0.12,sz*0.25},{sz*0.72,sz*0.6}}];
    front.backgroundColor = EMIColor(0x5e,0x3b,0x20);
    front.layer.borderWidth = 5*s; front.layer.borderColor = EMIColor(0x3b,0x24,0x12).CGColor;
    NSArray *colors = @[EMIColor(0x1b,0x68,0x2f),EMIColor(0x5d,0x2b,0x5e),
                        EMIColor(0x6a,0x25,0x25),EMIColor(0x19,0x3d,0x6c),EMIColor(0xb7,0x9b,0x32)];
    CGFloat bookW = front.bounds.size.width / colors.count;
    for (int i = 0; i < (int)colors.count; i++) {
        UIView *book = [[UIView alloc] initWithFrame:(CGRect){{i*bookW+3*s,3*s},{bookW-6*s,front.bounds.size.height-6*s}}];
        book.backgroundColor = colors[i]; [front addSubview:book];
    }
    [v addSubview:front];
    return v;
}
- (UIView *)makeBrickCubeIcon {
    MWBCubeView *cube = [[MWBCubeView alloc] initWithSize:82*kEMIScale*0.98];
    [cube setTopTile:@"brick" frontTile:@"brick" sideTile:@"brick" topIndex:0 frontIndex:0 sideIndex:0];
    return cube;
}

#pragma mark - 物品网格

- (void)buildItemGrid {
    // 清空旧格子
    for (UIView *v in [_gridScroll.subviews copy]) [v removeFromSuperview];
    __weak typeof(self) ws = self;

    CGFloat s = kEMIScale;
    CGFloat cellSize = 159*s;
    int cols = 10;
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

#pragma mark - 底部快捷栏

- (void)buildHotbar {
    CGFloat s = kEMIScale;
    CGFloat hbW = 1092*s, hbH = 139*s;
    CGFloat hbX = _window.frame.origin.x + 417*s;
    CGFloat hbY = _window.frame.origin.y + 941*s;
    _hotbar = [[UIView alloc] initWithFrame:(CGRect){{hbX,hbY},{hbW,hbH}}];
    _hotbar.backgroundColor = EMIColor(0xd7,0xde,0xd7);
    _hotbar.layer.borderWidth = 8*s;
    _hotbar.layer.borderColor = EMIColor(0x11,0x11,0x11).CGColor;
    [self addSubview:_hotbar];
    [self addInsetShadow:_hotbar light:EMIColor(0xee,0xf6,0xef) dark:EMIColor(0x69,0x71,0x6b)
                   lightW:6 darkW:6];
    int slots = 9; CGFloat pad = 8*s;
    CGFloat slotW = (hbW-pad*2)/slots, slotH = hbH-pad*2;
    for (int i = 0; i < slots; i++) {
        UIView *slot = [[UIView alloc] initWithFrame:(CGRect){{pad+i*slotW,pad},{slotW,slotH}}];
        slot.backgroundColor = [UIColor colorWithRed:40/255.0 green:52/255.0 blue:35/255.0 alpha:0.78];
        slot.layer.borderWidth = (i==0 ? 8 : 7)*s;
        slot.layer.borderColor = (i==0 ? EMIColor(0xe7,0xf0,0xe7) : EMIColor(0x85,0x8b,0x83)).CGColor;
        CALayer *st=[CALayer layer],*sl=[CALayer layer],*sb=[CALayer layer],*sr=[CALayer layer];
        st.backgroundColor = EMIColor(0x51,0x56,0x50).CGColor;
        sl.backgroundColor = EMIColor(0x51,0x56,0x50).CGColor;
        sb.backgroundColor = EMIColor(0xc1,0xc7,0xc0).CGColor;
        sr.backgroundColor = EMIColor(0xc1,0xc7,0xc0).CGColor;
        [slot.layer addSublayer:st]; [slot.layer addSublayer:sl];
        [slot.layer addSublayer:sb]; [slot.layer addSublayer:sr];
        CGFloat sh = 4*s, sw = slot.bounds.size.width, sh2 = slot.bounds.size.height;
        st.frame = (CGRect){{0,0},{sw,sh}}; sl.frame = (CGRect){{0,0},{sh,sh2}};
        sb.frame = (CGRect){{0,sh2-sh},{sw,sh}}; sr.frame = (CGRect){{sw-sh,0},{sh,sh2}};
        [_hotbar addSubview:slot];
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
    self.frame = view.bounds; [view addSubview:self];
    self.alpha = 0; self.transform = CGAffineTransformMakeScale(0.95, 0.95);
    [UIView animateWithDuration:0.15 animations:^{
        self.alpha = 1; self.transform = CGAffineTransformIdentity;
    }];
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
