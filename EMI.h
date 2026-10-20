#import <UIKit/UIKit.h>
#import <stdint.h>

// minecraftpe 主二进制的 ASLR slide
// (Tweak.xm 计算速度常量等静态地址时使用, 实现在 EMI.mm)
extern uintptr_t MWBMainSlide(void);

// 调试模式开关 (由 Toolbox 面板控制, YES 时输出详细日志)
extern BOOL gMWBDebug;

// LocalPlayer 指针 (由 Tweak.xm 的 normalTick hook 维护)
extern void *gLocalPlayer;

// 调试日志: NSLog + 写 /var/mobile/Documents/mowanbox.log (实现在 EMI.mm)
void MWBDLog(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);

// 缩放系数 (按 1920x1080 参考算, 实现在 EMI.mm)
extern CGFloat kEMIScale;

// MC 原版点击音 (Tweak.xm 的 MWBUI.mm 实现, 运行时从游戏 bundle 加载 click.m4a)
void MWBPlayClick(void);

#define EMIColor(r,g,b) [UIColor colorWithRed:(r)/255.0 green:(g)/255.0 blue:(b)/255.0 alpha:1.0]

// ---- 物品数据 (定义在 EMIItems.mm) ----
typedef struct {
    const char *cnName;     // 中文名
    BOOL isBlock;           // YES=方块(立方体) NO=物品(平面图标)
    int itemId;             // MCPE 物品/方块数字 ID
    const char *tile;       // terrain 组名(方块) 或 items 组名(物品)
    int idx;                // tile 索引
    // 方块三面 (若与 tile/idx 相同则填 NULL/-1)
    const char *topTile; int topIdx;
    const char *frontTile; int frontIdx;
    const char *sideTile; int sideIdx;
    int maxStack;           // 最大堆叠
    int category;           // 0=全部 1=装备 2=配方 3=建筑
} MWBItemDef;
extern int gItemCount;
extern MWBItemDef gItems[];
const MWBItemDef *MWBItemDefForId(int itemId);
NSString *MWBItemName(int itemId);
int MWBVariantCount(int itemId);
NSString *MWBVariantName(int itemId, int aux);
NSArray *MWBGameRecipesForItem(int itemId);  // 每条= @[9格id数组, 产物数量]

// 物品给予后端 (实现在 EMI.mm)
bool MWBGiveItem(int id, int count, int aux);
void **mwb_items_registry(void);

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
