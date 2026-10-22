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

// 悬浮窗偏好 (悬浮窗设置页用; 存自家 Documents/mwbfloat.plist, 与游戏存档无关)
void MWBFloatApplyPrefs(void);   // 按偏好重布按钮 (大小/透明度)
void MWBFloatSetSize(int s);     // 0小48 / 1中64 / 2大80
void MWBFloatSetAlpha(int a);    // 0低0.55 / 1中0.8 / 2高1.0
void MWBFloatReset(void);        // 恢复默认 (中+不透明+右上)
