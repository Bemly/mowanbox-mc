/* MWBMenu.mm — 选项菜单主视图实现 (分类导航 + 设置页 + 开关回调) */
#import <UIKit/UIKit.h>
#import "MWBCommon.h"
#import "MWBUI.h"
#import "MWBMenu.h"
#import "MWBFloat.h"

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

// 侧栏游戏原版图标 (touchgui2 裸图标 + items 刷怪蛋; v7 分区零宽容矩形, 校对过)
// [0](138,4,21,21) [1](109,2,22,22) [2](136,31,24,24) [3](108,30,23,23) [4]蛋(16,192,16,16)
- (UIView *)makeSideIcon:(int)idx {
    struct { const char *f; CGRect r; } tabs[5] = {
        {"touchgui2.png", (CGRect){{138,4},{21,21}}},
        {"touchgui2.png", (CGRect){{109,2},{22,22}}},
        {"touchgui2.png", (CGRect){{136,31},{24,24}}},
        {"touchgui2.png", (CGRect){{108,30},{23,23}}},
        {"items-opaque.png", (CGRect){{16,192},{16,16}}},
    };
    if (idx < 0 || idx > 4) return nil;
    UIImage *img = MWBGameIcon(@(tabs[idx].f), tabs[idx].r);
    if (!img) return nil;
    UIImageView *iv = [[UIImageView alloc] initWithImage:img];
    iv.contentMode = UIViewContentModeScaleAspectFit;
    return iv;
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

    // 5 个分类图标 (游戏原版切图, 运行时从游戏 bundle 读, 不进仓库):
    // [0]齿轮=作弊 [1]手柄=世界 [2]方块=EMI [3]喇叭=悬浮窗 [4]刷怪蛋=刷怪(占位)
    // 切图矩形按 256 基准, 真机截图对过再锁; 读不到一律回落 SVG 线稿
    // 5 个分类图标 (全部游戏原版资源, 运行时读, 不进仓库):
    // [0]钻石剑+钻石镐(物品图标合成)=作弊 [1]手柄(touchgui2)=世界
    // [2]草方块(EMI等距立方体)=物品 [3]喇叭(touchgui)=悬浮窗 [4]刷怪蛋(items)=刷怪
    // 切图矩形按 256 基准, 真机截图对过再锁; 读不到一律回落同顺序 SVG 线稿
    // SVG 兜底 (上面切图读不到时用, 与旧图标一致): 作弊/世界/EMI/悬浮窗/刷怪
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
        MWBSideButton *b = nil;
        UIView *iconView = [self makeSideIcon:i];
        if (iconView) b = [[MWBSideButton alloc] initWithIconView:iconView];
        else b = [[MWBSideButton alloc] initWithSVGPaths:icons[i]];
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

    // ---- 页 0: 作弊 (齿轮): 开关全家桶 (跑跳从旧 Controls 页并入)
    UIView *p0 = [[UIView alloc] init];
    p0.backgroundColor = [UIColor clearColor];
    UILabel *h0 = [[UILabel alloc] init];
    h0.attributedText = MWBPixelText(@"作弊", MWBPixelFont(41), MWB_COLOR(0xf0,0xee,0xea),
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
        @[@"史莱姆区块", [self makeToggle:gSlimeChunk action:@selector(togSlimeChunk:)]],
        @[@"调试模式", [self makeToggle:gMWBDebug action:@selector(togDebug:)]],
        @[@"加速奔跑", [self makeToggle:gSpeed action:@selector(togSpeed:)]],
        @[@"超级跳跃", [self makeToggle:gSuperJump action:@selector(togSuperJump:)]],
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

    // (旧 Blocks 占位页 / Controls 页已删: 跑跳并入页0作弊, 世界页移为页1, EMI/悬浮窗/刷怪蛋为页2/3/4)

    // (旧 Controls 页已删, 见上)

    // ---- 页 1: 世界 (手柄): 时间/天气/动作/难度/反应核/爆炸 (刷怪已迁往页4刷怪蛋)
    UIView *p3 = [[UIView alloc] init];
    p3.backgroundColor = [UIColor clearColor];
    UILabel *h3 = [[UILabel alloc] init];
    h3.attributedText = MWBPixelText(@"世界", MWBPixelFont(41), MWB_COLOR(0xf0,0xee,0xea),
                                     4, 4, MWB_COLOR(0x30,0x30,0x31));
    [h3 sizeToFit];
    h3.frame = (CGRect){{padL,padTop},{h3.bounds.size.width,h3.bounds.size.height}};
    [p3 addSubview:h3];
    // 时间切换: 两行六个像素按钮 (0.10 一天 19200 tick: 日出0/白天1000/正午4800/黄昏9600/夜晚13000/午夜14400)
    // 白天/夜晚走 gTimeMode (跨版本通用); 日出/正午/黄昏/午夜走 gTimeCustom010 (仅 0.10, 其余版本置灰)
    UILabel *timeLabel = [self makeRowLabel:@"时间"];
    timeLabel.frame = (CGRect){{33,CGRectGetMaxY(h3.frame)+30},{200,60}};
    [p3 addSubview:timeLabel];
    NSArray *timeTitlesA = @[@"日出", @"白天", @"正午"];
    int timeTagsA[3] = {6, 1, 7};
    CGFloat tBase = CGRectGetMaxY(h3.frame) + 30;
    CGFloat rowY = tBase;
    for (int i = 0; i < 3; i++) {
        MWBPixelButton *tBtn = [[MWBPixelButton alloc] init];
        [tBtn setAttributedTitle:MWBPixelText(timeTitlesA[i], MWBPixelFont(28), MWB_COLOR(0xef,0xed,0xeb),
                                              3, 3, MWB_COLOR(0x39,0x36,0x38)) forState:UIControlStateNormal];
        tBtn.tag = timeTagsA[i];
        [tBtn addTarget:self action:@selector(setTime:) forControlEvents:UIControlEventTouchUpInside];
        tBtn.frame = (CGRect){{pw-33-390+i*135,rowY},{120,60}};
        if (timeTagsA[i] >= 6 && !MWB010Only()) {
            tBtn.alpha = 0.35;
            tBtn.userInteractionEnabled = NO;
        }
        [p3 addSubview:tBtn];
    }
    tBase = rowY + 60;
    NSArray *timeTitlesB = @[@"黄昏", @"夜晚", @"午夜"];
    int timeTagsB[3] = {8, 2, 9};
    rowY = tBase + 10;
    for (int i = 0; i < 3; i++) {
        MWBPixelButton *tBtn = [[MWBPixelButton alloc] init];
        [tBtn setAttributedTitle:MWBPixelText(timeTitlesB[i], MWBPixelFont(28), MWB_COLOR(0xef,0xed,0xeb),
                                              3, 3, MWB_COLOR(0x39,0x36,0x38)) forState:UIControlStateNormal];
        tBtn.tag = timeTagsB[i];
        [tBtn addTarget:self action:@selector(setTime:) forControlEvents:UIControlEventTouchUpInside];
        tBtn.frame = (CGRect){{pw-33-390+i*135,rowY},{120,60}};
        if (timeTagsB[i] >= 6 && !MWB010Only()) {
            tBtn.alpha = 0.35;
            tBtn.userInteractionEnabled = NO;
        }
        [p3 addSubview:tBtn];
    }
    tBase = rowY + 60;
    // 微调: -233 / +233 两个像素按钮 (tag 25/26, 在当前 dayTime 上加减, 仅 0.10)
    UILabel *stepLabel = [self makeRowLabel:@"微调"];
    stepLabel.frame = (CGRect){{33,tBase+10},{200,60}};
    [p3 addSubview:stepLabel];
    NSArray *stepTitles = @[@"-233", @"+233"];
    int stepTags[2] = {25, 26};
    rowY = tBase + 10;
    for (int i = 0; i < 2; i++) {
        MWBPixelButton *stBtn = [[MWBPixelButton alloc] init];
        [stBtn setAttributedTitle:MWBPixelText(stepTitles[i], MWBPixelFont(28), MWB_COLOR(0xef,0xed,0xeb),
                                              3, 3, MWB_COLOR(0x39,0x36,0x38)) forState:UIControlStateNormal];
        stBtn.tag = stepTags[i];
        [stBtn addTarget:self action:@selector(setTime:) forControlEvents:UIControlEventTouchUpInside];
        stBtn.frame = (CGRect){{pw-33-250+i*135,rowY},{120,60}};
        if (!MWB010Only()) {
            stBtn.alpha = 0.35;
            stBtn.userInteractionEnabled = NO;
        }
        [p3 addSubview:stBtn];
    }
    tBase = rowY + 60;
    // 0.10/1.1.7/1.20.62 没有可写天气通道, 按钮置灰, 只读不点
    UILabel *wxLabel = [self makeRowLabel:@"天气"];
    wxLabel.frame = (CGRect){{33,tBase+20},{200,60}};
    [p3 addSubview:wxLabel];
    NSArray *wxTitles = @[@"晴", @"雨", @"雷"];
    for (int i = 0; i < 3; i++) {
        MWBPixelButton *wxBtn = [[MWBPixelButton alloc] init];
        [wxBtn setAttributedTitle:MWBPixelText(wxTitles[i], MWBPixelFont(28), MWB_COLOR(0xef,0xed,0xeb),
                                              3, 3, MWB_COLOR(0x39,0x36,0x38)) forState:UIControlStateNormal];
        wxBtn.tag = 3 + i;
        [wxBtn addTarget:self action:@selector(setWeather:) forControlEvents:UIControlEventTouchUpInside];
        wxBtn.frame = (CGRect){{pw-33-400+i*135,tBase+20},{120,60}};
        if (!MWBWeatherSupported()) {
            wxBtn.alpha = 0.35;
            wxBtn.userInteractionEnabled = NO;
        }
        [p3 addSubview:wxBtn];
    }
    // 动作: 治疗 / 附魔255 / 传送+10 / 铺石块 (tag 10-13)
    UILabel *actLabel = [self makeRowLabel:@"动作"];
    actLabel.frame = (CGRect){{33,tBase+100},{200,60}};
    [p3 addSubview:actLabel];
    NSArray *actTitles = @[@"治疗", @"附魔", @"传送", @"铺石"];
    for (int i = 0; i < 4; i++) {
        MWBPixelButton *actBtn = [[MWBPixelButton alloc] init];
        [actBtn setAttributedTitle:MWBPixelText(actTitles[i], MWBPixelFont(24), MWB_COLOR(0xef,0xed,0xeb),
                                               3, 3, MWB_COLOR(0x39,0x36,0x38)) forState:UIControlStateNormal];
        actBtn.tag = 10 + i;
        [actBtn addTarget:self action:@selector(doAction:) forControlEvents:UIControlEventTouchUpInside];
        actBtn.frame = (CGRect){{pw-33-430+i*105,tBase+100},{95,56}};
        [p3 addSubview:actBtn];
    }
    p3.frame = (CGRect){{0,0},{pw,tBase+368}};
    NSArray *diffTitles = @[@"和平", @"简单", @"普通", @"困难"];
    // 难度: 和平 / 简单 / 普通 / 困难 四个像素按钮 (tag 15-18, 目前只接了 0.10 后端)
    UILabel *diffLabel = [self makeRowLabel:@"难度"];
    diffLabel.frame = (CGRect){{33,tBase+164},{200,60}};
    [p3 addSubview:diffLabel];
    for (int i = 0; i < 4; i++) {
        MWBPixelButton *diffBtn = [[MWBPixelButton alloc] init];
        [diffBtn setAttributedTitle:MWBPixelText(diffTitles[i], MWBPixelFont(24), MWB_COLOR(0xef,0xed,0xeb),
                                                3, 3, MWB_COLOR(0x39,0x36,0x38)) forState:UIControlStateNormal];
        diffBtn.tag = 15 + i;
        [diffBtn addTarget:self action:@selector(setDifficulty:) forControlEvents:UIControlEventTouchUpInside];
        diffBtn.frame = (CGRect){{pw-33-430+i*105,tBase+164},{95,56}};
        if (!MWB010Only()) {
            diffBtn.alpha = 0.35;
            diffBtn.userInteractionEnabled = NO;
        }
        [p3 addSubview:diffBtn];
    }
    // 反应核: 点燃 (tag 14, 目前只接了 0.10 后端)
    UILabel *reactorLabel = [self makeRowLabel:@"反应核"];
    reactorLabel.frame = (CGRect){{33,tBase+228},{200,60}};
    [p3 addSubview:reactorLabel];
    MWBPixelButton *reactorBtn = [[MWBPixelButton alloc] init];
    [reactorBtn setAttributedTitle:MWBPixelText(@"点燃", MWBPixelFont(24), MWB_COLOR(0xef,0xed,0xeb),
                                               3, 3, MWB_COLOR(0x39,0x36,0x38)) forState:UIControlStateNormal];
    reactorBtn.tag = 14;
    [reactorBtn addTarget:self action:@selector(doAction:) forControlEvents:UIControlEventTouchUpInside];
    reactorBtn.frame = (CGRect){{pw-33-430,tBase+228},{95,56}};
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
    explodeBtn.frame = (CGRect){{pw-33-430+105,tBase+228},{95,56}};
    if (!MWB010Only()) {
        explodeBtn.alpha = 0.35;
        explodeBtn.userInteractionEnabled = NO;
    }
    [p3 addSubview:explodeBtn];
    // (刷怪行已迁往页4刷怪蛋页, 后端 tag 20-23/doAction 保留供 flag/旧链路用)
    [pages addObject:p3];

    // ---- 页 2: 物品 (方块堆): EMI 浏览器嵌入本页容器, 切页时装/卸
    UIView *pEMI = [[UIView alloc] init];
    pEMI.backgroundColor = [UIColor clearColor];
    pEMI.tag = 0xE111;
    pEMI.frame = (CGRect){{0,0},{pw,600}};
    [pages addObject:pEMI];

    // ---- 页 3: 悬浮窗 (喇叭): 大小/透明度/位置复位 (语言切换第二轮)
    UIView *pF = [[UIView alloc] init];
    pF.backgroundColor = [UIColor clearColor];
    UILabel *hF = [[UILabel alloc] init];
    hF.attributedText = MWBPixelText(@"悬浮窗", MWBPixelFont(41), MWB_COLOR(0xf0,0xee,0xea),
                                     4, 4, MWB_COLOR(0x30,0x30,0x31));
    [hF sizeToFit];
    hF.frame = (CGRect){{padL,padTop},{hF.bounds.size.width,hF.bounds.size.height}};
    [pF addSubview:hF];
    CGFloat fBase = CGRectGetMaxY(hF.frame) + 30;
    UILabel *sizeLabel = [self makeRowLabel:@"大小"];
    sizeLabel.frame = (CGRect){{33,fBase},{200,60}};
    [pF addSubview:sizeLabel];
    NSArray *sizeTitles = @[@"小", @"中", @"大"];
    for (int i = 0; i < 3; i++) {
        MWBPixelButton *sBtn = [[MWBPixelButton alloc] init];
        [sBtn setAttributedTitle:MWBPixelText(sizeTitles[i], MWBPixelFont(28), MWB_COLOR(0xef,0xed,0xeb),
                                              3, 3, MWB_COLOR(0x39,0x36,0x38)) forState:UIControlStateNormal];
        sBtn.tag = 30 + i;
        [sBtn addTarget:self action:@selector(setFloatSize:) forControlEvents:UIControlEventTouchUpInside];
        sBtn.frame = (CGRect){{pw-33-390+i*135,fBase},{120,60}};
        [pF addSubview:sBtn];
    }
    UILabel *alphaLabel = [self makeRowLabel:@"透明度"];
    alphaLabel.frame = (CGRect){{33,fBase+70},{200,60}};
    [pF addSubview:alphaLabel];
    NSArray *alphaTitles = @[@"低", @"中", @"高"];
    for (int i = 0; i < 3; i++) {
        MWBPixelButton *aBtn = [[MWBPixelButton alloc] init];
        [aBtn setAttributedTitle:MWBPixelText(alphaTitles[i], MWBPixelFont(28), MWB_COLOR(0xef,0xed,0xeb),
                                              3, 3, MWB_COLOR(0x39,0x36,0x38)) forState:UIControlStateNormal];
        aBtn.tag = 33 + i;
        [aBtn addTarget:self action:@selector(setFloatAlpha:) forControlEvents:UIControlEventTouchUpInside];
        aBtn.frame = (CGRect){{pw-33-390+i*135,fBase+70},{120,60}};
        [pF addSubview:aBtn];
    }
    UILabel *posLabel = [self makeRowLabel:@"位置"];
    posLabel.frame = (CGRect){{33,fBase+140},{200,60}};
    [pF addSubview:posLabel];
    MWBPixelButton *resetBtn = [[MWBPixelButton alloc] init];
    [resetBtn setAttributedTitle:MWBPixelText(@"复位", MWBPixelFont(28), MWB_COLOR(0xef,0xed,0xeb),
                                             3, 3, MWB_COLOR(0x39,0x36,0x38)) forState:UIControlStateNormal];
    resetBtn.tag = 36;
    [resetBtn addTarget:self action:@selector(resetFloat:) forControlEvents:UIControlEventTouchUpInside];
    resetBtn.frame = (CGRect){{pw-33-390,fBase+140},{120,60}};
    [pF addSubview:resetBtn];
    UILabel *langLabel = [self makeRowLabel:@"语言"];
    langLabel.frame = (CGRect){{33,fBase+210},{200,60}};
    [pF addSubview:langLabel];
    NSArray *langTitles = @[@"中文", @"英文"];
    for (int i = 0; i < 2; i++) {
        MWBPixelButton *langBtn = [[MWBPixelButton alloc] init];
        [langBtn setAttributedTitle:MWBPixelText(langTitles[i], MWBPixelFont(28), MWB_COLOR(0xef,0xed,0xeb),
                                                3, 3, MWB_COLOR(0x39,0x36,0x38)) forState:UIControlStateNormal];
        langBtn.tag = 37 + i;
        [langBtn addTarget:self action:@selector(setLang:) forControlEvents:UIControlEventTouchUpInside];
        langBtn.frame = (CGRect){{pw-33-255+i*135,fBase+210},{120,60}};
        if (!MWB010Only()) {
            langBtn.alpha = 0.35;
            langBtn.userInteractionEnabled = NO;
        }
        [pF addSubview:langBtn];
    }
    pF.frame = (CGRect){{0,0},{pw,fBase+280}};
    [pages addObject:pF];

    // ---- 页 4: 刷怪 (刷怪蛋): 蛋格占位, 点按只记日志, 接线下一轮
    // 蛋序假设(待接线时真机验): 蛋0-14 ↔ 实体[10-16,32-39]
    // = 鸡/牛/猪/羊/狼/村民/哞菇/僵尸/爬行者/骷髅/蜘蛛/猪人/史莱姆/末影人/蠹虫
    UIView *pEgg = [[UIView alloc] init];
    pEgg.backgroundColor = [UIColor clearColor];
    UILabel *hE = [[UILabel alloc] init];
    hE.attributedText = MWBPixelText(@"刷怪", MWBPixelFont(41), MWB_COLOR(0xf0,0xee,0xea),
                                     4, 4, MWB_COLOR(0x30,0x30,0x31));
    [hE sizeToFit];
    hE.frame = (CGRect){{padL,padTop},{hE.bounds.size.width,hE.bounds.size.height}};
    [pEgg addSubview:hE];
    NSArray *eggNames = @[@"鸡", @"牛", @"猪", @"羊", @"狼",
                          @"村民", @"哞菇", @"僵尸", @"爬行者", @"骷髅",
                          @"蜘蛛", @"猪人", @"史莱姆", @"末影人", @"蠹虫"];
    CGFloat eTop = CGRectGetMaxY(hE.frame) + 20;
    CGFloat eCell = (pw - 66) / 5.0;
    for (int i = 0; i < 15; i++) {
        int r = i / 5, c = i % 5;
        UIButton *egg = [UIButton buttonWithType:UIButtonTypeCustom];
        egg.frame = (CGRect){{33 + c * eCell, eTop + r * 118},{eCell - 8, 84}};
        UIImage *eggImg = MWBGameIcon(@"items-opaque.png",
            (CGRect){{(CGFloat)(16 + (i + 1) * 16), 192},{16, 16}});
        [egg setImage:eggImg forState:UIControlStateNormal];
        egg.imageView.contentMode = UIViewContentModeScaleAspectFit;
        egg.imageView.layer.magnificationFilter = kCAFilterNearest;
        egg.tag = 100 + i;
        [egg addTarget:self action:@selector(eggTap:) forControlEvents:UIControlEventTouchUpInside];
        if (!MWB010Only()) {
            egg.alpha = 0.35;
            egg.userInteractionEnabled = NO;
        }
        [pEgg addSubview:egg];
        UILabel *en = [[UILabel alloc] init];
        en.text = eggNames[i];
        en.font = [UIFont systemFontOfSize:20];
        en.textColor = MWB_COLOR(0xcf,0xcc,0xc6);
        en.textAlignment = NSTextAlignmentCenter;
        en.frame = (CGRect){{33 + c * eCell, eTop + r * 118 + 86},{eCell - 8, 28}};
        [pEgg addSubview:en];
    }
    pEgg.frame = (CGRect){{0,0},{pw,eTop + 3 * 118 + 10}};
    [pages addObject:pEgg];

    self.pages = pages;
    self.currentPage = 0;
    for (UIView *p in pages) [_panel addSubview:p];
    [self showPage:0];
}

- (void)showPage:(NSInteger)idx {
    // 离开物品页先卸 EMI, 避免浏览器残留旧容器上
    if (_currentPage == 2 && idx != 2) [MWBEMIManager dismissBrowser];
    _currentPage = idx;
    for (NSInteger i = 0; i < _pages.count; i++) {
        _pages[i].hidden = (i != idx);
    }
    if (idx < _pages.count) {
        _panel.contentSize = _pages[idx].bounds.size;
        [_panel setContentOffset:CGPointZero animated:NO];
    }
    // 进物品页把 EMI 浏览器嵌入页内容器 (容器 tag 0xE111)
    if (idx == 2 && idx < _pages.count) {
        UIView *box = [_pages[idx] viewWithTag:0xE111];
        if (box) [MWBEMIManager presentBrowserInView:box onClose:nil];
    }
}

- (void)switchPage:(MWBSideButton *)sender {
    for (MWBSideButton *b in _sideButtons) b.active = NO;
    sender.active = YES;
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
    if (_currentPage == 2) [MWBEMIManager dismissBrowser];
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
- (void)togSlimeChunk:(MWBPixelToggle *)t {
    if (!MWB010Only()) { t.on = NO; gSlimeChunk = NO; [self toast:@"仅0.10可用"]; return; }
    gSlimeChunk = t.on;
    // 叠加画在小地图上: 打开时顺手把小地图也打开 (小地图开关不同步, 重进菜单即一致)
    if (t.on && !gMinimap) { gMinimap = YES; MWBMinimapShow(YES); [self toast:@"小地图已连带打开"]; }
}
- (void)togDebug:(MWBPixelToggle *)t {
    gMWBDebug = t.on;
    NSLog(@"[魔玩盒子] 调试模式 %@", gMWBDebug ? @"已开启" : @"已关闭");
}
- (void)setTime:(MWBPixelButton *)sender {
    int tag = (int)sender.tag;
    MWBApplyTimeTag(tag);
    if (tag == 25 || tag == 26) return;   // 微调不关菜单, 方便连点
    [self close];   // 时间是纯视觉效果, 关菜单直接看结果 (开着会被半透明面板压暗误判)
}
- (void)setWeather:(MWBPixelButton *)sender {
    if (!MWBWeatherSupported()) return;
    gWeatherMode = (int)sender.tag - 2;
    [self close];   // 同上
}
- (void)setDifficulty:(MWBPixelButton *)sender {
    int d = (int)sender.tag - 15;
    MWBSetDifficulty010(d);
    NSArray *names = @[@"和平", @"简单", @"普通", @"困难"];
    if (d >= 0 && d < 4) [self toast:[names[d] stringByAppendingString:@"(已发送)"]];
}
// 菜单内轻提示: 走悬浮窗 VC 的 showToast (无引用, 用 performSelector 避循环依赖)
- (void)toast:(NSString *)msg {
    UIViewController *vc = self.window.rootViewController;
    if ([vc respondsToSelector:@selector(showToast:)])
        [vc performSelector:@selector(showToast:) withObject:msg];
}
- (void)setFloatSize:(MWBPixelButton *)sender {
    int s = (int)sender.tag - 30;  // 0小 1中 2大
    if (s < 0 || s > 2) return;
    MWBFloatSetSize(s);
    [self toast:@[@"小悬浮窗", @"中悬浮窗", @"大悬浮窗"][s]];
}
- (void)setFloatAlpha:(MWBPixelButton *)sender {
    int a = (int)sender.tag - 33;  // 0低 1中 2高
    if (a < 0 || a > 2) return;
    MWBFloatSetAlpha(a);
    [self toast:@[@"低透明度", @"中透明度", @"高透明度"][a]];
}
- (void)resetFloat:(MWBPixelButton *)sender {
    (void)sender;
    MWBFloatReset();
    [self toast:@"悬浮窗已复位"];
}
- (void)setLang:(MWBPixelButton *)sender {
    if (!MWB010Only()) return;
    gChinese = ((int)sender.tag == 37);
    MWBApplyLang();
    [self toast:(gChinese ? @"已切中文" : @"已切英文")];
}
- (void)eggTap:(UIButton *)sender {
    int i = (int)sender.tag - 100;
    MWBLogFile(@"[刷怪蛋] 点击 idx=%d (占位, 接线下一轮)", i);
    [self toast:@"刷怪蛋接线中, 下一版可用"];
}
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
