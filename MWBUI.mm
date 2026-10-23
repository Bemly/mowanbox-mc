/* MWBUI.mm — 像素风 UI 套件实现 (配色/字体/像素视图/SVG/开关/按钮/侧栏图标/点击音) */
#import <UIKit/UIKit.h>
#import <CoreText/CoreText.h>
#import <AVFoundation/AVFoundation.h>
#import "MWBCommon.h"
#import "MWBUI.h"
#import "FusionPixel.h"

#pragma mark - 像素配色 (与参考 CSS 变量一一对应)


UIColor *kTopBar;          // #777078 顶栏
UIColor *kSidebar;         // #a69d99 侧栏
UIColor *kSidebarLight;    // #c3bbb6
UIColor *kSidebarDark;     // #655f5f
UIColor *kInk;             // #343132
UIColor *kWhiteText;       // #eeeae6
UIColor *kPanelBG;         // rgba(15,16,14,0.66)
UIColor *kField;           // #302d2e
UIColor *kControl;         // #c5bcba
UIColor *kControlLight;    // #eee9e5
UIColor *kControlDark;     // #6b6668

UIFont *MWBPixelFont(CGFloat size) {
    UIFont *f = [UIFont fontWithName:@"Fusion-Pixel-8px-Prop-zh_hans-Regular" size:size];
    if (!f) f = [UIFont fontWithName:@"Fusion Pixel 8px Prop zh_hans" size:size];
    return f ?: [UIFont systemFontOfSize:size];
}

// 注册内嵌的 Pixelify Sans 字体
void MWBRegisterFont(void) {
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

// MC 原版开关音效: click.m4a, 运行时从游戏 bundle 加载 (不打包版权素材, 与贴图同路)
static AVAudioPlayer *gMWBClickPlayer = nil;
void MWBEnsureClickLoaded(void) {
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        NSURL *url = [[NSBundle mainBundle] URLForResource:@"click" withExtension:@"m4a"];
        NSString *msg = nil;
        if (url) {
            NSError *err = nil;
            gMWBClickPlayer = [[AVAudioPlayer alloc] initWithContentsOfURL:url error:&err];
            if (gMWBClickPlayer) {
                gMWBClickPlayer.volume = 1.0;
                [gMWBClickPlayer prepareToPlay];
                msg = [NSString stringWithFormat:@"[魔玩盒子] 点击音已加载(%.2fs)", gMWBClickPlayer.duration];
            } else {
                msg = [NSString stringWithFormat:@"[魔玩盒子] 点击音加载失败: %@", err.localizedDescription];
            }
        } else {
            msg = @"[魔玩盒子] 未找到 click.m4a";
        }
        NSLog(@"%@", msg);
        NSURL *logURL = [NSURL fileURLWithPath:MWB_LOG_PATH];
        NSFileHandle *fh = [NSFileHandle fileHandleForWritingToURL:logURL error:nil];
        if (fh) {
            [fh seekToEndOfFile];
            NSString *line = [NSString stringWithFormat:@"%@ %@\n", [NSDate date], msg];
            [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        }
    });
}
void MWBPlayClick(void) {
    MWBEnsureClickLoaded();
    if (gMWBClickPlayer) { gMWBClickPlayer.currentTime = 0; [gMWBClickPlayer play]; }
}

// 游戏原版图标: 运行时从游戏 bundle 切图 (CgBI 的 PNG 用 UIImage 直接读,
// iOS 会自己处理; 按像素矩形裁剪, 最近邻放大保持像素风)
UIImage *MWBGameIcon(NSString *file, CGRect rect) {
    static NSCache *cache = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSCache new]; });
    NSString *key = [NSString stringWithFormat:@"%@-%@",
                     file, NSStringFromCGRect(rect)];
    UIImage *hit = [cache objectForKey:key];
    if (hit) return hit;
    NSString *res = [[[NSBundle mainBundle] resourcePath]
                     stringByAppendingPathComponent:file];
    UIImage *full = [UIImage imageWithContentsOfFile:res];
    if (!full) return nil;
    // rect 按 256 基准给出, 实际图可能是 2x Retina (@2x 后缀同名文件 iOS 自动选,
    // 但包内是 CgBI 无 @2x, 按 full.scale 换算)
    CGFloat sc = full.scale ?: 1.0;
    CGSize px = (CGSize){full.size.width * sc, full.size.height * sc};
    if (px.width < 1 || px.height < 1) return nil;
    // 把 256 基准矩形映射到实际像素
    CGFloat k = px.width / 256.0;
    CGRect pr = (CGRect){{rect.origin.x * k, rect.origin.y * k},
                         {rect.size.width * k, rect.size.height * k}};
    if (pr.origin.x < 0 || pr.origin.y < 0 ||
        CGRectGetMaxX(pr) > px.width + 1 || CGRectGetMaxY(pr) > px.height + 1)
        return nil;
    CGImageRef sub = CGImageCreateWithImageInRect(full.CGImage, pr);
    if (!sub) return nil;
    UIImage *out = [UIImage imageWithCGImage:sub scale:1.0
                               orientation:full.imageOrientation];
    CGImageRelease(sub);
    if (out) [cache setObject:out forKey:key];
    return out;
}

// 创建带像素阴影的属性字符串
NSAttributedString *MWBPixelText(NSString *text, UIFont *font, UIColor *color,
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

UIBezierPath *MWBPathFromSVG(NSString *d) {
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

// 游戏原生开关拨钮 (运行时从 touchgui 切图, 不进仓库; 读不到回落像素格)
static UIImage *MWBTOGOff_(void) {
    static UIImage *im; static dispatch_once_t o;
    dispatch_once(&o, ^{ im = MWBGameIcon(@"touchgui.png", (CGRect){{162,205},{36,20}}); });
    return im;
}
static UIImage *MWBTOGOn_(void) {
    static UIImage *im; static dispatch_once_t o;
    dispatch_once(&o, ^{ im = MWBGameIcon(@"touchgui.png", (CGRect){{199,205},{36,20}}); });
    return im;
}

@implementation MWBPixelToggle {
    UIView *_i, *_b;  // 左格 / 右格 (无游戏图时回落用)
    UIImageView *_togImg;  // 游戏拨钮 (有图时用)
}
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        [self addTarget:self action:@selector(toggle) forControlEvents:UIControlEventTouchUpInside];
        if (MWBTOGOff_() && MWBTOGOn_()) {
            // 游戏原生拨钮模式: 自带石钮边框, 本体透明
            self.backgroundColor = [UIColor clearColor];
            self.layer.borderWidth = 0;
            _togImg = [[UIImageView alloc] init];
            _togImg.contentMode = UIViewContentModeScaleAspectFit;
            _togImg.layer.magnificationFilter = kCAFilterNearest;
            _togImg.userInteractionEnabled = NO;
            [self addSubview:_togImg];
        } else {
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
        }
        [self applyStyle];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w=self.bounds.size.width, h=self.bounds.size.height;
    if (_togImg) {
        // 36x20 原生比, 按高适配居中 (行高77 -> 图高63)
        CGFloat ih = h - 14, iw = ih * 36.0 / 20.0;
        if (iw > w) { iw = w; ih = iw * 20.0 / 36.0; }
        _togImg.frame = (CGRect){{(w-iw)/2,(h-ih)/2},{iw,ih}};
        return;
    }
    CGFloat pad=7;
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
- (void)toggle { MWBPlayClick(); self.on = !_on; [self sendActionsForControlEvents:UIControlEventValueChanged]; }
- (void)setOn:(BOOL)on { _on = on; [self applyStyle]; }
- (void)applyStyle {
    if (_togImg) { _togImg.image = _on ? MWBTOGOn_() : MWBTOGOff_(); return; }
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
// 像素按钮统一 MC 点击音
- (void)sendAction:(SEL)action to:(id)target forEvent:(UIEvent *)event {
    MWBPlayClick();
    [super sendAction:action to:target forEvent:event];
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

@implementation MWBSideButton {
    NSMutableArray<CAShapeLayer *> *_shapeLayers;
    UIView *_iconView;
}
- (instancetype)initWithImage:(UIImage *)img {
    UIImageView *iv = [[UIImageView alloc] initWithImage:img];
    iv.contentMode = UIViewContentModeScaleAspectFit;
    return [self initWithIconView:iv];
}
- (instancetype)initWithIconView:(UIView *)icon {
    if ((self = [super init])) {
        self.backgroundColor = MWB_COLOR(0xad,0xa4,0xa0);
        self.layer.borderWidth = 0;
        _shapeLayers = [NSMutableArray new];
        _iconView = icon;
        _iconView.userInteractionEnabled = NO;
        _iconView.layer.magnificationFilter = kCAFilterNearest;
        [self addSubview:_iconView];
    }
    return self;
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
    if (_iconView) {
        // 游戏原版图标: 居中占 74%, 最近邻放大保像素风
        CGFloat s = MIN(w,h) * 0.89;  // 1.2x (用户嫌小)
        _iconView.frame = (CGRect){{(w-s)/2,(h-s)/2},{s,s}};
    }
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
// 侧栏图标统一 MC 点击音
- (void)sendAction:(SEL)action to:(id)target forEvent:(UIEvent *)event {
    MWBPlayClick();
    [super sendAction:action to:target forEvent:event];
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

#pragma mark - 插件自身语言 (中英 i18n, 与游戏汉化独立)

// 中英对照表: {key, 中文, 英文} (按钮英文按 120px/28号与 95px/24号宽度收过, 长词用缩写)
static const char *kMWBTrTable[][3] = {
    {"back", "返回", "Back"},
    {"options", "选项", "Options"},
    {"cheats", "作弊", "Cheats"},
    {"world", "世界", "World"},
    {"float", "悬浮窗", "Float"},
    {"spawn", "刷怪", "Spawn"},
    {"ysm", "模型设置", "Model"},
    {"ysm_models", "模型", "Models"},
    {"ysm_prev", "前一页", "Prev"},
    {"ysm_next", "后一页", "Next"},
    {"ysm_set", "设置", "Settings"},
    {"ysm_back", "返回", "Back"},
    {"ysm_none", "没找到模型（mwbmodels/<名>.glb＋<名>_anim.json）", "No models (mwbmodels/<id>.glb + <id>_anim.json)"},
    {"inv", "无敌", "Invincible"},
    {"fly", "飞行", "Fly"},
    {"instabreak", "快速破坏", "Instabreak"},
    {"noclip", "穿墙", "Noclip"},
    {"night", "夜视", "Night Vision"},
    {"aura", "杀戮光环", "Kill Aura"},
    {"minimap", "小地图", "Minimap"},
    {"slime", "史莱姆区块", "Slime Chunks"},
    {"debug", "调试模式", "Debug"},
    {"speed", "加速奔跑", "Fast Run"},
    {"jump", "超级跳跃", "Super Jump"},
    {"skin4d", "4D皮肤", "4D Skin"},
    {"time", "时间", "Time"},
    {"srise", "日出", "Sunrise"},
    {"day", "白天", "Day"},
    {"noon", "正午", "Noon"},
    {"dusk", "黄昏", "Dusk"},
    {"nightt", "夜晚", "Night"},
    {"midn", "午夜", "12 AM"},
    {"adjust", "微调", "Adjust"},
    {"weather", "天气", "Weather"},
    {"clear", "晴", "Clear"},
    {"rain", "雨", "Rain"},
    {"storm", "雷", "Storm"},
    {"action", "动作", "Action"},
    {"heal", "治疗", "Heal"},
    {"ench", "附魔", "Ench"},
    {"tp", "传送", "TP"},
    {"fill", "铺石", "Fill"},
    {"diff", "难度", "Difficulty"},
    {"peace", "和平", "Peace"},
    {"easy", "简单", "Easy"},
    {"normal", "普通", "Normal"},
    {"hard", "困难", "Hard"},
    {"reactor", "反应核", "Reactor"},
    {"ignite", "点燃", "Ignite"},
    {"boom", "爆炸", "Boom"},
    {"mode", "模式", "Mode"},
    {"surv", "生存", "Survival"},
    {"creat", "创造", "Creative"},
    {"size", "大小", "Size"},
    {"sz_s", "小", "S"},
    {"sz_m", "中", "M"},
    {"sz_l", "大", "L"},
    {"alpha", "透明度", "Alpha"},
    {"al_lo", "低", "Low"},
    {"al_md", "中", "Med"},
    {"al_hi", "高", "High"},
    {"pos", "位置", "Position"},
    {"reset", "复位", "Reset"},
    {"lang", "语言", "Language"},
    {"enter_world", "请先进入世界", "Enter a world first"},
    {"t_float_s", "小悬浮窗", "Small float"},
    {"t_float_m", "中悬浮窗", "Medium float"},
    {"t_float_l", "大悬浮窗", "Large float"},
    {"t_alpha_lo", "低透明度", "Low alpha"},
    {"t_alpha_md", "中透明度", "Medium alpha"},
    {"t_alpha_hi", "高透明度", "High alpha"},
    {"t_float_reset", "悬浮窗已复位", "Float reset"},
    {"t_sent", "(已发送)", "(sent)"},
    {"t_only010", "仅0.10可用", "0.10 only"},
    {"t_map_auto", "小地图已连带打开", "Minimap auto-on"},
    {"t_spawned", "已刷出(玩家旁边)", " spawned nearby"},
    {"cave_tag", "·洞", "·cave"},
    {"recipe_of", "的配方", " Recipe"},
    {"recipe_none", "游戏配方中没有能合成该物品的配方 (自然生成 / 怪物掉落)", "No recipe in game (natural / drop only)"},
    {"recipe_hint", "轻触任意处关闭", "Tap anywhere to close"},
    {"variant_sel", "选择变种", "Variants"},
    {"give1", "给 1 个", "Give 1"},
    {"give64", "给 1 组", "Give 64"},
    {"egg0", "鸡", "Chicken"},
    {"egg1", "牛", "Cow"},
    {"egg2", "猪", "Pig"},
    {"egg3", "羊", "Sheep"},
    {"egg4", "狼", "Wolf"},
    {"egg5", "村民", "Villager"},
    {"egg6", "哞菇", "Mooshroom"},
    {"egg7", "僵尸", "Zombie"},
    {"egg8", "爬行者", "Creeper"},
    {"egg9", "骷髅", "Skeleton"},
    {"egg10", "蜘蛛", "Spider"},
    {"egg11", "猪人", "Pigman"},
    {"egg12", "史莱姆", "Slime"},
    {"egg13", "末影人", "Enderman"},
    {"egg14", "蠹虫", "Silverfish"},
    {"wool", "羊毛", "Wool"},
    {"dye", "染料", "Dye"},
    {"coal", "煤炭", "Coal"},
    {"charcoal", "木炭", "Charcoal"},
    {"oak", "橡木", "Oak"},
    {"spruce", "云杉", "Spruce"},
    {"birch", "桦木", "Birch"},
    {"variant_n", "变种", "Variant"},
    {"c_white", "白", "White"},
    {"c_orange", "橙", "Orange"},
    {"c_magenta", "品红", "Magenta"},
    {"c_lblue", "淡蓝", "Lt Blue"},
    {"c_yellow", "黄", "Yellow"},
    {"c_lime", "黄绿", "Lime"},
    {"c_pink", "粉", "Pink"},
    {"c_gray", "灰", "Gray"},
    {"c_lgray", "浅灰", "Lt Gray"},
    {"c_cyan", "青", "Cyan"},
    {"c_purple", "紫", "Purple"},
    {"c_blue", "蓝", "Blue"},
    {"c_brown", "棕", "Brown"},
    {"c_green", "绿", "Green"},
    {"c_red", "红", "Red"},
    {"c_black", "黑", "Black"},
    {"c_ink", "墨囊", "Ink"},
    {"c_rose", "玫瑰红", "Rose"},
    {"c_cactus", "仙人掌绿", "Cactus"},
    {"c_cocoa", "可可豆", "Cocoa"},
    {"c_sky", "天蓝", "Sky"},
    {"c_silver", "银灰", "Silver"},
    {"c_pink2", "粉红", "Pink"},
    {"c_bone", "骨粉", "Bone"},
};

static NSDictionary *MWBTrDict(void) {
    static NSDictionary *d = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *m = [NSMutableDictionary new];
        size_t n = sizeof(kMWBTrTable) / sizeof(kMWBTrTable[0]);
        for (size_t i = 0; i < n; i++) {
            NSString *k = [NSString stringWithUTF8String:kMWBTrTable[i][0]];
            NSString *zh = [NSString stringWithUTF8String:kMWBTrTable[i][1]];
            NSString *en = [NSString stringWithUTF8String:kMWBTrTable[i][2]];
            m[k] = @[zh, en];
        }
        d = m;
    });
    return d;
}

static NSString *MWBPluginLangPath(void) {
    return @"/var/mobile/Documents/mwbpluglang.plist";
}

static int gMWBPluginLangCached = -1;   // 内存缓存 (set 时同步更新, 免得切完还读旧值)

void MWBSetPluginLang(int lang) {
    if (lang != 0 && lang != 1) return;
    gMWBPluginLangCached = lang;
    NSMutableDictionary *d = [NSMutableDictionary new];
    d[@"lang"] = @(lang);
    [d writeToURL:[NSURL fileURLWithPath:MWBPluginLangPath()] atomically:YES];
}

int MWBPluginLang(void) {
    if (gMWBPluginLangCached >= 0) return gMWBPluginLangCached;
    NSURL *u = [NSURL fileURLWithPath:MWBPluginLangPath()];
    NSError *e = nil;
    NSDictionary *ro = [NSDictionary dictionaryWithContentsOfURL:u error:&e];
    int v = 0;
    if ([ro isKindOfClass:[NSDictionary class]]) v = (int)[ro[@"lang"] integerValue];
    gMWBPluginLangCached = (v == 1) ? 1 : 0;
    return gMWBPluginLangCached;
}

NSString *MWBTr(const char *key) {
    NSArray *pair = MWBTrDict()[[NSString stringWithUTF8String:key]];
    if (![pair isKindOfClass:[NSArray class]] || pair.count < 2)
        return [NSString stringWithUTF8String:key];
    return (MWBPluginLang() == 1) ? pair[1] : pair[0];
}
