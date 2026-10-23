/* EMI.mm — EMI 物品管理器 (给予后端+管理器入口). 视图见EMIViews, 窗口见EMIWindow, 数据见EMIItems. */
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <ImageIO/ImageIO.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <substrate.h>
#import <string.h>
#import "EMI.h"
#import "EMIViews.h"
#import "EMIWindow.h"

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <ImageIO/ImageIO.h>
#import <objc/runtime.h>
#import <mach-o/dyld.h>
#import <substrate.h>
#import <string.h>
#import "EMI.h"

/* ============================================================
 * 物品给予功能 (C++ hook MCPE 0.10.0)
 *
 * 逆向结果 (2026-08-28 经符号表+反汇编核实):
 * - LocalPlayer 指针由 Tweak.xm 的 normalTick hook 维护
 * - Player+0x1708 = Inventory*
 * - 物品注册表 = 游戏静态数组 Item::items (Item* items[512]),
 *   符号 __ZN4Item5itemsE, 用 MSFindSymbol 运行时解析,
 *   不再硬编码地址 (旧硬编码 0x10034cd00 实为 __MergedGlobals 常量池, 是错的)
 * - Inventory::add(ItemInstance*) 符号 __ZN9Inventory3addEP12ItemInstance,
 *   直接调用 (旧 vtable+0x148 槽位不是 add, 是错的)
 * - ItemInstance 布局 (FillingContainer::add 反汇编确认):
 *   id@0x00(int) count@0x04(int) Item*@0x08(ptr) valid@0x18(byte)
 *   注意 valid 必须在 0x18, 旧结构体因对齐把它排到了 0x20 导致永远被拒
 * ============================================================ */

// ItemInstance 结构 (0.10 真实布局, 0x20 字节; 这里多留 0x20 清零保险区)
// 没有独立 id 字段! 物品种类由 +0x08 的 Item* 决定:
//   +0x00 count 数量
//   +0x04 aux  辅助值: 工具=剩余耐久 / 染料羊毛=颜色 / 其他=变种号 (0=新物品)
//   +0x08 item Item 指针
//   +0x10 info 每物品静态信息指针 (全局表 0x100353790[id], 游戏自己的实例都有值)
//   +0x18 valid 有效标志
// (2026-08-28 实测教训: 把 id 写到 +0x00 会给出 id 个物品; aux 写成 1 会让
//  工具耐久变 1、钻石无法放进钻石块配方)
struct MWBItemInstance {
    int count;          // 0x00
    int aux;            // 0x04
    void *item;         // 0x08
    void *info;         // 0x10
    uint8_t valid;      // 0x18
    uint8_t pad[7];     // 0x19..0x1F
    uint8_t pad2[0x20]; // 0x20..0x3F 保险清零区
};

// 每物品静态信息表 (配方可拷贝循环写入实例 +0x10 处的同一张表)
#define MWB_ITEM_INFO_TABLE_VMADDR 0x100353790UL

static uintptr_t gSlide = 0;                 // ASLR slide
// 调试模式开关 (由 Toolbox 面板控制)
BOOL gMWBDebug = NO;
// 缩放系数 (按 1920x1080 参考算, 各视图共用)
CGFloat kEMIScale = 1.0;

// 调试日志: 同时输出 NSLog 和写文件 (设备上 /var/mobile/Documents/mowanbox.log)
void MWBDLog(NSString *fmt, ...) {
    va_list args; va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSString *line = [NSString stringWithFormat:@"%@ %@\n",
                      [NSDate date], msg];
    NSLog(@"%@", msg);
    // 追加写文件 (URL-based API, iOS 12 推荐)
    NSURL *logURL = [NSURL fileURLWithPath:MWB_LOG_PATH];
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingToURL:logURL error:nil];
    if (fh) {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
        [fh closeFile];
    } else {
        NSError *writeErr = nil;
        [line writeToURL:logURL atomically:YES encoding:NSUTF8StringEncoding error:&writeErr];
        if (writeErr) NSLog(@"[EMI] 日志写入失败: %@", writeErr.localizedDescription);
    }
}

// LocalPlayer::normalTick
// 注意: LocalPlayer::normalTick 已在 Tweak.xm 中 hook, gLocalPlayer 由那里维护
// EMI 不需要重复 hook, 直接使用 gLocalPlayer 即可

// 获取 minecraftpe 主二进制的 ASLR slide
// 注意: 不能用 image 0, Substrate 注入后 image 0 可能是其他 dylib
static uintptr_t mwb_slide() {
    if (!gSlide) {
        for (uint32_t i = 0; i < _dyld_image_count(); i++) {
            const char *name = _dyld_get_image_name(i);
            if (name && strstr(name, "minecraftpe.app/minecraftpe")) {
                gSlide = _dyld_get_image_vmaddr_slide(i);
                break;
            }
        }
        if (!gSlide) {
            // 兜底: 用 image 0
            gSlide = _dyld_get_image_vmaddr_slide(0);
        }
    }
    return gSlide;
}

// 供 Tweak.xm 等外部使用的 slide 入口 (mwb_slide 仅本文件可见)
uintptr_t MWBMainSlide(void) { return mwb_slide(); }

// 物品注册表: 游戏静态数组 Item::items (方块与物品都在其中, 512 项)
void **mwb_items_registry(void) {
    static void **reg = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        reg = (void **)MSFindSymbol(NULL, "__ZN4Item5itemsE");
        MWBDLog(@"[EMI调试] Item::items 注册表 = %p", reg);
    });
    return reg;
}

// Inventory::add(ItemInstance*): 内部检查后转调 FillingContainer::add 完成入库
typedef bool (*MWBAddFn)(void *, MWBItemInstance *);
static MWBAddFn mwb_inventory_add(void) {
    static MWBAddFn fn = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fn = (MWBAddFn)MSFindSymbol(NULL, "__ZN9Inventory3addEP12ItemInstance");
        MWBDLog(@"[EMI调试] Inventory::add = %p", fn);
    });
    return fn;
}

// 背包回读: 直接读游戏物品栏格子, 验证真实入库情况 (Container::getItem = vtable+0x10)
static void MWBDumpInventory(void *inventory, NSString *tag) {
    static int (*getSize)(void *) = NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        getSize = (int (*)(void *))MSFindSymbol(NULL, "__ZNK9Inventory16getContainerSizeEv");
    });
    if (!getSize || !inventory) return;
    void **vtable = *(void ***)inventory;
    void *(*getItem)(void *, int) = (void *(*)(void *, int))vtable[0x10 / 8];
    if (!getItem) return;
    int n = getSize(inventory);
    if (n < 0 || n > 36) n = 36;
    NSMutableString *m = [NSMutableString stringWithFormat:@"[EMI调试] 背包回读(%@) %d 格:", tag, n];
    for (int i = 0; i < n; i++) {
        void *inst = getItem(inventory, i);
        if (!inst) continue;
        int count = *(int *)inst, aux = *(int *)((char *)inst + 4);   // count@0x00, aux@0x04
        if (count == 0 && aux == 0) continue;
        [m appendFormat:@" [i%d aux=%d×%d]", i, aux, count];
    }
    MWBDLog(@"%@", m);
}

// 给予物品: id=MCPE物品ID, count=数量, aux=辅助值 (0=新物品; 变种/颜色用 aux 指定)
bool MWBGiveItem(int id, int count, int aux) {
    MWBDLog(@"[EMI调试] ===== 给予物品开始 id=%d count=%d =====", id, count);
    if (!gLocalPlayer) {
        MWBDLog(@"[EMI调试] 给予失败: 玩家未就绪 (还没进入世界)");
        return false;
    }
    if (count <= 0) count = 1;

    // Player+0x1708 = Inventory*
    void *inventory = *(void **)((char *)gLocalPlayer + 0x1708);
    MWBDLog(@"[EMI调试] player=%p inventory=%p", gLocalPlayer, inventory);
    if (!inventory) { MWBDLog(@"[EMI调试] 给予失败: 物品栏为空"); return false; }

    // 从 Item::items 注册表取 Item*
    void **registry = mwb_items_registry();
    if (!registry || id < 0 || id >= 512) {
        MWBDLog(@"[EMI调试] 给予失败: 注册表未解析或 ID %d 越界", id);
        return false;
    }
    void *item = registry[id];
    MWBDLog(@"[EMI调试] registry[%d]=%p", id, item);
    if (!item) { MWBDLog(@"[EMI调试] 给予失败: 物品 ID %d 未注册", id); return false; }

    // 构造 ItemInstance (valid 必须在 0x18; aux=0 保证满耐久/可参与配方)
    MWBItemInstance inst;
    memset(&inst, 0, sizeof(inst));
    inst.count = count;
    inst.aux = aux;
    inst.item = item;
    inst.info = *(void **)(MWBMainSlide() + MWB_ITEM_INFO_TABLE_VMADDR + (uintptr_t)id * 8);
    inst.valid = 1;
    MWBDLog(@"[EMI调试] ItemInstance: count=%d aux=%d item=%p info=%p valid@0x18=1 size=%zu",
                         inst.count, inst.aux, inst.item, inst.info, sizeof(inst));

    // 直接调用 Inventory::add
    MWBAddFn add = mwb_inventory_add();
    if (!add) { MWBDLog(@"[EMI调试] 给予失败: Inventory::add 未解析"); return false; }
    bool ok = false;
    @try {
        MWBDumpInventory(inventory, @"给予前");
        ok = add(inventory, &inst);
    } @catch (NSException *e) {
        MWBDLog(@"[EMI调试] add 调用异常: %@", e);
        return false;
    }
    MWBDumpInventory(inventory, ok ? @"给予后" : @"失败后");
    MWBDLog(@"[EMI] 给予物品 id=%d count=%d %@", id, count, ok ? @"成功" : @"失败(物品栏可能已满)");
    return ok;
}

// 初始化物品给予 (运行时解析符号并落盘日志)
static void MWBInstallGiver() {
    MWBDLog(@"[EMI调试] ===== 物品给予模块初始化 =====");
    for (uint32_t i = 0; i < 3; i++) {
        const char *name = _dyld_get_image_name(i);
        intptr_t s = _dyld_get_image_vmaddr_slide(i);
        MWBDLog(@"[EMI调试] image[%d] slide=0x%lx name=%s", i, (long)s, name ? name : "?");
    }
    void **reg = mwb_items_registry();
    MWBAddFn add = mwb_inventory_add();
    MWBDLog(@"[EMI] 物品给予模块已就绪 (registry=%p add=%p)", reg, add);
    MWBDumpItemRegistry();
}

// 游戏 getName 同款: 虚表 +0x118 即 getDescriptionId (Item::getName 反编译实锤),
// 只读调它拿真名, 比猜 id 准
static NSString *MWBDescOfItem(void *item) {
    if (!item) return nil;
    void *fn = *(void **)((char *)(*(void **)item) + 0x118);
    if (!fn) return nil;
    char tmp[24]; memset(tmp, 0, sizeof(tmp));
    register void *r0 __asm__("x0") = item;
    register void *r8 __asm__("x8") = tmp;
    __asm__ volatile (
        "blr %[fn]\n"
        : "+r" (r0), "+r" (r8)
        : [fn] "r" (fn)
        : "memory", "cc", "x1", "x2", "x3", "x4", "x5", "x6", "x7",
          "x9", "x10", "x11", "x12", "x13", "x14", "x15", "x16", "x17");
    uint8_t *s = (uint8_t *)tmp;
    // libc++ 布局: 末字节低位 1=长串 ([0]=指针 [8]=长度), 0=短串 (数据在位, 长度=末字节>>1)
    // (之前分支写反 + 长串偏移错, 读出野指针导致进程静默死亡, 真名全变问号)
    if (s[23] & 1) {
        void *p = *(void **)s;
        size_t n = *(size_t *)(s + 8);
        if (!p || n == 0 || n > 256) return nil;
        return [[NSString alloc] initWithBytes:p length:n encoding:NSUTF8StringEncoding];
    }
    size_t n = s[23] >> 1;
    if (n > 23) return nil;
    return [[NSString alloc] initWithBytes:tmp length:n encoding:NSUTF8StringEncoding];
}

// dumpitems: 扫 Item::items[512] 落盘全部已注册 id+真名 (与 EMI 表做 diff, 找原版缺口;
// 索引即 id, <256 为方块, >=256 为物品; preload 和世界 tick 里都接, 以世界内为准)
// C 缓冲分行拼 (appendFormat 拼百项大行会被吞, 见小地图教训; 真名走 getDescriptionId 只读调)
void MWBDumpItemRegistry(void) {
    if (![[NSFileManager defaultManager] fileExistsAtPath:@"/tmp/mwbcmd-dumpitems"]) return;
    [[NSFileManager defaultManager] removeItemAtPath:@"/tmp/mwbcmd-dumpitems" error:nil];
    void **reg = mwb_items_registry();
    if (!reg) { MWBDLog(@"[dumpitems] 注册表未解析"); return; }
    static char buf[2048];
    int total = 0;
    for (int pass = 0; pass < 2; pass++) {
        int lo = pass ? 256 : 0, hi = pass ? 512 : 256;
        int n = snprintf(buf, sizeof(buf), "[dumpitems] %s:", pass ? "I" : "B");
        int cnt = 0;
        for (int i = lo; i < hi && n > 0 && n < (int)sizeof(buf) - 128; i++) {
            if (!reg[i]) continue;
            NSString *d = MWBDescOfItem(reg[i]);
            const char *nm = d ? [d UTF8String] : "?";
            n += snprintf(buf + n, sizeof(buf) - n, " %d=%s", i, nm);
            if (++cnt % 12 == 0) { MWBDLog(@"%s", buf); n = 0; }
        }
        if (n > 0) MWBDLog(@"%s", buf);
        total += cnt;
        MWBDLog(@"[dumpitems] %s共%d项", pass ? "物品" : "方块", cnt);
    }
    MWBDLog(@"[dumpitems] 合计%d项已注册", total);
}

// dumpcats: 复刻原版 CreativeInventoryScreen::populateItems 尾部分发扫全表分类
// (方块: Tile* 非空读 Tile+0x8c, 否则读 Item+0x58; 原版 tab=cat-1, 共 4 个 tab 向量)
// 与 EMI 表 category 做 diff, 把错位的物品搬到原版同 tab; C 缓冲拼行
// (NSMutableString appendFormat 拼大数据行会被吞, 见小地图教训)
void MWBDumpItemCats(void) {
    if (![[NSFileManager defaultManager] fileExistsAtPath:@"/tmp/mwbcmd-dumpcats"]) return;
    [[NSFileManager defaultManager] removeItemAtPath:@"/tmp/mwbcmd-dumpcats" error:nil];
    void **reg = mwb_items_registry();
    if (!reg) { MWBDLog(@"[dumpcats] 注册表未解析"); return; }
    void **tiles = (void **)(MWBMainSlide() + MWB_ITEM_INFO_TABLE_VMADDR);
    static char buf[16384];
    int n = snprintf(buf, sizeof(buf), "[dumpcats] cat(原版tab=cat-1):");
    int cnt[8] = {0,0,0,0,0,0,0,0};
    for (int i = 0; i < 512 && n > 0 && n < (int)sizeof(buf) - 16; i++) {
        void *it = reg[i];
        if (!it) continue;
        void *t = (i < 256) ? tiles[i] : NULL;
        int cat = t ? *(int *)((char *)t + 0x8c) : *(int *)((char *)it + 0x58);
        if (cat >= 0 && cat < 8) cnt[cat]++;
        n += snprintf(buf + n, sizeof(buf) - n, " %d=%d", i, cat);
    }
    MWBDLog(@"%s", buf);
    MWBDLog(@"[dumpcats] 各cat数量: 0=%d 1=%d 2=%d 3=%d 4=%d 5=%d 6=%d 7=%d (正常应只有1..4有数)",
        cnt[0], cnt[1], cnt[2], cnt[3], cnt[4], cnt[5], cnt[6], cnt[7]);
}

// emivrfy: EMI 全表自检 (只读): 逐项复算原版 cat 并按 原1→3/原2→2/原3→1/原4→0
// 映射回 EMI 分类, 与 gItems category 逐项比对, 错位(或原版cat异常)落日志; 未注册 id 跳过
void MWBEMIVerifyCats(void) {
    if (![[NSFileManager defaultManager] fileExistsAtPath:@"/tmp/mwbcmd-emivrfy"]) return;
    [[NSFileManager defaultManager] removeItemAtPath:@"/tmp/mwbcmd-emivrfy" error:nil];
    void **reg = mwb_items_registry();
    if (!reg) { MWBDLog(@"[emivrfy] 注册表未解析"); return; }
    void **tiles = (void **)(MWBMainSlide() + MWB_ITEM_INFO_TABLE_VMADDR);
    static char buf[4096];
    int n = snprintf(buf, sizeof(buf), "[emivrfy] 错位(id:原cat/现cat):");
    int bad = 0, skip = 0;
    for (int k = 0; k < gItemCount && n > 0 && n < (int)sizeof(buf) - 24; k++) {
        int id = gItems[k].itemId;
        if (id < 0 || id >= 512 || !reg[id]) { skip++; continue; }
        void *t = (id < 256) ? tiles[id] : NULL;
        int cat = t ? *(int *)((char *)t + 0x8c) : *(int *)((char *)reg[id] + 0x58);
        int want = (cat == 1) ? 3 : (cat == 2) ? 2 : (cat == 3) ? 1 : (cat == 4) ? 0 : -1;
        if (want < 0 || want != gItems[k].category) {
            bad++;
            n += snprintf(buf + n, sizeof(buf) - n, " %d:%d/%d", id, cat, gItems[k].category);
        }
    }
    MWBDLog(@"%s", buf);
    MWBDLog(@"[emivrfy] 共%d项 错位%d 未注册跳过%d (错位0即与原版一致)", gItemCount, bad, skip);
}

#pragma mark - EMI 管理器

@implementation MWBEMIManager {
    MWBEMIWindow *_window;               // 物品浏览器 (现挂在悬浮窗根视图上)
    void (^_browserOnClose)(void);       // 浏览器关闭回调 (回退菜单到第 0 项)
}
+ (instancetype)shared {
    static MWBEMIManager *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[self alloc] init]; });
    return inst;
}
+ (void)install {
    dispatch_async(dispatch_get_main_queue(), ^{ [[self shared] preload]; });
}
// 合并进悬浮窗: 在悬浮窗宿主视图上显示 EMI 物品浏览器 (不再自建窗口/悬浮按钮)
+ (void)presentBrowserInView:(UIView *)hostView onClose:(void (^)(void))onClose {
    [[self shared] presentInView:hostView onClose:onClose];
}
+ (void)dismissBrowser { [[self shared] dismissBrowser]; }
// 调试用: cycript 调用 [MWBEMIManager scrollDebug:[NSNumber numberWithFloat:950]]
+ (void)scrollDebug:(NSNumber *)y {
    dispatch_async(dispatch_get_main_queue(), ^{
        for (UIWindow *w in [UIApplication sharedApplication].windows) {
            UIView *sv = [w viewWithTag:999];
            if ([sv isKindOfClass:[UIScrollView class]]) {
                [(UIScrollView *)sv setContentOffset:(CGPoint){0, y.floatValue} animated:NO];
            }
        }
    });
}
// 调试用: cycript 调用 [MWBEMIManager giveItem:264 count:1] 或 [MWBEMIManager giveItem:35 count:1 aux:3]
+ (BOOL)giveItem:(int)itemId count:(int)count {
    return MWBGiveItem(itemId, count, 0);
}
+ (BOOL)giveItem:(int)itemId count:(int)count aux:(int)aux {
    return MWBGiveItem(itemId, count, aux);
}
// 调试用: cycript 调用 [MWBEMIManager playerPointer]
+ (void *)playerPointer {
    return gLocalPlayer;
}
// 预加载: 纹理 + 给予 hook (不再自建窗口/悬浮按钮)
- (void)preload {
    CGSize ss = [UIScreen mainScreen].bounds.size;
    kEMIScale = MIN(ss.width/1920.0, ss.height/1080.0);
    // 预加载贴图
    [MWBTextureAtlas terrainAtlas];
    [MWBTextureAtlas itemsAtlas];
    // 安装物品给予 hook
    MWBInstallGiver();
    NSLog(@"[EMI] 物品管理器已就绪(已合并进悬浮窗), scale=%.3f, 物品数=%d", kEMIScale, gItemCount);
}
// 在悬浮窗宿主视图上显示物品浏览器 (覆盖在菜单之上)
- (void)presentInView:(UIView *)hostView onClose:(void (^)(void))onClose {
    if (!hostView || _window.superview) return;
    _browserOnClose = [onClose copy];
    _window = [[MWBEMIWindow alloc] initWithFrame:hostView.bounds];
    _window.autoresizingMask = UIViewAutoresizingFlexibleWidth|UIViewAutoresizingFlexibleHeight;
    __weak typeof(self) ws = self;
    _window.onClose = ^{ __strong typeof(ws) s = ws; if (!s) return; [s dismissBrowser]; };
    [_window showInView:hostView];
}
- (void)dismissBrowser {
    [_window hide];
    _window = nil;
    if (_browserOnClose) { void (^b)(void) = _browserOnClose; _browserOnClose = NULL; b(); }
}
@end
