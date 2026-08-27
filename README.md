# 魔玩我的世界盒子 (mowanbox-mc)

为已越狱 iOS 设备上的 Minecraft PE 注入游戏内修改器悬浮窗，功能形态参考 Minecraft PE Toolbox：左侧 TMI 菜单、右侧开关面板。

**仅用于本地离线单机世界，不针对联网多人服务器。**

## 当前状态

- 目标版本：Minecraft PE **0.10.0**（`moe.bemly.mcpe.0.10`）
- 目标设备：iPad mini 2 / iOS 12.5.8 / arm64
- 悬浮窗 UI 已完成（可拖动悬浮按钮、左右两栏面板、触摸透传）
- 已实现功能：无敌、飞行、快速破坏、加速奔跑、超级跳跃、时间切换（白天/夜晚）
- 开发中：游戏模式切换、物品添加、生成生物、传送等

## 技术栈

- [Theos](https://theos.dev/) 构建系统
- Cydia Substrate（`MSHookFunction`）hook C++ 游戏函数
- Logos (`.xm`) + Objective-C UIKit 悬浮窗
- 打包为 Sileo/Cydia 可安装的 `.deb`

## 构建

```bash
export THEOS=~/theos
export PATH="$THEOS/bin:$PATH"
make package
```

产物在 `packages/` 目录。

## 安装

```bash
sshpass -p alpine scp packages/*.deb root@<设备IP>:/tmp/mowanbox.deb
sshpass -p alpine ssh root@<设备IP> 'dpkg -i /tmp/mowanbox.deb'
killall minecraftpe 2>/dev/null
```

## 版本规范

使用 [CalVer](https://calver.org/) 日历化版本，格式为 `YYYY.M.D`（如 `2026.8.27`）。

## 免责声明

本项目仅供学习交流，不收录任何 Minecraft 原版资源或受版权保护的素材。
