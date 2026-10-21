// Tweak.xm — 魔玩我的世界盒子 (mowanbox-mc) 主入口
// 按分类拆分后仅保留: 全局状态定义 + %ctor (版本识别→调各版本安装函数→UI 安装)。
// UI 套件见 MWBUI.mm / 菜单见 MWBMenu.mm / 悬浮窗见 MWBFloat.mm /
// 各版本 hook 见 MWBHooks010/1133/117/143/1215/120.mm / 动作分发见 MWBActions.mm / 调试见 MWBDebug.mm。
#import <UIKit/UIKit.h>
#import <stdint.h>
#import "MWBCommon.h"
#import "MWBUI.h"
#import "MWBFloat.h"

// ---- 全局开关状态 (声明见 MWBCommon.h) ----
BOOL gInvincible  = NO;
BOOL gFly         = NO;
BOOL gFastBreak   = NO;
BOOL gSpeed       = NO;
BOOL gSuperJump   = NO;
BOOL gNoclip      = NO;
BOOL gNightVision = NO;
BOOL gKillAura    = NO;
BOOL gMinimap     = NO;
int  gGV          = 0;   // 当前游戏版本 (MWBGameVersion 数值, %ctor 内赋值, 跨版本分发用)
int  gTimeMode    = 0;   // 点按语义: 1=跳白天 2=跳夜晚, 下一个 tick 写一次即清零, 时间自然流
int  gTimeCustom010 = -1; // 0.10 绝对时刻跳转 (>=0 有效, hook 写一次即清零)
int  gWeatherMode = 0;   // 0=不修改 1=晴 2=雨 3=雷

void *gLocalPlayer = NULL;   // LocalPlayer* (EMI 也用)
void *gLevel      = NULL;

// ---- 版本指针 (声明见 MWBCommon.h) ----
void *gPlayer1133 = NULL, *gLevel1133 = NULL;
void *gPlayer117  = NULL;
void *gPlayer143  = NULL;
void *gPlayer1215 = NULL;
void *gLevelData120 = NULL, *gActor120 = NULL;
uint8_t gMiniMap1133[48 * 48];   // 小地图后端: 48x48单层采样 (矿石标红由UI侧着色)
uint8_t gMiniMap010[48 * 48];    // 0.10 小地图后端: 48x48表面扫描
uint8_t gMiniMap010H[48 * 48];    // 0.10 表面高度
uint8_t gMiniMap010D[48 * 48];    // 0.10 水深

%ctor {
    MWBRegisterFont();
    NSLog(@"[魔玩盒子] 插件已加载");
    // 版本自适应: 不依赖包名,运行时识别游戏版本再选注入方式,同一UI操作
    MWBGameVersion gv = [MWBVersion currentVersion];
    gGV = (int)gv;
    NSLog(@"[魔玩盒子] 当前游戏版本: %@ 注入方式=%ld",
          [MWBVersion nameForVersion:gv], (long)[MWBVersion currentInjectStyle]);

    // 0.10 永远安装 (符号 hook); 其余版本按识别结果安装
    MWBInstallHooks010();
    if (gv == MWBGameV1_13_3) MWBInstallHooks1133();
    if (gv == MWBGameV1_1_7)  MWBInstallHooks117();
    if (gv == MWBGameV1_4_3)  MWBInstallHooks143();
    if (gv == MWBGameV1_2_15) MWBInstallHooks1215();
    if (gv == MWBGameV1_20_62) MWBInstallHooks120();

    [[NSNotificationCenter defaultCenter]
        addObserverForName:UIApplicationDidFinishLaunchingNotification
                    object:nil queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *n){ MWBInstall(); }];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0*NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ MWBInstall(); });
}
