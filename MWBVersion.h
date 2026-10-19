#import <Foundation/Foundation.h>

// 游戏版本(运行时识别,不依赖注入时的包名判断)
typedef NS_ENUM(NSInteger, MWBGameVersion) {
    MWBGameUnknown = 0,
    MWBGameV0_10,    // 0.10.0, 8.5M, 符号齐全
    MWBGameV1_1_7,   // 1.1.7.1, 24M, 全strip
    MWBGameV1_2_15,  // 1.2.15.1, 31M, 全strip
    MWBGameV1_4_3,   // 真1.4.3.0, 33M, 全strip (注意:文件名"MCPE替身 1.4.3.ipa"实为1.13.3,勿信文件名)
    MWBGameV1_13_3,  // 1.13.3.0, 55M, 全strip (文件名1.4.3的包实为此版本,MD5相同)
    MWBGameV1_20_62, // 1.20.62.01, 170M, ECS重构
};

// 各版本注入方式差异(子agent逆向结论汇总)
typedef NS_ENUM(NSInteger, MWBInjectStyle) {
    MWBInjectSymbol,   // 0.10: MSFindSymbol直接按名hook
    MWBInjectPattern,  // 1.1.7/1.2.15/1.13.3: 字符串锚点+pattern定位,再hook
    MWBInjectECS,      // 1.20.62: EnTT ECS,需动态探查,暂不hook(只读观察)
};

@interface MWBVersion : NSObject
// 当前游戏版本(单例,首次调用时识别并缓存)
+ (MWBGameVersion)currentVersion;
+ (NSString *)currentVersionString;
+ (MWBInjectStyle)currentInjectStyle;
// 各版本主二进制解包后大小(字节),用于版本字符串缺失时的兜底判断
+ (MWBGameVersion)versionForBinarySize:(unsigned long long)size;
// 调试用: 版本名
+ (NSString *)nameForVersion:(MWBGameVersion)v;
@end
