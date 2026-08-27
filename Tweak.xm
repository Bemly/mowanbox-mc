#import <UIKit/UIKit.h>

/* ============================================================
 * 魔玩我的世界盒子 (mowanbox)
 * 目标: Minecraft PE 0.10.0  bundle: moe.bemly.mcpe.0.10
 * 形态: 游戏内悬浮按钮 + 左右两栏修改面板 (参考 Toolbox)
 * 阶段: UI 骨架已完成, 功能开关待接入游戏内 hook (见 TODO)
 * 技术: 独立 UIWindow (UIWindowLevelAlert+100) 覆盖, hitTest 透传
 * ============================================================ */

#pragma mark - 透传容器: 点到自身空白就把事件交给下面的游戏窗口

@interface MWBContainerView : UIView
@end
@implementation MWBContainerView
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    // 命中容器自身(空白区域)时返回 nil, 让触摸继续向下传递
    return (hit == self) ? nil : hit;
}
@end

#pragma mark - 覆盖窗口: 命中空白时返回 nil, 让触摸透传到游戏窗口

@interface MWBOverlayWindow : UIWindow
@end
@implementation MWBOverlayWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    // 命中 window 自身或根视图空白区域 -> 透传给下层游戏窗口
    if (hit == self || hit == self.rootViewController.view) return nil;
    return hit;
}
@end

#pragma mark - 左栏菜单项 (图标块 + 文字)

@interface MWBMenuItem : UIView
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) void (^onTap)(void);
- (instancetype)initWithIcon:(NSString *)icon title:(NSString *)title;
@end
@implementation MWBMenuItem {
    UILabel *_iconLabel;
    UILabel *_titleLabel;
}
- (instancetype)initWithIcon:(NSString *)icon title:(NSString *)title {
    if ((self = [super init])) {
        _title = [title copy];
        self.backgroundColor = [UIColor clearColor];
        _iconLabel = [[UILabel alloc] init];
        _iconLabel.text = icon;
        _iconLabel.textColor = [UIColor whiteColor];
        _iconLabel.font = [UIFont boldSystemFontOfSize:17];
        _iconLabel.textAlignment = NSTextAlignmentCenter;
        _iconLabel.backgroundColor = [UIColor colorWithWhite:1 alpha:0.15];
        _iconLabel.layer.cornerRadius = 6;
        _iconLabel.clipsToBounds = YES;
        [self addSubview:_iconLabel];
        _titleLabel = [[UILabel alloc] init];
        _titleLabel.text = title;
        _titleLabel.textColor = [UIColor whiteColor];
        _titleLabel.font = [UIFont systemFontOfSize:15];
        [self addSubview:_titleLabel];
        self.userInteractionEnabled = YES;
        [self addGestureRecognizer:[[UITapGestureRecognizer alloc]
            initWithTarget:self action:@selector(handleTap)]];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat h = self.bounds.size.height;
    _iconLabel.frame = CGRectMake(12, (h - 28) / 2, 28, 28);
    _titleLabel.frame = CGRectMake(50, 0, self.bounds.size.width - 60, h);
}
- (void)handleTap { if (self.onTap) self.onTap(); }
@end

#pragma mark - 右栏开关行

@interface MWBSwitchRow : UIView
@property (nonatomic, strong, readonly) UILabel *titleLabel;
@property (nonatomic, strong, readonly) UISwitch *toggle;
- (instancetype)initWithTitle:(NSString *)title on:(BOOL)on;
@end
@implementation MWBSwitchRow
- (instancetype)initWithTitle:(NSString *)title on:(BOOL)on {
    if ((self = [super init])) {
        self.backgroundColor = [UIColor clearColor];
        _titleLabel = [[UILabel alloc] init];
        _titleLabel.text = title;
        _titleLabel.textColor = [UIColor whiteColor];
        _titleLabel.font = [UIFont systemFontOfSize:16];
        [self addSubview:_titleLabel];
        _toggle = [[UISwitch alloc] init];
        _toggle.on = on;
        _toggle.onTintColor = [UIColor colorWithRed:0.30 green:0.85 blue:0.40 alpha:1.0];
        [self addSubview:_toggle];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat h = self.bounds.size.height, w = self.bounds.size.width;
    _titleLabel.frame = CGRectMake(16, 0, w - 80, h);
    _toggle.frame = CGRectMake(w - 60, (h - 31) / 2, 51, 31);
}
@end

#pragma mark - 右栏分段选择行 (白天/夜晚, 生存/创造)

@interface MWBSegmentRow : UIView
@property (nonatomic, strong, readonly) UISegmentedControl *seg;
- (instancetype)initWithTitle:(NSString *)title items:(NSArray *)items selected:(NSInteger)idx;
@end
@implementation MWBSegmentRow
- (instancetype)initWithTitle:(NSString *)title items:(NSArray *)items selected:(NSInteger)idx {
    if ((self = [super init])) {
        self.backgroundColor = [UIColor clearColor];
        UILabel *t = [[UILabel alloc] init];
        t.text = title;
        t.textColor = [UIColor colorWithWhite:1 alpha:0.65];
        t.font = [UIFont boldSystemFontOfSize:12];
        t.frame = CGRectMake(16, 8, 248, 18);
        t.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [self addSubview:t];
        _seg = [[UISegmentedControl alloc] initWithItems:items];
        _seg.selectedSegmentIndex = idx;
        _seg.tintColor = [UIColor colorWithRed:0.20 green:0.55 blue:1.0 alpha:1.0];
        _seg.frame = CGRectMake(16, 30, 248, 32);
        _seg.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [self addSubview:_seg];
    }
    return self;
}
@end

#pragma mark - 主控制器

@interface MWBOverlayViewController : UIViewController
@property (nonatomic, strong) UIButton *floatButton;   // 悬浮按钮
@property (nonatomic, strong) UIView *leftPanel;      // 左栏面板
@property (nonatomic, strong) UIView *rightPanel;     // 右栏面板
@end
@implementation MWBOverlayViewController

- (void)loadView {
    self.view = [[MWBContainerView alloc] init];
    self.view.backgroundColor = [UIColor clearColor];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [self setupFloatButton];
    [self setupPanels];
}

// 创建可拖动的悬浮按钮
- (void)setupFloatButton {
    _floatButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _floatButton.frame = CGRectMake(12, 220, 52, 52);
    _floatButton.backgroundColor = [UIColor colorWithRed:0.15 green:0.50 blue:0.95 alpha:0.92];
    _floatButton.layer.cornerRadius = 26;
    _floatButton.layer.borderWidth = 2;
    _floatButton.layer.borderColor = [UIColor whiteColor].CGColor;
    _floatButton.titleLabel.font = [UIFont boldSystemFontOfSize:22];
    [_floatButton setTitle:@"魔" forState:UIControlStateNormal];
    [_floatButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [_floatButton addTarget:self action:@selector(togglePanels)
           forControlEvents:UIControlEventTouchUpInside];
    // 拖动手势
    [_floatButton addGestureRecognizer:[[UIPanGestureRecognizer alloc]
        initWithTarget:self action:@selector(handlePan:)]];
    [self.view addSubview:_floatButton];
}

// 处理悬浮按钮拖动, 限制在屏幕范围内
- (void)handlePan:(UIPanGestureRecognizer *)pan {
    CGPoint t = [pan translationInView:self.view];
    CGPoint c = _floatButton.center;
    c.x += t.x; c.y += t.y;
    CGFloat r = 26, w = self.view.bounds.size.width, h = self.view.bounds.size.height;
    c.x = MAX(r, MIN(w - r, c.x));
    c.y = MAX(r + 20, MIN(h - r, c.y));
    _floatButton.center = c;
    [pan setTranslation:CGPointZero inView:self.view];
}

// 创建左右两栏面板
- (void)setupPanels {
    CGFloat sw = self.view.bounds.size.width, sh = self.view.bounds.size.height;
    UIColor *panelBG = [UIColor colorWithWhite:0 alpha:0.72];

    // ---- 左栏: 功能菜单 ----
    _leftPanel = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 200, sh)];
    _leftPanel.backgroundColor = panelBG;
    _leftPanel.autoresizingMask = UIViewAutoresizingFlexibleHeight;
    _leftPanel.hidden = YES;
    // 左栏菜单项: @[图标, 标题]
    NSArray *items = @[
        @[@"T", @"TMI"],
        @[@"物", @"添加物品"],
        @[@"兽", @"生成生物"],
        @[@"传", @"传送"],
    ];
    CGFloat y = 24;
    for (NSArray *it in items) {
        MWBMenuItem *mi = [[MWBMenuItem alloc] initWithIcon:it[0] title:it[1]];
        mi.frame = CGRectMake(0, y, 200, 48);
        mi.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        NSString *name = it[1];
        mi.onTap = ^{ NSLog(@"[魔玩盒子] 左栏菜单: %@ (功能待实现)", name); };
        [_leftPanel addSubview:mi];
        y += 52;
    }
    [self.view addSubview:_leftPanel];

    // ---- 右栏: 修改开关 ----
    _rightPanel = [[UIView alloc] initWithFrame:CGRectMake(sw - 280, 0, 280, sh)];
    _rightPanel.backgroundColor = panelBG;
    _rightPanel.autoresizingMask = UIViewAutoresizingFlexibleHeight
                                 | UIViewAutoresizingFlexibleLeftMargin;
    _rightPanel.hidden = YES;

    // 顶部标题栏 + 关闭按钮
    UIView *titleBar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 280, 44)];
    titleBar.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    UILabel *titleLabel = [[UILabel alloc] initWithFrame:CGRectMake(16, 0, 200, 44)];
    titleLabel.text = @"魔玩盒子";
    titleLabel.textColor = [UIColor whiteColor];
    titleLabel.font = [UIFont boldSystemFontOfSize:17];
    titleLabel.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [titleBar addSubview:titleLabel];
    UIButton *closeBtn = [UIButton buttonWithType:UIButtonTypeSystem];
    closeBtn.frame = CGRectMake(280 - 44, 0, 44, 44);
    closeBtn.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    [closeBtn setTitle:@"✕" forState:UIControlStateNormal];
    closeBtn.titleLabel.font = [UIFont boldSystemFontOfSize:22];
    [closeBtn setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [closeBtn addTarget:self action:@selector(togglePanels)
       forControlEvents:UIControlEventTouchUpInside];
    [titleBar addSubview:closeBtn];
    [_rightPanel addSubview:titleBar];

    CGFloat ry = 60;

    // 时间切换: 白天 / 夜晚
    MWBSegmentRow *timeRow = [[MWBSegmentRow alloc]
        initWithTitle:@"时间" items:@[@"白天", @"夜晚"] selected:0];
    timeRow.frame = CGRectMake(0, ry, 280, 72);
    timeRow.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [timeRow.seg addTarget:self action:@selector(timeChanged:)
          forControlEvents:UIControlEventValueChanged];
    [_rightPanel addSubview:timeRow]; ry += 80;

    // 游戏模式切换: 生存 / 创造
    MWBSegmentRow *modeRow = [[MWBSegmentRow alloc]
        initWithTitle:@"游戏模式" items:@[@"生存", @"创造"] selected:0];
    modeRow.frame = CGRectMake(0, ry, 280, 72);
    modeRow.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    [modeRow.seg addTarget:self action:@selector(modeChanged:)
          forControlEvents:UIControlEventValueChanged];
    [_rightPanel addSubview:modeRow]; ry += 80;

    // 功能开关项: @[标题, 默认开启]
    NSArray *switches = @[
        @[@"物品叠加×99", @NO],
        @[@"快速破坏",    @YES],
        @[@"无敌",        @YES],
        @[@"加速奔跑",    @NO],
        @[@"超级跳跃",    @NO],
    ];
    for (NSArray *s in switches) {
        MWBSwitchRow *row = [[MWBSwitchRow alloc]
            initWithTitle:s[0] on:[s[1] boolValue]];
        row.frame = CGRectMake(0, ry, 280, 44);
        row.autoresizingMask = UIViewAutoresizingFlexibleWidth;
        [row.toggle addTarget:self action:@selector(switchChanged:)
             forControlEvents:UIControlEventValueChanged];
        [_rightPanel addSubview:row]; ry += 48;
    }
    [self.view addSubview:_rightPanel];
}

// 切换面板显示/隐藏 (点击悬浮按钮或关闭按钮)
- (void)togglePanels {
    BOOL show = _leftPanel.hidden;
    if (show) {
        _leftPanel.hidden = NO; _rightPanel.hidden = NO;
        _leftPanel.alpha = 0;   _rightPanel.alpha = 0;
        _leftPanel.transform  = CGAffineTransformMakeTranslation(-200, 0);
        _rightPanel.transform = CGAffineTransformMakeTranslation(280, 0);
        [UIView animateWithDuration:0.22 animations:^{
            self->_leftPanel.alpha = 1; self->_rightPanel.alpha = 1;
            self->_leftPanel.transform = CGAffineTransformIdentity;
            self->_rightPanel.transform = CGAffineTransformIdentity;
        }];
        // 让悬浮按钮浮在面板之上, 再点一次即可关闭
        [self.view bringSubviewToFront:_floatButton];
    } else {
        [UIView animateWithDuration:0.2 animations:^{
            self->_leftPanel.alpha = 0; self->_rightPanel.alpha = 0;
            self->_leftPanel.transform  = CGAffineTransformMakeTranslation(-200, 0);
            self->_rightPanel.transform = CGAffineTransformMakeTranslation(280, 0);
        } completion:^(BOOL f){
            self->_leftPanel.hidden = YES; self->_rightPanel.hidden = YES;
        }];
    }
}

#pragma mark - 功能回调 (TODO: 接入 0.10.0 游戏内符号 hook)

- (void)timeChanged:(UISegmentedControl *)s {
    // TODO: 调用游戏内设置时间的函数
    NSLog(@"[魔玩盒子] 时间 -> %@ (功能待实现)", s.selectedSegmentIndex == 0 ? @"白天" : @"夜晚");
}
- (void)modeChanged:(UISegmentedControl *)s {
    // TODO: 调用游戏内切换游戏模式的函数
    NSLog(@"[魔玩盒子] 游戏模式 -> %@ (功能待实现)", s.selectedSegmentIndex == 0 ? @"生存" : @"创造");
}
- (void)switchChanged:(UISwitch *)s {
    // TODO: 根据开关项启用/禁用对应修改功能
    NSString *title = @"";
    if ([s.superview isKindOfClass:[MWBSwitchRow class]])
        title = ((MWBSwitchRow *)s.superview).titleLabel.text;
    NSLog(@"[魔玩盒子] 开关 [%@] -> %@ (功能待实现)", title, s.on ? @"开" : @"关");
}

@end

#pragma mark - 安装覆盖窗口

static MWBOverlayWindow *gMWBWindow = nil;

static void MWBInstallOverlay(void) {
    if (gMWBWindow) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gMWBWindow) return;
        MWBOverlayWindow *w = [[MWBOverlayWindow alloc]
            initWithFrame:[UIScreen mainScreen].bounds];
        w.windowLevel = UIWindowLevelAlert + 100;
        w.backgroundColor = [UIColor clearColor];
        w.rootViewController = [[MWBOverlayViewController alloc] init];
        w.hidden = NO;
        gMWBWindow = w;
        NSLog(@"[魔玩盒子] 悬浮窗已安装");
    });
}

%ctor {
    NSLog(@"[魔玩盒子] 插件已加载: %@",
          [[NSBundle mainBundle] bundleIdentifier]);
    // 监听游戏启动完成通知, 安装悬浮窗
    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidFinishLaunchingNotification
                    object:nil queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *n){ MWBInstallOverlay(); }];
    // 兜底: 若 dylib 加载晚于启动通知, 2 秒后再装一次
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ MWBInstallOverlay(); });
}
