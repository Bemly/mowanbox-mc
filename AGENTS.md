# AGENTS.md — 魔玩我的世界盒子 (mowanbox)

本文件是本仓库对 AI agent 的项目级指导，任何在本仓库工作的 agent 都应先读完本文件再动手。

## 项目简介

- **中文名**：魔玩我的世界盒子
- **英文名**：mowanbox
- **目标**：在已越狱的 iPad mini 2 上，为 Minecraft PE（国际版）注入一个游戏内修改器悬浮窗，功能形态参考 Minecraft PE Toolbox（见图 `docs/toolbox-reference.png`）：左侧 TMI 菜单（Add Item / Add Mobs / Teleport 等）、右侧开关面板（Day/Night、Survival/Creative、Invincible、Super Jump、Item Multiplier、Block Breaker 等）。
- **当前阶段**：仅完成环境确认与仓库初始化，**功能代码暂不编写**。后续再确定目标 MC 版本、注入方式与功能清单。

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

## 开发约定（待功能启动后细化）

- 注入技术路线待定：Cydia Substrate Tweak（`.dylib` + `.plist` Filter）或动态库注入，目标架构 `arm64`，最低系统 iOS 12.x。
- 目标 MC 版本待用户确认（建议优先 `com.mojang.minecraftpe` 1.16.50，因其为官方包名且 iOS 12 可运行；1.20.62 最低 iOS 11 但需确认在 iOS 12.5.8 上的实际运行情况）。
- 悬浮窗 UI 参考 `docs/toolbox-reference.png`，具体功能清单后续再定，当前不写功能代码。
- 所有设备操作命令、路径、版本信息以本文件记录为准；若设备状态变化（重装/升级 MC），需同步更新本文件。

## 常用只读探查命令

```bash
# 连接
sshpass -p alpine ssh root@192.168.1.81

# 查看 MC 容器版本
for d in /var/containers/Bundle/Application/*/minecraftpe.app; do
  echo "$d"; plutil -key CFBundleShortVersionString "$d/Info.plist"
done

# 查看已加载的 tweak 列表
ls /Library/MobileSubstrate/DynamicLibraries/

# 查看设备/系统信息
uname -a; cat /System/Library/CoreServices/SystemVersion.plist
```
