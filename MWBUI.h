// MWBUI.h — 像素风 UI 套件 (配色/字体/像素视图/开关/按钮/侧栏图标)
#import <UIKit/UIKit.h>

#define MWB_COLOR(r,g,b)  [UIColor colorWithRed:(r)/255.0 green:(g)/255.0 blue:(b)/255.0 alpha:1.0]

extern UIColor *kTopBar;          // #777078 顶栏
extern UIColor *kSidebar;         // #a69d99 侧栏
extern UIColor *kSidebarLight;    // #c3bbb6
extern UIColor *kSidebarDark;     // #655f5f
extern UIColor *kInk;             // #343132
extern UIColor *kWhiteText;       // #eeeae6
extern UIColor *kPanelBG;         // rgba(15,16,14,0.66)
extern UIColor *kField;           // #302d2e
extern UIColor *kControl;         // #c5bcba
extern UIColor *kControlLight;    // #eee9e5
extern UIColor *kControlDark;     // #6b6668

UIFont *MWBPixelFont(CGFloat size);
void MWBRegisterFont(void);
NSAttributedString *MWBPixelText(NSString *text, UIFont *font, UIColor *color,
                                 CGFloat shadowX, CGFloat shadowY, UIColor *shadowColor);
UIBezierPath *MWBPathFromSVG(NSString *d);

// MC 原版点击音 (运行时从游戏 bundle 加载 click.m4a, 不打包版权素材)
void MWBPlayClick(void);
void MWBEnsureClickLoaded(void);

// 外边框 (4px 深色) + 内阴影 (左上浅色 / 右下深色)
@interface MWBPixelView : UIView
@property (nonatomic) CGFloat outerWidth;
@property (nonatomic, strong) UIColor *outerColor;
@property (nonatomic) CGFloat insetWidth;
@property (nonatomic, strong) UIColor *insetLight;
@property (nonatomic, strong) UIColor *insetDark;
@end

// 像素开关 (两格 i/b 样式)
@interface MWBPixelToggle : UIControl
@property (nonatomic, getter=isOn) BOOL on;
- (void)toggle;
@end

// 像素按钮 (Back / 分类按钮)
@interface MWBPixelButton : UIButton
@end

// 侧栏图标按钮
@interface MWBSideButton : UIControl
@property (nonatomic, getter=isActive) BOOL active;
- (instancetype)initWithSVGPaths:(NSArray<NSString *> *)paths;
@end
