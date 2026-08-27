# AGENTS.md — 魔玩我的世界盒子 (mowanbox)

本文件是本仓库对 AI agent 的项目级指导，任何在本仓库工作的 agent 都应先读完本文件再动手。

## 项目简介

- **中文名**：魔玩我的世界盒子
- **英文名**：mowanbox
- **目标**：在已越狱的 iPad mini 2 上，为 Minecraft PE（国际版）注入一个游戏内修改器悬浮窗，功能形态参考 Minecraft PE Toolbox（见图 `docs/toolbox-reference.png`）：左侧 TMI 菜单（Add Item / Add Mobs / Teleport 等）、右侧开关面板（Day/Night、Survival/Creative、Invincible、Super Jump、Item Multiplier、Block Breaker 等）。
- **当前阶段**：UI 骨架已完成并在设备上验证通过（悬浮按钮可拖动、左右两栏面板、关闭按钮、触摸透传正常）。**下一步：实现各开关/菜单的游戏内功能 hook**（时间、游戏模式、无敌、高跳、加速等）。

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
- **UI 文字、代码注释、NSLog 一律用中文**。
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
