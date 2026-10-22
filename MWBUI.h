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
// 插件自身语言 (0中文 1英文, 默认中文, 落盘自家 Documents/mwbpluglang.plist;
// 与游戏汉化 gChinese 独立, 由悬浮窗页语言按钮一键双切)
void MWBSetPluginLang(int lang);
int MWBPluginLang(void);
// 插件中英翻译 (key 为英文 ID, 中文模式回中文, 查不到回 key 本身)
NSString *MWBTr(const char *key);
NSAttributedString *MWBPixelText(NSString *text, UIFont *font, UIColor *color,
                                 CGFloat shadowX, CGFloat shadowY, UIColor *shadowColor);
UIBezierPath *MWBPathFromSVG(NSString *d);
// 游戏原版图标 (运行时从游戏 bundle 切图, 不打包版权素材;
// file=包内文件名如 touchgui.png, rect=256基准像素区;
// 找不到文件/越界一律回 nil, 调用方用 SVG 兜底; 切图矩形见 MWBMenu.mm 图标表, 真机截图调)
UIImage *MWBGameIcon(NSString *file, CGRect rect);

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
// 游戏原版图标按钮 (img 居中显示, 像素风最近邻放大; img=nil 时调用方改用 SVG 版)
- (instancetype)initWithImage:(UIImage *)img;
// 任意图标视图 (EMI 立方体/物品图标等, 居中嵌入, 触摸穿透)
- (instancetype)initWithIconView:(UIView *)icon;
@end
