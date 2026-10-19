#import "MWBVersion.h"
#import <mach-o/dyld.h>
#import <sys/stat.h>

@implementation MWBVersion

static MWBGameVersion gVersion = MWBGameUnknown;
static dispatch_once_t gOnce;

+ (MWBGameVersion)currentVersion {
    dispatch_once(&gOnce, ^{
        gVersion = [self detectVersion];
        NSLog(@"[魔玩盒子] 游戏版本识别: %@ (%ld) 注入方式=%ld",
              [self nameForVersion:gVersion], (long)gVersion,
              (long)[self styleForVersion:gVersion]);
    });
    return gVersion;
}

+ (NSString *)currentVersionString {
    NSString *v = [[NSBundle mainBundle] objectForInfoDictionaryKey:@"CFBundleShortVersionString"];
    return v ?: @"";
}

// 识别优先级: 版本号字符串 > 主二进制大小 > 符号探测(0.10才有符号)
+ (MWBGameVersion)detectVersion {
    NSString *ver = [self currentVersionString];
    // 注意: 文件名"MCPE替身 1.4.3.ipa"的包内版本号实为1.13.3.0(二进制MD5与1.13.3相同),
    // 这里以包内真实版本号为准,不以文件名/包名为准
    if ([ver hasPrefix:@"0.10"]) return MWBGameV0_10;
    if ([ver hasPrefix:@"1.1.7"]) return MWBGameV1_1_7;
    if ([ver hasPrefix:@"1.2.15"]) return MWBGameV1_2_15;
    if ([ver hasPrefix:@"1.13.3"]) return MWBGameV1_13_3;
    if ([ver hasPrefix:@"1.4.3"]) return MWBGameV1_4_3;
    if ([ver hasPrefix:@"1.20"]) return MWBGameV1_20_62;

    // 兜底: 主二进制大小(解包后字节数,见逆向记录)
    const char *exe = NULL;
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const char *name = _dyld_get_image_name(i);
        if (name && strstr(name, "minecraftpe.app/minecraftpe")) { exe = name; break; }
    }
    if (exe) {
        struct stat st;
        if (stat(exe, &st) == 0) {
            MWBGameVersion gv = [self versionForBinarySize:(unsigned long long)st.st_size];
            if (gv != MWBGameUnknown) return gv;
        }
    }
    return MWBGameUnknown;
}

+ (MWBGameVersion)versionForBinarySize:(unsigned long long)size {
    // 允许±2M误差(签名/压缩差异)
    const unsigned long long M = 1024 * 1024;
    if (size > 7*M && size < 10*M) return MWBGameV0_10;     // 8.5M
    if (size > 22*M && size < 26*M) return MWBGameV1_1_7;   // 24M
    if (size > 29*M && size < 32*M) return MWBGameV1_2_15;  // 31M
    if (size > 32*M && size < 34*M) return MWBGameV1_4_3;   // 真1.4.3 33M
    if (size > 53*M && size < 57*M) return MWBGameV1_13_3;  // 55M
    if (size > 165*M && size < 175*M) return MWBGameV1_20_62; // 170M
    return MWBGameUnknown;
}

+ (MWBInjectStyle)currentInjectStyle {
    return [self styleForVersion:[self currentVersion]];
}

+ (MWBInjectStyle)styleForVersion:(MWBGameVersion)v {
    switch (v) {
        case MWBGameV0_10: return MWBInjectSymbol;
        case MWBGameV1_1_7:
        case MWBGameV1_2_15:
        case MWBGameV1_4_3:
        case MWBGameV1_13_3: return MWBInjectPattern;
        case MWBGameV1_20_62: return MWBInjectECS;
        default: return MWBInjectPattern;
    }
}

+ (NSString *)nameForVersion:(MWBGameVersion)v {
    switch (v) {
        case MWBGameV0_10: return @"0.10.0";
        case MWBGameV1_1_7: return @"1.1.7";
        case MWBGameV1_2_15: return @"1.2.15";
        case MWBGameV1_4_3: return @"真1.4.3";
        case MWBGameV1_13_3: return @"1.13.3";
        case MWBGameV1_20_62: return @"1.20.62";
        default: return @"未知版本";
    }
}

@end
