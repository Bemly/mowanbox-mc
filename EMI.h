#import <UIKit/UIKit.h>
#import <stdint.h>

// minecraftpe 主二进制的 ASLR slide
// (Tweak.xm 计算速度常量等静态地址时使用, 实现在 EMI.mm)
extern uintptr_t MWBMainSlide(void);

// 调试模式开关 (由 Toolbox 面板控制, YES 时输出详细日志)
extern BOOL gMWBDebug;

// LocalPlayer 指针 (由 Tweak.xm 的 normalTick hook 维护)
extern void *gLocalPlayer;

// EMI 物品管理器入口 (独立于 Toolbox 菜单)
@interface MWBEMIManager : NSObject
+ (void)install;
@end

// 调试用: 直接给予物品 (cycript 可调用)
// 用法: [MWBEMIManager giveItem:264 count:1]  (264=钻石)
//       [MWBEMIManager giveItem:35 count:1 aux:3]  (aux=颜色/变种/耐久)
@interface MWBEMIManager (Debug)
+ (BOOL)giveItem:(int)itemId count:(int)count;
+ (BOOL)giveItem:(int)itemId count:(int)count aux:(int)aux;
+ (void *)playerPointer;
@end
