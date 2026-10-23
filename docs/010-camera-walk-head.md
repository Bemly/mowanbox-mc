# 0.10 相机/行走/头逆向全图（kuna＋反汇编实锤，imagebase=0x100000000）

> 方法：只读 `/tmp/mcpe010` 胖包 arm64 切片（8157 函数），MSFindSymbol 一律按名直解。
> 约定：yaw 度数、0=南、顺时针增、无界累积（实测 842°/1048°）；pitch 符号待定（不影响 yaw 结论）。

## 0. 五量总表（渲染每帧读的就是这些）

| 量 | 现值 | 旧值 | 写者 | 读者 |
|---|---|---|---|---|
| 视角 yaw | +0x78 | +0x80 | 触摸管线→ look target（+0x15d8/+0x15dc/+0x15c8）→`Mob::normalTick` ease | 背面相机、头（经 aiStep） |
| 视角 pitch | +0x7c | +0x84 | 同上 | 头 pitch（直连）、夜视无关 |
| 身体 yaw | +0x150 | +0x154 | `Mob::normalTick`：行走时追视角；静止不动 | 渲染身体朝向、转身动画 |
| 头 yaw | +0x158 | +0x15c | `Mob::aiStep`：每 tick `=视角+0x78` | 渲染（按相对身体钳制） |
| +0x3c | 未定案 | — | tick/出生/重生/触摸链**无写者**（只见触摸读一次） | 无（渲染不读） |

prev=cur+4 配对由 `Mob::baseTick` 每 tick 拷贝（0x154←0x150、0x15c←0x158、0x80←0x78、0x84←0x7c）。

## 1. 相机 `GameRenderer::setupCamera @0x100205bb8`（3384B，大函数可 hook）

- 第一人称（`Options+0x2cd==0`）：head 小偏置 -0.1，直走 `label_10020676c`。
- 第三背面（`+0x2cd=1,+0x2d6=0`）：**活路**。每帧直读玩家 `+0x78/+0x7c`，8 方位 `TileSource::clip` 碰撞收距离（`+0x134`），尾巴（仅背面跑）再做 yaw/pitch 合成。拖视角即转机。
- 第三正面（`+0x2d6!=0`）：读渲染器缓存 `+0x38/+0x3c`（yaw 新/旧）、`+0x40/+0x44`（pitch 新/旧），距离取反机位摆身前。**投喂链已死**（无 UI 可达，出生写一次不再更新）→正脸相机钉死；c0/c90 截图同背景实锤。尾巴跳过。
- 读的实体一律 `*(MC+0x1b0)`，`caminfo` 已验同体 gLocalPlayer。

## 2. 行走链（tick 内调用序）

`LocalPlayer::normalTick` → `Player::normalTick`/`Mob::normalTick`/`superTick` → `updateAi`（摆臂计时）→
`aiStep`（输入位：跳 0x11/升 0x13/降 0x14 在 `TouchscreenInput::tick` 置位；飞行 0x16c1）→
`travel`（`Player::travel` 只包飞行修正，直调 `Mob::travel`）→ `move`（`LocalPlayer::move` 包潜行/台阶，直调
`Entity::move`：`+0x12a` 免碰撞分支即穿墙 hook 点；落地写 `+0x125`）→ `Mob::baseTick`（prev 拷贝）
→ `updateWalkAnim`（位移测速，见下）。

- 视角转动：拖→look target 三元组（yaw+0x15d8/pitch+0x15dc/步数+0x15c8）→`Mob::normalTick` 按步数 ease
 （yaw 裹角±π，pitch 线性）；同时位置三元组（+0x15cc/0x15d0/0x15d4）同理。setter 在触摸 look 管线（未钉到具体函数，不影响鱼：只读+0x78）。
- 身体转动：`Mob::normalTick` 位移分支——走动时身体 yaw 按转速追视角（裹角），静止不写。
  头每 tick 先跟视角（`Mob::aiStep: +0x158=+0x78`），渲染再按相对身体裹角钳制。
- 测速照抄 `updateWalkAnim`：水平位移 `hypot(dx,dz)×4`，转身给 0.5，上限 1.0，指数跟随进 `+0x198`，
  相位累进 `+0x19c`；疾跑（虚表+0x170 槽 46 判 1）×1.5。插件跑阈 5.4/走 0.6 系观测标定（满速≈4.3/疾跑≈5.6）。

## 3. 头（`MobRenderer::render @0x10018386c` 反编译实锤）

- 头 pitch：`model+0xbc = interp(+0x7c/+0x84)`——视角直连，无钳制。
- 身体 yaw：`model+0xb8 = interp(+0x150/+0x154)`（裹角归一）；第二角 `+0xb4 ← +0x158/+0x15c`。
- 骑乘覆盖：被骑实体 yaw/pitch 接管 b8，并按相对角钳制（±界）。
- 四肢：`HumanoidModel::setupAnim`（model 虚表槽经 `+0x98` model 取，walk 相位 `+0x19c`/速度 `+0x198` 由 115–125 行灌入）。
- 经理对象 `*(0x10034d0b8+0x18)`，贴图走虚表 `+0x2d8`（`Mob::getTexture`）——YSM 注释里的两个 VA 是对的。

## 4. 状态位一览（插件已用，全直接读）

vy +0x70／落地 +0x125／水 +0x12d／潜行 `*(*(p+0x1810)+0x12)`／睡 +0x1804／血 int +0x168
（上限 20）／能力 Player+5824［无敌/飞/可飞/瞬挖］／坐标 +0x28（**是眼睛**，`gap=+1.62` 实锤，脚=眼−1.62）。

## 5. 对鱼的直接结论（待改，按序）

1. `T` 跟身体必须用 **+0x150**（-230 跟的是 +0x3c：无写者≈常量，站着碰巧对、走路不跟）。结构不动，只换源。
2. Head 骨 Δ 必须用 **+0x150** 当 body 源（同上；跟脸档 body==view 即 Δ=0 仍成立）。
3. `FaceTick`／`camyaw` 写 +0x3c **无实锤效果**（camyaw 测试当年被旧 FaceTick 覆盖污染），建议退役 +0x3c 用法；第 4 档真锁脸应改写 +0x150（如需复活）。
4. 孪生视角（如复活）：yaw 进三角前先裹到 ±180（无界累积吃 float 精度）；pitch 符号待真机定。
5. 第 4 档相机 hook 已删（-234 revert），复活第 4 档前先修正面缓存投喂（写者待找：`MinecraftClient::tick` 嫌疑最大）。

## 6. 未闭环（不影响鱼，只列）

- look target（+0x15d8）setter 具体函数；+0x3c 身份确证（出生链无写者，疑 write-once 幽灵值）；
- pitch 符号；疾跑虚表槽 46 身份（可用速度阈代替）；`Player::updateAi` 极短（摆臂计时而已）。
