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
            [self showToast:MWBTr("enter_world")]; return;
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

#pragma mark - 触控板 (1.2 式升/降, 仅 0.10 世界内, 挂 rootVC.view 上, 菜单打开自动盖住)
// 跳用游戏原生键 (0.10 自带, 输入位直连), 不再自绘 (之前自绘跳与原生重叠还占右下角);
// 升/降样式复用 0.10 跳跃键观感 (大圆角灰钮+三角, 全代码手绘), 位置按 1.2 在右侧中部纵列

// tag 0x6D71/0x6D72 (0x6D70 跳/0x6D73 蹲已撤, 见下), 右中锚定 (旋转靠 autoresizing 贴边)
#define MWB_PAD_JUMP  0x6D70
#define MWB_PAD_UP    0x6D71
#define MWB_PAD_DOWN  0x6D72
#define MWB_PAD_SIZE  76

@interface MWBPadHelper : NSObject
+ (instancetype)shared;
- (void)padJumpDown:(UIButton *)b;   // 跳: 按住置游戏输入[0x11], aiStep 按原版离地闸起跳
- (void)padJumpUp:(UIButton *)b;
- (void)padUpDown:(UIButton *)b;     // 升: 按住置游戏输入[0x13], tick 内 aiStep 按原版速率拉升
- (void)padUpUp:(UIButton *)b;
- (void)padDownDown:(UIButton *)b;   // 降: 按住置游戏输入[0x14], 同理下降
- (void)padDownUp:(UIButton *)b;
@end

@implementation MWBPadHelper
+ (instancetype)shared {
    static MWBPadHelper *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[self alloc] init]; });
    return inst;
}
- (void)padJumpDown:(UIButton *)b { (void)b; MWBPlayClick(); gPadJump = YES; }
- (void)padJumpUp:(UIButton *)b { (void)b; gPadJump = NO; }
- (void)padUpDown:(UIButton *)b { (void)b; gFlyUp = YES; }
- (void)padUpUp:(UIButton *)b { (void)b; gFlyUp = NO; }
- (void)padDownDown:(UIButton *)b { (void)b; gFlyDown = YES; }
- (void)padDownUp:(UIButton *)b { (void)b; gFlyDown = NO; }
@end

// 原生风触控钮 (复用 0.10 跳跃键观感: 灰渐变圆角 + 深色三角; 全代码手绘, 不打包贴图)
@interface MWBNativePadButton : UIControl
@property (nonatomic) BOOL pointUp;   // YES=▲升 / NO=▼降
@end

@implementation MWBNativePadButton {
    CAGradientLayer *_face;
    CAShapeLayer *_tri;
}
- (instancetype)initWithUp:(BOOL)up {
    if ((self = [super initWithFrame:CGRectZero])) {
        _pointUp = up;
        self.backgroundColor = [UIColor clearColor];
        self.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleTopMargin;
        self.alpha = 0.85;
        _face = [CAGradientLayer layer];
        _face.colors = @[(id)MWB_COLOR(0xd8,0xd8,0xd8).CGColor,
                         (id)MWB_COLOR(0xa8,0xa8,0xa8).CGColor];
        _face.cornerRadius = 12;
        _face.borderWidth = 3;
        _face.borderColor = MWB_COLOR(0x37,0x37,0x37).CGColor;
        [self.layer addSublayer:_face];
        _tri = [CAShapeLayer layer];
        _tri.fillColor = MWB_COLOR(0x3f,0x3f,0x3f).CGColor;
        [self.layer addSublayer:_tri];
        MWBPadHelper *h = [MWBPadHelper shared];
        if (up) {
            [self addTarget:h action:@selector(padUpDown:) forControlEvents:UIControlEventTouchDown];
            [self addTarget:h action:@selector(padUpUp:)
                forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
        } else {
            [self addTarget:h action:@selector(padDownDown:) forControlEvents:UIControlEventTouchDown];
            [self addTarget:h action:@selector(padDownUp:)
                forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
        }
        self.hidden = YES;
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    _face.frame = self.bounds;
    // 三角占钮宽 44%, 居中 (升▲/降▼)
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    CGFloat tw = w * 0.44, th = h * 0.34;
    CGFloat cx = w / 2, cy = h / 2;
    UIBezierPath *p = [UIBezierPath bezierPath];
    if (_pointUp) {
        [p moveToPoint:(CGPoint){cx, cy - th / 2}];
        [p addLineToPoint:(CGPoint){cx + tw / 2, cy + th / 2}];
        [p addLineToPoint:(CGPoint){cx - tw / 2, cy + th / 2}];
    } else {
        [p moveToPoint:(CGPoint){cx, cy + th / 2}];
        [p addLineToPoint:(CGPoint){cx + tw / 2, cy - th / 2}];
        [p addLineToPoint:(CGPoint){cx - tw / 2, cy - th / 2}];
    }
    [p closePath];
    _tri.path = p.CGPath;
    _tri.frame = self.bounds;
}
- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    self.alpha = highlighted ? 0.6 : 0.85;
}
// 按键统一 MC 点击音
- (void)sendAction:(SEL)action to:(id)target forEvent:(UIEvent *)event {
    MWBPlayClick();
    [super sendAction:action to:target forEvent:event];
}
@end

// 原生跳跃区搬迁 (0.10 的跳是方向键正中那颗独立触控区, 无独立键;
// 1.2 式分离 = 把它整体搬到右侧, 游戏自己画+自己判, 像素级原生)。
// 命名槽位 0x29~0x31 (rect 在 +0xc~+0x18, 反编译实锤), 每 20 tick 自愈一次
// (旋转/重建布局后矩形会被打回原形, 自动重搬)。成功搬迁后自绘跳退场当纯兜底。
static void *sJumpArea010 = NULL;
static BOOL sJumpLive010 = NO;
static void MWBRelocateJumpPad(void) {
    void *touch = gTouchInput010;
    if (!touch) return;
    uintptr_t vtab = MWBMainSlide() + 0x1003015b0UL;
    // 先取全区最大范围当屏幕尺寸 (单位自适应, 点还是像素都不怕)
    float W = 0, H = 0;
    void *slots[9];
    for (int i = 0; i < 9; i++) {
        void *a = *(void **)((char *)touch + (0x29 + i) * 8);
        slots[i] = (a && *(void **)a == (void *)vtab) ? a : NULL;
        if (!slots[i]) continue;
        float x1 = *(float *)((char *)a + 0x10);
        float y1 = *(float *)((char *)a + 0x18);
        if (x1 > W) W = x1;
        if (y1 > H) H = y1;
    }
    if (W <= 0 || H <= 0) return;
    float tCX = W - 110.0f * (W / 1024.0f);   // 目标中心: 右侧, 高度对齐方向键中下部
    float tCY = H - 180.0f * (H / 768.0f);
    // 已搬且矩形还在目标位 → 无事可做
    if (sJumpArea010) {
        float x0 = *(float *)((char *)sJumpArea010 + 0xc);
        float x1 = *(float *)((char *)sJumpArea010 + 0x10);
        float y0 = *(float *)((char *)sJumpArea010 + 0x14);
        float y1 = *(float *)((char *)sJumpArea010 + 0x18);
        if (fabsf((x0 + x1) * 0.5f - tCX) < 2 && fabsf((y0 + y1) * 0.5f - tCY) < 2) {
            sJumpLive010 = YES;
            return;
        }
        sJumpArea010 = NULL;   // 布局重建了, 重新找
    }
    // 收左半屏小矩形 (方向键簇), 取形心最近的当正中那颗
    void *cand[9];
    float ccx[9], ccy[9], cwid[9], chgt[9];
    int m = 0;
    for (int i = 0; i < 9; i++) {
        void *a = slots[i];
        if (!a) continue;
        float x0 = *(float *)((char *)a + 0xc);
        float x1 = *(float *)((char *)a + 0x10);
        float y0 = *(float *)((char *)a + 0x14);
        float y1 = *(float *)((char *)a + 0x18);
        float w = x1 - x0, h = y1 - y0;
        if (w < 10 || h < 10 || w > H * 0.5 || h > H * 0.5) continue;   // 过滤大条幅
        if (x1 > W * 0.6 || y0 < 0 || y1 > H) continue;                 // 只要左半屏内
        cand[m] = a;
        ccx[m] = (x0 + x1) * 0.5f; ccy[m] = (y0 + y1) * 0.5f;
        cwid[m] = w; chgt[m] = h;
        m++;
    }
    if (m < 3) {
        static int sLogged = 0;
        if ((sLogged++ % 50) == 0)
            MWBLogFile(@"[010触控] 跳跃区扫描: 左半小矩形仅 %d 个, 不搬", m);
        return;
    }
    float gx = 0, gy = 0;
    for (int i = 0; i < m; i++) { gx += ccx[i]; gy += ccy[i]; }
    gx /= m; gy /= m;
    int best = 0;
    float bd2 = 1e30f;
    for (int i = 0; i < m; i++) {
        float dx = ccx[i] - gx, dy = ccy[i] - gy, d2 = dx * dx + dy * dy;
        if (d2 < bd2) { bd2 = d2; best = i; }
    }
    // 包围校验: 正中那颗的中心必须严格落在其他几颗中心的外包框里 (十字形才成立)
    float mix = 1e30f, max = -1e30f, miy = 1e30f, may = -1e30f;
    for (int i = 0; i < m; i++) {
        if (i == best) continue;
        if (ccx[i] < mix) mix = ccx[i];
        if (ccx[i] > max) max = ccx[i];
        if (ccy[i] < miy) miy = ccy[i];
        if (ccy[i] > may) may = ccy[i];
    }
    if (!(ccx[best] > mix && ccx[best] < max && ccy[best] > miy && ccy[best] < may)) {
        static int sLogged2 = 0;
        if ((sLogged2++ % 50) == 0)
            MWBLogFile(@"[010触控] 跳跃区扫描: %d 个但正中校验不过, 不搬", m);
        return;
    }
    void *a = cand[best];
    float w = cwid[best], h = chgt[best];
    MWBLogFile(@"[010触控] 搬跳跃区 %p 原矩形[(%.0f,%.0f)-(%.0f,%.0f)]→目标中心(%.0f,%.0f)",
               a, (double)(ccx[best] - w / 2), (double)(ccy[best] - h / 2),
               (double)(ccx[best] + w / 2), (double)(ccy[best] + h / 2),
               (double)tCX, (double)tCY);
    *(float *)((char *)a + 0xc) = tCX - w / 2;
    *(float *)((char *)a + 0x10) = tCX + w / 2;
    *(float *)((char *)a + 0x14) = tCY - h / 2;
    *(float *)((char *)a + 0x18) = tCY + h / 2;
    sJumpArea010 = a;
    sJumpLive010 = YES;
}

// 显隐同步 (game 线调进来也安全, 统一弹主线程; 菜单打开时面板盖住钮, 关菜单后下次同步恢复)
void MWBPadSync(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *w = nil;
        for (UIWindow *ww in [UIApplication sharedApplication].windows)
            if ([NSStringFromClass([ww class]) containsString:@"MWBOverlay"]) { w = ww; break; }
        if (!w) return;
        UIViewController *vc = w.rootViewController;
        if (!vc) return;
        UIView *host = vc.view;
        MWBRelocateJumpPad();   // 原生跳先搬 (成功则自绘跳退场当纯兜底)
        MWBNativePadButton *jump = (MWBNativePadButton *)[host viewWithTag:MWB_PAD_JUMP];
        if (!jump) {
            jump = [[MWBNativePadButton alloc] initWithUp:YES];
            jump.tag = MWB_PAD_JUMP;
            [host addSubview:jump];
            MWBNativePadButton *up = [[MWBNativePadButton alloc] initWithUp:YES];
            up.tag = MWB_PAD_UP;
            [host addSubview:up];
            MWBNativePadButton *down = [[MWBNativePadButton alloc] initWithUp:NO];
            down.tag = MWB_PAD_DOWN;
            [host addSubview:down];
            // 清掉旧版像素风按钮残留
            [[host viewWithTag:0x6D73] removeFromSuperview];
            jump = (MWBNativePadButton *)[host viewWithTag:MWB_PAD_JUMP];
        }
        // 三钮触摸接线 (创建时只定样式, 手势每次重绑防复用串线)
        MWBPadHelper *ph = [MWBPadHelper shared];
        MWBNativePadButton *up = (MWBNativePadButton *)[host viewWithTag:MWB_PAD_UP];
        MWBNativePadButton *down = (MWBNativePadButton *)[host viewWithTag:MWB_PAD_DOWN];
        void (^wireHold)(MWBNativePadButton *, SEL, SEL) = ^(MWBNativePadButton *b, SEL dn, SEL upSEL) {
            [b removeTarget:nil action:NULL forControlEvents:UIControlEventAllEvents];
            [b addTarget:ph action:dn forControlEvents:UIControlEventTouchDown];
            [b addTarget:ph action:upSEL forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
        };
        wireHold(jump, @selector(padJumpDown:), @selector(padJumpUp:));
        wireHold(up, @selector(padUpDown:), @selector(padUpUp:));
        wireHold(down, @selector(padDownDown:), @selector(padDownUp:));
        // 右侧纵列 (1.2 式分离布局: 跳/升同位上格, 飞时跳变升、降在下格;
        // 高度对齐方向键中部 (bh-188), 不贴右下角, 降钮 x 与快捷栏错开不重叠)
        CGFloat bw = host.bounds.size.width, bh = host.bounds.size.height;
        CGFloat s = MWB_PAD_SIZE;
        CGFloat cx = bw - 12 - s;
        CGFloat yTop = bh - 12 - s * 2 - 8;
        jump.frame = (CGRect){{cx, yTop}, {s, s}};
        up.frame = jump.frame;
        down.frame = (CGRect){{cx, yTop + s + 8}, {s, s}};
        // 显隐: 世界外/非 0.10 全藏; 非飞行只露跳, 飞行时跳换升+降
        BOOL inWorld = MWBIsInWorld();
        BOOL is010 = (gGV == (int)MWBGameV0_10);
        BOOL flying = gFly;
        if (inWorld && is010 && gLocalPlayer) {
            char *abil = (char *)gLocalPlayer + PLAYER_ABILITIES_OFFSET;
            if (abil[ABIL_FLYING]) flying = YES;   // 野生飞行 (创造档自带) 也认
        }
        // 自绘跳是纯兜底: 原生区搬过去就退场, 搬不动才露出来顶着
        jump.hidden = !(inWorld && is010 && !flying && !sJumpLive010);
        up.hidden = down.hidden = !(inWorld && is010 && flying);
    });
}

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
