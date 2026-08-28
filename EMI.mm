#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <ImageIO/ImageIO.h>
#import <objc/runtime.h>
#import "EMI.h"

/* ============================================================
 * EMI 物品管理器 UI (1:1 移植自 Minecraft 创造物品栏参考样式)
 * 纯 UIKit + CALayer, 无 WebView
 * 方块/物品贴图直接从 MCPE app bundle 的 terrain-atlas.tga /
 * items-opaque.png 加载, 不打包任何版权素材
 * ============================================================ */

#pragma mark - 配色

#define EMIColor(r,g,b) [UIColor colorWithRed:(r)/255.0 green:(g)/255.0 blue:(b)/255.0 alpha:1.0]
static CGFloat kEMIScale;

#pragma mark - 纹理图集加载器

@interface MWBTextureAtlas : NSObject
@property (nonatomic, strong) UIImage *image;
@property (nonatomic, strong) NSDictionary<NSString*, NSArray*> *tiles; // name -> @[@{@"u0":..}, ...]
+ (instancetype)terrainAtlas;
+ (instancetype)itemsAtlas;
- (CGRect)contentsRectForName:(NSString *)name index:(int)idx; // 归一化 0-1
@end

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
    NSString *path = [[NSBundle mainBundle] pathForResource:res ofType:ext];
    if (!path) { NSLog(@"[EMI] 找不到贴图 %@.%@", res, ext); return; }
    // 用 ImageIO 加载 (支持 TGA/PNG)
    NSURL *url = [NSURL fileURLWithPath:path];
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (src) {
        CGImageRef cg = CGImageSourceCreateImageAtIndex(src, 0, NULL);
        if (cg) {
            _image = [UIImage imageWithCGImage:cg scale:1.0 orientation:UIImageOrientationUp];
            CGImageRelease(cg);
        }
        CFRelease(src);
    }
    if (!_image) { _image = [UIImage imageWithContentsOfFile:path]; }
    NSLog(@"[EMI] 加载贴图 %@: %dx%d", res,
          (int)CGImageGetWidth(_image.CGImage), (int)CGImageGetHeight(_image.CGImage));

    // 解析 meta JSON
    NSString *metaPath = [[NSBundle mainBundle] pathForResource:metaName ofType:nil];
    if (!metaPath) {
        metaPath = [[NSBundle mainBundle] pathForResource:[metaName stringByDeletingPathExtension]
                                                   ofType:[metaName pathExtension]];
    }
    NSData *data = [NSData dataWithContentsOfFile:metaPath];
    if (data) {
        NSArray *arr = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
        NSMutableDictionary *dict = [NSMutableDictionary dictionary];
        for (NSDictionary *g in arr) {
            dict[g[@"name"]] = g[@"uvs"];
        }
        _tiles = dict;
        NSLog(@"[EMI] 解析 %@: %lu 个纹理组", metaName, (unsigned long)dict.count);
    }
}

- (CGRect)contentsRectForName:(NSString *)name index:(int)idx {
    NSArray *uvs = _tiles[name];
    if (!uvs || idx < 0 || idx >= (int)uvs.count) return CGRectMake(0, 0, 1, 1);
    NSArray *uv = uvs[idx];
    CGFloat u0 = [uv[0] floatValue], v0 = [uv[1] floatValue];
    CGFloat u1 = [uv[2] floatValue], v1 = [uv[3] floatValue];
    // CALayer contentsRect: origin 左上角, y 向下; meta UV 原点在左上角
    return CGRectMake(u0, v0, u1 - u0, v1 - v0);
}
@end

#pragma mark - 等距立方体 (CALayer 3D 变换贴纹理)

@interface MWBCubeView : UIView
- (void)setTopTile:(NSString *)top frontTile:(NSString *)front sideTile:(NSString *)side
          topIndex:(int)ti frontIndex:(int)fi sideIndex:(int)si;
@end
@implementation MWBCubeView {
    CALayer *_top, *_front, *_side;
}
- (instancetype)initWithSize:(CGFloat)size {
    if ((self = [super initWithFrame:CGRectMake(0, 0, size, size)])) {
        self.backgroundColor = [UIColor clearColor];
        _top = [CALayer layer]; _front = [CALayer layer]; _side = [CALayer layer];
        for (CALayer *l in @[_top, _front, _side]) {
            l.bounds = CGRectMake(0, 0, 16, 16);
            l.anchorPoint = CGPointMake(0, 0);
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

@interface MWBItemIconView : UIView
- (void)setItemTile:(NSString *)name index:(int)idx;
@end
@implementation MWBItemIconView {
    CALayer *_iconLayer;
}
- (instancetype)initWithSize:(CGFloat)size {
    if ((self = [super initWithFrame:CGRectMake(0, 0, size, size)])) {
        self.backgroundColor = [UIColor clearColor];
        _iconLayer = [CALayer layer];
        _iconLayer.bounds = CGRectMake(0, 0, 16, 16);
        _iconLayer.anchorPoint = CGPointMake(0, 0);
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

@interface MWBEMICell : UIView
@property (nonatomic, strong) UIView *content;
@property (nonatomic, copy) void (^onTap)(void);
@property (nonatomic, copy) void (^onDoubleTap)(void);
@property (nonatomic, copy) void (^onLongPress)(void);
@end
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
    _hlTop.frame = CGRectMake(0, 0, w, b); _hlLeft.frame = CGRectMake(0, 0, b, h);
    _shBottom.frame = CGRectMake(b, h-7*kEMIScale, w-b, 7*kEMIScale);
    _shRight.frame = CGRectMake(w-7*kEMIScale, b, 7*kEMIScale, h-b);
    if (_content) {
        CGFloat cs = 82*kEMIScale*0.78;
        _content.frame = CGRectMake((w-cs)/2, (h-cs)/2, cs, cs);
    }
}
- (void)handleSingle { if (self.onTap) self.onTap(); }
- (void)handleDouble { if (self.onDoubleTap) self.onDoubleTap(); }
- (void)handleLong:(UILongPressGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan && self.onLongPress) self.onLongPress();
}
@end

#pragma mark - 分类标签

@interface MWBEMITab : UIControl
@property (nonatomic, getter=isActive) BOOL active;
- (instancetype)initWithIcon:(UIView *)icon;
@end
@implementation MWBEMITab {
    UIView *_icon; CALayer *_inner;
}
- (instancetype)initWithIcon:(UIView *)icon {
    if ((self = [super init])) {
        self.backgroundColor = EMIColor(0xc5,0xbd,0xb6);
        self.layer.borderWidth = 10*kEMIScale;
        self.layer.borderColor = EMIColor(0xc5,0xbd,0xb6).CGColor;
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOffset = CGSizeMake(8*kEMIScale, 8*kEMIScale);
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
    _inner.frame = CGRectMake(b, b, w-2*b, h-2*b);
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
        [sh[0] setFrame:CGRectMake(0,0,iw,s)]; [sh[1] setFrame:CGRectMake(0,0,s,ih)];
        [sh[2] setFrame:CGRectMake(0,ih-s,iw,s)]; [sh[3] setFrame:CGRectMake(iw-s,0,s,ih)];
    }
    if (_icon) {
        CGFloat iconSize = MIN(w, h)*0.55;
        _icon.frame = CGRectMake((w-iconSize)/2, (h-iconSize)/2, iconSize, iconSize);
    }
}
- (void)tabPress { self.transform = CGAffineTransformMakeTranslation(2*kEMIScale, 2*kEMIScale); }
- (void)tabRelease { self.transform = CGAffineTransformIdentity; }
@end

#pragma mark - 物品数据

// 物品定义
typedef struct {
    const char *cnName;     // 中文名
    BOOL isBlock;           // YES=方块(立方体) NO=物品(平面图标)
    const char *tile;       // terrain 组名(方块) 或 items 组名(物品)
    int idx;                // tile 索引
    // 方块三面 (若与 tile/idx 相同则填 NULL/-1)
    const char *topTile; int topIdx;
    const char *frontTile; int frontIdx;
    const char *sideTile; int sideIdx;
    int maxStack;           // 最大堆叠
    int category;           // 0=全部 1=装备 2=配方 3=建筑
} MWBItemDef;

// 材质索引: 0木 1石 2铁 3钻石 4金
#define B(nm,cn,tp,ti,tt,ti2,ft,fi2,st,si2,stk,cat) \
    {(cn), YES, (tp), (ti), (tt), (ti2), (ft), (fi2), (st), (si2), (stk), (cat)}
#define I(nm,cn,tp,ti,stk,cat) \
    {(cn), NO, (tp), (ti), NULL, 0, NULL, 0, NULL, 0, (stk), (cat)}

static MWBItemDef gItems[] = {
    // ---- 建筑方块 (category 3) ----
    B(stone,       "石头",     "stone",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(grass,       "草方块",   "grass",0, "grass",0, "grass",1, "dirt",0, 64, 3),
    B(dirt,        "泥土",     "dirt",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(cobble,      "圆石",     "cobblestone",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(planks,      "橡木木板", "planks",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(sapling,     "橡树树苗", "sapling",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(bedrock,     "基岩",     "bedrock",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(sand,        "沙子",     "sand",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(gravel,      "沙砾",     "gravel",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(gold_ore,    "金矿石",   "gold_ore",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(iron_ore,    "铁矿石",   "iron_ore",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(coal_ore,    "煤矿石",   "coal_ore",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(log,         "橡木原木", "log",0, "log",4, "log",0, "log",0, 64, 3),
    B(leaves,      "橡树树叶", "leaves",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(glass,       "玻璃",     "glass",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(lapis_ore,   "青金石矿石","lapis_ore",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(lapis_block, "青金石块", "lapis_block",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(sandstone,   "砂岩",     "sandstone",0, "sandstone",0, "sandstone",2, "sandstone",2, 64, 3),
    B(wool_white,  "白色羊毛", "wool",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(gold_block,  "金块",     "gold_block",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(iron_block,  "铁块",     "iron_block",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(stone_slab,  "石台阶",   "stone_slab",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(brick,       "砖块",     "brick",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(tnt,         "TNT",      "tnt",0, "tnt",1, "tnt",0, "tnt",2, 64, 3),
    B(bookshelf,   "书架",     "bookshelf",0, "planks",0, "bookshelf",0, "planks",0, 64, 3),
    B(mossy,       "苔石",     "cobblestone_mossy",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(obsidian,    "黑曜石",   "obsidian",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(diamond_ore, "钻石矿石", "diamond_ore",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(diamond_blk, "钻石块",   "diamond_block",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(crafting,    "工作台",   "crafting_table",0, "crafting_table",1, "crafting_table",0, "crafting_table",2, 64, 3),
    B(furnace,     "熔炉",     "furnace",0, "furnace",2, "furnace",0, "furnace",1, 64, 3),
    B(ice,         "冰",       "ice",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(snow,        "雪块",     "snow",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(clay,        "黏土块",   "clay",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(pumpkin,     "南瓜",     "pumpkin",0, "pumpkin",1, "pumpkin",0, "pumpkin",2, 64, 3),
    B(netherrack,  "地狱岩",   "netherrack",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(soul_sand,   "灵魂沙",   "soul_sand",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(glowstone,   "萤石",     "glowstone",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(coal_block,  "煤炭块",   "coal_block",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(emerald_ore, "绿宝石矿石","emerald_ore",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(emerald_blk, "绿宝石块", "emerald_block",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(redstone_ore,"红石矿石", "redstone_ore",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(redstone_blk,"红石块",   "redstone_block",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(stonebrick,  "石砖",     "stonebrick",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(melon,       "西瓜",     "melon",0, "melon",0, "melon",1, "melon",1, 64, 3),
    B(mycelium,    "菌丝",     "mycelium",0, "mycelium",1, "mycelium",0, "dirt",0, 64, 3),
    B(end_stone,   "末地石",   "end_stone",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(quartz_blk,  "石英块",   "quartz_block",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(hay,         "干草块",   "hayblock",0, "hayblock",0, "hayblock",1, "hayblock",1, 64, 3),
    B(hardened_clay,"硬化黏土","hardened_clay",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(sponge,      "海绵",     "sponge",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(glass_pane,  "玻璃板",   "glass_pane_top",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(iron_bars,   "铁栏杆",   "iron_bars",0, NULL,0, NULL,0, NULL,0, 64, 3),

    // ---- 装备/工具 (category 1) ----
    I(sword_w,  "木剑",   "sword",0, 1, 1),
    I(sword_s,  "石剑",   "sword",1, 1, 1),
    I(sword_i,  "铁剑",   "sword",2, 1, 1),
    I(sword_d,  "钻石剑", "sword",3, 1, 1),
    I(sword_g,  "金剑",   "sword",4, 1, 1),
    I(pick_w,   "木镐",   "pickaxe",0, 1, 1),
    I(pick_s,   "石镐",   "pickaxe",1, 1, 1),
    I(pick_i,   "铁镐",   "pickaxe",2, 1, 1),
    I(pick_d,   "钻石镐", "pickaxe",3, 1, 1),
    I(pick_g,   "金镐",   "pickaxe",4, 1, 1),
    I(axe_w,    "木斧",   "axe",0, 1, 1),
    I(axe_s,    "石斧",   "axe",1, 1, 1),
    I(axe_i,    "铁斧",   "axe",2, 1, 1),
    I(axe_d,    "钻石斧", "axe",3, 1, 1),
    I(shovel_w, "木铲",   "shovel",0, 1, 1),
    I(shovel_i, "铁铲",   "shovel",2, 1, 1),
    I(shovel_d, "钻石铲", "shovel",3, 1, 1),
    I(bow,      "弓",     "bow_standby",0, 1, 1),
    I(arrow,    "箭",     "arrow",0, 64, 1),
    I(helmet_i, "铁头盔", "helmet",2, 1, 1),
    I(chest_i,  "铁胸甲", "chestplate",2, 1, 1),
    I(legs_i,   "铁护腿", "leggings",2, 1, 1),
    I(boots_i,  "铁靴子", "boots",2, 1, 1),
    I(helmet_d, "钻石头盔","helmet",3, 1, 1),
    I(chest_d,  "钻石胸甲","chestplate",3, 1, 1),
    I(flint,    "打火石", "flint_and_steel",0, 1, 1),
    I(shears,   "剪刀",   "shears",0, 1, 1),
    I(fishrod,  "钓鱼竿", "fishing_rod_uncast",0, 1, 1),
    I(shield_x, "盾牌",   "bowl",0, 1, 1), // 0.10 无盾牌, 占位

    // ---- 材料/物品 (category 0) ----
    I(stick,        "木棍",       "stick",0, 64, 0),
    I(coal,         "煤炭",       "coal",0, 64, 0),
    I(charcoal,     "木炭",       "charcoal",0, 64, 0),
    I(diamond,      "钻石",       "diamond",0, 64, 0),
    I(iron_ingot,   "铁锭",       "iron_ingot",0, 64, 0),
    I(gold_ingot,   "金锭",       "gold_ingot",0, 64, 0),
    I(emerald,      "绿宝石",     "emerald",0, 64, 0),
    I(redstone,     "红石粉",     "redstone_dust",0, 64, 0),
    I(quartz,       "下界石英",   "quartz",0, 64, 0),
    I(clay_ball,    "黏土球",     "clay_ball",0, 64, 0),
    I(brick_item,   "红砖",       "brick",0, 64, 0),
    I(netherbrick,  "地狱砖",     "netherbrick",0, 64, 0),
    I(flint_item,   "燧石",       "flint",0, 64, 0),
    I(string,       "线",         "string",0, 64, 0),
    I(leather,      "皮革",       "leather",0, 64, 0),
    I(feather,      "羽毛",       "feather",0, 64, 0),
    I(bone,         "骨头",       "bone",0, 64, 0),
    I(slimeball,    "黏液球",     "slimeball",0, 64, 0),
    I(egg,          "鸡蛋",       "egg",0, 16, 0),
    I(snowball,     "雪球",       "snowball",0, 16, 0),
    I(gunpowder,    "火药",       "gunpowder",0, 64, 0),
    I(glowdust,     "萤石粉",     "glowstone_dust",0, 64, 0),
    I(blaze_rod,    "烈焰棒",     "blaze_rod",0, 64, 0),
    I(blaze_powder, "烈焰粉",     "blaze_powder",0, 64, 0),
    I(ender_pearl,  "末影珍珠",   "ender_pearl",0, 16, 0),
    I(ender_eye,    "末影之眼",   "ender_eye",0, 64, 0),
    I(magma_cream,  "岩浆膏",     "magma_cream",0, 64, 0),
    I(ghast_tear,   "恶魂之泪",   "ghast_tear",0, 64, 0),
    I(sugar,        "糖",         "sugar",0, 64, 0),
    I(nether_wart,  "地狱疣",     "nether_wart",0, 64, 0),
    I(wheat,        "小麦",       "wheat",0, 64, 0),
    I(seeds,        "小麦种子",   "seeds_wheat",0, 64, 0),
    I(apple,        "苹果",       "apple",0, 64, 0),
    I(gold_apple,   "金苹果",     "apple_golden",0, 64, 0),
    I(bread,        "面包",       "bread",0, 64, 0),
    I(cookie,       "饼干",       "cookie",0, 64, 0),
    I(cake,         "蛋糕",       "cake",0, 1, 0),
    I(melon_item,   "西瓜片",     "melon",0, 64, 0),
    I(carrot,       "胡萝卜",     "carrot",0, 64, 0),
    I(potato,       "马铃薯",     "potato",0, 64, 0),
    I(baked_potato, "烤马铃薯",   "potato_baked",0, 64, 0),
    I(beef_raw,     "生牛肉",     "beef_raw",0, 64, 0),
    I(beef_cooked,  "牛排",       "beef_cooked",0, 64, 0),
    I(pork_raw,     "生猪排",     "porkchop_raw",0, 64, 0),
    I(pork_cooked,  "熟猪排",     "porkchop_cooked",0, 64, 0),
    I(chicken_raw,  "生鸡肉",     "chicken_raw",0, 64, 0),
    I(chicken_ckd,  "熟鸡肉",     "chicken_cooked",0, 64, 0),
    I(bucket,       "桶",         "bucket",0, 1, 0),
    I(bucket_water, "水桶",       "bucket",1, 1, 0),
    I(bucket_lava,  "熔岩桶",     "bucket",2, 1, 0),
    I(book,         "书",         "book_normal",0, 64, 0),
    I(paper,        "纸",         "paper",0, 64, 0),
    I(map,          "地图",       "map_empty",0, 64, 0),
    I(compass,      "指南针",     "compass_item",0, 64, 0),
    I(clock,        "钟",         "clock_item",0, 64, 0),
    I(bowl,         "碗",         "bowl",0, 64, 0),
    I(mushroom_stew,"蘑菇煲",     "mushroom_stew",0, 1, 0),
    I(saddle,       "鞍",         "saddle",0, 1, 0),
    I(boat,         "船",         "boat",0, 1, 0),
    I(minecart,     "矿车",       "minecart_normal",0, 1, 0),
    I(bed,          "床",         "bed",0, 1, 0),
    I(reeds,        "甘蔗",       "reeds",0, 64, 0),
    I(rotten_flesh, "腐肉",       "rotten_flesh",0, 64, 0),
    I(spider_eye,   "蜘蛛眼",     "spider_eye",0, 64, 0),
    I(bottle,       "玻璃瓶",     "potion_bottle_empty",0, 64, 0),
    I(potion,       "药水",       "potion_bottle_drinkable",0, 1, 0),
    I(skull,        "骷髅头颅",   "skull_skeleton",0, 64, 0),
    I(record_cat,   "唱片 Cat",   "record_cat",0, 1, 0),
    I(book_ench,    "附魔书",     "book_enchanted",0, 1, 0),
};
static int gItemCount = sizeof(gItems) / sizeof(gItems[0]);

#pragma mark - EMI 主窗口

@interface MWBEMIWindow : UIView
@property (nonatomic, copy) void (^onClose)(void);
@end
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

- (void)buildWindow {
    CGFloat s = kEMIScale;
    CGFloat winW = 1879*s, winH = 923*s;
    CGFloat winX = (self.bounds.size.width-winW)/2;
    CGFloat winY = (self.bounds.size.height-winH-139*s)/2;
    _window = [[UIView alloc] initWithFrame:CGRectMake(winX, winY, winW, winH)];
    _window.backgroundColor = EMIColor(0xc8,0xc0,0xb8);
    _window.layer.borderWidth = 10*s;
    _window.layer.borderColor = EMIColor(0x9c,0x91,0x89).CGColor;
    _window.layer.shadowColor = [UIColor blackColor].CGColor;
    _window.layer.shadowOffset = CGSizeMake(8*s, 8*s);
    _window.layer.shadowRadius = 0; _window.layer.shadowOpacity = 0.28;
    [self addSubview:_window];
    [self addInsetShadow:_window light:EMIColor(0xe7,0xe0,0xda) dark:EMIColor(0x7f,0x77,0x70)
                   lightW:8 darkW:9];

    _rail = [[UIView alloc] initWithFrame:CGRectMake(6*s, 20*s, 165*s, 878*s)];
    [_window addSubview:_rail];

    UIControl *closeBtn = [self makeCloseButton];
    closeBtn.frame = CGRectMake(24*s, 0, 132*s, 120*s);
    [closeBtn addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];
    [_rail addSubview:closeBtn];

    NSArray *icons = @[[self makeSaplingIcon],[self makeSwordIcon],
                       [self makeBookshelfIcon],[self makeBrickCubeIcon]];
    NSMutableArray *tabs = [NSMutableArray array];
    CGFloat tabY[] = {156, 336, 516, 696};
    for (int i = 0; i < 4; i++) {
        MWBEMITab *tab = [[MWBEMITab alloc] initWithIcon:icons[i]];
        tab.frame = CGRectMake(0, tabY[i]*s, 165*s, 166*s);
        tab.tag = i; tab.active = (i == 0);
        [tab addTarget:self action:@selector(switchTab:) forControlEvents:UIControlEventTouchUpInside];
        [_rail addSubview:tab]; [tabs addObject:tab];
    }
    _tabs = tabs;

    _gridWrap = [[UIView alloc] initWithFrame:CGRectMake(233*s, 37*s, 1590*s, 873*s)];
    _gridWrap.backgroundColor = EMIColor(0x1a,0x1a,0x19);
    _gridWrap.layer.borderWidth = 8*s;
    _gridWrap.layer.borderColor = EMIColor(0x17,0x17,0x16).CGColor;
    [_window addSubview:_gridWrap];

    _gridScroll = [[UIScrollView alloc] initWithFrame:_gridWrap.bounds];
    _gridScroll.tag = 999;
    _gridScroll.autoresizingMask = UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    _gridScroll.backgroundColor = [UIColor clearColor];
    _gridScroll.showsVerticalScrollIndicator = NO;
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
    t.frame = CGRectMake(o,o,w-2*o,lw*s); l.frame = CGRectMake(o,o,lw*s,h-2*o);
    b.frame = CGRectMake(o,h-o-dw*s,w-2*o,dw*s); r.frame = CGRectMake(w-o-dw*s,o,dw*s,h-2*o);
}

- (UIControl *)makeCloseButton {
    UIControl *btn = [[UIControl alloc] init];
    btn.backgroundColor = EMIColor(0xc5,0xbd,0xb6);
    btn.layer.borderWidth = 10*kEMIScale;
    btn.layer.borderColor = EMIColor(0xc5,0xbd,0xb6).CGColor;
    btn.layer.shadowColor = [UIColor blackColor].CGColor;
    btn.layer.shadowOffset = CGSizeMake(8*kEMIScale, 8*kEMIScale);
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
        it.frame = CGRectMake(0,0,iw,sh); il.frame = CGRectMake(0,0,sh,ih);
        ib.frame = CGRectMake(0,ih-sh,iw,sh); ir.frame = CGRectMake(iw-sh,0,sh,ih);
        UIView *x1 = [inner viewWithTag:2], *x2 = [inner viewWithTag:3];
        CGFloat xw = 60*s, xh = 19*s;
        x1.frame = CGRectMake((iw-xw)/2,(ih-xh)/2,xw,xh);
        x2.frame = CGRectMake((iw-xw)/2,(ih-xh)/2,xw,xh);
        x1.transform = CGAffineTransformMakeRotation(M_PI_4);
        x2.transform = CGAffineTransformMakeRotation(-M_PI_4);
    }
}

#pragma mark - 分类图标

- (UIView *)makeSaplingIcon {
    UIView *v = [[UIView alloc] init]; v.backgroundColor = [UIColor clearColor];
    CGFloat s = kEMIScale, sz = 78*s;
    v.bounds = CGRectMake(0,0,sz,sz);
    UIView *trunk = [[UIView alloc] initWithFrame:CGRectMake(sz*0.42,sz*0.65,sz*0.12,sz*0.3)];
    trunk.backgroundColor = EMIColor(0x6b,0x3b,0x12);
    UIView *leaves = [[UIView alloc] initWithFrame:CGRectMake(sz*0.15,sz*0.1,sz*0.7,sz*0.6)];
    leaves.backgroundColor = EMIColor(0x2c,0x76,0x07);
    [v addSubview:trunk]; [v addSubview:leaves];
    return v;
}
- (UIView *)makeSwordIcon {
    UIView *v = [[UIView alloc] init]; v.backgroundColor = [UIColor clearColor];
    CGFloat s = kEMIScale, sz = 92*s;
    v.bounds = CGRectMake(0,0,sz,sz);
    UIView *blade = [[UIView alloc] initWithFrame:CGRectMake(sz*0.42,sz*0.02,sz*0.18,sz*0.7)];
    blade.backgroundColor = EMIColor(0xc2,0xcb,0xce);
    blade.layer.borderWidth = 4*s; blade.layer.borderColor = EMIColor(0x2f,0x34,0x34).CGColor;
    UIView *guard = [[UIView alloc] initWithFrame:CGRectMake(sz*0.22,sz*0.68,sz*0.6,sz*0.13)];
    guard.backgroundColor = EMIColor(0x5d,0x44,0x2d);
    guard.layer.borderWidth = 4*s; guard.layer.borderColor = EMIColor(0x2a,0x21,0x18).CGColor;
    UIView *handle = [[UIView alloc] initWithFrame:CGRectMake(sz*0.45,sz*0.78,sz*0.15,sz*0.27)];
    handle.backgroundColor = EMIColor(0x5e,0x44,0x2f);
    handle.layer.borderWidth = 4*s; handle.layer.borderColor = EMIColor(0x2a,0x21,0x18).CGColor;
    [v addSubview:blade]; [v addSubview:guard]; [v addSubview:handle];
    v.transform = CGAffineTransformMakeRotation(-M_PI_4*0.97);
    return v;
}
- (UIView *)makeBookshelfIcon {
    UIView *v = [[UIView alloc] init]; v.backgroundColor = [UIColor clearColor];
    CGFloat s = kEMIScale, sz = 80*s;
    v.bounds = CGRectMake(0,0,sz,sz);
    UIView *front = [[UIView alloc] initWithFrame:CGRectMake(sz*0.12,sz*0.25,sz*0.72,sz*0.6)];
    front.backgroundColor = EMIColor(0x5e,0x3b,0x20);
    front.layer.borderWidth = 5*s; front.layer.borderColor = EMIColor(0x3b,0x24,0x12).CGColor;
    NSArray *colors = @[EMIColor(0x1b,0x68,0x2f),EMIColor(0x5d,0x2b,0x5e),
                        EMIColor(0x6a,0x25,0x25),EMIColor(0x19,0x3d,0x6c),EMIColor(0xb7,0x9b,0x32)];
    CGFloat bookW = front.bounds.size.width / colors.count;
    for (int i = 0; i < (int)colors.count; i++) {
        UIView *book = [[UIView alloc] initWithFrame:CGRectMake(i*bookW+3*s,3*s,bookW-6*s,front.bounds.size.height-6*s)];
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

    CGFloat s = kEMIScale;
    CGFloat cellSize = 159*s;
    int cols = 10;
    NSMutableArray *visible = [NSMutableArray array];
    for (int i = 0; i < gItemCount; i++) {
        if (_currentCategory == 0 || gItems[i].category == _currentCategory)
            [visible addObject:@(i)];
    }
    int rows = ((int)visible.count + cols - 1) / cols;
    _gridScroll.contentSize = CGSizeMake(cols*cellSize, rows*cellSize);

    for (int i = 0; i < (int)visible.count; i++) {
        int defIdx = [visible[i] intValue];
        MWBItemDef def = gItems[defIdx];
        int r = i/cols, c = i%cols;
        MWBEMICell *cell = [[MWBEMICell alloc] initWithFrame:CGRectMake(c*cellSize, r*cellSize, cellSize, cellSize)];
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
        cell.onTap = ^{ NSLog(@"[EMI] 单击 %@ (给予1个)", cn); };
        cell.onDoubleTap = ^{ NSLog(@"[EMI] 双击 %@ (给予%ld个)", cn, (long)stack); };
        cell.onLongPress = ^{ NSLog(@"[EMI] 长按 %@ (查看合成)", cn); };
        [_gridScroll addSubview:cell];
    }
}

#pragma mark - 底部快捷栏

- (void)buildHotbar {
    CGFloat s = kEMIScale;
    CGFloat hbW = 1092*s, hbH = 139*s;
    CGFloat hbX = _window.frame.origin.x + 417*s;
    CGFloat hbY = _window.frame.origin.y + 941*s;
    _hotbar = [[UIView alloc] initWithFrame:CGRectMake(hbX, hbY, hbW, hbH)];
    _hotbar.backgroundColor = EMIColor(0xd7,0xde,0xd7);
    _hotbar.layer.borderWidth = 8*s;
    _hotbar.layer.borderColor = EMIColor(0x11,0x11,0x11).CGColor;
    [self addSubview:_hotbar];
    [self addInsetShadow:_hotbar light:EMIColor(0xee,0xf6,0xef) dark:EMIColor(0x69,0x71,0x6b)
                   lightW:6 darkW:6];
    int slots = 9; CGFloat pad = 8*s;
    CGFloat slotW = (hbW-pad*2)/slots, slotH = hbH-pad*2;
    for (int i = 0; i < slots; i++) {
        UIView *slot = [[UIView alloc] initWithFrame:CGRectMake(pad+i*slotW, pad, slotW, slotH)];
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
        st.frame = CGRectMake(0,0,sw,sh); sl.frame = CGRectMake(0,0,sh,sh2);
        sb.frame = CGRectMake(0,sh2-sh,sw,sh); sr.frame = CGRectMake(sw-sh,0,sh,sh2);
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
@end

#pragma mark - EMI 悬浮按钮

@interface MWBEMIFloatButton : UIView
@property (nonatomic, copy) void (^onTap)(void);
@end
@implementation MWBEMIFloatButton
- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = EMIColor(0x41,0x50,0x2f);
        self.layer.borderWidth = 4;
        self.layer.borderColor = EMIColor(0x27,0x2b,0x22).CGColor;
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOffset = CGSizeMake(5, 5);
        self.layer.shadowRadius = 0; self.layer.shadowOpacity = 0.55;
        UILabel *icon = [[UILabel alloc] init];
        icon.text = @"E"; icon.textColor = EMIColor(0xdf,0xc5,0x5b);
        icon.font = [UIFont boldSystemFontOfSize:26];
        icon.textAlignment = NSTextAlignmentCenter; icon.tag = 1;
        [self addSubview:icon];
        self.userInteractionEnabled = YES;
        [self addGestureRecognizer:[[UITapGestureRecognizer alloc]
            initWithTarget:self action:@selector(tap)]];
        UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc]
            initWithTarget:self action:@selector(pan:)];
        [self addGestureRecognizer:pan];
    }
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    UIView *icon = [self viewWithTag:1]; icon.frame = self.bounds;
}
- (void)tap { if (self.onTap) self.onTap(); }
- (void)pan:(UIPanGestureRecognizer *)g {
    CGPoint t = [g translationInView:self.superview];
    CGPoint c = self.center; c.x += t.x; c.y += t.y;
    CGFloat w=self.bounds.size.width/2, h=self.bounds.size.height/2;
    c.x = MAX(w, MIN(self.superview.bounds.size.width-w, c.x));
    c.y = MAX(h+20, MIN(self.superview.bounds.size.height-h, c.y));
    self.center = c; [g setTranslation:CGPointZero inView:self.superview];
}
@end

#pragma mark - EMI 透传窗口

@interface EMIOverlayWindow : UIWindow
@end
@implementation EMIOverlayWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    if (hit == self || hit == self.rootViewController.view) return nil;
    return hit;
}
@end

#pragma mark - EMI 管理器

@implementation MWBEMIManager {
    EMIOverlayWindow *_emiWindow;
    MWBEMIFloatButton *_floatBtn;
    MWBEMIWindow *_window;
}
+ (instancetype)shared {
    static MWBEMIManager *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[self alloc] init]; });
    return inst;
}
+ (void)install {
    dispatch_async(dispatch_get_main_queue(), ^{ [[self shared] setup]; });
}
// 调试用: cycript 调用 [MWBEMIManager scrollDebug:[NSNumber numberWithFloat:950]]
+ (void)scrollDebug:(NSNumber *)y {
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            UIView *sv = [w viewWithTag:999];
            if ([sv isKindOfClass:[UIScrollView class]]) {
                [(UIScrollView *)sv setContentOffset:CGPointMake(0, y.floatValue) animated:NO];
            }
        }
    });
}
- (void)setup {
    if (_emiWindow) return;
    CGSize ss = [UIScreen mainScreen].bounds.size;
    kEMIScale = MIN(ss.width/1920.0, ss.height/1080.0);
    // 预加载贴图
    [MWBTextureAtlas terrainAtlas];
    [MWBTextureAtlas itemsAtlas];

    _emiWindow = [[EMIOverlayWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    _emiWindow.windowLevel = UIWindowLevelAlert + 101;
    _emiWindow.backgroundColor = [UIColor clearColor];
    _emiWindow.rootViewController = [[UIViewController alloc] init];
    _emiWindow.rootViewController.view.backgroundColor = [UIColor clearColor];
    _emiWindow.hidden = NO;

    _floatBtn = [[MWBEMIFloatButton alloc] initWithFrame:CGRectMake(12, 300, 52, 52)];
    _floatBtn.autoresizingMask = UIViewAutoresizingFlexibleRightMargin;
    __weak typeof(self) ws = self;
    _floatBtn.onTap = ^{ [ws toggle]; };
    [_emiWindow addSubview:_floatBtn];
    NSLog(@"[EMI] 悬浮按钮已安装, scale=%.3f, 物品数=%d", kEMIScale, gItemCount);
}
- (void)toggle {
    typeof(self) ss = self;
    if (_window.superview) {
        [_window hide]; _floatBtn.hidden = NO;
        [UIView animateWithDuration:0.15 animations:^{ ss->_floatBtn.alpha = 1; }];
    } else {
        _window = [[MWBEMIWindow alloc] initWithFrame:_emiWindow.bounds];
        _window.autoresizingMask = UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
        __weak typeof(self) ws = self;
        _window.onClose = ^{
            __strong typeof(ws) s = ws; if (!s) return;
            s->_floatBtn.hidden = NO;
            [UIView animateWithDuration:0.15 animations:^{ s->_floatBtn.alpha = 1; }];
        };
        [_window showInView:_emiWindow];
        [UIView animateWithDuration:0.15 animations:^{ ss->_floatBtn.alpha = 0; }
                         completion:^(BOOL f){ ss->_floatBtn.hidden = YES; }];
    }
}
@end
