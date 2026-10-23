// MWBGLBMolang.mm — molang 子集求值实现（逐字照抄 viewer tokenize/parseMolang/evalMol）
// viewer 里只用来算 scale 显隐：旋转/位移里的 molang 通道转 GLB 时已跳过，这里同理只喂 scale。
#import "MWBGLBMolang.h"
#import <math.h>
#import <ctype.h>

// ---- AST 节点（k 与 viewer 的 {k:...} 一一对应） ----
typedef enum { MN_NUM, MN_STR, MN_VAR, MN_CALL, MN_UN, MN_BIN, MN_TERN } MNodeKind;
typedef struct MNode {
    MNodeKind k;
    double num;            // MN_NUM
    char *str;             // MN_STR/MN_VAR/MN_CALL 名（malloc，伴随 AST，常驻不释放）
    char op[3];            // MN_UN/MN_BIN 操作符
    struct MNode *a, *b, *c; // 子节点（c 仅三元 else 用；CALL 参数链挂 a，其余挂 b 链表）
    struct MNode *next;    // CALL 参数链表
} MNode;

static MNode *MNNew(MNodeKind k) {
    MNode *n = (MNode *)calloc(1, sizeof(MNode));
    n->k = k;
    return n;
}

// ---- 分词（与 viewer tokenize 同规则） ----
typedef enum { MT_NUM, MT_STR, MT_ID, MT_OP } MTKind;
typedef struct { MTKind t; double num; char *s; } MTok;

static void MFreeToks(MTok *toks, int n) {
    for (int i = 0; i < n; i++) if (toks[i].s) free(toks[i].s);
    free(toks);
}

// 成功返回词数（>=0），失败返回 -1
static int MTokenize(const char *s, MTok **out) {
    int cap = 32, n = 0;
    MTok *toks = (MTok *)malloc(sizeof(MTok) * (size_t)cap);
    int i = 0, L = (int)strlen(s);
    // *out 置空防野指针（失败路径调用方直接判 -1）
    *out = NULL;
    while (i < L) {
        char c = s[i];
        if (isspace((unsigned char)c)) { i++; continue; }
        if (n >= cap) { cap *= 2; toks = (MTok *)realloc(toks, sizeof(MTok) * (size_t)cap); }
        if (c == '\'') {
            int j = i + 1;
            while (j < L && s[j] != '\'') j++;
            int len = j - (i + 1);
            char *v = (char *)malloc((size_t)len + 1);
            memcpy(v, s + i + 1, (size_t)len); v[len] = 0;
            toks[n].t = MT_STR; toks[n].num = 0; toks[n].s = v; n++;
            i = (j < L) ? j + 1 : j;
            continue;
        }
        if ((isdigit((unsigned char)c)) || (c == '.' && i + 1 < L && isdigit((unsigned char)s[i + 1]))) {
            int j = i;
            while (j < L && (isdigit((unsigned char)s[j]) || s[j] == '.' || s[j] == 'e' || s[j] == 'E')) j++;
            // e/E 后面的符号只在紧跟 e/E 时吃掉（与 viewer /[eE]/ 判定一致）
            if (j < L && (s[j] == '+' || s[j] == '-') && j > i && (s[j-1] == 'e' || s[j-1] == 'E')) {
                // 把符号并入数字（viewer 是 break 后下一轮当操作符？不：viewer 在 [...] 内吞掉）
                // viewer 逻辑：遇到 +/- 且前一字符不是 e/E 则 break；是 e/E 则吞入。
                // 这里 j 停在符号处且前字符是 e/E，应吞入：继续吃数字部分
                j++;
                while (j < L && isdigit((unsigned char)s[j])) j++;
            }
            char buf[64]; int bl = j - i;
            if (bl >= (int)sizeof(buf)) bl = (int)sizeof(buf) - 1;
            memcpy(buf, s + i, (size_t)bl); buf[bl] = 0;
            toks[n].t = MT_NUM; toks[n].num = strtod(buf, NULL); toks[n].s = NULL; n++;
            i = j;
            continue;
        }
        if (isalpha((unsigned char)c) || c == '_') {
            int j = i;
            while (j < L && (isalnum((unsigned char)s[j]) || s[j] == '_' || s[j] == '.')) j++;
            int len = j - i;
            char *v = (char *)malloc((size_t)len + 1);
            memcpy(v, s + i, (size_t)len); v[len] = 0;
            toks[n].t = MT_ID; toks[n].num = 0; toks[n].s = v; n++;
            i = j;
            continue;
        }
        if (i + 1 < L) {
            char two[3] = {s[i], s[i+1], 0};
            if (!strcmp(two,"==") || !strcmp(two,"!=") || !strcmp(two,"<=") ||
                !strcmp(two,">=") || !strcmp(two,"&&") || !strcmp(two,"||")) {
                char *v = (char *)malloc(3); memcpy(v, two, 3);
                toks[n].t = MT_OP; toks[n].num = 0; toks[n].s = v; n++;
                i += 2;
                continue;
            }
        }
        if (strchr("+-*/%()<>,!?:", c)) {
            char *v = (char *)malloc(2); v[0] = c; v[1] = 0;
            toks[n].t = MT_OP; toks[n].num = 0; toks[n].s = v; n++;
            i++;
            continue;
        }
        MFreeToks(toks, n);
        return -1;
    }
    *out = toks;
    return n;
}

// ---- 递归下降（与 viewer parseMolang 同优先级） ----
typedef struct { MTok *t; int n; int p; int fail; } MParser;

static MNode *MExpr(MParser *pa);
static int MPeekIsOp(MParser *pa, const char *op) {
    return pa->p < pa->n && pa->t[pa->p].t == MT_OP && !strcmp(pa->t[pa->p].s, op);
}
static MNode *MPrim(MParser *pa) {
    if (pa->p >= pa->n) { pa->fail = 1; return NULL; }
    MTok *t = &pa->t[pa->p];
    if (t->t == MT_NUM) { pa->p++; MNode *n = MNNew(MN_NUM); n->num = t->num; return n; }
    if (t->t == MT_STR) {
        pa->p++; MNode *n = MNNew(MN_STR);
        n->str = (char *)malloc(strlen(t->s) + 1); strcpy(n->str, t->s);
        return n;
    }
    if (t->t == MT_ID) {
        char *name = (char *)malloc(strlen(t->s) + 1); strcpy(name, t->s);
        pa->p++;
        if (MPeekIsOp(pa, "(")) {
            pa->p++;
            MNode *n = MNNew(MN_CALL); n->str = name;
            MNode **tail = &n->a;
            if (!MPeekIsOp(pa, ")")) {
                *tail = MExpr(pa); tail = &(*tail)->next;
                while (MPeekIsOp(pa, ",")) { pa->p++; *tail = MExpr(pa); tail = &(*tail)->next; }
            }
            if (!MPeekIsOp(pa, ")")) { pa->fail = 1; return n; }
            pa->p++;
            return n;
        }
        MNode *n = MNNew(MN_VAR); n->str = name;
        return n;
    }
    if (t->t == MT_OP && !strcmp(t->s, "(")) {
        pa->p++;
        MNode *e = MExpr(pa);
        if (!MPeekIsOp(pa, ")")) { pa->fail = 1; return e; }
        pa->p++;
        return e;
    }
    pa->fail = 1;
    return NULL;
}
static MNode *MUn(MParser *pa) {
    if (MPeekIsOp(pa, "!") || MPeekIsOp(pa, "-")) {
        MNode *n = MNNew(MN_UN);
        strcpy(n->op, pa->t[pa->p].s); pa->p++;
        n->a = MUn(pa);
        return n;
    }
    return MPrim(pa);
}
static MNode *MBin(MParser *pa, MNode *(*sub)(MParser *), const char *ops) {
    MNode *l = sub(pa);
    for (;;) {
        if (pa->p >= pa->n || pa->t[pa->p].t != MT_OP) return l;
        char cur[3]; strncpy(cur, pa->t[pa->p].s, 2); cur[2] = 0;
        int hit = 0;
        // ops 里以空格分隔多个操作符（"== !=" 这类含等号的要整词比）
        const char *p = ops;
        while (*p) {
            while (*p == ' ') p++;
            if (!*p) break;
            const char *q = p;
            while (*q && *q != ' ') q++;
            if ((int)strlen(cur) == (int)(q - p) && !strncmp(cur, p, (size_t)(q - p))) { hit = 1; break; }
            p = q;
        }
        if (!hit) return l;
        pa->p++;
        MNode *n = MNNew(MN_BIN); strcpy(n->op, cur);
        n->a = l; n->b = sub(pa); l = n;
    }
}
static MNode *MMul(MParser *pa) { return MBin(pa, MUn, "* / %"); }
static MNode *MAdd(MParser *pa) { return MBin(pa, MMul, "+ -"); }
static MNode *MCmp(MParser *pa) { return MBin(pa, MAdd, "< > <= >="); }
static MNode *MEq(MParser *pa) { return MBin(pa, MCmp, "== !="); }
static MNode *MAnd(MParser *pa) { return MBin(pa, MEq, "&&"); }
static MNode *MOr(MParser *pa) { return MBin(pa, MAnd, "||"); }
static MNode *MTern(MParser *pa) {
    MNode *c = MOr(pa);
    if (MPeekIsOp(pa, "?")) {
        pa->p++;
        MNode *n = MNNew(MN_TERN); n->a = c;
        n->b = MExpr(pa);
        if (!MPeekIsOp(pa, ":")) { pa->fail = 1; return n; }
        pa->p++;
        n->c = MTern(pa);
        return n;
    }
    return c;
}
static MNode *MExpr(MParser *pa) { return MTern(pa); }

// ---- 求值（与 viewer evalMol 同语义） ----
static float MEval(MNode *n, const MWBMolangEnv *env) {
    if (!n) return 0;
    switch (n->k) {
        case MN_NUM: return (float)n->num;
        case MN_STR: return 0;
        case MN_VAR: {
            const char *v = n->str ? n->str : "";
            if (!strncmp(v, "v.roaming.", 10)) {
                NSNumber *x = env && env->roaming ? env->roaming[[NSString stringWithUTF8String:v + 10]] : nil;
                return x ? [x floatValue] : 0;
            }
            if (!strcmp(v, "query.anim_time") || !strcmp(v, "query.life_time"))
                return env ? env->t : 0;
            // 其余 query./q./variable./v./c./t./ysm.* 全回 0（viewer 同款）
            return 0;
        }
        case MN_CALL: {
            const char *f = n->str ? n->str : "";
            if (!strncmp(f, "math.", 5)) {
                const char *m = f + 5;
                float a0 = 0, a1 = 0, a2 = 0;
                MNode *p = n->a;
                if (p) { a0 = MEval(p, env); p = p->next; }
                if (p) { a1 = MEval(p, env); p = p->next; }
                if (p) { a2 = MEval(p, env); }
                if (!strcmp(m, "clamp")) return fminf(a2, fmaxf(a0, a1));
                if (!strcmp(m, "cos")) return cosf(a0);
                if (!strcmp(m, "sin")) return sinf(a0);
                if (!strcmp(m, "lerp")) return a0 + (a1 - a0) * a2;
                if (!strcmp(m, "abs")) return fabsf(a0);
                if (!strcmp(m, "sqrt")) return sqrtf(a0);
                if (!strcmp(m, "floor")) return floorf(a0);
                if (!strcmp(m, "ceil")) return ceilf(a0);
                if (!strcmp(m, "pow")) return powf(a0, a1);
                if (!strcmp(m, "min")) {
                    float r = a0; for (MNode *q = n->a ? n->a->next : NULL; q; q = q->next) {
                        float v = MEval(q, env); if (v < r) r = v;
                    } return r;
                }
                if (!strcmp(m, "max")) {
                    float r = a0; for (MNode *q = n->a ? n->a->next : NULL; q; q = q->next) {
                        float v = MEval(q, env); if (v > r) r = v;
                    } return r;
                }
                return 0;
            }
            return 0;
        }
        case MN_UN: {
            float v = MEval(n->a, env);
            return !strcmp(n->op, "!") ? (v == 0 ? 1 : 0) : -v;
        }
        case MN_BIN: {
            float l = MEval(n->a, env), r = MEval(n->b, env);
            if (!strcmp(n->op, "+")) return l + r;
            if (!strcmp(n->op, "-")) return l - r;
            if (!strcmp(n->op, "*")) return l * r;
            if (!strcmp(n->op, "/")) return r == 0 ? 0 : l / r;
            if (!strcmp(n->op, "%")) return r == 0 ? 0 : fmodf(l, r);
            if (!strcmp(n->op, "==")) return l == r ? 1 : 0;
            if (!strcmp(n->op, "!=")) return l != r ? 1 : 0;
            if (!strcmp(n->op, "<")) return l < r ? 1 : 0;
            if (!strcmp(n->op, ">")) return l > r ? 1 : 0;
            if (!strcmp(n->op, "<=")) return l <= r ? 1 : 0;
            if (!strcmp(n->op, ">=")) return l >= r ? 1 : 0;
            if (!strcmp(n->op, "&&")) return (l != 0 && r != 0) ? 1 : 0;
            if (!strcmp(n->op, "||")) return (l != 0 || r != 0) ? 1 : 0;
            return 0;
        }
        case MN_TERN:
            return MEval(n->a, env) != 0 ? MEval(n->b, env) : MEval(n->c, env);
    }
    return 0;
}

void *MWBMolangParse(NSString *s) {
    if (!s || !s.length) return NULL;
    static NSMutableDictionary *cache = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cache = [NSMutableDictionary new]; });
    @synchronized (cache) {
        id hit = cache[s];
        if ([hit isKindOfClass:[NSNull class]]) return NULL; // 解析失败记账，不反复抛错
        if (hit) return [hit pointerValue];
        const char *c = [s UTF8String];
        MTok *toks = NULL;
        int n = MTokenize(c, &toks);
        MNode *root = NULL;
        if (n >= 0) {
            MParser pa; pa.t = toks; pa.n = n; pa.p = 0; pa.fail = 0;
            root = MExpr(&pa);
            if (pa.fail || pa.p < pa.n) root = NULL; // 尾随词直接作废（viewer 抛错同款）
            MFreeToks(toks, n);
        }
        if (!root) { cache[s] = [NSNull null]; return NULL; }
        cache[s] = [NSValue valueWithPointer:root];
        return root;
    }
}

float MWBMolangEval(void *ast, const MWBMolangEnv *env) {
    if (!ast) return 0;
    @try { return MEval((MNode *)ast, env); }
    @catch (...) { return 0; }
}

float MWBMolangValue(id v, const MWBMolangEnv *env) {
    if ([v isKindOfClass:[NSNumber class]]) return [v floatValue];
    if ([v isKindOfClass:[NSString class]]) return MWBMolangEval(MWBMolangParse(v), env);
    return 0;
}
