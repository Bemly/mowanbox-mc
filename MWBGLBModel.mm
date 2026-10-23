// MWBGLBModel.mm — GLB 直解直画实现（变换/叠加语义逐字照抄 viewer + ysm_to_glb.py）
// viewer 里 three.js 做的事，这里拆成三件：
//  1) GLB 解析：头/JSON/BIN 三段，NSJSONSerialization，只读 float32 + uint16（转换器只写这两种）；
//  2) 姿势：旋转 slerp/位移 lerp（GLB 纯数字通道），scale 走 vis 叠加（molang 求值）；
//  3) 绘制：自家最小 shader（纹理+0.5 丢弃），不用游戏 shader，不猜 attribute 位置。
// 单位：GLB 是米（pivot/16），游戏是 Bedrock 单位，解析时全乘 16（顶点+节点位移），运行时零换算。
// UV：GLB 是 flipY 约定，PNG 解出来是左上原点，解析时 v=1-v（three 内部同款翻转）。
#import "MWBGLBModel.h"
#import "MWBGLBMolang.h"
#import "MWBCommon.h"
#import <OpenGLES/ES2/gl.h>
#import <ImageIO/ImageIO.h>
#import <math.h>
#import <vector>
#import <map>
#import <string>

// ---- 捕获矩阵（uniform hook 内调，只做 64 字节拷贝） ----
static float sGLBProj[16]; static BOOL sHasProj = NO;
static float sGLBMV[16];   static BOOL sHasMV = NO;
void MWBGLBCaptureMatrix(const float *m) {
    if (!m) return;
    // 透视签名与穿墙判断同款（列主序 m[11]==-1、m[15]==0）
    if (m[3] == 0.0f && m[7] == 0.0f && fabsf(m[11] + 1.0f) < 1e-6f && m[15] == 0.0f) {
        memcpy(sGLBProj, m, sizeof(sGLBProj)); sHasProj = YES;
    } else if (m[15] == 1.0f) {
        memcpy(sGLBMV, m, sizeof(sGLBMV)); sHasMV = YES; // 最后一个仿射胜出（画时读，错位也只错位不崩）
    }
}

// ---- 数据 ----
struct GLBMesh { float *pos; float *uv; uint16_t *idx; int nvert; int nidx; };
struct GLBNode {
    std::string name; float t[3]; float q[4]; float s[3];
    int mesh; std::vector<int> children; int parent;
};
struct GLBKeys { // 单节点单通道关键帧
    std::vector<float> times; std::vector<float> vals; // vals 按分量展开（quat 4/pos 3）
    int comp; BOOL step; // 全段 STEP（任一 mode==1 即按 viewer 持留）
};
struct GLBAnim { int loop; float length; std::map<int, GLBKeys> rot; std::map<int, GLBKeys> pos; };

static std::vector<GLBNode> sNodes;
static std::map<std::string, int> sName2Idx;
static std::vector<GLBMesh> sMeshes;
static std::vector<int> sRootSet; // Root 子树（含 Root），只画这些
static std::map<std::string, GLBAnim> sAnims;
static NSDictionary *sVisScale = nil; // anim -> {loop,length,tracks}
static NSArray *sVisOrder = nil;
static NSData *sTexPNG = nil;
static NSString *sCurAnim = nil;
static BOOL sParsed = NO;
static float sTMain = 0, sTVis = 0; // 主动作时间 / 常驻层时间（viewer 双时钟同款）
static GLuint sProg = 0, sTex = 0; // 自家 shader 与贴图（GL 线程建，reload 时置 0 下次重建）

// ---- 小数学（列主序，与 GL 一致） ----
static void GLBQuatToMat(const float *q, float *m) {
    float x = q[0], y = q[1], z = q[2], w = q[3];
    float xx = x*x, yy = y*y, zz = z*z, xy = x*y, xz = x*z, yz = y*z, wx = w*x, wy = w*y, wz = w*z;
    m[0] = 1-2*(yy+zz); m[1] = 2*(xy+wz);   m[2] = 2*(xz-wy);   m[3] = 0;
    m[4] = 2*(xy-wz);   m[5] = 1-2*(xx+zz); m[6] = 2*(yz+wx);   m[7] = 0;
    m[8] = 2*(xz+wy);   m[9] = 2*(yz-wx);   m[10] = 1-2*(xx+yy); m[11] = 0;
    m[12] = 0; m[13] = 0; m[14] = 0; m[15] = 1;
}
static void GLBMatMul(const float *a, const float *b, float *o) {
    float r[16];
    for (int c = 0; c < 4; c++) for (int r_ = 0; r_ < 4; r_++)
        r[c*4+r_] = a[r_]*b[c*4] + a[4+r_]*b[c*4+1] + a[8+r_]*b[c*4+2] + a[12+r_]*b[c*4+3];
    memcpy(o, r, sizeof(r));
}
static void GLBLocalMat(const float *t, const float *q, const float *s, float *m) {
    float R[16], o[16];
    GLBQuatToMat(q, R);
    // local = T·R·S（viewer/转换器同款分解）
    for (int c = 0; c < 3; c++) for (int r_ = 0; r_ < 3; r_++) o[c*4+r_] = R[c*4+r_] * s[c];
    o[3] = 0; o[7] = 0; o[11] = 0; o[15] = 1;
    o[12] = t[0]; o[13] = t[1]; o[14] = t[2];
    memcpy(m, o, sizeof(o));
}
static void GLBSlerp(const float *a, const float *b, float f, float *o) {
    float dot = a[0]*b[0]+a[1]*b[1]+a[2]*b[2]+a[3]*b[3];
    float b2[4]; memcpy(b2, b, sizeof(b2));
    if (dot < 0) { dot = -dot; b2[0]=-b2[0]; b2[1]=-b2[1]; b2[2]=-b2[2]; b2[3]=-b2[3]; }
    float s0, s1;
    if (dot > 0.9995f) { s0 = 1-f; s1 = f; }
    else {
        float th = acosf(fminf(1.0f, dot));
        float st = sinf(th);
        s0 = sinf((1-f)*th)/st; s1 = sinf(f*th)/st;
    }
    for (int i = 0; i < 4; i++) o[i] = s0*a[i]+s1*b2[i];
    float l = sqrtf(o[0]*o[0]+o[1]*o[1]+o[2]*o[2]+o[3]*o[3]);
    if (l > 1e-6f) for (int i = 0; i < 4; i++) o[i] /= l;
}

// ---- 关键帧采样（viewer trackVal 同语义；rot 专用四元数版） ----
static float GLBLen(id v) { return [v isKindOfClass:[NSNumber class]] ? [v floatValue] : INFINITY; }
static float GLBWrapT(float t, int loop, float length) {
    if (loop == 1) {
        // viewer：length 无穷（sidecar 里 null）即自由跑，不取模不钳制
        if (isfinite(length) && length > 0) {
            float r = fmodf(t, length); if (r < 0) r += length; return r;
        }
        return t;
    }
    if (isfinite(length)) return fminf(t, length);
    return t;
}
static void GLBScaleAt(NSArray *kfs, float t, const MWBMolangEnv *env, int loop, float length, float out[3]) {
    if (!kfs || !kfs.count) { out[0]=out[1]=out[2]=1; return; }
    float tt = GLBWrapT(t, loop, length);
    NSArray *first = kfs[0];
    if (tt <= [first[0] floatValue]) {
        NSArray *v = first[2];
        for (int k = 0; k < 3; k++) out[k] = MWBMolangValue(v[k], env);
        return;
    }
    for (NSUInteger i = 0; i + 1 < kfs.count; i++) {
        NSArray *a = kfs[i], *b = kfs[i+1];
        float ta = [a[0] floatValue], tb = [b[0] floatValue];
        if (tt >= ta && tt <= tb) {
            if ([a[1] intValue] == 1 || tb == ta) {
                NSArray *v = a[2];
                for (int k = 0; k < 3; k++) out[k] = MWBMolangValue(v[k], env);
                return;
            }
            float f = (tt - ta) / (tb - ta);
            NSArray *va = a[2], *vb = b[2];
            for (int k = 0; k < 3; k++) {
                float xa = MWBMolangValue(va[k], env), xb = MWBMolangValue(vb[k], env);
                out[k] = xa + (xb - xa) * f;
            }
            return;
        }
    }
    NSArray *v = [kfs lastObject][2];
    for (int k = 0; k < 3; k++) out[k] = MWBMolangValue(v[k], env);
}
static void GLBRotAt(const GLBKeys *k, float t, int loop, float length, float out[4]) {
    if (!k || k->times.empty()) { out[0]=out[1]=out[2]=0; out[3]=1; return; }
    float tt = GLBWrapT(t, loop, length);
    size_t n = k->times.size();
    if (tt <= k->times[0]) { memcpy(out, &k->vals[0], 4*sizeof(float)); return; }
    for (size_t i = 0; i + 1 < n; i++) {
        if (tt >= k->times[i] && tt <= k->times[i+1]) {
            if (k->step || k->times[i+1] == k->times[i]) {
                memcpy(out, &k->vals[i*4], 4*sizeof(float)); return;
            }
            float f = (tt - k->times[i]) / (k->times[i+1] - k->times[i]);
            GLBSlerp(&k->vals[i*4], &k->vals[(i+1)*4], f, out);
            return;
        }
    }
    memcpy(out, &k->vals[(n-1)*4], 4*sizeof(float));
}
static void GLBPosAt(const GLBKeys *k, float t, int loop, float length, float out[3]) {
    if (!k || k->times.empty()) return; // 调用方保留 base
    float tt = GLBWrapT(t, loop, length);
    size_t n = k->times.size();
    if (tt <= k->times[0]) { memcpy(out, &k->vals[0], 3*sizeof(float)); return; }
    for (size_t i = 0; i + 1 < n; i++) {
        if (tt >= k->times[i] && tt <= k->times[i+1]) {
            if (k->step || k->times[i+1] == k->times[i]) {
                memcpy(out, &k->vals[i*3], 3*sizeof(float)); return;
            }
            float f = (tt - k->times[i]) / (k->times[i+1] - k->times[i]);
            for (int c = 0; c < 3; c++)
                out[c] = k->vals[i*3+c] + (k->vals[(i+1)*3+c] - k->vals[i*3+c]) * f;
            return;
        }
    }
    memcpy(out, &k->vals[(n-1)*3], 3*sizeof(float));
}

// ---- GLB 解析 ----
static BOOL GLBReadAcc(NSDictionary *acc, NSArray *views, const uint8_t *bin, size_t binLen,
                       int wantComp, NSString *wantType, int wantCount, const void **pOut) {
    int vi = [acc[@"bufferView"] intValue];
    if (vi < 0 || vi >= (int)views.count) return NO;
    NSDictionary *v = views[vi];
    size_t off = (size_t)[v[@"byteOffset"] longLongValue] + (size_t)[acc[@"byteOffset"] longLongValue];
    if ([acc[@"componentType"] intValue] != wantComp) return NO;
    if (![acc[@"type"] isEqualToString:wantType]) return NO;
    if ([acc[@"count"] intValue] != wantCount && wantCount >= 0) return NO;
    if (v[@"byteStride"] && [v[@"byteStride"] intValue] != 0) return NO; // 紧排才读
    *pOut = bin + off;
    return YES;
}

BOOL MWBGLBEnsureParsed(void) {
    if (sParsed) return YES;
    NSString *dir = @"/var/mobile/Documents/mwbmodels";
    NSString *glbPath = [dir stringByAppendingPathComponent:@"fatfish.glb"];
    NSData *data = [NSData dataWithContentsOfFile:glbPath];
    if (!data || data.length < 20) { MWBLogFile(@"[GLB] 读不到 %@", glbPath); return NO; }
    const uint8_t *b = (const uint8_t *)data.bytes;
    uint32_t magic = b[0]|(b[1]<<8)|(b[2]<<16)|(b[3]<<24);
    if (magic != 0x46546C67) { MWBLogFile(@"[GLB] 魔数不对"); return NO; }
    uint32_t jl = b[12]|(b[13]<<8)|(b[14]<<16)|(b[15]<<24);
    if (20 + jl > data.length) { MWBLogFile(@"[GLB] JSON 越界"); return NO; }
    NSError *e = nil;
    NSDictionary *j = [NSJSONSerialization JSONObjectWithData:[data subdataWithRange:NSMakeRange(20, jl)]
                                                      options:0 error:&e];
    if (!j || e) { MWBLogFile(@"[GLB] JSON 坏：%@", e); return NO; }
    size_t binOff = 20 + jl + 8, binLen = 0;
    if (binOff > data.length) { MWBLogFile(@"[GLB] 无 BIN 段"); return NO; }
    binLen = data.length - binOff;
    const uint8_t *bin = b + binOff;
    NSArray *jNodes = j[@"nodes"], *jMeshes = j[@"meshes"];
    NSArray *jAccs = j[@"accessors"], *jViews = j[@"bufferViews"], *jAnims = j[@"animations"];
    if (!jNodes || !jMeshes || !jAccs || !jViews) { MWBLogFile(@"[GLB] 缺段"); return NO; }

    sNodes.clear(); sName2Idx.clear(); sMeshes.clear(); sRootSet.clear(); sAnims.clear();
    // 节点
    for (NSUInteger i = 0; i < jNodes.count; i++) {
        NSDictionary *n = jNodes[i];
        GLBNode nd; char nb[128];
        NSString *nm = [n[@"name"] isKindOfClass:[NSString class]] ? n[@"name"] : [NSString stringWithFormat:@"n%lu", (unsigned long)i];
        snprintf(nb, sizeof(nb), "%s", [nm UTF8String]); nd.name = nb;
        NSArray *t = n[@"translation"], *q = n[@"rotation"], *sc = n[@"scale"];
        // 解析时直接乘 16 进游戏单位（顶点+位移同乘，运行时零换算）
        nd.t[0] = t ? [t[0] floatValue]*16.0f : 0; nd.t[1] = t ? [t[1] floatValue]*16.0f : 0; nd.t[2] = t ? [t[2] floatValue]*16.0f : 0;
        if (q) { nd.q[0]=[q[0] floatValue]; nd.q[1]=[q[1] floatValue]; nd.q[2]=[q[2] floatValue]; nd.q[3]=[q[3] floatValue]; }
        else { nd.q[0]=nd.q[1]=nd.q[2]=0; nd.q[3]=1; }
        if (sc) { nd.s[0]=[sc[0] floatValue]; nd.s[1]=[sc[1] floatValue]; nd.s[2]=[sc[2] floatValue]; }
        else { nd.s[0]=nd.s[1]=nd.s[2]=1; }
        nd.mesh = [n[@"mesh"] intValue];
        if (!n[@"mesh"]) nd.mesh = -1;
        nd.parent = -1;
        for (id c in (NSArray *)(n[@"children"] ?: @[])) {
            int ci = [c intValue];
            if (ci >= 0 && ci < (int)jNodes.count) nd.children.push_back(ci);
        }
        sName2Idx[nd.name] = (int)sNodes.size();
        sNodes.push_back(nd);
    }
    for (size_t i = 0; i < sNodes.size(); i++)
        for (int c : sNodes[i].children) sNodes[c].parent = (int)i;
    // Root 子树（只画这些，菜单三件套天然排除，viewer 里 pre_parallel2 藏的是同一批）
    auto itR = sName2Idx.find("Root");
    std::vector<int> stack;
    if (itR != sName2Idx.end()) stack.push_back(itR->second);
    else for (size_t i = 0; i < sNodes.size(); i++) if (sNodes[i].parent < 0) stack.push_back((int)i);
    std::vector<char> seen(sNodes.size(), 0);
    while (!stack.empty()) {
        int cur = stack.back(); stack.pop_back();
        if (seen[cur]) continue; seen[cur] = 1; sRootSet.push_back(cur);
        for (int c : sNodes[cur].children) stack.push_back(c);
    }
    // 网格（只解析 POSITION/NORMAL 跳过/TEXCOORD_0 + 索引；verts 已相对 pivot，乘 16）
    long totalTris = 0;
    for (NSUInteger i = 0; i < jMeshes.count; i++) {
        NSDictionary *prim = jMeshes[i][@"primitives"][0];
        NSDictionary *attr = prim[@"attributes"];
        int pi = [attr[@"POSITION"] intValue], ui = [attr[@"TEXCOORD_0"] intValue], ii = [prim[@"indices"] intValue];
        if (pi < 0 || ui < 0 || ii < 0 || pi >= (int)jAccs.count || ui >= (int)jAccs.count || ii >= (int)jAccs.count) continue;
        const void *pp = NULL, *pu = NULL, *pi_ = NULL;
        int nv = [jAccs[pi][@"count"] intValue], ni = [jAccs[ii][@"count"] intValue];
        if (!GLBReadAcc(jAccs[pi], jViews, bin, binLen, 5126, @"VEC3", -1, &pp)) continue;
        if (!GLBReadAcc(jAccs[ui], jViews, bin, binLen, 5126, @"VEC2", nv, &pu)) continue;
        if (!GLBReadAcc(jAccs[ii], jViews, bin, binLen, 5123, @"SCALAR", -1, &pi_)) continue;
        GLBMesh m; m.nvert = nv; m.nidx = ni;
        m.pos = (float *)malloc(sizeof(float) * 3 * (size_t)nv);
        m.uv = (float *)malloc(sizeof(float) * 2 * (size_t)nv);
        m.idx = (uint16_t *)malloc(sizeof(uint16_t) * (size_t)ni);
        if (!m.pos || !m.uv || !m.idx) { free(m.pos); free(m.uv); free(m.idx); continue; }
        const float *fp = (const float *)pp; const float *fu = (const float *)pu;
        for (int v = 0; v < nv; v++) {
            m.pos[v*3]=fp[v*3]*16.0f; m.pos[v*3+1]=fp[v*3+1]*16.0f; m.pos[v*3+2]=fp[v*3+2]*16.0f;
            m.uv[v*2]=fu[v*2]; m.uv[v*2+1]=1.0f-fu[v*2+1]; // flipY（three 同款）
        }
        memcpy(m.idx, pi_, sizeof(uint16_t) * (size_t)ni);
        totalTris += ni / 3;
        sMeshes.push_back(m);
        // mesh 序号 == jMeshes 下标（节点 mesh 字段直接对）
        if ((int)sMeshes.size() != (int)i + 1) { /* 跳过坏 mesh 后序号错位，打日志 */ }
    }
    // 网格序号对齐检查（解析跳过会导致节点 mesh 错位，必须对上否则张冠李戴）
    if (sMeshes.size() != jMeshes.count) {
        MWBLogFile(@"[GLB] 网格对不上 parsed=%lu json=%lu，本轮不画", (unsigned long)sMeshes.size(), (unsigned long)jMeshes.count);
        for (auto &m : sMeshes) { free(m.pos); free(m.uv); free(m.idx); }
        sMeshes.clear(); sNodes.clear(); sRootSet.clear();
        return NO;
    }
    // 动画（只取纯数字 rot/pos，molang 通道跳过，viewer/转换器同款）
    for (NSDictionary *clip in (NSArray *)(jAnims ?: @[])) {
        NSString *full = clip[@"name"];
        NSString *bare = [full hasPrefix:@"main:"] ? [full substringFromIndex:5] : full;
        GLBAnim an; an.loop = [[clip[@"extras"][@"loop"] description] isEqualToString:@"1"] ? 1 : 2;
        // extras.loop 在 JSON 里是 bool；description 保险起见双判
        id lp = clip[@"extras"][@"loop"];
        an.loop = ([lp boolValue]) ? 1 : 2;
        an.length = [clip[@"extras"][@"length"] floatValue];
        NSArray *chans = clip[@"channels"], *smps = clip[@"samplers"];
        for (NSDictionary *ch in chans) {
            int ni = [ch[@"target"][@"node"] intValue];
            NSString *path = ch[@"target"][@"path"];
            NSDictionary *sm = smps[[ch[@"sampler"] intValue]];
            int iAcc = [sm[@"input"] intValue], oAcc = [sm[@"output"] intValue];
            NSString *interp = sm[@"interpolation"];
            if (iAcc < 0 || oAcc < 0 || iAcc >= (int)jAccs.count || oAcc >= (int)jAccs.count) continue;
            int nt = [jAccs[iAcc][@"count"] intValue];
            const void *tp = NULL, *vp = NULL;
            if (!GLBReadAcc(jAccs[iAcc], jViews, bin, binLen, 5126, @"SCALAR", -1, &tp)) continue;
            BOOL isRot = [path isEqualToString:@"rotation"], isPos = [path isEqualToString:@"translation"];
            if (!isRot && !isPos) continue; // scale 走 vis，不从 GLB 取
            int comp = isRot ? 4 : 3;
            NSString *vt = isRot ? @"VEC4" : @"VEC3";
            if (!GLBReadAcc(jAccs[oAcc], jViews, bin, binLen, 5126, vt, nt, &vp)) continue;
            GLBKeys k; k.comp = comp; k.step = [interp isEqualToString:@"STEP"];
            const float *ft = (const float *)tp, *fv = (const float *)vp;
            for (int f = 0; f < nt; f++) { k.times.push_back(ft[f]); for (int c = 0; c < comp; c++) k.vals.push_back(fv[f*comp+c]); }
            if (isRot) an.rot[ni] = k; else an.pos[ni] = k;
        }
        // translation 输出是绝对位移（含 pivot），解析时乘 16 进游戏单位
        for (auto &kv : an.pos) for (float &v : kv.second.vals) v *= 16.0f;
        sAnims[[bare UTF8String]] = an;
    }
    // 贴图（images[0] 内嵌 PNG，解码留给 GL 线程上传，这里只存字节）
    NSArray *jImgs = j[@"images"];
    if (jImgs.count) {
        int bvi = [jImgs[0][@"bufferView"] intValue];
        if (bvi >= 0 && bvi < (int)jViews.count) {
            size_t off = (size_t)[jViews[bvi][@"byteOffset"] longLongValue];
            size_t len = (size_t)[jViews[bvi][@"byteLength"] longLongValue];
            if (off + len <= binLen) sTexPNG = [NSData dataWithBytes:bin+off length:len];
        }
    }
    // vis sidecar（scale 轨道 + 顺序 + 设置）
    NSString *visPath = [dir stringByAppendingPathComponent:@"fatfish_vis.json"];
    NSData *visData = [NSData dataWithContentsOfFile:visPath];
    if (visData) {
        NSDictionary *vis = [NSJSONSerialization JSONObjectWithData:visData options:0 error:&e];
        if (vis) { sVisScale = vis[@"scale"]; sVisOrder = vis[@"order"]; }
        else MWBLogFile(@"[GLB] sidecar 解析失败：%@", e);
    } else MWBLogFile(@"[GLB] 无 sidecar（只画绑定姿势）：%@", visPath);
    if (!sCurAnim) sCurAnim = @"idle";
    sParsed = YES;
    MWBLogFile(@"[GLB] 解析成功 节点=%lu 网格=%lu 三角=%ld Root子树=%lu 动画=%lu 贴图=%lu字节 sidecar=%@",
               (unsigned long)sNodes.size(), (unsigned long)sMeshes.size(), totalTris,
               (unsigned long)sRootSet.size(), (unsigned long)sAnims.size(),
               (unsigned long)(sTexPNG ? sTexPNG.length : 0), sVisScale ? @"有" : @"无");
    MWBGLBLogStats();
    return YES;
}

void MWBGLBLogStats(void) {
    MWBLogFile(@"[GLB] 自检 节点=%lu 网格=%lu Root子树=%lu 动画=%lu 当前=%@ sidecar动画=%lu",
               (unsigned long)sNodes.size(), (unsigned long)sMeshes.size(),
               (unsigned long)sRootSet.size(), (unsigned long)sAnims.size(), sCurAnim,
               (unsigned long)(sVisScale ? [sVisScale count] : 0));
}

// 免重启重载（调参不用反复杀进程；GL 对象下次首画重建）
void MWBGLBReload(void) {
    for (auto &m : sMeshes) { free(m.pos); free(m.uv); free(m.idx); }
    sMeshes.clear(); sNodes.clear(); sName2Idx.clear(); sRootSet.clear(); sAnims.clear();
    sVisScale = nil; sVisOrder = nil; sTexPNG = nil;
    if (sTex) { /* GL 线程外不删，下次首画复用或重建 */ }
    sProg = 0; sTex = 0; sTMain = 0; sTVis = 0;
    sParsed = NO;
    MWBLogFile(@"[GLB] 重载");
    MWBGLBEnsureParsed();
}

void MWBGLBSetAnim(NSString *name) {
    sCurAnim = [name copy] ?: @"idle";
    MWBLogFile(@"[GLB] 切动作 %@", sCurAnim);
}

// ---- 自家 shader（纹理 + 0.5 丢弃，不碰游戏 shader；attrib 固定 0/1，link 时绑定） ----
static GLint sUMVP = -1, sUTex = -1;
static GLuint GLBCompile(GLenum type, const char *src) {
    GLuint sh = glCreateShader(type);
    glShaderSource(sh, 1, &src, NULL); glCompileShader(sh);
    GLint ok = 0; glGetShaderiv(sh, GL_COMPILE_STATUS, &ok);
    if (!ok) { MWBLogFile(@"[GLB] shader 编译失败"); glDeleteShader(sh); return 0; }
    return sh;
}
static BOOL GLBInitGL(void) {
    if (sProg) return YES;
    const char *vs = "attribute vec3 a_pos; attribute vec2 a_uv; uniform mat4 u_mvp; varying vec2 v_uv;"
                     "void main(){ v_uv=a_uv; gl_Position=u_mvp*vec4(a_pos,1.0); }";
    const char *fs = "precision mediump float; varying vec2 v_uv; uniform sampler2D u_tex;"
                     "void main(){ vec4 c=texture2D(u_tex,v_uv); if(c.a<0.5) discard; gl_FragColor=c; }";
    GLuint v = GLBCompile(GL_VERTEX_SHADER, vs), f = GLBCompile(GL_FRAGMENT_SHADER, fs);
    if (!v || !f) return NO;
    sProg = glCreateProgram();
    glAttachShader(sProg, v); glAttachShader(sProg, f);
    glBindAttribLocation(sProg, 0, "a_pos"); glBindAttribLocation(sProg, 1, "a_uv");
    glLinkProgram(sProg);
    GLint ok = 0; glGetProgramiv(sProg, GL_LINK_STATUS, &ok);
    glDeleteShader(v); glDeleteShader(f);
    if (!ok) { MWBLogFile(@"[GLB] program 链接失败"); sProg = 0; return NO; }
    sUMVP = glGetUniformLocation(sProg, "u_mvp");
    sUTex = glGetUniformLocation(sProg, "u_tex");
    // 贴图上传（PNG 解码 + Nearest，不过滤，viewer 同款像素风）
    if (sTexPNG) {
        CGImageSourceRef src = CGImageSourceCreateWithData((CFDataRef)sTexPNG, NULL);
        CGImageRef img = src ? CGImageSourceCreateImageAtIndex(src, 0, NULL) : NULL;
        if (img) {
            size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img);
            void *px = calloc(w * h, 4);
            CGContextRef ctx = CGBitmapContextCreate(px, w, h, 8, w*4,
                CGColorSpaceCreateDeviceRGB(), kCGImageAlphaPremultipliedLast);
            if (ctx) {
                CGContextDrawImage(ctx, CGRectMake(0, 0, w, h), img);
                glGenTextures(1, &sTex);
                glBindTexture(GL_TEXTURE_2D, sTex);
                glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
                glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
                glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
                glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
                glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA, (GLsizei)w, (GLsizei)h, 0,
                             GL_RGBA, GL_UNSIGNED_BYTE, px);
                MWBLogFile(@"[GLB] 贴图上传 %zux%zu tex=%u", w, h, sTex);
                CGContextRelease(ctx);
            }
            free(px); CGImageRelease(img);
        }
        if (src) CFRelease(src);
    }
    return YES;
}

// ---- 绘制 ----
void MWBGLBDraw(void) {
    if (!gGLBModel || !sParsed || sRootSet.empty() || !sHasProj || !sHasMV) return;
    if (!GLBInitGL() || !sTex) return;
    // 双时钟推进（viewer 同款，dt 钳 0.1）
    static double sLast = 0;
    double now = CFAbsoluteTimeGetCurrent();
    float dt = sLast > 0 ? (float)(now - sLast) : 0.016f;
    if (dt > 0.1f) dt = 0.1f; if (dt < 0) dt = 0;
    sLast = now;
    sTMain += dt; sTVis += dt;

    // 当前动作（GLB 里 main: 前缀，sidecar 裸名，两种都试，viewer 同款）
    const GLBAnim *an = NULL;
    char abuf[128]; snprintf(abuf, sizeof(abuf), "%s", [sCurAnim UTF8String]);
    auto it = sAnims.find(abuf);
    if (it == sAnims.end()) { snprintf(abuf, sizeof(abuf), "main:%s", [sCurAnim UTF8String]); it = sAnims.find(abuf); }
    int loop = 2; float len = 0;
    if (it != sAnims.end()) { an = &it->second; loop = an->loop; len = an->length; }

    // vis 叠加：常驻层 + 当前动作，后者覆盖（viewer updateVisibility 同款）
    // 每层带自己的 loop/length，时间基：主动作层用 sTMain，常驻层用 sTVis（viewer 双时钟同款）
    MWBMolangEnv env; env.roaming = @{}; env.t = sTMain; // 默认设置全 0（P4 接 UI）
    std::map<std::string, NSDictionary *> computed; // bone -> @{kfs,loop,len,main}
    if (sVisScale) {
        for (id a in (NSArray *)(sVisOrder ?: @[])) {
            NSDictionary *A = sVisScale[a];
            if (!A) continue;
            for (id bn in (NSDictionary *)A[@"tracks"])
                computed[[bn UTF8String]] = @{@"kfs": A[@"tracks"][bn], @"loop": A[@"loop"] ?: @2,
                                              @"len": A[@"length"] ?: [NSNull null], @"main": @NO};
        }
        NSDictionary *A = sVisScale[sCurAnim];
        if (A) for (id bn in (NSDictionary *)A[@"tracks"])
            computed[[bn UTF8String]] = @{@"kfs": A[@"tracks"][bn], @"loop": A[@"loop"] ?: @2,
                                          @"len": A[@"length"] ?: [NSNull null], @"main": @YES};
    }

    // 世界矩阵（只算 Root 子树；local = T·R·S）
    static std::vector<float> sWorld; // 每节点 16
    sWorld.assign(sNodes.size() * 16, 0);
    std::vector<char> sHidden(sNodes.size(), 0);
    std::vector<float> sScaleX(sNodes.size()*3, 0);
    // 先定每节点 scale（vis 命中则求值，否则 base）
    for (int ni : sRootSet) {
        float sc[3] = { sNodes[ni].s[0], sNodes[ni].s[1], sNodes[ni].s[2] };
        auto hc = computed.find(sNodes[ni].name);
        BOOL hide = NO;
        if (hc != computed.end()) {
            NSDictionary *hit = hc->second;
            int lp = [hit[@"loop"] intValue];
            float ln = GLBLen(hit[@"len"]);
            float tb = [hit[@"main"] boolValue] ? sTMain : sTVis;
            float s[3]; GLBScaleAt(hit[@"kfs"], tb, &env, lp, ln, s);
            sc[0]=s[0]; sc[1]=s[1]; sc[2]=s[2];
            hide = (fabsf(s[0])<1e-3f || fabsf(s[1])<1e-3f || fabsf(s[2])<1e-3f);
        }
        sHidden[ni] = hide;
        sScaleX[ni*3]=sc[0]; sScaleX[ni*3+1]=sc[1]; sScaleX[ni*3+2]=sc[2];
    }
    // DFS：父世界 · local；隐藏子树整枝跳过（viewer visible=false 同款）
    auto rIt = sName2Idx.find("Root");
    int rootIdx = (rIt != sName2Idx.end()) ? rIt->second : sRootSet[0];
    std::vector<int> stack; stack.push_back(rootIdx);
    // 根 local 单独乘（父视为单位）
    {
        float t[3], q[4];
        memcpy(t, sNodes[rootIdx].t, sizeof(t)); memcpy(q, sNodes[rootIdx].q, sizeof(q));
        if (an) {
            auto rp = an->rot.find(rootIdx); if (rp != an->rot.end()) GLBRotAt(&rp->second, sTMain, loop, len, q);
            auto pp = an->pos.find(rootIdx); if (pp != an->pos.end()) GLBPosAt(&pp->second, sTMain, loop, len, t);
        }
        float sc[3] = {sScaleX[rootIdx*3],sScaleX[rootIdx*3+1],sScaleX[rootIdx*3+2]};
        float L[16]; GLBLocalMat(t, q, sc, L);
        memcpy(&sWorld[rootIdx*16], L, sizeof(L));
    }
    // 用栈展开子树（先压根，深搜序）
    std::vector<int> dfs;
    while (!stack.empty()) { int c = stack.back(); stack.pop_back(); dfs.push_back(c);
        for (int k : sNodes[c].children) stack.push_back(k); }
    for (size_t di = 1; di < dfs.size(); di++) {
        int ni = dfs[di], pi = sNodes[ni].parent;
        float t[3], q[4];
        memcpy(t, sNodes[ni].t, sizeof(t)); memcpy(q, sNodes[ni].q, sizeof(q));
        if (an) {
            auto rp = an->rot.find(ni); if (rp != an->rot.end()) GLBRotAt(&rp->second, sTMain, loop, len, q);
            auto pp = an->pos.find(ni); if (pp != an->pos.end()) GLBPosAt(&pp->second, sTMain, loop, len, t);
        }
        float sc[3] = {sScaleX[ni*3],sScaleX[ni*3+1],sScaleX[ni*3+2]};
        float L[16], W[16]; GLBLocalMat(t, q, sc, L);
        GLBMatMul(&sWorld[pi*16], L, W);
        memcpy(&sWorld[ni*16], W, sizeof(W));
    }

    // GL 现场保存
    GLint oldProg = 0, oldTex = 0, oldActive = 0, oldAB = 0, oldCull = 0;
    glGetIntegerv(GL_CURRENT_PROGRAM, &oldProg);
    glGetIntegerv(GL_TEXTURE_BINDING_2D, &oldTex);
    glGetIntegerv(GL_ACTIVE_TEXTURE, &oldActive);
    glGetIntegerv(GL_ARRAY_BUFFER_BINDING, &oldAB);
    oldCull = glIsEnabled(GL_CULL_FACE);
    GLint a0e=0, a1e=0; GLint a0s=0,a0t=0,a0n=0,a0st=0,a1s=0,a1t=0,a1n=0,a1st=0; void *a0p=NULL,*a1p=NULL;
    glGetVertexAttribiv(0, GL_VERTEX_ATTRIB_ARRAY_ENABLED, &a0e);
    glGetVertexAttribiv(1, GL_VERTEX_ATTRIB_ARRAY_ENABLED, &a1e);
    glGetVertexAttribiv(0, GL_VERTEX_ATTRIB_ARRAY_SIZE, &a0s);
    glGetVertexAttribiv(0, GL_VERTEX_ATTRIB_ARRAY_TYPE, &a0t);
    glGetVertexAttribiv(0, GL_VERTEX_ATTRIB_ARRAY_NORMALIZED, &a0n);
    glGetVertexAttribiv(0, GL_VERTEX_ATTRIB_ARRAY_STRIDE, &a0st);
    glGetVertexAttribiv(1, GL_VERTEX_ATTRIB_ARRAY_SIZE, &a1s);
    glGetVertexAttribiv(1, GL_VERTEX_ATTRIB_ARRAY_TYPE, &a1t);
    glGetVertexAttribiv(1, GL_VERTEX_ATTRIB_ARRAY_NORMALIZED, &a1n);
    glGetVertexAttribiv(1, GL_VERTEX_ATTRIB_ARRAY_STRIDE, &a1st);
    glGetVertexAttribPointerv(0, GL_VERTEX_ATTRIB_ARRAY_POINTER, &a0p);
    glGetVertexAttribPointerv(1, GL_VERTEX_ATTRIB_ARRAY_POINTER, &a1p);

    glUseProgram(sProg);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, sTex);
    glUniform1i(sUTex, 0);
    glDisable(GL_CULL_FACE); // 双面（viewer doubleSide 同款）
    glBindBuffer(GL_ARRAY_BUFFER, 0);
    glEnableVertexAttribArray(0); glEnableVertexAttribArray(1);

    // MVP = 投影 · 实体模型视图 · 节点世界（实体矩阵取捕获到的最新仿射，错位只错位不崩）
    long drawn = 0, tris = 0; long shown = 0, total = 0;
    // 祖先隐藏链（viewer 子树隐藏同款）
    std::vector<char> visOK(sNodes.size(), 0);
    visOK[rootIdx] = !sHidden[rootIdx];
    for (size_t di = 1; di < dfs.size(); di++) {
        int ni = dfs[di];
        visOK[ni] = visOK[sNodes[ni].parent] && !sHidden[ni];
    }
    for (int ni : sRootSet) {
        if (computed.count(sNodes[ni].name)) { total++; if (visOK[ni]) shown++; }
        if (!visOK[ni]) continue;
        int mi = sNodes[ni].mesh;
        if (mi < 0 || mi >= (int)sMeshes.size()) continue;
        GLBMesh &m = sMeshes[mi];
        float MV[16], MVP[16];
        GLBMatMul(sGLBMV, &sWorld[ni*16], MV);
        GLBMatMul(sGLBProj, MV, MVP);
        glUniformMatrix4fv(sUMVP, 1, GL_FALSE, MVP);
        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 0, m.pos);
        glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 0, m.uv);
        glDrawElements(GL_TRIANGLES, m.nidx, GL_UNSIGNED_SHORT, m.idx);
        drawn++; tris += m.nidx / 3;
    }

    // 现场恢复
    if (a0e) glEnableVertexAttribArray(0); else glDisableVertexAttribArray(0);
    if (a1e) glEnableVertexAttribArray(1); else glDisableVertexAttribArray(1);
    glVertexAttribPointer(0, a0s, a0t, a0n, a0st, a0p);
    glVertexAttribPointer(1, a1s, a1t, a1n, a1st, a1p);
    glBindBuffer(GL_ARRAY_BUFFER, oldAB);
    if (oldCull) glEnable(GL_CULL_FACE); else glDisable(GL_CULL_FACE);
    glActiveTexture(oldActive);
    glBindTexture(GL_TEXTURE_2D, oldTex);
    glUseProgram(oldProg);

    static int sFrames = 0; sFrames++;
    if (sFrames == 1 || sFrames % 600 == 0)
        MWBLogFile(@"[GLB] 存活帧=%d 本帧网格=%ld 三角=%ld 可见=%ld/%ld", sFrames, drawn, tris, shown, total);
}
