/* MWBZhLang.mm — 0.10 中文汉化应用层 (I18n 静态 map 复写, 不碰游戏 bundle) */
#import "MWBCommon.h"
#import <map>
#import <string>

// I18n::get 反编译实锤: std::map 静态根在 slide+0x10034e440 (同进程同 libc++, 直接调 operator[] 类型安全)
static std::map<std::string, std::string> *MWB_I18nMap(void) {
    if (gGV != (int)MWBGameV0_10) return NULL;
    return (std::map<std::string, std::string> *)(MWBMainSlide() + 0x10034e440UL);
}

// 英文原表: 运行时从游戏自带 en_US.lang 解析 (只读 bundle, 不修改不打包)
static std::map<std::string, std::string> gOrigEn;
static BOOL gOrigLoaded = NO;
static void MWBLoadOrigEn(void) {
    if (gOrigLoaded) return;
    gOrigLoaded = YES;
    NSURL *u = [[NSBundle mainBundle] URLForResource:@"en_US" withExtension:@"lang"];
    if (!u) return;
    NSError *e = nil;
    NSString *s = [NSString stringWithContentsOfURL:u encoding:NSUTF8StringEncoding error:&e];
    if (!s) return;
    for (NSString *line in [s componentsSeparatedByCharactersInSet:[NSCharacterSet newlineCharacterSet]]) {
        NSString *t = [line stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (!t.length || [t hasPrefix:@"#"]) continue;
        NSRange r = [t rangeOfString:@"="];
        if (r.location == NSNotFound) continue;
        NSString *k = [t substringToIndex:r.location];
        NSString *v = [t substringFromIndex:r.location + 1];
        gOrigEn[[k UTF8String]] = [v UTF8String];
    }
}

// 按 gChinese 在 I18n map 上整表复写 (fillTranslations 之后调; 游戏内所有 I18n::get 即时生效, 无需重进)
void MWBApplyLang(void) {
    std::map<std::string, std::string> *m = MWB_I18nMap();
    if (!m || m->empty()) return;   // 翻译表还没加载 (早于 MinecraftClient::init), hook 点会补调
    if (gChinese) {
        for (int i = 0; i < MWBZhBlocksCount; i++) (*m)[MWBZhBlocks[i].k] = MWBZhBlocks[i].v;
        for (int i = 0; i < MWBZhGuiCount; i++) (*m)[MWBZhGui[i].k] = MWBZhGui[i].v;
    } else {
        MWBLoadOrigEn();
        for (auto &p : gOrigEn) (*m)[p.first] = p.second;
    }
    MWBLogFile(@"[汉化] 已应用%@", gChinese ? @"中文" : @"英文");
}
