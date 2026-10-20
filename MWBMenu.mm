/* MWBMenu.mm — 选项菜单主视图实现 (分类导航 + 设置页 + 开关回调) */
#import <UIKit/UIKit.h>
#import "MWBCommon.h"
#import "MWBUI.h"
#import "MWBMenu.h"

#pragma mark - 选项菜单主视图

@implementation MWBOptionsMenu {
    UIView *_topBar;
    UIView *_sideNav;
    UIScrollView *_panel;
    NSArray<MWBSideButton *> *_sideButtons;
    MWBPixelButton *_backButton;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor clearColor];
        self.alpha = 0;
        self.transform = CGAffineTransformMakeScale(0.985, 0.985);
        [self setupTopBar];
        [self setupBody];
    }
    return self;
}

- (void)setupTopBar {
    CGFloat barH = 104;
    _topBar = [[UIView alloc] initWithFrame:(CGRect){{0,0},{self.bounds.size.width,barH}}];
    _topBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    _topBar.backgroundColor = kTopBar;
    [self addSubview:_topBar];

    // 顶部 5px 亮边, 底部 7px 暗边
    UIView *topLight = [[UIView alloc] init];
    topLight.backgroundColor = MWB_COLOR(0xbb,0xb3,0xb7);
    topLight.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [_topBar addSubview:topLight];
    UIView *bottomDark = [[UIView alloc] init];
    bottomDark.backgroundColor = MWB_COLOR(0x19,0x19,0x1a);
    bottomDark.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [_topBar addSubview:bottomDark];
    UIView *innerShadow = [[UIView alloc] init];
    innerShadow.backgroundColor = MWB_COLOR(0x4e,0x49,0x4e);
    innerShadow.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [_topBar addSubview:innerShadow];

    // Back 按钮
    _backButton = [[MWBPixelButton alloc] init];
    _backButton.autoresizingMask = UIViewAutoresizingFlexibleRightMargin;
    NSAttributedString *backTitle = MWBPixelText(@"Back", MWBPixelFont(36), MWB_COLOR(0xef,0xed,0xeb),
                                                 3, 3, MWB_COLOR(0x39,0x36,0x38));
    [_backButton setAttributedTitle:backTitle forState:UIControlStateNormal];
    [_backButton addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];
    [_topBar addSubview:_backButton];

    // 标题
    UILabel *title = [[UILabel alloc] init];
    title.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    title.textAlignment = NSTextAlignmentCenter;
    title.attributedText = MWBPixelText(@"Options", MWBPixelFont(42), MWB_COLOR(0xe9,0xe6,0xe4),
                                        4, 4, MWB_COLOR(0x37,0x35,0x37));
    [_topBar addSubview:title];

    _topBar.frame = (CGRect){{0,0},{self.bounds.size.width,barH}};
    topLight.frame = (CGRect){{0,0},{_topBar.bounds.size.width,5}};
    bottomDark.frame = (CGRect){{0,barH-7},{_topBar.bounds.size.width,7}};
    innerShadow.frame = (CGRect){{0,barH-12},{_topBar.bounds.size.width,5}};
    _backButton.frame = (CGRect){{16,10},{132,barH-20}};
    title.frame = (CGRect){{148,0},{_topBar.bounds.size.width-296,barH}};
}

- (void)setupBody {
    CGFloat barH = 104;
    CGFloat sideW = 137;
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;

    // 左侧导航
    _sideNav = [[UIView alloc] initWithFrame:(CGRect){{0,barH},{sideW,h-barH}}];
    _sideNav.autoresizingMask = UIViewAutoresizingFlexibleHeight;
    _sideNav.backgroundColor = kSidebar;
    [self addSubview:_sideNav];
    // 右侧内阴影
    UIView *navEdge = [[UIView alloc] init];
    navEdge.backgroundColor = MWB_COLOR(0x74,0x6e,0x6d);
    navEdge.autoresizingMask = UIViewAutoresizingFlexibleHeight|UIViewAutoresizingFlexibleLeftMargin;
    [_sideNav addSubview:navEdge];
    navEdge.frame = (CGRect){{sideW-5,0},{5,_sideNav.bounds.size.height}};

    // 5 个分类图标 (SVG path 与参考一致): 工具/方块/控制/世界/物品(EMI)
    NSArray *icons = @[
        @[@"M10 8h18v7h-5v5l25 25 4-4 7 7-11 11-7-7 4-4-25-25h-5v5H8V10z",
          @"M48 7h9v9l-7 7-7-2-19 19-6 10-7 7-4-4 7-7 10-6 19-19-2-7z"],
        @[@"M5 7h25v22H5zm4 5v5h7v-5zm11 0v5h6v-5zM34 7h25v22H34zm4 5v5h7v-5zm11 0v5h6v-5zM5 34h25v22H5zm4 5v5h7v-5zm11 0v5h6v-5zM34 34h25v22H34zm4 5v5h7v-5zm11 0v5h6v-5z"],
        @[@"M18 17h28l8 7 6 22-5 10h-9L36 45h-8L18 56H9L4 46l6-22zm-2 10v7h-7v8h7v7h8v-7h7v-8h-7v-7zm27 5v7h7v-7zm8 9v7h7v-7z"],
        @[@"M27 5h9v12h-9zM8 14h9v9H8zm38 1h9v9h-9zM18 24h10v10H18zm19-2h10v10H37zM5 36h10v10H5zm49-4h8v11h-8zM26 39h12v12H26zm-13 10h9v10h-9zm32-9h10v11H45zM35 54h8v8h-8z"],
        @[@"M32 6 L54 26 L32 58 L10 26 Z", @"M10 26 H54"],
    ];
    NSMutableArray *btns = [NSMutableArray new];
    CGFloat btnPad = 18, btnTop = 24;
    CGFloat btnSize = sideW - btnPad*2;
    CGFloat step = btnSize + 16;
    for (int i = 0; i < 5; i++) {
        MWBSideButton *b = [[MWBSideButton alloc] initWithSVGPaths:icons[i]];
        b.frame = (CGRect){{btnPad,btnTop + i*step},{btnSize,btnSize}};
        b.tag = i;
        b.active = (i == 0);
        [b addTarget:self action:@selector(switchPage:) forControlEvents:UIControlEventTouchUpInside];
        [_sideNav addSubview:b];
        [btns addObject:b];
    }
    _sideButtons = btns;

    // 右侧设置面板
    _panel = [[UIScrollView alloc] initWithFrame:(CGRect){{sideW,barH},{w-sideW,h-barH}}];
    _panel.autoresizingMask = UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    _panel.backgroundColor = kPanelBG;
    _panel.alwaysBounceVertical = YES;
    _panel.showsVerticalScrollIndicator = NO;
    // 按钮按下立刻响应: 关掉滚动视图的触摸延迟, 否则手指稍抖就被当成滚动吃掉点击
    _panel.delaysContentTouches = NO;
    [self addSubview:_panel];

    [self buildPages];
}

// 创建像素开关
- (MWBPixelToggle *)makeToggle:(BOOL)on action:(SEL)sel {
    MWBPixelToggle *t = [[MWBPixelToggle alloc] init];
    t.on = on;
    [t addTarget:self action:sel forControlEvents:UIControlEventValueChanged];
    return t;
}

// 创建设置行标签
- (UILabel *)makeRowLabel:(NSString *)text {
    UILabel *l = [[UILabel alloc] init];
    l.attributedText = MWBPixelText(text, MWBPixelFont(30), MWB_COLOR(0xcf,0xcc,0xc6),
                                    4, 4, MWB_COLOR(0x30,0x30,0x31));
    return l;
}

- (void)buildPages {
    NSMutableArray *pages = [NSMutableArray new];
    CGFloat pw = _panel.bounds.size.width;
    CGFloat padL = 58, padTop = 4;

    // ---- 页 0: Game (工具) ----
    UIView *p0 = [[UIView alloc] init];
    p0.backgroundColor = [UIColor clearColor];
    UILabel *h0 = [[UILabel alloc] init];
    h0.attributedText = MWBPixelText(@"Game", MWBPixelFont(41), MWB_COLOR(0xf0,0xee,0xea),
                                     4, 4, MWB_COLOR(0x30,0x30,0x31));
    [h0 sizeToFit];
    h0.frame = (CGRect){{padL,padTop},{h0.bounds.size.width,h0.bounds.size.height}};
    [p0 addSubview:h0];
    NSArray *rows0 = @[
        @[@"无敌", [self makeToggle:gInvincible action:@selector(togInvincible:)]],
        @[@"飞行", [self makeToggle:gFly action:@selector(togFly:)]],
        @[@"快速破坏", [self makeToggle:gFastBreak action:@selector(togFastBreak:)]],
        @[@"穿墙", [self makeToggle:gNoclip action:@selector(togNoclip:)]],
        @[@"夜视", [self makeToggle:gNightVision action:@selector(togNightVision:)]],
        @[@"杀戮光环", [self makeToggle:gKillAura action:@selector(togKillAura:)]],
        @[@"小地图", [self makeToggle:gMinimap action:@selector(togMinimap:)]],
        @[@"调试模式", [self makeToggle:gMWBDebug action:@selector(togDebug:)]],
    ];
    CGFloat ry = CGRectGetMaxY(h0.frame) + 20;
    for (NSArray *r in rows0) {
        UILabel *l = [self makeRowLabel:r[0]];
        MWBPixelToggle *t = r[1];
        UIView *row = [[UIView alloc] init];
        row.backgroundColor = [UIColor clearColor];
        [row addSubview:l]; [row addSubview:t];
        // 整行可点: 行内空白/文字区本是死的, 手指落点稍偏就没反应;
        // 由行统一接管, 开关本身设为不拦截避免双重触发
        t.userInteractionEnabled = NO;
        [row addGestureRecognizer:[[UITapGestureRecognizer alloc]
            initWithTarget:t action:@selector(toggle)]];
        row.frame = (CGRect){{33,ry},{pw-66-33,77}};
        l.frame = (CGRect){{0,0},{MIN(445,row.bounds.size.width-180),77}};
        t.frame = (CGRect){{row.bounds.size.width-152,0},{152,77}};
        [p0 addSubview:row];
        ry += 85;
    }
    p0.frame = (CGRect){{0,0},{pw,ry}};
    [pages addObject:p0];

    // ---- 页 1: Blocks (方块) ----
    UIView *p1 = [[UIView alloc] init];
    p1.backgroundColor = [UIColor clearColor];
    UILabel *h1 = [[UILabel alloc] init];
    h1.attributedText = MWBPixelText(@"Blocks", MWBPixelFont(41), MWB_COLOR(0xf0,0xee,0xea),
                                     4, 4, MWB_COLOR(0x30,0x30,0x31));
    [h1 sizeToFit];
    h1.frame = (CGRect){{padL,padTop},{h1.bounds.size.width,h1.bounds.size.height}};
    [p1 addSubview:h1];
    UILabel *todo1 = [[UILabel alloc] init];
    todo1.attributedText = MWBPixelText(@"物品功能开发中...", MWBPixelFont(28), kWhiteText,
                                        3, 3, [UIColor blackColor]);
    [todo1 sizeToFit];
    todo1.frame = (CGRect){{padL,CGRectGetMaxY(h1.frame)+30},{todo1.bounds.size.width,todo1.bounds.size.height}};
    [p1 addSubview:todo1];
    p1.frame = (CGRect){{0,0},{pw,CGRectGetMaxY(todo1.frame)+30}};
    [pages addObject:p1];

    // ---- 页 2: Controls (手柄) ----
    UIView *p2 = [[UIView alloc] init];
    p2.backgroundColor = [UIColor clearColor];
    UILabel *h2 = [[UILabel alloc] init];
    h2.attributedText = MWBPixelText(@"Controls", MWBPixelFont(41), MWB_COLOR(0xf0,0xee,0xea),
                                     4, 4, MWB_COLOR(0x30,0x30,0x31));
    [h2 sizeToFit];
    h2.frame = (CGRect){{padL,padTop},{h2.bounds.size.width,h2.bounds.size.height}};
    [p2 addSubview:h2];
    NSArray *rows2 = @[
        @[@"加速奔跑", [self makeToggle:gSpeed action:@selector(togSpeed:)]],
        @[@"超级跳跃", [self makeToggle:gSuperJump action:@selector(togSuperJump:)]],
    ];
    ry = CGRectGetMaxY(h2.frame) + 20;
    for (NSArray *r in rows2) {
        UILabel *l = [self makeRowLabel:r[0]];
        MWBPixelToggle *t = r[1];
        UIView *row = [[UIView alloc] init];
        [row addSubview:l]; [row addSubview:t];
        // 整行可点: 同上 (Controls页)
        t.userInteractionEnabled = NO;
        [row addGestureRecognizer:[[UITapGestureRecognizer alloc]
            initWithTarget:t action:@selector(toggle)]];
        row.frame = (CGRect){{33,ry},{pw-66-33,77}};
        l.frame = (CGRect){{0,0},{MIN(445,row.bounds.size.width-180),77}};
        t.frame = (CGRect){{row.bounds.size.width-152,0},{152,77}};
        [p2 addSubview:row];
        ry += 85;
    }
    p2.frame = (CGRect){{0,0},{pw,ry}};
    [pages addObject:p2];

    // ---- 页 3: World (粒子) ----
    UIView *p3 = [[UIView alloc] init];
    p3.backgroundColor = [UIColor clearColor];
    UILabel *h3 = [[UILabel alloc] init];
    h3.attributedText = MWBPixelText(@"World", MWBPixelFont(41), MWB_COLOR(0xf0,0xee,0xea),
                                     4, 4, MWB_COLOR(0x30,0x30,0x31));
    [h3 sizeToFit];
    h3.frame = (CGRect){{padL,padTop},{h3.bounds.size.width,h3.bounds.size.height}};
    [p3 addSubview:h3];
    // 时间切换: 白天 / 夜晚 两个像素按钮
    UILabel *timeLabel = [self makeRowLabel:@"时间"];
    timeLabel.frame = (CGRect){{33,CGRectGetMaxY(h3.frame)+30},{200,60}};
    [p3 addSubview:timeLabel];
    MWBPixelButton *dayBtn = [[MWBPixelButton alloc] init];
    [dayBtn setAttributedTitle:MWBPixelText(@"白天", MWBPixelFont(28), MWB_COLOR(0xef,0xed,0xeb),
                                            3, 3, MWB_COLOR(0x39,0x36,0x38)) forState:UIControlStateNormal];
    dayBtn.tag = 1;
    [dayBtn addTarget:self action:@selector(setTime:) forControlEvents:UIControlEventTouchUpInside];
    dayBtn.frame = (CGRect){{pw-33-260,CGRectGetMaxY(h3.frame)+30},{120,60}};
    [p3 addSubview:dayBtn];
    MWBPixelButton *nightBtn = [[MWBPixelButton alloc] init];
    [nightBtn setAttributedTitle:MWBPixelText(@"夜晚", MWBPixelFont(28), MWB_COLOR(0xef,0xed,0xeb),
                                              3, 3, MWB_COLOR(0x39,0x36,0x38)) forState:UIControlStateNormal];
    nightBtn.tag = 2;
    [nightBtn addTarget:self action:@selector(setTime:) forControlEvents:UIControlEventTouchUpInside];
    nightBtn.frame = (CGRect){{pw-33-130,CGRectGetMaxY(h3.frame)+30},{120,60}};
    [p3 addSubview:nightBtn];
    // 天气: 晴 / 雨 / 雷 三个像素按钮 (tag 3/4/5)
    // 0.10/1.1.7/1.20.62 没有可写天气通道, 按钮置灰, 只读不点
    UILabel *wxLabel = [self makeRowLabel:@"天气"];
    wxLabel.frame = (CGRect){{33,CGRectGetMaxY(dayBtn.frame)+20},{200,60}};
    [p3 addSubview:wxLabel];
    NSArray *wxTitles = @[@"晴", @"雨", @"雷"];
    for (int i = 0; i < 3; i++) {
        MWBPixelButton *wxBtn = [[MWBPixelButton alloc] init];
        [wxBtn setAttributedTitle:MWBPixelText(wxTitles[i], MWBPixelFont(28), MWB_COLOR(0xef,0xed,0xeb),
                                              3, 3, MWB_COLOR(0x39,0x36,0x38)) forState:UIControlStateNormal];
        wxBtn.tag = 3 + i;
        [wxBtn addTarget:self action:@selector(setWeather:) forControlEvents:UIControlEventTouchUpInside];
        wxBtn.frame = (CGRect){{pw-33-400+i*135,CGRectGetMaxY(dayBtn.frame)+20},{120,60}};
        if (!MWBWeatherSupported()) {
            wxBtn.alpha = 0.35;
            wxBtn.userInteractionEnabled = NO;
        }
        [p3 addSubview:wxBtn];
    }
    // 动作: 治疗 / 附魔255 / 传送+10 / 铺石块 (tag 10-13)
    UILabel *actLabel = [self makeRowLabel:@"动作"];
    actLabel.frame = (CGRect){{33,CGRectGetMaxY(dayBtn.frame)+100},{200,60}};
    [p3 addSubview:actLabel];
    NSArray *actTitles = @[@"治疗", @"附魔", @"传送", @"铺石"];
    for (int i = 0; i < 4; i++) {
        MWBPixelButton *actBtn = [[MWBPixelButton alloc] init];
        [actBtn setAttributedTitle:MWBPixelText(actTitles[i], MWBPixelFont(24), MWB_COLOR(0xef,0xed,0xeb),
                                               3, 3, MWB_COLOR(0x39,0x36,0x38)) forState:UIControlStateNormal];
        actBtn.tag = 10 + i;
        [actBtn addTarget:self action:@selector(doAction:) forControlEvents:UIControlEventTouchUpInside];
        actBtn.frame = (CGRect){{pw-33-430+i*105,CGRectGetMaxY(dayBtn.frame)+100},{95,56}};
        [p3 addSubview:actBtn];
    }
    p3.frame = (CGRect){{0,0},{pw,CGRectGetMaxY(dayBtn.frame)+368}};
    NSArray *diffTitles = @[@"和平", @"简单", @"普通", @"困难"];
    // 难度: 和平 / 简单 / 普通 / 困难 四个像素按钮 (tag 15-18, 目前只接了 0.10 后端)
    UILabel *diffLabel = [self makeRowLabel:@"难度"];
    diffLabel.frame = (CGRect){{33,CGRectGetMaxY(dayBtn.frame)+164},{200,60}};
    [p3 addSubview:diffLabel];
    for (int i = 0; i < 4; i++) {
        MWBPixelButton *diffBtn = [[MWBPixelButton alloc] init];
        [diffBtn setAttributedTitle:MWBPixelText(diffTitles[i], MWBPixelFont(24), MWB_COLOR(0xef,0xed,0xeb),
                                                3, 3, MWB_COLOR(0x39,0x36,0x38)) forState:UIControlStateNormal];
        diffBtn.tag = 15 + i;
        [diffBtn addTarget:self action:@selector(setDifficulty:) forControlEvents:UIControlEventTouchUpInside];
        diffBtn.frame = (CGRect){{pw-33-430+i*105,CGRectGetMaxY(dayBtn.frame)+164},{95,56}};
        if (!MWB010Only()) {
            diffBtn.alpha = 0.35;
            diffBtn.userInteractionEnabled = NO;
        }
        [p3 addSubview:diffBtn];
    }
    // 反应核: 点燃 (tag 14, 目前只接了 0.10 后端)
    UILabel *reactorLabel = [self makeRowLabel:@"反应核"];
    reactorLabel.frame = (CGRect){{33,CGRectGetMaxY(dayBtn.frame)+228},{200,60}};
    [p3 addSubview:reactorLabel];
    MWBPixelButton *reactorBtn = [[MWBPixelButton alloc] init];
    [reactorBtn setAttributedTitle:MWBPixelText(@"点燃", MWBPixelFont(24), MWB_COLOR(0xef,0xed,0xeb),
                                               3, 3, MWB_COLOR(0x39,0x36,0x38)) forState:UIControlStateNormal];
    reactorBtn.tag = 14;
    [reactorBtn addTarget:self action:@selector(doAction:) forControlEvents:UIControlEventTouchUpInside];
    reactorBtn.frame = (CGRect){{pw-33-430,CGRectGetMaxY(dayBtn.frame)+228},{95,56}};
    if (!MWB010Only()) {
        reactorBtn.alpha = 0.35;
        reactorBtn.userInteractionEnabled = NO;
    }
    [p3 addSubview:reactorBtn];
    // 爆炸: 定点爆炸 (tag 24, 目前只接了 0.10 后端)
    MWBPixelButton *explodeBtn = [[MWBPixelButton alloc] init];
    [explodeBtn setAttributedTitle:MWBPixelText(@"爆炸", MWBPixelFont(24), MWB_COLOR(0xef,0xed,0xeb),
                                               3, 3, MWB_COLOR(0x39,0x36,0x38)) forState:UIControlStateNormal];
    explodeBtn.tag = 24;
    [explodeBtn addTarget:self action:@selector(doAction:) forControlEvents:UIControlEventTouchUpInside];
    explodeBtn.frame = (CGRect){{pw-33-430+105,CGRectGetMaxY(dayBtn.frame)+228},{95,56}};
    if (!MWB010Only()) {
        explodeBtn.alpha = 0.35;
        explodeBtn.userInteractionEnabled = NO;
    }
    [p3 addSubview:explodeBtn];
    // 刷怪: 僵尸 / 爬行者 / 骷髅 / 猪人 (tag 20-23, 目前只接了 0.10 后端)
    UILabel *mobLabel = [self makeRowLabel:@"刷怪"];
    mobLabel.frame = (CGRect){{33,CGRectGetMaxY(dayBtn.frame)+292},{200,60}};
    [p3 addSubview:mobLabel];
    NSArray *mobTitles = @[@"僵尸", @"爬行者", @"骷髅", @"猪人"];
    for (int i = 0; i < 4; i++) {
        MWBPixelButton *mobBtn = [[MWBPixelButton alloc] init];
        [mobBtn setAttributedTitle:MWBPixelText(mobTitles[i], MWBPixelFont(24), MWB_COLOR(0xef,0xed,0xeb),
                                               3, 3, MWB_COLOR(0x39,0x36,0x38)) forState:UIControlStateNormal];
        mobBtn.tag = 20 + i;
        [mobBtn addTarget:self action:@selector(doAction:) forControlEvents:UIControlEventTouchUpInside];
        mobBtn.frame = (CGRect){{pw-33-430+i*105,CGRectGetMaxY(dayBtn.frame)+292},{95,56}};
        if (!MWB010Only()) {
            mobBtn.alpha = 0.35;
            mobBtn.userInteractionEnabled = NO;
        }
        [p3 addSubview:mobBtn];
    }
    [pages addObject:p3];

    self.pages = pages;
    self.currentPage = 0;
    for (UIView *p in pages) [_panel addSubview:p];
    [self showPage:0];
}

- (void)showPage:(NSInteger)idx {
    _currentPage = idx;
    for (NSInteger i = 0; i < _pages.count; i++) {
        _pages[i].hidden = (i != idx);
    }
    if (idx < _pages.count) {
        _panel.contentSize = _pages[idx].bounds.size;
        [_panel setContentOffset:CGPointZero animated:NO];
    }
}

- (void)switchPage:(MWBSideButton *)sender {
    for (MWBSideButton *b in _sideButtons) b.active = NO;
    sender.active = YES;
    // 第 5 项 (tag=4): EMI 物品管理器, 作为浮层覆盖在本菜单之上, 不占 _panel 页
    if ((int)sender.tag == 4) {
        __weak typeof(self) ws = self;
        [MWBEMIManager presentBrowserInView:(self.superview ?: self.window)
                                   onClose:^{
            __strong typeof(ws) ss = ws; if (!ss) return;
            if (ss->_sideButtons.count > 0) ss->_sideButtons[0].active = YES;
            sender.active = NO;
            [ss showPage:0];
        }];
        return;
    }
    [self showPage:sender.tag];
}

- (void)showInView:(UIView *)view {
    self.frame = view.bounds;
    [view addSubview:self];
    [UIView animateWithDuration:0.16 delay:0 options:UIViewAnimationOptionCurveLinear animations:^{
        self.alpha = 1;
        self.transform = CGAffineTransformIdentity;
    } completion:nil];
}
- (void)hide {
    [UIView animateWithDuration:0.12 delay:0 options:UIViewAnimationOptionCurveLinear animations:^{
        self.alpha = 0;
        self.transform = CGAffineTransformMakeScale(0.985, 0.985);
    } completion:^(BOOL f){ [self removeFromSuperview]; }];
}
- (void)close {
    [self hide];
    if (self.onClose) self.onClose();
}

#pragma mark - 开关回调

- (void)togInvincible:(MWBPixelToggle *)t { gInvincible = t.on; }
- (void)togFly:(MWBPixelToggle *)t { gFly = t.on; }
- (void)togFastBreak:(MWBPixelToggle *)t { gFastBreak = t.on; }
- (void)togSpeed:(MWBPixelToggle *)t { gSpeed = t.on; MWBApplySpeed(t.on); }
- (void)togSuperJump:(MWBPixelToggle *)t { gSuperJump = t.on; }
- (void)togNoclip:(MWBPixelToggle *)t { gNoclip = t.on; }
- (void)togNightVision:(MWBPixelToggle *)t { gNightVision = t.on; }
- (void)togKillAura:(MWBPixelToggle *)t { gKillAura = t.on; }
- (void)togMinimap:(MWBPixelToggle *)t { gMinimap = t.on; MWBMinimapShow(t.on); }
- (void)togDebug:(MWBPixelToggle *)t {
    gMWBDebug = t.on;
    NSLog(@"[魔玩盒子] 调试模式 %@", gMWBDebug ? @"已开启" : @"已关闭");
}
- (void)setTime:(MWBPixelButton *)sender { gTimeMode = (int)sender.tag; }
- (void)setWeather:(MWBPixelButton *)sender {
    if (!MWBWeatherSupported()) return;
    gWeatherMode = (int)sender.tag - 2;
}
- (void)setDifficulty:(MWBPixelButton *)sender { MWBSetDifficulty010((int)sender.tag - 15); }
- (void)doAction:(MWBPixelButton *)sender {
    int tag = (int)sender.tag;
    if (tag == 10) MWBHealNow();
    else if (tag == 11) MWBEnchantHeld255();
    else if (tag == 12) MWBTeleportUp10();
    else if (tag == 13) MWBFillStone5();
    else if (tag == 14) MWB010SpawnReactor();
    else if (tag >= 20 && tag <= 23) {
        int mobIds[4] = {32, 33, 34, 36};  // 僵尸/爬行者/骷髅/僵尸猪人
        MWB010SpawnMob(mobIds[tag - 20]);
    }
    else if (tag == 24) MWB010Explode();
}

@end
