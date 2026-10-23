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
#import "MWBFishData.h"
#import "MWBGLBModel.h" // GLB 直画（大肥鱼），复用同一 render hook 在 orig 之后画
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
typedef void (*MSetModelFn)(void *thiz, void *model);
// 直写 part+0xB8（compile 读它当 Model* 调 getAABB），不用 setModel：
// setModel 会把自家 part 塞进原版 model 的链表污染原版遍历，直写等效且零污染。
__attribute__((unused)) static void MWBSkinLinkModel(void *part, void *model) {
    if (part) *(void **)((char *)part + 0xB8) = model;
}
static MPartCtorFn sPartCtor = NULL;
static MCubeCtorFn sCubeCtor = NULL;
static MAddChildFn sAddChild = NULL;
static MPartRenderFn sPartRender = NULL;
static MSetModelFn sSetModel = NULL;
static int sSymOK = 0;
static void MWBSkinResolve(void) {
    if (sSymOK) return;
    sSymOK = 1;
    sPartCtor = (MPartCtorFn)MSFindSymbol(NULL, "__ZN9ModelPartC1Eiiii");
    sCubeCtor = (MCubeCtorFn)MSFindSymbol(NULL, "__ZN4CubeC1EP9ModelPartiifffiiif");
    sAddChild = (MAddChildFn)MSFindSymbol(NULL, "__ZN9ModelPart8addChildEPS_");
    sPartRender = (MPartRenderFn)MSFindSymbol(NULL, "__ZN9ModelPart6renderEf");
    sSetModel = (MSetModelFn)MSFindSymbol(NULL, "__ZN9ModelPart8setModelEP5Model");
    if (!sPartCtor || !sCubeCtor || !sAddChild || !sPartRender || !sSetModel)
        MWBLogFile(@"[4D皮肤] 符号缺失 part=%p cube=%p add=%p render=%p setmodel=%p",
                   sPartCtor, sCubeCtor, sAddChild, sPartRender, sSetModel);
}

// ---- 自家树（建一次，逐帧复用，零每帧分配；parts 表留着逐帧重绑 Model） ----
static void *sCubeRoot = NULL;
static void **sPartsKept = NULL;
static int sPartsCount = 0;

// 手动给 part 的 cube 指针向量塞一个指针（C1 已清零向量，自家 malloc 指针数组拥有）
static void MWBSkinPushCube(void *part, void *cube) {
    void **f = (void **)((char *)part + 0x20);
    uint8_t *begin = (uint8_t *)f[0], *end = (uint8_t *)f[1], *cap = (uint8_t *)f[2];
    if (!begin || end + 8 > cap) { // 按需翻倍扩容（写死 16 会在第 3 盒起堆溢出，-172/-173 延迟死根因）
        size_t oldBytes = begin ? (size_t)(end - begin) : 0;
        size_t oldCap = begin ? (size_t)(cap - begin) : 0;
        size_t newCap = oldCap ? oldCap * 2 : 16;
        while (newCap - oldBytes < 8) newCap *= 2;
        uint8_t *nb = (uint8_t *)malloc(newCap);
        if (!nb) return;
        if (begin) { memcpy(nb, begin, oldBytes); free(begin); }
        f[0] = nb; f[1] = nb + oldBytes; f[2] = nb + newCap;
        end = nb + oldBytes;
    }
    *(void **)end = cube;
    f[1] = end + 8;
}

// 大肥鱼烘焙表（MWBFishData.c，机器生成）：建树=纯循环填表，无解析无解码。
// 坐标轴标定模型（单 part 三盒，无层级零递归）：X臂 origin(0,-1,-1) size(40,2,2) 最长，
// Y臂 origin(-1,0,-1) size(2,24,2)，Z臂 origin(-1,-1,0) size(2,2,16) 最短，长短即身份。
// 轴心 (0,0,0) 落在玩家脚下，俯视即可断出三轴正负与比例。鱼群验证时把调用换回鱼版。
__attribute__((unused)) static void MWBSkinBuildAxis(void *model) {
    if (sCubeRoot || !sPartCtor || !sCubeCtor || !sSetModel || !model) return;
    void *p = malloc(0xC0);
    if (!p) return;
    memset(p, 0, 0xC0);
    sPartCtor(p, 0, 0, 64, 64);
    static const float kOrg[3][3] = {{0,-1,-1},{-1,0,-1},{-1,-1,0}};
    static const int kSize[3][3] = {{40,2,2},{2,24,2},{2,2,16}};
    for (int i = 0; i < 3; i++) {
        void *c = malloc(0x2C8);
        if (!c) continue;
        memset(c, 0, 0x2C8);
        sCubeCtor(c, p, 0, 0, kOrg[i][0], kOrg[i][1], kOrg[i][2],
                  kSize[i][0], kSize[i][1], kSize[i][2], 0.0f);
        MWBSkinPushCube(p, c);
    }
    sSetModel(p, model);
    void **tbl = (void **)malloc(sizeof(void *));
    if (!tbl) return;
    tbl[0] = p;
    if (sPartsKept) free(sPartsKept);
    sPartsKept = tbl;
    sPartsCount = 1;
    sCubeRoot = p;
    MWBLogFile(@"[4D皮肤] 坐标轴建好");
}
__attribute__((unused)) static void MWBSkinBuild(void *model) {
    if (sCubeRoot || !sPartCtor || !sCubeCtor || !sAddChild || !sSetModel || !model) return;
    // 先搭全部 part（指针表留着第二遍串父子/setModel）
    void **parts = (void **)malloc(sizeof(void *) * (size_t)MWBFishBoneCount);
    if (!parts) return;
    for (int i = 0; i < MWBFishBoneCount; i++) parts[i] = NULL;
    for (int i = 0; i < MWBFishBoneCount; i++) {
        void *p = malloc(0xC0);
        if (!p) { free(parts); return; } // 失败即整树作废（sCubeRoot 保持空，永不藏原版）
        memset(p, 0, 0xC0);
        sPartCtor(p, 0, 0, 64, 64);
        *(float *)((char *)p + 0x00) = MWBFishBonePivot[i][0];
        *(float *)((char *)p + 0x04) = MWBFishBonePivot[i][1];
        *(float *)((char *)p + 0x08) = MWBFishBonePivot[i][2];
        *(float *)((char *)p + 0x0C) = MWBFishBoneRot[i][0];
        *(float *)((char *)p + 0x10) = MWBFishBoneRot[i][1];
        *(float *)((char *)p + 0x14) = MWBFishBoneRot[i][2];
        parts[i] = p;
    }
    MWBLogFile(@"[4D皮肤] 建树阶段1 parts就绪");
    // 再挂全部盒子（堆分配+原地构造+指针 push，照抄 HumanoidModel 亲传）
    for (int i = 0; i < MWBFishCubeCount; i++) {
        void *p = parts[MWBFishCubeBone[i]];
        void *c = malloc(0x2C8);
        if (!c || !p) continue;
        memset(c, 0, 0x2C8);
        const float *o = MWBFishCubeOrigin[i], *s = MWBFishCubeSize[i];
        sCubeCtor(c, p, 0, 0, o[0], o[1], o[2], (int)s[0], (int)s[1], (int)s[2], 0.0f);
        MWBSkinPushCube(p, c);
    }
    MWBLogFile(@"[4D皮肤] 建树阶段2 cubes就绪");
    // 最后串父子+填 Model（根=首个无父骨，即 Root）
    // 注意：model（HumanoidModel*）会随进出世界重建，parts 表留着逐帧重绑（见 hook），
    // 否则切世界后 +0xB8 成野指针，进新世界必死（-174 老是卡死闪退根因）。
    void *root = NULL;
    for (int i = 0; i < MWBFishBoneCount; i++) {
        if (!parts[i]) continue;
        sSetModel(parts[i], model);
        int par = MWBFishBoneParent[i];
        if (par < 0) { if (!root) root = parts[i]; }
        else if (parts[par]) sAddChild(parts[par], parts[i]);
    }
    if (!root) { free(parts); return; }
    if (sPartsKept) free(sPartsKept);
    sPartsKept = parts;
    sPartsCount = MWBFishBoneCount;
    // 真穿身上：相对坐标已证对，不再偏移（第三人称回看即见）。
    // 关键：compile 里读 part+0xB8 当 Model* 调 getAABB，C1 不填它，必须调 setModel
    // （HumanoidModel 构造里每 part 都调；漏调=空指针解引用静默死，-169 闪退根因）。
    // model 传 hook 的 self（HumanoidModel*），建树点在 mini hook 内才有，见下。
    sCubeRoot = root;
    MWBLogFile(@"[4D皮肤] 大肥鱼建好 root=%p 骨=%d 盒=%d", root, MWBFishBoneCount, MWBFishCubeCount);
}

// 原版六件套显隐（HumanoidModel::render hook 内调，self 即 model；
// 偏移 HumanoidModel::render 反编译实锤：model+0x108 起步进 0xC0 六个）
static void MWBSkinSetVanilla(void *model, BOOL hide) {
    if (!model) return;
    static const size_t kOff[6] = {0x108, 0x1C8, 0x288, 0x348, 0x408, 0x4C8};
    for (int i = 0; i < 6; i++)
        ((char *)model)[kOff[i] + 0x80] = hide ? 1 : 0;
}

// HumanoidModel::render 真签名：后六参是 16 字节向量（v0-v5），不是 float！
// 反编译实锤：入口 mov v8,v5，且喂 part 的矩阵就是 v5（lane0 即 f6=0.0625）。
// 按 float 声明转发会丢每个向量的高 12 字节，且自家 render 拿不到真矩阵（-168 隐身 bug 的根因）。
// 故 hook 与原函数一律用向量类型全量透传，自家树直接用游戏的 v5 矩阵画。
typedef float M16Skin __attribute__((vector_size(16)));
typedef void (*HModelRenderFn)(void *self, void *entity,
                               M16Skin p1, M16Skin p2, M16Skin p3,
                               M16Skin p4, M16Skin p5, M16Skin p6);
static HModelRenderFn orig_mini_render = NULL;
typedef void (*MPartRenderFnV)(void *part, M16Skin m); // x0=part, v0=矩阵，与游戏调用点一致

static void hooked_mini_render(void *self, void *entity,
                               M16Skin p1, M16Skin p2, M16Skin p3,
                               M16Skin p4, M16Skin p5, M16Skin p6) {
    // 先把六个向量存局部（无调用，v0-v5 原样落栈），之后随便调函数，透传时再全量装回去。
    M16Skin s1 = p1, s2 = p2, s3 = p3, s4 = p4, s5 = p5, s6 = p6;
    // 本地玩家：先建树（一次，渲染线程，malloc+叶子构造），树在才藏原版（防隐身）。
    // Model 随进出世界重建，每帧用当前 self 重绑（几十次指针写，可忽略），防野指针。
    if (entity && entity == gLocalPlayer) {
        MWBSkinResolve();
        if (gSkin4D && sPartRender) MWBSkinBuild(self); // 相对坐标已修正，切回鱼
        if (sCubeRoot && sPartsKept && sSetModel)
            for (int i = 0; i < sPartsCount; i++)
                if (sPartsKept[i]) sSetModel(sPartsKept[i], self);
        MWBSkinSetVanilla(self, (gSkin4D && sCubeRoot) || gGLBModel);
    }
    orig_mini_render(self, entity, s1, s2, s3, s4, s5, s6);
    // 自家树画在 orig 之后、同一 hook 内：栈顶还压着实体变换，用游戏真矩阵 v5 落在玩家身上。
    if (entity && entity == gLocalPlayer && gSkin4D && sCubeRoot && sPartRender) {
        ((MPartRenderFnV)sPartRender)(sCubeRoot, s6);
        static int sDbg = 0;
        // 定位用：前 3 帧 dump 真矩阵 v5 四 lane + 玩家坐标 + 根轴心（只 3 行）
        if (sDbg < 3 && gLocalPlayer) {
            sDbg++;
            float px = *(float *)((char *)gLocalPlayer + 0x28);
            float py = *(float *)((char *)gLocalPlayer + 0x28 + 4);
            float pz = *(float *)((char *)gLocalPlayer + 0x28 + 8);
            float rx = *(float *)((char *)sCubeRoot + 0x00);
            float ry = *(float *)((char *)sCubeRoot + 0x04);
            float rz = *(float *)((char *)sCubeRoot + 0x08);
            MWBLogFile(@"[4D皮肤] 矩阵v5=%.4f,%.4f,%.4f,%.4f 玩家=(%.1f,%.1f,%.1f) 根轴心=(%.1f,%.1f,%.1f)",
                       s6[0], s6[1], s6[2], s6[3], px, py, pz, rx, ry, rz);
        }
        static int sFrames = 0;
        sFrames++;
        // 存活计数：前 10 帧逐帧记，之后每 600 帧记一行（定位第几帧死，平时不刷屏）
        if (sFrames <= 10 || (sFrames % 600) == 0)
            MWBLogFile(@"[4D皮肤] 存活帧=%d", sFrames);
    }
    // GLB 直画（大肥鱼）：同一 hook 内 orig 之后画，自家 shader，不碰游戏状态机（内部保存/恢复）
    if (entity && entity == gLocalPlayer && gGLBModel) {
        MWBGLBDraw();
    }
}

// 上层透传（占位不断链）
typedef void (*MobRenderFn)(void *self, void *entity, const void *pos, float f1, float f2);
static MobRenderFn orig_mob_render = NULL;
static void hooked_mob_render(void *self, void *entity, const void *pos, float f1, float f2) {
    orig_mob_render(self, entity, pos, f1, f2);
}

// 外层透传（建树与绘制已搬进 HumanoidModel::render hook 内，那里栈顶有实体变换）
typedef void (*HMobRenderFn)(void *self, void *entity, const void *pos, float f1, float f2);
static HMobRenderFn orig_hmob_render = NULL;
static void hooked_hmob_render(void *self, void *entity, const void *pos, float f1, float f2) {
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
    MWBLogFile(@"[4D皮肤] 大肥鱼挂载就绪（开关 skin4d）");
}
