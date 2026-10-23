// MWBGLBModel.mm — GLB 直解 + 鱼链绘制（变换/叠加语义逐字照抄 viewer + ysm_to_glb.py）
// viewer 里 three.js 做的事，这里拆成三件：
//  1) GLB 解析：头/JSON/BIN 三段，NSJSONSerialization，只读 float32 + uint16（转换器只写这两种）；
//  2) 姿势：MWBYSMAnim 运行时直接吃 YSM 原始关键帧（fatfish_anim.json：全量旋转/位移/缩放＋molang＋分层，
//     取代旧的 GLB 四元数 clip＋scale sidecar，那条链丢了全部 molang 通道且插值/叠层都不对）；
//  3) 绘制：走已验证的鱼链（单次 sPartRender(root, s6)＋游戏递归＋自家贴图绑定），
//     盒子/UV/贴图走 ysm codec（RestoreCube 现成），骨架/动画/显隐走 GLB。
// 单位：游戏渲染就是 Bedrock/米制单位，GLB 解析零换算（web 移植页实锤：之前误乘 16
// 会把鱼放大 16 倍、相机包 inside，只能看到巨型多边形；iPad 症状一致）。
// UV：不翻转（GLTFLoader 对 glTF 贴图 flipY=false；上传链内存行序见 GLBInitGL 注释，必须同 web 一致）。
#import "MWBGLBModel.h"
#import "MWBYSMAnim.h" // YSM 动画运行时（姿势唯一来源）
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

static std::vector<GLBNode> sNodes;
static std::map<std::string, int> sName2Idx;
static std::vector<GLBMesh> sMeshes;
static std::vector<int> sRootSet; // Root 子树（含 Root），只画这些
static NSData *sTexPNG = nil;
static BOOL sParsed = NO;
static std::vector<float> sNodeT; // 3*节点：相对父轴心位移（运行时局部矩阵用）
static BOOL sAnimOK = NO;          // <模型>_anim.json 载入成功（否则画绑定姿势）
// 落位三件套：本体缩放 sGLBScale（默认 1x，2x 实机太大已回退）＋Y 偏置 sGLBLift（接地算法上再叠）＋
// 模型最低点 sMinY（解析期扫全顶点，判原点是否在脚）＋实地顶面 sGroundY（AutoTick 方块扫描）。
static float sGLBScale = 1.0f, sGLBLift = 0.0f, sMinY = 1e30f;
static float sGroundY = 0; static BOOL sHasGround = NO;
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

// 当前模型 id（橱窗选中，NSUserDefaults MWBYSMModel；文件 mwbmodels/<id>.glb ＋ <id>_anim.json）
NSString *MWBGLBModelId(void) {
    NSString *m = [[NSUserDefaults standardUserDefaults] stringForKey:@"MWBYSMModel"];
    return m.length ? m : @"fatfish";
}
void MWBGLBSetModel(NSString *mid) {
    if (!mid.length || [mid isEqualToString:MWBGLBModelId()]) return;
    [[NSUserDefaults standardUserDefaults] setObject:mid forKey:@"MWBYSMModel"];
    MWBLogFile(@"[GLB] 切模型 %@", mid);
    if (sParsed) MWBGLBReload(); // GL 对象下次首画重建
}

BOOL MWBGLBEnsureParsed(void) {
    if (sParsed) return YES;
    NSString *dir = @"/var/mobile/Documents/mwbmodels", *mid = MWBGLBModelId();
    NSString *glbPath = [dir stringByAppendingPathComponent:[mid stringByAppendingString:@".glb"]];
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
    NSArray *jAccs = j[@"accessors"], *jViews = j[@"bufferViews"];
    if (!jNodes || !jMeshes || !jAccs || !jViews) { MWBLogFile(@"[GLB] 缺段"); return NO; }

    sNodes.clear(); sName2Idx.clear(); sMeshes.clear(); sRootSet.clear();
    sMinY = 1e30f; // 本轮重扫最低点
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
            if (m.pos[v*3+1] < sMinY) sMinY = m.pos[v*3+1]; // 记最低点（判原点是否在脚）
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
    // YSM 动画运行时（姿势唯一来源；缺文件则画绑定姿势）
    {
        std::vector<const char *> names; names.reserve(sNodes.size());
        sNodeT.assign(sNodes.size() * 3, 0);
        for (size_t i = 0; i < sNodes.size(); i++) {
            names.push_back(sNodes[i].name.c_str());
            memcpy(&sNodeT[i * 3], sNodes[i].t, sizeof(float) * 3);
        }
        sAnimOK = MWBAnimLoad([dir stringByAppendingPathComponent:[mid stringByAppendingString:@"_anim.json"]], names.data(), (int)names.size());
    }
    sParsed = YES;
    MWBLogFile(@"[GLB] 解析成功 构建=%@ 节点=%lu 网格=%lu 三角=%ld Root子树=%lu 贴图=%lu字节 YSM动画=%@ minY=%.2f",
               @MWB_BUILD_TAG,(unsigned long)sNodes.size(), (unsigned long)sMeshes.size(), totalTris,
               (unsigned long)sRootSet.size(), (unsigned long)(sTexPNG ? sTexPNG.length : 0), sAnimOK ? @"有" : @"无", sMinY);
    MWBGLBLogStats();
    return YES;
}

void MWBGLBLogStats(void) {
    MWBLogFile(@"[GLB] 自检 节点=%lu 网格=%lu Root子树=%lu YSM动画=%@ 主=%s 控制器=%s 寿命=%.1f 二阶=%d",
               (unsigned long)sNodes.size(), (unsigned long)sMeshes.size(), (unsigned long)sRootSet.size(),
               sAnimOK ? @"有" : @"无", MWBAnimMainName(), MWBAnimCtrlState(), MWBAnimLife(), MWBAnimSecondOrderCount());
}

// 免重启重载（调参不用反复杀进程；GL 对象下次首画重建）
void MWBGLBReload(void) {
    for (auto &m : sMeshes) { free(m.pos); free(m.uv); free(m.idx); }
    sMeshes.clear(); sNodes.clear(); sName2Idx.clear(); sRootSet.clear();
    sTexPNG = nil; MWBAnimUnload(); sAnimOK = NO;
    if (sTex) { /* GL 线程外不删，下次首画复用或重建 */ }
    sTex = 0; sVBOInit = NO;
    sParsed = NO;
    MWBLogFile(@"[GLB] 重载");
    MWBGLBEnsureParsed();
}

void MWBGLBSetAnim(NSString *name) {
    MWBAnimForceMain(name.length ? name.UTF8String : NULL); // 手动主动画（sticky，glbanim-auto 回自动）
    MWBLogFile(@"[GLB] 手动主动画 %@", name ?: @"(自动)");
}

// ---- 动画输入采集（香草状态 → MWBAnimInput；主动画选择在运行时内，与 web pickMain 同） ----
// 状态信号（kuna 反 0.10 实锤，全直接读偏移，零游戏调用，normalTick 内调安全）：
// - 睡 Player::isSleeping=+0x1804；水 Entity::isInWater=+0x12d；落地 Entity::move 写 +0x125；
// - 潜行 LocalPlayer::isSneaking=*(*(p+0x1810)+0x12)；飞 abil[1]；血 int +0x168；
// - 速度：位置差分/实际时间（米/秒，EMA）；视角 yaw +0x78、身体 yaw +0x150、俯仰 +0x7c（度）。
static BOOL sGLBAuto = YES;
void MWBGLBSetAuto(BOOL on) {
    sGLBAuto = on;
    if (on) MWBAnimForceMain(NULL);
    MWBLogFile(@"[GLB] 自动动作%@", on ? @"开" : @"关");
}
void MWBGLBSetScale(float s) {
    if (s > 0.05f && s < 20.0f) sGLBScale = s;
    MWBLogFile(@"[GLB] 本体缩放 x%.2f", sGLBScale);
}
void MWBGLBSetLift(float m) {
    if (m > -10.0f && m < 10.0f) sGLBLift = m;
    MWBLogFile(@"[GLB] 落位偏置 %+.2f米", sGLBLift);
}
static float GLBWrap180(float a) { a = fmodf(a + 180.0f, 360.0f); if (a < 0) a += 360.0f; return a - 180.0f; }
void MWBGLBAutoTick(void *player) {
    if (!player) return;
    char *p = (char *)player;
    double now = CFAbsoluteTimeGetCurrent();
    static double sT = 0; static float sPx = 0, sPy = 0, sPz = 0, sBody = 0, sGs = 0, sVs = 0, sYs = 0;
    float px = *(float *)(p + 0x28), py = *(float *)(p + 0x28 + 4), pz = *(float *)(p + 0x28 + 8);
    float body = *(float *)(p + ENTITY_BODY_YAW_OFF), view = *(float *)(p + ENTITY_YAW_OFF);
    if (sT > 0) {
        float dt = (float)(now - sT);
        if (dt > 0.005f && dt < 2.0f) {
            float gs = sqrtf((px - sPx) * (px - sPx) + (pz - sPz) * (pz - sPz)) / dt;
            float vs = (py - sPy) / dt, ys = GLBWrap180(body - sBody) / dt;
            if (gs < 30.0f) sGs += 0.4f * (gs - sGs);   // EMA，钳传送毛刺
            if (fabsf(vs) < 60.0f) sVs += 0.5f * (vs - sVs);
            sYs += 0.4f * (ys - sYs);
        }
    }
    sT = now; sPx = px; sPy = py; sPz = pz; sBody = body;
    uint8_t water = *(uint8_t *)(p + 0x12d), ground = *(uint8_t *)(p + 0x125);
    // 接地扫描：站立跟实地顶面（+0x28 是眼，直接扫方块），飞/游/空跟玩家（sHasGround=NO 时画侧回落到眼-1.62）。
    // 只在落地非水时扫（ts=*(p+0x48)，getTile tick 线程只读可调，小地图同款），10 tick 一次。
    static int sCd = 0;
    if ((sCd++ % 10) == 0) {
        if (ground && !water) {
            void *ts = *(void **)(p + 0x48);
            sHasGround = NO;
            if (ts) {
                int cx = (int)floorf(px), cz = (int)floorf(pz);
                for (int y = (int)floorf(py); y > (int)floorf(py) - 14 && y >= 0; y--) {
                    MWBBlockPos bp = {cx, y, cz};
                    uint8_t id = MWB010GetTile(ts, &bp);
                    if (id != 0 && id != 8 && id != 9) { sGroundY = (float)(y + 1); sHasGround = YES; break; }
                }
            }
        } else sHasGround = NO;
    }
    void *t = *(void **)(p + 0x1810);
    MWBAnimInput in;
    in.groundSpeed = sGs; in.vertSpeed = sVs; in.yawSpeed = sYs;
    in.headYaw = GLBWrap180(view - body);
    in.headPitch = *(float *)(p + ENTITY_PITCH_OFF);
    in.onGround = ground != 0; in.inWater = water != 0;
    in.flying = (p + PLAYER_ABILITIES_OFFSET)[1] != 0;
    in.sneaking = t ? *(uint8_t *)((char *)t + 0x12) != 0 : NO;
    in.sleeping = *(uint8_t *)(p + 0x1804) != 0;
    in.dead = *(int *)(p + 0x168) <= 0;
    in.swinging = NO;
    MWBAnimSetInput(&in);
    static int sLogCd = 0;
    if ((sLogCd++ % 200) == 0)
        MWBLogFile(@"[YSM动画] 输入 地速=%.2f 竖速=%.2f 角速=%.1f 头yaw=%.1f 头pitch=%.1f 地=%d 水=%d 飞=%d 潜=%d 主=%s 控制器=%s",
                   in.groundSpeed, in.vertSpeed, in.yawSpeed, in.headYaw, in.headPitch, in.onGround, in.inWater, in.flying,
                   in.sneaking, MWBAnimMainName(), MWBAnimCtrlState());
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
// 游戏真相机（0.10 MatrixStack 三栈，GameRenderer::saveMatrices 反编译实锤）：
// 每栈是 std::deque<Matrix>（map@+8 / start@+0x20 / size@+0x28，块 64 个×64 字节，栈顶=start+size-1）；
// 0x10034F570=投影（saveMatrices 单存 +0x98），0x10034F5D0=视图、0x10034F5A0=世界（存 MV=视图·世界）。
// 之前读 program uniform 是死路：uniform 绘制时才同步，orig 前读到的是上一 pass 旧值。
#define MS_PROJ_VA  0x10034F570UL
#define MS_WORLD_VA 0x10034F5A0UL
#define MS_VIEW_VA  0x10034F5D0UL
static const float *GLBStackTop(uintptr_t va) {
    char *ms = (char *)(MWBMainSlide() + va);
    void **map = *(void ***)(ms + 8);
    uint64_t start = *(uint64_t *)(ms + 0x20), size = *(uint64_t *)(ms + 0x28);
    if (!map || size == 0 || size > 4096) return NULL;
    uint64_t i = start + size - 1;
    char *blk = (char *)map[i >> 6];
    return blk ? (const float *)(blk + ((i & 63) << 6)) : NULL;
}
static float sGamePVW[16]; static float sGameRel[3]; static BOOL sHasGameCam = NO;
static float sGameW0[16]; // 世界栈底（本实体 push 前），手持物品矩阵要落回世界栈坐标系
// MobRenderer::render 入口（orig 前）调：pos=实体相对相机坐标（渲染用插值值），P·V·W 此刻即本实体的基准相机
void MWBGLBCaptureEntity(const float *pos) {
    const float *P = GLBStackTop(MS_PROJ_VA), *V = GLBStackTop(MS_VIEW_VA), *W = GLBStackTop(MS_WORLD_VA);
    if (!P || !V || !W || !pos) { sHasGameCam = NO; return; }
    float PV[16]; GLBMatMul(P, V, PV); GLBMatMul(PV, W, sGamePVW);
    memcpy(sGameW0, W, sizeof(sGameW0));
    memcpy(sGameRel, pos, sizeof(sGameRel));
    sHasGameCam = YES;
    static int sCamLog = 0;
    if ((sCamLog++ % 300) == 0)
        MWBLogFile(@"[GLB] 游戏相机 rel=(%.2f,%.2f,%.2f) P=[%.2f,%.2f,%.2f,%.2f] V=[%.2f,%.2f,%.2f|%.2f,%.2f,%.2f] W=[%.2f,%.2f,%.2f,%.2f]",
                   pos[0], pos[1], pos[2], P[0], P[5], P[10], P[11],
                   V[0], V[5], V[10], V[12], V[13], V[14], W[0], W[12], W[13], W[14]);
}
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
// ---- 手持物品落到鱼手上 ----
// 原版 HumanoidMobRenderer::additionalRendering（IDA 实锤）：push 世界栈 → ModelPart::translateTo(右臂 model+0x288, 栈顶, 1/16)
// → 平移 (-1/16, 7/16, 1/16) 到手心 → 按物品类型旋转缩放 → ItemInHandRenderer::renderItem → pop。
// 我们在 translateTo 命中右臂时把栈顶整个换成：W0 · T(落位) · 鱼 RightHandLocator 世界 · K，
// K = S(-1,-1,1) · T(1/16,-7/16,-1/16)：原版臂坐标系是模型空间（MobRenderer 已 scale(-1,-1,1)，Y 朝下沿手臂），
// 鱼 locator 是实体空间（Y 朝上）→ 翻 x/y；再预先抵消原版随后那一步平移，物品原点正好落在 locator 轴心。
static float sHandW[16]; static BOOL sHasHand = NO; static int sHandNi = -2;
static std::vector<float> *sWorldRef = NULL; // 指向绘制内 sWorld（本帧节点世界）
static void GLBUpdateHand(const float *T) {
    if (sHandNi == -2) { auto it = sName2Idx.find("RightHandLocator"); sHandNi = it != sName2Idx.end() ? it->second : -1; }
    if (sHandNi < 0 || !sWorldRef || (int)sWorldRef->size() < (sHandNi + 1) * 16) { sHasHand = NO; return; }
    float A[16], H[16];
    GLBMatMul(sGameW0, T, A);
    GLBMatMul(A, &(*sWorldRef)[sHandNi * 16], H);
    for (int r = 0; r < 4; r++) { H[r] = -H[r]; H[4 + r] = -H[4 + r]; }   // ·S(-1,-1,1)
    const float tx = 1.0f / 16, ty = -7.0f / 16, tz = -1.0f / 16;        // ·T(抵消原版手心平移)
    for (int r = 0; r < 4; r++) H[12 + r] += H[r] * tx + H[4 + r] * ty + H[8 + r] * tz;
    memcpy(sHandW, H, sizeof(sHandW));
    sHasHand = YES;
}
BOOL MWBGLBHandMatrix(float *out) {
    if (!sHasHand || !out) return NO;
    memcpy(out, sHandW, sizeof(sHandW));
    return YES;
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
    // 运行时推进（dt 钳 0.1，帧率无关）
    static double sLast = 0;
    double now = CFAbsoluteTimeGetCurrent();
    float dt = sLast > 0 ? (float)(now - sLast) : 0.016f;
    if (dt > 0.1f) dt = 0.1f; if (dt < 0) dt = 0;
    sLast = now;

    // 局部矩阵：YSM 运行时（全量关键帧＋molang＋分层＋头随视角）；未载入则绑定姿势
    static std::vector<float> sWorld; // 每节点 16
    sWorld.assign(sNodes.size() * 16, 0);
    sWorldRef = &sWorld;
    sHasHand = NO; // 本帧重算（相机/落位齐了才置位）
    std::vector<char> sHidden(sNodes.size(), 0);
    if (sAnimOK) {
        MWBAnimTick(dt);
        MWBAnimPose(sRootSet.data(), (int)sRootSet.size(), sNodeT.data(), sWorld.data(), sHidden.data());
    } else {
        for (int ni : sRootSet) GLBLocalMat(sNodes[ni].t, sNodes[ni].q, sNodes[ni].s, &sWorld[ni*16]);
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
        // T = 平移(玩家脚下)·绕Y(跟身体朝向)：鱼替的是身体，必须跟身体 +0x150（走动追视角、静止不动）。
        // 旧 +0x3c 无写者（站着碰巧对、走路不跟），已退役。
        // 跟视角 +0x78 是错的：V 相机世界固定，T 再跟视角转，拖相机时鱼自己转一份，
        // 与背景转动叠加就是“快1倍”（180° 见脸、360° 回背；正确应是 360° 一圈）。
        // 模型正面是 -z，玩家 yaw=0 朝南(+z，同 Java)，故 θ=π-bodyYaw；头尾若反只改 π 常数（与速率无关）。
        float yawDeg = *(float *)((char *)gLocalPlayer + ENTITY_BODY_YAW_OFF);
        float th = (180.0f - yawDeg) * (float)M_PI / 180.0f;
        sYawDbg = yawDeg; sThDbg = th;
        // 落位 Y：站立跟实地扫描（sHasGround），飞/游/空跟 py；再叠 lift；本体统一缩放 sGLBScale。
        float ty = (sHasGround ? sGroundY : py) + sGLBLift;
        float sc = sGLBScale, ct = cosf(th), st = sinf(th);
        if (sHasGameCam) {
            // 游戏真相机：相对相机坐标系（rel 是眼，+0x28 也是眼；脚=rel.y+(脚绝对-眼绝对)，gap=1.62 实锤）
            float feetAbs = sHasGround ? sGroundY : (py - 1.62f);
            px = sGameRel[0]; pz = sGameRel[2]; ty = sGameRel[1] + (feetAbs - py) + sGLBLift;
            memcpy(WVP, sGamePVW, sizeof(WVP));
        }
        float T[16] = {ct*sc,0,-st*sc,0, 0,sc,0,0, st*sc,0,ct*sc,0, px,ty,pz,1};
        GLBMatMul(WVP, T, WT);
        if (sHasGameCam) GLBUpdateHand(T);
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
        if (sNodes[ni].mesh >= 0) { total++; if (visOK[ni]) shown++; } // 可见=有网格且自身/祖先未被缩放隐藏
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
        static int sVtxLog = 0;
        if (drawn == 1 && m.nvert > 0 && (sVtxLog++ % 120) == 0) {
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
            MWBLogFile(@"[GLB] 首顶点 cam=%s prog=%u world=%d post=%d 玩家=(%.1f,%.1f,%.1f) yaw=%.1f th=%.2f 世界=(%.1f,%.1f,%.1f) clip=(%.1f,%.1f,%.1f,%.1f) ndc=(%.2f,%.2f,%.2f) alt=(%.2f,%.2f,%.2f) postndc=(%.2f,%.2f,%.2f) gy=%.1f gap=%+.2f sc=%.2f",
                       sHasGameCam ? "game" : "self", sSnapProg, sHasSnapWorld ? 1 : 0, hasPost ? (int)postProg : -1, ppx, ppy, ppz, sYawDbg, sThDbg, x, y, z, cx, cy, cz, cw,
                       cw != 0 ? cx/cw : 999, cw != 0 ? cy/cw : 999, cw != 0 ? cz/cw : 999,
                       aw != 0 ? ax/aw : 999, aw != 0 ? ay/aw : 999, aw != 0 ? az/aw : 999,
                       qw != 0 ? qx/qw : 999, qw != 0 ? qy/qw : 999, qw != 0 ? qz/qw : 999,
                       sHasGround ? sGroundY : 9999, sHasGround ? (ppy - sGroundY) : 9999, sGLBScale);
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
