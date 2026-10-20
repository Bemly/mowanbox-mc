// MWBMenu.h — 选项菜单主视图 (左侧分类导航 + 右侧设置页)
#import <UIKit/UIKit.h>
#import "MWBUI.h"

@interface MWBOptionsMenu : UIView
@property (nonatomic, copy) void (^onClose)(void);
@property (nonatomic, strong) NSArray<UIView *> *pages;
@property (nonatomic) NSInteger currentPage;
- (void)showInView:(UIView *)view;
- (void)hide;
- (void)showPage:(NSInteger)idx;
@end
