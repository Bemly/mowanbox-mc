#import <UIKit/UIKit.h>
#import <stdint.h>

// minecraftpe 主二进制的 ASLR slide
// (Tweak.xm 计算速度常量等静态地址时使用, 实现在 EMI.mm)
extern uintptr_t MWBMainSlide(void);

// 调试模式开关 (由 Toolbox 面板控制, YES 时输出详细日志)
extern BOOL gMWBDebug;

// LocalPlayer 指针 (由 Tweak.xm 的 normalTick hook 维护)
extern void *gLocalPlayer;

// MC 原版点击音 (Tweak.xm 实现, 运行时从游戏 bundle 加载 click.m4a)
void MWBPlayClick(void);

// EMI 物品管理器入口 (现在作为悬浮窗菜单的第 5 项, 不再自建窗口/悬浮按钮)
@interface MWBEMIManager : NSObject
+ (void)install;
@end

// 合并进悬浮窗: 在宿主视图(悬浮窗根视图)上显示/隐藏 EMI 物品浏览器
@interface MWBEMIManager (Unified)
+ (void)presentBrowserInView:(UIView *)hostView onClose:(void (^)(void))onClose;
+ (void)dismissBrowser;
@end

// 调试用: 直接给予物品 (cycript 可调用)
// 用法: [MWBEMIManager giveItem:264 count:1]  (264=钻石)
//       [MWBEMIManager giveItem:35 count:1 aux:3]  (aux=颜色/变种/耐久)
@interface MWBEMIManager (Debug)
+ (BOOL)giveItem:(int)itemId count:(int)count;
+ (BOOL)giveItem:(int)itemId count:(int)count aux:(int)aux;
+ (void *)playerPointer;
@end
