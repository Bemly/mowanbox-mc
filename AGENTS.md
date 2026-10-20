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
  - 2026-10-19：六替身包已逆向（`MCPE替身 1.4.3.ipa`实为1.13.3同体包，真1.4.3为`Minecraft_1.4.3_Steve.ipa`，已按替身规范重制覆盖）；新增`MWBVersion`运行时识别版本（版本号>二进制大小兜底），Filter覆盖6个bundle，同一UI。
  - 2026-10-19 真机验证（插件`2026.8.27-1+debug`，Filter 6包）：0.10 ✅双hook成功+悬浮窗正常；1.1.7 ✅注入无崩+悬浮窗正常（注：早前killall+uiopen连崩两次含一次裸跑，手动点图标可进，自动拉起路径待查）；1.4.3 ✅注入无崩+悬浮窗正常；1.13.3 ✅同上；1.20.62 ✅同上（仅UI，ECS暂不hook）；1.2.15未安装未验。
  - 2026-10-19 0.10进世界全功能实测 ✅（cycript直调`[MWBTouchHelper tapGameAtX:y]`进My World生存档）：无敌/速破 `abil=[1,0,1,1]` 落盘；`giveItem:264` 背包回读+快捷栏5钻石可见；时间切白天世界变亮。新增`tapGameAtX:y`（直调游戏VC touchesBegan/Ended，合规不崩；cycript调不了CGPointMake，改走编译侧）。
  - 2026-10-19 全版本进世界实测 ✅（同一插件`2026.8.27-2+debug`，cycript直调进档，均无崩、TOOLBOX+E悬浮窗全在）：1.1.7 ✅进My World复活存活；1.4.3 ✅进My World复活存活（蜘蛛杀过一次）；1.13.3 ✅进My World复活存活；1.20.62 ✅过不支持设备弹窗+存档升级弹窗进樱花林世界（仅UI）；0.10为唯一全功能版，其余高版本hook待接。
  - 2026-10-19 六路子agent逆向+全版本功能合入（插件`2026.8.27-10+debug`）：0.10无附魔系统（附魔台0.12才进PE，做不到；另得setIsCreativeMode@0x1000ce840与hurt头abil[0]实锤）；1.1.7 Abilities API直调（Player+0x1258/setBool/setFloat，tick@0x100439DE0实锤流动，inv回读=1粘住，dayTime锁13000，但开着无敌死过一次、天空停留日落疑客户端/服务端两套时间，未全实锤）；1.4.3 getter拦截模型（getBool/canFly/getFloat/tickTime，进世界流动，深夜+满血骷髅 adjacent ✅）；1.13.3能力表纠正（Base+12+i*12，invulnerable=Player+2480单写，fly/mayfly/instabuild/walkSpeed/flySpeed全接，时间双实锤）；1.2.15合入未验（本机无安装：Actor+0x24E无敌、能力表BSS步长0x18、Level+0xF8→+0x12C）；1.20.62 tick@0x105D03F74装上无崩但进世界25秒+跳跃3次均不触发（打偏，下一轮换备选0x101F5CD20，abilities待运行时探测）。附魔255：仅1.1.7有路（0x100AE6028绕上限检查，未调），其余版本待真机跟。
  - 2026-10-19 Toolbox最新版(5.4.58)功能单扒全+1.13.3先锋版开接（插件`2026.8.27-13+debug`）：新增穿墙/夜视开关与晴/雨/雷按钮；天气走Level wrapper@0x101FB32F4（裸写setter只改数不下雨，wrapper带广播才下，日志rain=1.00+雨丝画面双实锤 ✅）；药水getById(1/8/16)全返回有效指针（应用待构造EffectInstance）；穿墙已写未验。
  - 2026-10-20 八路agent全开+真机马拉松（插件`2026.8.27-34+debug`，c0bbe0a之后未推，待推）：
    - 1.1.7 ✅无敌：子agent证hurt读Abilities map，改hook getBool单点拦截（28B安全），47k次hurt调用后满血 ✅；夜晚常量改18000（13000本来就是日落）；给予链全通但count/id难定界（实例dump：空手持+4也是1，泥土模板缺，钻石Item*背包扫不到，封存）；附魔255后端已合入未验。
    - 1.4.3 ✅无敌（getBool拦截，夜雨2小时满血 ✅）；✅天气（LevelData+0x15C/160/164/168裸写即下雨，无需广播）；✅药水（effect143-16夜视图标亮）；给予/附魔/传送后端已合入（give跑通无崩但钻石不可见，count问题同1.1.7）。
    - 1.13.3：时间/天气双✅；getPos槽+0x60 ✅（读数684.5,68.6与+0x41C一致，三pos之争终结：+0x41C是pos）；teleportTo槽+0x88调用无崩（位移待视觉确认）；KillAura实体遍历 ✅（Level+0x58，虚表探测到1实体）；药水instance构造 ✅（id/duration/show全落位）但addEffect槽+0x5F8调完无效果（槽错）；GetAttr直调因string ABI崩（-27 ips为证，已禁用）；WorldEdit：getBlock ✅（高空回air正确）、setBlock两崩（石头槽纠正base+0x38仍抛C++异常，停用待第三轮推导）；无敌单写阵亡（需hurt拦截，VA待找）。
    - 1.20.62：tick换ECS system body@0x101F5CD20+wrapper@0x101F5D8B4+abilWrite三hook装上无崩；进世界卡Bedrock弹窗（不支持设备/ControlMode SELECT点不上，MTKView识别+全VC广播已修，SELECT仍需手动点一次）。
    - 基础设施：flag文件通道（/tmp/mwbcmd-*，touch+chown mobile，tick内poll+tick后异步泻洪）；tick内同步调容器函数必死锁（-19冻屏，0 CPU）；栈ItemInstance被容器引用变野指针（堆分配）；cycript每进程约2次调用后wedge、脚本内sleep无用（时序走shell）；killall必须用SIGTERM（-9会在存档时杀坏世界，1.1.7世界丢过两次）。
  - 待办：1.13.3 hurt拦截VA、setBlock第三轮推导、附魔/给予count定界、1.20手动过SELECT后验sysBody、小地图/矿物/光环UI、1.2.15（无安装）。
   - 2026-10-20(晚) 0.10.0 二进制(arm64, 从 `MCPE替身 0.10.max.ipa` 解出 `minecraftpe-arm64`)用 REA+IDA 复核：
     - 符号表齐全(8000+函数, 未strip), AGENTS.md 全部核心符号地址逐一对上(normalTick@0x10017e9ec / Item::items@0x100346dc8 / Inventory::add@0x10010dd08 / Recipes构造@0x1001957a0 / teleportTo@0x100210a7c / setIsCreativeMode@0x1000ce840 / setTileAndData@0x1001031ac / Level::tick@0x1001103c4), imagebase=0x100000000。
     - `LevelData` 序列化布局(`ExternalFileLevelStorage::writeLevelData@0x100154434` 逐字段核实): Time+0x98, RandomSeed+0x78, SpawnX/Y/Z+0x80/84/88, GameType+0xF4, Dimension+0xF0, spawnMobs+0xF8, Generator+0x108, LimitedWorldOriginX/Y/Z+0x8C/90/94。**无任何 rain/lightning/thunder 字段, 亦无 setRain/setter 符号 → 0.10.0 无动态天气系统**(雨/雪只是生物群系派生视觉: isInWaterOrRain/TerrainParticle/getTopRainTilePos 均读群系), 故 0.10 上"天气开关"做不了。
     - 反应核可做(符号全): `NetherReactorTile::use@0x10015a344`(激活), `NetherReactorTileEntity::tick@0x100d47f0 / lightItUp@0x100d41b8(造下界尖塔) / spawnEnemy@0x100d5ec0(刷僵尸猪人)`。夜间亮度由 dayTime 自动派生(sky亮度存 Level+0x90,0..11), 时间开关已随之生效。
   - 2026-10-20(晚) 0.10 新功能合入(插件`2026.8.27-36+debug`, 待真机验证):
     - World 页新增难度行(和平/简单/普通/困难, tag 15-18, 仅 0.10): 走 `ServerLevel::setDifficulty@0x1001b8f7c`(写 ServerLevel+0x14B8 并广播; `Level::setDifficulty@0x10011524c` 反编译只是 RET 空壳不可用; 经 `ServerLevel::tick→Level::tick` 调用链证实 gLevel 即 ServerLevel*, 可直调), 其他版本置灰。
     - World 页新增反应核行(点燃, tag 14, 仅 0.10): 运行时读三 Tile 单例 id(默认金41/圆石4/核247, 与 `use` 反编译读 BSS+0x48 一致), 在玩家脚下搭 use 校验的 3x3x3 图案后直调 `NetherReactorTile::use`, 成功把玩家传送到 y+32(尖塔同步建到核上方+30, y+4 会埋住); 日志记录图案 id、Level+0x15E4 门值与 use 返回值。治疗按钮 0.10 走 `Mob::heal@0x10020e25c`(上限20, 只写血量不碰容器)。
     - 天气收尾: 0.10/1.1.7/1.20.62 没有可写天气通道, 晴/雨/雷按钮置灰且 `setWeather:` 直接返回; 天气只在 1.2.15/1.4.3/1.13.3 开放。
     - flag 通道新增 `reactor`、`diff-0/1/2/3`、`mob-<实体id>`、`explode`; cycript 新增 `dbgReactor`、`dbgDiff:`、`dbgMob:`、`dbgExplode`。
     - World 页新增刷怪行(僵尸/爬行者/骷髅/僵尸猪人, tag 20-23→实体 id 32/33/34/36, 仅 0.10): `MobFactory::CreateMob@0x10024dea0` 建怪 + `addMob@0x10024e25c` 入世界, MobFactory 取自 TileSource 链(`*(*(ts+24)+5680)`, spawnEnemy 反编译同款), 出生点玩家旁(+2x/+1y), 日志记 id/mob/add 返回值; tag→id 映射 20→32/21→33/22→34/23→36, 后端另接受 10-16/37-39/1807/2848-2855/5898-5904/22286。
     - World 页反应核行追加爆炸按钮(tag 24, 仅 0.10): `Level::explode@0x100112714(gLevel, 玩家, x,y,z, 4.0)` 定点引爆(约 TNT 当量, 会伤及玩家, 建议开无敌), 日志记坐标。
     - 其他可挖: 难度切换已核实符号(`Level::setDifficulty@0x10011524c` 与 `ServerLevel::setDifficulty@0x1001b8f7c`); Mob 生成链(`MobFactory::addMob@0x10024e25c` / `_spawnMobCluster@0x10024e470`)、爆炸链(`Level::explode@0x100112714` / `Explosion::explode@0x10020b4d0`)都带符号, 可作为下一批动作/刷怪功能逆向。
     - 2026-10-20(晚) IDA 深挖 0.10 下一批功能(符号+反编译实锤, 待实现): `MobFactory::CreateMob` 实体 id 全映射(10鸡/11牛/12猪/13羊/14狼/15村民/16哞菇/32僵尸/33爬行者/34骷髅/35蜘蛛/36僵尸猪人/37史莱姆/38末影人/39蠹虫/1807村民/2848-2855 同 32-39/5898-5904 同 10-13+哞菇/22286狼) —— 可做"刷怪"按钮(CreateMob+addMob); 爆炸链 `Level::explode(Entity*,x,y,z,威力)` / `Explosion::explode` —— 可做定点爆炸; `Mob::heal(Mob*,int)` 已接治疗; `SetHealthPacket` 存在但单机直调 heal 更简单。
   - 2026-10-20(晚) 真机验证熔断(插件-37/-38, 0.10.0)：连续3次点进世界均在 Streaming 线程 SIGABRT（`Thread 5 Streaming 1` abort，堆栈只有游戏地形流式帧、无 mowanbox 参与；崩溃日志 `minecraftpe-2026-10-20-19{4050,4351,4532}.ips`），-34 对照组同签名复现 → 非本次回归；当天 15:14（动手前）已有同类崩溃。崩溃会把正在加载世界的 level.dat 回写成 325 字节 stub，已确认 `3W8AALGCCwA=`（19:43）与 `DZQAAKoGCwA=`（19:45）被 stub 化，其余 4 世界完好。**即起停止一切进世界点击**，保住剩余存档；待查 Streaming abort 根因（IDA 可反流式加载链）后再恢复真机验证。
   - 2026-10-20(晚) 验证恢复（插件-39/-41，全新世界）：经用户授权删6个旧测试世界（备份按要求不保留），新建世界一次进入无崩 → **插件无罪**，旧世界 LevelDB 损坏是唯一原因（kuna 反 abort 点为 `leveldb::ReadBlock` 内 `"corrupted compressed block contents"` 分支）。-41 补了 0.10 flag poll（`hooked_normalTick` 末加 `MWBPollCmdFile()`，之前只在 1.13.3/1.1.7/1.4.3 接了）。新鲜世界实测：时间昼夜 ✅（截图分明）；反应核触发 ✅（`[010反应核] 图案=41/4/247 y=71 gate=1 use=0`、无崩但玩家埋块里，落点 y+32 仍不够，并行侧继续调）；刷怪 ✅（`[010刷怪] id=32 mob=0x… add=1`×2）；爆炸 ✅（执行无崩地形改变，截图半出土）；难度 flag 通（`diff=0` 被消费，效果待强验证）。设备现装 -41，世界内只剩 1 个全新测试世界。

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
