/* EMIViews.mm — EMI 视图组件 (纹理集/立方体/图标/格子/分类标签) */
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <ImageIO/ImageIO.h>
#import <objc/runtime.h>
#import "EMI.h"
#import "EMIViews.h"

#pragma mark - 纹理图集加载器


@implementation MWBTextureAtlas

+ (instancetype)terrainAtlas {
    static MWBTextureAtlas *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        inst = [[self alloc] init];
        [inst loadResource:@"terrain-atlas" ext:@"tga" meta:@"terrain.meta"];
    });
    return inst;
}
+ (instancetype)itemsAtlas {
    static MWBTextureAtlas *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        inst = [[self alloc] init];
        [inst loadResource:@"items-opaque" ext:@"png" meta:@"items.meta"];
    });
    return inst;
}

- (void)loadResource:(NSString *)res ext:(NSString *)ext meta:(NSString *)metaName {
    NSURL *url = [[NSBundle mainBundle] URLForResource:res withExtension:ext];
    if (!url) { NSLog(@"[EMI] 找不到贴图 %@.%@", res, ext); return; }
    // 用 ImageIO 加载 (支持 TGA/PNG)
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (src) {
        CGImageRef cg = CGImageSourceCreateImageAtIndex(src, 0, NULL);
        if (cg) {
            _image = [UIImage imageWithCGImage:cg scale:1.0 orientation:UIImageOrientationUp];
            CGImageRelease(cg);
        }
        CFRelease(src);
    }
    if (!_image) { _image = [UIImage imageWithContentsOfFile:url.path]; }
    NSLog(@"[EMI] 加载贴图 %@: %dx%d", res,
          (int)CGImageGetWidth(_image.CGImage), (int)CGImageGetHeight(_image.CGImage));

    // 解析 meta JSON (URL-based API)
    NSURL *metaURL = [[NSBundle mainBundle] URLForResource:metaName withExtension:nil];
    if (!metaURL) {
        NSString *name = [metaName stringByDeletingPathExtension];
        NSString *ext2 = [metaName pathExtension];
        metaURL = [[NSBundle mainBundle] URLForResource:name withExtension:ext2];
    }
    NSError *jsonErr = nil;
    NSData *data = [NSData dataWithContentsOfURL:metaURL options:0 error:&jsonErr];
    if (data) {
        NSArray *arr = [NSJSONSerialization JSONObjectWithData:data options:0 error:&jsonErr];
        if (!jsonErr && [arr isKindOfClass:[NSArray class]]) {
            NSMutableDictionary *dict = [NSMutableDictionary new];
            for (NSDictionary *g in arr) {
                dict[g[@"name"]] = g[@"uvs"];
            }
            _tiles = dict;
            NSLog(@"[EMI] 解析 %@: %lu 个纹理组", metaName, (unsigned long)dict.count);
        } else {
            NSLog(@"[EMI] 解析 %@ 失败: %@", metaName, jsonErr.localizedDescription);
        }
    }
}

- (CGRect)contentsRectForName:(NSString *)name index:(int)idx {
    NSArray *uvs = _tiles[name];
    if (!uvs || idx < 0 || idx >= (int)uvs.count) return (CGRect){{0,0},{1,1}};
    NSArray *uv = uvs[idx];
    CGFloat u0 = [uv[0] floatValue], v0 = [uv[1] floatValue];
    CGFloat u1 = [uv[2] floatValue], v1 = [uv[3] floatValue];
    // CALayer contentsRect: origin 左上角, y 向下; meta UV 原点在左上角
    return (CGRect){{u0,v0},{u1 - u0,v1 - v0}};
}
@end

#pragma mark - 等距立方体 (CALayer 3D 变换贴纹理)

@implementation MWBCubeView {
    CALayer *_top, *_front, *_side;
}
- (instancetype)initWithSize:(CGFloat)size {
    if ((self = [super initWithFrame:(CGRect){{0,0},{size,size}}])) {
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = NO;  // 让触摸穿透到 cell
        _top = [CALayer layer]; _front = [CALayer layer]; _side = [CALayer layer];
        for (CALayer *l in @[_top, _front, _side]) {
            l.bounds = (CGRect){{0,0},{16,16}};
            l.anchorPoint = (CGPoint){0, 0};
            l.contentsGravity = kCAGravityResize;
            l.magnificationFilter = kCAFilterNearest;
            l.minificationFilter = kCAFilterNearest;
            [self.layer addSublayer:l];
        }
        [self applyTransforms];
    }
    return self;
}

- (void)setTopTile:(NSString *)top frontTile:(NSString *)front sideTile:(NSString *)side
          topIndex:(int)ti frontIndex:(int)fi sideIndex:(int)si {
    MWBTextureAtlas *atlas = [MWBTextureAtlas terrainAtlas];
    CGImageRef img = atlas.image.CGImage;
    _top.contents = (__bridge id)img;
    _front.contents = (__bridge id)img;
    _side.contents = (__bridge id)img;
    _top.contentsRect = [atlas contentsRectForName:top index:ti];
    _front.contentsRect = [atlas contentsRectForName:front index:fi];
    _side.contentsRect = [atlas contentsRectForName:side index:si];
}

- (void)applyTransforms {
    CGFloat S = self.bounds.size.width;
    // 参考 CSS 82x82 立方体, 归一化后按 S 缩放
    // top: (0,0)->(.5,.01) (16,0)->(.96,.24) (0,16)->(.04,.25)
    [self setFace:_top a:0.46*S/16 b:0.23*S/16 c:-0.46*S/16 d:0.24*S/16 tx:0.5*S ty:0.01*S];
    // front: (0,0)->(.04,.25) (16,0)->(.5,.49) (0,16)->(.04,.75)
    [self setFace:_front a:0.46*S/16 b:0.24*S/16 c:0 d:0.5*S/16 tx:0.04*S ty:0.25*S];
    // side: (0,0)->(.5,.49) (16,0)->(.96,.24) (0,16)->(.5,.99)
    [self setFace:_side a:0.46*S/16 b:-0.25*S/16 c:0 d:0.5*S/16 tx:0.5*S ty:0.49*S];
}
- (void)setFace:(CALayer *)l a:(CGFloat)a b:(CGFloat)b c:(CGFloat)c d:(CGFloat)d
             tx:(CGFloat)tx ty:(CGFloat)ty {
    CATransform3D t = CATransform3DIdentity;
    t.m11 = a; t.m12 = b; t.m21 = c; t.m22 = d; t.m41 = tx; t.m42 = ty;
    l.transform = t;
}
- (void)layoutSubviews { [super layoutSubviews]; [self applyTransforms]; }
@end

#pragma mark - 平面物品图标 (物品/工具/材料)

@implementation MWBItemIconView {
    CALayer *_iconLayer;
}
- (instancetype)initWithSize:(CGFloat)size {
    if ((self = [super initWithFrame:(CGRect){{0,0},{size,size}}])) {
        self.backgroundColor = [UIColor clearColor];
        self.userInteractionEnabled = NO;  // 让触摸穿透到 cell
        _iconLayer = [CALayer layer];
        _iconLayer.bounds = (CGRect){{0,0},{16,16}};
        _iconLayer.anchorPoint = (CGPoint){0, 0};
        _iconLayer.contentsGravity = kCAGravityResize;
        _iconLayer.magnificationFilter = kCAFilterNearest;
        _iconLayer.minificationFilter = kCAFilterNearest;
        [self.layer addSublayer:_iconLayer];
    }
    return self;
}
- (void)setItemTile:(NSString *)name index:(int)idx {
    MWBTextureAtlas *atlas = [MWBTextureAtlas itemsAtlas];
    _iconLayer.contents = (__bridge id)atlas.image.CGImage;
    _iconLayer.contentsRect = [atlas contentsRectForName:name index:idx];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat S = self.bounds.size.width;
    CGFloat scale = S / 16.0;
    _iconLayer.transform = CATransform3DMakeScale(scale, scale, 1);
}
@end

#pragma mark - 物品格子

@implementation MWBEMICell {
    CALayer *_hlTop, *_hlLeft, *_shBottom, *_shRight;
}
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = EMIColor(0x3a,0x3a,0x39);
        _hlTop = [CALayer layer]; _hlTop.backgroundColor = EMIColor(0x1b,0x1b,0x1a).CGColor;
        _hlLeft = [CALayer layer]; _hlLeft.backgroundColor = EMIColor(0x1b,0x1b,0x1a).CGColor;
        _shBottom = [CALayer layer]; _shBottom.backgroundColor = EMIColor(0x5a,0x59,0x57).CGColor;
        _shRight = [CALayer layer]; _shRight.backgroundColor = EMIColor(0x5a,0x59,0x57).CGColor;
        [self.layer addSublayer:_hlTop]; [self.layer addSublayer:_hlLeft];
        [self.layer addSublayer:_shBottom]; [self.layer addSublayer:_shRight];
        self.userInteractionEnabled = YES;
        UITapGestureRecognizer *single = [[UITapGestureRecognizer alloc]
            initWithTarget:self action:@selector(handleSingle)];
        UITapGestureRecognizer *dbl = [[UITapGestureRecognizer alloc]
            initWithTarget:self action:@selector(handleDouble)];
        dbl.numberOfTapsRequired = 2;
        [single requireGestureRecognizerToFail:dbl];
        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc]
            initWithTarget:self action:@selector(handleLong:)];
        lp.minimumPressDuration = 0.4;
        [self addGestureRecognizer:single]; [self addGestureRecognizer:dbl];
        [self addGestureRecognizer:lp];
    }
    return self;
}
- (void)setContent:(UIView *)content {
    [_content removeFromSuperview]; _content = content;
    [self addSubview:content]; [self setNeedsLayout];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height, b = 8*kEMIScale;
    _hlTop.frame = (CGRect){{0,0},{w,b}}; _hlLeft.frame = (CGRect){{0,0},{b,h}};
    _shBottom.frame = (CGRect){{b,h-7*kEMIScale},{w-b,7*kEMIScale}};
    _shRight.frame = (CGRect){{w-7*kEMIScale,b},{7*kEMIScale,h-b}};
    if (_content) {
        CGFloat cs = 82*kEMIScale*0.78;
        _content.frame = (CGRect){{(w-cs)/2,(h-cs)/2},{cs,cs}};
    }
}
- (void)handleSingle { MWBPlayClick(); if (self.onTap) self.onTap(); }
- (void)handleDouble { MWBPlayClick(); if (self.onDoubleTap) self.onDoubleTap(); }
- (void)handleLong:(UILongPressGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan && self.onLongPress) self.onLongPress();
}
@end

#pragma mark - 分类标签

@implementation MWBEMITab {
    UIView *_icon; CALayer *_inner;
}
- (instancetype)initWithIcon:(UIView *)icon {
    if ((self = [super init])) {
        self.backgroundColor = EMIColor(0xc5,0xbd,0xb6);
        self.layer.borderWidth = 10*kEMIScale;
        self.layer.borderColor = EMIColor(0xc5,0xbd,0xb6).CGColor;
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOffset = (CGSize){8*kEMIScale, 8*kEMIScale};
        self.layer.shadowRadius = 0; self.layer.shadowOpacity = 0.48;
        _inner = [CALayer layer]; _inner.backgroundColor = EMIColor(0xcf,0xc8,0xc1).CGColor;
        [self.layer addSublayer:_inner];
        _icon = icon; [self addSubview:icon];
        [self addTarget:self action:@selector(tabPress) forControlEvents:UIControlEventTouchDown];
        [self addTarget:self action:@selector(tabRelease)
       forControlEvents:UIControlEventTouchUpInside|UIControlEventTouchUpOutside];
    }
    return self;
}
- (void)setActive:(BOOL)active {
    _active = active;
    _inner.backgroundColor = (active ? EMIColor(0xf1,0xeb,0xe5) : EMIColor(0xcf,0xc8,0xc1)).CGColor;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = self.bounds.size.width, h = self.bounds.size.height;
    CGFloat b = 10*kEMIScale, s = 6*kEMIScale;
    _inner.frame = (CGRect){{b,b},{w-2*b,h-2*b}};
    if (!objc_getAssociatedObject(self, "emi_tab_shadow")) {
        CALayer *t=[CALayer layer],*l=[CALayer layer],*bt=[CALayer layer],*r=[CALayer layer];
        t.backgroundColor = EMIColor(0xf1,0xeb,0xe5).CGColor;
        l.backgroundColor = EMIColor(0xf1,0xeb,0xe5).CGColor;
        bt.backgroundColor = EMIColor(0x8e,0x85,0x7e).CGColor;
        r.backgroundColor = EMIColor(0x8e,0x85,0x7e).CGColor;
        [_inner addSublayer:t]; [_inner addSublayer:l];
        [_inner addSublayer:bt]; [_inner addSublayer:r];
        objc_setAssociatedObject(self, "emi_tab_shadow", @[t,l,bt,r], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    NSArray *sh = objc_getAssociatedObject(self, "emi_tab_shadow");
    if (sh.count == 4) {
        CGFloat iw=_inner.bounds.size.width, ih=_inner.bounds.size.height;
        [sh[0] setFrame:(CGRect){{0,0},{iw,s}}]; [sh[1] setFrame:(CGRect){{0,0},{s,ih}}];
        [sh[2] setFrame:(CGRect){{0,ih-s},{iw,s}}]; [sh[3] setFrame:(CGRect){{iw-s,0},{s,ih}}];
    }
    if (_icon) {
        CGFloat iconSize = MIN(w, h)*0.55;
        _icon.frame = (CGRect){{(w-iconSize)/2,(h-iconSize)/2},{iconSize,iconSize}};
    }
}
- (void)tabPress { self.transform = CGAffineTransformMakeTranslation(2*kEMIScale, 2*kEMIScale); }
- (void)tabRelease { self.transform = CGAffineTransformIdentity; }
// 分类标签统一 MC 点击音
- (void)sendAction:(SEL)action to:(id)target forEvent:(UIEvent *)event {
    MWBPlayClick();
    [super sendAction:action to:target forEvent:event];
}
@end
