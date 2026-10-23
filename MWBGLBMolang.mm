// MWBGLBMolang.mm — molang 完整子集实现，逐行对应 web/js/ysm-molang.js（tokenize/parse/ev/callFn）
// 旧版只够 scale 显隐（三角按弧度、无赋值/语句/??、query 全回 0），YSM 全量动画用不了，整体重写。
#import "MWBGLBMolang.h"
#import <math.h>
#import <string>
#import <vector>
#import <unordered_map>
#import <mutex>

void MWBLogFile(NSString *format, ...); // 定义在 MWBActions.mm（C++ 链接）

// ---- 名字驻留 ----
static std::mutex sInternMu;
static std::unordered_map<std::string, int> *sInternMap = NULL;
static std::vector<std::string> *sInternNames = NULL;
int MWBMolIntern(const char *name) {
    std::lock_guard<std::mutex> lk(sInternMu);
    if (!sInternMap) { sInternMap = new std::unordered_map<std::string, int>(); sInternNames = new std::vector<std::string>(); }
    auto it = sInternMap->find(name);
    if (it != sInternMap->end()) return it->second;
    int id = (int)sInternNames->size();
    sInternNames->push_back(name);
    (*sInternMap)[name] = id;
    return id;
}
const char *MWBMolName(int id) {
    std::lock_guard<std::mutex> lk(sInternMu);
    return (sInternNames && id >= 0 && id < (int)sInternNames->size()) ? (*sInternNames)[id].c_str() : "";
}
static std::string MNorm(const std::string &raw) { // 对应 normName
    std::string s = raw;
    for (auto &c : s) c = (char)tolower((unsigned char)c);
    if (!s.compare(0, 6, "query.")) return "q." + s.substr(6);
    if (!s.compare(0, 9, "variable.")) return "v." + s.substr(9);
    if (!s.compare(0, 5, "temp.")) return "t." + s.substr(5);
    if (!s.compare(0, 8, "context.")) return "c." + s.substr(8);
    return s;
}

// ---- 分词 ----
enum MTokT { T_NUM, T_STR, T_ID, T_OP };
struct MTok { MTokT t; double num; std::string s; };
static bool MTokenize(const char *src, std::vector<MTok> &out) {
    size_t L = strlen(src), i = 0;
    while (i < L) {
        char c = src[i];
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r') { i++; continue; }
        if (c == '/' && i + 1 < L && src[i + 1] == '/') { while (i < L && src[i] != '\n') i++; continue; }
        if (c == '\'') {
            size_t j = i + 1; while (j < L && src[j] != '\'') j++;
            out.push_back({T_STR, 0, std::string(src + i + 1, j - i - 1)}); i = j + 1; continue;
        }
        if (isdigit((unsigned char)c) || (c == '.' && i + 1 < L && isdigit((unsigned char)src[i + 1]))) {
            size_t j = i;
            while (j < L && (isdigit((unsigned char)src[j]) || src[j] == '.')) j++;
            if (j < L && (src[j] == 'e' || src[j] == 'E')) {
                j++; if (j < L && (src[j] == '+' || src[j] == '-')) j++;
                while (j < L && isdigit((unsigned char)src[j])) j++;
            }
            out.push_back({T_NUM, strtod(std::string(src + i, j - i).c_str(), NULL), ""});
            if (j < L && (src[j] == 'f' || src[j] == 'F')) j++;
            i = j; continue;
        }
        if (isalpha((unsigned char)c) || c == '_') {
            size_t j = i;
            while (j < L && (isalnum((unsigned char)src[j]) || src[j] == '_' || src[j] == '.')) j++;
            out.push_back({T_ID, 0, std::string(src + i, j - i)}); i = j; continue;
        }
        if (i + 1 < L) {
            std::string two(src + i, 2);
            if (two == "==" || two == "!=" || two == "<=" || two == ">=" || two == "&&" || two == "||" || two == "??" || two == "->") {
                out.push_back({T_OP, 0, two}); i += 2; continue;
            }
        }
        if (strchr("+-*/%()<>,!?:;={}[]", c)) { out.push_back({T_OP, 0, std::string(1, c)}); i++; continue; }
        return false;
    }
    return true;
}

// ---- AST ----
enum MK { K_NUM, K_STR, K_VAR, K_CALL, K_MATH, K_UN, K_BIN, K_TERN, K_SET, K_SEQ, K_RET };
enum MOp { O_ADD, O_SUB, O_MUL, O_DIV, O_MOD, O_LT, O_GT, O_LE, O_GE, O_EQ, O_NE, O_AND, O_OR, O_COAL, O_NOT, O_NEG };
enum MFn { F_SIN, F_COS, F_ASIN, F_ACOS, F_ATAN, F_ATAN2, F_ABS, F_CLAMP, F_LERP, F_MIN, F_MAX, F_POW, F_SQRT,
           F_FLOOR, F_CEIL, F_ROUND, F_TRUNC, F_MOD, F_EXP, F_LN, F_RANDOM, F_RANDI, F_HERMITE, F_UNKNOWN };
struct MNode {
    MK k; double num; int id; int op; std::string str;
    MNode *a, *b, *c; std::vector<MNode *> args;
};
static MNode *MNew(MK k) { MNode *n = new MNode(); n->k = k; n->num = 0; n->id = -1; n->op = 0; n->a = n->b = n->c = NULL; return n; }
static MFn MMathFn(const std::string &m) {
    static const char *names[] = {"sin","cos","asin","acos","atan","atan2","abs","clamp","lerp","min","max","pow","sqrt",
                                  "floor","ceil","round","trunc","mod","exp","ln","random","random_integer","hermite_blend"};
    for (int i = 0; i < (int)F_UNKNOWN; i++) if (m == names[i]) return (MFn)i;
    return F_UNKNOWN;
}

struct MParser {
    std::vector<MTok> &t; size_t p; bool fail;
    explicit MParser(std::vector<MTok> &tk) : t(tk), p(0), fail(false) {}
    bool peek(const char *v) { return p < t.size() && t[p].t == T_OP && t[p].s == v; }
    void eat(const char *v) { if (peek(v)) p++; else fail = true; }
    MNode *prim() {
        if (p >= t.size()) { fail = true; return MNew(K_NUM); }
        MTok &k = t[p];
        if (k.t == T_NUM) { p++; MNode *n = MNew(K_NUM); n->num = k.num; return n; }
        if (k.t == T_STR) { p++; MNode *n = MNew(K_STR); n->str = k.s; return n; }
        if (k.t == T_ID) {
            p++;
            std::string nm = MNorm(k.s);
            if (nm == "true" || nm == "false") { MNode *n = MNew(K_NUM); n->num = nm == "true" ? 1 : 0; return n; }
            if (nm == "math.pi") { MNode *n = MNew(K_NUM); n->num = M_PI; return n; }
            if (peek("(")) {
                p++;
                MNode *n;
                if (!nm.compare(0, 5, "math.")) { n = MNew(K_MATH); n->op = MMathFn(nm.substr(5)); }
                else { n = MNew(K_CALL); n->id = MWBMolIntern(nm.c_str()); }
                if (!peek(")")) { n->args.push_back(expr()); while (peek(",") && !fail) { p++; n->args.push_back(expr()); } }
                eat(")");
                return n;
            }
            MNode *n = MNew(K_VAR); n->id = MWBMolIntern(nm.c_str()); return n;
        }
        if (peek("(")) { p++; MNode *e = expr(); eat(")"); return e; }
        fail = true; p++; return MNew(K_NUM);
    }
    MNode *un() {
        if (peek("!") || peek("-")) { MNode *n = MNew(K_UN); n->op = peek("!") ? O_NOT : O_NEG; p++; n->a = un(); return n; }
        if (peek("+")) { p++; return un(); }
        return prim();
    }
    MNode *binl(int lvl) { // 0 mul 1 add 2 cmp 3 eq 4 and 5 or
        static const char *ops[6][4] = {{"*","/","%",NULL},{"+","-",NULL,NULL},{"<",">","<=",">="},{"==","!=",NULL,NULL},{"&&",NULL,NULL,NULL},{"||",NULL,NULL,NULL}};
        static const int codes[6][4] = {{O_MUL,O_DIV,O_MOD,0},{O_ADD,O_SUB,0,0},{O_LT,O_GT,O_LE,O_GE},{O_EQ,O_NE,0,0},{O_AND,0,0,0},{O_OR,0,0,0}};
        MNode *l = lvl == 0 ? un() : binl(lvl - 1);
        for (;;) {
            int hit = -1;
            for (int i = 0; i < 4 && ops[lvl][i]; i++) if (peek(ops[lvl][i])) { hit = i; break; }
            if (hit < 0 || fail) return l;
            p++;
            MNode *n = MNew(K_BIN); n->op = codes[lvl][hit]; n->a = l; n->b = lvl == 0 ? un() : binl(lvl - 1); l = n;
        }
    }
    MNode *coal() { MNode *l = binl(5); if (peek("??")) { p++; MNode *n = MNew(K_BIN); n->op = O_COAL; n->a = l; n->b = coal(); return n; } return l; }
    MNode *tern() {
        MNode *c = coal();
        if (peek("?")) {
            p++;
            MNode *n = MNew(K_TERN); n->a = c; n->b = tern();
            if (peek(":")) { p++; n->c = tern(); }
            return n;
        }
        return c;
    }
    MNode *expr() {
        if (p + 1 < t.size() && t[p].t == T_ID && t[p + 1].t == T_OP && t[p + 1].s == "=") {
            MNode *n = MNew(K_SET); n->id = MWBMolIntern(MNorm(t[p].s).c_str()); p += 2; n->a = expr(); return n;
        }
        return tern();
    }
    MNode *program() {
        MNode *seq = MNew(K_SEQ);
        bool semi = false, ret = false;
        while (p < t.size() && !fail) {
            if (peek(";")) { p++; semi = true; continue; }
            if (t[p].t == T_ID && MNorm(t[p].s) == "return") { p++; MNode *r = MNew(K_RET); r->a = expr(); seq->args.push_back(r); ret = true; continue; }
            seq->args.push_back(expr());
        }
        if (seq->args.size() == 1 && !semi && !ret) { MNode *only = seq->args[0]; delete seq; return only; }
        return seq;
    }
};

// ---- 求值 ----
static const double kD2R = M_PI / 180.0;
static float MEv(MNode *n, const MWBMolEnv *e);
static float MMath(MNode *n, const MWBMolEnv *e) {
    float a[8] = {0}; int na = (int)n->args.size(); if (na > 8) na = 8;
    for (int i = 0; i < na; i++) a[i] = MEv(n->args[i], e);
    switch ((MFn)n->op) {
        case F_SIN: return (float)sin(a[0] * kD2R);
        case F_COS: return (float)cos(a[0] * kD2R);
        case F_ASIN: return (float)(asin(a[0]) / kD2R);
        case F_ACOS: return (float)(acos(a[0]) / kD2R);
        case F_ATAN: return (float)(atan(a[0]) / kD2R);
        case F_ATAN2: return (float)(atan2(a[0], a[1]) / kD2R);
        case F_ABS: return fabsf(a[0]);
        case F_CLAMP: return fminf(a[2], fmaxf(a[1], a[0]));
        case F_LERP: return a[0] + (a[1] - a[0]) * a[2];
        case F_MIN: { float r = a[0]; for (int i = 1; i < na; i++) r = fminf(r, a[i]); return r; }
        case F_MAX: { float r = a[0]; for (int i = 1; i < na; i++) r = fmaxf(r, a[i]); return r; }
        case F_POW: return powf(a[0], a[1]);
        case F_SQRT: return sqrtf(a[0]);
        case F_FLOOR: return floorf(a[0]);
        case F_CEIL: return ceilf(a[0]);
        case F_ROUND: return roundf(a[0]);
        case F_TRUNC: return truncf(a[0]);
        case F_MOD: return a[1] == 0 ? 0 : fmodf(a[0], a[1]);
        case F_EXP: return expf(a[0]);
        case F_LN: return logf(a[0]);
        case F_RANDOM: return a[0] + (float)arc4random_uniform(1000000) / 1000000.0f * (a[1] - a[0]);
        case F_RANDI: return roundf(a[0] + (float)arc4random_uniform(1000000) / 1000000.0f * (a[1] - a[0]));
        case F_HERMITE: return 3 * a[0] * a[0] - 2 * a[0] * a[0] * a[0];
        default: return 0;
    }
}
static float MEv(MNode *n, const MWBMolEnv *e) {
    switch (n->k) {
        case K_NUM: return (float)n->num;
        case K_STR: return 0;
        case K_VAR: { int def = 1; return e->get ? e->get(e->ctx, n->id, &def) : 0; }
        case K_SET: { float v = MEv(n->a, e); if (e->set) e->set(e->ctx, n->id, v); return v; }
        case K_UN: { float v = MEv(n->a, e); return n->op == O_NOT ? (v == 0 ? 1 : 0) : -v; }
        case K_TERN: return MEv(n->a, e) != 0 ? MEv(n->b, e) : (n->c ? MEv(n->c, e) : 0);
        case K_BIN: {
            if (n->op == O_COAL) {
                if (n->a->k == K_VAR) { int def = 1; float v = e->get ? e->get(e->ctx, n->a->id, &def) : 0; return def ? v : MEv(n->b, e); }
                return MEv(n->a, e);
            }
            if (n->op == O_AND) return (MEv(n->a, e) != 0 && MEv(n->b, e) != 0) ? 1 : 0;
            if (n->op == O_OR) return (MEv(n->a, e) != 0 || MEv(n->b, e) != 0) ? 1 : 0;
            float l = MEv(n->a, e), r = MEv(n->b, e);
            switch (n->op) {
                case O_ADD: return l + r; case O_SUB: return l - r; case O_MUL: return l * r;
                case O_DIV: return r == 0 ? 0 : l / r;
                case O_MOD: return r == 0 ? 0 : fmodf(l, r);
                case O_LT: return l < r; case O_GT: return l > r; case O_LE: return l <= r; case O_GE: return l >= r;
                case O_EQ: return l == r; case O_NE: return l != r;
            }
            return 0;
        }
        case K_MATH: return MMath(n, e);
        case K_CALL: return e->call ? e->call(e->ctx, n->id, (void **)n->args.data(), (int)n->args.size(), e) : 0;
        case K_RET: return MEv(n->a, e);
        case K_SEQ: {
            float last = 0;
            for (MNode *s : n->args) { last = MEv(s, e); if (s->k == K_RET) return last; }
            return last;
        }
    }
    return 0;
}

// ---- 对外 ----
static std::mutex sCacheMu;
static std::unordered_map<std::string, MNode *> *sCache = NULL;
static int sFails = 0;
void *MWBMolCompile(const char *src) {
    if (!src || !*src) return NULL;
    std::lock_guard<std::mutex> lk(sCacheMu);
    if (!sCache) sCache = new std::unordered_map<std::string, MNode *>();
    auto it = sCache->find(src);
    if (it != sCache->end()) return it->second;
    std::vector<MTok> toks;
    MNode *root = NULL;
    if (MTokenize(src, toks)) {
        MParser pa(toks);
        root = pa.program();
        if (pa.fail) root = NULL; // 坏树不回收（常驻小量，免悬垂）
    }
    if (!root) { sFails++; MWBLogFile(@"[molang] 解析失败：%s", src); }
    (*sCache)[src] = root;
    return root;
}
float MWBMolEval(void *ast, const MWBMolEnv *env) { return ast && env ? MEv((MNode *)ast, env) : 0; }
float MWBMolEvalNode(void *node, const MWBMolEnv *env) { return node && env ? MEv((MNode *)node, env) : 0; }
const char *MWBMolNodeStr(void *node) { MNode *n = (MNode *)node; return (n && n->k == K_STR) ? n->str.c_str() : NULL; }
int MWBMolFailCount(void) { return sFails; }
