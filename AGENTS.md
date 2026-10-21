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
   - 2026-10-20(晚) 验证恢复（插件-39/-41全新世界）：经用户授权删6个旧测试世界（备份按要求不保留），新建世界一次进入无崩 → **插件无罪**，旧世界 LevelDB 损坏是唯一原因（kuna 反 abort 点为 `leveldb::ReadBlock` 内 `"corrupted compressed block contents"` 分支）。-41 补了 0.10 flag poll（`hooked_normalTick` 末加 `MWBPollCmdFile()`，之前只在 1.13.3/1.1.7/1.4.3 接了）。新鲜世界实测：时间昼夜 ✅（截图分明）；反应核触发 ✅（`[010反应核] 图案=41/4/247 y=71 gate=1 use=0`、无崩但玩家埋块里，落点 y+32 仍不够并行侧继续调）；刷怪 ✅（`[010刷怪] id=32 mob=0x… add=1`×2）；爆炸 ✅（执行无崩地形改变，截图半出土）；难度 flag 通（`diff=0` 被消费，效果待强验证）。设备现装 -41，世界内只剩 1 个全新测试世界。
   - 2026-10-20(晚) 白天渲染黑诊断（插件-53）：用户报切白天后地面仍黑夜、但僵尸灼烧（逻辑对）。kuna 复核 `Level::tick`：亮度由 override(+0x15F0)>=0 则用之否则用 dayTime(+0x1588) 算出写 `Level+0x90`；device 日志证实切白天后 `dayTime=1001/override=-1/sky=0`（亮度字节已是白天）→ 疑渲染读了另一只 Level 或光照表未刷新。`TileSource::getRawBrightness` 反编译：`Level*=TileSource+24`、`TileSource+0x11` 为昼夜开关。新增 `dayinfo2` 探针对比 gLevel 与渲染链 Level 是否同体；另修 `MWBPollCmdFile` 尾部无条件泻洪导致的日志刷屏（7MB+）。设备现装 -53。
   - 2026-10-21(晨) 真机三截图定案（插件-53/54）：dayinfo2 证**同体=1**且 sky 已对 → 地面光与逻辑无关；夜晚天空黑+地面白天亮、切白天后重渲染仍漆黑 → **地面光烘焙在区块存储光照里**。kuna 全二进制仅一处重算（`RandomLevelSource::postProcess` 调 `LevelChunk::updateLightsAndHeights`），`TileSource::getBrightness` 直接返回存储值（与实时相减的 getRawBrightness 是两条路）→ 香草本来就不刷旧区块。-54 只调 `allChanged` 无效（稳定态手摇刷新仍黑）。-55：`setLevel` 捕获渲染器（`nm -arch arm64` 取名：setLevel@0x1007e858/allChanged@0x1007ebfc/relight@0x100221e4c，均为本地符号 MSFindSymbol 可解），时间边沿等30tick落位后先走 MainChunkSource 表（+0x20桶/+0x28数，虚表槽校验，上限1024）逐块重算存储光照再 allChanged；另有 `refresh` 手摇档。设备现装 -55。
   - 2026-10-21(晨) IDA 深挖定案 + 回滚 -52（插件-56→-62 全部推翻）：-56 虚表校验拦错（LevelChunk 首字段非虚表，命中277全拦）、-57 改镜像范围后命中277但 0 块（结构假设错）、-58 改坐标比对后重算跑通（277块）但画面不动、-59 加 lightinfo 只读探针（存储天光恒15/块光10/头顶15/0，证存储与时间无关）并停掉自动重算。IDA 反 `setTileAndData` 铁证：`v42!=v39` 才通知（同值重写直接返回），`renderer::onTileChanged` 对新旧相同仍标脏（v15=0分支）→ -62 改逐块伪造"挖掉石头"通知（监听链 ts+56/虚表+0x30/flag=3，只通知不写世界）并删 allChanged，另修 flag 双消费（poll 内 remove 失败跳过）。但 -62 未及验证且用户明确叫停（另有两次把玩家埋进石头/尖塔的操作事故）。**结论**：显示链=存储直读、无实时因子、无香草按时重刷已全部实锤；锻造（按模式15/4写存储，lightinfo 验证落位）+伪造通知重建在理论上闭环但未经真机确认。**设备已回滚 -52**（无卡顿版，下次启动生效，-62 包保留在 packages/），光照问题暂停等有把握再动。教训：慢机（tick~1/s、重建277块要数分钟）上不得用秒级等待下结论；进世界/切时间等用户动作不可代劳盲点。
   - 2026-10-21(午) 用户叫停并回退到动光照之前：-53~-62 七版光照改动全部推倒，`MWBActions.mm`/`MWBCommon.h`/`MWBHooks010.mm` 已用 `git checkout 1dfc389 --` 恢复到 0.10 时间按钮最初形态（只写 dayTime+清覆写，无重算/重建/探针/伪造），构建验证通过（产物 -63 与 -52 同行为，packages/ 里，**未部署**）。AGENTS 历史保留备查。设备侧早已是 -52 文件（23:24 版，无需任何操作）。-62 的伪造通知重建链在理论上闭环但从未经真机确认，留待以后有把握再说。
   - 2026-10-21(午) IDA+kuna 全工具复核定案之二（纠正上一条"没有链"的结论：链有两条，都是活的，但各有各的滞后）：
     - 存储光照确实与时间无关（`TileSource::getBrightness` 读存储，`updateLightsAndHeights@0x100221e4c` 唯一调用点是 `postProcess`），-54~-62 针对存储/网格的一切手术方向错了，推倒正确。
     - 活路一（地形光照图，逐帧但带门）：`MinecraftClient::tick@0x10002ee08` 内 256 项光照表重算（日出色+天空曲线+gamma全实时）+每帧 `ImageData::_loadTexData` 上传，`renderChunks@0x10007f5fc` 把该纹理绑到 unit1 供地形采样。重算被门控：`LocalPlayer+0x1854==3` 才跑（全二进制唯二写入：构造置1，`LocalPlayer::tickWorld@0x10017e980` 在附近已加载区块数 W20≥105/114 时置3；W20 扫半径4共57点，`new(0x40)` 状态体在 `MC+0x178` 链上）。慢机上流式加载几分钟才 settle，秒级测试时门恒失败=光照表冻结=地面亮度冻结；天空（`getSkyColor` 直读无门）、逻辑（`getRawBrightness` 无门）不受影响——这正是"天空逻辑对、地面错"的分叉点。BlockLauncher 的 `nativeSetTime` 注释里留着被注释掉的 `allChanged`，也是同一条链的旁证。
     - 活路二（环境亮度，平滑爬行无门）：`LevelRenderer::tick@0x10007f7b8` 每 tick 把 `[0x1de]` 向实时目标收敛 10%（`dat_1002aaca4=0.1` 已从二进制读出），`renderLevel@0x1000815e8` 用它乘雾色/环境色（`[0x754/8/C]`）。跳变后它按指数爬，慢机 tick~1/s 时 30 tick 才收敛 96%，秒级 verdict 必黑；重进则初值即正确所以"修好"。"夜晚天空黑+地面白天亮"（day→night 切后环境还没爬下去）与"切白天重渲染仍黑"（night→day 切后环境还没爬上来，allChanged 与它无关）正好是一体两面。
     - 结论：bug 不是"没链"，是"两条活链各自滞后（门控冻结+指数爬行），而之前所有验证都在收敛前下了结论"。零代码判别实验（用户侧，站着别动）：夜里切白天后每 30s 截一张连截 5 分钟——若某时刻突然变亮=门控通过（看 W20/settle）；若平滑变亮=环境爬行；若 5 分钟仍黑=另有冻结，再上只读探针（表项+`+0x1854`+dayTime三值dump）。修复方向按实验结果二选一：(a) 跳变时顺手 snap `[0x774]/[0x778]` 到目标（渲染浮点，无 gameplay 副作用）；(b) 门控侧只读轮询 settle（`+0x1854==3` 再判 verdict，或 toast 提示等待），绝不提前置3（它还 gate 着 normalTick 里一段移动码，有副作用）。
   - 2026-10-21(晚) 时间按钮改一次性跳转+六时段微调（插件-70~-74）：用户报"点了白天/夜晚后时间永远不动"——旧写法每 tick 硬写 dayTime 锁死了时间。改成点一下写一次就松手（hook 内用完即清零，时间自然流，-70/-71 真机验证流动正常）。另按用户要求加时段：0.10 一天 19200 tick（`%0x4B00` 取模实锤），World 页时间区改 2×3（日出0/白天1000/正午4800/黄昏9600/夜晚13000/午夜14400）+ 微调行 -233/+233（tag 25/26）；新按钮走 `gTimeCustom010` 一次性后端（仅 0.10，其余版本置灰），白天/夜晚保持跨版本；`setTime:` 与 flag `dottime` 共用 `MWBApplyTimeTag`。逐个真机验证：日出/正午/黄昏/午夜截图+dayinfo 全对；dottime-8/26 走按钮同函数验证通过；排版曾出阶梯错位（循环内读写 tBase），已修并截图确认（-74，设备现装）。flag 另有 `tod-N`（绝对时刻）/`menupage-N`（开菜单跳页，悬浮窗点按 cycript 够不着 overlay 窗）。
   - 2026-10-21(晚) 真机门控全链验证定案之三（插件-64~-69，只读探针 `light010/cmp010/dayinfo`，零 gameplay 改动）：门控四条件逐项实锤全过——①`field_0xa0==gLevel`（同A0=1）；②`field_0x58` 是字节（IDA：4 处全 `LDRB`，之前读到的 -256 只是相邻字节，byte0=0 即门开）；③门调的是 `MinecraftClient::getLocalPlayer`（dladdr 反查 `__ZN15MinecraftClient14getLocalPlayerEv`，V=0x100a7dfc0），实调返回即 gLocalPlayer（同LP=1），`+0x1854==3`（gate2=3）；④v27(`*(MC+0x178链+0xa0`)==gLevel（同体=1），dayTime/sky 两边一致。附带修正：旧 `Minecraft::tickEii` 主流程根本不跑（mc恒0），已改 hook `MinecraftClient::tickEii` 捕获 MC（-66）；另 `tapGameAtX` 坐标系是点（768×1024）不是像素，Play 中心用 (512,458)。
   - 真机双向验证（新进程，门全开）：夜13349→强置白天1001，表 2 分钟内翻成白天值（[16]ff0f0f0f→ff131313/[128]ff1b1515→ff434343），地面同步变亮 ✅；再强置夜晚13000，地面变暗但表保持白天值——不是冻结，是缓存判等跳过（日出色+日曲线在黎明1001≈黄昏13000处对称相等，eps=0.05 实测读出很小，判等即物理正确：黄昏本就≈黎明亮度），地面变暗走环境 `[0x1de]` 10% 爬行（读天空字节 0↔11 非对称，必收敛）。结论：**时间按钮（只写 dayTime+清覆写）正确且充分，无需任何代码修复**；-53~-62 的全部手术本来就不用做。旧进程 2 小时冻结是门控失败（当时 mc hook 已坏无法验证 cp，最大嫌疑是该 aged 进程内 getLocalPlayer/0xa8 屏检查 transient 失败），属个案不可复现，不再追。
   - 探针保留：`light010`（门/速率/表）、`cmp010`（v11/P/V/slot/dladdr/v27/mcA0/同体/mc58/a0a0/cp/gate2 全链）、`dayinfo+mctick`（MinecraftClient::tick 存活计数，实测 20/s）。均为 flag 触发、默认静默。
   - 2026-10-21(午) 逆向参考库（都在 `/Users/bemly/Projects/mcpe-refs/`，仓库外，不提交）：`HorizonPE`（Razzile，2014-2015 iOS Substrate 开源修改器：hurt无敌/normalTick飞行/getWalkingSpeedModifier加速/jumpFromGround高跳/六个getDestroySpeed速破/DestroyBlock扩散nuker，与 mowanbox 同族；偏移是 0.8/0.9 代abil在player+0xC6C，不可照抄）；`MCPELauncher`（zhuowei/BlockLauncher，0.10年代Android原生patch集大成，找符号/绕校验/ModPE runtime思路通用）；`MCPE-NativeMods`（byteandahalf，BlockLauncher用C++ native mod例子）；`ModPEScripts`（zhuowei）/`McPeScripts`（tombailey，ModPE JS功能清单对照）。以上均为 `--depth 1` 克隆。
   - 2026-10-21(午) 用户明确授权（长期有效）：agent 可直接在真机上操作测试世界（进世界/切时间/截图/新建与删除测试世界、装自家插件包），无需逐条请示；10-20 的进世界熔断是临时措施（当晚查明 LevelDB 损坏后即解除），不构成任何 standing 禁止；历史熔断记录保留备查。用户数据红线不变：只动测试世界，不碰其他存档/容器/钥匙串/照片等。
    - 2026-10-22(晨) 小地图A Map Atlases风+转向实锤（插件-82~-90，设备现装-90）：框体羊皮纸底+N/坐标行/洞穴深蓝边框；夜暗按 Level+0x90 天空字节（**白天0夜里10~11**，初版映射反了已纠正）；坐标16号字防截断、N 移入图内。转向：旧 `ENTITY_YAW_OFF 0xAC` 恒0是错的，加 `dragGameFromX:y:toX:y:`（`turn-N` flag）转视角+`yawscan010` 扫玩家对象 diff 两轮锁定真 yaw=`+0x78`/pitch=`+0x7C`（311.0→432.3，矩阵区+0x194~0x1a8 联动）；箭头公式经 8 组真机截图程序量角闭环为屏角(顺时针从正北)=`(180+yaw)%360`（yaw=0朝南增量顺时针，Java 同款）；`tapGameAtX` 点不动自家 UIKit 菜单（只到游戏 VC），故关菜单走 `menuclose` flag；开菜单藏小地图/关菜单恢复双向截图验证 ✅。教训：`NSMutableString appendFormat` 拼大数据行莫名被吞（空头行），探针 dump 改 C 缓冲 `snprintf` 直拼；小箭头肉眼判向不可靠，一律程序量角。

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
4. **不备份，直接删**：测试地图/世界多了直接删，不备份；本项目自己的插件文件（dylib/plist/deb，如 `/Library/MobileSubstrate/DynamicLibraries/` 下自家文件及 `/tmp/mowanbox.deb`）切记不要备份、直接删/直接覆盖（设备上留 `.bak` 会干扰注入判断）。本条是第 1 条的例外，但仅限测试世界和自家插件文件。
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
- **关键文件**（2026-10-20 已按分类拆分，超 1k 行大文件不再有；跨文件接口集中在 `MWBCommon.h` / `EMI.h`）：
  - `Tweak.xm`：主入口（全局状态定义 + `%ctor` 版本分发 + 各版本安装调用）。
  - `MWBUI.h/.mm`：像素风 UI 套件（配色/字体/开关/按钮/侧栏图标/点击音）。
  - `MWBMenu.h/.mm`：选项菜单（左侧分类导航 + 右侧设置页）。
  - `MWBFloat.h/.mm`：单一悬浮窗（头像按钮 + 透传窗口 + 主控制器 + 安装入口 + 进世界判定）。
  - `MWBHooks010/1133/117/143/1215/120.mm`：各版本 hook + 后端（各带 `MWBInstallHooks*` 安装函数）。
  - `MWBActions.mm`：跨版本动作分发（治疗/附魔/传送/铺石/天气/难度/反应核/刷怪/爆炸）+ flag 通道 + 小地图 + 文件日志。
  - `MWBDebug.mm`：触摸模拟 + cycript 调试入口 + 菜单命中探针（`hitmenu`）。
  - `EMI.mm`（管理器+给予后端）、`EMIItems.mm`（物品表/变体/配方）、`EMIViews.mm`（纹理/立方体/图标/格子/标签）、`EMIWindow.mm`（面板+主窗口+快捷栏）。
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
- **单文件不超过 1000 行（只算手写代码；自动生成的资源字节数组头如字体/图片除外），超了必须按分类拆文件**：UI 套件 / 菜单 / 悬浮窗 / 各版本 hook（一版一文件，各带 `MWBInstallHooks*` 安装函数）/ 动作分发 / 调试 / EMI（数据/视图/窗口/管理）；跨文件接口集中到 `MWBCommon.h` / `EMI.h`，`%ctor` 只做版本分发。拆完必须 `make package` 通过 + 真机新鲜世界验证（菜单探针翻转+截图）无回归再提交推送。
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
