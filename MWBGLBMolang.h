// MWBGLBMolang.h — molang 完整子集（YSM 动画运行时用），逐行对应 web/js/ysm-molang.js
// 语句（; 分隔 / return / v.x = … 赋值 / // 注释）、??、a?b（无 else 回 0）、a?b:c、比较逻辑算术、一元 ! -；
// math.* 三角按角度（Bedrock 规定）；名字大小写不敏感，前缀统一 query.→q. variable.→v. temp.→t. context.→c.
// 变量/查询名编译期驻留成整数号（A7 逐帧求值免字符串查找），宿主按号取值；ysm.* 等函数交给宿主回调。
// 注释与日志一律中文。
#import <Foundation/Foundation.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MWBMolEnv {
    void *ctx;
    // 取变量/查询：id 为驻留号；未定义时置 *def=0 并回 0（?? 靠它）
    float (*get)(void *ctx, int id, int *def);
    // 赋值（v./t./v.roaming.*）
    void (*set)(void *ctx, int id, float v);
    // 宿主函数（非 math.*）：fid 为函数名驻留号，args 为 AST 节点，用 MWBMolEvalNode / MWBMolNodeStr 取
    float (*call)(void *ctx, int fid, void **args, int nargs, const struct MWBMolEnv *env);
} MWBMolEnv;

// 名字驻留（传规范化后的小写名，如 "q.ground_speed"）；同名同号，进程内常驻
int MWBMolIntern(const char *name);
const char *MWBMolName(int id);
// 编译（内部按源串缓存；失败回 NULL 并记一次日志）
void *MWBMolCompile(const char *src);
// 求值（ast 为 NULL 回 0）
float MWBMolEval(void *ast, const MWBMolEnv *env);
// 宿主回调里取参数：节点求值 / 字符串字面量（非串回 NULL）
float MWBMolEvalNode(void *node, const MWBMolEnv *env);
const char *MWBMolNodeStr(void *node);
// 编译失败计数（自检日志用）
int MWBMolFailCount(void);

#ifdef __cplusplus
}
#endif
