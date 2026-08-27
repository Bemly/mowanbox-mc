#import <UIKit/UIKit.h>
#import <CoreText/CoreText.h>
#import <substrate.h>
#import "FusionPixel.h"

/* ============================================================
 * 魔玩我的世界盒子 (mowanbox-mc)
 * 目标: Minecraft PE 0.10.0  bundle: moe.bemly.mcpe.0.10
 * UI:   像素风 Options 菜单 (1:1 移植自 Toolbox 参考样式)
 *       纯 UIKit + CALayer 原生实现, 无 WebView, 保证性能
 * 功能: Cydia Substrate hook C++ 游戏函数
 * ============================================================ */

#pragma mark - 像素配色 (与参考 CSS 变量一一对应)

#define MWB_COLOR(r,g,b)  [UIColor colorWithRed:(r)/255.0 green:(g)/255.0 blue:(b)/255.0 alpha:1.0]

static UIColor *kTopBar;          // #777078 顶栏
static UIColor *kSidebar;         // #a69d99 侧栏
static UIColor *kSidebarLight;    // #c3bbb6
static UIColor *kSidebarDark;     // #655f5f
static UIColor *kInk;             // #343132
static UIColor *kWhiteText;       // #eeeae6
static UIColor *kPanelBG;         // rgba(15,16,14,0.66)
static UIColor *kField;           // #302d2e
static UIColor *kControl;         // #c5bcba
static UIColor *kControlLight;    // #eee9e5
static UIColor *kControlDark;     // #6b6668

static UIFont *MWBPixelFont(CGFloat size) {
    UIFont *f = [UIFont fontWithName:@"Fusion-Pixel-8px-Prop-zh_hans-Regular" size:size];
    if (!f) f = [UIFont fontWithName:@"Fusion Pixel 8px Prop zh_hans" size:size];
    return f ?: [UIFont systemFontOfSize:size];
}

// 注册内嵌的 Pixelify Sans 字体
static void MWBRegisterFont(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        kTopBar        = MWB_COLOR(0x77,0x70,0x78);
        kSidebar       = MWB_COLOR(0xa6,0x9d,0x99);
        kSidebarLight  = MWB_COLOR(0xc3,0xbb,0xb6);
        kSidebarDark   = MWB_COLOR(0x65,0x5f,0x5f);
        kInk           = MWB_COLOR(0x34,0x31,0x32);
        kWhiteText     = MWB_COLOR(0xee,0xea,0xe6);
        kPanelBG       = [UIColor colorWithRed:15/255.0 green:16/255.0 blue:14/255.0 alpha:0.66];
        kField         = MWB_COLOR(0x30,0x2d,0x2e);
        kControl       = MWB_COLOR(0xc5,0xbc,0xba);
        kControlLight  = MWB_COLOR(0xee,0xe9,0xe5);
        kControlDark   = MWB_COLOR(0x6b,0x66,0x68);

        CGDataProviderRef provider = CGDataProviderCreateWithData(NULL, kFusionPixelFont, kFusionPixelFont_len, NULL);
        CGFontRef cgFont = CGFontCreateWithDataProvider(provider);
        if (cgFont) { CTFontManagerRegisterGraphicsFont(cgFont, NULL); CGFontRelease(cgFont); }
        CGDataProviderRelease(provider);
    });
}

// 创建带像素阴影的属性字符串
static NSAttributedString *MWBPixelText(NSString *text, UIFont *font, UIColor *color,
                                        CGFloat shadowX, CGFloat shadowY, UIColor *shadowColor) {
    NSShadow *s = [[NSShadow alloc] init];
    s.shadowColor = shadowColor;
    s.shadowOffset = CGSizeMake(shadowX, shadowY);
    s.shadowBlurRadius = 0;
    return [[NSAttributedString alloc] initWithString:text attributes:@{
        NSFontAttributeName: font,
        NSForegroundColorAttributeName: color,
        NSShadowAttributeName: s,
    }];
}

#pragma mark - 像素边框视图 (模拟 CSS border + inset box-shadow)

@interface MWBPixelView : UIView
// 外边框 (4px 深色)
@property (nonatomic) CGFloat outerWidth;
@property (nonatomic, strong) UIColor *outerColor;
// 内阴影 (左上浅色 / 右下深色)
@property (nonatomic) CGFloat insetWidth;
@property (nonatomic, strong) UIColor *insetLight;
@property (nonatomic, strong) UIColor *insetDark;
@end
@implementation MWBPixelView {
    CALayer *_top, *_left, *_bottom, *_right;
}
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        _outerWidth = 4; _insetWidth = 4;
        _outerColor = MWB_COLOR(0x2b,0x29,0x2a);
        _insetLight = kSidebarLight;
        _insetDark = kSidebarDark;
        self.layer.magnificationFilter = kCAFilterNearest;
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    CGFloat o = _outerWidth, i = _insetWidth;
    self.layer.borderWidth = o;
    self.layer.borderColor = _outerColor.CGColor;
    if (!_top) {
        _top = [CALayer layer]; _left = [CALayer layer];
        _bottom = [CALayer layer]; _right = [CALayer layer];
        [self.layer addSublayer:_top]; [self.layer addSublayer:_left];
        [self.layer addSublayer:_bottom]; [self.layer addSublayer:_right];
    }
    _top.frame = CGRectMake(o, o, w - 2*o, i); _top.backgroundColor = _insetLight.CGColor;
    _left.frame = CGRectMake(o, o, i, h - 2*o); _left.backgroundColor = _insetLight.CGColor;
    _bottom.frame = CGRectMake(o, h - o - i, w - 2*o, i); _bottom.backgroundColor = _insetDark.CGColor;
    _right.frame = CGRectMake(w - o - i, o, i, h - 2*o); _right.backgroundColor = _insetDark.CGColor;
}
@end

#pragma mark - SVG path 解析 (支持 M/L/H/V/Z 及小写相对命令)

static UIBezierPath *MWBPathFromSVG(NSString *d) {
    UIBezierPath *p = [UIBezierPath bezierPath];
    CGFloat x = 0, y = 0, sx = 0, sy = 0;
    __block NSUInteger i = 0, n = d.length;
    static NSCharacterSet *numStart;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ numStart = [NSCharacterSet characterSetWithCharactersInString:@"-0123456789."]; });

    CGFloat (^readNum)(void) = ^CGFloat{
        while (i < n) { unichar c=[d characterAtIndex:i]; if(c==' '||c==','||c=='\n') i++; else break; }
        CGFloat sign=1, num=0, frac=0, div=1; BOOL dot=NO;
        if (i<n && [d characterAtIndex:i]=='-') { sign=-1; i++; }
        while (i<n) {
            unichar c=[d characterAtIndex:i];
            if (c>='0'&&c<='9') { if(dot){frac=frac*10+(c-'0');div*=10;} else num=num*10+(c-'0'); i++; }
            else if (c=='.'&&!dot) { dot=YES; i++; } else break;
        }
        return sign*(num+frac/div);
    };
    BOOL (^atNum)(void) = ^{ while(i<n){unichar c=[d characterAtIndex:i]; if(c==' '||c==',')i++; else break;} return i<n && [numStart characterIsMember:[d characterAtIndex:i]]; };

    while (i < n) {
        while (i<n) { unichar c=[d characterAtIndex:i]; if(c==' '||c==','||c=='\n')i++; else break; }
        if (i>=n) break;
        unichar cmd = [d characterAtIndex:i];
        if (![[NSCharacterSet letterCharacterSet] characterIsMember:cmd]) break;
        i++;
        switch (cmd) {
            case 'M': x=readNum(); y=readNum(); sx=x; sy=y; [p moveToPoint:CGPointMake(x,y)];
                      while(atNum()){ x=readNum(); y=readNum(); [p addLineToPoint:CGPointMake(x,y)]; } break;
            case 'L': while(atNum()){ x=readNum(); y=readNum(); [p addLineToPoint:CGPointMake(x,y)]; } break;
            case 'H': while(atNum()){ x=readNum(); [p addLineToPoint:CGPointMake(x,y)]; } break;
            case 'V': while(atNum()){ y=readNum(); [p addLineToPoint:CGPointMake(x,y)]; } break;
            case 'm': x+=readNum(); y+=readNum(); sx=x; sy=y; [p moveToPoint:CGPointMake(x,y)]; break;
            case 'l': while(atNum()){ x+=readNum(); y+=readNum(); [p addLineToPoint:CGPointMake(x,y)]; } break;
            case 'h': while(atNum()){ x+=readNum(); [p addLineToPoint:CGPointMake(x,y)]; } break;
            case 'v': while(atNum()){ y+=readNum(); [p addLineToPoint:CGPointMake(x,y)]; } break;
            case 'Z': case 'z': [p closePath]; x=sx; y=sy; break;
            default: break;
        }
    }
    return p;
}

#pragma mark - 像素开关 (两格 i/b 样式)

@interface MWBPixelToggle : UIControl
@property (nonatomic, getter=isOn) BOOL on;
@end
@implementation MWBPixelToggle {
    UIView *_i, *_b;  // 左格 / 右格
}
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = MWB_COLOR(0x9c,0x96,0x95);
        self.layer.borderWidth = 5;
        self.layer.borderColor = MWB_COLOR(0x68,0x63,0x66).CGColor;
        // 外框内阴影
        UIView *hl = [[UIView alloc] init]; hl.backgroundColor = MWB_COLOR(0xc7,0xc0,0xbd);
        UIView *sh = [[UIView alloc] init]; sh.backgroundColor = MWB_COLOR(0x4f,0x4c,0x4e);
        hl.autoresizingMask = UIViewAutoresizingFlexibleRightMargin|UIViewAutoresizingFlexibleBottomMargin;
        sh.autoresizingMask = UIViewAutoresizingFlexibleTopMargin|UIViewAutoresizingFlexibleLeftMargin;
        [self addSubview:hl]; [self addSubview:sh];
        objc_setAssociatedObject(hl, "isHL", @YES, OBJC_ASSOCIATION_RETAIN_NONATOMIC);

        _i = [[UIView alloc] init]; _b = [[UIView alloc] init];
        _i.layer.borderWidth = 4; _b.layer.borderWidth = 4;
        [self addSubview:_i]; [self addSubview:_b];
        [self addTarget:self action:@selector(toggle) forControlEvents:UIControlEventTouchUpInside];
        [self applyStyle];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w=self.bounds.size.width, h=self.bounds.size.height, pad=7;
    // 内阴影条
    for (UIView *v in self.subviews) {
        if (v == _i || v == _b) continue;
        if ([objc_getAssociatedObject(v, "isHL") boolValue]) v.frame = CGRectMake(5,5,w-10,4);
        else v.frame = CGRectMake(5,h-9,w-10,4);
    }
    CGFloat cellW = (w - pad*2 - 4) / 2;
    _i.frame = CGRectMake(pad, pad, cellW, h - pad*2);
    _b.frame = CGRectMake(pad + cellW + 4, pad, cellW, h - pad*2);
}
- (void)toggle { self.on = !_on; [self sendActionsForControlEvents:UIControlEventValueChanged]; }
- (void)setOn:(BOOL)on { _on = on; [self applyStyle]; }
- (void)applyStyle {
    if (_on) {
        _i.backgroundColor = MWB_COLOR(0xe7,0xdd,0xdc);
        _i.layer.borderColor = MWB_COLOR(0xa5,0x9f,0xa0).CGColor;
        _b.backgroundColor = MWB_COLOR(0xff,0xfd,0xfd);
        _b.layer.borderColor = MWB_COLOR(0xc6,0xbe,0xc0).CGColor;
    } else {
        _i.backgroundColor = MWB_COLOR(0xc6,0xbd,0xbb);
        _i.layer.borderColor = MWB_COLOR(0x70,0x6b,0x6c).CGColor;
        _b.backgroundColor = MWB_COLOR(0x77,0x71,0x73);
        _b.layer.borderColor = MWB_COLOR(0x4d,0x4a,0x4b).CGColor;
    }
}
@end

#pragma mark - 像素按钮 (Back / 分类按钮)

@interface MWBPixelButton : UIButton
@end
@implementation MWBPixelButton
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.layer.borderWidth = 4;
        self.layer.borderColor = MWB_COLOR(0x31,0x2e,0x2f).CGColor;
        self.backgroundColor = MWB_COLOR(0xb3,0xa8,0xa3);
        self.adjustsImageWhenHighlighted = NO;
    }
    return self;
}
- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    if (highlighted) {
        self.backgroundColor = MWB_COLOR(0x77,0x70,0x6e);
        self.transform = CGAffineTransformMakeTranslation(2, 2);
    } else {
        self.backgroundColor = MWB_COLOR(0xb3,0xa8,0xa3);
        self.transform = CGAffineTransformIdentity;
    }
}
- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGFloat w=rect.size.width, h=rect.size.height, b=4;
    // 内阴影: 左上浅色, 右下深色
    CGContextSetFillColorWithColor(ctx, MWB_COLOR(0xd5,0xce,0xca).CGColor);
    CGContextFillRect(ctx, CGRectMake(b,b,w-2*b,b)); // top
    CGContextFillRect(ctx, CGRectMake(b,b,b,h-2*b)); // left
    CGContextSetFillColorWithColor(ctx, MWB_COLOR(0x77,0x70,0x6e).CGColor);
    CGContextFillRect(ctx, CGRectMake(b,h-2*b,w-2*b,b)); // bottom
    CGContextFillRect(ctx, CGRectMake(w-2*b,b,b,h-2*b)); // right
}
@end

#pragma mark - 侧栏图标按钮

@interface MWBSideButton : UIControl
@property (nonatomic, getter=isActive) BOOL active;
- (instancetype)initWithSVGPaths:(NSArray<NSString *> *)paths;
@end
@implementation MWBSideButton {
    NSMutableArray<CAShapeLayer *> *_shapeLayers;
}
- (instancetype)initWithSVGPaths:(NSArray<NSString *> *)paths {
    if ((self = [super init])) {
        self.backgroundColor = MWB_COLOR(0xad,0xa4,0xa0);
        self.layer.borderWidth = 0;
        _shapeLayers = [NSMutableArray array];
        for (NSString *svg in paths) {
            CAShapeLayer *s = [CAShapeLayer layer];
            s.path = [MWBPathFromSVG(svg) CGPath];
            s.fillColor = MWB_COLOR(0x4b,0x47,0x49).CGColor;
            s.strokeColor = MWB_COLOR(0x2f,0x2d,0x2e).CGColor;
            s.lineWidth = 2;
            s.lineJoin = kCALineJoinMiter;
            [self.layer addSublayer:s];
            [_shapeLayers addObject:s];
        }
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w=self.bounds.size.width, h=self.bounds.size.height, pad=w*0.13;
    CGFloat s = MIN(w,h) - pad*2;
    CGFloat ox = (w-s)/2, oy=(h-s)/2;
    // 缩放 64x64 viewBox 到实际尺寸
    CGAffineTransform t = CGAffineTransformMakeScale(s/64.0, s/64.0);
    for (CAShapeLayer *layer in _shapeLayers) {
        CGPathRef scaled = CGPathCreateCopyByTransformingPath(layer.path, &t);
        layer.path = scaled;
        CGPathRelease(scaled);
        layer.frame = CGRectMake(ox, oy, s, s);
        layer.bounds = CGRectMake(0, 0, s, s);
        layer.position = CGPointMake(w/2, h/2);
    }
}
- (void)setActive:(BOOL)active {
    _active = active;
    self.backgroundColor = active ? MWB_COLOR(0xb8,0xaf,0xab) : MWB_COLOR(0xad,0xa4,0xa0);
}
- (void)setHighlighted:(BOOL)highlighted {
    [super setHighlighted:highlighted];
    if (highlighted) self.transform = CGAffineTransformMakeTranslation(2, 2);
    else self.transform = CGAffineTransformIdentity;
}
- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGFloat w=rect.size.width, h=rect.size.height;
    // 左边 4px #6a6463, 右边 4px #d3ccc7, 上边 4px #cabfba, 下边 5px #565253
    CGContextSetFillColorWithColor(ctx, MWB_COLOR(0x6a,0x64,0x63).CGColor);
    CGContextFillRect(ctx, CGRectMake(0,0,4,h));
    CGContextSetFillColorWithColor(ctx, MWB_COLOR(0xd3,0xcc,0xc7).CGColor);
    CGContextFillRect(ctx, CGRectMake(w-4,0,4,h));
    CGContextSetFillColorWithColor(ctx, MWB_COLOR(0xca,0xbf,0xba).CGColor);
    CGContextFillRect(ctx, CGRectMake(0,0,w,4));
    CGContextSetFillColorWithColor(ctx, MWB_COLOR(0x56,0x52,0x53).CGColor);
    CGContextFillRect(ctx, CGRectMake(0,h-5,w,5));
}
@end

#pragma mark - 设置行 (标签 + 控件)

@interface MWBSettingRow : UIView
@property (nonatomic, strong, readonly) UILabel *label;
@property (nonatomic, strong) UIView *control;
- (instancetype)initWithLabel:(NSString *)text control:(UIView *)control;
@end
@implementation MWBSettingRow
- (instancetype)initWithLabel:(NSString *)text control:(UIView *)control {
    if ((self = [super init])) {
        _label = [[UILabel alloc] init];
        _label.backgroundColor = [UIColor clearColor];
        _label.numberOfLines = 1;
        [self addSubview:_label];
        _control = control;
        [self addSubview:control];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w=self.bounds.size.width, h=self.bounds.size.height;
    CGFloat labelW = MIN(445, w - 180);
    _label.frame = CGRectMake(0, 0, labelW, h);
    CGSize cs = _control.intrinsicContentSize;
    if (cs.width <= 0 || cs.height <= 0) cs = _control.bounds.size;
    CGFloat cw = 152, ch = 77;
    if ([_control isKindOfClass:[MWBPixelToggle class]]) { cw=152; ch=77; }
    else if ([_control isKindOfClass:[MWBPixelButton class]]) { cw=120; ch=60; }
    _control.frame = CGRectMake(w - cw, (h-ch)/2, cw, ch);
}
@end

#pragma mark - 功能开关全局状态

static BOOL gInvincible  = YES;
static BOOL gFly         = NO;
static BOOL gFastBreak   = YES;
static BOOL gSpeed       = NO;
static BOOL gSuperJump   = NO;
static int  gTimeMode    = 0;  // 0=不修改 1=白天 2=夜晚

static void *gLocalPlayer = NULL;
static void *gLevel       = NULL;

#define PLAYER_ABILITIES_OFFSET   5824
#define ABIL_INVULNERABLE 0
#define ABIL_FLYING 1
#define ABIL_MAY_FLY 2
#define ABIL_INSTABUILD 3
#define LEVEL_TIME_OFFSET 5512
#define ENTITY_VELOCITY_Y_OFFSET 112
#define TICK_TIME_DAY 1000
#define TICK_TIME_NIGHT 13000

#pragma mark - 选项菜单主视图

@interface MWBOptionsMenu : UIView
@property (nonatomic, copy) void (^onClose)(void);
@property (nonatomic, strong) NSArray<UIView *> *pages;
@property (nonatomic) NSInteger currentPage;
- (void)showInView:(UIView *)view;
- (void)hide;
@end
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
    _topBar = [[UIView alloc] initWithFrame:CGRectMake(0, 0, self.bounds.size.width, barH)];
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

    _topBar.frame = CGRectMake(0, 0, self.bounds.size.width, barH);
    topLight.frame = CGRectMake(0, 0, _topBar.bounds.size.width, 5);
    bottomDark.frame = CGRectMake(0, barH-7, _topBar.bounds.size.width, 7);
    innerShadow.frame = CGRectMake(0, barH-12, _topBar.bounds.size.width, 5);
    _backButton.frame = CGRectMake(16, 10, 132, barH-20);
    title.frame = CGRectMake(148, 0, _topBar.bounds.size.width-296, barH);
}

- (void)setupBody {
    CGFloat barH = 104;
    CGFloat sideW = 137;
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;

    // 左侧导航
    _sideNav = [[UIView alloc] initWithFrame:CGRectMake(0, barH, sideW, h-barH)];
    _sideNav.autoresizingMask = UIViewAutoresizingFlexibleHeight;
    _sideNav.backgroundColor = kSidebar;
    [self addSubview:_sideNav];
    // 右侧内阴影
    UIView *navEdge = [[UIView alloc] init];
    navEdge.backgroundColor = MWB_COLOR(0x74,0x6e,0x6d);
    navEdge.autoresizingMask = UIViewAutoresizingFlexibleHeight|UIViewAutoresizingFlexibleLeftMargin;
    [_sideNav addSubview:navEdge];
    navEdge.frame = CGRectMake(sideW-5, 0, 5, _sideNav.bounds.size.height);

    // 4 个分类图标 (SVG path 与参考一致)
    NSArray *icons = @[
        @[@"M10 8h18v7h-5v5l25 25 4-4 7 7-11 11-7-7 4-4-25-25h-5v5H8V10z",
          @"M48 7h9v9l-7 7-7-2-19 19-6 10-7 7-4-4 7-7 10-6 19-19-2-7z"],
        @[@"M5 7h25v22H5zm4 5v5h7v-5zm11 0v5h6v-5zM34 7h25v22H34zm4 5v5h7v-5zm11 0v5h6v-5zM5 34h25v22H5zm4 5v5h7v-5zm11 0v5h6v-5zM34 34h25v22H34zm4 5v5h7v-5zm11 0v5h6v-5z"],
        @[@"M18 17h28l8 7 6 22-5 10h-9L36 45h-8L18 56H9L4 46l6-22zm-2 10v7h-7v8h7v7h8v-7h7v-8h-7v-7zm27 5v7h7v-7zm8 9v7h7v-7z"],
        @[@"M27 5h9v12h-9zM8 14h9v9H8zm38 1h9v9h-9zM18 24h10v10H18zm19-2h10v10H37zM5 36h10v10H5zm49-4h8v11h-8zM26 39h12v12H26zm-13 10h9v10h-9zm32-9h10v11H45zM35 54h8v8h-8z"],
    ];
    NSMutableArray *btns = [NSMutableArray array];
    CGFloat btnPad = 18, btnTop = 34;
    CGFloat btnSize = sideW - btnPad*2;
    for (int i = 0; i < 4; i++) {
        MWBSideButton *b = [[MWBSideButton alloc] initWithSVGPaths:icons[i]];
        b.frame = CGRectMake(btnPad, btnTop + i*(btnSize+6), btnSize, btnSize);
        b.tag = i;
        b.active = (i == 0);
        [b addTarget:self action:@selector(switchPage:) forControlEvents:UIControlEventTouchUpInside];
        [_sideNav addSubview:b];
        [btns addObject:b];
    }
    _sideButtons = btns;

    // 右侧设置面板
    _panel = [[UIScrollView alloc] initWithFrame:CGRectMake(sideW, barH, w-sideW, h-barH)];
    _panel.autoresizingMask = UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    _panel.backgroundColor = kPanelBG;
    _panel.alwaysBounceVertical = YES;
    _panel.showsVerticalScrollIndicator = NO;
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
    NSMutableArray *pages = [NSMutableArray array];
    CGFloat pw = _panel.bounds.size.width;
    CGFloat padL = 58, padTop = 4;

    // ---- 页 0: Game (工具) ----
    UIView *p0 = [[UIView alloc] init];
    p0.backgroundColor = [UIColor clearColor];
    UILabel *h0 = [[UILabel alloc] init];
    h0.attributedText = MWBPixelText(@"Game", MWBPixelFont(41), MWB_COLOR(0xf0,0xee,0xea),
                                     4, 4, MWB_COLOR(0x30,0x30,0x31));
    [h0 sizeToFit];
    h0.frame = CGRectMake(padL, padTop, h0.bounds.size.width, h0.bounds.size.height);
    [p0 addSubview:h0];
    NSArray *rows0 = @[
        @[@"无敌", [self makeToggle:gInvincible action:@selector(togInvincible:)]],
        @[@"飞行", [self makeToggle:gFly action:@selector(togFly:)]],
        @[@"快速破坏", [self makeToggle:gFastBreak action:@selector(togFastBreak:)]],
    ];
    CGFloat ry = CGRectGetMaxY(h0.frame) + 20;
    for (NSArray *r in rows0) {
        UILabel *l = [self makeRowLabel:r[0]];
        MWBPixelToggle *t = r[1];
        UIView *row = [[UIView alloc] init];
        row.backgroundColor = [UIColor clearColor];
        [row addSubview:l]; [row addSubview:t];
        row.frame = CGRectMake(33, ry, pw-66-33, 77);
        l.frame = CGRectMake(0, 0, MIN(445,row.bounds.size.width-180), 77);
        t.frame = CGRectMake(row.bounds.size.width-152, 0, 152, 77);
        [p0 addSubview:row];
        ry += 85;
    }
    p0.frame = CGRectMake(0, 0, pw, ry);
    [pages addObject:p0];

    // ---- 页 1: Blocks (方块) ----
    UIView *p1 = [[UIView alloc] init];
    p1.backgroundColor = [UIColor clearColor];
    UILabel *h1 = [[UILabel alloc] init];
    h1.attributedText = MWBPixelText(@"Blocks", MWBPixelFont(41), MWB_COLOR(0xf0,0xee,0xea),
                                     4, 4, MWB_COLOR(0x30,0x30,0x31));
    [h1 sizeToFit];
    h1.frame = CGRectMake(padL, padTop, h1.bounds.size.width, h1.bounds.size.height);
    [p1 addSubview:h1];
    UILabel *todo1 = [[UILabel alloc] init];
    todo1.attributedText = MWBPixelText(@"物品功能开发中...", MWBPixelFont(28), kWhiteText,
                                        3, 3, [UIColor blackColor]);
    [todo1 sizeToFit];
    todo1.frame = CGRectMake(padL, CGRectGetMaxY(h1.frame)+30, todo1.bounds.size.width, todo1.bounds.size.height);
    [p1 addSubview:todo1];
    p1.frame = CGRectMake(0, 0, pw, CGRectGetMaxY(todo1.frame)+30);
    [pages addObject:p1];

    // ---- 页 2: Controls (手柄) ----
    UIView *p2 = [[UIView alloc] init];
    p2.backgroundColor = [UIColor clearColor];
    UILabel *h2 = [[UILabel alloc] init];
    h2.attributedText = MWBPixelText(@"Controls", MWBPixelFont(41), MWB_COLOR(0xf0,0xee,0xea),
                                     4, 4, MWB_COLOR(0x30,0x30,0x31));
    [h2 sizeToFit];
    h2.frame = CGRectMake(padL, padTop, h2.bounds.size.width, h2.bounds.size.height);
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
        row.frame = CGRectMake(33, ry, pw-66-33, 77);
        l.frame = CGRectMake(0, 0, MIN(445,row.bounds.size.width-180), 77);
        t.frame = CGRectMake(row.bounds.size.width-152, 0, 152, 77);
        [p2 addSubview:row];
        ry += 85;
    }
    p2.frame = CGRectMake(0, 0, pw, ry);
    [pages addObject:p2];

    // ---- 页 3: World (粒子) ----
    UIView *p3 = [[UIView alloc] init];
    p3.backgroundColor = [UIColor clearColor];
    UILabel *h3 = [[UILabel alloc] init];
    h3.attributedText = MWBPixelText(@"World", MWBPixelFont(41), MWB_COLOR(0xf0,0xee,0xea),
                                     4, 4, MWB_COLOR(0x30,0x30,0x31));
    [h3 sizeToFit];
    h3.frame = CGRectMake(padL, padTop, h3.bounds.size.width, h3.bounds.size.height);
    [p3 addSubview:h3];
    // 时间切换: 白天 / 夜晚 两个像素按钮
    UILabel *timeLabel = [self makeRowLabel:@"时间"];
    timeLabel.frame = CGRectMake(33, CGRectGetMaxY(h3.frame)+30, 200, 60);
    [p3 addSubview:timeLabel];
    MWBPixelButton *dayBtn = [[MWBPixelButton alloc] init];
    [dayBtn setAttributedTitle:MWBPixelText(@"白天", MWBPixelFont(28), MWB_COLOR(0xef,0xed,0xeb),
                                            3, 3, MWB_COLOR(0x39,0x36,0x38)) forState:UIControlStateNormal];
    dayBtn.tag = 1;
    [dayBtn addTarget:self action:@selector(setTime:) forControlEvents:UIControlEventTouchUpInside];
    dayBtn.frame = CGRectMake(pw-33-260, CGRectGetMaxY(h3.frame)+30, 120, 60);
    [p3 addSubview:dayBtn];
    MWBPixelButton *nightBtn = [[MWBPixelButton alloc] init];
    [nightBtn setAttributedTitle:MWBPixelText(@"夜晚", MWBPixelFont(28), MWB_COLOR(0xef,0xed,0xeb),
                                              3, 3, MWB_COLOR(0x39,0x36,0x38)) forState:UIControlStateNormal];
    nightBtn.tag = 2;
    [nightBtn addTarget:self action:@selector(setTime:) forControlEvents:UIControlEventTouchUpInside];
    nightBtn.frame = CGRectMake(pw-33-130, CGRectGetMaxY(h3.frame)+30, 120, 60);
    [p3 addSubview:nightBtn];
    p3.frame = CGRectMake(0, 0, pw, CGRectGetMaxY(dayBtn.frame)+30);
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
- (void)togSpeed:(MWBPixelToggle *)t { gSpeed = t.on; }
- (void)togSuperJump:(MWBPixelToggle *)t { gSuperJump = t.on; }
- (void)setTime:(MWBPixelButton *)sender { gTimeMode = (int)sender.tag; }

@end

#pragma mark - 悬浮按钮 (T + TOOLBOX 像素样式)

@interface MWBFloatingButton : UIView
@property (nonatomic, copy) void (^onTap)(void);
@end
@implementation MWBFloatingButton {
    UIView *_iconBox;
    UILabel *_iconLabel;
    UILabel *_textLabel;
}
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = kSidebar;
        self.layer.borderWidth = 4;
        self.layer.borderColor = MWB_COLOR(0x2b,0x29,0x2a).CGColor;
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOffset = CGSizeMake(5, 5);
        self.layer.shadowRadius = 0;
        self.layer.shadowOpacity = 0.55;

        // T 图标方块
        _iconBox = [[UIView alloc] init];
        _iconBox.backgroundColor = MWB_COLOR(0x41,0x50,0x2f);
        _iconBox.layer.borderWidth = 3;
        _iconBox.layer.borderColor = MWB_COLOR(0x27,0x2b,0x22).CGColor;
        [self addSubview:_iconBox];
        _iconLabel = [[UILabel alloc] init];
        _iconLabel.attributedText = MWBPixelText(@"T", MWBPixelFont(23), MWB_COLOR(0xdf,0xc5,0x5b),
                                                 2, 2, MWB_COLOR(0x24,0x24,0x1d));
        _iconLabel.textAlignment = NSTextAlignmentCenter;
        [_iconBox addSubview:_iconLabel];

        _textLabel = [[UILabel alloc] init];
        _textLabel.attributedText = MWBPixelText(@"TOOLBOX", MWBPixelFont(20), kInk,
                                                 2, 2, MWB_COLOR(0xdd,0xd6,0xd1));
        [self addSubview:_textLabel];

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
    CGFloat h = self.bounds.size.height;
    CGFloat iconSize = 39;
    _iconBox.frame = CGRectMake(7, (h-iconSize)/2, iconSize, iconSize);
    _iconLabel.frame = _iconBox.bounds;
    [_textLabel sizeToFit];
    _textLabel.frame = CGRectMake(7+iconSize+11, 0, _textLabel.bounds.size.width, h);
}
- (void)handleTap { if (self.onTap) self.onTap(); }
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
- (void)drawRect:(CGRect)rect {
    CGContextRef ctx = UIGraphicsGetCurrentContext();
    CGFloat w=rect.size.width, h=rect.size.height, b=4;
    // inset 4px 4px 0 light, inset -4px -4px 0 dark
    CGContextSetFillColorWithColor(ctx, kSidebarLight.CGColor);
    CGContextFillRect(ctx, CGRectMake(b,b,w-2*b,b));
    CGContextFillRect(ctx, CGRectMake(b,b,b,h-2*b));
    CGContextSetFillColorWithColor(ctx, kSidebarDark.CGColor);
    CGContextFillRect(ctx, CGRectMake(b,h-2*b,w-2*b,b));
    CGContextFillRect(ctx, CGRectMake(w-2*b,b,b,h-2*b));
    // 图标方块内阴影
    CGFloat ix=7, iy=(h-39)/2, is=39;
    CGContextSetFillColorWithColor(ctx, MWB_COLOR(0x75,0x83,0x53).CGColor);
    CGContextFillRect(ctx, CGRectMake(ix+3, iy+3, is-6, 3));
    CGContextFillRect(ctx, CGRectMake(ix+3, iy+3, 3, is-6));
    CGContextSetFillColorWithColor(ctx, MWB_COLOR(0x25,0x30,0x20).CGColor);
    CGContextFillRect(ctx, CGRectMake(ix+3, iy+is-6, is-6, 3));
    CGContextFillRect(ctx, CGRectMake(ix+is-6, iy+3, 3, is-6));
}
@end

#pragma mark - 透传窗口

@interface MWBOverlayWindow : UIWindow
@end
@implementation MWBOverlayWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self || hit == self.rootViewController.view) return nil;
    return hit;
}
@end

#pragma mark - 主控制器

@interface MWBViewController : UIViewController
@property (nonatomic, strong) MWBFloatingButton *floatButton;
@property (nonatomic, strong) MWBOptionsMenu *menu;
@end
@implementation MWBViewController
- (void)loadView { self.view = [[UIView alloc] init]; self.view.backgroundColor = [UIColor clearColor]; }
- (void)viewDidLoad {
    [super viewDidLoad];
    CGFloat sw = self.view.bounds.size.width;
    _floatButton = [[MWBFloatingButton alloc] initWithFrame:CGRectMake(sw-22-200, 22, 200, 58)];
    _floatButton.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin;
    __weak MWBViewController *ws = self;
    _floatButton.onTap = ^{ [ws toggleMenu]; };
    [self.view addSubview:_floatButton];
}
- (void)toggleMenu {
    if (_menu.superview) {
        [_menu hide];
        _floatButton.hidden = NO;
        [UIView animateWithDuration:0.15 animations:^{ self->_floatButton.alpha = 1; }];
    } else {
        _menu = [[MWBOptionsMenu alloc] initWithFrame:self.view.bounds];
        _menu.autoresizingMask = UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
        __weak MWBViewController *ws = self;
        _menu.onClose = ^{
            MWBViewController *ss = ws;
            if (!ss) return;
            ss->_floatButton.hidden = NO;
            [UIView animateWithDuration:0.15 animations:^{ ss->_floatButton.alpha = 1; }];
        };
        [_menu showInView:self.view];
        [UIView animateWithDuration:0.15 animations:^{ self->_floatButton.alpha = 0; } completion:^(BOOL f){ self->_floatButton.hidden = YES; }];
    }
}
@end

#pragma mark - C++ 游戏函数 hook

typedef void (*NormalTickFn)(void *self);
static NormalTickFn orig_normalTick = NULL;
static void hooked_normalTick(void *self) {
    orig_normalTick(self);
    gLocalPlayer = self;
    char *abil = (char *)self + PLAYER_ABILITIES_OFFSET;
    if (gInvincible) abil[ABIL_INVULNERABLE] = 1;
    if (gFly) { abil[ABIL_FLYING] = 1; abil[ABIL_MAY_FLY] = 1; }
    if (gFastBreak) abil[ABIL_INSTABUILD] = 1;
    if (gSpeed) {
        *(float *)((char *)self + 108) *= 2.5f;
        *(float *)((char *)self + 116) *= 2.5f;
    }
    if (gSuperJump) {
        float *vy = (float *)((char *)self + ENTITY_VELOCITY_Y_OFFSET);
        if (*vy > 0.40f && *vy < 0.44f) *vy *= 2.5f;
    }
}

typedef void (*LevelTickFn)(void *self);
static LevelTickFn orig_levelTick = NULL;
static void hooked_levelTick(void *self) {
    orig_levelTick(self);
    gLevel = self;
    if (gTimeMode == 1) *(int64_t *)((char *)self + LEVEL_TIME_OFFSET) = TICK_TIME_DAY;
    else if (gTimeMode == 2) *(int64_t *)((char *)self + LEVEL_TIME_OFFSET) = TICK_TIME_NIGHT;
}

#pragma mark - 安装

static MWBOverlayWindow *gWindow = nil;
static void MWBInstall(void) {
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
    });
}

%ctor {
    MWBRegisterFont();
    NSLog(@"[魔玩盒子] 插件已加载");

    #define MWB_HOOK(mangled, replacement, original) do { \
        void *_s = MSFindSymbol(NULL, mangled); \
        if (_s) { MSHookFunction(_s, (void *)replacement, (void **)&original); \
            NSLog(@"[魔玩盒子] 已 hook: %s", mangled); } \
        else NSLog(@"[魔玩盒子] 警告: 未找到 %s", mangled); \
    } while (0)

    MWB_HOOK("__ZN11LocalPlayer10normalTickEv", hooked_normalTick, orig_normalTick);
    MWB_HOOK("__ZN5Level4tickEv", hooked_levelTick, orig_levelTick);

    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidFinishLaunchingNotification
                    object:nil queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *n){ MWBInstall(); }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0*NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ MWBInstall(); });
}
