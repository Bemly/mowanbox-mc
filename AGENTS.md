# AGENTS.md — 魔玩我的世界盒子 (mowanbox)

本仓库 AI agent 项目级指导，先读完再动手。编年史归档见 docs/history.md（只读备查不追加）。

## 项目简介

- 魔玩我的世界盒子 / mowanbox：已越狱 iPad mini 2 上给 MCPE 国际版注游戏内修改器悬浮窗，对标 docs/toolbox-reference.png（左 TMI 菜单、右开关面板）。
- 主攻 0.10.0（moe.bemly.mcpe.0.10）；另适配 1.1.7/1.2.15/真1.4.3/1.13.3/1.20.62（MWBVersion 运行时识别，Filter 覆盖 6 包）。
- 现状：菜单/悬浮窗/EMI 骨架完成；0.10 全功能（无敌飞行速破加速跳跃时间难度反应核刷怪爆炸治疗模式切换夜视穿墙小地图汉化）；EMI 分类已与原版创造栏对齐（emivrfy 错位 0）。设备现装 -153，世界内只剩 1 个全新测试世界。
- 用户长期授权：可直接操作测试世界（进世界/切时间/截图/增删测试世界/装自家插件），无需逐条请示；只动测试世界。

## 目标设备与连接

- 设备：iPad mini 2（iPad4,4 / A7 / arm64），iOS 12.5.8（16G88），Cydia Substrate 0.9.6005
- SSH：sshpass -p alpine ssh -o StrictHostKeyChecking=accept-new root@192.168.1.81（密码 alpine，WiFi 非 USB）
- USB 仅识别无 libimobiledevice，设备交互走 SSH
- MC 安装（/var/containers/Bundle/Application/，禁删禁覆盖）：0.10.0 moe.bemly.mcpe.0.10（C26BCC77）/ 1.1.7 / 1.4.3 / 1.13.3 / 1.16.50 com.mojang.minecraftpe / 1.20.62 / 3.7.30 com.netease.mc
- 共存 tweak：MCPE.dylib、MinecraftSettings.dylib，勿覆盖 MCPE.plist 的 Filter

## 安全红线

1. 不删不清用户数据：存档、games/com.mojang、容器、钥匙串、照片等，无逐条授权不 rm -rf、dd、卸载。例外（仅此）：测试世界随便删、自家插件文件直接覆盖（设备上不留 .bak）。
2. 只搞本地离线单机：不碰联网服务器、Realms、反作弊、内购破解。
3. 不碰网易版 com.netease.mc。
4. 不收录侵权素材：不提交 IPA、解密二进制、原版贴图音效，逆向笔记只写文字。
5. SSH 优先只读，写操作限自家 bundle id 不动系统文件。

## 开发约定

- 技术路线：Cydia Substrate Tweak（Logos .xm），Theos 构建（~/theos），Xcode 15.2 + iOS 17.2 SDK，codesign -s - --force 签名，make package 出 deb。目标 arm64，部署 iOS 12.0。
- 关键文件（手写超 1k 行必须拆，接口收在 MWBCommon.h / EMI.h）：Tweak.xm（入口+版本分发）/ MWBUI（像素风套件）/ MWBMenu（菜单）/ MWBFloat（悬浮窗+进世界判定）/ MWBHooks010/1133/117/143/1215/120（各版 hook + MWBInstallHooks*）/ MWBActions（动作分发+flag 通道+日志）/ MWBDebug（触摸模拟+hitmenu）/ EMI+EMIItems+EMIViews+EMIWindow（物品）/ Makefile / control / mowanbox.plist（Filter）。
- 文字注释日志一律中文；API 基线 iOS 12（C99 复合字面量、URL-based 文件、字面量集合、block 动画/通知/定时器、UIGraphicsImageRenderer、NSError 检查；禁用 CGRectMake、pathForResource、arrayWithObjects、beginAnimations、UIWebView 等）。
- Git：每次操作完 git commit + git push origin main。新结论落 AGENTS 只记干货（3 行以内），长过程不进 AGENTS 也不进 history（history 只减不增）。
- 逆向参考库（仓库外不提交）：/Users/bemly/Projects/mcpe-refs/。
- 已验证的坑：
  1. mowanbox.plist 用 NeXTSTEP 数组格式 + 权限 644（root:wheel），否则不注入。
  2. 触摸透传重写 UIWindow hitTest（只重写 rootVC.view 不够）。
  3. 面板打开要 bringSubviewToFront 悬浮钮。
  4. 12 字节短函数禁 hook（跳板 16 字节踩坏相邻函数，见 0.10 getBaseSpeed 闪退）；改 vm_protect 写常量代替。
  5. ItemInstance 布局 count@0/aux@4/Item*@8/info@0x10/valid@0x18，无独立 id 字段。
  6. 合成触摸禁合成 UIEvent sendEvent（SIGSEGV），直调游戏 VC touchesBegan。
  7. Recipes 懒加载（单例 0x10034d0c0，new 0x18 + __ZN7RecipesC2Ev；Recipe 0x48，产物 vector@0x30，虚表+0x40 取格）。
  8. flag 通道 /tmp/mwbcmd-*（touch+chown mobile，tick 内 poll、tick 后异步泻洪）；tick 内禁调容器函数（死锁）；cycript 每进程约 2 次调用上限；killall 只用 SIGTERM。
  9. appendFormat 拼大数据行会被吞改 C 缓冲 snprintf；tapGameAtX 点不动自家 UIKit 菜单（走 flag）。
  10. YSM：ModelPart/Cube 只有 C1（无 C2），compile/render 均带 float（f6 透传首帧默认 0.0625）；禁手动调 compile（进程无日志死亡改走 render 内脏检查自动编译）；日志禁 writeToURL 追加（会截断+NUL 空洞只留句柄追加）。

## 0.10.0 逆向符号速查（MSFindSymbol 直解，imagebase=0x100000000）

| 用途 | 符号 / 地址 | 说明 |
|---|---|---|
| 玩家 | LocalPlayer::normalTick @0x17e9ec | 维护 gLocalPlayer |
| 注册表 | __ZN4Item5itemsE @0x100346dc8 | Item* items[512]；旧 0x10034cd00 是 MergedGlobals 常量池 |
| 给予 | __ZN9Inventory3addEP12ItemInstance @0x10010dd08 | 转调 FillingContainer::add @0x1000ae754 |
| 配方 | 单例 @0x10034d0c0；构造 __ZN7RecipesC2Ev @0x1001957a0 | 239 条 |
| 物品栏 | Player+0x1708 | Inventory* |
| 加速 | @0x1002ab79c | __TEXT __const float 0.1f |
| 能力 | Player+5824 | [0]无敌[1]飞行[2]可飞[3]瞬挖 |
| 时间 | Level+5512 | int64 白天1000/夜晚13000；覆写+0x15F0 |
| 速度Y | Entity+112 | 跳跃初速 0.42 |
| 创造栏分类 | 方块 Tile+0x8c / 物品 Item+0x58，tab=cat-1 | populateItems 尾部分发实锤 |
| 偏航俯仰 | LocalPlayer+0x78/+0x7C | 屏角=(180+yaw)%360 |
| gamma | Options+0x2D0（经 MC+0x1C8） | 夜视改 0/5 |

## 构建与部署

```bash
export THEOS=~/theos PATH="$THEOS/bin:$PATH"
make package
sshpass -p alpine scp packages/*.deb root@192.168.1.81:/tmp/mowanbox.deb
sshpass -p alpine ssh root@192.168.1.81 "dpkg -i /tmp/mowanbox.deb"
sshpass -p alpine ssh root@192.168.1.81 "killall minecraftpe 2>/dev/null; uiopen moe.bemly.mcpe.0.10"
sshpass -p alpine ssh root@192.168.1.81 "activator send libactivator.system.take-screenshot"
```
