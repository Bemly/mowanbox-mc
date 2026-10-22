// MWBCommon.h — 魔玩盒子共享声明
// 拆分后的跨文件接口集中在此: 全局状态 extern、跨文件函数声明、共用结构/常量。
// (UI/菜单/悬浮窗/各版本 hook/动作分发/调试 .mm 都 import 它)
#import <Foundation/Foundation.h>
#import <substrate.h>
#import "MWBVersion.h"
#import "EMI.h"

// ---- 0.10 偏移/常量 ----
#define PLAYER_ABILITIES_OFFSET   5824
#define ABIL_INVULNERABLE 0
#define ABIL_FLYING 1
#define ABIL_MAY_FLY 2
#define ABIL_INSTABUILD 3
#define LEVEL_TIME_OFFSET 5512
#define LEVEL_TIME_OVERRIDE_OFF 0x15F0   // 天空覆写(>=0 时亮度/天色只认它,不认 dayTime;-1=跟随 dayTime)
#define ENTITY_VELOCITY_Y_OFFSET 112
#define ENTITY_YAW_OFF   0x78   // LocalPlayer 偏航角(度, 转视角前后内存diff实锤: 311→432, 旧0xAC恒0是错的)
#define ENTITY_PITCH_OFF 0x7C   // LocalPlayer 俯仰角(度, 与yaw相邻成对, 转视角不变)
#define TICK_TIME_DAY 1000
#define TICK_TIME_NIGHT 13000

// ---- 方块坐标 (1.13.3 WorldEdit + 0.10 铺石 + 诊断共用) ----
typedef struct { int x, y, z; } MWBBlockPos;

// ---- 全局开关/状态 (定义在 Tweak.xm) ----
extern BOOL gInvincible, gFly, gFastBreak, gSpeed, gSuperJump;
extern BOOL gNoclip, gNightVision, gKillAura, gMinimap, gSlimeChunk, gChinese;
extern int gGV, gTimeMode, gWeatherMode;
extern int gTimeCustom010;   // 0.10 绝对时刻跳转 (Tweak.xm 定义, MWBHooks010 消费)
extern void *gLevel;

// ---- 版本指针 (定义在 Tweak.xm) ----
extern void *gPlayer1133, *gLevel1133;
extern void *gPlayer117;
extern void *gPlayer143;
extern void *gPlayer1215;
extern void *gLevelData120, *gActor120;
extern uint8_t gMiniMap1133[48 * 48];   // 小地图采样缓存 (1133 采样/动作侧读取)
extern uint8_t gMiniMap010[48 * 48];
extern uint8_t gMiniMap010H[48 * 48];   // 0.10 表面高度 (明暗用)
extern uint8_t gMiniMap010D[48 * 48];   // 0.10 水深 (水色用, 非水=0)    // 小地图采样缓存 (0.10 采样/动作侧读取）

// ---- 进世界判定 (定义在 MWBFloat.mm, 各版本 tick 打点) ----
void MWBMarkWorldTick(void);
BOOL MWBIsInWorld(void);

// ---- 各版本 hook 安装 (定义在各 MWBHooks*.mm, %ctor 调用) ----
void MWBInstallHooks010(void);
void MWBInstallHooks1133(void);
void MWBInstallHooks117(void);
void MWBInstallHooks143(void);
void MWBInstallHooks1215(void);
void MWBInstallHooks120(void);

// ---- 文件日志 (定义在 MWBActions.mm) ----
void MWBLogFile(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

// ---- 符号 hook 安装宏 (各 MWBInstallHooks* 用; 日志进 NSLog + 文件) ----
#define MWB_HOOK(mangled, replacement, original) do { \
    void *_s = MSFindSymbol(NULL, mangled); \
    if (_s) { MSHookFunction(_s, (void *)replacement, (void **)&original); \
        NSLog(@"[魔玩盒子] 已 hook: %s -> %p", mangled, _s); \
        MWBLogFile(@"[Toolbox] hook 成功: %s @ %p", mangled, _s); } \
    else { NSLog(@"[魔玩盒子] 警告: 未找到 %s", mangled); \
        MWBLogFile(@"[Toolbox] hook 失败: 未找到 %s", mangled); } \
} while (0)

// ---- 跨版本动作 (定义在 MWBActions.mm) ----
void MWBHealNow(void);
void MWBApplyTimeTag(int tag);   // 时间按钮语义 (菜单/flag 共用, 定义在 MWBActions.mm)
void MWBEnchantHeld255(void);
void MWBTeleportUp10(void);
void MWBFillStone5(void);
void MWBMinimapShow(BOOL on);
void MWBMinimapRefresh(void);
BOOL MWBIsSlimeChunk(int chunkX, int chunkZ);   // 史莱姆区块判定 (定义在 MWBMinimap.mm, 与游戏同算法)
void MWBApplyLang(void);   // 汉化: 按 gChinese 把中文表/英文原表写入 I18n 静态 map (定义在 MWBZhLang.mm)

// 汉化表条目 (表定义在 MWBZhBlocks.mm / MWBZhGui.mm, 数据行不计入手写代码行数)
typedef struct { const char *k; const char *v; } MWBZhEntry;
extern const MWBZhEntry MWBZhBlocks[];
extern const int MWBZhBlocksCount;
extern const MWBZhEntry MWBZhGui[];
extern const int MWBZhGuiCount;
void MWBPollCmdFile(void);
BOOL MWBWeatherSupported(void);
BOOL MWB010Only(void);
void MWBApplySpeed(BOOL on);

// ---- 1.13.3 后端 (定义在 MWBHooks1133.mm) ----
void MWB1133_KillAuraTick(void);
int MWB1133_SampleMinimap(void);
int MWB010_SampleMinimap(void);   // 0.10 表面扫描 (TileSource::getTile 逐列找顶)
bool MWB1133_ApplyEffect(void *actor, int fxId, int amplifier, int durTicks);
bool MWB1133_TeleportUp10(void *actor);
int MWB1133_FillStone(int half);
void MWB1133_ForEachActor(void *level, void (^blk)(void *actor));
void *MWB1133BlockSource(void);
void *MWB1133BlockById(int blockId);
void *MWB1133GetOne(void *bs, int x, int y, int z);
int MWB1133SetOne(void *bs, int x, int y, int z, void *blk);
int MWB1133_BlockIdOf(void *blk);
#define V1133_BLOCKBASE_VA 0x1034C8870UL   // (动作诊断只读验证用)

// ---- 1.1.7 后端 (定义在 MWBHooks117.mm) ----
bool MWB117_Give(void *player, int itemId, int count);
bool MWB117_EnchantMax(void *player, int enchId, int level);
#define V117_ITEMREG_VA  0x10178CCF8UL     // (动作诊断背包扫描用)
#define V117_HELDITEM_VA 0x100A4A110UL     // (动作诊断手持 dump 用)

// ---- 1.4.3 后端 (定义在 MWBHooks143.mm) ----
bool MWB143_Give(void *player, int itemId, int count);
bool MWB143_EnchantMax(void *player, int enchId, int level);
bool MWB143_Effect(void *player, int fxId, int seconds, int ampl);
bool MWB143_Teleport(void *player, float x, float y, float z);
bool MWB143_SetGameType(void *player, int type);

// ---- 1.2.15 后端 (定义在 MWBHooks1215.mm) ----
bool MWB1215_GiveBlock(void *player, int blkId, int count);
bool MWB1215_EnchantHeld(void *player, int enchId, int level);
bool MWB1215_Effect(void *player, int fxId, int seconds, int ampl);
bool MWB1215_Teleport(void *player, float x, float y, float z);
bool MWB1215_AddXP(void *player, int pts);

// ---- 1.20.62 后端 (定义在 MWBHooks120.mm) ----
void MWB120ProbeMobEffect(void);

// ---- 0.10 后端 (定义在 MWBHooks010.mm) ----
uint8_t MWB010GetTile(void *ts, MWBBlockPos *pos);   // 方块读取 (定义在 MWBMinimap.mm, 渲染线程只读可调)
void *MWB010Minecraft(void);   // MinecraftClient::tick 捕获的 MC (只读探针用, 可为 NULL)
extern int gMcTick010Count;    // MinecraftClient::tick 调用计数 (client tick 存活探针)
void MWB010SetCreative(void *player, bool creative);
void MWB010SetCreativeFull(bool creative);
void MWBSetGameMode010(int mode);   // 生存/创造切换 (定义在 MWBActions.mm, 0=生存 1=创造)
bool MWB010Teleport(void *player, float x, float y, float z);
void MWBSetDifficulty010(int difficulty);
void MWB010SpawnReactor(void);
void MWB010SpawnMob(int typeId);
void MWB010Explode(void);
void MWB010NightVisionTick(void);   // 夜视: 改游戏 gamma(Options+0x2D0), 开关都要调(关时恢复)
void MWB010Sink(int dy);            // 穿墙验证: 原地垂直传送(正下/负上)
// 穿墙透视诊断计数 (定义在 MWBHooks010.mm, glinfo flag 打)
int MWB010GLCalls(void);
int MWB010GLPersp(void);
int MWB010GLBuried(void);
int MWB010GLPatched(void);
int MWB010GOTSlots(void);
