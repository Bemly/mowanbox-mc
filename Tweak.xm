#import <UIKit/UIKit.h>
#import <CoreText/CoreText.h>
#import <mach/mach.h>
#import <substrate.h>
#import "FusionPixel.h"
#import "MWBAvatar.h"
#import "EMI.h"
#import "MWBVersion.h"

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
    s.shadowOffset = (CGSize){shadowX, shadowY};
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
    _top.frame = (CGRect){{o,o},{w - 2*o,i}}; _top.backgroundColor = _insetLight.CGColor;
    _left.frame = (CGRect){{o,o},{i,h - 2*o}}; _left.backgroundColor = _insetLight.CGColor;
    _bottom.frame = (CGRect){{o,h - o - i},{w - 2*o,i}}; _bottom.backgroundColor = _insetDark.CGColor;
    _right.frame = (CGRect){{w - o - i,o},{i,h - 2*o}}; _right.backgroundColor = _insetDark.CGColor;
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
            case 'M': x=readNum(); y=readNum(); sx=x; sy=y; [p moveToPoint:(CGPoint){x,y}];
                      while(atNum()){ x=readNum(); y=readNum(); [p addLineToPoint:(CGPoint){x,y}]; } break;
            case 'L': while(atNum()){ x=readNum(); y=readNum(); [p addLineToPoint:(CGPoint){x,y}]; } break;
            case 'H': while(atNum()){ x=readNum(); [p addLineToPoint:(CGPoint){x,y}]; } break;
            case 'V': while(atNum()){ y=readNum(); [p addLineToPoint:(CGPoint){x,y}]; } break;
            case 'm': x+=readNum(); y+=readNum(); sx=x; sy=y; [p moveToPoint:(CGPoint){x,y}]; break;
            case 'l': while(atNum()){ x+=readNum(); y+=readNum(); [p addLineToPoint:(CGPoint){x,y}]; } break;
            case 'h': while(atNum()){ x+=readNum(); [p addLineToPoint:(CGPoint){x,y}]; } break;
            case 'v': while(atNum()){ y+=readNum(); [p addLineToPoint:(CGPoint){x,y}]; } break;
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
        if ([objc_getAssociatedObject(v, "isHL") boolValue]) v.frame = (CGRect){{5,5},{w-10,4}};
        else v.frame = (CGRect){{5,h-9},{w-10,4}};
    }
    CGFloat cellW = (w - pad*2 - 4) / 2;
    _i.frame = (CGRect){{pad,pad},{cellW,h - pad*2}};
    _b.frame = (CGRect){{pad + cellW + 4,pad},{cellW,h - pad*2}};
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
    CGContextFillRect(ctx, (CGRect){{b,b},{w-2*b,b}}); // top
    CGContextFillRect(ctx, (CGRect){{b,b},{b,h-2*b}}); // left
    CGContextSetFillColorWithColor(ctx, MWB_COLOR(0x77,0x70,0x6e).CGColor);
    CGContextFillRect(ctx, (CGRect){{b,h-2*b},{w-2*b,b}}); // bottom
    CGContextFillRect(ctx, (CGRect){{w-2*b,b},{b,h-2*b}}); // right
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
        _shapeLayers = [NSMutableArray new];
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
        layer.frame = (CGRect){{ox,oy},{s,s}};
        layer.bounds = (CGRect){{0,0},{s,s}};
        layer.position = (CGPoint){w/2, h/2};
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
    CGContextFillRect(ctx, (CGRect){{0,0},{4,h}});
    CGContextSetFillColorWithColor(ctx, MWB_COLOR(0xd3,0xcc,0xc7).CGColor);
    CGContextFillRect(ctx, (CGRect){{w-4,0},{4,h}});
    CGContextSetFillColorWithColor(ctx, MWB_COLOR(0xca,0xbf,0xba).CGColor);
    CGContextFillRect(ctx, (CGRect){{0,0},{w,4}});
    CGContextSetFillColorWithColor(ctx, MWB_COLOR(0x56,0x52,0x53).CGColor);
    CGContextFillRect(ctx, (CGRect){{0,h-5},{w,5}});
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
    _label.frame = (CGRect){{0,0},{labelW,h}};
    CGSize cs = _control.intrinsicContentSize;
    if (cs.width <= 0 || cs.height <= 0) cs = _control.bounds.size;
    CGFloat cw = 152, ch = 77;
    if ([_control isKindOfClass:[MWBPixelToggle class]]) { cw=152; ch=77; }
    else if ([_control isKindOfClass:[MWBPixelButton class]]) { cw=120; ch=60; }
    _control.frame = (CGRect){{w - cw,(h-ch)/2},{cw,ch}};
}
@end

#pragma mark - 功能开关全局状态

static BOOL gInvincible  = NO;
static BOOL gFly         = NO;
static BOOL gFastBreak   = NO;
static BOOL gSpeed       = NO;
static BOOL gSuperJump   = NO;
static BOOL gNoclip      = NO;
static BOOL gNightVision = NO;
static BOOL gKillAura    = NO;
static BOOL gMinimap     = NO;
static int  gGV          = 0;   // 当前游戏版本 (MWBGameVersion 数值, %ctor 内赋值, 跨版本分发用)
static int  gTimeMode    = 0;  // 0=不修改 1=白天 2=夜晚
static int  gWeatherMode = 0;  // 0=不修改 1=晴 2=雨 3=雷

// 0.10 没有动态天气系统, 只有写过天气通道的版本才开放天气按钮
static BOOL MWBWeatherSupported(void) {
    return gGV == (int)MWBGameV1_2_15 || gGV == (int)MWBGameV1_4_3 || gGV == (int)MWBGameV1_13_3;
}

// 反应核点燃与难度切换目前只接了 0.10 后端
static BOOL MWB010Only(void) {
    return gGV == (int)MWBGameV0_10;
}

// 跨版本动作分发 (定义在版本段之后, 这里前置声明)
static void MWBHealNow(void);
static void MWBEnchantHeld255(void);
static void MWBTeleportUp10(void);
static void MWBFillStone5(void);
static void MWB010SpawnReactor(void);
static void MWBSetDifficulty010(int difficulty);
static BOOL MWBWeatherSupported(void);
static BOOL MWB010Only(void);
static void MWBMinimapShow(BOOL on);
static void MWBMinimapRefresh(void);
void MWB1133_KillAuraTick(void);
int MWB1133_SampleMinimap(void);
static void MWBPollCmdFile(void);

void *gLocalPlayer = NULL;       // LocalPlayer* (EMI 也用)
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

// 加速奔跑: Player::getBaseSpeed 只有 12 字节 (adrp+ldr+ret, 返回全局常量 0.1f),
// Substrate 的 arm64 跳板需要 16 字节, hook 它会踩坏紧随其后的
// Player::getEntityTypeId, 进世界后首次移动即 SIGILL 闪退 (2026-08-28 崩溃日志)。
// 反汇编确认该常量位于 __TEXT,__const 静态地址 0x1002ab79c,
// 全二进制仅 getBaseSpeed 一处引用, 因此不 hook 函数, 直接用
// vm_protect(VM_PROT_COPY) 改写常量, 只影响玩家速度, 不影响怪物
#define PLAYER_BASESPEED_VMADDR 0x1002ab79c
#define MWB_SPEED_MULT 2.5f

static float gOrigBaseSpeed = 0.0f;   // 原始基础速度 (首次改写前缓存)

// 按开关改写/恢复玩家基础速度常量
static void MWBApplySpeed(BOOL on) {
    float *p = (float *)(MWBMainSlide() + PLAYER_BASESPEED_VMADDR);
    if (!gOrigBaseSpeed) gOrigBaseSpeed = *p;
    vm_address_t page = ((vm_address_t)p) & ~(vm_page_size - 1);
    kern_return_t kr = vm_protect(mach_task_self(), page, vm_page_size, 0,
                                  VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) {
        NSLog(@"[魔玩盒子] 加速奔跑失败: vm_protect 改写权限被拒 (%d)", kr);
        return;
    }
    *p = on ? gOrigBaseSpeed * MWB_SPEED_MULT : gOrigBaseSpeed;
    // 写完恢复只读可执行
    vm_protect(mach_task_self(), page, vm_page_size, 0, VM_PROT_READ | VM_PROT_EXECUTE);
    NSLog(@"[魔玩盒子] 加速奔跑 %@ (基础速度 %.1f → %.2f)",
          on ? @"已开启" : @"已关闭", gOrigBaseSpeed, *p);
}

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
    p3.frame = (CGRect){{0,0},{pw,CGRectGetMaxY(dayBtn.frame)+318}};
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
}

@end

#pragma mark - 悬浮按钮 (头像 logo, 无文字)

@interface MWBFloatingButton : UIView
@property (nonatomic, copy) void (^onTap)(void);
@end
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
    _floatButton = [[MWBFloatingButton alloc] initWithFrame:(CGRect){{sw-22-64,22},{64,64}}];
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
static int gTickCount = 0;
static void hooked_normalTick(void *self) {
    orig_normalTick(self);
    gLocalPlayer = self;
    gTickCount++;
    char *abil = (char *)self + PLAYER_ABILITIES_OFFSET;
    if (gInvincible) abil[ABIL_INVULNERABLE] = 1;
    if (gFly) { abil[ABIL_FLYING] = 1; abil[ABIL_MAY_FLY] = 1; }
    if (gFastBreak) abil[ABIL_INSTABUILD] = 1;
    // 超级跳跃: 检测跳跃瞬间的速度 (jumpFromGround 设为 0.42)
    if (gSuperJump) {
        float *vy = (float *)((char *)self + ENTITY_VELOCITY_Y_OFFSET);
        if (*vy > 0.40f && *vy < 0.44f) *vy = 0.85f;
    }
    // 调试日志: 每 200 tick 输出一次状态
    if (gMWBDebug && (gTickCount % 200) == 1) {
        NSString *m = [NSString stringWithFormat:
            @"%@ [Toolbox调试] tick #%d player=%p abil=[%d,%d,%d,%d] vy=%.3f speed=%s fly=%s inv=%s fast=%s jump=%s\n",
            [NSDate date], gTickCount, self,
            abil[0], abil[1], abil[2], abil[3],
            *(float *)((char *)self + ENTITY_VELOCITY_Y_OFFSET),
            gSpeed ? "开" : "关", gFly ? "开" : "关",
            gInvincible ? "开" : "关", gFastBreak ? "开" : "关",
            gSuperJump ? "开" : "关"];
        NSURL *logURL = [NSURL fileURLWithPath:@"/var/mobile/Documents/mowanbox.log"];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingToURL:logURL error:nil];
        if (fh) { [fh seekToEndOfFile]; [fh writeData:[m dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
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

#pragma mark - 1.13.3 版本适配 (静态VA+slide,无需符号)
// 逆向结论: Player::normalTick @0x101D5CAC8 (2636B,可hook)
// Level::tick @0x101FAAC70, 背包 Player+4416,
// abilities Player+2376 (12B步长x18条目,使能位+8,值+12),
// dayTime Level+0x510 (int32), gameTime Level+0x4E8
#define V1133_PLAYERNORMALTICK_VA 0x101D5CAC8UL
#define V1133_LEVELTICK_VA        0x101FAAC70UL
#define V1133_PLAYER_ABILITIES_OFF 2376
#define V1133_PLAYER_INV_OFF       4416
#define V1133_LEVEL_DAYTIME_OFF    0x510
#define V1133_LEVEL_SHARED_OFF     0x1e8
#define V1133_UNWRAP_VA            0x1024ECE84UL
#define V1133_SETRAIN_VA           0x1024EC9E0UL
#define V1133_SETRAINTIME_VA       0x1024EC9F0UL
#define V1133_SETLIGHT_VA          0x1024EC9B0UL
#define V1133_SETLIGHTTIME_VA      0x1024EC9C0UL
#define V1133_MOBEFFECT_GET_VA     0x101E40170UL
#define V1133_WEATHERWRAP_VA       0x101FB32F4UL

static void *gPlayer1133 = NULL;
static void *gLevel1133 = NULL;
static int gTick1133 = 0;
typedef void (*V1133TickFn)(void *self);
static V1133TickFn orig_1133_playerTick = NULL;
static V1133TickFn orig_1133_levelTick = NULL;

// 能力表探测: 18条目x12B,附名字表(静态0x10340F230)和12字节hex,用于定位无敌下标
#define V1133_ABIL_NAMES_VA 0x10340F230UL
static void MWB1133LogAbilities(void *player, NSFileHandle *fh) {
    char *base = (char *)player + V1133_PLAYER_ABILITIES_OFF;
    char **names = (char **)(MWBMainSlide() + V1133_ABIL_NAMES_VA);
    NSMutableString *m = [NSMutableString stringWithFormat:@"[1133能力表] player=%p\n", player];
    for (int i = 0; i < 18; i++) {
        char *e = base + i * 12;
        const char *nm = "??";
        @try {
            char *np = names[i];
            if (np && (uintptr_t)np > 0x100000000UL) nm = np;
        } @catch (NSException *ex) { nm = "bad"; }
        [m appendFormat:@" [%d]%-12s", i, nm];
        for (int b = 0; b < 12; b++) [m appendFormat:@" %02x", (unsigned char)e[b]];
        [m appendString:@"\n"];
    }
    [fh writeData:[m dataUsingEncoding:NSUTF8StringEncoding]];
}

static void hooked_1133_playerTick(void *self) {
    orig_1133_playerTick(self);
    gPlayer1133 = self;
    gTick1133++;
    // 无敌: entry[8]invulnerable 值=Player+2480 (Base2376+12+8*12, 逆向分队实锤)
    // 旧双写 base[8*12]/[9*12] 实为 teleport/invulnerable, 现改为单写去副作用
    char *ab = (char *)self + V1133_PLAYER_ABILITIES_OFF + 12;
    if (gInvincible) ab[8 * 12] = 1;                    // Player+2480 invulnerable
    if (gFly) { ab[9 * 12] = 1; ab[10 * 12] = 1; }      // flying+mayfly
    if (gFastBreak) ab[11 * 12] = 1;                    // instabuild
    if (gSpeed) {
        *(float *)(ab + 14 * 12) = 1.0f;                // walkSpeed
        *(float *)(ab + 13 * 12) = 1.0f;                // flySpeed
    }
    if (gNoclip) ab[17 * 12] = 1;                       // noclip
    if (gKillAura) MWB1133_KillAuraTick();
    if (gMinimap && (gTick1133 % 40) == 1) {
        if (MWB1133_SampleMinimap() >= 0) MWBMinimapRefresh();
    }
    MWBPollCmdFile();
    // 夜视药水探测: getById(速度1/跳跃8/夜视16) 回读指针, 非空即药水系统可达
    if (gNightVision && gMWBDebug && (gTick1133 % 200) == 1) {
        void *(*getById)(int) = (void *(*)(int))(MWBMainSlide() + V1133_MOBEFFECT_GET_VA);
        void *e1 = getById(1), *e8 = getById(8), *e16 = getById(16);
        NSURL *logURL = [NSURL fileURLWithPath:@"/var/mobile/Documents/mowanbox.log"];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingToURL:logURL error:nil];
        if (fh) {
            [fh seekToEndOfFile];
            NSString *line = [NSString stringWithFormat:@"%@ [1133药水] speed=%p jump=%p nightvision=%p\n",
                              [NSDate date], e1, e8, e16];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    }
    if (gMWBDebug && (gTick1133 % 200) == 1) {
        NSURL *logURL = [NSURL fileURLWithPath:@"/var/mobile/Documents/mowanbox.log"];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingToURL:logURL error:nil];
        if (fh) {
            [fh seekToEndOfFile];
            NSString *line = [NSString stringWithFormat:@"%@ [1133] tick #%d player=%p\n",
                              [NSDate date], gTick1133, self];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            MWB1133LogAbilities(self, fh);
            [fh closeFile];
        }
    }
}

static void hooked_1133_levelTick(void *self) {
    orig_1133_levelTick(self);
    gLevel1133 = self;
    if (gTimeMode == 1) *(int32_t *)((char *)self + V1133_LEVEL_DAYTIME_OFF) = TICK_TIME_DAY;
    else if (gTimeMode == 2) *(int32_t *)((char *)self + V1133_LEVEL_DAYTIME_OFF) = TICK_TIME_NIGHT;
    // 天气: 调 Level wrapper (自带变更检测+同步广播, 比裸写setter靠谱)
    // void wrapper(Level*, float rain, int rainTime, float lightning, int lightningTime)
    if (gWeatherMode >= 1 && gWeatherMode <= 3) {
        void (*wfn)(void *, float, int, float, int) =
            (void (*)(void *, float, int, float, int))(MWBMainSlide() + V1133_WEATHERWRAP_VA);
        if (gWeatherMode == 1) wfn(self, 0.0f, 0, 0.0f, 0);
        else if (gWeatherMode == 2) wfn(self, 1.0f, 12000, 0.0f, 0);
        else wfn(self, 1.0f, 12000, 1.0f, 12000);
    }
    static int s_lvTick = 0;
    if (gMWBDebug && ((++s_lvTick % 200) == 1)) {
        NSURL *logURL = [NSURL fileURLWithPath:@"/var/mobile/Documents/mowanbox.log"];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingToURL:logURL error:nil];
        if (fh) {
            [fh seekToEndOfFile];
            void *(*uw)(void *) = (void *(*)(void *))(MWBMainSlide() + V1133_UNWRAP_VA);
            void *dbgLd = uw((char *)self + V1133_LEVEL_SHARED_OFF);
            float rain = dbgLd ? *(float *)((char *)dbgLd + 0x354) : -9.0f;
            NSString *line = [NSString stringWithFormat:
                @"%@ [1133关卡] tick #%d level=%p dayTime=%d gTimeMode=%d ld=%p rain=%.2f wmode=%d\n",
                [NSDate date], s_lvTick, self,
                *(int32_t *)((char *)self + V1133_LEVEL_DAYTIME_OFF), gTimeMode,
                dbgLd, rain, gWeatherMode];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    }
}

#pragma mark - 1.13.3 大件 (药水应用/传送/治疗/遍历/WorldEdit/KillAura/小地图)
// 收尾逆向结论, 静态VA+slide
#define V1133_EFFECT_CTOR_VA   0x101E401CCUL
#define V1133_ADDEFFECT_SLOT   0x5F8
#define V1133_TELEPORT_SLOT    0x88
#define V1133_GETPOS_SLOT      0x60
#define V1133_GETATTR_VA       0x101119404UL
#define V1133_LEVEL_ACTORS_OFF 0x58
#define V1133_GETBLOCK_VA      0x101F87334UL
#define V1133_SETBLOCK_VA      0x101F88950UL
#define V1133_BLOCKBASE_VA     0x1034C8870UL
#define V1133_STONESLOT_OFF    0x38  // 重推导结论: base+8是map, 真石头在base+0x38
#define V1133_ACTOR_BS_OFF     0x338
#define V1133_KILLAURA_RANGE   4.0f
#define V1133_VT_MELEE_SLOT    0x9e8

// 药水应用 (实例0xE8: id@8/amp@C/dur@38, +0x78恒1)
bool MWB1133_ApplyEffect(void *actor, int fxId, int amplifier, int durTicks) {
    if (!actor) return false;
    uintptr_t s = MWBMainSlide();
    void *(*getById)(int) = (void *(*)(int))(s + V1133_MOBEFFECT_GET_VA);
    void *fx = getById(fxId);
    if (!fx) return false;
    char e1[24] = {0}, e2[24] = {0}, e3[24] = {0};
    void *buf = malloc(0xE8);
    if (!buf) return false;
    memset(buf, 0, 0xE8);
    ((void (*)(void *, int, void *, void *, int, int, int, void *))(s + V1133_EFFECT_CTOR_VA))(
        buf, fxId, e1, e2, amplifier, 0, durTicks, e3);
    *(uint8_t *)((char *)buf + 0x78) = 1;
    NSURL *lurl = [NSURL fileURLWithPath:@"/var/mobile/Documents/mowanbox.log"];
    NSFileHandle *lfh = [NSFileHandle fileHandleForWritingToURL:lurl error:nil];
    if (lfh) {
        [lfh seekToEndOfFile];
        NSMutableString *m = [NSMutableString stringWithFormat:@"%@ [1133实例] id=%d fx=%p inst:",
                             [NSDate date], fxId, fx];
        for (int i = 0; i < 0x40; i += 8)
            [m appendFormat:@" +%x=%02x%02x%02x%02x%02x%02x%02x%02x", i,
             ((uint8_t *)fx)[i], ((uint8_t *)fx)[i+1], ((uint8_t *)fx)[i+2], ((uint8_t *)fx)[i+3],
             ((uint8_t *)fx)[i+4], ((uint8_t *)fx)[i+5], ((uint8_t *)fx)[i+6], ((uint8_t *)fx)[i+7]];
        [m appendString:@" buf:"];
        for (int i = 0; i < 0xE8; i += 8)
            [m appendFormat:@" +%x=%02x%02x%02x%02x%02x%02x%02x%02x", i,
             ((uint8_t *)buf)[i], ((uint8_t *)buf)[i+1], ((uint8_t *)buf)[i+2], ((uint8_t *)buf)[i+3],
             ((uint8_t *)buf)[i+4], ((uint8_t *)buf)[i+5], ((uint8_t *)buf)[i+6], ((uint8_t *)buf)[i+7]];
        [m appendString:@"\n"];
        [lfh writeData:[m dataUsingEncoding:NSUTF8StringEncoding]];
        [lfh closeFile];
    }
    void *vt = *(void **)actor;
    bool r = ((bool (*)(void *, void *))(*(void **)((char *)vt + V1133_ADDEFFECT_SLOT)))(actor, buf);
    return r;
}
// 传送: getPos槽读当前(+10Y)→teleportTo槽 (不碰raw偏移, 避三pos之争)
bool MWB1133_TeleportUp10(void *actor) {
    NSURL *lurl = [NSURL fileURLWithPath:@"/var/mobile/Documents/mowanbox.log"];
    NSFileHandle *lfh = [NSFileHandle fileHandleForWritingToURL:lurl error:nil];
    if (!actor) return false;
    void *vt = *(void **)actor;
    void *(*getPos)(void *) = (void *(*)(void *))(*(void **)((char *)vt + V1133_GETPOS_SLOT));
    float *p = (float *)getPos(actor);
    if (!p) {
        if (lfh) { [lfh seekToEndOfFile];
            [lfh writeData:[@"[1133传送] getPos空\n" dataUsingEncoding:NSUTF8StringEncoding]]; [lfh closeFile]; }
        return false;
    }
    float v[3] = {p[0], p[1] + 10.0f, p[2]};
    ((void (*)(void *, void *))(*(void **)((char *)vt + V1133_TELEPORT_SLOT)))(actor, v);
    if (lfh) {
        [lfh seekToEndOfFile];
        NSString *line = [NSString stringWithFormat:@"%@ [1133传送] 从(%.1f,%.1f,%.1f)+10Y\n",
                          [NSDate date], p[0], p[1], p[2]];
        [lfh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [lfh closeFile];
    }
    return true;
}
// 属性实例 (治疗/饱食/XP: 先取实例, CURR/MAX槽运行时定界)
void *MWB1133_GetAttr(void *actor, const char *name) {
    if (!actor || !name) return NULL;
    char sstr[24] = {0};
    size_t n = strlen(name);
    if (n >= 24) return NULL;
    memcpy(sstr, name, n);
    return ((void *(*)(void *, void *))(MWBMainSlide() + V1133_GETATTR_VA))(actor, sstr);
}
// 实体遍历 (Level+0x58 vector<Actor*>, 越界保护)
void MWB1133_ForEachActor(void *level, void (^blk)(void *actor)) {
    if (!level || !blk) return;
    void **begin = *(void ***)((char *)level + V1133_LEVEL_ACTORS_OFF);
    void **end = *(void ***)((char *)level + V1133_LEVEL_ACTORS_OFF + 8);
    if (!begin || !end || end < begin || (end - begin) > 10000) return;
    for (void **it = begin; it < end; it++) if (*it) blk(*it);
}
// WorldEdit: 方块读写原语
typedef struct { int x, y, z; } MWBBlockPos;
static void *MWB1133BlockSource(void) {
    if (!gPlayer1133) return NULL;
    return *(void **)((char *)gPlayer1133 + V1133_ACTOR_BS_OFF);
}
static void *MWB1133BlockById(int blockId) {
    if (blockId == 1) {
        // 石头走修正槽 base+0x38, 并验虚表落在TEXT段才回 (防map指针再崩)
        void *s = *(void **)(MWBMainSlide() + V1133_BLOCKBASE_VA + V1133_STONESLOT_OFF);
        if (s) {
            void *vt = *(void **)s;
            uintptr_t lo = MWBMainSlide() + 0x100000000UL, hi = lo + 0x4000000UL;
            if ((uintptr_t)vt >= lo && (uintptr_t)vt < hi) return s;
        }
        return NULL;
    }
    if (blockId < 0 || blockId > 255) return NULL;
    return ((void **)(MWBMainSlide() + V1133_BLOCKBASE_VA))[blockId];
}
int MWB1133_BlockIdOf(void *blk) {
    if (!blk) return 0;
    // base[i]轮询已证伪(base+8是map), 只认air槽与石头槽
    if (blk == MWB1133BlockById(0)) return 0;
    void *stone = MWB1133BlockById(1);
    if (stone && blk == stone) return 1;
    return -1;
}
static void *MWB1133GetOne(void *bs, int x, int y, int z) {
    if (!bs) return NULL;
    MWBBlockPos p = {x, y, z};
    return ((void *(*)(void *, void *))(MWBMainSlide() + V1133_GETBLOCK_VA))(bs, &p);
}
int MWB1133SetOne(void *bs, int x, int y, int z, void *blk) {
    if (!bs || !blk || y < 0 || y > 255) return 0;
    MWBBlockPos p = {x, y, z};
    char dummy[16] = {0};
    return ((int (*)(void *, void *, void *, int, void *, int))(MWBMainSlide() + V1133_SETBLOCK_VA))(
        bs, &p, blk, 3, dummy, 0);
}
// fillCube: 以玩家脚下为中心边长n的石头立方 (分帧由调用方按tick切, 单次默认5³)
int MWB1133_FillStone(int half) {
    void *bs = MWB1133BlockSource();
    void *blk = MWB1133BlockById(1);
    NSURL *lurl = [NSURL fileURLWithPath:@"/var/mobile/Documents/mowanbox.log"];
    NSFileHandle *lfh = [NSFileHandle fileHandleForWritingToURL:lurl error:nil];
    uintptr_t slide = MWBMainSlide();
    uintptr_t lo = slide + 0x100000000UL, hi = lo + 0x4000000UL;
    BOOL bsOk = bs && (uintptr_t)bs > 0x100000000UL && *(void **)bs &&
                (uintptr_t)(*(void **)bs) >= lo && (uintptr_t)(*(void **)bs) < hi;
    if (!bs || !blk || !gPlayer1133) {
        if (lfh) { [lfh seekToEndOfFile];
            NSString *line = [NSString stringWithFormat:@"%@ [1133铺石] 缺件 bs=%p blk=%p player=%p\n",
                              [NSDate date], bs, blk, gPlayer1133];
            [lfh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [lfh closeFile]; }
        return -1;
    }
    if (!bsOk) {
        if (lfh) { [lfh seekToEndOfFile];
            NSString *line = [NSString stringWithFormat:@"%@ [1133铺石] bs虚表无效, 停写 bs=%p\n",
                              [NSDate date], bs];
            [lfh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [lfh closeFile]; }
        return -3;
    }
    float px = *(float *)((char *)gPlayer1133 + 0x41C);
    float py = *(float *)((char *)gPlayer1133 + 0x41C + 4);
    float pz = *(float *)((char *)gPlayer1133 + 0x41C + 8);
    int cx = (int)floorf(px), cy = (int)floorf(py), cz = (int)floorf(pz);
    // 先验: 读脚下方块+注册表比对, 不对就停 (避免125连写崩)
    int footId = MWB1133_BlockIdOf(MWB1133GetOne(bs, cx, cy - 1, cz));
    if (lfh) { [lfh seekToEndOfFile];
        NSString *line = [NSString stringWithFormat:
                          @"%@ [1133铺石] 玩家(%d,%d,%d) 脚下id=%d bs高度=%d\n",
                          [NSDate date], cx, cy, cz, footId, *(int16_t *)((char *)bs + 0x30)];
        [lfh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [lfh closeFile]; }
    if (footId < 0) return -2;  // 读链不通, 不写
    int n = 0;
    for (int y = cy - half; y <= cy + half; y++)
        for (int z = cz - half; z <= cz + half; z++)
            for (int x = cx - half; x <= cx + half; x++)
                n += MWB1133SetOne(bs, x, y, z, blk);
    if (lfh) { [lfh seekToEndOfFile];
        NSString *line = [NSString stringWithFormat:@"%@ [1133铺石] 写入%d块\n", [NSDate date], n];
        [lfh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [lfh closeFile]; }
    return n;
}
// KillAura: 最近敌对虚表攻击 (虚表需运行时填表, 空表时只记日志)
static void *gHostileVTs1133[16];
static int gHostileVTCount1133 = 0;
void MWB1133_KillAuraTick(void) {
    if (!gLevel1133 || !gPlayer1133) return;
    // 填表前探测: 每200tick记一次周围实体数与虚表 (填表后自动转攻击)
    if (gHostileVTCount1133 == 0) {
        if (gMWBDebug && (gTick1133 % 200) == 1) {
            __block int n = 0;
            __block int nv = 0;
            MWB1133_ForEachActor(gLevel1133, ^(void *a) {
                if (a == gPlayer1133) return;
                n++;
                if (n > 1000 || nv >= 16) return;
                void *vt = *(void **)a;
                for (int i = 0; i < nv; i++) if (gHostileVTs1133[i] == vt) return;
                gHostileVTs1133[nv++] = vt;  // 借表暂存 (count仍0, 不转攻击)
            });
            NSURL *logURL = [NSURL fileURLWithPath:@"/var/mobile/Documents/mowanbox.log"];
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingToURL:logURL error:nil];
            if (fh) {
                [fh seekToEndOfFile];
                NSMutableString *m = [NSMutableString stringWithFormat:@"%@ [1133光环探测] 实体=%d 虚表%d种:",
                                      [NSDate date], n, nv];
                for (int i = 0; i < nv; i++) [m appendFormat:@" %p", gHostileVTs1133[i]];
                [m appendString:@"\n"];
                [fh writeData:[m dataUsingEncoding:NSUTF8StringEncoding]];
                [fh closeFile];
            }
        }
        return;
    }
    __block void *best = NULL;
    __block float bestD2 = V1133_KILLAURA_RANGE * V1133_KILLAURA_RANGE;
    float *pp = (float *)((char *)gPlayer1133 + 0x41C);
    MWB1133_ForEachActor(gLevel1133, ^(void *a) {
        if (a == gPlayer1133) return;
        if (gHostileVTCount1133 == 0) return;  // 未填表只探测 (探测在debug日志)
        void *vt = *(void **)a;
        BOOL hostile = NO;
        for (int i = 0; i < gHostileVTCount1133; i++)
            if (gHostileVTs1133[i] == vt) { hostile = YES; break; }
        if (!hostile) return;
        if (*(uint8_t *)((char *)a + 0x351)) return;  // 已死跳过
        float *mp = (float *)((char *)a + 0x41C);
        float dx = mp[0] - pp[0], dy = mp[1] - pp[1], dz = mp[2] - pp[2];
        float d2 = dx * dx + dy * dy + dz * dz;
        if (d2 < bestD2) { bestD2 = d2; best = a; }
    });
    if (best) {
        void **pvt = *(void ***)gPlayer1133;
        ((void (*)(void *, void *))pvt[V1133_VT_MELEE_SLOT / 8])(gPlayer1133, best);
    }
}
// 小地图后端: 48x48单层采样 (玩家Y-2层, 矿石标红由UI侧按id着色)
static uint8_t gMiniMap1133[48 * 48];
int MWB1133_SampleMinimap(void) {
    void *bs = MWB1133BlockSource();
    if (!bs || !gPlayer1133) return -1;
    float px = *(float *)((char *)gPlayer1133 + 0x41C);
    float py = *(float *)((char *)gPlayer1133 + 0x41C + 4);
    float pz = *(float *)((char *)gPlayer1133 + 0x41C + 8);
    int cx = (int)floorf(px), cy = (int)floorf(py) - 2, cz = (int)floorf(pz);
    int air = 0;
    for (int dz = -24; dz < 24; dz++)
        for (int dx = -24; dx < 24; dx++) {
            int id = MWB1133_BlockIdOf(MWB1133GetOne(bs, cx + dx, cy, cz + dz));
            if (id <= 0) { air++; id = 0; }
            gMiniMap1133[(dz + 24) * 48 + (dx + 24)] = (uint8_t)(id & 0xFF);
        }
    return air;  // air数过大说明pos错层, 运行时判据
}

#pragma mark - 1.1.7 版本适配 (Abilities API 直接调用)
// 逆向结论: Abilities=Player+0x1258, setBool/getBool/setFloat 三件套+能力名bss,
// Level::tick @0x100B0398C, dayTime=Level+0x15C int32, 跳跃取值器 @0x10099CA88
#define V117_PLAYERTICK_VA     0x100439DE0UL
#define V117_LEVELTICK_VA      0x100B0398CUL
#define V117_JUMPPOWER_VA      0x10099CA88UL
#define V117_SETBOOL_VA        0x100A450F0UL
#define V117_SETFLOAT_VA       0x100A45134UL
#define V117_ABILITIES_OFF     0x1258
#define V117_LEVEL_DAYTIME_OFF 0x15C
#define V117_ABIL_INVULN       0x10178BD48UL
#define V117_ABIL_FLYING       0x10178BD60UL
#define V117_ABIL_INSTABUILD   0x10178BD78UL
#define V117_ABIL_MAYFLY       0x10178BDF0UL
#define V117_ABIL_WALKSPEED    0x10178BDC0UL
#define V117_ABIL_FLYSPEED     0x10178BDA8UL
#define V117_GETBOOL_VA        0x100A450C4UL
#define V117_HURT_VA           0x100997D40UL
#define V117_MKITEM_VA         0x1007B16F4UL
#define V117_MKENCH_VA         0x1007B1748UL
#define V117_APPLYENCH_VA      0x100AE6028UL
#define V117_HELDITEM_VA       0x100A4A110UL
#define V117_ITEMREG_VA        0x10178CCF8UL
#define V117_NIGHT_TRUE        18000  // 13000只是日落, 真夜用18000

typedef void (*V117TickFn)(void *self);
typedef void (*V117SetBoolFn)(void *abil, void *name, int v);
typedef int (*V117GetBoolFn)(void *abil, void *name);
typedef void (*V117SetFloatFn)(void *abil, void *name, float v);
typedef float (*V117JumpFn)(void *self);
static V117TickFn orig_117_playerTick = NULL, orig_117_levelTick = NULL;
static V117JumpFn orig_117_jump = NULL;
typedef int (*V117HurtFn)(void *self, void *src, int dmg, void *a, void *b);
static V117GetBoolFn orig_117_getBool = NULL;
static V117HurtFn orig_117_hurt = NULL;
static int gHurtCount117 = 0;  // hurt 调用计数 (死亡之谜诊断用)

// 无敌: 拦截 getBool 单点, 覆盖所有副本与伤害类型 (hurt/fire/helper 全走这里)
static int hooked_117_getBool(void *abil, void *entry) {
    if (gInvincible && entry == (void *)(MWBMainSlide() + V117_ABIL_INVULN)) return 1;
    return orig_117_getBool(abil, entry);
}
// 兜底: hurt 计数+诊断 (若getBool拦截后仍死, 下一步直接return 0)
static int hooked_117_hurt(void *self, void *src, int dmg, void *a, void *b) {
    gHurtCount117++;
    if (gMWBDebug && (gHurtCount117 % 5) == 1) {
        NSURL *logURL = [NSURL fileURLWithPath:@"/var/mobile/Documents/mowanbox.log"];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingToURL:logURL error:nil];
        if (fh) {
            [fh seekToEndOfFile];
            V117GetBoolFn getB = (V117GetBoolFn)(MWBMainSlide() + V117_GETBOOL_VA);
            int inv = getB((char *)self + V117_ABILITIES_OFF, (void *)(MWBMainSlide() + V117_ABIL_INVULN));
            NSString *line = [NSString stringWithFormat:@"%@ [117受伤] #%d self=%p dmg=%d inv=%d\n",
                              [NSDate date], gHurtCount117, self, dmg, inv];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    }
    return orig_117_hurt(self, src, dmg, a, b);
}
static V117SetBoolFn v117_setBool = NULL;
static V117SetFloatFn v117_setFloat = NULL;
static void *gPlayer117 = NULL;
static int gTick117 = 0;

static void hooked_117_playerTick(void *self) {
    orig_117_playerTick(self);
    gPlayer117 = self;
    MWBPollCmdFile();
    gTick117++;
    void *abil = (char *)self + V117_ABILITIES_OFF;
    uintptr_t s = MWBMainSlide();
    V117SetBoolFn setB = (V117SetBoolFn)(s + V117_SETBOOL_VA);
    V117SetFloatFn setF = (V117SetFloatFn)(s + V117_SETFLOAT_VA);
    if (gInvincible) setB(abil, (void *)(s + V117_ABIL_INVULN), 1);
    if (gFly) {
        setB(abil, (void *)(s + V117_ABIL_FLYING), 1);
        setB(abil, (void *)(s + V117_ABIL_MAYFLY), 1);
    }
    if (gFastBreak) setB(abil, (void *)(s + V117_ABIL_INSTABUILD), 1);
    if (gSpeed) setF(abil, (void *)(s + V117_ABIL_WALKSPEED), 0.25f);
    if (gMWBDebug && (gTick117 % 200) == 1) {
        NSURL *logURL = [NSURL fileURLWithPath:@"/var/mobile/Documents/mowanbox.log"];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingToURL:logURL error:nil];
        if (fh) {
            [fh seekToEndOfFile];
            V117GetBoolFn getB = (V117GetBoolFn)(MWBMainSlide() + V117_GETBOOL_VA);
            int inv = -1, fly = -1;
            if (getB) {
                void *abil = (char *)self + V117_ABILITIES_OFF;
                uintptr_t s = MWBMainSlide();
                inv = getB(abil, (void *)(s + V117_ABIL_INVULN));
                fly = getB(abil, (void *)(s + V117_ABIL_FLYING));
            }
            NSString *line = [NSString stringWithFormat:@"%@ [117] tick #%d player=%p inv=%d fly=%d\n",
                              [NSDate date], gTick117, self, inv, fly];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    }
}
static void hooked_117_levelTick(void *self) {
    orig_117_levelTick(self);
    if (gTimeMode == 1) *(int32_t *)((char *)self + V117_LEVEL_DAYTIME_OFF) = TICK_TIME_DAY;
    else if (gTimeMode == 2) *(int32_t *)((char *)self + V117_LEVEL_DAYTIME_OFF) = V117_NIGHT_TRUE;
    static int s_lv117 = 0;
    if (gMWBDebug && ((++s_lv117 % 200) == 1)) {
        NSURL *logURL = [NSURL fileURLWithPath:@"/var/mobile/Documents/mowanbox.log"];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingToURL:logURL error:nil];
        if (fh) {
            [fh seekToEndOfFile];
            NSString *line = [NSString stringWithFormat:@"%@ [117关卡] #%d level=%p dayTime=%d mode=%d\n",
                              [NSDate date], s_lv117, self,
                              *(int32_t *)((char *)self + V117_LEVEL_DAYTIME_OFF), gTimeMode];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    }
}
static float hooked_117_jump(void *self) {
    if (gSuperJump) return 0.85f;
    return orig_117_jump(self);
}

// 1.1.7 给予: 复刻 GiveCommand 内环 (描述子0x50 + 实例0x70 + mgr虚表+0x18)
bool MWB117_Give(void *player, int itemId, int count) {
    if (!player || itemId < 0 || itemId >= 0x200) return false;
    uintptr_t s = MWBMainSlide();
    void **reg = (void **)(s + V117_ITEMREG_VA);
    void *item = reg[itemId];
    NSURL *logURL = [NSURL fileURLWithPath:@"/var/mobile/Documents/mowanbox.log"];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingToURL:logURL error:nil];
    // 堆分配 (容器add可能引用传入实例, 栈内存返回即野指针, -20连给冻屏教训)
    unsigned char *inst = (unsigned char *)malloc(0x70);
    unsigned char *elem = (unsigned char *)malloc(0x50);
    if (!inst || !elem) { free(inst); free(elem); return false; }
    memset(inst, 0, 0x70);
    memset(elem, 0, 0x50);
    if (item) {
        *(uint16_t *)(elem + 0x00) = (uint16_t)itemId;
        *(int *)(elem + 0x04) = 1;
        *(void **)(elem + 0x10) = item;
        ((void (*)(void *, int, void *))(s + V117_MKITEM_VA))(inst, 0, elem);
    }
    void *mgr = *(void **)((char *)(*(void **)((char *)player + 0x40)) + 0x320);
    void *inv = (char *)player + 0x1288;
    if (fh) {
        [fh seekToEndOfFile];
        NSMutableString *m = [NSMutableString stringWithFormat:@"%@ [117给予] id=%d item=%p mgr=%p inst:",
                             [NSDate date], itemId, item, mgr];
        for (int i = 0; i < 0x70; i += 8)
            [m appendFormat:@" +%x=%02x%02x%02x%02x%02x%02x%02x%02x", i,
             inst[i], inst[i+1], inst[i+2], inst[i+3], inst[i+4], inst[i+5], inst[i+6], inst[i+7]];
        [m appendString:@"\n"];
        [fh writeData:[m dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
    if (!item) { free(inst); free(elem); return false; }
    (void)count;  // count 搬运待实例dump定界后写死
    ((void (*)(void *, void *, void *))((*(void ***)mgr)[3]))(mgr, inv, inst);
    return true;  // inst/elem 堆留给游戏 (容器可能引用, 不free)
}

// 1.1.7 超等级附魔: 跳过 0x100839D74 前置检查, 直调应用 (例: 锋利id9 x255)
bool MWB117_EnchantMax(void *player, int enchId, int level) {
    if (!player || enchId < 0 || enchId >= 0x1B) return false;
    uintptr_t s = MWBMainSlide();
    void *tbl = *(void **)(s + 0x10178E0C78UL);
    if (!tbl || !((void **)tbl)[enchId]) return false;
    void *held = ((void *(*)(void *))(s + V117_HELDITEM_VA))(player);
    if (!held) return false;
    unsigned char st = 0;
    ((void (*)(void *, int, int, unsigned char *))(s + V117_APPLYENCH_VA))(held, enchId, level, &st);
    if ((st & 0xFE) != 2) return false;
    unsigned char *einst = (unsigned char *)malloc(0x70);
    if (!einst) return false;
    memset(einst, 0, 0x70);
    ((void (*)(void *, void *, int, int))(s + V117_MKENCH_VA))(einst, held, enchId, level);
    void *mgr = *(void **)((char *)(*(void **)((char *)player + 0x40)) + 0x320);
    void *inv = (char *)player + 0x1288;
    ((void (*)(void *, void *, void *))((*(void ***)mgr)[3]))(mgr, inv, einst);
    return true;  // einst 堆留给游戏, 不free
}

#pragma mark - 1.4.3 版本适配 (Abilities map 模型, getter 拦截)
// 逆向结论: Abilities=Player+0x1388(内嵌map), getBool/getFloat/canFly/tickTime hook,
// setGameType one-shot 切生存创造, LevelData=Level+0xf8解引用+0x12c
#define V143_GETBOOL_VA     0x100f5070cUL
#define V143_GETFLOAT_VA    0x100f5081cUL
#define V143_CANFLY_VA      0x100f506b4UL
#define V143_SETGAMETYPE_VA 0x100f60b04UL
#define V143_TICKTIME_VA    0x100620c88UL
#define V143_ABILITIES_OFF  0x1388
#define V143_AB_INVULN      0x102089b50UL
#define V143_AB_FLYING      0x102089b68UL
#define V143_AB_INSTABUILD  0x102089b80UL
#define V143_AB_WALKSPEED   0x102089bc8UL
#define V143_AB_MAYFLY      0x102089bf8UL
#define V143_GETITEM_VA     0x100FB2560UL
#define V143_TAGBYITEM_VA   0x100FD7BDCUL
#define V143_GIVEADD_VA     0x100CAB61CUL
#define V143_EMPTYTAG_VA    0x10208D4A0UL
#define V143_APPLYENCH_VA   0x10102C0B4UL
#define V143_HANDREFRESH_VA 0x100F58704UL
#define V143_HAND_OFF       0x15D0
#define V143_SETGAMETYPE2_VA 0x100703F94UL
#define V143_FXMAKE_VA      0x100DF200CUL
#define V143_FXAPPLY_VA     0x100E5F158UL
#define V143_TPFAST_VA      0x100CCE7E4UL
#define V143_PLAYER_LEVEL_OFF 0xD00
#define V143_WEATHER_RAIN_OFF 0x15C
#define V143_WEATHER_RAINT_OFF 0x160
#define V143_WEATHER_LIGHT_OFF 0x164
#define V143_WEATHER_LIGHTT_OFF 0x168

typedef unsigned char (*V143GetBoolFn)(void *abil, void *entry);
typedef float (*V143GetFloatFn)(void *abil, void *entry);
typedef int (*V143CanFlyFn)(void *abil);
typedef void (*V143TickTimeFn)(void *level);
static V143GetBoolFn orig_143_getBool = NULL;
static V143GetFloatFn orig_143_getFloat = NULL;
static V143CanFlyFn orig_143_canFly = NULL;
static V143TickTimeFn orig_143_tickTime = NULL;
static void *gPlayer143 = NULL;
static int gTick143 = 0;

static unsigned char hooked_143_getBool(void *abil, void *entry) {
    gPlayer143 = (char *)abil - V143_ABILITIES_OFF;
    uintptr_t s = MWBMainSlide();
    if (gInvincible && entry == (void *)(s + V143_AB_INVULN)) return 1;
    if (gFastBreak && entry == (void *)(s + V143_AB_INSTABUILD)) return 1;
    return orig_143_getBool(abil, entry);
}
static int hooked_143_canFly(void *abil) {
    gPlayer143 = (char *)abil - V143_ABILITIES_OFF;
    if (gFly) return 1;
    return orig_143_canFly(abil);
}
static float hooked_143_getFloat(void *abil, void *entry) {
    if (gSpeed && entry == (void *)(MWBMainSlide() + V143_AB_WALKSPEED)) return 0.25f;
    float r = orig_143_getFloat(abil, entry);
    if (gSuperJump) {  // vy=+0xc8, 起跳瞬间抬升 (三证据, 无需新hook)
        void *p = (char *)abil - V143_ABILITIES_OFF;
        float vy = *(float *)((char *)p + 0xc8);
        if (vy > 0.1f && vy < 0.6f) *(float *)((char *)p + 0xc8) = 0.9f;
    }
    return r;
}
static void hooked_143_tickTime(void *level) {
    orig_143_tickTime(level);
    MWBPollCmdFile();
    if (gTimeMode == 1 || gTimeMode == 2) {
        void *ld = *(void **)((char *)level + 0xf8);
        if (ld) *(int32_t *)((char *)ld + 0x12c) = (gTimeMode == 1 ? 1000 : 13000);
    }
    if (gWeatherMode == 1 || gWeatherMode == 2 || gWeatherMode == 3) {
        void *ld = *(void **)((char *)level + 0xf8);
        if (ld) {
            char *w = (char *)ld;
            if (gWeatherMode == 1) {
                *(float *)(w + V143_WEATHER_RAIN_OFF) = 0.0f;
                *(float *)(w + V143_WEATHER_LIGHT_OFF) = 0.0f;
            } else if (gWeatherMode == 2) {
                *(float *)(w + V143_WEATHER_RAIN_OFF) = 1.0f;
                *(int *)(w + V143_WEATHER_RAINT_OFF) = 6000;
                *(float *)(w + V143_WEATHER_LIGHT_OFF) = 0.0f;
            } else {
                *(float *)(w + V143_WEATHER_RAIN_OFF) = 1.0f;
                *(int *)(w + V143_WEATHER_RAINT_OFF) = 6000;
                *(float *)(w + V143_WEATHER_LIGHT_OFF) = 1.0f;
                *(int *)(w + V143_WEATHER_LIGHTT_OFF) = 6000;
            }
        }
    }
    if (gMWBDebug && ((++gTick143 % 200) == 1)) {
        NSURL *logURL = [NSURL fileURLWithPath:@"/var/mobile/Documents/mowanbox.log"];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingToURL:logURL error:nil];
        if (fh) {
            [fh seekToEndOfFile];
            NSString *line = [NSString stringWithFormat:@"%@ [143] tickTime #%d level=%p player=%p\n",
                              [NSDate date], gTick143, level, gPlayer143];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    }
}

// 1.4.3 one-shot: 给予钻石 (Tag布局已定死, 容器Player+0x1888)
bool MWB143_Give(void *player, int itemId, int count) {
    if (!player || itemId < 0 || itemId > 511) return false;
    uintptr_t s = MWBMainSlide();
    void *item = ((void *(*)(int))(s + V143_GETITEM_VA))(itemId);
    if (!item) return false;
    char tag[0x78];
    memset(tag, 0, sizeof(tag));
    ((void (*)(void *, void *, int))(s + V143_TAGBYITEM_VA))(tag, item, count);
    ((void (*)(void *, void *, void *))(s + V143_GIVEADD_VA))(
        (char *)player + 0x1888, (void *)(s + V143_EMPTYTAG_VA), tag);
    return true;
}
// 1.4.3 one-shot: 手持超附魔 (跳过上限校验, 例锋利id9 x255)
bool MWB143_EnchantMax(void *player, int enchId, int level) {
    if (!player) return false;
    uintptr_t s = MWBMainSlide();
    void *hand = *(void **)((char *)player + V143_HAND_OFF);
    if (!hand) return false;
    ((void (*)(void *, int, int))(s + V143_APPLYENCH_VA))(hand, enchId, level);
    ((void (*)(void *))(s + V143_HANDREFRESH_VA))(player);
    return true;
}
// 1.4.3 one-shot: 夜视/速度药水 (实例15B: id/dur/amp/+C/+E)
bool MWB143_Effect(void *player, int fxId, int seconds, int ampl) {
    if (!player) return false;
    uintptr_t s = MWBMainSlide();
    char inst[16];
    memset(inst, 0, sizeof(inst));
    ((void (*)(void *, int, int, int, int, int))(s + V143_FXMAKE_VA))(inst, fxId, seconds * 20, ampl, 0, 1);
    ((void (*)(void *, void *))(s + V143_FXAPPLY_VA))(player, inst);
    return true;
}
// 1.4.3 one-shot: 传送 (同维度快路径 sub_100CCE7E4)
bool MWB143_Teleport(void *player, float x, float y, float z) {
    if (!player) return false;
    uintptr_t s = MWBMainSlide();
    float p[3] = {x, y, z};
    ((void (*)(void *, void *, float *, int, float, float, float))(s + V143_TPFAST_VA))(
        NULL, player, p, 3, x, y, z);
    return true;
}
// 1.4.3 one-shot: 生存/创造 (0/1, 替代虚表方案)
bool MWB143_SetGameType(void *player, int type) {
    if (!player || type < 0 || type > 2) return false;
    ((void (*)(void *, int))(MWBMainSlide() + V143_SETGAMETYPE2_VA))(player, type);
    return true;
}

#pragma mark - 1.2.15 版本适配 (本机未安装, 只合入不验证)
// 逆向纠正: instabuild=idx2(旧idx3实为lightning); LevelData内联Level+0xF8不解引用
// 能力表: 0=invulnerable 1=flying 2=instabuild 3=lightning 4=flySpeed 5=walkSpeed
//         6=noclip 7=mayfly 8=worldbuilder 9=mute
#define V1215_PLAYER_TICK   0x100376F78UL
#define V1215_LEVEL_TIMETICK 0x1005D41A4UL
#define V1215_SET_BOOL      0x100E97BF0UL
#define V1215_SET_FLOAT     0x100E97C88UL
#define V1215_ABIL_BASE     0x101F112D8UL
#define V1215_ABIL_FLYING   1
#define V1215_ABIL_INSTABUILD 2
#define V1215_ABIL_FLYSPEED 4
#define V1215_ABIL_WALKSPEED 5
#define V1215_ABIL_NOCLIP   6
#define V1215_ABIL_MAYFLY   7
#define V1215_PLAYER_ABIL_OFF 0x370
#define V1215_ACTOR_INVULN_OFF 0x24E
#define V1215_LD_OFF        0xF8
#define V1215_LD_TIME_OFF   0x12C
#define V1215_LD_RAIN_OFF   0x188
#define V1215_LD_LIGHT_OFF  0x18C
#define V1215_GET_SELECT    0x100E9F314UL
#define V1215_ST_FILL       0x100F11D64UL
#define V1215_ST_BLANK      0x100F125A8UL
#define V1215_CONT_ADD      0x100C36B50UL
#define V1215_CONT_FLAG     0x101F14B50UL
#define V1215_EQUIP_OFF     0x1820
#define V1215_ENCH_APPLY    0x100F54D30UL
#define V1215_FX_LOOKUP     0x100D4D6A4UL
#define V1215_FX_MAKE       0x100D4F114UL
#define V1215_FX_ADD        0x100DB8BE4UL
#define V1215_TP_SLOT       208
#define V1215_XP_PTS_SLOT   3024
#define V1215_XP_LVL_SLOT   3032
#define V1215_SET_SPAWN     0x100E9DB84UL

typedef void (*V1215TickFn)(void *self);
typedef void (*V1215SetBoolFn)(void *abil, void *entry, unsigned char v);
typedef void (*V1215SetFloatFn)(void *abil, void *entry, float v);
static V1215TickFn orig_1215_playerTick = NULL, orig_1215_timeTick = NULL;
static void *gPlayer1215 = NULL;

static void hooked_1215_playerTick(void *self) {
    orig_1215_playerTick(self);
    gPlayer1215 = self;
    if (gInvincible) ((unsigned char *)self)[V1215_ACTOR_INVULN_OFF] = 1;
    void *abil = (char *)self + V1215_PLAYER_ABIL_OFF;
    uintptr_t slide = MWBMainSlide();
    V1215SetBoolFn setB = (V1215SetBoolFn)(slide + V1215_SET_BOOL);
    V1215SetFloatFn setF = (V1215SetFloatFn)(slide + V1215_SET_FLOAT);
    if (gFastBreak) setB(abil, (void *)(slide + V1215_ABIL_BASE + V1215_ABIL_INSTABUILD * 0x18), 1);
    if (gFly) {
        setB(abil, (void *)(slide + V1215_ABIL_BASE + V1215_ABIL_FLYING * 0x18), 1);
        setB(abil, (void *)(slide + V1215_ABIL_BASE + V1215_ABIL_MAYFLY * 0x18), 1);
    }
    if (gNoclip) setB(abil, (void *)(slide + V1215_ABIL_BASE + V1215_ABIL_NOCLIP * 0x18), 1);
    if (gSpeed) setF(abil, (void *)(slide + V1215_ABIL_BASE + V1215_ABIL_WALKSPEED * 0x18), 0.25f);
}
static void hooked_1215_timeTick(void *level) {
    orig_1215_timeTick(level);
    if (gTimeMode == 1 || gTimeMode == 2) {
        // LevelData内联, 直接加偏移 (旧代码多一次解引用是野指针bug)
        *(int32_t *)((char *)level + V1215_LD_OFF + V1215_LD_TIME_OFF) =
            (gTimeMode == 1 ? 1000 : 13000);
    }
    if (gWeatherMode == 1 || gWeatherMode == 2) {
        char *ld = (char *)level + V1215_LD_OFF;
        if (gWeatherMode == 1) { *(float *)(ld + V1215_LD_RAIN_OFF) = 0.0f; *(int *)(ld + V1215_LD_LIGHT_OFF) = 0; }
        else { *(float *)(ld + V1215_LD_RAIN_OFF) = 1.0f; *(int *)(ld + V1215_LD_LIGHT_OFF) = 0; }
    }
}
// 1.2.15 one-shot: 方块给予/附魔/药水/传送/XP/出生点 (静态结论, 待真机验)
bool MWB1215_GiveBlock(void *player, int blkId, int count) {
    if (!player || blkId < 0 || blkId > 255 || count < 1) return false;
    uintptr_t s = MWBMainSlide();
    char proto[120], one[120];
    memset(proto, 0, sizeof(proto));
    ((void (*)(void *))(s + V1215_ST_BLANK))(proto);
    ((void (*)(void *, int, int, int))(s + V1215_ST_FILL))(proto, blkId, count, 0);
    if (*(uint8_t *)(proto + 0x13) == 0) return false;
    ((void (*)(void *, void *, void *))(s + V1215_CONT_ADD))(
        (char *)player + V1215_EQUIP_OFF, (void *)(s + V1215_CONT_FLAG), proto);
    (void)one;
    return true;
}
bool MWB1215_EnchantHeld(void *player, int enchId, int level) {
    if (!player) return false;
    uintptr_t s = MWBMainSlide();
    void *st = ((void *(*)(void *))(s + V1215_GET_SELECT))(player);
    if (!st) return false;
    ((void (*)(void *, int, int))(s + V1215_ENCH_APPLY))(st, enchId, level);
    return true;
}
bool MWB1215_Effect(void *player, int fxId, int seconds, int ampl) {
    if (!player) return false;
    uintptr_t s = MWBMainSlide();
    void *fx = ((void *(*)(int))(s + V1215_FX_LOOKUP))(fxId);
    if (!fx) return false;
    char inst[16];
    memset(inst, 0, sizeof(inst));
    ((void (*)(void *, void *, int, int, int, int))(s + V1215_FX_MAKE))(inst, fx, seconds * 20, ampl, 0, 1);
    ((void (*)(void *, void *))(s + V1215_FX_ADD))(player, inst);
    return true;
}
bool MWB1215_Teleport(void *player, float x, float y, float z) {
    if (!player) return false;
    float v[3] = {x, y, z};
    ((void (*)(void *, float *, int, int, int))(*(void **)((char *)player + V1215_TP_SLOT)))(player, v, 1, 3, 1);
    return true;
}
bool MWB1215_AddXP(void *player, int pts) {
    if (!player || !pts) return false;
    ((void (*)(void *, int))(*(void **)((char *)player + V1215_XP_PTS_SLOT)))(player, pts);
    return true;
}

#pragma mark - 1.20.62 版本适配 (EnTT ECS, systemBody为主hook)
// 逆向纠正: 旧tick@0x105D03F74打偏(事件路径非常驻); 换ECS system body@0x101F5CD20
// +wrapper@0x101F5D8B4+abilWrite@0x1040AA2B0; abilities无固定偏移, 运行时探测
#define V120_TICK_SENDINPUT_VA 0x105D03F74UL
#define V120_SYS_BODY_VA    0x101F5CD20UL
#define V120_SYS_WRAP_VA    0x101F5D8B4UL
#define V120_ABILWRITE_VA   0x1040AA2B0UL
#define V120_MOBGETBYID_VA  0x105D14BC8UL
#define V120_LEVELDATA_TIME_OFF 0x388
#define V120_LEVELDATA_GAME_OFF 0x370
#define V120_GETTIME_VA 0x1026D2DD8UL
#define V120_SETTIME_VA 0x106D30960UL
#define V120_UNWRAP_VA  0x106D31750UL

typedef void (*V120TickFn)(void *self);
typedef void (*V120SysBodyFn)(void *registry, uint64_t entity);
typedef void (*V120WrapFn)(void *actorLike);
typedef void (*V120AbilWriteFn)(void *pkt, void *stream, void *ctx);
typedef int (*V120GetTimeFn)(void *levelData);
typedef void (*V120SetTimeFn)(void *levelData, int t);
typedef void *(*V120UnwrapFn)(void *smartptr);
static V120TickFn orig_120_tick = NULL;
static V120SysBodyFn orig_120_sysBody = NULL;
static V120WrapFn orig_120_wrapper = NULL;
static V120AbilWriteFn orig_120_abilWrite = NULL;
static void *gLevelData120 = NULL;
static void *gActor120 = NULL;
static int gTick120 = 0;
static int gTick120b = 0;

static void hooked_120_tick(void *self) {
    orig_120_tick(self);
    gTick120++;
    if (!gLevelData120 && self) {
        V120UnwrapFn unwrap = (V120UnwrapFn)(MWBMainSlide() + V120_UNWRAP_VA);
        void *cand = unwrap((char *)self + 0x9D0);
        if (!cand) cand = unwrap(*(void **)((char *)self + 8));
        gLevelData120 = cand;
    }
    if (gLevelData120) {
        V120SetTimeFn setTime = (V120SetTimeFn)(MWBMainSlide() + V120_SETTIME_VA);
        if (gTimeMode == 1) setTime(gLevelData120, TICK_TIME_DAY);
        else if (gTimeMode == 2) setTime(gLevelData120, TICK_TIME_NIGHT);
    }
    if (gMWBDebug && (gTick120 % 200) == 1) {
        NSURL *logURL = [NSURL fileURLWithPath:@"/var/mobile/Documents/mowanbox.log"];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingToURL:logURL error:nil];
        if (fh) {
            [fh seekToEndOfFile];
            V120GetTimeFn getTime = (V120GetTimeFn)(MWBMainSlide() + V120_GETTIME_VA);
            int dayTime = gLevelData120 ? getTime(gLevelData120) : -1;
            NSString *line = [NSString stringWithFormat:@"%@ [120] tick #%d self=%p dayTime=%d\n",
                              [NSDate date], gTick120, self, dayTime];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    }
}

// ECS system body: x0=registry, x1=entity (每tick跑, 本地受控才进body)
static void hooked_120_sysBody(void *registry, uint64_t entity) {
    orig_120_sysBody(registry, entity);
    if (gMWBDebug && ((++gTick120b % 200) == 1)) {
        NSURL *logURL = [NSURL fileURLWithPath:@"/var/mobile/Documents/mowanbox.log"];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingToURL:logURL error:nil];
        if (fh) {
            [fh seekToEndOfFile];
            int flag = gActor120 ? ((unsigned char *)gActor120)[0x1ED8] : -1;
            NSString *line = [NSString stringWithFormat:@"%@ [120sys] #%d reg=%p ent=0x%llx actor=%p flag=%d\n",
                              [NSDate date], gTick120b, registry, entity, gActor120, flag];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    }
    if (gLevelData120 && (gTimeMode == 1 || gTimeMode == 2)) {
        V120SetTimeFn setTime = (V120SetTimeFn)(MWBMainSlide() + V120_SETTIME_VA);
        setTime(gLevelData120, (gTimeMode == 1 ? TICK_TIME_DAY : TICK_TIME_NIGHT));
    }
}
// wrapper: x0=Actor-like (+0x1ED8本地标志, +0xB90实体)
static void hooked_120_wrapper(void *self) {
    orig_120_wrapper(self);
    gActor120 = self;
}
// abilWrite: 只记包指针 (读链回推用, 不改包)
static void hooked_120_abilWrite(void *pkt, void *stream, void *ctx) {
    orig_120_abilWrite(pkt, stream, ctx);
    if (gMWBDebug && (gTick120b % 200) == 1) {
        NSURL *logURL = [NSURL fileURLWithPath:@"/var/mobile/Documents/mowanbox.log"];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingToURL:logURL error:nil];
        if (fh) {
            [fh seekToEndOfFile];
            NSString *line = [NSString stringWithFormat:@"%@ [120abil] pkt=%p stream=%p ctx=%p\n",
                              [NSDate date], pkt, stream, ctx];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    }
}
// 1.20 药水直调验有效性 (纯函数): 1=速度 8=跳跃 16=夜视
void MWB120ProbeMobEffect(void) {
    void *(*getById)(int) = (void *(*)(int))(MWBMainSlide() + V120_MOBGETBYID_VA);
    void *e1 = getById(1), *e8 = getById(8), *e16 = getById(16);
    NSURL *logURL = [NSURL fileURLWithPath:@"/var/mobile/Documents/mowanbox.log"];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingToURL:logURL error:nil];
    if (fh) {
        [fh seekToEndOfFile];
        NSString *line = [NSString stringWithFormat:@"%@ [120药水] speed=%p jump=%p nightvision=%p\n",
                          [NSDate date], e1, e8, e16];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    }
}

#pragma mark - 0.10 生存/创造切换后端
void MWB010SetCreative(void *player, bool creative) {
    if (!player) player = gLocalPlayer;
    if (!player) return;
    char *a = (char *)player + PLAYER_ABILITIES_OFFSET;
    if (creative) { a[0] = 1; a[2] = 1; a[3] = 1; }
    else *(uint32_t *)a = 0;
}

// 0.10 gMinecraft 捕获 (Minecraft::tick 首参即this) + 完整版切换 + 传送直调
static void *gMinecraft010 = NULL;
typedef void (*MinecraftTick010Fn)(void *self, int a, int b);
static MinecraftTick010Fn orig_mc010Tick = NULL;
static void hooked_mc010Tick(void *self, int a, int b) {
    orig_mc010Tick(self, a, b);
    gMinecraft010 = self;
}
void MWB010SetCreativeFull(bool creative) {
    void (*setC)(void *, bool) = (void (*)(void *, bool))MSFindSymbol(NULL, "__ZN9Minecraft17setIsCreativeModeEb");
    if (setC && gMinecraft010) { setC(gMinecraft010, creative); return; }
    MWB010SetCreative(NULL, creative);
}
bool MWB010Teleport(void *player, float x, float y, float z) {
    typedef void (*TpFn)(void *, float, float, float);
    TpFn tp = (TpFn)MSFindSymbol(NULL, "__ZN3Mob10teleportToEfff");
    if (!tp || !player) player = gLocalPlayer;
    if (!tp || !player) return false;
    tp(player, x, y, z);
    return true;
}

#pragma mark - 触摸模拟 (调试用, cycript 可调用)

// 通过 UITouch 模拟单次点击
// 用法 (cycript): [MWBTouchHelper tapAtX:512 y:480]
@interface MWBTouchHelper : NSObject
+ (void)tapAtX:(CGFloat)x y:(CGFloat)y;
+ (UIView *)findGameView;
// 直调式点击 (AGENTS 坑#6 合规路径: 直接调游戏 VC 的 touchesBegan/Ended,
// 不走 UIApplication sendEvent:, 不会 SIGSEGV)
// 用法 (cycript): [MWBTouchHelper tapGameAtX:512 y:485]
+ (void)tapGameAtX:(CGFloat)x y:(CGFloat)y;
+ (UIViewController *)findGameVC;
@end

@implementation MWBTouchHelper

// 找到 MCPE 的 OpenGL 渲染 view (GLKView/EAGLView)
+ (UIView *)findGameView {
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        // 跳过我们自己的 overlay window
        if ([w isKindOfClass:NSClassFromString(@"MWBOverlayWindow")]) continue;
        // 递归查找 GLKView/EAGLView
        NSMutableArray *stack = [@[w] mutableCopy];
        while (stack.count > 0) {
            UIView *v = stack.lastObject;
            [stack removeLastObject];
            NSString *cls = NSStringFromClass([v class]);
            if ([cls containsString:@"GLKView"] || [cls containsString:@"EAGL"] ||
                [cls containsString:@"Surface"] || [cls containsString:@"Render"] ||
                [cls containsString:@"MTKView"] || [cls containsString:@"Metal"]) {
                return v;
            }
            for (UIView *sub in v.subviews) [stack addObject:sub];
        }
    }
    return nil;
}

+ (UITouch *)createTouchAt:(CGPoint)pt window:(UIWindow *)window view:(UIView *)view phase:(UITouchPhase)phase {
    UITouch *touch = [[UITouch alloc] init];
    [touch setValue:window forKey:@"_window"];
    [touch setValue:view forKey:@"_view"];
    [touch setValue:@(phase) forKey:@"_phase"];
    [touch setValue:@([[NSDate date] timeIntervalSinceReferenceDate]) forKey:@"_timestamp"];
    [touch setValue:@1 forKey:@"_tapCount"];
    NSValue *loc = [NSValue valueWithCGPoint:pt];
    [touch setValue:loc forKey:@"_locationInWindow"];
    [touch setValue:loc forKey:@"_previousLocationInWindow"];
    return touch;
}

+ (void)tapAtX:(CGFloat)x y:(CGFloat)y {
    NSURL *logURL = [NSURL fileURLWithPath:@"/var/mobile/Documents/mowanbox.log"];
    void (^log)(NSString *) = ^(NSString *m) {
        NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], m];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingToURL:logURL error:nil];
        if (fh) { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
    };

    dispatch_async(dispatch_get_main_queue(), ^{
        UIView *gameView = [self findGameView];
        UIWindow *window = gameView.window;
        log([NSString stringWithFormat:@"模拟点击 (%.0f,%.0f) gameView=%@ window=%@",
            x, y, gameView.class, window.class]);
        if (!gameView || !window) { log(@"未找到游戏 view, 放弃"); return; }

        CGPoint pt = (CGPoint){x, y};

        // 必须走 UIApplication sendEvent: 路由 (直接调 window touchesBegan: 是
        // UIResponder 空实现, 不会转发给子 view); 同时 UIEvent 内部 _touches
        // 也要塞进触摸, 否则游戏侧查 allTouches 拿不到
        UITouch *touch = [self createTouchAt:pt window:window view:gameView phase:UITouchPhaseBegan];
        UIEvent *beganEvent = [[UIEvent alloc] init];
        @try { [beganEvent setValue:[NSSet setWithObject:touch] forKey:@"_touches"]; }
        @catch (NSException *e) { log([NSString stringWithFormat:@"注入 _touches 失败: %@", e]); return; }
        [[UIApplication sharedApplication] sendEvent:beganEvent];
        log(@"触摸 began 已发送");

        // Touch Ended (延迟 80ms, 复用同一个 UITouch 对象)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [touch setValue:@(UITouchPhaseEnded) forKey:@"_phase"];
            UIEvent *endEvent = [[UIEvent alloc] init];
            @try { [endEvent setValue:[NSSet setWithObject:touch] forKey:@"_touches"]; }
            @catch (NSException *e) { log([NSString stringWithFormat:@"注入 _touches 失败: %@", e]); return; }
            [[UIApplication sharedApplication] sendEvent:endEvent];
            log(@"触摸 ended 已发送");
        });
    });
}

// 找到游戏的主 ViewController (minecraftpe 开头、非自家 overlay)
+ (UIViewController *)findGameVC {
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        UIViewController *rvc = w.rootViewController;
        if (!rvc) continue;
        NSString *cls = NSStringFromClass([rvc class]);
        if ([cls containsString:@"MWB"] || [cls containsString:@"EMI"]) continue;
        if ([cls rangeOfString:@"minecraftpe" options:NSCaseInsensitiveSearch].length > 0) {
            return rvc;
        }
    }
    return nil;
}

// 直调式点击: began+ended 直接打到游戏 VC (主线程同步执行)
// 1.20 教训: 设置类弹窗是独立 VC, 只打主 VC 够不着, 改为全窗口全 VC 广播
+ (void)tapGameAtX:(CGFloat)x y:(CGFloat)y {
    NSURL *logURL = [NSURL fileURLWithPath:@"/var/mobile/Documents/mowanbox.log"];
    void (^log)(NSString *) = ^(NSString *m) {
        NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], m];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingToURL:logURL error:nil];
        if (fh) { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
    };
    dispatch_async(dispatch_get_main_queue(), ^{
        NSMutableArray *vcs = [NSMutableArray new];
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            if ([w isKindOfClass:NSClassFromString(@"MWBOverlayWindow")]) continue;
            UIViewController *rvc = w.rootViewController;
            while (rvc) {
                NSString *cls = NSStringFromClass([rvc class]);
                if (![cls containsString:@"MWB"] && ![cls containsString:@"EMI"]) [vcs addObject:rvc];
                if (rvc.presentedViewController && rvc.presentedViewController != rvc)
                    rvc = rvc.presentedViewController;
                else break;
            }
            if (vcs.count == 0) {
                UIViewController *fvc = [self findGameVC];
                if (fvc) [vcs addObject:fvc];
            }
        }
        UIView *gameView = [self findGameView];
        UIWindow *window = gameView.window ?: [UIApplication sharedApplication].keyWindow;
        log([NSString stringWithFormat:@"直调点击 (%.0f,%.0f) vc数=%lu view=%@",
             x, y, (unsigned long)vcs.count, NSStringFromClass([gameView class])]);
        if (vcs.count == 0 || !gameView) { log(@"未找到游戏 VC/view, 放弃"); return; }
        CGPoint pt = (CGPoint){x, y};
        UITouch *touch = [self createTouchAt:pt window:window view:gameView phase:UITouchPhaseBegan];
        NSSet *s = [NSSet setWithObject:touch];
        for (UIViewController *vc in vcs) [vc touchesBegan:s withEvent:nil];
        log(@"直调 began 已调用");
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [touch setValue:@(UITouchPhaseEnded) forKey:@"_phase"];
            for (UIViewController *vc in vcs) [vc touchesEnded:s withEvent:nil];
            log(@"直调 ended 已调用");
        });
    });
}

// cycript 直调开关 (确定性测试通道, 不依赖坐标点悬浮窗)
// 用法: cycript -p PID -e "[MWBTouchHelper dbgInv:1]"
+ (void)dbgInv:(BOOL)v { gInvincible = v; }
+ (void)dbgFly:(BOOL)v { gFly = v; }
+ (void)dbgBreak:(BOOL)v { gFastBreak = v; }
+ (void)dbgSpeed:(BOOL)v { gSpeed = v; }
+ (void)dbgJump:(BOOL)v { gSuperJump = v; }
+ (void)dbgNoclip:(BOOL)v { gNoclip = v; }
+ (void)dbgNight:(BOOL)v { gNightVision = v; }
+ (void)dbgAura:(BOOL)v { gKillAura = v; }
+ (void)dbgMap:(BOOL)v { gMinimap = v; MWBMinimapShow(v); }
+ (void)dbgDebug:(BOOL)v { gMWBDebug = v; }
+ (void)dbgTime:(int)v { gTimeMode = v; }
+ (void)dbgWeather:(int)v { gWeatherMode = v; }
+ (void)dbgHeal { MWBHealNow(); }
+ (void)dbgEnchant { MWBEnchantHeld255(); }
+ (void)dbgGive117:(int)itemId {
    if (gGV != (int)MWBGameV1_1_7) return;
    for (int i = 0; i < 100 && !gPlayer117; i++) [NSThread sleepForTimeInterval:0.5];
    if (gPlayer117) MWB117_Give(gPlayer117, itemId, 1);
}
+ (void)dbgGive143:(int)itemId { if (gGV == (int)MWBGameV1_4_3 && gPlayer143) MWB143_Give(gPlayer143, itemId, 5); }
+ (void)dbgTeleport { MWBTeleportUp10(); }
+ (void)dbgFill { MWBFillStone5(); }
+ (void)dbgReactor { MWB010SpawnReactor(); }
+ (void)dbgDiff:(int)difficulty { MWBSetDifficulty010(difficulty); }
+ (void)dbgProbe120 { MWB120ProbeMobEffect(); }

@end

#pragma mark - 跨版本动作分发

// flag文件通道 (绕过cycript两次调用上限: ssh touch /tmp/mwbcmd-<动作>[-<参数>] 即可触发)
// 支持: inv-0/1 fly break speed jump noclip night aura map debug time-0/1/2 weather-0/1/2/3
//       heal enchant give117-264 give143-264 effect143-16 teleport1133 fill5 reactor diff-0/1/2/3
// 注意: 游戏调用必须在tick返回后异步执行 (tick内同步调容器函数会死锁, -19冻屏教训)
static int gPendGive117 = -1, gPendGive143 = -1, gPendEffect143 = -1, gPendEffect1133 = -1;
static int gPendDiff010 = -1;
static BOOL gPendHeal = NO, gPendEnchant = NO, gPendTeleport = NO, gPendFill = NO, gPendReactor = NO;
static void MWBFlushPending(void) {
    NSURL *lurl = [NSURL fileURLWithPath:@"/var/mobile/Documents/mowanbox.log"];
    NSFileHandle *lfh = [NSFileHandle fileHandleForWritingToURL:lurl error:nil];
    if (lfh) {
        [lfh seekToEndOfFile];
        NSString *line = [NSString stringWithFormat:@"%@ [泻洪] heal=%d ench=%d g117=%d g143=%d e143=%d e1133=%d tp=%d fill=%d reactor=%d diff=%d\n",
                          [NSDate date], gPendHeal, gPendEnchant, gPendGive117, gPendGive143,
                          gPendEffect143, gPendEffect1133, gPendTeleport, gPendFill, gPendReactor, gPendDiff010];
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
}
static void MWBPollCmdFile(void) {
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

static void MWBHealNow(void) {
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
static void MWBEnchantHeld255(void) {
    if (gGV == (int)MWBGameV1_1_7 && gPlayer117) MWB117_EnchantMax(gPlayer117, 9, 255);
    else if (gGV == (int)MWBGameV1_4_3 && gPlayer143) MWB143_EnchantMax(gPlayer143, 9, 255);
    else if (gGV == (int)MWBGameV1_2_15 && gPlayer1215) MWB1215_EnchantHeld(gPlayer1215, 9, 255);
}
static void MWBTeleportUp10(void) {
    if (gGV == (int)MWBGameV1_13_3 && gPlayer1133) MWB1133_TeleportUp10(gPlayer1133);
}
static void MWBFillStone5(void) {
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
static void MWBSetDifficulty010(int difficulty) {
    if (gGV != (int)MWBGameV0_10 || !gLevel) return;
    if (difficulty < 0 || difficulty > 3) return;
    typedef void (*SetDifficultyFn)(void *, int);
    SetDifficultyFn setDifficulty =
        (SetDifficultyFn)MSFindSymbol(NULL, "__ZN11ServerLevel13setDifficultyEi");
    if (!setDifficulty) setDifficulty = (SetDifficultyFn)(MWBMainSlide() + 0x1001b8f7cUL);
    if (setDifficulty) setDifficulty(gLevel, difficulty);
}

// 0.10 一键反应核: 在玩家脚下按游戏校验图案搭平台+核, 再直调 NetherReactorTile::use 激活
static void MWB010SpawnReactor(void) {
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
static void MWBMinimapShow(BOOL on) {
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
static void MWBMinimapRefresh(void) {
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
        // 安装 EMI 物品管理器 (独立悬浮按钮)
        [MWBEMIManager install];
    });
}

%ctor {
    MWBRegisterFont();
    NSLog(@"[魔玩盒子] 插件已加载");
    // 版本自适应: 不依赖包名,运行时识别游戏版本再选注入方式,同一UI操作
    MWBGameVersion gv = [MWBVersion currentVersion];
    gGV = (int)gv;
    NSLog(@"[魔玩盒子] 当前游戏版本: %@ 注入方式=%ld",
          [MWBVersion nameForVersion:gv], (long)[MWBVersion currentInjectStyle]);

    // 日志辅助: 追加写文件
    void (^logFile)(NSString *) = ^(NSString *m) {
        NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], m];
        NSURL *logURL = [NSURL fileURLWithPath:@"/var/mobile/Documents/mowanbox.log"];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingToURL:logURL error:nil];
        if (fh) { [fh seekToEndOfFile]; [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]]; [fh closeFile]; }
        else { [line writeToURL:logURL atomically:YES encoding:NSUTF8StringEncoding error:nil]; }
    };

    #define MWB_HOOK(mangled, replacement, original) do { \
        void *_s = MSFindSymbol(NULL, mangled); \
        if (_s) { MSHookFunction(_s, (void *)replacement, (void **)&original); \
            NSLog(@"[魔玩盒子] 已 hook: %s -> %p", mangled, _s); \
            logFile([NSString stringWithFormat:@"[Toolbox] hook 成功: %s @ %p", mangled, _s]); } \
        else { NSLog(@"[魔玩盒子] 警告: 未找到 %s", mangled); \
            logFile([NSString stringWithFormat:@"[Toolbox] hook 失败: 未找到 %s", mangled]); } \
    } while (0)

    MWB_HOOK("__ZN11LocalPlayer10normalTickEv", hooked_normalTick, orig_normalTick);
    MWB_HOOK("__ZN5Level4tickEv", hooked_levelTick, orig_levelTick);
    MWB_HOOK("__ZN9Minecraft4tickEii", hooked_mc010Tick, orig_mc010Tick);

    // 1.13.3: 无符号,按静态VA+slide直接hook (函数2636B/2396B,跳板安全)
    if (gv == MWBGameV1_13_3) {
        uintptr_t slide = MWBMainSlide();
        void *pTick = (void *)(slide + V1133_PLAYERNORMALTICK_VA);
        void *lTick = (void *)(slide + V1133_LEVELTICK_VA);
        MSHookFunction(pTick, (void *)hooked_1133_playerTick, (void **)&orig_1133_playerTick);
        MSHookFunction(lTick, (void *)hooked_1133_levelTick, (void **)&orig_1133_levelTick);
        NSLog(@"[魔玩盒子] 1.13.3 hook: playerTick=%p levelTick=%p", pTick, lTick);
        logFile([NSString stringWithFormat:@"[1133] hook 成功: playerTick=%p levelTick=%p", pTick, lTick]);
    }

    // 1.1.7: Abilities API + tick hook + 跳跃取值器 (函数均≥32B,跳板安全)
    if (gv == MWBGameV1_1_7) {
        uintptr_t slide = MWBMainSlide();
        v117_setBool = (V117SetBoolFn)(slide + V117_SETBOOL_VA);
        v117_setFloat = (V117SetFloatFn)(slide + V117_SETFLOAT_VA);
        MSHookFunction((void *)(slide + V117_PLAYERTICK_VA), (void *)hooked_117_playerTick, (void **)&orig_117_playerTick);
        MSHookFunction((void *)(slide + V117_LEVELTICK_VA), (void *)hooked_117_levelTick, (void **)&orig_117_levelTick);
        MSHookFunction((void *)(slide + V117_JUMPPOWER_VA), (void *)hooked_117_jump, (void **)&orig_117_jump);
        MSHookFunction((void *)(slide + V117_GETBOOL_VA), (void *)hooked_117_getBool, (void **)&orig_117_getBool);
        MSHookFunction((void *)(slide + V117_HURT_VA), (void *)hooked_117_hurt, (void **)&orig_117_hurt);
        NSLog(@"[魔玩盒子] 1.1.7 hook: playerTick/levelTick/jump/getBool+hurt");
        logFile(@"[117] hook 成功: playerTick+levelTick+jump+getBool+hurt");
    }

    // 1.4.3: getter 拦截模型 (无需 normalTick)
    if (gv == MWBGameV1_4_3) {
        uintptr_t s143 = MWBMainSlide();
        MSHookFunction((void *)(s143 + V143_GETBOOL_VA), (void *)hooked_143_getBool, (void **)&orig_143_getBool);
        MSHookFunction((void *)(s143 + V143_CANFLY_VA), (void *)hooked_143_canFly, (void **)&orig_143_canFly);
        MSHookFunction((void *)(s143 + V143_GETFLOAT_VA), (void *)hooked_143_getFloat, (void **)&orig_143_getFloat);
        MSHookFunction((void *)(s143 + V143_TICKTIME_VA), (void *)hooked_143_tickTime, (void **)&orig_143_tickTime);
        NSLog(@"[魔玩盒子] 1.4.3 hook: getBool/canFly/getFloat/tickTime");
        logFile(@"[143] hook 成功: getBool+canFly+getFloat+tickTime");
    }

    // 1.2.15: 本机未安装, 合入待验 (Actor无敌位+能力setter+时间tick)
    if (gv == MWBGameV1_2_15) {
        uintptr_t s1215 = MWBMainSlide();
        MSHookFunction((void *)(s1215 + V1215_PLAYER_TICK), (void *)hooked_1215_playerTick, (void **)&orig_1215_playerTick);
        MSHookFunction((void *)(s1215 + V1215_LEVEL_TIMETICK), (void *)hooked_1215_timeTick, (void **)&orig_1215_timeTick);
        NSLog(@"[魔玩盒子] 1.2.15 hook: playerTick+timeTick");
        logFile(@"[1215] hook 成功: playerTick+timeTick");
    }

    // 1.20.62: ECS systemBody为主hook (旧sendInput打偏, 保留但不再依赖)
    if (gv == MWBGameV1_20_62) {
        uintptr_t s120 = MWBMainSlide();
        MSHookFunction((void *)(s120 + V120_TICK_SENDINPUT_VA), (void *)hooked_120_tick, (void **)&orig_120_tick);
        MSHookFunction((void *)(s120 + V120_SYS_BODY_VA), (void *)hooked_120_sysBody, (void **)&orig_120_sysBody);
        MSHookFunction((void *)(s120 + V120_SYS_WRAP_VA), (void *)hooked_120_wrapper, (void **)&orig_120_wrapper);
        MSHookFunction((void *)(s120 + V120_ABILWRITE_VA), (void *)hooked_120_abilWrite, (void **)&orig_120_abilWrite);
        NSLog(@"[魔玩盒子] 1.20.62 hook: tick+sysBody+wrapper+abilWrite");
        logFile(@"[120] hook 成功: tick+sysBody+wrapper+abilWrite");
    }

    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidFinishLaunchingNotification
                    object:nil queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *n){ MWBInstall(); }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0*NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ MWBInstall(); });
}
