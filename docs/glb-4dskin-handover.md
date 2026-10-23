# 4D 皮肤 GLB 交接（web 对比＋逆向＋iPad 现状，全量经验）

> 给下一个 agent：读完这篇＋`AGENTS.md`＋`web/README.md` 再动手。编年史别碰（`docs/history.md` 只读）。
> 当前：插件 `4eaabfa`（-228）在设备上，web 页 `8139` 正常，iPad 上鱼已出现但**横躺＋头尾反＋疑似悬空**待验。

## 1. 一句话目标

0.10 上用 GLB（大肥鱼女仆模型）替换本地玩家外观。工作流：**web 先行验证，插件照抄**——CPU 逻辑（解析/姿势/vis/molang/UV/绘制）在 web 页和 viewer 参考逐项对齐后，才搬进游戏；游戏里只调 iPad 专属部分（相机/落位/开关）。

## 2. 当前状态（2026-10-23 夜）

- web 页：解析 452/256/23688/48、Root 子树 431；8 组动作×时刻可见对照全绿；Root/Head 矩阵与 three 逐元一致；像素重心左右同为 (0.42,0.53)。✅ 全绿。
- iPad：-228，鱼已完整出现（截图见 3.5），但 (a) 横躺/头尾反（已定位到自家相机叉乘符号＋缺 yaw，本版刚修，未验证），(b) 悬空疑似（用户一直在飞，无法区分；需落地验），(c) 贴图方向刚修（去 CTM 翻转，待验）。
- 设备：iPad mini 2，包 `moe.bemly.mowanbox`，游戏 `moe.bemly.mcpe.0.10`，测试世界有两个 My World（2.4/3.0MB，都别删别动）。

## 3. Web 对比体系（`web/`，服务：`web/` 下 `python3 -m http.server 8139`）

- 地址：`http://127.0.0.1:8139/index.html`（8129 是旧 viewer 别混；8130 也是旧服务）。
- 左＝参考：three `GLTFLoader` 解 GLB＋mixer 姿势＋viewer 原 `updateVisibility`。右＝移植：手解 GLB＋手写 pose/vis/molang＋自家 shader，WVP 用 SIM 相机。
- 判定三件套（顶栏）：可见计数（Root 子树＋子树继承，如 `30/144 一致 ✅`）、`[GLB] 首顶点`（clip/ndc）、像素（前景占比＋重心）。
- `?only=骨名` 只画该骨子树，`?m=1` 米制（现主线已默认米制，见下）。
- `🧪自检`：molang 用例＋首帧对照。
- testdata（`fatfish.glb` 2.5M/`fatfish_vis.json` 59K）在 `web/testdata/`，gitignore 不提交，源头 `~/Downloads/大肥鱼_3js_viewer/`。

### 3.1 web 修出的三个真 bug（iPad 同样中招过）

1. **UV 翻转**：GLTFLoader 对 glTF 贴图 `flipY=false`，数据侧 `1-v` 会把面片采到透明区，被 `alpha<0.5 discard` 吃成锥体残件（`?only=Head` 0 像素）。去翻转后全身出现。——插件 `MWBGLBModel.mm` 数据侧同样去翻转。
2. **对照口径**：参考侧必须同样做子树继承＋只比 Root 子树，否则永远差一截（30/144 vs 66/150 的教训）。
3. **单位**：之前误乘 16（iPad 上鱼放大 16 倍、相机包 inside 只能看到巨型多边形）。现两边都是米制零换算。

## 4. 插件逻辑 vs web 逐模块对照（检查用）

| 模块 | web | iPad | 结论 |
|---|---|---|---|
| GLB 三段解析/accessor/网格对齐 | `plugin-glb.js:121 parseGLB` | `MWBGLBModel.mm:272 EnsureParsed` | ✅ 一致（452/256/23688/48/431 两边日志对上） |
| 单位/UV 数据 | 米制直用；UV 不翻转 | 同左（`×16`/`1-v` 已删） | ✅ 一致 |
| 姿势数学 | `quatToMat/matMul/localMat/slerp/wrapT` (8–56 行) | `GLBQuatToMat/GLBMatMul/GLBLocalMat/GLBSlerp/GLBWrapT` (147–190 行) | ✅ 一致（quat 抽 200 随机数对 three 全过） |
| 采样/vis叠加 | `scaleAt/rotAt/posAt/computePose` (58–316 行) | `GLBScaleAt/GLBRotAt/GLBPosAt`＋绘制内 pose 段 (191–256, 590–630 行) | ✅ 一致（8 组全绿；Head 逐元相等） |
| molang | `plugin-molang.js` 全文件 | `MWBGLBMolang.mm` 全文件 | ✅ 一致（vis 只用 `math.clamp`；`pi` 两边都没有） |
| shader/VBO/attrib/采样器 | `index.html:116–129` | `MWBGLBModel.mm:33–49` | ✅ **逐字相同**（alphaTest 0.5/Nearest/Clamp/双面/attrib 0/1） |
| MVP 模型部分 | `WVP_SIM·world` | `WVP_自家·T玩家·world` | ⚠️ iPad 特有：T 把鱼从原点搬到玩家脚下（web 不需要） |
| MVP 相机部分 | SIM 相机（三相机） | 自家 chase 相机（60°/游戏视口比/0.1/1000，eye=玩家+(6,8,6)，**刚修叉乘符号＋加 yaw**） | ⚠️ 待验证（见 6） |
| 贴图上传 | ImageBitmap→texImage2D（不翻转） | CGImage→CGBitmap（**刚删 CTM 翻转**，与 `MWBYSMModel.mm:302` 同款） | ⚠️ 刚改，待验证（见 6） |
| 第一人称 | N/A | 显示原版（鱼不画，`showFish` 门） | ⚠️ iPad 特有（防盖脸） |
| 开关 | 无 | 菜单 skin4d／flag `skin4d`/`glb-1`(解析+开)/`glb-2`(重载)/`glbanim-名` | iPad 特有 |

## 5. 逆向速查（0.10，imagebase=0x100000000，按名直解为主）

- `HumanoidModel::render(__ZN13HumanoidModel6renderER6Entityffffff)`：hook 点；后六参是 16 字节向量（v0–v5），按 float 转发丢高 12 字节（-168 隐身根因）。`orig` 前后分别抓快照/绘制。
- `ModelPart::render(__ZN9ModelPart6renderEf)`：真签名是 `(x0=part, v0=16字节矩阵)`；但注意该"矩阵"实际是 float4（lane0 即 f6=0.0625 缩放），render 内部用调用方已绑好的 program/uniform 画——这就是旧手搓立方体能显示的原因（蹭游戏状态），也是 GLB 自家 shader 必须自备 MVP 的原因。
- ModelPart 对象 `0xC0`，cube `0x2C8`，cube 指针向量在 part+0x20，children 在 +0x38，旋转点 +0x00/角 +0x0C，隐藏开关 +0x80，`+0xB8` 是 Model*（compile 用）。
- 六件套 model+0x108 步进 0xC0 共六个，藏原版写 `[off+0x80]=1`（`MWBSkinSetVanilla`）。
- program 42：只有 WORLDVIEWPROJ＋RENDER_DISTANCE＋CURRENT_COLOR，**不是 gameplay 相机**（原点恒居中/z 恒越界，多轮实锤；疑似天空或固定 pass）。program 48：全套实体 shader（TILE_LIGHT_COLOR/OVERLAY_COLOR/TEXTURE_0/WORLDVIEWPROJ/RENDER_DISTANCE/FOG_COLOR/**WORLD**/FOG_CONTROL）——hook 时从没绑上过，只在诊断 dump 里见过。
- 游戏主二进制几乎不调 `glUniformMatrix4fv`（GOT 统计 calls=1），矩阵疑似走 vec4 路上传——直接读 uniform 值做 MVP 是死路（已弃）。
- 相机：Options 经 MC+0x1C8；`+0x2cd` 0=第一/1=第三，`+0x2d6` 0=背面/1=正面；`MWBCamValue()` 读值（`MWBCamera010.mm:29`），flag `cam-0..3` 直写（`MWBSetCamValue01:39`）。
- 玩家：`gLocalPlayer`（normalTick 维护）；坐标 +0x28（脚，待落地再确一次），yaw +0x78（度，0 朝南，Java 同约定已验），pitch +0x7C，身体朝向 +0x3c。
- flag 通道 `/tmp/mwbcmd-<动作>[-<参数>]`（touch＋chown mobile；tick 内 poll，`cooldown%20`；禁在设备上 grep 全日志，scp 回本机再 grep）。

## 6. 待验证三件事（按顺序，一次只认一个）

1. **朝向**（-228 刚修）：自家 lookAt 的 `x=up×z` 之前符号写反（整图滚转 180°，鱼横躺）；另加了 `T=平移·绕Y(θ)，θ=π-yaw` 跟玩家朝向（`+0x78`，度）。看点：鱼站直、脸朝前（第三背面应看到后脑勺）。若脸朝前（看到脸）→ θ 改 `π+yaw`，一版的事。日志同行打 `yaw=/th=`。
2. **悬空**：落位 `T` 用 `+0x28` 当脚。若用户站平地鱼脚还离地 → `+0x28` 不是脚，加 Y 偏移（先让用户落地截图量差值，别猜）。
3. **贴图方向**：刚删 CTM 翻转（与 YSM 路径逐字节同款）。若鱼出现但花/倒 → 两种回退：(a) 加回 CTM 翻转；(b) 数据侧翻转。先看截图再选。

## 7. 日志阅读规则（`/var/mobile/Documents/mowanbox.log`，scp 回本机 grep）

- `插件已加载 构建=`：先对构建号（Makefile 用 git 计数+短哈希+dirty 注入；dirty 构建号会撞，必要时看功能行区分）。
- `[GLB] 解析成功 … 节点=452 网格=256 三角=23688 Root子树=431 动画=48`：解析 OK 基线。
- `[GLB] 首顶点 prog= world= post= 玩家=(x,y,z) yaw= th= … ndc=(x,y,z) alt= postndc=`：`ndc` 是自家相机结果（要在 [-1,1] 内、w>0）；`alt/postndc` 是游戏 WVP 对照（一直是错的，不用管）；`玩家=` 对 T 落位；`yaw/th` 对朝向。
- `[GLB] 自家相机 视口=WxH aspect=`：只打一次。
- `[GLB] 存活帧= 本帧网格= 三角= 可见=`：绘制心跳（107/11208/30/144 为 idle 基线）。
- `[相机] 视角切/诊断`：确认第三人称（2cd=1）。
- `[4D皮肤] GLB 挂载就绪`：hook 装上。旧烘焙关键字（`建树/矩阵v5/大肥鱼建好`）本进程必须 0 行（已删干净）。

## 8. 设备操作（红线内）

- SSH：`sshpass -p alpine ssh -o StrictHostKeyChecking=accept-new root@192.168.1.81`；禁 `killall/ps aux`（本机卡死），杀进程 `launchctl list | grep -i mcpe` 拿 pid＋`kill -15`；拉起 `uiopen moe.bemly.mcpe.0.10`。
- 部署：`make package`→`scp packages/<最新>.deb`→`dpkg -i`→重启游戏。模型文件在设备 `/var/mobile/Documents/mwbmodels/`（fatfish.glb 2.5M＋fatfish_vis.json 59K，源头 `~/Downloads/大肥鱼_3js_viewer/`，chown mobile）。
- 截图：`activator send libactivator.system.take-screenshot`→`/var/mobile/Media/DCIM/100APPLE/` 最新 →scp 回本机看。
- 只动测试世界（现两个 My World 都别删）；用户自己在测，大动作（重启/重装）先吱一声。

## 9. 文件清单（改动面）

- 删：`MWBFishData.c/.h`（旧烘焙模型，已 `git rm`）、Makefile 里条目、hook 内手搓树全套（`MWBSkin4D.mm` 现 87 行只剩 hook＋藏原版＋桩）。
- 改：`MWBGLBModel.mm`（单位/UV/上传/自家相机/T/yaw/诊断）、`MWBSkin4D.mm`（hook 门＋快照）、`MWBMenu.mm`（skin4d 直驱 GLB）、`MWBActions.mm`（flag 同语义）、`MWBGLBModel.h`（快照声明）、`Makefile`（构建号）。
- 新：`web/`（验证页＋移植＋对照）、`web/testdata/.gitignore`、`docs/glb-4dskin-handover.md`（本篇）。
- 没动：`MWBYSM*`（不在编译列表，多余但无害）、uniform 捕获桩（`MWBMini4DScaleMatrix` 留桩）。
