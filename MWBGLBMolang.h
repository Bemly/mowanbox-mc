// MWBGLBMolang.h — molang 子集求值（照抄 viewer index.html，只够 scale 显隐表达式）
// 支持：数字/单引号串（当 0）/比较逻辑三元/+-*/%()/,/!/math.* 函数/v.roaming.* 查表/
// query.anim_time/life_time 取 t/其余 query/variable/v/c/t/ysm.* 全回 0。
// 注释与日志一律中文。
#import <Foundation/Foundation.h>

// 求值环境（调用方栈上构造，roaming 可为 nil 全当 0）
typedef struct {
    NSDictionary *roaming; // NSString -> NSNumber
    float t;               // query.anim_time / life_time
} MWBMolangEnv;

// 解析表达式为 AST（内部缓存，多次调用同一字符串只解析一次；失败返回 NULL）
void *MWBMolangParse(NSString *s);
// 求值（ast 为 NULL 回 0；内部异常一律吞掉回 0，不抛）
float MWBMolangEval(void *ast, const MWBMolangEnv *env);
// 快捷：字符串直接求值（数字 NSNumber 也可直接传，非数字非字符串回 0）
float MWBMolangValue(id v, const MWBMolangEnv *env);
