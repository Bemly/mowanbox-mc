// MWBGLBModel.h — GLB 直解直画（照抄 viewer：GLTFLoader 场景语义 + updateVisibility 叠加 + 自家小 shader）
// 数据：/var/mobile/Documents/mwbmodels/fatfish.glb（模型+内嵌贴图+48 动画）
//      + fatfish_vis.json（scale 轨道 sidecar + 设置定义，molang 表达式走 MWBGLBMolang）。
// 变换照抄 ysm_to_glb.py：节点 local = T(相对父轴心)·R(四元数)·S，世界 = 父·local；
// 动画旋转/位移只取 GLB 纯数字通道（molang 通道转的时候已跳过，viewer 同款）；
// scale 走 vis 叠加 pre→main→parallel（后者覆盖），molang 参与求值；
// 隐藏按 viewer 规则：任一分量 |c|<1e-3 即整组关（含子树）。
// 注释与日志一律中文。
#import <Foundation/Foundation.h>

// GLB 捕获到的矩阵（MWBHooks010 的 uniform hook 内调，投影/模型视图各存最新一份）
void MWBGLBCaptureMatrix(const float *m);
// WVP 快照（render hook 内 orig 之前调：此时绑定的正是给本实体上传的 program+uniform，
// 读出来就是香草画它用的 P·V；draw 内 post-orig 再读会拿到别的 pass，w<0 就是这么来的）
// 入口矩阵（不再使用；绘制走鱼链单次 sPartRender，矩阵由游戏栈处理）
void MWBGLBSnapshotWVP(void);
// 游戏真相机抓取（MobRenderer::render 入口 orig 前调，pos=本地玩家相对相机坐标；读 MatrixStack 三栈顶）
void MWBGLBCaptureEntity(const float *pos);

// 解析（任意线程可调，只做 CPU 事：读文件/解 JSON/拷顶点，不碰 GL；成功返回 YES）
BOOL MWBGLBEnsureParsed(void);
// 免重启重载（清掉重解，GL 对象下次首画重建）
void MWBGLBReload(void);
// 及格线自检（节点/网格/三角数，打日志供与 viewer stats 对账）
void MWBGLBLogStats(void);

// 绘制（必须 GL 线程调，即 render hook 内；首调编译 shader+上传贴图）
// entityMV 为 NULL 则用捕获到的模型视图矩阵。
void MWBGLBDraw(void);
// 诊断（glinfo2 打开关/解析/矩阵/uniform 调用/版本串）
void MWBGLBLogDiag(void);
// 是否真能画（开关+解析+矩阵齐才藏原版，否则不藏，免得鱼没画出来人也没了）
BOOL MWBGLBCanDraw(void);

// 当前动作名（默认 idle；GLB 里 clip 名带 main: 前缀，sidecar 用裸名，两种都试，viewer 同款）
void MWBGLBSetAnim(NSString *name);
// 自动动作（默认开：按香草同款状态进 locomotion clip；glbanim-<名> 手动后自动停，glbanim-auto 回自动）
void MWBGLBSetAuto(BOOL on);
// 每 tick 调一次（normalTick 内，gGLBModel 才调）：读状态→变化才切 clip
void MWBGLBAutoTick(void *player);
// 本体缩放（×，默认 1；glbscale-N 百分比免重编调）＋落位 Y 偏置（米，默认 0；glblift-N 厘米）
void MWBGLBSetScale(float s);
void MWBGLBSetLift(float m);
