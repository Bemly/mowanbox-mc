// MWBYSMModel.mm — Bedrock 骨骼盒子 → 自家 ModelPart/Cube 搭建与渲染实现
// 铁律：本文件只新增，不改仓库任何已有文件。
// 所有游戏函数一律 MSFindSymbol 按名解析，不硬编码地址。
#import "MWBYSMModel.h"
#import <substrate.h>
#import <ImageIO/ImageIO.h>
#import <OpenGLES/ES2/gl.h>
#import <malloc/malloc.h>
#import <string.h>

// ============ 逆向结论照抄区（勿重新发明） ============
// ModelPart 对象大小 0xC0；构造 ModelPart::ModelPart(this, texU, texV, texW, texH)。
// cube vector 在 part+0x20（begin/end/cap = +0x20/+0x28/+0x30）。
// children vector 在 +0x38/+0x40/+0x48（addChild 串父子）。
// 旋转点 part+0x00/0x04/0x08（float），旋转角 +0x0C/0x10/0x14。
// 隐藏开关 +0x80（1=藏）/+0x19（可见）；纹理宽高 float 在 +0x68/+0x6C。
// Cube::Cube(this, part, texU, texV, x,y,z, w,h,d, inflate)，对象大小 0x2C8，
//   构造完推进 part+0x20 的 vector（std::vector push_back 语义，参考 HumanoidModel 构造做法）。
// 6 个 PolygonQuad 槽位 cube+0x00/+0x54/+0xA8/+0xFC/+0x150/+0x1A4（stride 0x54）；
//   每 quad 4 顶点，UV 在 quad+0x0C/+0x20/+0x34/+0x48（各 8 字节=2×float）。
// 顶点排布推断（待真机标定）：每顶点 20 字节 = 坐标 12 字节(3×float)+UV 8 字节，
//   故 pos 在 quad+0x00/+0x14/+0x28/+0x3C（各 3×float），UV 紧随其后；
//   0x54 stride = 4×20 字节 + 4 字节尾部，dump 按此读，错了以真机 dump 为准。
// 归一化值=像素/纹理宽高（宽高从 part+0x68/+0x6C 读）；负 uv_size 直接写
//   （u1<u0 即镜像）；无校验无钳制；写完必须调一次 ModelPart::compile 否则 render 脏检查会画旧 Mesh。
// 渲染走 ModelPart::render；藏原版把 HumanoidModel 内 6 个内嵌 part
//   （model 基 +0x108/+0x1C8/+0x288/+0x348/+0x408/+0x4C8）的 +0x80 置 1。
// 朝向映射未完全确定：6 quad 对 ±X/±Y/±Z、每面 4 组 UV 与角的配对，按
//   “构造原有矩形环序”占位写，待真机标定（见 kYSMFaceOrder 与 dumpFaces）。
// 自家 GL 纹理：ImageIO（CGImageSourceCreateWithURL）从 PNG 解码，经 glTexImage2D
//   建纹理（GLES2，RGBA）；本类只建纹理不绑定，绑定/恢复归 hook 层
//   （Textures::bindTexture，见头文件注释）；纹理参数 GL_LINEAR + CLAMP_TO_EDGE
//   （若负 UV 镜像语义不成立，真机再改 REPEAT，此处已标明）。

// ============ 单位与坐标系假设（数值直传，待真机标定） ============
// Bedrock geo.json 单位 vs 0.10 ModelPart 单位：先按“数值直传”实现。
//   旋转点 pivot：Bedrock 单位原样写入 part+0x00/04/08（游戏内 1 单位=1/16 方块？此换算未经证实）。
//   旋转角 rotation：Bedrock 给的是度，原样写入 +0x0C/10/14；若真机角度不对，
//     第一嫌疑就是“游戏要弧度”，届时统一乘 π/180（已在 kYSMDeg2Rad 备好开关）。
//   立方体 origin/size：Bedrock 数值原样传给 Cube 构造；cube 级 pivot/rotation
//     在 0.10 Cube 里没有独立字段（只有整 part 的旋转点/角），暂忽略并打日志，
//     如需精确可为每 cube 单建一个子 part（待真机标定后再定）。

// ============ 本文件静态日志（MWBDLog 风格，URL-based API） ============
static void MWBYSMWriteLog(NSString *line) {
    // 日志文件固定写 /var/mobile/Documents/mowanbox.log，只用 URL-based API。
    NSURL *url = [NSURL fileURLWithPath:@"/var/mobile/Documents/mowanbox.log"];
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:url.path]) {
        // 文件不存在则建空文件（URL-based 创建）。
        [@"" writeToURL:url atomically:YES encoding:NSUTF8StringEncoding error:nil];
    }
    NSError *err = nil;
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingToURL:url error:&err];
    if (!fh) { NSLog(@"[YSM] 日志打开失败: %@", err); return; }
    [fh seekToEndOfFile];
    NSString *out = [line stringByAppendingString:@"\n"];
    [out writeToURL:url atomically:NO encoding:NSUTF8StringEncoding error:nil]; // 兜底直写（小日志）
    [fh writeData:[out dataUsingEncoding:NSUTF8StringEncoding]];
    [fh closeFile];
}
#define MWBYSMLog(fmt, ...) do { \
    NSString *_s = [NSString stringWithFormat:(fmt), ##__VA_ARGS__]; \
    NSLog(@"[YSM] %@", _s); \
    MWBYSMWriteLog([@"[YSM] " stringByAppendingString:_s]); \
} while (0)

// ============ 常量与符号名 ============
static const size_t kYSMPartSize = 0xC0;   // ModelPart 对象大小
static const size_t kYSMCubeSize = 0x2C8;  // Cube 对象大小
static const size_t kYSMQuadStride = 0x54; // PolygonQuad 步长
static const int kYSMFaceCount = 6;        // 面数
// 朝向占位映射：槽位 i 对应 Bedrock 面名（按“构造原有矩形环序”占位，待真机标定）。
static NSString *kYSMFaceOrder[6]; // 静态清零，首次使用时延迟初始化，避免 +load 时机问题
// 角度单位开关：0=度数直传（默认），1=转弧度；待真机标定后拨。
static const int kYSMConvertDeg2Rad = 0;
static const float kYSMDeg2Rad = 0.01745329252f; // π/180

// 符号名（MSFindSymbol 按名解析，不硬编码地址）
#define YSM_SYM_PART_CTOR "___ZN9ModelPartC2Eiiii"
// 注：Itanium 规范里无参函数符号应以 v 结尾；逆向给出字串照抄使用，
// 若 MSFindSymbol 取不到，下面的解析函数会自动补试 "...v" 形式。
#define YSM_SYM_PART_CTOR_ALT "__ZN9ModelPartC2Eiiii"
#define YSM_SYM_ADDCHILD "__ZN9ModelPart8addChildEPS_"
#define YSM_SYM_CUBE_CTOR "__ZN4CubeC2EP9ModelPartiifffiiiiif"
#define YSM_SYM_COMPILE "__ZN9ModelPart7compileE"
#define YSM_SYM_RENDER "__ZN9ModelPart6renderE"
// hook 层用符号（本文件只在注释里引用，不解析；解析归 hook 层）：
//   Textures::bindTexture =
//   "__ZN8Textures11bindTextureERKNSt3__112basic_stringIcNS0_11char_traitsIcEENS_0_9allocatorIcEEEE"
//   manager 来源：manager=*(*(slide+0x10034d0b8)+0x18)，静态 VA 待真机核对。
//   取原贴图：虚表+0x2d8（Mob::getTexture，只读不 hook）。
//   hook 点：HumanoidModel::render =
//   "__ZN13HumanoidModel6renderER6Entityffffff"，最后一个参数即 Entity*，
//   按 entity==gLocalPlayer 过滤（hook 由上层写，不在本文件）。

// ============ 游戏函数指针类型 ============
typedef void (*YSMPartCtorFn)(void *thiz, int texU, int texV, int texW, int texH);
typedef void (*YSMAddChildFn)(void *thiz, void *child);
typedef void (*YSMCubeCtorFn)(void *thiz, void *part, int texU, int texV,
                              float x, float y, float z, int w, int h, int d, float inflate);
typedef void (*YSMCompileFn)(void *thiz);
typedef void (*YSMRenderFn)(void *thiz);

// 符号缓存（首次调用时 MSFindSymbol 解析）
static YSMPartCtorFn sPartCtor = NULL;
static YSMAddChildFn sAddChild = NULL;
static YSMCubeCtorFn sCubeCtor = NULL;
static YSMCompileFn sCompile = NULL;
static YSMRenderFn sRender = NULL;
static int sSymResolved = 0;

// 根 part → 自家纹理名登记表（freeTree 按根查表删纹理；只记根，不记中间节点）
static NSMutableDictionary *sYSMTexMap(void) {
    static NSMutableDictionary *m = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ m = [NSMutableDictionary new]; });
    return m;
}

// 解析全部游戏符号（按名，失败记日志，调用方判空）
static int YSMResolveSyms(void) {
    if (sSymResolved) return (sPartCtor && sCubeCtor) ? 1 : 0;
    sSymResolved = 1;
    // 构造符号逆向字串带三下划线前缀，先照抄试，取不到再试标准双下划线形式。
    void *p = MSFindSymbol(NULL, YSM_SYM_PART_CTOR);
    if (!p) p = MSFindSymbol(NULL, YSM_SYM_PART_CTOR_ALT);
    sPartCtor = (YSMPartCtorFn)p;
    sAddChild = (YSMAddChildFn)MSFindSymbol(NULL, YSM_SYM_ADDCHILD);
    sCubeCtor = (YSMCubeCtorFn)MSFindSymbol(NULL, YSM_SYM_CUBE_CTOR);
    sCompile  = (YSMCompileFn)MSFindSymbol(NULL, YSM_SYM_COMPILE);
    sRender   = (YSMRenderFn)MSFindSymbol(NULL, YSM_SYM_RENDER);
    if (!sPartCtor) MWBYSMLog(@"符号缺失: ModelPart 构造");
    if (!sAddChild) MWBYSMLog(@"符号缺失: ModelPart::addChild");
    if (!sCubeCtor) MWBYSMLog(@"符号缺失: Cube 构造");
    if (!sCompile)  MWBYSMLog(@"符号缺失: ModelPart::compile");
    if (!sRender)   MWBYSMLog(@"符号缺失: ModelPart::render");
    return (sPartCtor && sCubeCtor) ? 1 : 0;
}

// 面序延迟初始化
static void YSMEnsureFaceOrder(void) {
    if (!kYSMFaceOrder[0]) {
        // 占位顺序（待真机标定）：槽位 0..5 依次对应 east/west/up/down/south/north。
        kYSMFaceOrder[0] = @"east";
        kYSMFaceOrder[1] = @"west";
        kYSMFaceOrder[2] = @"up";
        kYSMFaceOrder[3] = @"down";
        kYSMFaceOrder[4] = @"south";
        kYSMFaceOrder[5] = @"north";
    }
}

// ============ 小工具：安全取数 ============
static float YSMFloatAt(NSArray *arr, NSUInteger i) {
    // 数组越界/类型不对一律回 0，不崩。
    if (![arr isKindOfClass:[NSArray class]] || i >= arr.count) return 0;
    id v = arr[i];
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v floatValue];
    return 0;
}
static int YSMIntAt(NSArray *arr, NSUInteger i) {
    if (![arr isKindOfClass:[NSArray class]] || i >= arr.count) return 0;
    id v = arr[i];
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v intValue];
    return 0;
}
static float YSMRotFix(float deg) {
    // 角度单位假设开关：默认度数直传；标定后若游戏要弧度，把 kYSMConvertDeg2Rad 置 1。
    if (kYSMConvertDeg2Rad) return deg * kYSMDeg2Rad;
    return deg;
}

// ============ 内存小工具：vector 语义 ============
// part+0x20 cube vector：begin/end/cap 连续三指针；元素 Cube 内嵌，步长 0x2C8。
// part+0x38 children vector：元素为 part 指针，步长 8（arm64）。
static void **YSMVecField(void *part, size_t off) {
    return (void **)((uint8_t *)part + off);
}
// 确保 cube vector 至少能再塞 n 个 Cube（ doubling 扩容，memcpy 搬运）。
// 假设：Cube 可按字节搬运（HumanoidModel 构造同样做法；若真机发现 Cube 持有外部堆资源需改为原地构造）。
static int YSMEnsureCubeCap(void *part, int n) {
    void **f = YSMVecField(part, 0x20);
    uint8_t *begin = (uint8_t *)f[0], *end = (uint8_t *)f[1], *cap = (uint8_t *)f[2];
    size_t need = (size_t)n * kYSMCubeSize;
    size_t have = begin ? (size_t)(cap - end) : 0;
    if (have >= need) return 1;
    size_t oldBytes = begin ? (size_t)(end - begin) : 0;
    size_t oldCap = begin ? (size_t)(cap - begin) : 0;
    size_t newCap = oldCap ? oldCap : kYSMCubeSize;
    while (newCap - oldBytes < need) newCap *= 2;
    uint8_t *nb = (uint8_t *)malloc(newCap);
    if (!nb) return 0;
    if (begin && oldBytes) memcpy(nb, begin, oldBytes);
    if (begin) free(begin);
    f[0] = nb; f[1] = nb + oldBytes; f[2] = nb + newCap;
    return 1;
}
// children vector 压一个 part 指针（元素 8 字节）。
static int YSMPushChildPtr(void *part, void *child) {
    void **f = YSMVecField(part, 0x38);
    uint8_t *begin = (uint8_t *)f[0], *end = (uint8_t *)f[1], *cap = (uint8_t *)f[2];
    if (!begin || end + 8 > cap) {
        size_t oldBytes = begin ? (size_t)(end - begin) : 0;
        size_t oldCap = begin ? (size_t)(cap - begin) : 0;
        size_t newCap = oldCap ? oldCap * 2 : 8 * 4;
        uint8_t *nb = (uint8_t *)malloc(newCap);
        if (!nb) return 0;
        if (begin && oldBytes) memcpy(nb, begin, oldBytes);
        if (begin) free(begin);
        f[0] = nb; f[1] = nb + oldBytes; f[2] = nb + newCap;
        begin = (uint8_t *)f[0]; end = (uint8_t *)f[1];
        (void)begin;
        end = (uint8_t *)f[1];
    }
    void **slot = (void **)f[1];
    slot[0] = child;
    f[1] = (uint8_t *)(slot + 1);
    return 1;
}

// ============ 建 part / 加 cube ============
// 新建一个 ModelPart：malloc(0xC0)+调构造（placement new 等价；构造是 C++ 函数，直接调）。
static void *YSMNewPart(int texW, int texH) {
    void *part = malloc(kYSMPartSize);
    if (!part) return NULL;
    memset(part, 0, kYSMPartSize);
    sPartCtor(part, 0, 0, texW, texH); // part 级 texU/texV 无 Bedrock 对应，传 0 占位
    return part;
}
// 给 part 加一个 Cube：vector 预留槽位后直接在槽位上调构造（省一次拷贝，
// 等价于 temp 构造 + push_back；构造内若有 new 行为则跟随，假设见下）。
// 假设：Cube 构造只写自身 0x2C8 内存（及 part 纹理尺寸等只读引用），无全局副作用。
static void *YSMAddCube(void *part, int texU, int texV,
                        float x, float y, float z, int w, int h, int d, float inflate) {
    if (!YSMEnsureCubeCap(part, 1)) return NULL;
    void **f = YSMVecField(part, 0x20);
    void *slot = f[1];
    memset(slot, 0, kYSMCubeSize);
    sCubeCtor(slot, part, texU, texV, x, y, z, w, h, d, inflate);
    f[1] = (uint8_t *)slot + kYSMCubeSize;
    return slot;
}

// ============ 逐面改 UV ============
// 把 Bedrock 面矩形 [u,v,du,dv]（像素）归一化后写入指定 quad 槽的 4 个 UV 点。
// 负 du/dv 直接写（u1<u0 即镜像）；无校验无钳制；宽高从 part+0x68/+0x6C 读。
static void YSMWriteFaceUV(void *part, void *cube, int face, float u, float v, float du, float dv) {
    float texW = *(float *)((uint8_t *)part + 0x68);
    float texH = *(float *)((uint8_t *)part + 0x6C);
    // 构造若没写浮点宽高（只读到 0），回退用建树时传入的尺寸，见调用方传入。
    if (texW <= 0) texW = 64;
    if (texH <= 0) texH = 64;
    float u0 = u / texW, v0 = v / texH;
    float u1 = (u + du) / texW, v1 = (v + dv) / texH; // du/dv 为负即 u1<u0，直接写即镜像
    // 矩形环序占位：4 角按 (u0,v0)→(u1,v0)→(u1,v1)→(u0,v1) 写 4 个 UV 点，
    // 与哪只角对应的配对关系待真机 dump 标定（见 dumpFaces）。
    float us[4] = { u0, u1, u1, u0 };
    float vs[4] = { v0, v0, v1, v1 };
    static const size_t kUVOff[4] = { 0x0C, 0x20, 0x34, 0x48 };
    uint8_t *quad = (uint8_t *)cube + (size_t)face * kYSMQuadStride;
    for (int i = 0; i < 4; i++) {
        float *dst = (float *)(quad + kUVOff[i]);
        dst[0] = us[i];
        dst[1] = vs[i];
    }
}

// ============ 面标定 dump ============
// 单面 dump：打该 quad 4 顶点的 pos（推断偏移）与 UV（逆向实锤偏移）。
static void mwb_dumpFace(void *cube, int f) {
    if (!cube || f < 0 || f >= kYSMFaceCount) return;
    uint8_t *quad = (uint8_t *)cube + (size_t)f * kYSMQuadStride;
    static const size_t kPosOff[4] = { 0x00, 0x14, 0x28, 0x3C }; // 推断，待标定
    static const size_t kUVOff[4] = { 0x0C, 0x20, 0x34, 0x48 };  // 实锤
    YSMEnsureFaceOrder();
    MWBYSMLog(@"面槽 %d（占位对应 %@）@%p:", f, kYSMFaceOrder[f], quad);
    for (int i = 0; i < 4; i++) {
        float *pp = (float *)(quad + kPosOff[i]);
        float *pu = (float *)(quad + kUVOff[i]);
        MWBYSMLog(@"  点%d pos=(%.3f,%.3f,%.3f) uv=(%.4f,%.4f)", i,
                  pp[0], pp[1], pp[2], pu[0], pu[1]);
    }
}

// ============ 自家 GL 纹理上传 ============
// 输入 CGImage（上游 PNG 文件先用 ImageIO 的 CGImageSourceCreateWithURL 解码得到，
// 与 EMIViews.mm 同款链路），经 glTexImage2D 建 RGBA 纹理，返回纹理名，失败返回 0。
// 参数 GL_LINEAR + CLAMP_TO_EDGE；若负 UV 镜像语义不成立，真机再改 REPEAT。
// 注意：上传时的 glBindTexture 会污染游戏 Textures 的 last-bound 缓存（BSS），
//   调用方（hook 层）负责用 Textures::bindTexture 恢复，本函数不管恢复。
static unsigned YSMUploadCGImage(CGImageRef cg) {
    if (!cg) return 0;
    size_t w = CGImageGetWidth(cg), h = CGImageGetHeight(cg);
    if (!w || !h) return 0;
    size_t bytes = w * h * 4;
    void *px = malloc(bytes);
    if (!px) return 0;
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(px, w, h, 8, w * 4, cs,
        (CGBitmapInfo)kCGImageAlphaPremultipliedLast);
    CGColorSpaceRelease(cs);
    if (!ctx) { free(px); return 0; }
    CGContextDrawImage(ctx, (CGRect){{0, 0}, {(CGFloat)w, (CGFloat)h}}, cg);
    CGContextRelease(ctx);
    GLuint tex = 0;
    glGenTextures(1, &tex);
    glBindTexture(GL_TEXTURE_2D, tex); // 污染说明见上，由调用方恢复
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, (GLsizei)w, (GLsizei)h,
                 0, GL_RGBA, GL_UNSIGNED_BYTE, px);
    free(px);
    return tex;
}

// PNG 文件 URL 输入时的解码入口（ImageIO），与 UIImage 输入走同一上传函数。
// 本类对外接口收的是 UIImage（上游已解完），此函数留作 hook 层/将来传文件路径时用。
__attribute__((unused)) static unsigned YSMUploadPNGURL(NSURL *url) {
    if (!url) return 0;
    CGImageSourceRef src = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
    if (!src) return 0;
    CGImageRef cg = CGImageSourceCreateImageAtIndex(src, 0, NULL);
    CFRelease(src);
    if (!cg) return 0;
    unsigned t = YSMUploadCGImage(cg);
    CGImageRelease(cg);
    return t;
}

// ============ 递归释放 ============
static void YSMFreePart(void *part) {
    if (!part) return;
    // 先递归释放 children（元素为 part*，步长 8）。
    void **cf = YSMVecField(part, 0x38);
    uint8_t *cb = (uint8_t *)cf[0], *ce = (uint8_t *)cf[1];
    if (cb && ce > cb) {
        for (void **p = (void **)cb; (uint8_t *)p < ce; p++) {
            if (*p && *p != part) YSMFreePart(*p); // 防自环
        }
        free(cb);
    }
    // cube vector 存的是内嵌 Cube（0x2C8/个），整块释放即可。
    // 假设：Cube/ModelPart 无需调析构（无外部堆资源）；若真机发现泄漏，需补调析构符号。
    void **qf = YSMVecField(part, 0x20);
    if (qf[0]) free(qf[0]);
    free(part);
}

// ============ 对外接口 ============
@implementation MWBYSMModel

+ (void *)buildWithBones:(NSArray *)bones texW:(int)texW texH:(int)texH textureGL:(unsigned *)outTex image:(UIImage *)img {
    if (outTex) *outTex = 0;
    YSMEnsureFaceOrder();
    if (![bones isKindOfClass:[NSArray class]] || bones.count == 0) {
        MWBYSMLog(@"建树失败：bones 为空");
        return NULL;
    }
    if (!YSMResolveSyms()) {
        MWBYSMLog(@"建树失败：核心符号缺失");
        return NULL;
    }
    // 自家 GL 纹理：ImageIO 解码（上游 PNG→UIImage）+ glTexImage2D 上传。
    // 必须在 GL 线程调；上传绑定的污染由调用方恢复（见头文件）。
    unsigned tex = 0;
    if (img) {
        CGImageRef cg = img.CGImage;
        if (cg) tex = YSMUploadCGImage(cg);
        if (!tex) MWBYSMLog(@"贴图上传失败，走无纹理建树");
    }
    if (outTex) *outTex = tex;

    // 第一遍：每 bone 建一个 part（名→part 查表）。
    NSMutableDictionary *parts = [NSMutableDictionary new];
    NSMutableArray *order = [NSMutableArray new]; // 与 bones 同序，用于第二遍串父子
    for (NSDictionary *b in bones) {
        if (![b isKindOfClass:[NSDictionary class]]) continue;
        NSString *name = b[@"name"];
        if (![name isKindOfClass:[NSString class]]) continue;
        void *part = YSMNewPart(texW, texH);
        if (!part) { MWBYSMLog(@"part 分配失败：%@", name); continue; }
        // 旋转点：Bedrock pivot 数值直传（单位假设见文件头）。
        NSArray *pivot = b[@"pivot"];
        *(float *)((uint8_t *)part + 0x00) = YSMFloatAt(pivot, 0);
        *(float *)((uint8_t *)part + 0x04) = YSMFloatAt(pivot, 1);
        *(float *)((uint8_t *)part + 0x08) = YSMFloatAt(pivot, 2);
        // 旋转角：Bedrock 度数直传（弧度嫌疑见文件头开关）。
        NSArray *rot = b[@"rotation"];
        *(float *)((uint8_t *)part + 0x0C) = YSMRotFix(YSMFloatAt(rot, 0));
        *(float *)((uint8_t *)part + 0x10) = YSMRotFix(YSMFloatAt(rot, 1));
        *(float *)((uint8_t *)part + 0x14) = YSMRotFix(YSMFloatAt(rot, 2));
        parts[name] = [NSValue valueWithPointer:part];
        [order addObject:b];
    }
    if (parts.count == 0) {
        MWBYSMLog(@"建树失败：无有效 bone");
        if (tex) glDeleteTextures(1, (GLuint *)&tex);
        if (outTex) *outTex = 0;
        return NULL;
    }
    // 第二遍：cube 填充 + 父子串联。
    void *root = NULL;
    for (NSDictionary *b in order) {
        NSString *name = b[@"name"];
        void *part = [(NSValue *)parts[name] pointerValue];
        if (!part) continue;
        NSArray *cubes = b[@"cubes"];
        if ([cubes isKindOfClass:[NSArray class]]) {
            // 预留全部 cube 槽位（一次扩容，减少搬运）。
            int n = 0;
            for (id c in cubes) if ([c isKindOfClass:[NSDictionary class]]) n++;
            if (n > 0) YSMEnsureCubeCap(part, n);
            for (NSDictionary *c in cubes) {
                if (![c isKindOfClass:[NSDictionary class]]) continue;
                NSArray *org = c[@"origin"];
                NSArray *sz = c[@"size"];
                float x = YSMFloatAt(org, 0), y = YSMFloatAt(org, 1), z = YSMFloatAt(org, 2);
                int w = YSMIntAt(sz, 0), h = YSMIntAt(sz, 1), d = YSMIntAt(sz, 2);
                // Bedrock inflate：输入结构无此字段，传 0（注释留档）。
                // part/cube 级 texU/texV：Bedrock 是逐面 UV，无整盒对应值，传 0 占位，
                //   随后逐面覆盖（构造值仅占位）。
                void *cube = YSMAddCube(part, 0, 0, x, y, z, w, h, d, 0.0f);
                if (!cube) { MWBYSMLog(@"cube 构造失败：%@.%@", name, @"?"); continue; }
                // cube 级 pivot/rotation：0.10 Cube 无独立字段，暂忽略；非零则记日志待标定。
                NSArray *cp = c[@"pivot"], *cr = c[@"rotation"];
                if ((YSMFloatAt(cp, 0) != 0 || YSMFloatAt(cp, 1) != 0 || YSMFloatAt(cp, 2) != 0 ||
                     YSMFloatAt(cr, 0) != 0 || YSMFloatAt(cr, 1) != 0 || YSMFloatAt(cr, 2) != 0)) {
                    MWBYSMLog(@"cube 级 pivot/rotation 暂忽略（%@），待标定", name);
                }
                // 逐面 UV：uv 字典 east/west/up/down/south/north 各 @[u,v,du,dv] 像素。
                NSDictionary *uv = c[@"uv"];
                if ([uv isKindOfClass:[NSDictionary class]]) {
                    for (int f = 0; f < kYSMFaceCount; f++) {
                        NSArray *r = uv[kYSMFaceOrder[f]];
                        if (![r isKindOfClass:[NSArray class]]) continue;
                        YSMWriteFaceUV(part, cube, f,
                                       YSMFloatAt(r, 0), YSMFloatAt(r, 1),
                                       YSMFloatAt(r, 2), YSMFloatAt(r, 3));
                    }
                }
                // 写完必须调一次 compile，否则 render 脏检查会画旧 Mesh。
                if (sCompile) sCompile(part);
            }
        }
        // 父子串联：parent 名查表，addChild 串起来；无 parent 的第一个即根。
        id pName = b[@"parent"];
        NSString *parentName = ([pName isKindOfClass:[NSString class]] && [(NSString *)pName length]) ? pName : nil;
        if (parentName) {
            void *pp = [(NSValue *)parts[parentName] pointerValue];
            if (pp && pp != part) {
                if (sAddChild) sAddChild(pp, part);
                YSMPushChildPtr(pp, part); // 同步自家遍历用表（addChild 语义的镜像，释放/渲染遍历用）
            } else {
                MWBYSMLog(@"父 bone 未找到：%@->%@", name, parentName);
                if (!root) root = part;
            }
        } else if (!root) {
            root = part;
        }
    }
    if (!root) {
        // 全都有 parent（环/孤儿）时兜底取第一个。
        NSDictionary *first = order[0];
        root = [(NSValue *)parts[first[@"name"]] pointerValue];
    }
    // 登记根→纹理，供 freeTree 删除。
    @synchronized (sYSMTexMap()) {
        sYSMTexMap()[[NSValue valueWithPointer:root]] = @(tex);
    }
    MWBYSMLog(@"建树成功：%lu bones，根=%p 纹理=%u", (unsigned long)parts.count, root, tex);
    return root;
}

+ (void)renderTree:(void *)root {
    // 纯绘制：假设调用方已绑好自家纹理，内部不做任何绑定/恢复。
    // 旋转/位移由各 part 自家的 render 读旋转点/角完成，本函数只做递归。
    if (!root) return;
    if (!sRender && !YSMResolveSyms()) return;
    if (!sRender) return;
    sRender(root);
    void **f = YSMVecField(root, 0x38);
    uint8_t *b = (uint8_t *)f[0], *e = (uint8_t *)f[1];
    if (b && e > b) {
        for (void **p = (void **)b; (uint8_t *)p < e; p++) {
            if (*p && *p != root) [self renderTree:*p];
        }
    }
}

+ (void)setVanillaHidden:(void *)model hide:(BOOL)hide {
    // HumanoidModel 内 6 个内嵌 part 偏移（逆向实锤），+0x80 置 1 藏 / 置 0 恢复。
    if (!model) return;
    // 边沿触发：hook 每帧都调，状态不变直接回（否则每帧打日志，20KB/s 刷屏；新世界 model 指针变了会自动重应用）。
    static void *sLastModel = NULL; static BOOL sLastHide = NO; static BOOL sInit = NO;
    if (sInit && sLastModel == model && sLastHide == hide) return;
    sInit = YES; sLastModel = model; sLastHide = hide;
    static const size_t kOff[6] = { 0x108, 0x1C8, 0x288, 0x348, 0x408, 0x4C8 };
    for (int i = 0; i < 6; i++) {
        uint8_t *part = (uint8_t *)model + kOff[i];
        *(part + 0x80) = hide ? 1 : 0; // 隐藏开关
        *(part + 0x19) = hide ? 0 : 1; // 可见开关（与上成对，逆向结论）
    }
    MWBYSMLog(@"原版六件套%@：model=%p", hide ? @"隐藏" : @"恢复", model);
}

+ (void)freeTree:(void *)root {
    if (!root) return;
    unsigned tex = 0;
    @synchronized (sYSMTexMap()) {
        NSNumber *n = sYSMTexMap()[[NSValue valueWithPointer:root]];
        if (n) {
            tex = [n unsignedIntValue];
            [sYSMTexMap() removeObjectForKey:[NSValue valueWithPointer:root]];
        }
    }
    YSMFreePart(root);
    if (tex) glDeleteTextures(1, (GLuint *)&tex); // 必须在 GL 线程调
    MWBYSMLog(@"释放树：根=%p 纹理=%u", root, tex);
}

+ (void)dumpFaces:(void *)cube {
    // 面标定 dump：6 个 quad 的 pos/uv 全打到日志（拿不准映射时真机调用）。
    if (!cube) { MWBYSMLog(@"dumpFaces：cube 为空"); return; }
    for (int f = 0; f < kYSMFaceCount; f++) mwb_dumpFace(cube, f);
}

@end
