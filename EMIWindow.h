// EMIWindow.h — EMI 主窗口 (创造物品栏风格窗口 + 底部快捷栏)
#import <UIKit/UIKit.h>

@interface MWBEMIWindow : UIView
@property (nonatomic, copy) void (^onClose)(void);
- (void)showInView:(UIView *)view;
- (void)hide;
- (void)showRecipeForId:(int)itemId;
- (void)showVariantForId:(int)itemId;
@end
