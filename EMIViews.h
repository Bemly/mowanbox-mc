// EMIViews.h — EMI 视图组件 (纹理集/等距立方体/平面图标/格子/分类标签)
#import <UIKit/UIKit.h>

@interface MWBTextureAtlas : NSObject
@property (nonatomic, strong) UIImage *image;
@property (nonatomic, strong) NSDictionary<NSString *, NSArray*> *tiles;
+ (instancetype)terrainAtlas;
+ (instancetype)itemsAtlas;
- (CGRect)contentsRectForName:(NSString *)name index:(int)idx;
@end

@interface MWBCubeView : UIView
- (instancetype)initWithSize:(CGFloat)size;
- (void)setTopTile:(NSString *)top frontTile:(NSString *)front sideTile:(NSString *)side
          topIndex:(int)ti frontIndex:(int)fi sideIndex:(int)si;
@end

@interface MWBItemIconView : UIView
- (instancetype)initWithSize:(CGFloat)size;
- (void)setItemTile:(NSString *)name index:(int)idx;
@end

@interface MWBEMICell : UIView
@property (nonatomic, strong) UIView *content;
@property (nonatomic, copy) void (^onTap)(void);
@property (nonatomic, copy) void (^onDoubleTap)(void);
@property (nonatomic, copy) void (^onLongPress)(void);
@end

@interface MWBEMITab : UIControl
@property (nonatomic, getter=isActive) BOOL active;
- (instancetype)initWithIcon:(UIView *)icon;
@end
