// MWBYSMRender.mm — YSM 穿戴渲染 (hook HumanoidModel::render, 只影响本地玩家)
// 链路: Documents/mwbmodels/*.ysm → MWBYSMCodec 解码 → MWBYSMModel 建自家 ModelPart 树 → hook 内藏原版画自家。
// 纹理经 GL 句柄现场保存/恢复 (glGetIntegerv + glBindTexture), 不碰 Textures 的 last-bound 缓存, 语义自洽不泄漏。
#import "MWBCommon.h"
#import <UIKit/UIKit.h>
#import <OpenGLES/ES2/gl.h>
#import "MWBYSMCodec.h"
#import "MWBYSMModel.h"

static void *gYSMRoot = NULL;     // 自家 ModelPart 树根 (堆内存)
static unsigned gYSMTex = 0;      // 自家 GL 纹理名
static NSString *gYSMFile = nil;  // 已加载的文件名 (日志用)

// 模型目录 (自家 Documents/mwbmodels, 与游戏存档无关)
static NSURL *MWBYSMDir(void) {
    NSURL *docs = [[NSFileManager defaultManager] URLForDirectory:NSDocumentDirectory
                                                         inDomain:NSUserDomainMask
                                                appropriateForURL:nil
                                                           create:YES
                                                            error:nil];
    NSURL *d = [docs URLByAppendingPathComponent:@"mwbmodels" isDirectory:YES];
    [[NSFileManager defaultManager] createDirectoryAtURL:d
                             withIntermediateDirectories:YES
                                              attributes:nil
                                                   error:nil];
    return d;
}

// 加载目录下第一个 .ysm (按名排序, v1 只单模型)
void MWBYSMReload(void) {
    if (gYSMRoot) { [MWBYSMModel freeTree:gYSMRoot]; gYSMRoot = NULL; gYSMTex = 0; gYSMFile = nil; }
    NSError *e = nil;
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:MWBYSMDir()
                                                   includingPropertiesForKeys:nil
                                                                      options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                        error:&e];
    NSMutableArray *ysms = [NSMutableArray new];
    for (NSURL *u in files)
        if ([[u.pathExtension lowercaseString] isEqualToString:@"ysm"]) [ysms addObject:u];
    [ysms sortUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        return [a.lastPathComponent compare:b.lastPathComponent];
    }];
    if (ysms.count == 0) {
        MWBLogFile(@"[YSM] 目录无模型: %@", MWBYSMDir().path);
        return;
    }
    NSURL *u = ysms[0];
    MWBLogFile(@"[YSM] 开始解码 %@ (%lld 字节)", u.lastPathComponent,
               [[[NSFileManager defaultManager] attributesOfItemAtPath:u.path error:nil][NSFileSize] longLongValue]);
    NSArray *bones = nil; NSData *png = nil; int tw = 0, th = 0;
    if (![MWBYSMCodec loadYSM:u bones:&bones texturePNG:&png texW:&tw texH:&th error:&e] || !bones || !png) {
        MWBLogFile(@"[YSM] 解码失败 %@: %@", u.lastPathComponent, e.localizedDescription);
        return;
    }
    MWBLogFile(@"[YSM] 解码完成: %lu 骨, 贴图 %d 字节 %dx%d, 开始建树",
               (unsigned long)bones.count, (int)png.length, tw, th);
    UIImage *img = [UIImage imageWithData:png];
    if (!img) { MWBLogFile(@"[YSM] 贴图损坏: %@", u.lastPathComponent); return; }
    unsigned tex = 0;
    void *root = [MWBYSMModel buildWithBones:bones texW:tw texH:th textureGL:&tex image:img];
    if (!root) { MWBLogFile(@"[YSM] 建树失败: %@", u.lastPathComponent); return; }
    gYSMRoot = root; gYSMTex = tex; gYSMFile = [u.lastPathComponent copy];
    MWBLogFile(@"[YSM] 已加载 %@: %lu 骨, 贴图 %dx%d tex=%u",
               gYSMFile, (unsigned long)bones.count, tw, th, tex);
}

// 测试通道: 直接读 .geo.json (Bedrock 标准格式, NSJSONSerialization 解析),
// 先用 1 盒小模型验证渲染链, 再攻全精度 .ysm (tick 线程同步建树会冻屏, 故先小后大)
void MWBYSMReloadGeo(void) {
    if (gYSMRoot) { [MWBYSMModel freeTree:gYSMRoot]; gYSMRoot = NULL; gYSMTex = 0; gYSMFile = nil; }
    NSError *e = nil;
    NSArray *files = [[NSFileManager defaultManager] contentsOfDirectoryAtURL:MWBYSMDir()
                                                   includingPropertiesForKeys:nil
                                                                      options:NSDirectoryEnumerationSkipsHiddenFiles
                                                                        error:&e];
    NSMutableArray *geos = [NSMutableArray new];
    for (NSURL *u in files)
        if ([u.pathExtension.lowercaseString isEqualToString:@"json"]) [geos addObject:u];
    [geos sortUsingComparator:^NSComparisonResult(NSURL *a, NSURL *b) {
        return [a.lastPathComponent compare:b.lastPathComponent];
    }];
    if (geos.count == 0) { MWBLogFile(@"[YSM] 目录无 geo.json"); return; }
    NSURL *u = geos[0];
    NSData *jd = [NSData dataWithContentsOfURL:u options:0 error:&e];
    if (!jd) { MWBLogFile(@"[YSM] 读失败 %@: %@", u.lastPathComponent, e.localizedDescription); return; }
    NSDictionary *geo = [NSJSONSerialization JSONObjectWithData:jd options:0 error:&e];
    if (![geo isKindOfClass:[NSDictionary class]]) { MWBLogFile(@"[YSM] JSON 坏: %@", u.lastPathComponent); return; }
    NSArray *arr = geo[@"minecraft:geometry"];
    NSDictionary *g0 = ([arr isKindOfClass:[NSArray class]] && arr.count > 0) ? arr[0] : nil;
    if (!g0) { MWBLogFile(@"[YSM] 无 geometry: %@", u.lastPathComponent); return; }
    int tw = [g0[@"description"][@"texture_width"] intValue];
    int th = [g0[@"description"][@"texture_height"] intValue];
    if (tw <= 0) tw = 64; if (th <= 0) th = 64;
    // 与解码器输出同形: uv 面名 → @[u,v,du,dv] 像素
    NSMutableArray *bones = [NSMutableArray new];
    for (NSDictionary *b in (NSArray *)g0[@"bones"]) {
        if (![b isKindOfClass:[NSDictionary class]]) continue;
        NSMutableArray *cubes = [NSMutableArray new];
        for (NSDictionary *c in (NSArray *)b[@"cubes"]) {
            if (![c isKindOfClass:[NSDictionary class]]) continue;
            NSMutableDictionary *uvm = [NSMutableDictionary new];
            NSDictionary *uv = c[@"uv"];
            if ([uv isKindOfClass:[NSDictionary class]]) {
                for (NSString *face in uv) {
                    NSDictionary *f = uv[face];
                    if (![f isKindOfClass:[NSDictionary class]]) continue;
                    NSArray *o = f[@"uv"], *s = f[@"uv_size"];
                    if ([o isKindOfClass:[NSArray class]] && [s isKindOfClass:[NSArray class]]
                        && o.count >= 2 && s.count >= 2)
                        uvm[face] = @[o[0], o[1], s[0], s[1]];
                }
            }
            [cubes addObject:@{@"origin": c[@"origin"] ?: @[@0,@0,@0],
                               @"size": c[@"size"] ?: @[@1,@1,@1],
                               @"pivot": c[@"pivot"] ?: (b[@"pivot"] ?: @[@0,@0,@0]),
                               @"rotation": c[@"rotation"] ?: @[@0,@0,@0],
                               @"uv": uvm}];
        }
        [bones addObject:@{@"name": b[@"name"] ?: @"unnamed",
                           @"parent": b[@"parent"] ?: @"",
                           @"pivot": b[@"pivot"] ?: @[@0,@0,@0],
                           @"rotation": b[@"rotation"] ?: @[@0,@0,@0],
                           @"cubes": cubes}];
    }
    // 同目录找同名 png, 没有就用 1x1 白点 (纯几何验证)
    NSString *pngName = [[u.lastPathComponent stringByDeletingPathExtension]
                         stringByAppendingPathExtension:@"png"];
    NSURL *pu = [u.URLByDeletingLastPathComponent URLByAppendingPathComponent:pngName];
    NSData *png = [NSData dataWithContentsOfURL:pu options:0 error:nil];
    UIImage *img = png ? [UIImage imageWithData:png] : nil;
    if (!img) {
        uint8_t px[4] = {255, 255, 255, 255};
        CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
        CGContextRef ctx = CGBitmapContextCreate((void *)px, 1, 1, 8, 4, cs,
                                                kCGImageAlphaPremultipliedLast);
        CGImageRef cg = CGBitmapContextCreateImage(ctx);
        img = [UIImage imageWithCGImage:cg];
        CGImageRelease(cg); CGContextRelease(ctx); CGColorSpaceRelease(cs);
    }
    unsigned tex = 0;
    void *root = [MWBYSMModel buildWithBones:bones texW:tw texH:th textureGL:&tex image:img];
    if (!root) { MWBLogFile(@"[YSM] geo 建树失败: %@", u.lastPathComponent); return; }
    gYSMRoot = root; gYSMTex = tex; gYSMFile = [u.lastPathComponent copy];
    MWBLogFile(@"[YSM] 已加载 geo %@: %lu 骨 tex=%u", gYSMFile, (unsigned long)bones.count, tex);
}

typedef void (*HModelRenderFn)(void *self, void *entity,
                               float f1, float f2, float f3, float f4, float f5, float f6);
static HModelRenderFn orig_hmodel_render = NULL;

static void hooked_hmodel_render(void *self, void *entity,
                                 float f1, float f2, float f3, float f4, float f5, float f6) {
    // 只接管本地玩家 + 已加载模型；其余实体/未加载走原路零影响
    if (gYSM && gYSMRoot && gYSMTex && entity && entity == gLocalPlayer) {
        [MWBYSMModel setVanillaHidden:self hide:YES];   // 藏六件套 (幂等)
        orig_hmodel_render(self, entity, f1, f2, f3, f4, f5, f6);  // setup 照跑, 部件被藏画不出
        MWBLogFile(@"[YSM] 原版走完");
        GLint prev = 0;
        glGetIntegerv(GL_TEXTURE_BINDING_2D, &prev);
        glBindTexture(GL_TEXTURE_2D, (GLuint)gYSMTex);
        MWBLogFile(@"[YSM] 纹理已绑 tex=%u", gYSMTex);
        [MWBYSMModel renderTree:gYSMRoot scale:f6];
        MWBLogFile(@"[YSM] 自家树画完");
        glBindTexture(GL_TEXTURE_2D, (GLuint)prev);    // 经句柄恢复, 缓存依旧自洽
        return;
    }
    if (entity && entity == gLocalPlayer)
        [MWBYSMModel setVanillaHidden:self hide:NO];    // 关断恢复 (幂等, 防粘藏)
    orig_hmodel_render(self, entity, f1, f2, f3, f4, f5, f6);
}

// 0.10 才安装 (%ctor 调用, 版本不对直接返回)
void MWBYSMInstall(void) {
    if (gGV != (int)MWBGameV0_10) return;
    MWB_HOOK("__ZN13HumanoidModel6renderER6Entityffffff",
             hooked_hmodel_render, orig_hmodel_render);
    MWBLogFile(@"[YSM] 渲染接管就绪, 模型目录: %@", MWBYSMDir().path);
}
