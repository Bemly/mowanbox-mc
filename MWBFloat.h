// MWBFloat.h — 单一悬浮窗 (头像 logo 按钮 + 透传窗口 + 主控制器 + 安装入口)
#import <UIKit/UIKit.h>
#import "MWBMenu.h"

@interface MWBFloatingButton : UIView
@property (nonatomic, copy) void (^onTap)(void);
@end

@interface MWBOverlayWindow : UIWindow
@end

@interface MWBViewController : UIViewController
@property (nonatomic, strong) MWBFloatingButton *floatButton;
@property (nonatomic, strong) MWBOptionsMenu *menu;
- (void)toggleMenu;
@end

// 整包 UI 安装入口 (overlay 窗口 + EMI, %ctor 调用, 幂等)
void MWBInstall(void);
