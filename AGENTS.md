# AGENTS.md — 魔玩我的世界盒子 (mowanbox)

本文件是本仓库对 AI agent 的项目级指导，任何在本仓库工作的 agent 都应先读完本文件再动手。

## 项目简介

- **中文名**：魔玩我的世界盒子
- **英文名**：mowanbox
- **目标**：在已越狱的 iPad mini 2 上，为 Minecraft PE（国际版）注入一个游戏内修改器悬浮窗，功能形态参考 Minecraft PE Toolbox（见图 `docs/toolbox-reference.png`）：左侧 TMI 菜单（Add Item / Add Mobs / Teleport 等）、右侧开关面板（Day/Night、Survival/Creative、Invincible、Super Jump、Item Multiplier、Block Breaker 等）。
- **当前阶段**：
  - Toolbox 菜单 UI 骨架已完成（悬浮按钮可拖动、左右两栏面板、关闭按钮、触摸透传正常）。
  - EMI 物品管理器 UI 骨架已完成：独立 E 悬浮按钮、创造物品栏风格窗口（分类栏/10列网格/快捷栏）、等距立方体用游戏真实 terrain-atlas.tga 贴图渲染、物品用 items-opaque.png 渲染、110+ 物品定义、分类切换。
  - 2026-08-28：修复进世界闪退（hook 短函数 getBaseSpeed 踩坏相邻函数，见"已验证的坑"），加速奔跑改用 vm_protect 改写速度常量实现。
  - 2026-08-28：物品给予功能重写并核实 ItemInstance 真实布局（count@0/aux@4/Item*@8/info@0x10/valid@0x18，无独立 id 字段），修复"给 id 个物品/工具耐久 1/给的钻石不能合成"三连 bug。
  - 2026-08-28：长按查看合成改读游戏内 Recipes 单例（239 条配方，懒加载），不再手写配方表；多变体物品（羊毛/染料/原木/木板/台阶/砂岩/煤炭）单击弹出变体选择面板。
  - **待真机验证**：长按配方的材料显示、工具图标金/钻石互换修正、变体面板交互。

## Git 约定

- **每次操作完（构建/部署/逆向结论落盘/功能完成）都要 git 提交并推送 GitHub**（`git commit` + `git push origin main`），保持远程与本地同步。

## 目标设备与连接

- **设备**：iPad mini 2（型号标识符 `iPad4,4`，代号 J85AP），arm64（S5L8960X / A7）
- **系统**：iOS 12.5.8（Build 16G88），Darwin Kernel 18.7.0
- **越狱环境**：Cydia Substrate 已安装（`com.saurik.substrate.safemode` 0.9.6005）
- **SSH 连接**：
  - 地址：`root@192.168.1.81`（局域网 WiFi，非 USB）
  - 密码：`alpine`
  - 连接命令：`sshpass -p alpine ssh -o StrictHostKeyChecking=accept-new root@192.168.1.81`
  - 主机名：`ipados12hounoboru`
- **USB**：设备已通过 USB 识别到 Mac（Product ID `0x12ab`，Vendor `0x05ac`），但当前未安装 `libimobiledevice`（`idevice_id`/`ideviceinfo` 不可用），设备交互走 SSH。

## 设备上已有的 Minecraft 安装（只读盘点，勿删）

以下容器均位于 `/var/containers/Bundle/Application/`，**禁止删除或覆盖**：

| 版本 | Bundle ID | 最低 iOS | 容器 UUID（前缀） |
|---|---|---|---|
| 0.10.0 | `moe.bemly.mcpe.0.10` | 5.1.1 | C26BCC77 |
| 1.1.7 | `moe.bemly.mcpe.1.1` | 8.0 | 275DD938 |
| 1.4.3 | `moe.bemly.mcpe.1.4` | 9.0 | E900D99F |
| 1.13.3 | `moe.bemly.mcpe.1.13` | 10.0 | EC21AB78 |
| 1.16.50 | `com.mojang.minecraftpe`（官方包名） | 12.2 | 7757E7BE |
| 1.20.62 | `moe.bemly.mcpe.1.20` | 11.0 | 8387E65B |
| 3.7.30 | `com.netease.mc`（网易中国版） | 12.2 | A5ED18C6 |

已安装的 MC 相关 tweak（位于 `/Library/MobileSubstrate/DynamicLibraries/`）：
- `MCPE.dylib` / `MCPE.plist`（含 freecam、minidebug 等，来自 `com.darkshuper.*`）
- `MinecraftSettings.dylib` / `MinecraftSettings.plist`（`com.kushy.minecraftsettings` 4.2）

后续注入方案需考虑与已有 tweak 的共存/冲突，避免覆盖 `MCPE.plist` 的 Filter 配置。

## 安全红线（必须遵守）

1. **不得删除或清空平板上的任何用户数据**：包括但不限于 MC 存档、`games/com.mojang` 目录、应用容器、钥匙串、照片、其他 app 数据。没有用户明确逐条授权，不执行 `rm -rf`、`dd`、覆盖写、卸载等破坏性操作。
2. **仅针对本地离线单机世界**：本项目只用于玩家自己的本地单机存档修改（天气、飞行、生存/创造切换、无敌、高跳等）。**不针对联网多人服务器、Realms、网易版联机**，不开发绕过反作弊、联机作弊、内购破解相关功能。
3. **不碰网易版 `com.netease.mc`**：该版本有联网组件与反作弊风险，本项目注入目标限定为国际版离线 MC。
4. **部署前先备份**：向平板写入任何 dylib/plist 前，先在设备上备份原文件（如 `cp xxx xxx.bak`），并在本仓库记录变更。
5. **最小权限操作**：SSH 操作优先只读探查；写入操作限定在 `/Library/MobileSubstrate/` 下本项目自己的 bundle id，不修改系统文件。
6. **不收录任何侵权素材**：仓库内不放入 Minecraft 原版资源、受版权保护的材质/音效/二进制；逆向分析笔记以文字描述为主，不提交 IPA 或解密二进制。

## 开发约定

- **目标 MC 版本**：0.10.0（bundle id `moe.bemly.mcpe.0.10`，容器 C26BCC77）。其他版本后续再适配。
- **技术路线**：Cydia Substrate Tweak（Logos `.xm`），Theos 构建，打包为 Sileo/Cydia 可安装的 `.deb`。目标架构 `arm64`，部署目标 iOS 12.0。
- **构建环境（Mac）**：
  - Theos 安装在 `~/theos`（编译前 `export THEOS=~/theos && export PATH="$THEOS/bin:$PATH"`）。
  - Xcode 15.2 + iPhoneOS 17.2 SDK（Theos 自动通过 `xcrun` 找到，无需手动放 SDK）。
  - 签名用 macOS 自带 `codesign -s - --force`（ad-hoc），不依赖 ldid；Makefile 里设 `TARGET_CODESIGN`。
  - 打包用 Theos 自带的 `dm.pl`（纯 Perl），不依赖系统 dpkg-deb。`make package` 即可产出 deb。
- **关键文件**：
  - `Tweak.xm`：插件源码（Logos + ObjC）。
  - `Makefile`：Theos 构建配置。
  - `control`：deb 包元数据（Sileo 显示用）。
  - `mowanbox.plist`：Substrate Filter，决定注入哪个进程。
- **已验证的坑（务必遵守）**：
  1. **plist 必须用 NeXTSTEP 数组格式**：`{ Filter = { Bundles = ( "moe.bemly.mcpe.0.10" ); }; }`。XML 字典 + `<true/>` 布尔值格式 Substrate 不识别，会导致 dylib 不注入。文件权限必须 `644`（root:wheel），否则 mobile 用户读不到。
  2. **触摸透传必须在 UIWindow 层重写 hitTest**：仅在 rootViewController.view 上重写 hitTest 返回 nil 不够，UIWindow 自身的 hitTest 会在子视图返回 nil 后回退返回 window 自身吞掉事件。必须子类化 UIWindow，命中空白时返回 nil。
  3. 面板打开时要 `bringSubviewToFront:` 悬浮按钮，否则左栏面板会盖住按钮导致无法关闭；右栏顶部已加 ✕ 关闭按钮。
  4. **12 字节短函数不能用 MSHookFunction**（2026-08-28 闪退根因）：Substrate 的 arm64 跳板要 16 字节，hook `Player::getBaseSpeed`（仅 adrp+ldr+ret）会踩坏紧随其后的 `Player::getEntityTypeId`，一进世界首次移动即 `EXC_BAD_INSTRUCTION`。判断标准：符号表中该符号地址到下一个符号地址不足 16 字节就不能 hook。加速奔跑的替代实现：`getBaseSpeed` 只是返回 `__TEXT,__const` 里的全局 float 0.1f（静态地址 `0x1002ab79c`，全二进制仅此一处引用），用 `vm_protect(VM_PROT_COPY)` 改写该常量即可（见 Tweak.xm `MWBApplySpeed`）。
  5. **ItemInstance 的 valid 标志在 0x18，且 count 在 0x00 / id 在 0x04**：`FillingContainer::add` 反汇编确认读 `[item+0x18]` 判有效；count/id 位置写反的症状是"给 id 个物品"（点绿宝石块 id=133 给出 133 个），因为游戏把 +0x00 当数量、种类由 Item* 决定。结构体必须显式 padding 到 0x18（见 EMI.mm `MWBItemInstance`）。
  6. **合成 UI 的触摸不能用合成 UIEvent 走 `UIApplication sendEvent:`**（会 SIGSEGV 崩游戏）。游戏触摸入口是 `minecraftpeViewController` 的 `touchesBegan/Moved/Ended:withEvent:`，它只读 `touches` 集合参数、完全不用 event；要自动化点击可直接对它调 `touchesBegan:`（cycript 可做），但日常验证以用户手动点击为准。
  7. **游戏配方表是懒加载的**：`Recipes` 单例指针在静态地址 `0x10034d0c0`，游戏首次打开背包界面（`SurvivalInventoryScreen::updateCraftableItems`）才创建；插件要读配方需按同样方式懒加载（new 0x18 + 调 `__ZN7RecipesC2Ev`）。Recipe 布局（总 0x48）：+0x08 材料包 ItemPack（头节点指针在 +0x10，节点 `{next@0, id@0x1c, count@0x20}`，已按 id 合并），+0x30/+0x38 产物 `vector<ItemInstance>`（元素 0x20：count@0/id@4/Item*@8）。

## MCPE 0.10.0 逆向符号速查（已核实，可直接 MSFindSymbol）

| 用途 | 符号 / 地址（静态） | 说明 |
|---|---|---|
| 玩家指针 | hook `__ZN11LocalPlayer10normalTickEv` @ 0x17e9ec | Tweak.xm 维护 gLocalPlayer |
| 物品注册表 | `__ZN4Item5itemsE` @ 0x100346dc8 | `Item* items[512]` 静态数组，方块/物品都在里面；**旧的 0x10034cd00 是错的（实为 `__MergedGlobals` 常量池）** |
| 给予物品 | `__ZN9Inventory3addEP12ItemInstance` @ 0x10010dd08 | 直接调用；内部转调 `FillingContainer::add` @ 0x1000ae754；**vtable+0x148 不是 add** |
| 配方系统 | 单例指针 @ 0x10034d0c0；构造 `__ZN7RecipesC2Ev` @ 0x1001957a0 | 见"已验证的坑"第 7 条；配方总数实测 239 条 |
| 物品栏指针 | Player+0x1708 | `Inventory*` |
| 加速奔跑 | 速度常量 @ 0x1002ab79c | `__TEXT,__const` float 0.1f，vm_protect 改写 |
| 能力字段 | Player+5824 | [0]无敌 [1]飞行 [2]可飞 [3]瞬挖 |
| 时间字段 | Level+5512 | int64，白天 1000 / 夜晚 13000 |
| 速度 Y | Entity+112 | float，跳跃初速 0.42 |
- **UI 文字、代码注释、NSLog 一律用中文**。
- **API 基线：iOS 12.0，不向下兼容 iOS 8/9/10/11**。所有代码直接使用 iOS 12 可用的现代 API，不写 `@available`/`respondsToSelector:` 版本判断，不使用 iOS 13+ 才有的 API。具体规范：
  - 几何结构体用 C99 复合字面量：`(CGRect){{x,y},{w,h}}`、`(CGSize){w,h}`、`(CGPoint){x,y}`，不用 `CGRectMake`/`CGSizeMake`/`CGPointMake`。
  - 文件操作用 URL-based API：`URLForResource:withExtension:`、`dataWithContentsOfURL:options:error:`、`writeToURL:atomically:encoding:error:`、`fileHandleForWritingToURL:error:`，不用 path-based 的 `pathForResource:`、`dataWithContentsOfFile:`、`writeToFile:`、`fileHandleForWritingAtPath:`。文件路径用 `NSURL fileURLWithPath:` 转换。
  - 集合用现代写法：`@[]`/`@{}` 字面量、下标 `arr[i]`/`dict[key]`、`[NSMutableArray new]`/`[NSMutableDictionary new]`，不用 `arrayWithObjects:`/`dictionaryWithObjectsAndKeys:`/`objectAtIndex:`/`objectForKey:`。
  - 动画用 block-based `animateWithDuration:animations:completion:`，不用 `beginAnimations`/`commitAnimations`。
  - 通知用 block-based `addObserverForName:object:queue:usingBlock:`。
  - 定时器用 `NSTimer scheduledTimerWithTimeInterval:repeats:block:`（iOS 10+）。
  - 图形绘制优先 CALayer/UIBezierPath/CGContext 直接绘制（性能最佳）；离屏渲染用 `UIGraphicsImageRenderer`（iOS 10+），不用 `UIGraphicsBeginImageContext`。
  - 错误处理用 `NSError **` 参数并检查，不盲目传 `nil`。
  - `NSAttributedString` 属性用 `NSFontAttributeName` 等常量（iOS 12 上为 NSString* 类型，正确）。
  - 不用废弃 API：`UIWebView`、`NSURLConnection`、`AssetsLibrary`、`ABAddressBook`、`UILocalNotification`、`sizeWithFont:`、`applicationFrame` 等。
- 功能实现阶段：MCPE 0.10.0 是 C++ 二进制，游戏内函数多为 strip 状态，需在设备上用 `nm`/`strings`/class-dump（或 IDA/Ghidra 静态分析）定位时间、模式、生命值、移动速度等相关符号后再 hook。所有功能 hook 必须加空指针/版本判断，避免崩溃。
- 所有设备操作命令、路径、版本信息以本文件记录为准；若设备状态变化（重装/升级 MC），需同步更新本文件。

## 构建与部署命令

```bash
# 环境变量（每个新终端都要执行）
export THEOS=~/theos
export PATH="$THEOS/bin:$PATH"

# 编译
make

# 打包 deb（产物在 packages/ 目录）
make package

# 安装到设备（通过 SSH dpkg）
sshpass -p alpine scp packages/*.deb root@192.168.1.81:/tmp/mowanbox.deb
sshpass -p alpine ssh root@192.168.1.81 'dpkg -i /tmp/mowanbox.deb'

# 重启 MC 0.10.0 使插件生效
sshpass -p alpine ssh root@192.168.1.81 'killall minecraftpe 2>/dev/null; uiopen moe.bemly.mcpe.0.10'

# 截图（Activator）
sshpass -p alpine ssh root@192.168.1.81 'activator send libactivator.system.take-screenshot'
```
