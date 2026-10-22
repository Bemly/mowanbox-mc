// MWBYSMCodec.h — 魔玩盒子 .ysm 模型解码器对外接口
// 只读 .ysm 文件 (YSGP 容器, format 32, crypto 3), 输出骨骼盒子结构与 PNG 贴图字节。
// 注释与日志一律中文；调用方无需关心内部实现。
#import <Foundation/Foundation.h>

@interface MWBYSMCodec : NSObject
// 输入 .ysm 文件 URL；输出：
// bones 数组 (每项 NSDictionary{name, parent, pivot@[x,y,z], rotation@[x,y,z]度,
//   cubes@[ {origin, size, pivot, rotation, uv:{面名:@[u,v,du,dv]像素}} ]})，
// texturePNG 为名 white 的 PNG 原字节，texW/texH 为纹理尺寸。
// 成功返回 YES；失败返回 NO 并填 error。
+ (BOOL)loadYSM:(NSURL *)url
          bones:(NSArray **)outBones
     texturePNG:(NSData **)outPNG
            texW:(int *)w
            texH:(int *)h
           error:(NSError **)err;
@end
