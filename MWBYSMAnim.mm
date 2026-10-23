// MWBYSMAnim.mm — YSM 动画运行时实现，逐行对应 web/js/ysm-anim.js（web 页先验证，这里照搬）
// 语义见头文件；数学与 web 一致：骨骼 = 静止角 + 动画值，旋转 (-x,-y,+z) 度→弧度，位移 (-x,+y,+z)/16。
#import "MWBYSMAnim.h"
#import "MWBGLBMolang.h"
#import <math.h>
#import <string>
#import <vector>
#import <unordered_map>

void MWBLogFile(NSString *format, ...); // 定义在 MWBActions.mm（C++ 链接）

static const float kD2R = (float)(M_PI / 180.0);
static const float kMainFade = 0.2f; // 主动画切换淡入（秒）

// ---- 数据 ----
struct AVal { float num; void *ast; };              // ast 非空则求值
struct AKf { float t; int mode; bool hasPre; AVal pre[3]; AVal post[3]; };
struct ABone { int ni; std::vector<AKf> r, p, s; };
struct AAnim {
    std::string name; float len; int loop;
    std::vector<ABone> bones; ABone molang; bool hasMolang; bool headScripted;
    std::vector<std::pair<float, void *>> tl;
};
struct ACState { std::string name; int anim; std::vector<std::pair<void *, std::string>> tr; std::vector<void *> entry, exit; };
struct ASO { bool init; double xp, y, yd; int frame; }; // double：刚性弹簧（胸部 f=3）float 舍入会放大

static BOOL sReady = NO;
static std::vector<AAnim> sAnims;
static std::unordered_map<std::string, int> sAnimIdx;
static std::vector<float> sRest;                     // 3*节点，静止欧拉角（弧度）
static int sNodeCount = 0, sHeadNi = -1;
static std::unordered_map<std::string, ACState> sCtrl;
static std::string sCState;                          // 控制器当前状态（空=无控制器）
static std::vector<void *> sFuncs;
// 运行状态
static int sFrame = 0; static float sLife = 0, sDt = 0, sAnimT = 0;
static int sMain = -1, sPrevMain = -1; static float sMainT = 0, sPrevT = 0, sFade = 1, sCT = 0;
static int sLoco = 0;
static std::string sForce;
static MWBAnimInput sIn;
static std::vector<float> sVars; static std::vector<char> sVDef;      // 按驻留号
static std::vector<signed char> sKind;                                // 驻留号→取值类别（懒算）
static std::unordered_map<std::string, ASO> sSO;
static int sFnSecondOrder = -1;
// 层结果
static std::vector<float> sR, sP, sS; static std::vector<char> sHasR, sHasP, sHasS;

// ---- 取值类别（对应 env.get 的 switch） ----
enum { KV_VAR = 1, KV_ROAM, KV_CTRL, KV_EXTRA, KV_ANIMT, KV_LIFE, KV_GS, KV_VS, KV_YS, KV_GROUND, KV_WATER, KV_SNEAK,
       KV_HPITCH, KV_HYAW, KV_DT, KV_SWING, KV_ZERO, KV_UNKNOWN };
static int AKindOf(int id) {
    if (id >= (int)sKind.size()) sKind.resize(id + 64, 0);
    if (sKind[id]) return sKind[id];
    const char *n = MWBMolName(id);
    int k = KV_UNKNOWN;
    if (!strncmp(n, "v.roaming.", 10)) k = KV_ROAM;
    else if (!strncmp(n, "v.", 2) || !strncmp(n, "t.", 2)) k = KV_VAR;
    else if (!strcmp(n, "ctrl.playing_extra_animation")) k = KV_EXTRA;
    else if (!strncmp(n, "ctrl.", 5)) k = KV_CTRL;
    else if (!strcmp(n, "q.anim_time")) k = KV_ANIMT;
    else if (!strcmp(n, "q.life_time")) k = KV_LIFE;
    else if (!strcmp(n, "q.ground_speed")) k = KV_GS;
    else if (!strcmp(n, "q.vertical_speed")) k = KV_VS;
    else if (!strcmp(n, "q.yaw_speed")) k = KV_YS;
    else if (!strcmp(n, "q.is_on_ground")) k = KV_GROUND;
    else if (!strcmp(n, "q.is_in_water") || !strcmp(n, "q.is_in_water_or_rain")) k = KV_WATER;
    else if (!strcmp(n, "q.is_sneaking")) k = KV_SNEAK;
    else if (!strcmp(n, "q.head_x_rotation") || !strcmp(n, "ysm.head_pitch")) k = KV_HPITCH;
    else if (!strcmp(n, "q.head_y_rotation") || !strcmp(n, "ysm.head_yaw")) k = KV_HYAW;
    else if (!strcmp(n, "ysm.time_delta")) k = KV_DT;
    else if (!strcmp(n, "ysm.swinging") || !strcmp(n, "ysm.swinging_arm")) k = KV_SWING;
    else if (!strcmp(n, "ysm.has_elytra") || !strcmp(n, "ysm.elytra_rot_z")) k = KV_ZERO;
    sKind[id] = (signed char)k;
    return k;
}
static float AGet(void *ctx, int id, int *def) {
    switch (AKindOf(id)) {
        case KV_VAR: if (id < (int)sVDef.size() && sVDef[id]) return sVars[id]; *def = 0; return 0;
        case KV_ROAM: return id < (int)sVDef.size() && sVDef[id] ? sVars[id] : 0;
        case KV_CTRL: return (sMain >= 0 && sAnims[sMain].name == MWBMolName(id) + 5) ? 1 : 0;
        case KV_EXTRA: return 0;
        case KV_ANIMT: return sAnimT;
        case KV_LIFE: return sLife;
        case KV_GS: return sIn.groundSpeed;
        case KV_VS: return sIn.vertSpeed;
        case KV_YS: return sIn.yawSpeed;
        case KV_GROUND: return sIn.onGround ? 1 : 0;
        case KV_WATER: return sIn.inWater ? 1 : 0;
        case KV_SNEAK: return sIn.sneaking ? 1 : 0;
        case KV_HPITCH: return sIn.headPitch;
        case KV_HYAW: return sIn.headYaw;
        case KV_DT: return sDt;
        case KV_SWING: return sIn.swinging ? 1 : 0;
        case KV_ZERO: return 0;
    }
    *def = 0; return 0;
}
static void ASet(void *ctx, int id, float v) {
    if (id >= (int)sVars.size()) { sVars.resize(id + 64, 0); sVDef.resize(id + 64, 0); }
    sVars[id] = v; sVDef[id] = 1;
}
// 二阶动力学（t3ssel8r 经典式；同名每帧只推进一次）
static float ASecondOrder(ASO &st, double x, double f, double z, double r) {
    if (!st.init) { st.init = true; st.xp = x; st.y = x; st.yd = 0; st.frame = sFrame; return (float)st.y; }
    if (st.frame == sFrame || sDt <= 0) return (float)st.y;
    st.frame = sFrame;
    double T = sDt;
    f = fmax(f, 1e-3);
    double k1 = z / (M_PI * f), w = 2 * M_PI * f, k2 = 1 / (w * w), k3 = r * z / w;
    double xd = (x - st.xp) / T; st.xp = x;
    double k2s = fmax(k2, fmax(T * T / 2 + T * k1 / 2, T * k1));
    st.y += T * st.yd;
    st.yd += T * (x + k3 * xd - st.y - k1 * st.yd) / k2s;
    return (float)st.y;
}
static float ACall(void *ctx, int fid, void **args, int nargs, const MWBMolEnv *env) {
    if (fid == sFnSecondOrder && nargs >= 2) {
        const char *idn = MWBMolNodeStr(args[0]);
        ASO &st = sSO[idn ? idn : ""];
        float x = MWBMolEvalNode(args[1], env);
        float f = nargs > 2 ? MWBMolEvalNode(args[2], env) : 1, z = nargs > 3 ? MWBMolEvalNode(args[3], env) : 1;
        float r = nargs > 4 ? MWBMolEvalNode(args[4], env) : 0;
        return ASecondOrder(st, x, f, z, r);
    }
    return 0;
}
static MWBMolEnv sEnv = { NULL, AGet, ASet, ACall };

// ---- 载入 ----
static AVal AParseVal(id v) {
    AVal a = {0, NULL};
    if ([v isKindOfClass:[NSNumber class]]) a.num = [v floatValue];
    else if ([v isKindOfClass:[NSString class]]) a.ast = MWBMolCompile([v UTF8String]);
    return a;
}
static std::vector<AKf> AParseKfs(NSArray *arr) {
    std::vector<AKf> out;
    for (NSArray *k in arr) {
        if (![k isKindOfClass:[NSArray class]] || k.count < 4) continue;
        AKf f; f.t = [k[0] floatValue]; f.mode = [k[1] intValue];
        NSArray *pre = [k[2] isKindOfClass:[NSArray class]] ? k[2] : nil, *post = [k[3] isKindOfClass:[NSArray class]] ? k[3] : nil;
        f.hasPre = pre.count >= 3;
        for (int c = 0; c < 3; c++) {
            f.pre[c] = f.hasPre ? AParseVal(pre[c]) : (AVal){0, NULL};
            f.post[c] = post.count >= 3 ? AParseVal(post[c]) : (AVal){0, NULL};
        }
        out.push_back(f);
    }
    return out;
}
BOOL MWBAnimLoad(NSString *path, const char *const *nodeNames, int nodeCount) {
    MWBAnimUnload();
    NSData *d = [NSData dataWithContentsOfFile:path];
    if (!d) { MWBLogFile(@"[YSM动画] 读不到 %@", path); return NO; }
    NSError *e = nil;
    NSDictionary *j = [NSJSONSerialization JSONObjectWithData:d options:0 error:&e];
    if (![j isKindOfClass:[NSDictionary class]]) { MWBLogFile(@"[YSM动画] JSON 坏：%@", e); return NO; }
    std::unordered_map<std::string, int> name2ni;
    for (int i = 0; i < nodeCount; i++) name2ni[nodeNames[i]] = i;
    sNodeCount = nodeCount;
    auto hit = name2ni.find("Head"); sHeadNi = hit != name2ni.end() ? hit->second : -1;
    sRest.assign(nodeCount * 3, 0);
    NSDictionary *rest = j[@"rest"];
    for (int i = 0; i < nodeCount; i++) {
        NSArray *r = rest[[NSString stringWithUTF8String:nodeNames[i]]];
        if (r.count >= 3) for (int c = 0; c < 3; c++) sRest[i * 3 + c] = [r[c] floatValue];
    }
    sFnSecondOrder = MWBMolIntern("ysm.second_order");
    NSDictionary *anims = j[@"anims"];
    for (NSString *name in anims) {
        NSDictionary *a = anims[name];
        AAnim an; an.name = [name UTF8String];
        id ln = a[@"len"]; an.len = [ln isKindOfClass:[NSNumber class]] ? [ln floatValue] : INFINITY;
        an.loop = [a[@"loop"] intValue]; an.hasMolang = false; an.headScripted = false; an.molang.ni = -1;
        // bones 是有序数组 [[骨, {r,p,s}]...]：求值顺序 = YSM 原序（同名二阶先调者定值，与 web 一致）
        for (NSArray *pair in (NSArray *)a[@"bones"]) {
            if (![pair isKindOfClass:[NSArray class]] || pair.count < 2) continue;
            NSString *bn = pair[0]; NSDictionary *b = pair[1];
            ABone bo; std::string sbn = [bn UTF8String];
            auto it = name2ni.find(sbn); bo.ni = it != name2ni.end() ? it->second : -1;
            if (b[@"r"]) bo.r = AParseKfs(b[@"r"]);
            if (b[@"p"]) bo.p = AParseKfs(b[@"p"]);
            if (b[@"s"]) bo.s = AParseKfs(b[@"s"]);
            if (sbn == "molang") { an.molang = bo; an.hasMolang = true; }   // 脚本骨先算
            else if (bo.ni >= 0) an.bones.push_back(bo);                    // 模型里没有的骨跳过
            if (sbn == "Head" && b[@"r"]) {
                NSData *raw = [NSJSONSerialization dataWithJSONObject:b[@"r"] options:0 error:nil];
                NSString *s = raw ? [[NSString alloc] initWithData:raw encoding:NSUTF8StringEncoding] : @"";
                an.headScripted = [s containsString:@"ysm.head"];
            }
        }
        for (NSArray *t in (NSArray *)a[@"tl"]) if (t.count >= 2) an.tl.push_back({[t[0] floatValue], MWBMolCompile([t[1] UTF8String])});
        sAnimIdx[an.name] = (int)sAnims.size();
        sAnims.push_back(an);
    }
    NSDictionary *ctrl = j[@"ctrls"][@"player.parallel_7"];
    if (ctrl) {
        for (NSDictionary *s in (NSArray *)ctrl[@"states"]) {
            ACState cs; cs.name = [s[@"name"] UTF8String];
            NSDictionary *am = s[@"animations"]; NSString *an = am[@""] ?: am.allValues.firstObject;
            auto it = an ? sAnimIdx.find([an UTF8String]) : sAnimIdx.end();
            cs.anim = it != sAnimIdx.end() ? it->second : -1;
            // 转移条件有序数组 [[条件, 目标]...]（先满足者先转）
            for (NSArray *tr in (NSArray *)s[@"transitions"])
                if (tr.count >= 2) cs.tr.push_back({MWBMolCompile([tr[0] UTF8String]), [tr[1] UTF8String]});
            for (NSString *x in (NSArray *)s[@"on_entry"]) cs.entry.push_back(MWBMolCompile([x UTF8String]));
            for (NSString *x in (NSArray *)s[@"on_exit"]) cs.exit.push_back(MWBMolCompile([x UTF8String]));
            sCtrl[cs.name] = cs;
        }
        sCState = [ctrl[@"initial"] UTF8String] ?: "";
    }
    for (NSArray *f in (NSArray *)j[@"funcs"]) if (f.count >= 2) sFuncs.push_back(MWBMolCompile([f[1] UTF8String]));
    sR.assign(nodeCount * 3, 0); sP.assign(nodeCount * 3, 0); sS.assign(nodeCount * 3, 1);
    sHasR.assign(nodeCount, 0); sHasP.assign(nodeCount, 0); sHasS.assign(nodeCount, 0);
    auto mi = sAnimIdx.find("idle"); sMain = mi != sAnimIdx.end() ? mi->second : -1;
    sReady = YES;
    MWBLogFile(@"[YSM动画] 载入 动画=%lu 控制器态=%lu 函数=%lu molang失败=%d 头骨=%d",
               (unsigned long)sAnims.size(), (unsigned long)sCtrl.size(), (unsigned long)sFuncs.size(), MWBMolFailCount(), sHeadNi);
    return YES;
}
BOOL MWBAnimReady(void) { return sReady; }
void MWBAnimUnload(void) {
    sReady = NO; sAnims.clear(); sAnimIdx.clear(); sCtrl.clear(); sCState.clear(); sFuncs.clear(); sSO.clear();
    sVars.clear(); sVDef.clear(); sFrame = 0; sLife = 0; sMain = sPrevMain = -1; sMainT = sPrevT = sCT = 0; sFade = 1; sLoco = 0;
}
void MWBAnimSetInput(const MWBAnimInput *in) { if (in) sIn = *in; }
void MWBAnimForceMain(const char *name) { sForce = name ? name : ""; }
void MWBAnimSetRoaming(const char *name, float v) {
    char buf[128]; snprintf(buf, sizeof(buf), "v.roaming.%s", name);
    ASet(NULL, MWBMolIntern(buf), v);
}

// ---- 时间 ----
static float AWrap(const AAnim &an, float t) {
    if (an.loop == 1) return (isfinite(an.len) && an.len > 0) ? fmodf(t, an.len) : t;
    return isfinite(an.len) ? fminf(t, an.len) : t; // 2=停最后一帧 3=播一次（同样停住）
}
static void AFireTimeline(int ai, float t0, float t1) {
    if (ai < 0) return;
    const AAnim &an = sAnims[ai];
    if (an.tl.empty()) return;
    float a = AWrap(an, t0), b = AWrap(an, t1);
    for (auto &e : an.tl) {
        bool hit = (b >= a) ? (e.first > a && e.first <= b) : (e.first > a || e.first <= b);
        if (hit && e.second) MWBMolEval(e.second, &sEnv);
    }
}

// ---- 主动画选择（YSM 内置优先级，按 0.10 可得信号裁剪；与 web pickMain 同） ----
static const char *APickMain(void) {
    float s = sIn.groundSpeed;
    if (s > 5.4f) sLoco = 2; else if (s < 4.6f && sLoco == 2) sLoco = 1;
    if (s > 0.6f && sLoco == 0) sLoco = 1; else if (s < 0.35f) sLoco = 0;
    bool moving = sLoco > 0;
    if (sIn.dead) return "death";
    if (sIn.sleeping) return "sleep";
    if (sIn.inWater) return moving ? "swim" : "swim_stand";
    if (sIn.flying) return "fly";
    if (!sIn.onGround) return "jump";
    if (sIn.sneaking) return moving ? "sneak" : "sneaking";
    if (sLoco == 2) return "run";
    return moving ? "walk" : "idle";
}

void MWBAnimTick(float dt) {
    if (!sReady) return;
    sFrame++; sDt = dt; sLife += dt;
    for (void *f : sFuncs) if (f) MWBMolEval(f, &sEnv);          // player_update
    const char *want = sForce.size() ? sForce.c_str() : APickMain();
    auto it = sAnimIdx.find(want);
    if (it != sAnimIdx.end() && it->second != sMain) {
        sPrevMain = sMain; sPrevT = sMainT; sFade = 0;
        sMain = it->second; sMainT = 0;
    } else {
        float t0 = sMainT; sMainT += dt; AFireTimeline(sMain, t0, sMainT);
    }
    sPrevT += dt;
    sFade = fminf(1, sFade + dt / kMainFade);
    if (sFade > 0.999f) sFade = 1; // 边界定死（float/double 累加落点不同会让旧主动画多跑一帧，与 web 分叉）
    if (!sCState.empty()) {                                       // parallel_7 控制器
        auto cs = sCtrl.find(sCState);
        if (cs != sCtrl.end()) {
            for (auto &tr : cs->second.tr) {
                if (tr.first && MWBMolEval(tr.first, &sEnv) != 0 && sCtrl.count(tr.second)) {
                    for (void *x : cs->second.exit) if (x) MWBMolEval(x, &sEnv);
                    sCState = tr.second; sCT = 0;
                    for (void *x : sCtrl[sCState].entry) if (x) MWBMolEval(x, &sEnv);
                    break;
                }
            }
        }
        float t0 = sCT; sCT += dt;
        auto cur = sCtrl.find(sCState);
        if (cur != sCtrl.end()) AFireTimeline(cur->second.anim, t0, sCT);
    }
}

// ---- 采样（与 web sample 同：阶跃/线性/catmull-rom，pre/post） ----
static inline float AV(const AVal &v) { return v.ast ? MWBMolEval(v.ast, &sEnv) : v.num; }
static inline void AVec(const AVal *a, float *o) { o[0] = AV(a[0]); o[1] = AV(a[1]); o[2] = AV(a[2]); }
static void ASample(const std::vector<AKf> &k, float t, float *out) {
    size_t n = k.size();
    if (n == 1 || t <= k[0].t) { AVec(k[0].hasPre ? k[0].pre : k[0].post, out); return; }
    if (t >= k[n - 1].t) { AVec(k[n - 1].post, out); return; }
    size_t i = 0;
    while (i + 1 < n && k[i + 1].t <= t) i++;
    const AKf &a = k[i], &b = k[i + 1];
    if (a.mode == 1) { AVec(a.post, out); return; }
    float f = (t - a.t) / (b.t - a.t), A[3], B[3];
    AVec(a.post, A); AVec(b.hasPre ? b.pre : b.post, B);
    if (a.mode == 2 || b.mode == 2) {
        float P0[3], P3[3];
        if (i > 0) AVec(k[i - 1].post, P0); else memcpy(P0, A, sizeof(A));
        if (i + 2 < n) AVec(k[i + 2].hasPre ? k[i + 2].pre : k[i + 2].post, P3); else memcpy(P3, B, sizeof(B));
        float f2 = f * f, f3 = f2 * f;
        for (int c = 0; c < 3; c++)
            out[c] = 0.5f * (2 * A[c] + (-P0[c] + B[c]) * f + (2 * P0[c] - 5 * A[c] + 4 * B[c] - P3[c]) * f2 + (-P0[c] + 3 * A[c] - 3 * B[c] + P3[c]) * f3);
        return;
    }
    for (int c = 0; c < 3; c++) out[c] = A[c] + (B[c] - A[c]) * f;
}
static inline void APut(std::vector<float> &arr, std::vector<char> &has, int ni, const float *v, float w, float def) {
    float *o = &arr[ni * 3];
    if (w >= 1) { o[0] = v[0]; o[1] = v[1]; o[2] = v[2]; has[ni] = 1; return; }
    float b0 = has[ni] ? o[0] : def, b1 = has[ni] ? o[1] : def, b2 = has[ni] ? o[2] : def;
    o[0] = b0 + (v[0] - b0) * w; o[1] = b1 + (v[1] - b1) * w; o[2] = b2 + (v[2] - b2) * w; has[ni] = 1;
}
static void AApply(int ai, float t, float w) {
    if (ai < 0) return;
    const AAnim &an = sAnims[ai];
    sAnimT = AWrap(an, t);
    float tmp[3];
    if (an.hasMolang) {
        if (!an.molang.r.empty()) ASample(an.molang.r, sAnimT, tmp);
        if (!an.molang.p.empty()) ASample(an.molang.p, sAnimT, tmp);
        if (!an.molang.s.empty()) ASample(an.molang.s, sAnimT, tmp);
    }
    for (const ABone &b : an.bones) {
        if (!b.r.empty()) { ASample(b.r, sAnimT, tmp); APut(sR, sHasR, b.ni, tmp, w, 0); }
        if (!b.p.empty()) { ASample(b.p, sAnimT, tmp); APut(sP, sHasP, b.ni, tmp, w, 0); }
        if (!b.s.empty()) { ASample(b.s, sAnimT, tmp); APut(sS, sHasS, b.ni, tmp, w, 1); }
    }
}
static int AFind(const char *n) { auto it = sAnimIdx.find(n); return it != sAnimIdx.end() ? it->second : -1; }

void MWBAnimPose(const int *rootSet, int nRoot, const float *nodeT, float *local, char *hidden) {
    if (!sReady) return;
    std::fill(sHasR.begin(), sHasR.end(), 0); std::fill(sHasP.begin(), sHasP.end(), 0); std::fill(sHasS.begin(), sHasS.end(), 0);
    char nm[24];
    for (int i = 0; i < 8; i++) { snprintf(nm, sizeof(nm), "pre_parallel%d", i); AApply(AFind(nm), sLife, 1); }
    if (sFade < 1 && sPrevMain >= 0) AApply(sPrevMain, sPrevT, 1);   // 淡入期先铺旧主动画
    AApply(sMain, sMainT, (sFade < 1 && sPrevMain >= 0) ? sFade : 1);
    for (int i = 0; i < 7; i++) { snprintf(nm, sizeof(nm), "parallel%d", i); AApply(AFind(nm), sLife, 1); }
    if (!sCState.empty()) { auto cur = sCtrl.find(sCState); if (cur != sCtrl.end()) AApply(cur->second.anim, sCT, 1); }
    else AApply(AFind("parallel7"), sLife, 1);
    // 头随视角（主动画没自己写 ysm.head_* 时）
    if (sHeadNi >= 0 && !(sMain >= 0 && sAnims[sMain].headScripted)) {
        float *o = &sR[sHeadNi * 3];
        if (!sHasR[sHeadNi]) { o[0] = o[1] = o[2] = 0; sHasR[sHeadNi] = 1; }
        o[0] += sIn.headPitch; o[1] += sIn.headYaw;
    }
    for (int k = 0; k < nRoot; k++) {
        int ni = rootSet[k];
        if (ni < 0 || ni >= sNodeCount) continue;
        float rx = sRest[ni * 3], ry = sRest[ni * 3 + 1], rz = sRest[ni * 3 + 2];
        if (sHasR[ni]) { rx += -sR[ni * 3] * kD2R; ry += -sR[ni * 3 + 1] * kD2R; rz += sR[ni * 3 + 2] * kD2R; }
        float tx = nodeT[ni * 3], ty = nodeT[ni * 3 + 1], tz = nodeT[ni * 3 + 2];
        if (sHasP[ni]) { tx += -sP[ni * 3] / 16; ty += sP[ni * 3 + 1] / 16; tz += sP[ni * 3 + 2] / 16; }
        float sx = 1, sy = 1, sz = 1;
        hidden[ni] = 0;
        if (sHasS[ni]) {
            sx = sS[ni * 3]; sy = sS[ni * 3 + 1]; sz = sS[ni * 3 + 2];
            hidden[ni] = (fabsf(sx) < 1e-3f || fabsf(sy) < 1e-3f || fabsf(sz) < 1e-3f);
        }
        // local = T·Rz·Ry·Rx·S（列主序，与 web eulerMat 同）
        float cx = cosf(rx), snx = sinf(rx), cy = cosf(ry), sny = sinf(ry), cz = cosf(rz), snz = sinf(rz);
        float *m = &local[ni * 16];
        m[0] = cz * cy * sx; m[1] = snz * cy * sx; m[2] = -sny * sx; m[3] = 0;
        m[4] = (cz * sny * snx - snz * cx) * sy; m[5] = (snz * sny * snx + cz * cx) * sy; m[6] = cy * snx * sy; m[7] = 0;
        m[8] = (cz * sny * cx + snz * snx) * sz; m[9] = (snz * sny * cx - cz * snx) * sz; m[10] = cy * cx * sz; m[11] = 0;
        m[12] = tx; m[13] = ty; m[14] = tz; m[15] = 1;
    }
}

const char *MWBAnimMainName(void) { return sMain >= 0 ? sAnims[sMain].name.c_str() : "-"; }
const char *MWBAnimCtrlState(void) { return sCState.empty() ? "-" : sCState.c_str(); }
float MWBAnimLife(void) { return sLife; }
int MWBAnimSecondOrderCount(void) { return (int)sSO.size(); }
// 诊断：变量值 / 二阶状态（名不存在回 NAN）
float MWBAnimDebugVar(const char *name) {
    int id = MWBMolIntern(name);
    return (id < (int)sVDef.size() && sVDef[id]) ? sVars[id] : NAN;
}
float MWBAnimDebugSO(const char *name) { auto it = sSO.find(name); return it != sSO.end() ? (float)it->second.y : NAN; }
