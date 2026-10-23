// MWBGLBModel.mm — GLB 直解 + 鱼链绘制（变换/叠加语义逐字照抄 viewer + ysm_to_glb.py）
// viewer 里 three.js 做的事，这里拆成三件：
//  1) GLB 解析：头/JSON/BIN 三段，NSJSONSerialization，只读 float32 + uint16（转换器只写这两种）；
//  2) 姿势：旋转 slerp/位移 lerp（GLB 纯数字通道），scale 走 vis 叠加（molang 求值）；
//  3) 绘制：走已验证的鱼链（单次 sPartRender(root, s6)＋游戏递归＋自家贴图绑定），
//     盒子/UV/贴图走 ysm codec（RestoreCube 现成），骨架/动画/显隐走 GLB。
// 单位：游戏渲染就是 Bedrock/米制单位，GLB 解析零换算（web 移植页实锤：之前误乘 16
// 会把鱼放大 16 倍、相机包 inside，只能看到巨型多边形；iPad 症状一致）。
// UV：不翻转（GLTFLoader 对 glTF 贴图 flipY=false；上传链内存行序见 GLBInitGL 注释，必须同 web 一致）。
#import "MWBGLBModel.h"
#import "MWBGLBMolang.h"
#import "MWBCommon.h"
#import "MWBYSMCodec.h" // ysm 解密+盒子还原（只用解析器，不走 YSM 渲染）
#import <substrate.h> // MSFindSymbol 按名解析游戏构造/render
#import <OpenGLES/ES2/gl.h>
#import <ImageIO/ImageIO.h>
#import <math.h>
#import <vector>
#import <map>
#import <string>

// 自家 shader（ES3 合法；MVP 全 CPU 算好一次传进去，不碰游戏 program）
static GLuint sProg = 0; static GLint sUMVP = -1, sUTex = -1;
static GLuint sProgFor = 0; static GLint sProjLoc = -1; static BOOL sProjScanned = NO;
static float sPMat[16]; static BOOL sHasP = NO;
static GLuint GLBCompile(GLenum type, const char *src) {
    GLuint sh = glCreateShader(type);
    glShaderSource(sh, 1, &src, NULL); glCompileShader(sh);
    GLint ok = 0; glGetShaderiv(sh, GL_COMPILE_STATUS, &ok);
    if (!ok) { MWBLogFile(@"[GLB] shader 编译失败"); glDeleteShader(sh); return 0; }
    return sh;
}
static BOOL GLBInitProg(void) {
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
    return YES;
}
// 游戏 program 里找透视矩阵（名含 PROJ 但非 WORLDVIEW*，或列主序签名；运行时放宽 eps）
// 注：绘制已改走 orig 前快照，此扫描仅留作 glinfo 诊断用（平时不调）
__attribute__((unused)) static void GLBScanProgram(GLuint prog) {
    sProjScanned = YES; sProjLoc = -1; sHasP = NO; sProgFor = prog;
    GLint n = 0; glGetProgramiv(prog, GL_ACTIVE_UNIFORMS, &n);
    char name[128];
    // 先全量 dump（找矩阵到底以什么形式存在：mat4/vec4 数组/UBO 引用，一次看清）
    for (GLint i = 0; i < n && i < 64; i++) {
        GLsizei len = 0; GLint size = 0; GLenum type = 0;
        glGetActiveUniform(prog, (GLuint)i, sizeof(name), &len, &size, &type, name);
        if (type == GL_FLOAT_MAT4) {
            GLint loc = glGetUniformLocation(prog, name);
            if (loc < 0) continue;
            float m[16]; glGetUniformfv(prog, loc, m);
            MWBLogFile(@"[GLB] U mat4 prog=%u i=%d名=%s loc=%d m=[%.3f,%.3f,%.3f,%.3f, %.3f,%.3f,%.3f,%.3f, %.3f,%.3f,%.3f,%.3f, %.3f,%.3f,%.3f,%.3f]",
                       prog, (int)i, name, loc,
                       m[0],m[1],m[2],m[3],m[4],m[5],m[6],m[7],m[8],m[9],m[10],m[11],m[12],m[13],m[14],m[15]);
        } else if (type == GL_FLOAT_VEC4) {
            GLint loc = glGetUniformLocation(prog, name);
            float v[4] = {0};
            if (loc >= 0 && size >= 1) glGetUniformfv(prog, loc, v);
            MWBLogFile(@"[GLB] U vec4 prog=%u i=%d名=%s loc=%d size=%d v=[%.3f,%.3f,%.3f,%.3f]",
                       prog, (int)i, name, loc, (int)size, v[0], v[1], v[2], v[3]);
        } else {
            MWBLogFile(@"[GLB] U prog=%u i=%d名=%s type=0x%x size=%d", prog, (int)i, name, type, (int)size);
        }
    }
    for (GLint i = 0; i < n && i < 256; i++) {
        GLsizei len = 0; GLint size = 0; GLenum type = 0;
        glGetActiveUniform(prog, (GLuint)i, sizeof(name), &len, &size, &type, name);
        if (type != GL_FLOAT_MAT4) continue;
        GLint loc = glGetUniformLocation(prog, name);
        if (loc < 0) continue;
        NSString *nm = [[NSString stringWithUTF8String:name] uppercaseString];
        BOOL nameHit = ([nm rangeOfString:@"PROJ"].location != NSNotFound &&
                        [nm rangeOfString:@"WORLDVIEW"].location == NSNotFound);
        float m[16]; glGetUniformfv(prog, loc, m);
        BOOL sigHit = (m[3]==0.0f && m[7]==0.0f && fabsf(m[11]+1.0f)<1e-3f && m[15]==0.0f);
        if (nameHit || sigHit) {
            sProjLoc = loc; memcpy(sPMat, m, sizeof(sPMat)); sHasP = YES;
            MWBLogFile(@"[GLB] 投影定位 prog=%u loc=%d名=%s", prog, loc, name);
            return;
        }
    }
    MWBLogFile(@"[GLB] 投影没找到 prog=%u uniforms=%d", prog, (int)n);
}

// ---- 捕获矩阵（uniform hook 内调，只做 64 字节拷贝） ----
static float sGLBProj[16]; static BOOL sHasProj = NO;
static float sGLBMV[16];   static BOOL sHasMV = NO;
void MWBGLBCaptureMatrix(const float *m) {
    if (!m) return;
    // 透视签名与穿墙判断同款（列主序 m[11]==-1、m[15]==0）
    if (m[3] == 0.0f && m[7] == 0.0f && fabsf(m[11] + 1.0f) < 1e-6f && m[15] == 0.0f) {
        memcpy(sGLBProj, m, sizeof(sGLBProj)); sHasProj = YES;
    } else if (m[15] == 1.0f) {
        memcpy(sGLBMV, m, sizeof(sGLBMV)); sHasMV = YES; // 最后一个仿射胜出（诊断用）
    }
}

// ---- 数据 ----
struct GLBMesh { float *pos; float *uv; uint16_t *idx; int nvert; int nidx; GLuint vbo[3]; };
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
static GLuint sTex = 0; // 自家贴图（GL 线程建，reload 时置 0 下次重建）
static BOOL sVBOInit = NO; // VBO 已上传标记（reload 清零，下次重传；旧 GPU 缓冲随进程释放）

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
        // 位移零换算，米制直用（与 web/js/plugin-glb.js 逐行一致；勿乘 16）
        nd.t[0] = t ? [t[0] floatValue] : 0; nd.t[1] = t ? [t[1] floatValue] : 0; nd.t[2] = t ? [t[2] floatValue] : 0;
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
    // 网格（只解析 POSITION/NORMAL 跳过/TEXCOORD_0 + 索引；顶点/位移零换算，UV 不翻转；与 web 一致）
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
        GLBMesh m; m.nvert = nv; m.nidx = ni; m.vbo[0]=m.vbo[1]=m.vbo[2]=0;
        m.pos = (float *)malloc(sizeof(float) * 3 * (size_t)nv);
        m.uv = (float *)malloc(sizeof(float) * 2 * (size_t)nv);
        m.idx = (uint16_t *)malloc(sizeof(uint16_t) * (size_t)ni);
        if (!m.pos || !m.uv || !m.idx) { free(m.pos); free(m.uv); free(m.idx); continue; }
        const float *fp = (const float *)pp; const float *fu = (const float *)pu;
        for (int v = 0; v < nv; v++) {
            m.pos[v*3]=fp[v*3]; m.pos[v*3+1]=fp[v*3+1]; m.pos[v*3+2]=fp[v*3+2]; // 零换算（与 web 一致）
            m.uv[v*2]=fu[v*2]; m.uv[v*2+1]=fu[v*2+1]; // 不翻转（web 移植页实锤：GLTFLoader 对 glTF 贴图 flipY=false，翻了会被 alphaTest 吃成锥体残件）
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
            if (isRot) an.rot[ni] = k; else an.pos[ni] = k; // 位移与节点同单位，零换算（与 web 一致）
        }
        // translation 输出是绝对位移（含 pivot），与节点同单位零换算（与 web 一致；勿乘 16）
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
    MWBLogFile(@"[GLB] 解析成功 构建=%@ 节点=%lu 网格=%lu 三角=%ld Root子树=%lu 动画=%lu 贴图=%lu字节 sidecar=%@",
               @MWB_BUILD_TAG,(unsigned long)sNodes.size(), (unsigned long)sMeshes.size(), totalTris,
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
    sTex = 0; sTMain = 0; sTVis = 0; sVBOInit = NO;
    sParsed = NO;
    MWBLogFile(@"[GLB] 重载");
    MWBGLBEnsureParsed();
}

void MWBGLBSetAnim(NSString *name) {
    sCurAnim = [name copy] ?: @"idle";
    sTMain = 0; // 切 clip 从头播（中途切不断帧，跳动作不抽搐）
    MWBLogFile(@"[GLB] 切动作 %@", sCurAnim);
}

// ---- 自动动作（香草接轨）：优先级 death > 睡 > 水 > 飞 > 空中 > 潜行 > 跑/走/闲 ----
// 状态信号（kuna 反 0.10 实锤，全直接读偏移，零游戏调用，normalTick 内调安全）：
// - 睡 Player::isSleeping=+0x1804；水 Entity::isInWater=+0x12d；落地 Entity::move 写 +0x125；
// - 潜行 LocalPlayer::isSneaking=*(*(p+0x1810)+0x12)；飞 abil[1]；血 int +0x168；vy +0x70；
// - 速度照抄 Mob::updateWalkAnim：水平位移 hypot(dx,dz)/dt，米/秒＋EMA＋迟滞（跑 5.4/4.6，走 0.6/0.35）。
static BOOL sGLBAuto = YES;
void MWBGLBSetAuto(BOOL on) {
    sGLBAuto = on;
    MWBLogFile(@"[GLB] 自动动作%@", on ? @"开" : @"关");
}
void MWBGLBAutoTick(void *player) {
    if (!sGLBAuto || !player) return;
    static int sCd = 0;
    if ((sCd++ % 10) != 0) return; // 秒级状态，10 tick 判一次不抖不费
    char *p = (char *)player;
    float now = (float)[[NSDate date] timeIntervalSince1970];
    static float sPx = 0, sPz = 0, sT = 0, sSpd = 0;
    static BOOL sInit = NO;
    static int sLoc = 0; // 0 闲 1 走 2 跑（迟滞位）
    float px = *(float *)(p + 0x28), pz = *(float *)(p + 0x28 + 8);
    float vy = *(float *)(p + 0x70);
    if (!sInit) { sInit = YES; sPx = px; sPz = pz; sT = now; }
    else if (now > sT) {
        float dt = now - sT;
        if (dt > 0.005f && dt < 2.0f) {
            float inst = sqrtf((px - sPx) * (px - sPx) + (pz - sPz) * (pz - sPz)) / dt;
            if (inst < 30.0f) sSpd += 0.3f * (inst - sSpd); // EMA，钳传送毛刺
        }
        sPx = px; sPz = pz; sT = now;
    }
    int hp = *(int *)(p + 0x168);
    uint8_t water = *(uint8_t *)(p + 0x12d);
    uint8_t sleep = *(uint8_t *)(p + 0x1804);
    uint8_t ground = *(uint8_t *)(p + 0x125);
    BOOL flying = (p + PLAYER_ABILITIES_OFFSET)[1];
    void *t = *(void **)(p + 0x1810);
    BOOL sneak = t ? *(uint8_t *)((char *)t + 0x12) : NO;
    const char *want = "idle";
    if (hp <= 0) want = "death";
    else if (sleep) want = "sleep";
    else if (water) want = (sSpd > 0.5f) ? "swim" : "swim_stand";
    else if (flying) want = "fly";
    else if (!ground) want = (vy > 0.25f) ? "jump" : ((vy < -0.25f) ? "drop_loop" : "hover");
    else if (sneak) { want = "sneak"; sLoc = 0; }
    else {
        float s = sSpd;
        if (s > 5.4f) sLoc = 2;
        else if (s < 4.6f && sLoc == 2) sLoc = 1;
        else if (s > 0.6f && sLoc == 0) sLoc = 1;
        else if (s < 0.35f) sLoc = 0;
        want = (sLoc == 2) ? "run" : ((sLoc == 1) ? "walk" : "idle");
    }
    if (sLoc != 0 && (want[0] != 'r' && want[0] != 'w')) sLoc = 0; // 离开 locomotion 复位迟滞
    static char sLast[32] = "idle";
    if (strcmp(sLast, want) != 0) {
        snprintf(sLast, sizeof(sLast), "%s", want);
        MWBGLBSetAnim([NSString stringWithUTF8String:want]);
    }
}

// ---- 自家贴图（ES1 固定管线：游戏纹理不动，只绑自己的画完恢复；Nearest 像素风）
static BOOL GLBInitGL(void) {
    if (sTex) return YES;
    // 贴图上传（PNG 解码 + Nearest，不过滤，viewer 同款像素风；绑定要恢复，免得污染游戏后画）
    if (sTexPNG) {
        GLint oldBind = 0;
        glGetIntegerv(GL_TEXTURE_BINDING_2D, &oldBind);
        CGImageSourceRef src = CGImageSourceCreateWithData((CFDataRef)sTexPNG, NULL);
        CGImageRef img = src ? CGImageSourceCreateImageAtIndex(src, 0, NULL) : NULL;
        if (img) {
            size_t w = CGImageGetWidth(img), h = CGImageGetHeight(img);
            void *px = calloc(w * h, 4);
            CGContextRef ctx = CGBitmapContextCreate(px, w, h, 8, w*4,
                CGColorSpaceCreateDeviceRGB(), kCGImageAlphaPremultipliedLast);
            if (ctx) {
                // 上传行序与 web 对齐（ImageBitmap 内存行序 = PNG 行序，不翻转）：
                // 实锤：加 CTM 翻转后 iPad 只剩锥体残件，与 web"UV 翻转版"一模一样（alphaTest 吃掉镜像区）；
                // 而旧 YSM 路径（MWBYSMModel.mm:302，无 CTM 翻转）在真机显示正常。
                // 故此处不翻（与 YSM 路径逐字节同款上传）；数据侧 UV 同样不翻转，两边都与 web 一致。
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
        glBindTexture(GL_TEXTURE_2D, oldBind); // 恢复，免得后画全吃错贴图
    }
    return YES;
}

// ---- WVP 快照（render hook 内 orig 之前调，只读 uniform 不碰状态机） ----
// 背景：游戏实体 shader（prog 48 那套）把 WORLD 与 WORLDVIEWPROJ 分开传，
// WVP 只是相机 P·V，实体偏移全在 WORLD 里；只乘 WVP 会把鱼画到世界原点，
// 相机看玩家时原点正好在镜头后（w<0），就是"透明啥也没有"的根因。
// 故快照把两个都读走，绘制用 MVP = WVP·WORLD·节点世界（WORLD 缺席则退回直用）。
static float sSnapWVP[16]; static BOOL sHasSnapWVP = NO;
static float sSnapWorld[16]; static BOOL sHasSnapWorld = NO;
static GLuint sSnapProg = 0; static GLint sSnapWVPLoc = -2; static GLint sSnapWorldLoc = -2;
void MWBGLBSnapshotWVP(void) {
    GLint gprog = 0; glGetIntegerv(GL_CURRENT_PROGRAM, &gprog);
    if ((GLuint)gprog != sSnapProg) {
        sSnapProg = (GLuint)gprog;
        sSnapWVPLoc = (sSnapProg == 0) ? -1 : glGetUniformLocation(sSnapProg, "WORLDVIEWPROJ");
        sSnapWorldLoc = (sSnapProg == 0) ? -1 : glGetUniformLocation(sSnapProg, "WORLD");
        MWBLogFile(@"[GLB] 快照 prog=%u wvp=%d world=%d", sSnapProg, sSnapWVPLoc, sSnapWorldLoc);
    }
    if (sSnapWVPLoc < 0) { sHasSnapWVP = NO; return; }
    glGetUniformfv(sSnapProg, sSnapWVPLoc, sSnapWVP);
    if (sSnapWorldLoc >= 0) { glGetUniformfv(sSnapProg, sSnapWorldLoc, sSnapWorld); sHasSnapWorld = YES; }
    else sHasSnapWorld = NO;
    sHasSnapWVP = YES;
}

// ---- 绘制（VBO + 自家 shader，全 ES3 合法；MVP = 快照WVP · 节点世界） ----
static char sGLVer[128] = {0}, sGLRen[128] = {0}; // GL 线程缓存版本串（诊断用）
void MWBGLBLogDiag(void) {
    extern int MWB010GLCalls(void);
    MWBLogFile(@"[GLB] 诊断 开关=%d 解析=%d 网格=%lu WVP读回loc=%d uniform调用=%d 版本=%s 渲染器=%s",
               gGLBModel, sParsed, (unsigned long)sMeshes.size(),
               sProjLoc, MWB010GLCalls(), sGLVer, sGLRen);
}
// 开关+解析齐就藏原版（画不出时诊断会说，不再静默）
BOOL MWBGLBCanDraw(void) {
    return gGLBModel && sParsed && !sRootSet.empty();
}
void MWBGLBDraw(void) {
    if (!gGLBModel || !sParsed || sRootSet.empty()) return;
    if (!sGLVer[0]) {
        const char *v = (const char *)glGetString(GL_VERSION);
        const char *r = (const char *)glGetString(GL_RENDERER);
        if (v) strncpy(sGLVer, v, sizeof(sGLVer)-1);
        if (r) strncpy(sGLRen, r, sizeof(sGLRen)-1);
        MWBLogFile(@"[GLB] GL版本=%s 渲染器=%s", sGLVer, sGLRen);
    }
    if (!GLBInitGL() || !sTex) return;
    if (!GLBInitProg() || !sProg) return;
    if (!sVBOInit) {
        sVBOInit = YES;
        GLint oldAB = 0, oldEB = 0;
        glGetIntegerv(GL_ARRAY_BUFFER_BINDING, &oldAB);
        glGetIntegerv(GL_ELEMENT_ARRAY_BUFFER_BINDING, &oldEB);
        for (auto &m : sMeshes) {
            m.vbo[0] = m.vbo[1] = m.vbo[2] = 0;
            if (m.nvert <= 0 || m.nidx <= 0) continue;
            glGenBuffers(3, m.vbo);
            glBindBuffer(GL_ARRAY_BUFFER, m.vbo[0]);
            glBufferData(GL_ARRAY_BUFFER, (GLsizeiptr)(m.nvert*3*sizeof(float)), m.pos, GL_STATIC_DRAW);
            glBindBuffer(GL_ARRAY_BUFFER, m.vbo[1]);
            glBufferData(GL_ARRAY_BUFFER, (GLsizeiptr)(m.nvert*2*sizeof(float)), m.uv, GL_STATIC_DRAW);
            glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, m.vbo[2]);
            glBufferData(GL_ELEMENT_ARRAY_BUFFER, (GLsizeiptr)(m.nidx*sizeof(uint16_t)), m.idx, GL_STATIC_DRAW);
        }
        glBindBuffer(GL_ARRAY_BUFFER, oldAB);
        glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, oldEB);
        MWBLogFile(@"[GLB] VBO 上传完成 网格=%lu", (unsigned long)sMeshes.size());
    }
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

    // 世界矩阵（只算 Root 子树；local = T·R·S；位移/旋转走 track，无则 base）
    static std::vector<float> sWorld; // 每节点 16
    sWorld.assign(sNodes.size() * 16, 0);
    std::vector<char> sHidden(sNodes.size(), 0);
    std::vector<float> sScaleX(sNodes.size()*3, 0);
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
        float t[3], q[4];
        memcpy(t, sNodes[ni].t, sizeof(t)); memcpy(q, sNodes[ni].q, sizeof(q));
        if (an) {
            auto rp = an->rot.find(ni); if (rp != an->rot.end()) GLBRotAt(&rp->second, sTMain, loop, len, q);
            auto pp = an->pos.find(ni); if (pp != an->pos.end()) GLBPosAt(&pp->second, sTMain, loop, len, t);
        }
        float L[16]; GLBLocalMat(t, q, sc, L);
        memcpy(&sWorld[ni*16], L, sizeof(L));
    }
    auto rIt = sName2Idx.find("Root");
    int rootIdx = (rIt != sName2Idx.end()) ? rIt->second : sRootSet[0];
    std::vector<int> stack; stack.push_back(rootIdx);
    std::vector<int> dfs;
    while (!stack.empty()) { int c = stack.back(); stack.pop_back(); dfs.push_back(c);
        for (int k : sNodes[c].children) stack.push_back(k); }
    for (size_t di = 1; di < dfs.size(); di++) {
        int ni = dfs[di], pi = sNodes[ni].parent;
        float W[16]; GLBMatMul(&sWorld[pi*16], &sWorld[ni*16], W);
        memcpy(&sWorld[ni*16], W, sizeof(W));
    }
    // WVP 快照（hook 内 orig 之前抓的本实体 program 矩阵；post-orig 读会拿到别的 pass，w<0 就是这么来的）
    if (!sHasSnapWVP) {
        static int sNoSnap = 0;
        if (!sNoSnap) { sNoSnap = 1; MWBLogFile(@"[GLB] 无快照WVP（prog=%u wvp=%d）", sSnapProg, sSnapWVPLoc); }
        return;
    }
    // MVP 组装（与 web 对齐的最终形态：自家已知相机，不再读游戏 program 矩阵）。
    // 背景：prog 42 的 WORLDVIEWPROJ 经多轮日志实锤不是 gameplay 相机（原点恒居中/z 恒越界，
    // 疑似天空或固定 pass；pre/post 同值，换时机没用）。web SIM 相机同理可验证，故 iPad 也用自家相机：
    //  P(60°/视口比/0.1/1000) · V(eye=玩家+(6,8,6) 世界固定偏置俯视，免 yaw 约定风险) · T(玩家) · 节点世界。
    // 节点世界数学与 web/js/plugin-glb.js 逐元一致；相机/T 落位是 iPad 侧实体概念，日志可验。
    float WVP[16];
    float ppx0 = gLocalPlayer ? *(float *)((char *)gLocalPlayer + 0x28) : 0;
    float ppy0 = gLocalPlayer ? *(float *)((char *)gLocalPlayer + 0x28 + 4) : 0;
    float ppz0 = gLocalPlayer ? *(float *)((char *)gLocalPlayer + 0x28 + 8) : 0;
    {
        float ex = ppx0 + 6.0f, ey = ppy0 + 8.0f, ez = ppz0 + 6.0f; // 眼睛（世界固定偏置）
        float cx = ppx0, cy = ppy0 + 1.0f, cz = ppz0;              // 看点（玩家胸口）
        // 列主序 lookAt（three.js 同款：z=normalize(eye-center)，x=normalize(up×z)，y=z×x）
        float zx = ex - cx, zy = ey - cy, zz = ez - cz;
        float zl = sqrtf(zx*zx + zy*zy + zz*zz); if (zl < 1e-6f) zl = 1; zx/=zl; zy/=zl; zz/=zl;
        float xx = zz, xy = 0.0f, xz = -zx; // up=(0,1,0)×z = (zz,0,-zx)，顺序写反会整图滚转180°
        float xl = sqrtf(xx*xx + xy*xy + xz*xz); if (xl < 1e-6f) xl = 1; xx/=xl; xy/=xl; xz/=xl;
        float yx = zy*xz - zz*xy, yy = zz*xx - zx*xz, yz = zx*xy - zy*xx;
        float V[16] = {xx,yx,zx,0, xy,yy,zy,0, xz,yz,zz,0,
                        -(xx*ex+xy*ey+xz*ez), -(yx*ex+yy*ey+yz*ez), -(zx*ex+zy*ey+zz*ez), 1};
        GLint vp[4] = {0,0,0,0}; glGetIntegerv(GL_VIEWPORT, vp); // 游戏视口比（web 用 canvas 比，同理）
        float aspect = (vp[2] > 0 && vp[3] > 0) ? (float)vp[2] / (float)vp[3] : 1.0f;
        float f = 1.0f / tanf(60.0f * 0.5f * (float)M_PI / 180.0f);
        float nf = 1.0f / (0.1f - 1000.0f);
        float P[16] = {f/aspect,0,0,0, 0,f,0,0, 0,0,(1000.0f+0.1f)*nf,-1, 0,0,2*1000.0f*0.1f*nf,0};
        GLBMatMul(P, V, WVP);
    }
    static int sVpLogged = 0;
    if (!sVpLogged) {
        GLint vp[4] = {0,0,0,0}; glGetIntegerv(GL_VIEWPORT, vp);
        sVpLogged = 1;
        MWBLogFile(@"[GLB] 自家相机 视口=%dx%d aspect=%.3f", vp[2], vp[3],
                   (vp[2] > 0 && vp[3] > 0) ? (float)vp[2] / (float)vp[3] : -1.0f);
    }
    float WVPuse[16]; memcpy(WVPuse, WVP, sizeof(WVPuse));
    float WVPalt[16]; memcpy(WVPalt, sSnapWVP, sizeof(WVPalt)); // alt=游戏 WVP（prog42）直用对照，专供日志证明它不对
    // 对照：draw 时（post-orig）当前 program 的 WVP 也读一份，看和 pre-orig 是否同一矩阵
    GLint postProg = 0; glGetIntegerv(GL_CURRENT_PROGRAM, &postProg);
    float postWVP[16]; BOOL hasPost = NO;
    if (postProg != 0) {
        GLint postLoc = glGetUniformLocation((GLuint)postProg, "WORLDVIEWPROJ");
        if (postLoc >= 0) { glGetUniformfv((GLuint)postProg, postLoc, postWVP); hasPost = YES; }
    }
    // 实体落位：节点世界是模型本地（web SIM 相机直接看原点），游戏里必须先平移到玩家脚下。
    // T 只含位移（玩家朝向不管，鱼恒朝世界方向；与 web 姿势数学一致，落位是 iPad 侧实体概念）。
    // 玩家坐标 LocalPlayer+0x28（与矩阵探针/小地图同源）。
    float WT[16]; // WT = WVP · T(玩家位姿)，每帧一次，逐 mesh 只剩一次 4x4 乘
    static float sYawDbg = 0, sThDbg = 0; // 首顶点行同行打出，对朝向（符号反了截图即见脸朝后）
    if (gLocalPlayer) {
        float px = *(float *)((char *)gLocalPlayer + 0x28);
        float py = *(float *)((char *)gLocalPlayer + 0x28 + 4);
        float pz = *(float *)((char *)gLocalPlayer + 0x28 + 8);
        // T = 平移(玩家脚下)·绕Y(跟玩家朝向)：模型正面是 -z，玩家 yaw=0 朝南(+z，同 Java)，
        // 故 θ=π-yaw（把 -z 转到 facing；若真机脸朝后，把 π-yaw 改成 π+yaw，见日志 yaw 值）。
        float yawDeg = *(float *)((char *)gLocalPlayer + ENTITY_YAW_OFF);
        float th = (180.0f - yawDeg) * (float)M_PI / 180.0f;
        sYawDbg = yawDeg; sThDbg = th;
        float ct = cosf(th), st = sinf(th);
        float T[16] = {ct,0,-st,0, 0,1,0,0, st,0,ct,0, px,py,pz,1};
        GLBMatMul(WVP, T, WT);
    } else {
        memcpy(WT, WVP, sizeof(WT));
    }

    // ES3 现场保存（只动用到的状态）
    GLint oldProg = 0, oldTex = 0, oldActive = 0, oldAB = 0, oldEB = 0;
    glGetIntegerv(GL_CURRENT_PROGRAM, &oldProg);
    glGetIntegerv(GL_TEXTURE_BINDING_2D, &oldTex);
    glGetIntegerv(GL_ACTIVE_TEXTURE, &oldActive);
    glGetIntegerv(GL_ARRAY_BUFFER_BINDING, &oldAB);
    glGetIntegerv(GL_ELEMENT_ARRAY_BUFFER_BINDING, &oldEB);
    GLboolean cullEn = glIsEnabled(GL_CULL_FACE);
    GLint e0=0, e1=0, b0=0, b1=0, s0=0, t0=0, st0=0, n0=0, s1=0, t1=0, st1=0, n1=0;
    void *p0 = NULL, *p1 = NULL;
    glGetVertexAttribiv(0, GL_VERTEX_ATTRIB_ARRAY_ENABLED, &e0);
    glGetVertexAttribiv(1, GL_VERTEX_ATTRIB_ARRAY_ENABLED, &e1);
    glGetVertexAttribiv(0, GL_VERTEX_ATTRIB_ARRAY_BUFFER_BINDING, &b0);
    glGetVertexAttribiv(1, GL_VERTEX_ATTRIB_ARRAY_BUFFER_BINDING, &b1);
    glGetVertexAttribiv(0, GL_VERTEX_ATTRIB_ARRAY_SIZE, &s0);
    glGetVertexAttribiv(0, GL_VERTEX_ATTRIB_ARRAY_TYPE, &t0);
    glGetVertexAttribiv(0, GL_VERTEX_ATTRIB_ARRAY_STRIDE, &st0);
    glGetVertexAttribiv(0, GL_VERTEX_ATTRIB_ARRAY_NORMALIZED, &n0);
    glGetVertexAttribiv(1, GL_VERTEX_ATTRIB_ARRAY_SIZE, &s1);
    glGetVertexAttribiv(1, GL_VERTEX_ATTRIB_ARRAY_TYPE, &t1);
    glGetVertexAttribiv(1, GL_VERTEX_ATTRIB_ARRAY_STRIDE, &st1);
    glGetVertexAttribiv(1, GL_VERTEX_ATTRIB_ARRAY_NORMALIZED, &n1);
    glGetVertexAttribPointerv(0, GL_VERTEX_ATTRIB_ARRAY_POINTER, &p0);
    glGetVertexAttribPointerv(1, GL_VERTEX_ATTRIB_ARRAY_POINTER, &p1);

    glUseProgram(sProg);
    glUniform1i(sUTex, 0);
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, sTex);
    glDisable(GL_CULL_FACE); // 双面（viewer doubleSide 同款）
    long drawn = 0, tris = 0; long shown = 0, total = 0;
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
        if (!m.vbo[0]) continue;
        float M[16]; GLBMatMul(WT, &sWorld[ni*16], M);
        glUniformMatrix4fv(sUMVP, 1, GL_FALSE, M);
        glBindBuffer(GL_ARRAY_BUFFER, m.vbo[0]);
        glEnableVertexAttribArray(0);
        glVertexAttribPointer(0, 3, GL_FLOAT, GL_FALSE, 0, 0);
        glBindBuffer(GL_ARRAY_BUFFER, m.vbo[1]);
        glEnableVertexAttribArray(1);
        glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 0, 0);
        glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, m.vbo[2]);
        glDrawElements(GL_TRIANGLES, m.nidx, GL_UNSIGNED_SHORT, 0);
        drawn++; tris += m.nidx / 3;
        if (drawn == 1 && m.nvert > 0) {
            // 首顶点裁剪坐标（免截图定位：NDC 在 [-1,1] 内才可见；w<=0 在镜头后；NaN 即矩阵坏）
            // 用/备两种 MVP 都算：ndc=用WVPuse，alt=省WORLD直用（WORLD 缺席时两者同值）
            float x = m.pos[0], y = m.pos[1], z = m.pos[2];
            float cx = M[0]*x + M[4]*y + M[8]*z + M[12];
            float cy = M[1]*x + M[5]*y + M[9]*z + M[13];
            float cz = M[2]*x + M[6]*y + M[10]*z + M[14];
            float cw = M[3]*x + M[7]*y + M[11]*z + M[15];
            float Malt[16]; GLBMatMul(WVPalt, &sWorld[ni*16], Malt);
            float ax = Malt[0]*x + Malt[4]*y + Malt[8]*z + Malt[12];
            float ay = Malt[1]*x + Malt[5]*y + Malt[9]*z + Malt[13];
            float az = Malt[2]*x + Malt[6]*y + Malt[10]*z + Malt[14];
            float aw = Malt[3]*x + Malt[7]*y + Malt[11]*z + Malt[15];
            // post-orig 对照：同顶点用 draw 时刻 program 矩阵再算一遍；玩家坐标同行打出，对 T 落位
            float qx = x, qy = y, qz = z, qw = 1;
            if (hasPost) {
                float Mp[16]; GLBMatMul(postWVP, &sWorld[ni*16], Mp);
                qx = Mp[0]*x + Mp[4]*y + Mp[8]*z + Mp[12];
                qy = Mp[1]*x + Mp[5]*y + Mp[9]*z + Mp[13];
                qz = Mp[2]*x + Mp[6]*y + Mp[10]*z + Mp[14];
                qw = Mp[3]*x + Mp[7]*y + Mp[11]*z + Mp[15];
            }
            float ppx = gLocalPlayer ? *(float *)((char *)gLocalPlayer + 0x28) : 9999;
            float ppy = gLocalPlayer ? *(float *)((char *)gLocalPlayer + 0x28 + 4) : 9999;
            float ppz = gLocalPlayer ? *(float *)((char *)gLocalPlayer + 0x28 + 8) : 9999;
            MWBLogFile(@"[GLB] 首顶点 prog=%u world=%d post=%d 玩家=(%.1f,%.1f,%.1f) yaw=%.1f th=%.2f 世界=(%.1f,%.1f,%.1f) clip=(%.1f,%.1f,%.1f,%.1f) ndc=(%.2f,%.2f,%.2f) alt=(%.2f,%.2f,%.2f) postndc=(%.2f,%.2f,%.2f)",
                       sSnapProg, sHasSnapWorld ? 1 : 0, hasPost ? (int)postProg : -1, ppx, ppy, ppz, sYawDbg, sThDbg, x, y, z, cx, cy, cz, cw,
                       cw != 0 ? cx/cw : 999, cw != 0 ? cy/cw : 999, cw != 0 ? cz/cw : 999,
                       aw != 0 ? ax/aw : 999, aw != 0 ? ay/aw : 999, aw != 0 ? az/aw : 999,
                       qw != 0 ? qx/qw : 999, qw != 0 ? qy/qw : 999, qw != 0 ? qz/qw : 999);
        }
    }

    // 现场恢复
    if (e0) glEnableVertexAttribArray(0); else glDisableVertexAttribArray(0);
    if (e1) glEnableVertexAttribArray(1); else glDisableVertexAttribArray(1);
    glBindBuffer(GL_ARRAY_BUFFER, (GLuint)b0);
    glVertexAttribPointer(0, s0, t0, n0, st0, p0);
    glBindBuffer(GL_ARRAY_BUFFER, (GLuint)b1);
    glVertexAttribPointer(1, s1, t1, n1, st1, p1);
    glBindBuffer(GL_ARRAY_BUFFER, oldAB);
    glBindBuffer(GL_ELEMENT_ARRAY_BUFFER, oldEB);
    if (cullEn) glEnable(GL_CULL_FACE); else glDisable(GL_CULL_FACE);
    glActiveTexture(oldActive);
    glBindTexture(GL_TEXTURE_2D, oldTex);
    glUseProgram(oldProg);

    static int sFrames = 0; sFrames++;
    if (sFrames == 1 || sFrames % 600 == 0)
        MWBLogFile(@"[GLB] 存活帧=%d 本帧网格=%ld 三角=%ld 可见=%ld/%ld", sFrames, drawn, tris, shown, total);
}
