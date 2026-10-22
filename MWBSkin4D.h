// MWBSkin4D.h — 4D皮肤模块对外接口 (P1: 迷你史蒂夫)
// 简单模型先行验证渲染链: 同一史蒂夫只做缩放, 不改几何, 动画全保留。
// 开关 gSkin4D 在 Tweak.xm 定义, 绘制窗口 gMiniDrawScope 在 MWBSkin4D.mm 定义。
#import <Foundation/Foundation.h>

extern BOOL gSkin4D;        // 总开关 (默认关, 菜单/flag/cycript 三入口)
extern BOOL gMiniDrawScope; // 本地玩家自家绘制窗口 (render hook 置位, uniform 层消费)

// 0.10 才安装 (%ctor 调用, 版本不对直接返回)
void MWBSkin4DInstall(void);
// 均匀层消费: 模型矩阵做列缩放 (M*S, 原点不动), 投影矩阵不碰。
// 返回 YES=已命中 (调用方直接代传 return), NO=没命中 (调用方走原逻辑)。
BOOL MWBMini4DScaleMatrix(const float *m, float *out);
