/* MWBFloat.mm — 单一悬浮窗实现 (头像按钮 + 透传窗口 + 主控制器 + 安装入口) */
#import <UIKit/UIKit.h>
#import "MWBCommon.h"
#import "MWBUI.h"
#import "MWBMenu.h"
#import "MWBFloat.h"
#import "MWBAvatar.h"

#pragma mark - 悬浮按钮 (头像 logo, 无文字)

@implementation MWBFloatingButton {
    UIView *_iconBox;
    UIImageView *_iconImg;   // 悬浮窗 logo 头像 (内嵌 PNG)
}
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        // 裸 logo: 无背景无边框, 只有圆形头像 + 柔和投影
        self.backgroundColor = [UIColor clearColor];
        self.layer.borderWidth = 0;
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOffset = (CGSize){0, 2};
        self.layer.shadowRadius = 6;
        self.layer.shadowOpacity = 0.4;

        _iconBox = [[UIView alloc] init];
        _iconBox.backgroundColor = [UIColor clearColor];
        _iconBox.layer.borderWidth = 0;
        [self addSubview:_iconBox];
        _iconImg = [[UIImageView alloc] init];
        _iconImg.image = [UIImage imageWithData:[NSData dataWithBytes:kMWBAvatarPng length:kMWBAvatarPng_len]];
        _iconImg.contentMode = UIViewContentModeScaleAspectFill;
        _iconImg.clipsToBounds = YES;
        _iconImg.userInteractionEnabled = NO;
        _iconImg.backgroundColor = [UIColor clearColor];
        [_iconBox addSubview:_iconImg];

        self.userInteractionEnabled = YES;
        [self addGestureRecognizer:[[UITapGestureRecognizer alloc]
            initWithTarget:self action:@selector(handleTap)]];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
            initWithTarget:self action:@selector(handlePan:)];
        [self addGestureRecognizer:pan];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    // 纯 logo: 头像占满整个按钮, 圆形裁剪
    _iconBox.frame = self.bounds;
    _iconImg.frame = _iconBox.bounds;
    CGFloat side = MIN(_iconBox.bounds.size.width, _iconBox.bounds.size.height);
    _iconImg.layer.cornerRadius = side / 2.0;   // 圆形头像
}
- (void)handleTap { if (self.onTap) self.onTap(); }
// 圆形命中: 显示是圆, 触摸也只认圆内 (透明角不触发)
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event {
    CGFloat r = MIN(self.bounds.size.width, self.bounds.size.height) / 2.0;
    CGFloat dx = point.x - self.bounds.size.width / 2.0;
    CGFloat dy = point.y - self.bounds.size.height / 2.0;
    return (dx * dx + dy * dy) <= r * r;
}
- (void)handlePan:(UIPanGestureRecognizer *)pan {
    CGPoint t = [pan translationInView:self.superview];
    CGPoint c = self.center;
    c.x += t.x; c.y += t.y;
    CGFloat w=self.bounds.size.width, h=self.bounds.size.height;
    c.x = MAX(w/2, MIN(self.superview.bounds.size.width-w/2, c.x));
    c.y = MAX(h/2+20, MIN(self.superview.bounds.size.height-h/2, c.y));
    self.center = c;
    [pan setTranslation:CGPointZero inView:self.superview];
}
@end

#pragma mark - 透传窗口

@implementation MWBOverlayWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self || hit == self.rootViewController.view) return nil;
    return hit;
}
@end

CGFloat MWBFloatButtonSize(void);
CGFloat MWBFloatButtonAlpha(void);

#pragma mark - 主控制器

@implementation MWBViewController
- (void)loadView { self.view = [[UIView alloc] init]; self.view.backgroundColor = [UIColor clearColor]; }
- (void)viewDidLoad {
    [super viewDidLoad];
    CGFloat s = MWBFloatButtonSize();
    CGFloat sw = self.view.bounds.size.width;
    _floatButton = [[MWBFloatingButton alloc] initWithFrame:(CGRect){{sw-22-s,22},{s,s}}];
    _floatButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    _floatButton.alpha = MWBFloatButtonAlpha();
    __weak MWBViewController *ws = self;
    _floatButton.onTap = ^{ [ws toggleMenu]; };
    [self.view addSubview:_floatButton];
}
// 小地图盒子直接挂在 overlay window 上(与 rootVC.view 同级后加盖在上),
// 菜单开在 rootVC.view 里会被它压住: 开菜单藏小地图, 关菜单恢复 (tag 0x6D62 见 MWBActions)
- (void)mwbSetMinimapHidden:(BOOL)h {
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (![NSStringFromClass([w class]) containsString:@"MWBOverlay"]) continue;
        UIView *box = [w viewWithTag:0x6D62];
        if (box) box.hidden = h;
    }
}
- (void)toggleMenu {
    MWBPlayClick();
    if (_menu.superview) {
        [_menu hide];
        [self mwbSetMinimapHidden:NO];
        _floatButton.hidden = NO;
        [UIView animateWithDuration:0.15 animations:^{ self->_floatButton.alpha = 1; }];
    } else {
        // 主菜单/加载界面没有世界 tick, 只留悬浮窗, 点了也不开菜单
        if (!MWBIsInWorld()) {
            NSLog(@"[魔玩盒子] 主菜单点悬浮窗: 世界外不开菜单");
            [self showToast:@"请先进入世界"]; return;
        }
        _menu = [[MWBOptionsMenu alloc] initWithFrame:self.view.bounds];
        _menu.autoresizingMask = UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
        __weak MWBViewController *ws = self;
        _menu.onClose = ^{
            MWBViewController *ss = ws;
            if (!ss) return;
            [ss mwbSetMinimapHidden:NO];
            ss->_floatButton.hidden = NO;
            [UIView animateWithDuration:0.15 animations:^{ ss->_floatButton.alpha = 1; }];
        };
        [self mwbSetMinimapHidden:YES];
        [_menu showInView:self.view];
        [UIView animateWithDuration:0.15 animations:^{ self->_floatButton.alpha = 0; } completion:^(BOOL f){ self->_floatButton.hidden = YES; }];
    }
}
// 轻提示 (世界外点悬浮窗时用)
- (void)showToast:(NSString *)msg {
    UILabel *t = [[UILabel alloc] init];
    t.attributedText = MWBPixelText(msg, MWBPixelFont(28), kWhiteText, 2, 2, [UIColor blackColor]);
    [t sizeToFit];
    CGFloat w = t.bounds.size.width + 40, h = t.bounds.size.height + 24;
    t.frame = (CGRect){{(self.view.bounds.size.width-w)/2,(self.view.bounds.size.height-h)/2},{w,h}};
    t.textAlignment = NSTextAlignmentCenter;
    t.backgroundColor = [UIColor colorWithWhite:0 alpha:0.75];
    t.layer.cornerRadius = 8; t.clipsToBounds = YES;
    t.alpha = 0;
    [self.view addSubview:t];
    [UIView animateWithDuration:0.2 animations:^{ t.alpha = 1; } completion:^(BOOL f){
        [UIView animateWithDuration:0.3 delay:0.9 options:0 animations:^{ t.alpha = 0; }
                         completion:^(BOOL f2){ [t removeFromSuperview]; }];
    }];
}
@end

#pragma mark - 安装

static MWBOverlayWindow *gWindow = nil;

#pragma mark - 悬浮窗偏好 (自家 plist, 与游戏存档无关)

static NSString *MWBFloatPrefPath(void) {
    return @"/var/mobile/Documents/mwbfloat.plist";
}
static NSMutableDictionary *MWBFloatLoadPrefs(void) {
    NSURL *u = [NSURL fileURLWithPath:MWBFloatPrefPath()];
    NSError *e = nil;
    NSDictionary *ro =
        [NSDictionary dictionaryWithContentsOfURL:u error:&e];
    if ([ro isKindOfClass:[NSDictionary class]])
        return [ro mutableCopy];
    return [NSMutableDictionary new];
}
static const CGFloat kMWBFloatSizes[3] = {48, 64, 80};
static const CGFloat kMWBFloatAlphas[3] = {0.55, 0.8, 1.0};
static int MWBFloatSizeIdx(void) {
    int s = (int)[MWBFloatLoadPrefs()[@"size"] integerValue];
    // 未存过时 integerValue=0 会误判成"小", 用 objectForKey 区分缺省
    if (!MWBFloatLoadPrefs()[@"size"]) return 1;
    return (s < 0 || s > 2) ? 1 : s;
}
static int MWBFloatAlphaIdx(void) {
    if (!MWBFloatLoadPrefs()[@"alpha"]) return 2;
    int a = (int)[MWBFloatLoadPrefs()[@"alpha"] integerValue];
    return (a < 0 || a > 2) ? 2 : a;
}
CGFloat MWBFloatButtonSize(void) { return kMWBFloatSizes[MWBFloatSizeIdx()]; }
CGFloat MWBFloatButtonAlpha(void) { return kMWBFloatAlphas[MWBFloatAlphaIdx()]; }

void MWBFloatApplyPrefs(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!gWindow) return;
        UIViewController *rvc = gWindow.rootViewController;
        if (![rvc isKindOfClass:[MWBViewController class]]) return;
        MWBViewController *vc = (MWBViewController *)rvc;
        if (!vc.floatButton) return;
        CGFloat s = MWBFloatButtonSize();
        UIView *b = vc.floatButton;
        CGPoint c = b.center;
        if (c.x == 0 && c.y == 0)
            c = (CGPoint){b.superview.bounds.size.width - 22 - s / 2,
                          22 + s / 2};
        b.bounds = (CGRect){{0, 0}, {s, s}};
        UIView *sup = b.superview;
        if (sup) {
            CGFloat w = sup.bounds.size.width, h = sup.bounds.size.height;
            c.x = MAX(s / 2, MIN(w - s / 2, c.x));
            c.y = MAX(s / 2 + 20, MIN(h - s / 2, c.y));
            b.center = c;
        }
        b.alpha = MWBFloatButtonAlpha();
    });
}
void MWBFloatSetSize(int s) {
    if (s < 0 || s > 2) return;
    NSMutableDictionary *d = MWBFloatLoadPrefs();
    d[@"size"] = @(s);
    [d writeToURL:[NSURL fileURLWithPath:MWBFloatPrefPath()] atomically:YES];
    MWBFloatApplyPrefs();
}
void MWBFloatSetAlpha(int a) {
    if (a < 0 || a > 2) return;
    NSMutableDictionary *d = MWBFloatLoadPrefs();
    d[@"alpha"] = @(a);
    [d writeToURL:[NSURL fileURLWithPath:MWBFloatPrefPath()] atomically:YES];
    MWBFloatApplyPrefs();
}
void MWBFloatReset(void) {
    [[NSFileManager defaultManager] removeItemAtPath:MWBFloatPrefPath()
                                               error:nil];
    MWBFloatApplyPrefs();
}

void MWBInstall(void) {
    if (gWindow) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (gWindow) return;
        MWBRegisterFont();
        MWBOverlayWindow *w = [[MWBOverlayWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        w.windowLevel = UIWindowLevelAlert + 100;
        w.backgroundColor = [UIColor clearColor];
        w.rootViewController = [[MWBViewController alloc] init];
        w.hidden = NO;
        gWindow = w;
        NSLog(@"[魔玩盒子] 像素风 UI 已安装");
        // 预加载 MC 原版点击音 (静默解码, 点按时直接播)
        MWBEnsureClickLoaded();
        // 安装 EMI 物品管理器 (独立悬浮按钮)
        [MWBEMIManager install];
    });
}

// 进世界判定: 世界 tick 每帧打时间戳, 进菜单时检查新鲜度
static NSTimeInterval gLastWorldTick = 0;
void MWBMarkWorldTick(void) {
    gLastWorldTick = [[NSDate date] timeIntervalSince1970];
}
BOOL MWBIsInWorld(void) {
    return ([[NSDate date] timeIntervalSince1970] - gLastWorldTick) < 3.0;
}
