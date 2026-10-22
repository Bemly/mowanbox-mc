// MWBSkin4D.mm — 4D皮肤：手搓双立方体替换史蒂夫
// 高性能：无解码无建树无贴图上传，复用当前已绑定的史蒂夫贴图，逐帧只多一次 part 渲染。
// 逆向实锤（kuna 反 0.10，照抄游戏亲传，不自创）：
// - ModelPart::render(矩阵16, part)：脏位自动调 compile，禁手动调 compile。
// - Cube 构造是纯叶子（零 bl）：只写自身 0x2C8，不碰 vector。
// - cube vector 存指针（8 字节步进，compile 解引用），HumanoidModel 亲传：
//   operator new(0x2C8) 单独堆分配 Cube → 原地构造 → 指针 push 进 part+0x20 向量。
// - YSM 两宗罪（已避开）：render 按 (part,float) 调（实为 (矩阵,part)，0.0625 当指针静默死）；
//   cube vector 按内嵌对象搬运（实为指针，解引用飞）。
// - 均匀层缩放 P1 已证死（glinfo calls=1，吃不到矩阵），留桩不动，改走几何替换。
#import "MWBSkin4D.h"
#import "MWBCommon.h"
#import <string.h>
#import <math.h>
#import <dlfcn.h> // render 命中调用者反查用

#define MINI4D_SCALE 0.5f // P1 均匀桩倍率（已证死，留着不动）

BOOL gMiniDrawScope = NO; // P1 均匀桩窗口（不再置位，恒 NO，均匀分支自然 dormant）

// ---- 游戏符号（MSFindSymbol 按名解析，不硬编码地址） ----
typedef void (*MPartCtorFn)(void *thiz, int texU, int texV, int texW, int texH);
typedef void (*MCubeCtorFn)(void *thiz, void *part, int texU, int texV,
                             float x, float y, float z, int w, int h, int d, float inflate);
typedef void (*MAddChildFn)(void *thiz, void *child);
typedef void (*MPartRenderFn)(const float *m16, void *part);
static MPartCtorFn sPartCtor = NULL;
static MCubeCtorFn sCubeCtor = NULL;
static MAddChildFn sAddChild = NULL;
static MPartRenderFn sPartRender = NULL;
static int sSymOK = 0;
static void MWBSkinResolve(void) {
    if (sSymOK) return;
    sSymOK = 1;
    sPartCtor = (MPartCtorFn)MSFindSymbol(NULL, "__ZN9ModelPartC1Eiiii");
    sCubeCtor = (MCubeCtorFn)MSFindSymbol(NULL, "__ZN4CubeC1EP9ModelPartiifffiiif");
    sAddChild = (MAddChildFn)MSFindSymbol(NULL, "__ZN9ModelPart8addChildEPS_");
    sPartRender = (MPartRenderFn)MSFindSymbol(NULL, "__ZN9ModelPart6renderEf");
    if (!sPartCtor || !sCubeCtor || !sAddChild || !sPartRender)
        MWBLogFile(@"[4D皮肤] 符号缺失 part=%p cube=%p add=%p render=%p",
                   sPartCtor, sCubeCtor, sAddChild, sPartRender);
}

// ---- 自家双立方体（建一次，逐帧复用，零每帧分配） ----
static void *sCubeRoot = NULL; // 根 part（1 立方体）+ 子 part（1 立方体）连在一起
static const float kSkinIdentity[16] = {1,0,0,0, 0,1,0,0, 0,0,1,0, 0,0,0,1};

// 手动给 part 的 cube 指针向量塞一个指针（C1 已清零向量，自家 malloc 指针数组拥有）
static void MWBSkinPushCube(void *part, void *cube) {
    void **f = (void **)((char *)part + 0x20);
    uint8_t *begin = (uint8_t *)f[0], *end = (uint8_t *)f[1], *cap = (uint8_t *)f[2];
    if (!begin || end + 8 > cap) { // 首建：直接开能装 2 个指针的数组（本模块最多 1 个/ part）
        uint8_t *nb = (uint8_t *)malloc(16);
        if (!nb) return;
        if (begin) { // 已有则搬走（正常只走一次）
            size_t n = (size_t)(end - begin);
            memcpy(nb, begin, n);
            end = nb + n;
            free(begin);
        } else end = nb;
        f[0] = nb; f[1] = end; f[2] = nb + 16;
        end = (uint8_t *)f[1];
    }
    *(void **)end = cube;
    f[1] = end + 8;
}

static void MWBSkinBuild(void) {
    if (sCubeRoot || !sPartCtor || !sCubeCtor || !sAddChild) return;
    // 根：轴心 (0,12,0)，8 立方体占 y 12..20
    void *root = malloc(0xC0);
    if (!root) return;
    memset(root, 0, 0xC0);
    sPartCtor(root, 0, 0, 64, 64);
    *(float *)((char *)root + 0x00) = 0;
    *(float *)((char *)root + 0x04) = 12;
    *(float *)((char *)root + 0x08) = 0;
    void *cubeA = malloc(0x2C8);
    if (!cubeA) { free(root); return; }
    memset(cubeA, 0, 0x2C8);
    sCubeCtor(cubeA, root, 0, 0, -4.0f, 0.0f, -4.0f, 8, 8, 8, 0.0f);
    MWBSkinPushCube(root, cubeA);
    // 子：相对轴心 (0,8,0)，4 立方体接在根顶上（y 20..24），连在一起
    void *child = malloc(0xC0);
    if (!child) return; // root 已挂，泄漏 1 part 也比野指针强（只走一次）
    memset(child, 0, 0xC0);
    sPartCtor(child, 0, 0, 64, 64);
    *(float *)((char *)child + 0x00) = 0;
    *(float *)((char *)child + 0x04) = 8;
    *(float *)((char *)child + 0x08) = 0;
    void *cubeB = malloc(0x2C8);
    if (!cubeB) return;
    memset(cubeB, 0, 0x2C8);
    sCubeCtor(cubeB, child, 0, 0, -2.0f, 0.0f, -2.0f, 4, 4, 4, 0.0f);
    MWBSkinPushCube(child, cubeB);
    sAddChild(root, child);
    sCubeRoot = root;
    MWBLogFile(@"[4D皮肤] 双立方体建好 root=%p child=%p", root, child);
}

// 原版六件套显隐（HumanoidModel::render hook 内调，self 即 model；
// 偏移 HumanoidModel::render 反编译实锤：model+0x108 起步进 0xC0 六个）
static void MWBSkinSetVanilla(void *model, BOOL hide) {
    if (!model) return;
    static const size_t kOff[6] = {0x108, 0x1C8, 0x288, 0x348, 0x408, 0x4C8};
    for (int i = 0; i < 6; i++)
        ((char *)model)[kOff[i] + 0x80] = hide ? 1 : 0;
}

typedef void (*HModelRenderFn)(void *self, void *entity,
                               float f1, float f2, float f3, float f4, float f5, float f6);
static HModelRenderFn orig_mini_render = NULL;

static void hooked_mini_render(void *self, void *entity,
                               float f1, float f2, float f3, float f4, float f5, float f6) {
    // 本地玩家：树建好才藏（建树失败则永不藏，防隐身史蒂夫）；关则恢复（幂等防粘藏）
    if (entity && entity == gLocalPlayer)
        MWBSkinSetVanilla(self, gSkin4D && sCubeRoot);
    orig_mini_render(self, entity, f1, f2, f3, f4, f5, f6);
}

// 上层透传（占位不断链）
typedef void (*MobRenderFn)(void *self, void *entity, const void *pos, float f1, float f2);
static MobRenderFn orig_mob_render = NULL;
static void hooked_mob_render(void *self, void *entity, const void *pos, float f1, float f2) {
    orig_mob_render(self, entity, pos, f1, f2);
}

// 窗口所有者：HumanoidMobRenderer::render（逐实体）
// 开则先建树（一次），原版走完（已被藏画不出），再画自家双立方体；关则纯原路。
typedef void (*HMobRenderFn)(void *self, void *entity, const void *pos, float f1, float f2);
static HMobRenderFn orig_hmob_render = NULL;
static void hooked_hmob_render(void *self, void *entity, const void *pos, float f1, float f2) {
    if (gSkin4D && entity && entity == gLocalPlayer) {
        MWBSkinResolve();
        if (!sPartRender) { orig_hmob_render(self, entity, pos, f1, f2); return; }
        MWBSkinBuild();
        orig_hmob_render(self, entity, pos, f1, f2);
        if (sCubeRoot) {
            sPartRender(kSkinIdentity, sCubeRoot);
            static BOOL sLogged = NO;
            if (!sLogged) { sLogged = YES; MWBLogFile(@"[4D皮肤] 自家双立方体首渲"); }
        }
        return;
    }
    orig_hmob_render(self, entity, pos, f1, f2);
}

// P1 均匀桩（已证死，留桩不动，恒不命中因为窗口不再置位）
BOOL MWBMini4DScaleMatrix(const float *m, float *out) {
    if (!gSkin4D || !gMiniDrawScope || !m || !out) return NO;
    if (fabsf(m[3]) > 1e-6f || fabsf(m[7]) > 1e-6f || fabsf(m[11]) > 1e-6f) return NO;
    if (fabsf(m[15] - 1.0f) > 1e-6f) return NO;
    memcpy(out, m, sizeof(float) * 16);
    static const int kCols[] = {0, 1, 2, 4, 5, 6, 8, 9, 10};
    for (int i = 0; i < 9; i++) out[kCols[i]] *= MINI4D_SCALE;
    return YES;
}

// 0.10 才安装（%ctor 调用，版本不对直接返回）
void MWBSkin4DInstall(void) {
    if (gGV != (int)MWBGameV0_10) return;
    MWB_HOOK("__ZN13HumanoidModel6renderER6Entityffffff",
             hooked_mini_render, orig_mini_render);
    MWB_HOOK("__ZN11MobRenderer6renderER6EntityRK4Vec3ff",
             hooked_mob_render, orig_mob_render);
    MWB_HOOK("__ZN19HumanoidMobRenderer6renderER6EntityRK4Vec3ff",
             hooked_hmob_render, orig_hmob_render);
    MWBLogFile(@"[4D皮肤] 双立方体挂载就绪（开关 skin4d）");
}
