// MWBYSMModel.h — Bedrock 骨骼盒子 → 游戏自家 ModelPart/Cube 搭建与渲染
// 职责：把上游解码器给出的 bones NSArray 搭成 ModelPart 树并渲染。
// 铁律：本文件只新增，不改仓库任何已有文件。
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

@interface MWBYSMModel : NSObject

// 用 bones+贴图建一套自家 ModelPart 树（含 GL 纹理），返回根 part 指针（堆内存，外部持有）；失败返回 NULL。
// 入参 bones：每项 NSDictionary{name:NSString, parent:NSString(可空),
//   pivot:@[x,y,z](float), rotation:@[x,y,z](度),
//   cubes:@[{origin:@[x,y,z], size:@[w,h,d], pivot:@[x,y,z], rotation:@[x,y,z],
//   uv:@{east/west/up/down/south/north:@[u,v,du,dv]像素}}]}。
// texW/texH：随模型传入的纹理尺寸（UV 归一化与 ModelPart 构造用）。
// img：已解码贴图（上游用 ImageIO 的 CGImageSourceCreateWithURL 解码 PNG 得到，
//   与 EMIViews.mm 同款链路）；本函数只做 CGImage→RGBA→glTexImage2D 上传。
// outTex：成功时写回自家 GL 纹理名（GLuint），img 为空则写 0。
// 注意（纹理绑定归属）：本类只建纹理、不负责绑定。上传时那一次 glBindTexture
//   的污染由调用方处理；renderTree 内部不做任何绑定/恢复（假设调用方已绑好）。
//   绑定/恢复由 hook 层做：调 Textures::bindTexture(manager, 自家路径)
//   → renderTree → 调 Textures::bindTexture(manager, 原路径) 恢复。
//   经理对象来源（hook 层用，本类不用）：manager=*(*(slide+0x10034d0b8)+0x18)，
///  静态 VA 待真机核对；取原贴图调虚表+0x2d8（Mob::getTexture，只读不 hook）。
+ (void *)buildWithBones:(NSArray *)bones texW:(int)texW texH:(int)texH textureGL:(unsigned *)outTex image:(UIImage *)img;

// 渲染整棵树（递归 children），带旋转/位移（旋转点/旋转角由 render 自家读）。
// 纯绘制：内部不绑定纹理，调用方须先绑好自家纹理（见上）。
// scale 为 HumanoidModel::render 的 f6，render 与其内部 compile 同款透传。
+ (void)renderTree:(void *)root;
+ (void)renderTree:(void *)root scale:(float)f;

// 隐藏/恢复 HumanoidModel 六件套（model 为 HumanoidModel*，hide=YES/NO）。
+ (void)setVanillaHidden:(void *)model hide:(BOOL)hide;

// 释放整棵树（含 GL 纹理，内部按根 part 查表删除）。
+ (void)freeTree:(void *)root;

// 面标定 dump（拿不准映射时真机调用）：把 cube 全部 6 个 quad 的 pos/uv 打到日志。
+ (void)dumpFaces:(void *)cube;

@end
