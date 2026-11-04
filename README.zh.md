# 魔玩我的世界盒子 (mowanbox-mc)

[English](README.md)

为已越狱 iOS 设备上的 Minecraft PE 注入游戏内修改器悬浮窗。项目以 Cydia Substrate Tweak 形式注入游戏进程，用像素风 UIKit 浮层还原经典 MCPE Toolbox 布局：左侧分类栏、右侧设置面板。

> 仅用于本地离线单机世界。请勿用于联网多人服务器、Realms 或带反作弊的环境。

## 主要特性

- 可拖动头像悬浮按钮，窗口在面板外触摸透传
- 五页菜单：作弊 / 世界 / 物品 / 悬浮窗 / 模型
- 创造模式物品浏览器：分类、变体、配方、刷怪蛋
- 运行时 GLB 模型直画（4D 皮肤）与模型橱窗
- 0.10 运行时中文汉化，不修改游戏 bundle
- 小地图、史莱姆区块叠加、四视角相机滑条
- 运行时识别游戏版本，按版本挂载不同 hook 后端

## 截图

<table>
  <tr>
    <td width="50%"><img src="docs/screenshots/cheats-page.avif" alt="作弊页"><br><sub><b>作弊页</b>：开关、小地图、4D 皮肤</sub></td>
    <td width="50%"><img src="docs/screenshots/world-page.avif" alt="世界页"><br><sub><b>世界页</b>：时间、天气、动作、难度</sub></td>
  </tr>
  <tr>
    <td width="50%"><img src="docs/screenshots/items-page.avif" alt="物品页"><br><sub><b>物品页</b>：创造物品浏览、配方查看</sub></td>
    <td width="50%"><img src="docs/screenshots/model-page.avif" alt="模型页"><br><sub><b>模型页</b>：YSM 橱窗、模型设置</sub></td>
  </tr>
  <tr>
    <td width="50%"><img src="docs/screenshots/options-camera.avif" alt="选项页"><br><sub><b>选项页</b>：四视角相机滑条、4D 皮肤</sub></td>
    <td width="50%"><img src="docs/screenshots/ingame-4d-skin.avif" alt="游戏内 4D 皮肤"><br><sub><b>游戏内</b>：反应核、刷怪、4D 皮肤</sub></td>
  </tr>
</table>

## 支持的游戏版本

版本识别优先读 `CFBundleShortVersionString`，取不到时按主二进制大小兜底（见 `MWBVersion.mm`）。Tweak Filter 覆盖 6 个 bundle ID。

| 游戏版本 | Bundle ID | 状态 |
|---|---|---|
| 0.10.0 | `moe.bemly.mcpe.0.10` | 完整实现，主目标版本 |
| 1.1.7 | `moe.bemly.mcpe.1.1` | 部分功能：能力、时间、手持附魔 |
| 1.2.15 | `moe.bemly.mcpe.1.2` | 部分功能：能力、时间、天气、治疗、附魔；未上机验证 |
| 1.4.3 | `moe.bemly.mcpe.1.4` | 部分功能：能力、时间、天气、治疗、附魔 |
| 1.13.3 | `moe.bemly.mcpe.1.13` | 部分功能：能力、时间、天气、杀戮光环、小地图、治疗、传送、铺石 |
| 1.20.62 | `moe.bemly.mcpe.1.20` | 实验性：ECS hook，仅时间控制可用，其余多为只读观察 |

没有对应后端的控件会在 UI 中置灰禁用。

## 功能说明

### 作弊页

开关：无敌、飞行、快速破坏、穿墙、夜视、杀戮光环、小地图、史莱姆区块、调试日志、加速奔跑、超级跳跃、4D 皮肤。

### 世界页

- 时间：日出、白天、正午、黄昏、夜晚、午夜，另有 `-233` / `+233` tick 微调
- 天气：晴 / 雨 / 雷（仅 1.2.15、1.4.3、1.13.3）
- 动作：治疗、手持物品附魔 255、向上传送 10 格、铺 5x5x5 石头
- 难度：和平 / 简单 / 普通 / 困难
- 反应核：点燃
- 爆炸：在玩家位置定点爆炸
- 游戏模式：生存 / 创造

除上面标注的版本外，日出/正午/黄昏/午夜、时间微调、难度、反应核、爆炸、游戏模式、传送与铺石目前只有 0.10 菜单后端。

### 物品页

EMI 风格创造物品浏览器：

- 分类：全部 / 装备 / 功能方块 / 建筑方块 / 刷怪蛋
- 单击给予 1 个，双击给予一组，长按查看合成配方
- 多变体物品会打开变体选择面板
- 刷怪蛋页可在玩家旁边生成 15 种生物
- 物品 ID 与元数据读取游戏自身物品注册表，配方读取游戏 `Recipes` 单例

物品网格、给予、变体选择、配方与刷怪在 0.10 上实现。

### 悬浮窗页

悬浮窗大小（小 / 中 / 大）、透明度（低 / 中 / 高）、位置复位、界面语言（0.10 支持中文 / English）。

### 模型页

- 扫描 `/var/mobile/Documents/mwbmodels/` 下的 `<id>.glb` 与 `<id>_anim.json`
- 卡片橱窗播放离线烘焙的开门/循环精灵条
- 按 sidecar JSON 自动生成模型设置（复选框、数值范围、单选）
- 选中模型即切换 4D 皮肤；GLB 只在第三人称替换本地玩家

### 其他

- **小地图**：可拖动并记忆位置；0.10 支持表面/洞穴扫描，1.13.3 为单层采样
- **相机**：把 0.10 的第三人称开关改成四段滑条（第一人称 / 第三人称背面 / 第三人称正面 / 跟脸正面）
- **汉化**：0.10 下复写游戏内存中的 `I18n` 表，包含 853 条 GUI、实体、物品、死亡、成就文本及方块名；不修改游戏 bundle 文件

## 环境要求

- 已越狱 arm64 iOS 设备，iOS 12.0+（参考机为 iPad mini 2，iOS 12.5.8）
- Cydia Substrate / MobileSubstrate
- 构建需要 macOS、Xcode 与 iOS SDK
- [Theos](https://theos.dev/)、`dpkg`、`xz`

## 构建

```bash
export THEOS=~/theos
export PATH="$THEOS/bin:$PATH"

make package                  # 调试版：写 /var/mobile/Documents/mowanbox.log
make package FINALPACKAGE=1   # 发布版：日志编译期关闭
```

产物在 `packages/` 目录。Makefile 会把构建号（`git rev-list --count` + 短哈希 + dirty 标记）注入二进制，启动时打印。

CI（`.github/workflows/build.yml`）在推送到 `main` 和 PR 时同时构建 debug / release 两个包。推送 `v*` 标签，或手动触发并勾选 release，会创建 GitHub Release 并附上两个 `.deb`。

## 安装

```bash
scp packages/*.deb root@<设备IP>:/tmp/mowanbox.deb
ssh root@<设备IP> "dpkg -i /tmp/mowanbox.deb"
```

重启游戏以完成注入。参考设备上 `killall` 和 `ps` 容易卡死，改用 `launchctl` 加 `SIGTERM`：

```bash
ssh root@<设备IP> "launchctl list | grep -i mcpe"   # 记下 PID
ssh root@<设备IP> "kill -15 <PID>"
ssh root@<设备IP> "uiopen moe.bemly.mcpe.0.10"
```

最后一条命令里的 bundle ID 要与实际安装的游戏一致。

## 使用

点按悬浮头像打开菜单，拖动头像可移动位置。窗口在面板外透传触摸，不影响游戏操作。侧栏切换页面，关闭按钮收起菜单。

## 设备上的文件

| 路径 | 用途 |
|---|---|
| `/var/mobile/Documents/mowanbox.log` | 调试日志（仅调试版） |
| `/var/mobile/Documents/mwbfloat.plist` | 悬浮窗大小、透明度、位置 |
| `/var/mobile/Documents/mwbminimap.plist` | 小地图位置 |
| `/var/mobile/Documents/mwbmodels/<id>.glb` | GLB 模型 |
| `/var/mobile/Documents/mwbmodels/<id>_anim.json` | YSM 动画 sidecar |
| `/var/mobile/Documents/mwbmodels/<id>_thumb_intro.png` | 橱窗开门段精灵条 |
| `/var/mobile/Documents/mwbmodels/<id>_thumb_loop.png` | 橱窗循环段精灵条 |

插件偏好与游戏存档分开存放。插件不直接改写存档文件，世界内改动通过游戏自身 API 完成。

## 目录结构

| 路径 | 说明 |
|---|---|
| `Tweak.xm` | 入口、全局状态、版本分发 |
| `MWBVersion.{h,mm}` | 运行时版本识别 |
| `MWBCommon.h` | 共享全局变量、偏移与跨文件接口 |
| `MWBUI.{h,mm}` | 像素风 UI 套件 |
| `MWBMenu.{h,mm}` | 五页选项菜单 |
| `MWBFloat.{h,mm}` | 悬浮按钮、透传窗口、偏好设置 |
| `MWBHooks010.mm` | 0.10 hook（主后端） |
| `MWBHooks117.mm`、`MWBHooks1215.mm`、`MWBHooks143.mm`、`MWBHooks1133.mm` | 1.1.7 / 1.2.15 / 1.4.3 / 1.13.3 后端 |
| `MWBHooks120.mm` | 1.20.62 ECS hook（实验性） |
| `MWBActions.mm` | 跨版本动作分发与 `/tmp/mwbcmd-*` flag 通道 |
| `MWBCamera010.mm` | 0.10 四视角相机 |
| `MWBMinimap.mm` | 小地图渲染 |
| `EMI*.{h,mm}` | 物品浏览器、物品表、视图与窗口 |
| `MWBSkin4D.{h,mm}`、`MWBGLBModel.{h,mm}`、`MWBGLBMolang.{h,mm}` | GLB 解析、Molang、渲染与 4D 皮肤 |
| `MWBYSMAnim.*`、`MWBYSMCodec.*`、`MWBYSMMenu.mm`、`MWBYSMModel.*`、`MWBYSMRender.mm` | YSM 模型解码、动画与橱窗 |
| `MWBZhLang.mm`、`MWBZhGui.mm`、`MWBZhBlocks.mm` | 0.10 运行时中文汉化 |
| `MWBDebug.mm` | 触摸模拟与调试辅助 |
| `web/` | 浏览器端 GLB 验证页 |
| `tools/` | 离线模型烘焙与 sidecar 脚本 |
| `docs/` | 逆向笔记 |

## 自动化 / flag 通道

调试时可在设备 `/tmp` 下创建文件触发动作：

```bash
touch /tmp/mwbcmd-inv-1
touch /tmp/mwbcmd-time-2
touch /tmp/mwbcmd-menupage-1
```

完整命令列表见 `MWBActions.mm` 顶部注释。

## 限制

- 0.10.0 是唯一完整实现的后端，其余版本只提供部分功能，未支持的控件会置灰。
- 1.2.15 的 hook 已合入，但尚未在真机验证。
- 1.20.62 支持为实验性。
- 4D 皮肤与模型橱窗需要 0.10，并需自行把 GLB 资源放到设备上。
- 仓库不包含也不分发 Minecraft 原版素材、贴图、音效或游戏二进制。

## 许可证

本项目采用 **SIL Open Font License 1.1（OFL-1.1）**，完整文本见 [LICENSE](LICENSE)。

OFL 最初是为字体软件设计的。仓库内第三方组件仍沿用各自许可证，详见 [THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)。其中内嵌的 Fusion Pixel 字体版权归 Copyright (c) 2022 TakWolf 所有，同样以 OFL-1.1 授权。

## 免责声明

本项目仅供学习与本地离线实验使用，与 Mojang、Microsoft 无关联。Minecraft 是 Mojang Synergies AB 的商标。请勿用于在多人服务器作弊。
