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
// 入口矩阵（ES1：render hook 入口调，此时 MODELVIEW 即实体级变换）
void MWBGLBCaptureEntry(void);

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
