/* EMIItems.mm — 物品数据 (110+定义表/变体/游戏配方读取) */
#import <Foundation/Foundation.h>
#import <substrate.h>
#import "EMI.h"

#pragma mark - 物品数据

// 物品定义

// 材质索引: 工具 0木 1石 2铁 3金 4钻石 (注意金在钻石前面!); 盔甲 0皮革 1锁链 2铁 3钻石 4金
#define B(nm,cn,id,tp,ti,tt,ti2,ft,fi2,st,si2,stk,cat) \
    {(cn), YES, (id), (tp), (ti), (tt), (ti2), (ft), (fi2), (st), (si2), (stk), (cat)}
#define I(nm,cn,id,tp,ti,stk,cat) \
    {(cn), NO, (id), (tp), (ti), NULL, 0, NULL, 0, NULL, 0, (stk), (cat)}

MWBItemDef gItems[] = {
    // ---- 建筑方块 (category 3) ----
    B(stone,       "石头",      1,  "stone",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(grass,       "草方块",    2,  "grass",0, "grass",0, "grass",1, "dirt",0, 64, 3),
    B(dirt,        "泥土",      3,  "dirt",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(cobble,      "圆石",      4,  "cobblestone",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(planks,      "橡木木板",  5,  "planks",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(sapling,     "橡树树苗",  6,  "sapling",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(bedrock,     "基岩",      7,  "bedrock",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(sand,        "沙子",      12, "sand",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(gravel,      "沙砾",      13, "gravel",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(gold_ore,    "金矿石",    14, "gold_ore",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(iron_ore,    "铁矿石",    15, "iron_ore",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(coal_ore,    "煤矿石",    16, "coal_ore",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(log,         "橡木原木",  17, "log",0, "log",4, "log",0, "log",0, 64, 3),
    B(leaves,      "橡树树叶",  18, "leaves",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(glass,       "玻璃",      20, "glass",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(lapis_ore,   "青金石矿石",21, "lapis_ore",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(lapis_block, "青金石块",  22, "lapis_block",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(sandstone,   "砂岩",      24, "sandstone",0, "sandstone",0, "sandstone",2, "sandstone",2, 64, 3),
    B(wool_white,  "白色羊毛",  35, "wool",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(gold_block,  "金块",      41, "gold_block",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(iron_block,  "铁块",      42, "iron_block",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(stone_slab,  "石台阶",    44, "stone_slab",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(brick,       "砖块",      45, "brick",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(tnt,         "TNT",       46, "tnt",0, "tnt",1, "tnt",0, "tnt",2, 64, 3),
    B(bookshelf,   "书架",      47, "bookshelf",0, "planks",0, "bookshelf",0, "planks",0, 64, 3),
    B(mossy,       "苔石",      48, "cobblestone_mossy",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(obsidian,    "黑曜石",    49, "obsidian",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(diamond_ore, "钻石矿石",  56, "diamond_ore",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(diamond_blk, "钻石块",    57, "diamond_block",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(crafting,    "工作台",    58, "crafting_table",0, "crafting_table",1, "crafting_table",0, "crafting_table",2, 64, 3),
    B(furnace,     "熔炉",      61, "furnace",0, "furnace",2, "furnace",0, "furnace",1, 64, 3),
    B(ice,         "冰",        79, "ice",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(snow,        "雪块",      80, "snow",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(clay,        "黏土块",    82, "clay",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(pumpkin,     "南瓜",      86, "pumpkin",0, "pumpkin",1, "pumpkin",0, "pumpkin",2, 64, 3),
    B(netherrack,  "地狱岩",    87, "netherrack",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(soul_sand,   "灵魂沙",    88, "soul_sand",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(glowstone,   "萤石",      89, "glowstone",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(stonebrick,  "石砖",      98, "stonebrick",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(iron_bars,   "铁栏杆",    101,"iron_bars",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(glass_pane,  "玻璃板",    102,"glass_pane_top",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(melon,       "西瓜",      103,"melon",0, "melon",0, "melon",1, "melon",1, 64, 3),
    B(mycelium,    "菌丝",      110,"mycelium",0, "mycelium",1, "mycelium",0, "dirt",0, 64, 3),
    B(end_stone,   "末地石",    121,"end_stone",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(redstone_ore,"红石矿石",  73, "redstone_ore",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(redstone_blk,"红石块",    152,"redstone_block",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(quartz_blk,  "石英块",    155,"quartz_block",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(hay,         "干草块",    170,"hayblock",0, "hayblock",0, "hayblock",1, "hayblock",1, 64, 3),
    B(hardened_clay,"硬化黏土", 172,"hardened_clay",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(coal_block,  "煤炭块",    173,"coal_block",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(emerald_ore, "绿宝石矿石",129,"emerald_ore",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(emerald_blk, "绿宝石块",  133,"emerald_block",0, NULL,0, NULL,0, NULL,0, 64, 3),
    B(sponge,      "海绵",      19, "sponge",0, NULL,0, NULL,0, NULL,0, 64, 3),

    // ---- 装备/工具 (category 1) ----
    I(sword_w,  "木剑",   268, "sword",0, 1, 1),
    I(sword_s,  "石剑",   272, "sword",1, 1, 1),
    I(sword_i,  "铁剑",   267, "sword",2, 1, 1),
    I(sword_d,  "钻石剑", 276, "sword",4, 1, 1),
    I(sword_g,  "金剑",   283, "sword",3, 1, 1),
    I(pick_w,   "木镐",   270, "pickaxe",0, 1, 1),
    I(pick_s,   "石镐",   274, "pickaxe",1, 1, 1),
    I(pick_i,   "铁镐",   257, "pickaxe",2, 1, 1),
    I(pick_d,   "钻石镐", 278, "pickaxe",4, 1, 1),
    I(pick_g,   "金镐",   285, "pickaxe",3, 1, 1),
    I(axe_w,    "木斧",   271, "axe",0, 1, 1),
    I(axe_s,    "石斧",   275, "axe",1, 1, 1),
    I(axe_i,    "铁斧",   258, "axe",2, 1, 1),
    I(axe_d,    "钻石斧", 279, "axe",4, 1, 1),
    I(shovel_w, "木铲",   269, "shovel",0, 1, 1),
    I(shovel_s, "石铲",   273, "shovel",1, 1, 1),
    I(shovel_i, "铁铲",   256, "shovel",2, 1, 1),
    I(shovel_d, "钻石铲", 277, "shovel",4, 1, 1),
    I(shovel_g, "金铲",   284, "shovel",3, 1, 1),
    I(bow,      "弓",     261, "bow_standby",0, 1, 1),
    I(arrow,    "箭",     262, "arrow",0, 64, 1),
    I(helmet_i, "铁头盔", 306, "helmet",2, 1, 1),
    I(chest_i,  "铁胸甲", 307, "chestplate",2, 1, 1),
    I(legs_i,   "铁护腿", 308, "leggings",2, 1, 1),
    I(boots_i,  "铁靴子", 309, "boots",2, 1, 1),
    I(helmet_d, "钻石头盔",310,"helmet",3, 1, 1),
    I(chest_d,  "钻石胸甲",311,"chestplate",3, 1, 1),
    I(legs_d,   "钻石护腿",312,"leggings",3, 1, 1),
    I(boots_d,  "钻石靴子",313,"boots",3, 1, 1),
    I(flint,    "打火石", 259, "flint_and_steel",0, 1, 1),
    I(shears,   "剪刀",   359, "shears",0, 1, 1),
    I(fishrod,  "钓鱼竿", 346, "fishing_rod_uncast",0, 1, 1),

    // ---- 材料/物品 (category 0) ----
    I(stick,        "木棍",       280, "stick",0, 64, 0),
    I(coal,         "煤炭",       263, "coal",0, 64, 0),
    I(charcoal,     "木炭",       263, "charcoal",0, 64, 0),
    I(diamond,      "钻石",       264, "diamond",0, 64, 0),
    I(iron_ingot,   "铁锭",       265, "iron_ingot",0, 64, 0),
    I(gold_ingot,   "金锭",       266, "gold_ingot",0, 64, 0),
    I(emerald,      "绿宝石",     388, "emerald",0, 64, 0),
    I(redstone,     "红石粉",     331, "redstone_dust",0, 64, 0),
    I(clay_ball,    "黏土球",     337, "clay_ball",0, 64, 0),
    I(brick_item,   "红砖",       336, "brick",0, 64, 0),
    I(flint_item,   "燧石",       318, "flint",0, 64, 0),
    I(string,       "线",         287, "string",0, 64, 0),
    I(leather,      "皮革",       334, "leather",0, 64, 0),
    I(feather,      "羽毛",       288, "feather",0, 64, 0),
    I(bone,         "骨头",       352, "bone",0, 64, 0),
    I(slimeball,    "黏液球",     341, "slimeball",0, 64, 0),
    I(egg,          "鸡蛋",       344, "egg",0, 16, 0),
    I(snowball,     "雪球",       332, "snowball",0, 16, 0),
    I(gunpowder,    "火药",       289, "gunpowder",0, 64, 0),
    I(glowdust,     "萤石粉",     348, "glowstone_dust",0, 64, 0),
    I(blaze_rod,    "烈焰棒",     369, "blaze_rod",0, 64, 0),
    I(blaze_powder, "烈焰粉",     377, "blaze_powder",0, 64, 0),
    I(ender_pearl,  "末影珍珠",   368, "ender_pearl",0, 16, 0),
    I(ender_eye,    "末影之眼",   381, "ender_eye",0, 64, 0),
    I(magma_cream,  "岩浆膏",     378, "magma_cream",0, 64, 0),
    I(ghast_tear,   "恶魂之泪",   370, "ghast_tear",0, 64, 0),
    I(sugar,        "糖",         353, "sugar",0, 64, 0),
    I(wheat,        "小麦",       296, "wheat",0, 64, 0),
    I(seeds,        "小麦种子",   295, "seeds_wheat",0, 64, 0),
    I(apple,        "苹果",       260, "apple",0, 64, 0),
    I(gold_apple,   "金苹果",     322, "apple_golden",0, 64, 0),
    I(bread,        "面包",       297, "bread",0, 64, 0),
    I(cookie,       "饼干",       357, "cookie",0, 64, 0),
    I(cake,         "蛋糕",       354, "cake",0, 1, 0),
    I(melon_item,   "西瓜片",     360, "melon",0, 64, 0),
    I(carrot,       "胡萝卜",     391, "carrot",0, 64, 0),
    I(potato,       "马铃薯",     392, "potato",0, 64, 0),
    I(baked_potato, "烤马铃薯",   393, "potato_baked",0, 64, 0),
    I(beef_raw,     "生牛肉",     363, "beef_raw",0, 64, 0),
    I(beef_cooked,  "牛排",       364, "beef_cooked",0, 64, 0),
    I(pork_raw,     "生猪排",     319, "porkchop_raw",0, 64, 0),
    I(pork_cooked,  "熟猪排",     320, "porkchop_cooked",0, 64, 0),
    I(chicken_raw,  "生鸡肉",     365, "chicken_raw",0, 64, 0),
    I(chicken_ckd,  "熟鸡肉",     366, "chicken_cooked",0, 64, 0),
    I(bucket,       "桶",         325, "bucket",0, 1, 0),
    I(bucket_water, "水桶",       326, "bucket",1, 1, 0),
    I(bucket_lava,  "熔岩桶",     327, "bucket",2, 1, 0),
    I(book,         "书",         340, "book_normal",0, 64, 0),
    I(paper,        "纸",         339, "paper",0, 64, 0),
    I(map,          "地图",       358, "map_empty",0, 64, 0),
    I(compass,      "指南针",     345, "compass_item",0, 64, 0),
    I(clock,        "钟",         347, "clock_item",0, 64, 0),
    I(bowl,         "碗",         281, "bowl",0, 64, 0),
    I(mushroom_stew,"蘑菇煲",     282, "mushroom_stew",0, 1, 0),
    I(saddle,       "鞍",         329, "saddle",0, 1, 0),
    I(boat,         "船",         333, "boat",0, 1, 0),
    I(minecart,     "矿车",       342, "minecart_normal",0, 1, 0),
    I(bed,          "床",         355, "bed",0, 1, 0),
    I(reeds,        "甘蔗",       338, "reeds",0, 64, 0),
    I(rotten_flesh, "腐肉",       367, "rotten_flesh",0, 64, 0),
    I(spider_eye,   "蜘蛛眼",     375, "spider_eye",0, 64, 0),
    I(bottle,       "玻璃瓶",     374, "potion_bottle_empty",0, 64, 0),
    I(potion,       "药水",       373, "potion_bottle_drinkable",0, 1, 0),
    I(skull,        "骷髅头颅",   397, "skull_skeleton",0, 64, 0),
    I(book_ench,    "附魔书",     403, "book_enchanted",0, 1, 0),
};
int gItemCount = sizeof(gItems) / sizeof(gItems[0]);

// 按 ID 找物品定义
const MWBItemDef *MWBItemDefForId(int itemId) {
    for (int i = 0; i < gItemCount; i++)
        if (gItems[i].itemId == itemId) return &gItems[i];
    return NULL;
}
NSString *MWBItemName(int itemId) {
    const MWBItemDef *d = MWBItemDefForId(itemId);
    return d ? [NSString stringWithUTF8String:d->cnName] : [NSString stringWithFormat:@"ID %d", itemId];
}

#pragma mark - 变体物品 (aux 决定变种, 单击弹窗选择)

// 返回该物品的变种数 (0 = 无变体, 单击直接给予)
int MWBVariantCount(int itemId) {
    switch (itemId) {
        case 35:  return 16;   // 羊毛 16 色
        case 351: return 16;   // 染料 16 色
        case 17:  return 3;    // 原木
        case 5:   return 6;    // 木板
        case 44:  return 4;    // 石台阶
        case 24:  return 4;    // 砂岩
        case 263: return 2;    // 煤炭/木炭
        default:  return 0;
    }
}

// 变种名 (羊毛与染料的 aux 色序不同)
NSString *MWBVariantName(int itemId, int aux) {
    static const char *wool[16] = {"白","橙","品红","淡蓝","黄","黄绿","粉","灰","浅灰","青","紫","蓝","棕","绿","红","黑"};
    static const char *dye[16]  = {"墨囊","玫瑰红","仙人掌绿","可可豆","天蓝","紫","青","银灰","灰","粉红","黄绿","黄","淡蓝","品红","橙","骨粉"};
    if (itemId == 35) return [NSString stringWithFormat:@"羊毛·%s", wool[aux % 16]];
    if (itemId == 351) return [NSString stringWithFormat:@"染料·%s", dye[aux % 16]];
    if (itemId == 263) return aux == 1 ? @"木炭" : @"煤炭";
    if (itemId == 17) return aux == 0 ? @"橡木" : (aux == 1 ? @"云杉" : @"桦木");
    return [NSString stringWithFormat:@"变种 %d", aux];
}

#pragma mark - 游戏配方读取 (长按查看, 数据来自游戏 Recipes 单例)

// Recipes 单例指针的静态地址 (SurvivalInventoryScreen::updateCraftableItems 反汇编核实:
// 为空时 new 0x18 字节并调 Recipes 构造函数注册全部配方, 我们做同样的懒加载)
#define MWB_RECIPES_PTR_VMADDR 0x10034d0c0UL

// Recipe 对象布局 (addShapedRecipe / ItemPack::add 反汇编核实):
//   +0x08 材料包 ItemPack (头节点指针在 +0x10; 节点键值是 Item+0x30 的值, 不等于物品 id,
//         不能用来反查名字 — 已弃用, 材料改走虚表读取)
//   +0x30/+0x38 产物 vector<ItemInstance> (元素 0x20 字节: count@0x00, aux@0x04, Item*@0x08)
//   虚表 +0x40 = getIngredient(col, row, flag): 按格子返回材料 ItemInstance*
//   总大小 0x48

// 确保游戏配方表已初始化 (镜像游戏的懒加载逻辑)
static void **mwb_recipes_singleton(void) {
    void **slot = (void **)(MWBMainSlide() + MWB_RECIPES_PTR_VMADDR);
    if (!*slot) {
        void *(*recipesCtor)(void *) = (void *(*)(void *))MSFindSymbol(NULL, "__ZN7RecipesC2Ev");
        if (!recipesCtor) { MWBDLog(@"[EMI] 未找到 Recipes 构造符号"); return NULL; }
        void *obj = calloc(1, 0x18);
        if (!obj) return NULL;
        recipesCtor(obj);
        *slot = obj;
        MWBDLog(@"[EMI] 已按游戏方式懒加载配方表");
    }
    return (void **)*slot;
}

// 反查注册表: Item* -> 物品 ID
static int MWBIdOfItem(void *item) {
    void **reg = mwb_items_registry();
    if (!reg || !item) return -1;
    for (int i = 0; i < 512; i++)
        if (reg[i] == item) return i;
    return -1;
}

// 遍历游戏配方, 返回产物为 itemId 的所有配方
// 返回 @[ 每条配方@[9格id数组(0=空, 按行排列), 产物数量], ... ]
NSArray *MWBGameRecipesForItem(int itemId) {
    void **recipes = mwb_recipes_singleton();
    if (!recipes) return nil;
    void **begin = (void **)recipes[0], **end = (void **)recipes[1];
    if (!begin || end <= begin) { MWBDLog(@"[EMI] 游戏配方表为空"); return nil; }
    MWBDLog(@"[EMI] 游戏配方总数 %ld, 查找产物 id=%d", (long)(end - begin), itemId);
    void **reg = mwb_items_registry();
    void *want = reg ? reg[itemId] : NULL;
    if (!want) return nil;

    NSMutableArray *out = [NSMutableArray new];
    int dumped = 0;
    for (void **p = begin; p != end; p++) {
        char *r = (char *)*p;
        if (!r) continue;

        // 产物: vector<ItemInstance> @ +0x30 (元素内联, 首元素地址就是向量起点)
        // 元素 0x20 字节: count@0x00, aux@0x04, Item*@0x08
        char *res = *(char **)(r + 0x30);
        void **rve = *(void ***)(r + 0x38);
        if (!res || (char **)rve <= (char **)res) continue;
        void *rItem = *(void **)(res + 8);
        if (rItem != want) continue;
        int rcount = *(int *)res;
        int raux = *(int *)(res + 4);
        if (rcount <= 0 || rcount > 64) continue;

        // 诊断 (只打前 3 条命中配方)
        if (dumped < 3) {
            MWBDLog(@"[EMI配方命中] r=%p 产物数=%d 产物aux=%d", r, rcount, raux);
            dumped++;
        }

        // 材料: Recipe 虚表 +0x40 = getIngredient(col, row, flag), 按格子返回材料实例
        // (游戏 SurvivalInventoryScreen::updateIngredientCountFromRecipe 就这么读)
        // 注意: 合成格每格永远只放 1 个, 数量=格子数, 格子实例里的 count 字段不可信
        void **vtable = *(void ***)r;
        typedef void *(*GetCellFn)(void *, int, int, BOOL);
        GetCellFn getCell = (GetCellFn)vtable[0x40 / 8];
        if (!getCell) continue;
        NSMutableArray *cells = [NSMutableArray new];
        BOOL any = NO;
        for (int rowI = 0; rowI < 3; rowI++) {
            for (int colI = 0; colI < 3; colI++) {
                int cid = 0;
                void *cell = getCell(r, colI, rowI, NO);
                if (cell) {
                    void *it = *(void **)((char *)cell + 8);
                    if (it && *(int *)cell > 0) {
                        cid = MWBIdOfItem(it);
                        if (cid > 0) any = YES; else cid = 0;
                    }
                }
                [cells addObject:@(cid)];
            }
        }
        if (!any) continue;
        [out addObject:@[cells, @(rcount)]];
    }
    return out;
}
