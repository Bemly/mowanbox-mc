// MWBYSMAnim.h — YSM 动画运行时（直接吃 fatfish_anim.json 原始关键帧），逐行对应 web/js/ysm-anim.js
// 取代旧链路（GLB 四元数 clip + scale sidecar）：全量旋转/位移/缩放＋molang＋catmull-rom＋pre/post，
// 分层覆盖 pre_parallel0..7 → 主动画 → parallel0..7（parallel_7 由控制器驱动），player_update 函数，
// 时间轴事件，ysm.second_order 二阶物理，主动画切换 0.2s 淡入，头随视角。
// 只算局部矩阵（local = T·Rz·Ry·Rx·S）与隐藏位，世界矩阵合成仍在 MWBGLBModel。
// 注释与日志一律中文。
#import <Foundation/Foundation.h>

// 每帧输入（tick 线程写最新值，渲染线程读；单位：米/秒、度、度/秒）
typedef struct {
    float groundSpeed;  // 水平速度
    float vertSpeed;    // 竖直速度（上正）
    float yawSpeed;     // 身体偏航角速度
    float headYaw;      // 头相对身体偏航（视角 − 身体，裹到 ±180）
    float headPitch;    // 俯仰（游戏 +0x7c 原值）
    BOOL onGround, inWater, flying, sneaking, sleeping, dead, swinging;
} MWBAnimInput;

// 载入 sidecar（节点名按 GLB 节点序给，用于骨名→节点号与静止角）；成功回 YES
BOOL MWBAnimLoad(NSString *path, const char *const *nodeNames, int nodeCount);
BOOL MWBAnimReady(void);
void MWBAnimUnload(void);
// 输入（tick 线程调）
void MWBAnimSetInput(const MWBAnimInput *in);
// 手动主动画（NULL/空 = 回自动）
void MWBAnimForceMain(const char *name);
// 推进 dt 秒（渲染线程每帧调）
void MWBAnimTick(float dt);
// 出姿势：rootSet 内节点写 local[16*ni]（列主序）与 hidden[ni]；nodeT 为 GLB 节点相对父轴心位移（3*ni）
void MWBAnimPose(const int *rootSet, int nRoot, const float *nodeT, float *local, char *hidden);
// 模型设置（v.roaming.*）
void MWBAnimSetRoaming(const char *name, float v);
// 诊断：当前主动画/控制器状态/寿命/二阶状态数
const char *MWBAnimMainName(void);
const char *MWBAnimCtrlState(void);
float MWBAnimLife(void);
int MWBAnimSecondOrderCount(void);
float MWBAnimDebugVar(const char *name);
float MWBAnimDebugSO(const char *name);
