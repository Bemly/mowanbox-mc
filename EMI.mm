#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <ImageIO/ImageIO.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <substrate.h>
#import <string.h>
#import "EMI.h"

/* ============================================================
 * 物品给予功能 (C++ hook MCPE 0.10.0)
 *
 * 逆向结果 (2026-08-28 经符号表+反汇编核实):
 * - LocalPlayer 指针由 Tweak.xm 的 normalTick hook 维护
 * - Player+0x1708 = Inventory*
 * - 物品注册表 = 游戏静态数组 Item::items (Item* items[512]),
 *   符号 __ZN4Item5itemsE, 用 MSFindSymbol 运行时解析,
 *   不再硬编码地址 (旧硬编码 0x10034cd00 实为 __MergedGlobals 常量池, 是错的)
 * - Inventory::add(ItemInstance*) 符号 __ZN9Inventory3addEP12ItemInstance,
 *   直接调用 (旧 vtable+0x148 槽位不是 add, 是错的)
 * - ItemInstance 布局 (FillingContainer::add 反汇编确认):
 *   id@0x00(int) count@0x04(int) Item*@0x08(ptr) valid@0x18(byte)
 *   注意 valid 必须在 0x18, 旧结构体因对齐把它排到了 0x20 导致永远被拒
 * ============================================================ */

// ItemInstance 结构 (0.10 真实布局, 0x20 字节; 这里多留 0x20 清零保险区)
// 没有独立 id 字段! 物品种类由 +0x08 的 Item* 决定:
//   +0x00 count 数量
//   +0x04 aux  辅助值: 工具=剩余耐久 / 染料羊毛=颜色 / 其他=变种号 (0=新物品)
//   +0x08 item Item 指针
//   +0x10 info 每物品静态信息指针 (全局表 0x100353790[id], 游戏自己的实例都有值)
//   +0x18 valid 有效标志
// (2026-08-28 实测教训: 把 id 写到 +0x00 会给出 id 个物品; aux 写成 1 会让
//  工具耐久变 1、钻石无法放进钻石块配方)
struct MWBItemInstance {
    int count;          // 0x00
    int aux;            // 0x04
    void *item;         // 0x08
    void *info;         // 0x10
    uint8_t valid;      // 0x18
    uint8_t pad[7];     // 0x19..0x1F
    uint8_t pad2[0x20]; // 0x20..0x3F 保险清零区
};

// 每物品静态信息表 (配方可拷贝循环写入实例 +0x10 处的同一张表)
#define MWB_ITEM_INFO_TABLE_VMADDR 0x100353790UL

static uintptr_t gSlide = 0;                 // ASLR slide
// 调试模式开关 (由 Toolbox 面板控制)
BOOL gMWBDebug = NO;

// 调试日志: 同时输出 NSLog 和写文件 (设备上 /var/mobile/Documents/mowanbox.log)
static void MWBDLog(NSString *fmt, ...) {
    va_list args; va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"%@ %@\n",
                      [NSDate date], msg];
    NSLog(@"%@", msg);
    // 追加写文件 (URL-based API, iOS 12 推荐)
    NSURL *logURL = [NSURL fileURLWithPath:@"/var/mobile/Documents/mowanbox.log"];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingToURL:logURL error:nil];
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } else {
        NSError *writeErr = nil;
        [line writeToURL:logURL atomically:YES encoding:NSUTF8StringEncoding error:&writeErr];
        if (writeErr) NSLog(@"[EMI] 日志写入失败: %@", writeErr.localizedDescription);
    }
}

// LocalPlayer::normalTick
// 注意: LocalPlayer::normalTick 已在 Tweak.xm 中 hook, gLocalPlayer 由那里维护
// EMI 不需要重复 hook, 直接使用 gLocalPlayer 即可

// 获取 minecraftpe 主二进制的 ASLR slide
// 注意: 不能用 image 0, Substrate 注入后 image 0 可能是其他 dylib
static uintptr_t mwb_slide() {
    if (!gSlide) {
        for (uint32_t i = 0; i < _dyld_image_count(); i++) {
            const char *name = _dyld_get_image_name(i);
            if (name && strstr(name, "minecraftpe.app/minecraftpe")) {
                gSlide = _dyld_get_image_vmaddr_slide(i);
                break;
            }
        }
        if (!gSlide) {
            // 兜底: 用 image 0
            gSlide = _dyld_get_image_vmaddr_slide(0);
        }
    }
    return gSlide;
}

// 供 Tweak.xm 等外部使用的 slide 入口 (mwb_slide 仅本文件可见)
uintptr_t MWBMainSlide(void) { return mwb_slide(); }

// 物品注册表: 游戏静态数组 Item::items (方块与物品都在其中, 512 项)
static void **mwb_items_registry(void) {
    static void **reg = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        reg = (void **)MSFindSymbol(NULL, "__ZN4Item5itemsE");
        MWBDLog(@"[EMI调试] Item::items 注册表 = %p", reg);
    });
    return reg;
}

// Inventory::add(ItemInstance*): 内部检查后转调 FillingContainer::add 完成入库
typedef bool (*MWBAddFn)(void *, MWBItemInstance *);
static MWBAddFn mwb_inventory_add(void) {
    static MWBAddFn fn = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fn = (MWBAddFn)MSFindSymbol(NULL, "__ZN9Inventory3addEP12ItemInstance");
        MWBDLog(@"[EMI调试] Inventory::add = %p", fn);
    });
    return fn;
}

// 背包回读: 直接读游戏物品栏格子, 验证真实入库情况 (Container::getItem = vtable+0x10)
static void MWBDumpInventory(void *inventory, NSString *tag) {
    static int (*getSize)(void *) = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        getSize = (int (*)(void *))MSFindSymbol(NULL, "__ZNK9Inventory16getContainerSizeEv");
    });
    if (!getSize || !inventory) return;
    void **vtable = *(void ***)inventory;
    void *(*getItem)(void *, int) = (void *(*)(void *, int))vtable[0x10 / 8];
    if (!getItem) return;
    int n = getSize(inventory);
    if (n < 0 || n > 36) n = 36;
    NSMutableString *m = [NSMutableString stringWithFormat:@"[EMI调试] 背包回读(%@) %d 格:", tag, n];
    for (int i = 0; i < n; i++) {
        void *inst = getItem(inventory, i);
        if (!inst) continue;
        int count = *(int *)inst, aux = *(int *)((char *)inst + 4);   // count@0x00, aux@0x04
        if (count == 0 && aux == 0) continue;
        [m appendFormat:@" [i%d aux=%d×%d]", i, aux, count];
    }
    MWBDLog(@"%@", m);
}

// 给予物品: id=MCPE物品ID, count=数量, aux=辅助值 (0=新物品; 变种/颜色用 aux 指定)
static bool MWBGiveItem(int id, int count, int aux) {
    MWBDLog(@"[EMI调试] ===== 给予物品开始 id=%d count=%d =====", id, count);
    if (!gLocalPlayer) {
        MWBDLog(@"[EMI调试] 给予失败: 玩家未就绪 (还没进入世界)");
        return false;
    }
    if (count <= 0) count = 1;

    // Player+0x1708 = Inventory*
    void *inventory = *(void **)((char *)gLocalPlayer + 0x1708);
    MWBDLog(@"[EMI调试] player=%p inventory=%p", gLocalPlayer, inventory);
    if (!inventory) { MWBDLog(@"[EMI调试] 给予失败: 物品栏为空"); return false; }

    // 从 Item::items 注册表取 Item*
    void **registry = mwb_items_registry();
    if (!registry || id < 0 || id >= 512) {
        MWBDLog(@"[EMI调试] 给予失败: 注册表未解析或 ID %d 越界", id);
        return false;
    }
    void *item = registry[id];
    MWBDLog(@"[EMI调试] registry[%d]=%p", id, item);
    if (!item) { MWBDLog(@"[EMI调试] 给予失败: 物品 ID %d 未注册", id); return false; }

    // 构造 ItemInstance (valid 必须在 0x18; aux=0 保证满耐久/可参与配方)
    MWBItemInstance inst;
    memset(&inst, 0, sizeof(inst));
    inst.count = count;
    inst.aux = aux;
    inst.item = item;
    inst.info = *(void **)(MWBMainSlide() + MWB_ITEM_INFO_TABLE_VMADDR + (uintptr_t)id * 8);
    inst.valid = 1;
    MWBDLog(@"[EMI调试] ItemInstance: count=%d aux=%d item=%p info=%p valid@0x18=1 size=%zu",
                         inst.count, inst.aux, inst.item, inst.info, sizeof(inst));

    // 直接调用 Inventory::add
    MWBAddFn add = mwb_inventory_add();
    if (!add) { MWBDLog(@"[EMI调试] 给予失败: Inventory::add 未解析"); return false; }
    bool ok = false;
    @try {
        MWBDumpInventory(inventory, @"给予前");
        ok = add(inventory, &inst);
    } @catch (NSException *e) {
        MWBDLog(@"[EMI调试] add 调用异常: %@", e);
        return false;
    }
    MWBDumpInventory(inventory, ok ? @"给予后" : @"失败后");
    MWBDLog(@"[EMI] 给予物品 id=%d count=%d %@", id, count, ok ? @"成功" : @"失败(物品栏可能已满)");
    return ok;
}

// 初始化物品给予 (运行时解析符号并落盘日志)
static void MWBInstallGiver() {
    MWBDLog(@"[EMI调试] ===== 物品给予模块初始化 =====");
    for (uint32_t i = 0; i < 3; i++) {
        const char *name = _dyld_get_image_name(i);
        intptr_t s = _dyld_get_image_vmaddr_slide(i);
        MWBDLog(@"[EMI调试] image[%d] slide=0x%lx name=%s", i, (long)s, name ? name : "?");
    }
    void **reg = mwb_items_registry();
    MWBAddFn add = mwb_inventory_add();
    MWBDLog(@"[EMI] 物品给予模块已就绪 (registry=%p add=%p)", reg, add);
}

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

@interface MWBCubeView : UIView
- (void)setTopTile:(NSString *)top frontTile:(NSString *)front sideTile:(NSString *)side
          topIndex:(int)ti frontIndex:(int)fi sideIndex:(int)si;
@end
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

@interface MWBItemIconView : UIView
- (void)setItemTile:(NSString *)name index:(int)idx;
@end
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
    _hlTop.frame = (CGRect){{0,0},{w,b}}; _hlLeft.frame = (CGRect){{0,0},{b,h}};
    _shBottom.frame = (CGRect){{b,h-7*kEMIScale},{w-b,7*kEMIScale}};
    _shRight.frame = (CGRect){{w-7*kEMIScale,b},{7*kEMIScale,h-b}};
    if (_content) {
        CGFloat cs = 82*kEMIScale*0.78;
        _content.frame = (CGRect){{(w-cs)/2,(h-cs)/2},{cs,cs}};
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
@end

#pragma mark - 物品数据

// 物品定义
typedef struct {
    const char *cnName;     // 中文名
    BOOL isBlock;           // YES=方块(立方体) NO=物品(平面图标)
    int itemId;             // MCPE 物品/方块数字 ID
    const char *tile;       // terrain 组名(方块) 或 items 组名(物品)
    int idx;                // tile 索引
    // 方块三面 (若与 tile/idx 相同则填 NULL/-1)
    const char *topTile; int topIdx;
    const char *frontTile; int frontIdx;
    const char *sideTile; int sideIdx;
    int maxStack;           // 最大堆叠
    int category;           // 0=全部 1=装备 2=配方 3=建筑
} MWBItemDef;

// 材质索引: 工具 0木 1石 2铁 3金 4钻石 (注意金在钻石前面!); 盔甲 0皮革 1锁链 2铁 3钻石 4金
#define B(nm,cn,id,tp,ti,tt,ti2,ft,fi2,st,si2,stk,cat) \
    {(cn), YES, (id), (tp), (ti), (tt), (ti2), (ft), (fi2), (st), (si2), (stk), (cat)}
#define I(nm,cn,id,tp,ti,stk,cat) \
    {(cn), NO, (id), (tp), (ti), NULL, 0, NULL, 0, NULL, 0, (stk), (cat)}

static MWBItemDef gItems[] = {
    // ---- 建筑方块 (category 3) ----
    B(stone,       "石头",      1,  "stone",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(grass,       "草方块",    2,  "grass",0, "grass",0, "grass",1, "dirt",0, 64, 3),
    B(dirt,        "泥土",      3,  "dirt",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(cobble,      "圆石",      4,  "cobblestone",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(planks,      "橡木木板",  5,  "planks",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(sapling,     "橡树树苗",  6,  "sapling",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(bedrock,     "基岩",      7,  "bedrock",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(sand,        "沙子",      12, "sand",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(gravel,      "沙砾",      13, "gravel",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(gold_ore,    "金矿石",    14, "gold_ore",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(iron_ore,    "铁矿石",    15, "iron_ore",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(coal_ore,    "煤矿石",    16, "coal_ore",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(log,         "橡木原木",  17, "log",0, "log",4, "log",0, "log",0, 64, 3),
    B(leaves,      "橡树树叶",  18, "leaves",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(glass,       "玻璃",      20, "glass",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(lapis_ore,   "青金石矿石",21, "lapis_ore",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(lapis_block, "青金石块",  22, "lapis_block",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(sandstone,   "砂岩",      24, "sandstone",0, "sandstone",0, "sandstone",2, "sandstone",2, 64, 3),
    B(wool_white,  "白色羊毛",  35, "wool",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(gold_block,  "金块",      41, "gold_block",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(iron_block,  "铁块",      42, "iron_block",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(stone_slab,  "石台阶",    44, "stone_slab",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(brick,       "砖块",      45, "brick",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(tnt,         "TNT",       46, "tnt",0, "tnt",1, "tnt",0, "tnt",2, 64, 3),
    B(bookshelf,   "书架",      47, "bookshelf",0, "planks",0, "bookshelf",0, "planks",0, 64, 3),
    B(mossy,       "苔石",      48, "cobblestone_mossy",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(obsidian,    "黑曜石",    49, "obsidian",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(diamond_ore, "钻石矿石",  56, "diamond_ore",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(diamond_blk, "钻石块",    57, "diamond_block",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(crafting,    "工作台",    58, "crafting_table",0, "crafting_table",1, "crafting_table",0, "crafting_table",2, 64, 3),
    B(furnace,     "熔炉",      61, "furnace",0, "furnace",2, "furnace",0, "furnace",1, 64, 3),
    B(ice,         "冰",        79, "ice",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(snow,        "雪块",      80, "snow",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(clay,        "黏土块",    82, "clay",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(pumpkin,     "南瓜",      86, "pumpkin",0, "pumpkin",1, "pumpkin",0, "pumpkin",2, 64, 3),
    B(netherrack,  "地狱岩",    87, "netherrack",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(soul_sand,   "灵魂沙",    88, "soul_sand",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(glowstone,   "萤石",      89, "glowstone",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(stonebrick,  "石砖",      98, "stonebrick",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(iron_bars,   "铁栏杆",    101,"iron_bars",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(glass_pane,  "玻璃板",    102,"glass_pane_top",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(melon,       "西瓜",      103,"melon",0, "melon",0, "melon",1, "melon",1, 64, 3),
    B(mycelium,    "菌丝",      110,"mycelium",0, "mycelium",1, "mycelium",0, "dirt",0, 64, 3),
    B(end_stone,   "末地石",    121,"end_stone",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(redstone_ore,"红石矿石",  73, "redstone_ore",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(redstone_blk,"红石块",    152,"redstone_block",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(quartz_blk,  "石英块",    155,"quartz_block",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(hay,         "干草块",    170,"hayblock",0, "hayblock",0, "hayblock",1, "hayblock",1, 64, 3),
    B(hardened_clay,"硬化黏土", 172,"hardened_clay",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(coal_block,  "煤炭块",    173,"coal_block",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(emerald_ore, "绿宝石矿石",129,"emerald_ore",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(emerald_blk, "绿宝石块",  133,"emerald_block",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(sponge,      "海绵",      19, "sponge",0, NULL,0, NULL,0, NULL,0, 64, 3),

    // ---- 装备/工具 (category 1) ----
    I(sword_w,  "木剑",   268, "sword",0, 1, 1),
    I(sword_s,  "石剑",   272, "sword",1, 1, 1),
    I(sword_i,  "铁剑",   267, "sword",2, 1, 1),
    I(sword_d,  "钻石剑", 276, "sword",4, 1, 1),
    I(sword_g,  "金剑",   283, "sword",3, 1, 1),
    I(pick_w,   "木镐",   270, "pickaxe",0, 1, 1),
    I(pick_s,   "石镐",   274, "pickaxe",1, 1, 1),
    I(pick_i,   "铁镐",   257, "pickaxe",2, 1, 1),
    I(pick_d,   "钻石镐", 278, "pickaxe",4, 1, 1),
    I(pick_g,   "金镐",   285, "pickaxe",3, 1, 1),
    I(axe_w,    "木斧",   271, "axe",0, 1, 1),
    I(axe_s,    "石斧",   275, "axe",1, 1, 1),
    I(axe_i,    "铁斧",   258, "axe",2, 1, 1),
    I(axe_d,    "钻石斧", 279, "axe",4, 1, 1),
    I(shovel_w, "木铲",   269, "shovel",0, 1, 1),
    I(shovel_s, "石铲",   273, "shovel",1, 1, 1),
    I(shovel_i, "铁铲",   256, "shovel",2, 1, 1),
    I(shovel_d, "钻石铲", 277, "shovel",4, 1, 1),
    I(shovel_g, "金铲",   284, "shovel",3, 1, 1),
    I(bow,      "弓",     261, "bow_standby",0, 1, 1),
    I(arrow,    "箭",     262, "arrow",0, 64, 1),
    I(helmet_i, "铁头盔", 306, "helmet",2, 1, 1),
    I(chest_i,  "铁胸甲", 307, "chestplate",2, 1, 1),
    I(legs_i,   "铁护腿", 308, "leggings",2, 1, 1),
    I(boots_i,  "铁靴子", 309, "boots",2, 1, 1),
    I(helmet_d, "钻石头盔",310,"helmet",3, 1, 1),
    I(chest_d,  "钻石胸甲",311,"chestplate",3, 1, 1),
    I(legs_d,   "钻石护腿",312,"leggings",3, 1, 1),
    I(boots_d,  "钻石靴子",313,"boots",3, 1, 1),
    I(flint,    "打火石", 259, "flint_and_steel",0, 1, 1),
    I(shears,   "剪刀",   359, "shears",0, 1, 1),
    I(fishrod,  "钓鱼竿", 346, "fishing_rod_uncast",0, 1, 1),

    // ---- 材料/物品 (category 0) ----
    I(stick,        "木棍",       280, "stick",0, 64, 0),
    I(coal,         "煤炭",       263, "coal",0, 64, 0),
    I(charcoal,     "木炭",       263, "charcoal",0, 64, 0),
    I(diamond,      "钻石",       264, "diamond",0, 64, 0),
    I(iron_ingot,   "铁锭",       265, "iron_ingot",0, 64, 0),
    I(gold_ingot,   "金锭",       266, "gold_ingot",0, 64, 0),
    I(emerald,      "绿宝石",     388, "emerald",0, 64, 0),
    I(redstone,     "红石粉",     331, "redstone_dust",0, 64, 0),
    I(clay_ball,    "黏土球",     337, "clay_ball",0, 64, 0),
    I(brick_item,   "红砖",       336, "brick",0, 64, 0),
    I(flint_item,   "燧石",       318, "flint",0, 64, 0),
    I(string,       "线",         287, "string",0, 64, 0),
    I(leather,      "皮革",       334, "leather",0, 64, 0),
    I(feather,      "羽毛",       288, "feather",0, 64, 0),
    I(bone,         "骨头",       352, "bone",0, 64, 0),
    I(slimeball,    "黏液球",     341, "slimeball",0, 64, 0),
    I(egg,          "鸡蛋",       344, "egg",0, 16, 0),
    I(snowball,     "雪球",       332, "snowball",0, 16, 0),
    I(gunpowder,    "火药",       289, "gunpowder",0, 64, 0),
    I(glowdust,     "萤石粉",     348, "glowstone_dust",0, 64, 0),
    I(blaze_rod,    "烈焰棒",     369, "blaze_rod",0, 64, 0),
    I(blaze_powder, "烈焰粉",     377, "blaze_powder",0, 64, 0),
    I(ender_pearl,  "末影珍珠",   368, "ender_pearl",0, 16, 0),
    I(ender_eye,    "末影之眼",   381, "ender_eye",0, 64, 0),
    I(magma_cream,  "岩浆膏",     378, "magma_cream",0, 64, 0),
    I(ghast_tear,   "恶魂之泪",   370, "ghast_tear",0, 64, 0),
    I(sugar,        "糖",         353, "sugar",0, 64, 0),
    I(wheat,        "小麦",       296, "wheat",0, 64, 0),
    I(seeds,        "小麦种子",   295, "seeds_wheat",0, 64, 0),
    I(apple,        "苹果",       260, "apple",0, 64, 0),
    I(gold_apple,   "金苹果",     322, "apple_golden",0, 64, 0),
    I(bread,        "面包",       297, "bread",0, 64, 0),
    I(cookie,       "饼干",       357, "cookie",0, 64, 0),
    I(cake,         "蛋糕",       354, "cake",0, 1, 0),
    I(melon_item,   "西瓜片",     360, "melon",0, 64, 0),
    I(carrot,       "胡萝卜",     391, "carrot",0, 64, 0),
    I(potato,       "马铃薯",     392, "potato",0, 64, 0),
    I(baked_potato, "烤马铃薯",   393, "potato_baked",0, 64, 0),
    I(beef_raw,     "生牛肉",     363, "beef_raw",0, 64, 0),
    I(beef_cooked,  "牛排",       364, "beef_cooked",0, 64, 0),
    I(pork_raw,     "生猪排",     319, "porkchop_raw",0, 64, 0),
    I(pork_cooked,  "熟猪排",     320, "porkchop_cooked",0, 64, 0),
    I(chicken_raw,  "生鸡肉",     365, "chicken_raw",0, 64, 0),
    I(chicken_ckd,  "熟鸡肉",     366, "chicken_cooked",0, 64, 0),
    I(bucket,       "桶",         325, "bucket",0, 1, 0),
    I(bucket_water, "水桶",       326, "bucket",1, 1, 0),
    I(bucket_lava,  "熔岩桶",     327, "bucket",2, 1, 0),
    I(book,         "书",         340, "book_normal",0, 64, 0),
    I(paper,        "纸",         339, "paper",0, 64, 0),
    I(map,          "地图",       358, "map_empty",0, 64, 0),
    I(compass,      "指南针",     345, "compass_item",0, 64, 0),
    I(clock,        "钟",         347, "clock_item",0, 64, 0),
    I(bowl,         "碗",         281, "bowl",0, 64, 0),
    I(mushroom_stew,"蘑菇煲",     282, "mushroom_stew",0, 1, 0),
    I(saddle,       "鞍",         329, "saddle",0, 1, 0),
    I(boat,         "船",         333, "boat",0, 1, 0),
    I(minecart,     "矿车",       342, "minecart_normal",0, 1, 0),
    I(bed,          "床",         355, "bed",0, 1, 0),
    I(reeds,        "甘蔗",       338, "reeds",0, 64, 0),
    I(rotten_flesh, "腐肉",       367, "rotten_flesh",0, 64, 0),
    I(spider_eye,   "蜘蛛眼",     375, "spider_eye",0, 64, 0),
    I(bottle,       "玻璃瓶",     374, "potion_bottle_empty",0, 64, 0),
    I(potion,       "药水",       373, "potion_bottle_drinkable",0, 1, 0),
    I(skull,        "骷髅头颅",   397, "skull_skeleton",0, 64, 0),
    I(book_ench,    "附魔书",     403, "book_enchanted",0, 1, 0),
};
static int gItemCount = sizeof(gItems) / sizeof(gItems[0]);

// 按 ID 找物品定义
static const MWBItemDef *MWBItemDefForId(int itemId) {
    for (int i = 0; i < gItemCount; i++)
        if (gItems[i].itemId == itemId) return &gItems[i];
    return NULL;
}
static NSString *MWBItemName(int itemId) {
    const MWBItemDef *d = MWBItemDefForId(itemId);
    return d ? [NSString stringWithUTF8String:d->cnName] : [NSString stringWithFormat:@"ID %d", itemId];
}

#pragma mark - 变体物品 (aux 决定变种, 单击弹窗选择)

// 返回该物品的变种数 (0 = 无变体, 单击直接给予)
static int MWBVariantCount(int itemId) {
    switch (itemId) {
        case 35:  return 16;   // 羊毛 16 色
        case 351: return 16;   // 染料 16 色
        case 17:  return 3;    // 原木
        case 5:   return 6;    // 木板
        case 44:  return 4;    // 石台阶
        case 24:  return 4;    // 砂岩
        case 263: return 2;    // 煤炭/木炭
        default:  return 0;
    }
}

// 变种名 (羊毛与染料的 aux 色序不同)
static NSString *MWBVariantName(int itemId, int aux) {
    static const char *wool[16] = {"白","橙","品红","淡蓝","黄","黄绿","粉","灰","浅灰","青","紫","蓝","棕","绿","红","黑"};
    static const char *dye[16]  = {"墨囊","玫瑰红","仙人掌绿","可可豆","天蓝","紫","青","银灰","灰","粉红","黄绿","黄","淡蓝","品红","橙","骨粉"};
    if (itemId == 35) return [NSString stringWithFormat:@"羊毛·%s", wool[aux % 16]];
    if (itemId == 351) return [NSString stringWithFormat:@"染料·%s", dye[aux % 16]];
    if (itemId == 263) return aux == 1 ? @"木炭" : @"煤炭";
    if (itemId == 17) return aux == 0 ? @"橡木" : (aux == 1 ? @"云杉" : @"桦木");
    return [NSString stringWithFormat:@"变种 %d", aux];
}

#pragma mark - 游戏配方读取 (长按查看, 数据来自游戏 Recipes 单例)

// Recipes 单例指针的静态地址 (SurvivalInventoryScreen::updateCraftableItems 反汇编核实:
// 为空时 new 0x18 字节并调 Recipes 构造函数注册全部配方, 我们做同样的懒加载)
#define MWB_RECIPES_PTR_VMADDR 0x10034d0c0UL

// Recipe 对象布局 (addShapedRecipe / ItemPack::add 反汇编核实):
//   +0x08 材料包 ItemPack (头节点指针在 +0x10; 节点键值是 Item+0x30 的值, 不等于物品 id,
//         不能用来反查名字 — 已弃用, 材料改走虚表读取)
//   +0x30/+0x38 产物 vector<ItemInstance> (元素 0x20 字节: count@0x00, aux@0x04, Item*@0x08)
//   虚表 +0x40 = getIngredient(col, row, flag): 按格子返回材料 ItemInstance*
//   总大小 0x48

// 确保游戏配方表已初始化 (镜像游戏的懒加载逻辑)
static void **mwb_recipes_singleton(void) {
    void **slot = (void **)(MWBMainSlide() + MWB_RECIPES_PTR_VMADDR);
    if (!*slot) {
        void *(*recipesCtor)(void *) = (void *(*)(void *))MSFindSymbol(NULL, "__ZN7RecipesC2Ev");
        if (!recipesCtor) { MWBDLog(@"[EMI] 未找到 Recipes 构造符号"); return NULL; }
        void *obj = calloc(1, 0x18);
        if (!obj) return NULL;
        recipesCtor(obj);
        *slot = obj;
        MWBDLog(@"[EMI] 已按游戏方式懒加载配方表");
    }
    return (void **)*slot;
}

// 反查注册表: Item* -> 物品 ID
static int MWBIdOfItem(void *item) {
    void **reg = mwb_items_registry();
    if (!reg || !item) return -1;
    for (int i = 0; i < 512; i++)
        if (reg[i] == item) return i;
    return -1;
}

// 遍历游戏配方, 返回产物为 itemId 的所有配方
// 返回 @[ 每条配方@[材料数组 @[ @[id, count], ... ], 产物数量], ... ]
static NSArray *MWBGameRecipesForItem(int itemId) {
    void **recipes = mwb_recipes_singleton();
    if (!recipes) return nil;
    void **begin = (void **)recipes[0], **end = (void **)recipes[1];
    if (!begin || end <= begin) { MWBDLog(@"[EMI] 游戏配方表为空"); return nil; }
    MWBDLog(@"[EMI] 游戏配方总数 %ld, 查找产物 id=%d", (long)(end - begin), itemId);
    void **reg = mwb_items_registry();
    void *want = reg ? reg[itemId] : NULL;
    if (!want) return nil;

    NSMutableArray *out = [NSMutableArray new];
    int dumped = 0;
    for (void **p = begin; p != end; p++) {
        char *r = (char *)*p;
        if (!r) continue;

        // 产物: vector<ItemInstance> @ +0x30 (元素内联, 首元素地址就是向量起点)
        // 元素 0x20 字节: count@0x00, aux@0x04, Item*@0x08
        char *res = *(char **)(r + 0x30);
        void **rve = *(void ***)(r + 0x38);
        if (!res || (char **)rve <= (char **)res) continue;
        void *rItem = *(void **)(res + 8);
        if (rItem != want) continue;
        int rcount = *(int *)res;
        int raux = *(int *)(res + 4);
        if (rcount <= 0 || rcount > 64) continue;

        // 诊断 (只打前 3 条命中配方)
        if (dumped < 3) {
            MWBDLog(@"[EMI配方命中] r=%p 产物数=%d 产物aux=%d", r, rcount, raux);
            dumped++;
        }

        // 材料: Recipe 虚表 +0x40 = getIngredient(col, row, flag), 按格子返回材料实例
        // (游戏 SurvivalInventoryScreen::updateIngredientCountFromRecipe 就这么读)
        void **vtable = *(void ***)r;
        typedef void *(*GetCellFn)(void *, int, int, BOOL);
        GetCellFn getCell = (GetCellFn)vtable[0x40 / 8];
        if (!getCell) continue;
        NSMutableDictionary<NSValue *, NSNumber *> *merged = [NSMutableDictionary new];
        for (int rowI = 0; rowI < 3; rowI++) {
            for (int colI = 0; colI < 3; colI++) {
                void *cell = getCell(r, colI, rowI, NO);
                if (!cell) continue;
                void *it = *(void **)((char *)cell + 8);
                int cnt = *(int *)cell;
                if (!it || cnt <= 0) continue;
                NSValue *key = [NSValue valueWithPointer:it];
                merged[key] = @([merged[key] intValue] + cnt);
            }
        }
        if (merged.count == 0) continue;

        NSMutableArray *ings = [NSMutableArray new];
        for (NSValue *key in merged) {
            int id = MWBIdOfItem([key pointerValue]);
            if (id <= 0) continue;
            [ings addObject:@[@(id), merged[key]]];
        }
        if (ings.count == 0) continue;
        [out addObject:@[ings, @(rcount)]];
    }
    return out;
}

#pragma mark - 配方查看面板 (长按物品弹出)

@interface MWBRecipePanel : UIView
@property (nonatomic, copy) void (^onClose)(void);
- (instancetype)initWithFrame:(CGRect)frame resultId:(int)resultId;
@end

@implementation MWBRecipePanel
// 物品小图标 (方块用立方体, 物品用平面图)
- (UIView *)iconForId:(int)itemId size:(CGFloat)sz center:(CGPoint)c {
    UIView *wrap = [[UIView alloc] initWithFrame:(CGRect){{c.x - sz/2, c.y - sz/2},{sz, sz}}];
    wrap.backgroundColor = [UIColor clearColor];
    wrap.userInteractionEnabled = NO;
    const MWBItemDef *def = MWBItemDefForId(itemId);
    if (!def) {
        UILabel *q = [[UILabel alloc] initWithFrame:wrap.bounds];
        q.text = @"?"; q.textAlignment = NSTextAlignmentCenter;
        q.font = [UIFont boldSystemFontOfSize:sz * 0.6];
        q.textColor = EMIColor(0x6b,0x66,0x68);
        [wrap addSubview:q];
        return wrap;
    }
    UIView *icon;
    if (def->isBlock) {
        MWBCubeView *cube = [[MWBCubeView alloc] initWithSize:sz];
        const char *top = def->topTile ?: def->tile;
        const char *front = def->frontTile ?: def->tile;
        const char *side = def->sideTile ?: def->tile;
        [cube setTopTile:[NSString stringWithUTF8String:top]
               frontTile:[NSString stringWithUTF8String:front]
                sideTile:[NSString stringWithUTF8String:side]
                topIndex:def->topTile ? def->topIdx : def->idx
              frontIndex:def->frontTile ? def->frontIdx : def->idx
               sideIndex:def->sideTile ? def->sideIdx : def->idx];
        icon = cube;
    } else {
        MWBItemIconView *iv = [[MWBItemIconView alloc] initWithSize:sz];
        [iv setItemTile:[NSString stringWithUTF8String:def->tile] index:def->idx];
        icon = iv;
    }
    icon.frame = wrap.bounds;
    [wrap addSubview:icon];
    return wrap;
}

// 一行材料标签 (图标下方 名称×数量)
- (UILabel *)ingLabel:(int)itemId count:(int)count frame:(CGRect)f {
    UILabel *l = [[UILabel alloc] initWithFrame:f];
    l.text = count > 1 ? [NSString stringWithFormat:@"%@×%d", MWBItemName(itemId), count] : MWBItemName(itemId);
    l.font = [UIFont systemFontOfSize:26 * kEMIScale];
    l.textAlignment = NSTextAlignmentCenter;
    l.textColor = EMIColor(0x34,0x31,0x32);
    return l;
}

- (instancetype)initWithFrame:(CGRect)frame resultId:(int)resultId {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
        CGFloat s = kEMIScale;

        // 从游戏 Recipes 单例读配方
        NSArray *recipes = MWBGameRecipesForItem(resultId);
        BOOL none = recipes.count == 0;
        NSString *name = MWBItemName(resultId);

        CGFloat pw = 1560 * s;
        CGFloat rowH = 210 * s;
        CGFloat titleH = 130 * s;
        CGFloat ph = titleH + (none ? 140 * s : recipes.count * rowH + 30 * s) + 50 * s;
        UIView *panel = [[UIView alloc] initWithFrame:(CGRect){{(frame.size.width - pw) / 2, (frame.size.height - ph) / 2},{pw, ph}}];
        panel.backgroundColor = EMIColor(0xc8,0xc0,0xb8);
        panel.layer.borderWidth = 10 * s;
        panel.layer.borderColor = EMIColor(0x9c,0x91,0x89).CGColor;
        [self addSubview:panel];

        UILabel *title = [[UILabel alloc] initWithFrame:(CGRect){{40 * s, 20 * s},{pw - 80 * s, 80 * s}}];
        title.text = [NSString stringWithFormat:@"%@ 的配方", name];
        title.font = [UIFont boldSystemFontOfSize:48 * s];
        title.textColor = EMIColor(0x34,0x31,0x32);
        [panel addSubview:title];

        if (none) {
            UILabel *l = [[UILabel alloc] initWithFrame:(CGRect){{40 * s, titleH},{pw - 80 * s, 90 * s}}];
            l.text = @"游戏配方中没有能合成该物品的配方 (自然生成 / 怪物掉落)";
            l.font = [UIFont systemFontOfSize:36 * s];
            l.textColor = EMIColor(0x6b,0x66,0x68);
            [panel addSubview:l];
        }

        for (NSInteger rIdx = 0; rIdx < (NSInteger)recipes.count; rIdx++) {
            NSArray *entry = recipes[rIdx];
            NSArray *ings = entry[0];               // @[ @[id, count], ... ]
            int rcount = [entry[1] intValue];
            CGFloat y = titleH + rIdx * rowH;

            CGFloat x = 60 * s;
            for (NSInteger i = 0; i < (NSInteger)ings.count && i < 5; i++) {
                int ingId = [ings[i][0] intValue];
                int ingCount = [ings[i][1] intValue];
                if (i > 0) {
                    UILabel *plus = [[UILabel alloc] initWithFrame:(CGRect){{x, y + 55 * s},{36 * s, 50 * s}}];
                    plus.text = @"+";
                    plus.font = [UIFont boldSystemFontOfSize:38 * s];
                    plus.textColor = EMIColor(0x34,0x31,0x32);
                    [panel addSubview:plus];
                    x += 50 * s;
                }
                [panel addSubview:[self iconForId:ingId size:90 * s center:(CGPoint){x + 45 * s, y + 65 * s}]];
                [panel addSubview:[self ingLabel:ingId count:ingCount
                                           frame:(CGRect){{x - 20 * s, y + 125 * s},{230 * s, 40 * s}}]];
                x += 210 * s;
            }
            if (ings.count > 5) {
                UILabel *more = [[UILabel alloc] initWithFrame:(CGRect){{x, y + 55 * s},{90 * s, 50 * s}}];
                more.text = @"...";
                more.font = [UIFont boldSystemFontOfSize:38 * s];
                more.textColor = EMIColor(0x34,0x31,0x32);
                [panel addSubview:more];
                x += 100 * s;
            }
            UILabel *eq = [[UILabel alloc] initWithFrame:(CGRect){{x, y + 55 * s},{50 * s, 50 * s}}];
            eq.text = @"→";
            eq.font = [UIFont boldSystemFontOfSize:40 * s];
            eq.textColor = EMIColor(0x2c,0x76,0x07);
            [panel addSubview:eq];
            x += 62 * s;
            [panel addSubview:[self iconForId:resultId size:90 * s center:(CGPoint){x + 45 * s, y + 65 * s}]];
            [panel addSubview:[self ingLabel:resultId count:rcount
                                       frame:(CGRect){{x - 20 * s, y + 125 * s},{230 * s, 40 * s}}]];
        }

        UILabel *hint = [[UILabel alloc] initWithFrame:(CGRect){{0, ph - 40 * s},{pw, 34 * s}}];
        hint.text = @"轻触任意处关闭";
        hint.font = [UIFont systemFontOfSize:24 * s];
        hint.textAlignment = NSTextAlignmentCenter;
        hint.textColor = EMIColor(0x9c,0x91,0x89);
        [panel addSubview:hint];

        // 点任意处关闭
        [self addGestureRecognizer:[[UITapGestureRecognizer alloc]
            initWithTarget:self action:@selector(dismiss)]];
    }
    return self;
}
- (void)dismiss {
    if (self.onClose) self.onClose();
}
@end

#pragma mark - 变体选择面板 (多变体物品单击弹出)

@interface MWBVariantPanel : UIView
@property (nonatomic, copy) void (^onClose)(void);
- (instancetype)initWithFrame:(CGRect)frame itemId:(int)itemId;
@end

@implementation MWBVariantPanel {
    int _itemId, _selAux;
    NSMutableArray<UIControl *> *_optBtns;
    UIControl *_giveOne, *_giveStack;
}
- (void)styleBtn:(UIControl *)b title:(NSString *)t selected:(BOOL)sel fontSize:(CGFloat)fs {
    CGFloat s = kEMIScale;
    b.backgroundColor = sel ? EMIColor(0xf1,0xeb,0xe5) : EMIColor(0xcf,0xc8,0xc1);
    b.layer.borderWidth = 5 * s;
    b.layer.borderColor = sel ? EMIColor(0x2c,0x76,0x07).CGColor : EMIColor(0x8e,0x85,0x7e).CGColor;
    UILabel *l = [b viewWithTag:1];
    if (!l) {
        l = [[UILabel alloc] initWithFrame:b.bounds];
        l.tag = 1; l.textAlignment = NSTextAlignmentCenter;
        l.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [b addSubview:l];
    }
    l.font = [UIFont systemFontOfSize:fs];
    l.textColor = EMIColor(0x34,0x31,0x32);
    l.text = t;
}
- (void)pickVariant:(UIControl *)b {
    _selAux = (int)b.tag;
    [self refreshVariantSelection];
}
- (void)refreshVariantSelection {
    for (UIControl *b in _optBtns)
        [self styleBtn:b title:MWBVariantName(_itemId, (int)b.tag) selected:((int)b.tag == _selAux) fontSize:30 * kEMIScale];
}
- (void)giveTapped:(UIControl *)b {
    int n = b.tag == 101 ? 64 : 1;
    MWBDLog(@"[EMI调试] 变体面板给予 %s id=%d aux=%d", b.tag == 101 ? "1组" : "1个", _itemId, _selAux);
    MWBGiveItem(_itemId, n, _selAux);
    if (self.onClose) self.onClose();
}
- (instancetype)initWithFrame:(CGRect)frame itemId:(int)itemId {
    if ((self = [super initWithFrame:frame])) {
        _itemId = itemId; _selAux = 0;
        _optBtns = [NSMutableArray new];
        CGFloat s = kEMIScale;

        // 背景层: 半透明 + 点击关闭 (面板加在其上, 互不干扰)
        UIControl *backdrop = [[UIControl alloc] initWithFrame:self.bounds];
        backdrop.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
        [backdrop addTarget:self action:@selector(dismiss) forControlEvents:UIControlEventTouchUpInside];
        [self addSubview:backdrop];

        int n = MWBVariantCount(itemId);
        int cols = n <= 4 ? n : (n <= 6 ? 3 : 8);
        int rows = (n + cols - 1) / cols;
        CGFloat cellW = 190 * s, cellH = 110 * s, gap = 16 * s;
        CGFloat pw = cols * (cellW + gap) + gap + 20 * s;
        CGFloat topH = 120 * s;
        CGFloat btnH = 100 * s;
        CGFloat ph = topH + rows * (cellH + gap) + btnH + 50 * s;
        UIView *panel = [[UIView alloc] initWithFrame:(CGRect){{(frame.size.width - pw) / 2, MAX(20 * s, (frame.size.height - ph) / 2)},{pw, ph}}];
        panel.backgroundColor = EMIColor(0xc8,0xc0,0xb8);
        panel.layer.borderWidth = 10 * s;
        panel.layer.borderColor = EMIColor(0x9c,0x91,0x89).CGColor;
        [self addSubview:panel];

        UILabel *title = [[UILabel alloc] initWithFrame:(CGRect){{30 * s, 20 * s},{pw - 60 * s, 70 * s}}];
        title.text = [NSString stringWithFormat:@"%@ · 选择变种", MWBItemName(itemId)];
        title.font = [UIFont boldSystemFontOfSize:44 * s];
        title.textColor = EMIColor(0x34,0x31,0x32);
        [panel addSubview:title];

        for (int i = 0; i < n; i++) {
            UIControl *b = [[UIControl alloc] initWithFrame:(CGRect){{gap + (i % cols) * (cellW + gap), topH + (i / cols) * (cellH + gap)},{cellW, cellH}}];
            b.tag = i;
            [b addTarget:self action:@selector(pickVariant:) forControlEvents:UIControlEventTouchUpInside];
            [panel addSubview:b];
            [_optBtns addObject:b];
        }
        [self refreshVariantSelection];

        for (int i = 0; i < 2; i++) {
            UIControl *b = [[UIControl alloc] initWithFrame:(CGRect){{pw / 2 + (i == 0 ? -280 * s : 30 * s), ph - btnH - 26 * s},{250 * s, btnH}}];
            b.tag = 100 + i;
            [b addTarget:self action:@selector(giveTapped:) forControlEvents:UIControlEventTouchUpInside];
            [panel addSubview:b];
            [self styleBtn:b title:(i == 0 ? @"给 1 个" : @"给 1 组") selected:NO fontSize:36 * s];
            if (i == 0) _giveOne = b; else _giveStack = b;
        }
    }
    return self;
}
@end

#pragma mark - EMI 主窗口

@interface MWBEMIWindow : UIView
@property (nonatomic, copy) void (^onClose)(void);
- (void)showRecipeForId:(int)itemId;
- (void)showVariantForId:(int)itemId;
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
    _window = [[UIView alloc] initWithFrame:(CGRect){{winX,winY},{winW,winH}}];
    _window.backgroundColor = EMIColor(0xc8,0xc0,0xb8);
    _window.layer.borderWidth = 10*s;
    _window.layer.borderColor = EMIColor(0x9c,0x91,0x89).CGColor;
    _window.layer.shadowColor = [UIColor blackColor].CGColor;
    _window.layer.shadowOffset = (CGSize){8*s, 8*s};
    _window.layer.shadowRadius = 0; _window.layer.shadowOpacity = 0.28;
    [self addSubview:_window];
    [self addInsetShadow:_window light:EMIColor(0xe7,0xe0,0xda) dark:EMIColor(0x7f,0x77,0x70)
                   lightW:8 darkW:9];

    _rail = [[UIView alloc] initWithFrame:(CGRect){{6*s,20*s},{165*s,878*s}}];
    [_window addSubview:_rail];

    UIControl *closeBtn = [self makeCloseButton];
    closeBtn.frame = (CGRect){{24*s,0},{132*s,120*s}};
    [closeBtn addTarget:self action:@selector(close) forControlEvents:UIControlEventTouchUpInside];
    [_rail addSubview:closeBtn];

    NSArray *icons = @[[self makeSaplingIcon],[self makeSwordIcon],
                       [self makeBookshelfIcon],[self makeBrickCubeIcon]];
    NSMutableArray *tabs = [NSMutableArray new];
    CGFloat tabY[] = {156, 336, 516, 696};
    for (int i = 0; i < 4; i++) {
        MWBEMITab *tab = [[MWBEMITab alloc] initWithIcon:icons[i]];
        tab.frame = (CGRect){{0,tabY[i]*s},{165*s,166*s}};
        tab.tag = i; tab.active = (i == 0);
        [tab addTarget:self action:@selector(switchTab:) forControlEvents:UIControlEventTouchUpInside];
        [_rail addSubview:tab]; [tabs addObject:tab];
    }
    _tabs = tabs;

    _gridWrap = [[UIView alloc] initWithFrame:(CGRect){{233*s,37*s},{1590*s,873*s}}];
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
    t.frame = (CGRect){{o,o},{w-2*o,lw*s}}; l.frame = (CGRect){{o,o},{lw*s,h-2*o}};
    b.frame = (CGRect){{o,h-o-dw*s},{w-2*o,dw*s}}; r.frame = (CGRect){{w-o-dw*s,o},{dw*s,h-2*o}};
}

- (UIControl *)makeCloseButton {
    UIControl *btn = [[UIControl alloc] init];
    btn.backgroundColor = EMIColor(0xc5,0xbd,0xb6);
    btn.layer.borderWidth = 10*kEMIScale;
    btn.layer.borderColor = EMIColor(0xc5,0xbd,0xb6).CGColor;
    btn.layer.shadowColor = [UIColor blackColor].CGColor;
    btn.layer.shadowOffset = (CGSize){8*kEMIScale, 8*kEMIScale};
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
        it.frame = (CGRect){{0,0},{iw,sh}}; il.frame = (CGRect){{0,0},{sh,ih}};
        ib.frame = (CGRect){{0,ih-sh},{iw,sh}}; ir.frame = (CGRect){{iw-sh,0},{sh,ih}};
        UIView *x1 = [inner viewWithTag:2], *x2 = [inner viewWithTag:3];
        CGFloat xw = 60*s, xh = 19*s;
        x1.frame = (CGRect){{(iw-xw)/2,(ih-xh)/2},{xw,xh}};
        x2.frame = (CGRect){{(iw-xw)/2,(ih-xh)/2},{xw,xh}};
        x1.transform = CGAffineTransformMakeRotation(M_PI_4);
        x2.transform = CGAffineTransformMakeRotation(-M_PI_4);
    }
}

#pragma mark - 分类图标

- (UIView *)makeSaplingIcon {
    UIView *v = [[UIView alloc] init]; v.backgroundColor = [UIColor clearColor];
    CGFloat s = kEMIScale, sz = 78*s;
    v.bounds = (CGRect){{0,0},{sz,sz}};
    UIView *trunk = [[UIView alloc] initWithFrame:(CGRect){{sz*0.42,sz*0.65},{sz*0.12,sz*0.3}}];
    trunk.backgroundColor = EMIColor(0x6b,0x3b,0x12);
    UIView *leaves = [[UIView alloc] initWithFrame:(CGRect){{sz*0.15,sz*0.1},{sz*0.7,sz*0.6}}];
    leaves.backgroundColor = EMIColor(0x2c,0x76,0x07);
    [v addSubview:trunk]; [v addSubview:leaves];
    return v;
}
- (UIView *)makeSwordIcon {
    UIView *v = [[UIView alloc] init]; v.backgroundColor = [UIColor clearColor];
    CGFloat s = kEMIScale, sz = 92*s;
    v.bounds = (CGRect){{0,0},{sz,sz}};
    UIView *blade = [[UIView alloc] initWithFrame:(CGRect){{sz*0.42,sz*0.02},{sz*0.18,sz*0.7}}];
    blade.backgroundColor = EMIColor(0xc2,0xcb,0xce);
    blade.layer.borderWidth = 4*s; blade.layer.borderColor = EMIColor(0x2f,0x34,0x34).CGColor;
    UIView *guard = [[UIView alloc] initWithFrame:(CGRect){{sz*0.22,sz*0.68},{sz*0.6,sz*0.13}}];
    guard.backgroundColor = EMIColor(0x5d,0x44,0x2d);
    guard.layer.borderWidth = 4*s; guard.layer.borderColor = EMIColor(0x2a,0x21,0x18).CGColor;
    UIView *handle = [[UIView alloc] initWithFrame:(CGRect){{sz*0.45,sz*0.78},{sz*0.15,sz*0.27}}];
    handle.backgroundColor = EMIColor(0x5e,0x44,0x2f);
    handle.layer.borderWidth = 4*s; handle.layer.borderColor = EMIColor(0x2a,0x21,0x18).CGColor;
    [v addSubview:blade]; [v addSubview:guard]; [v addSubview:handle];
    v.transform = CGAffineTransformMakeRotation(-M_PI_4*0.97);
    return v;
}
- (UIView *)makeBookshelfIcon {
    UIView *v = [[UIView alloc] init]; v.backgroundColor = [UIColor clearColor];
    CGFloat s = kEMIScale, sz = 80*s;
    v.bounds = (CGRect){{0,0},{sz,sz}};
    UIView *front = [[UIView alloc] initWithFrame:(CGRect){{sz*0.12,sz*0.25},{sz*0.72,sz*0.6}}];
    front.backgroundColor = EMIColor(0x5e,0x3b,0x20);
    front.layer.borderWidth = 5*s; front.layer.borderColor = EMIColor(0x3b,0x24,0x12).CGColor;
    NSArray *colors = @[EMIColor(0x1b,0x68,0x2f),EMIColor(0x5d,0x2b,0x5e),
                        EMIColor(0x6a,0x25,0x25),EMIColor(0x19,0x3d,0x6c),EMIColor(0xb7,0x9b,0x32)];
    CGFloat bookW = front.bounds.size.width / colors.count;
    for (int i = 0; i < (int)colors.count; i++) {
        UIView *book = [[UIView alloc] initWithFrame:(CGRect){{i*bookW+3*s,3*s},{bookW-6*s,front.bounds.size.height-6*s}}];
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
    __weak typeof(self) ws = self;

    CGFloat s = kEMIScale;
    CGFloat cellSize = 159*s;
    int cols = 10;
    NSMutableArray *visible = [NSMutableArray new];
    for (int i = 0; i < gItemCount; i++) {
        if (_currentCategory == 0 || gItems[i].category == _currentCategory)
            [visible addObject:@(i)];
    }
    int rows = ((int)visible.count + cols - 1) / cols;
    _gridScroll.contentSize = (CGSize){cols*cellSize, rows*cellSize};

    for (int i = 0; i < (int)visible.count; i++) {
        int defIdx = [visible[i] intValue];
        MWBItemDef def = gItems[defIdx];
        int r = i/cols, c = i%cols;
        MWBEMICell *cell = [[MWBEMICell alloc] initWithFrame:(CGRect){{c*cellSize,r*cellSize},{cellSize,cellSize}}];
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
        NSInteger itemId = def.itemId;
        cell.onTap = ^{
            if (MWBVariantCount((int)itemId) > 0) {
                MWBDLog(@"[EMI调试] 单击 %@ (多变体, 打开选择面板)", cn);
                [ws showVariantForId:(int)itemId];
            } else {
                MWBDLog(@"[EMI调试] 单击 %@ (给予1个, id=%ld)", cn, (long)itemId);
                MWBGiveItem((int)itemId, 1, 0);
            }
        };
        cell.onDoubleTap = ^{
            MWBDLog(@"[EMI调试] 双击 %@ (给予%ld个, id=%ld)", cn, (long)stack, (long)itemId);
            MWBGiveItem((int)itemId, (int)stack, 0);
        };
        cell.onLongPress = ^{
            MWBDLog(@"[EMI调试] 长按 %@ (查看配方)", cn);
            [ws showRecipeForId:(int)itemId];
        };
        [_gridScroll addSubview:cell];
    }
}

#pragma mark - 底部快捷栏

- (void)buildHotbar {
    CGFloat s = kEMIScale;
    CGFloat hbW = 1092*s, hbH = 139*s;
    CGFloat hbX = _window.frame.origin.x + 417*s;
    CGFloat hbY = _window.frame.origin.y + 941*s;
    _hotbar = [[UIView alloc] initWithFrame:(CGRect){{hbX,hbY},{hbW,hbH}}];
    _hotbar.backgroundColor = EMIColor(0xd7,0xde,0xd7);
    _hotbar.layer.borderWidth = 8*s;
    _hotbar.layer.borderColor = EMIColor(0x11,0x11,0x11).CGColor;
    [self addSubview:_hotbar];
    [self addInsetShadow:_hotbar light:EMIColor(0xee,0xf6,0xef) dark:EMIColor(0x69,0x71,0x6b)
                   lightW:6 darkW:6];
    int slots = 9; CGFloat pad = 8*s;
    CGFloat slotW = (hbW-pad*2)/slots, slotH = hbH-pad*2;
    for (int i = 0; i < slots; i++) {
        UIView *slot = [[UIView alloc] initWithFrame:(CGRect){{pad+i*slotW,pad},{slotW,slotH}}];
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
        st.frame = (CGRect){{0,0},{sw,sh}}; sl.frame = (CGRect){{0,0},{sh,sh2}};
        sb.frame = (CGRect){{0,sh2-sh},{sw,sh}}; sr.frame = (CGRect){{sw-sh,0},{sh,sh2}};
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

#pragma mark - 配方查看

- (void)showRecipeForId:(int)itemId {
    MWBRecipePanel *p = [[MWBRecipePanel alloc] initWithFrame:self.bounds resultId:itemId];
    __weak typeof(self) ws = self;
    __weak MWBRecipePanel *wp = p;
    p.onClose = ^{ [ws finishedWithPanel:wp]; };
    [self addSubview:p];
}

#pragma mark - 变体选择

- (void)showVariantForId:(int)itemId {
    MWBVariantPanel *p = [[MWBVariantPanel alloc] initWithFrame:self.bounds itemId:itemId];
    __weak typeof(self) ws = self;
    __weak MWBVariantPanel *wp = p;
    p.onClose = ^{ [ws finishedWithPanel:wp]; };
    [self addSubview:p];
}
// 面板关闭回调 (异步, 避免在手势回调栈里移除视图)
- (void)finishedWithPanel:(UIView *)p {
    [p removeFromSuperview];
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
        self.layer.shadowOffset = (CGSize){5, 5};
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
                [(UIScrollView *)sv setContentOffset:(CGPoint){0, y.floatValue} animated:NO];
            }
        }
    });
}
// 调试用: cycript 调用 [MWBEMIManager giveItem:264 count:1] 或 [MWBEMIManager giveItem:35 count:1 aux:3]
+ (BOOL)giveItem:(int)itemId count:(int)count {
    return MWBGiveItem(itemId, count, 0);
}
+ (BOOL)giveItem:(int)itemId count:(int)count aux:(int)aux {
    return MWBGiveItem(itemId, count, aux);
}
// 调试用: cycript 调用 [MWBEMIManager playerPointer]
+ (void *)playerPointer {
    return gLocalPlayer;
}
- (void)setup {
    if (_emiWindow) return;
    CGSize ss = [UIScreen mainScreen].bounds.size;
    kEMIScale = MIN(ss.width/1920.0, ss.height/1080.0);
    // 预加载贴图
    [MWBTextureAtlas terrainAtlas];
    [MWBTextureAtlas itemsAtlas];
    // 安装物品给予 hook
    MWBInstallGiver();

    _emiWindow = [[EMIOverlayWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
    _emiWindow.windowLevel = UIWindowLevelAlert + 101;
    _emiWindow.backgroundColor = [UIColor clearColor];
    _emiWindow.rootViewController = [[UIViewController alloc] init];
    _emiWindow.rootViewController.view.backgroundColor = [UIColor clearColor];
    _emiWindow.hidden = NO;

    _floatBtn = [[MWBEMIFloatButton alloc] initWithFrame:(CGRect){{12,300},{52,52}}];
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
            [s->_window hide];
            s->_floatBtn.hidden = NO;
            [UIView animateWithDuration:0.15 animations:^{ s->_floatBtn.alpha = 1; }];
        };
        [_window showInView:_emiWindow];
        [UIView animateWithDuration:0.15 animations:^{ ss->_floatBtn.alpha = 0; }
                         completion:^(BOOL f){ ss->_floatBtn.hidden = YES; }];
    }
}
@end
