# 4D皮肤 GLB 移植 1.x（GLES 四版）hook 点表

> 目标：把 0.10 的 GLB 链（游戏真相机 P·V·W + 本地玩家相对相机坐标 + 身体 yaw + 藏原版）搬到 1.1.7/1.2.15/1.4.3/1.13.3。
> 来源：隔壁 iMac IDA 9.4（idalib）反 `/Volumes/Public/MCPE替身 <ver>.ipa`（10-19 重制版）主二进制 arm64 切片，imagebase=0x100000000。
> 设备一致性：1.1.7/1.4.3/1.13.3 设备二进制与 ipa 的 `__TEXT` 仅加载命令区 <10 字节不同（重签），代码逐字节相同 → VA 直用。1.2.15 设备未装。
> 1.20.62 不在本表：bgfx/RenderDragon 走 Metal，GLES 自绘路不适用。

## 0. 四版共性（静态实锤）

- 全部 cryptid=0、strip、无 RTTI（`-fno-rtti`）；只有 1.13.3 留有 ~1000 条 `__PRETTY_FUNCTION__` 串，1.1–1.4 仅十几条 → 1.13 可按名定位，老三版靠 `WORLDVIEWPROJ` 等常量名锚点。
- 渲染均为 GLES（导入 `_glUniformMatrix4fv/_glUniform4fv/_glDrawElements`），mce 常量缓冲：`ShaderConstant` 值指针 @+48、脏标 @+41。
- **MatrixStack**（四版同构）：`std::vector<Matrix>`，begin@0 / end@8 / cap@16，dirty 字节@24，栈顶 = `end-64`，对象 0x20。
- **WorldConstants**：`init` 按名取 `WORLDVIEWPROJ/WORLD/WORLDVIEW/PROJ` 存 this[2..5]；`refresh` 计算 `WORLDVIEW=视图·世界`、`WVP=投影·WORLDVIEW`。
- 相机三栈两种形态：
  - 1.1.7：**全局**三栈（同 0.10），指针存于 `__DATA`，`*(MatrixStack**)(slide+VA)`。
  - 1.2.15/1.4.3/1.13.3：**相机结构内**三栈，视图@+0 / 世界@+0x20 / 投影@+0x40，由每次绘制的常量同步入口传入。

## 1. 相机矩阵来源

| 版本 | WorldConstants::init | refresh | 每次绘制同步入口（hook 抓相机） | 相机参数 | MatrixStack top / dirty |
|---|---|---|---|---|---|
| 1.1.7 | 0x1006BB3A0 | 0x1006BB588 | 0x1006BD864（不需要） | 全局：投影 `*0x101587C90` / 世界 `*0x101587C98` / 视图 `*0x101587CA0` | 0x1006CBBCC / 0x1006CB9E8 |
| 1.2.15 | 0x100A4BA30 | 0x100A4BC90 | 0x100A4E85C（132B） | x2 | 0x100A6AEC4 / 0x100A6ACA4 |
| 1.4.3 | 0x100ABFD64 | 0x100ABFFE0 | 0x100AC27EC（132B） | x2 | 0x100ADD390 / 0x100ADD2F8 |
| 1.13.3 | 0x1010DC1B4 | 0x1010DC454 | 0x1010DF9D8（184B） | x1 | 0x10110EC60 / 0x10110EBCC |

- 1.2.15/1.4.3 同步入口签名 `(flags*, ctx, camera, a4, a5)`：反编译把 x2 吞了，但内层包装 `wrapper(WC, ctx, cam)` 用 a3 调 refresh → 相机在 x2。
- 1.13.3 同步入口 `(ctx, camera, a3, a4)`：`wrapper(WC+32, ctx, cam)` → 相机在 x1（调用者 0x100926030 以 `a2[2], a2[3]` 传入）。
- 上机校验：抓到的指针按 `end-begin` 为 64 的倍数且非零才认；UI/离屏 pass 也走同一入口，取"进实体渲染前最后一次"的相机。

## 2. 本地玩家渲染 hook（藏原版 + 相对相机坐标）

| 版本 | 函数 | 签名 / 关键参数 | 状态 |
|---|---|---|---|
| 1.13.3 | `ActorRenderDispatcher::render` 0x100AAD1F4（892B） | `(this, BaseActorRenderContext&, Actor&, const Vec3&, const Vec3& 相对相机坐标, const Vec2& rot, bool)`；x2=Actor、x4=相对坐标（与渲染距离平方比较即证） | ✅ pretty 串实锤；本地玩家不调 orig 即连盔甲一起藏 |
| 1.4.3 | 未定位 | — | ⏳ 上机差分（见 4） |
| 1.2.15 | 未定位 | — | ⏳ 1.4.3 定位后按函数结构比对移植（设备未装，只能静态） |
| 1.1.7 | 未定位 | — | ⏳ 上机差分 |

- 1.13.3 旁证：同族 `ActorShaderManager::setupShaderParameters(ScreenContext&, BaseActorRenderContext&, Actor&, …)` 0x100A8ECC0（1808B），9 个包装调用者，可作备用挂点（只能抓不能藏）。
- 老三版静态死路（已试）：`Actor Render System` 性能标签 1.13 才有；`entities/terrain` 串落在音效 JSON 解析；`__FILE__` 路径无渲染器 .cpp。

## 3. 玩家朝向偏移

| 版本 | 视角 yaw（pitch/yaw，旧值+8） | 身体 yaw（旧值+4） | 头 yaw | 依据 |
|---|---|---|---|---|
| 1.13.3 | Actor+0xEC（pitch+0xE8，旧 +0xF0/+0xF4） | Mob+0x750（旧 +0x754） | Mob+0x758（旧 +0x75C） | molang `query.body_y_rotation` → 虚表+160 → Player 虚表 0x1032DD7E0 槽 20 = 0x101B598E8 插值读 +0x754/+0x750；头为槽 21 |
| 1.4.3 / 1.2.15 / 1.1.7 | ⏳ | ⏳ | ⏳ | 无 molang 查询名；上机内存 diff（同 0.10 yawscan 做法：转视角/走动前后扫玩家对象） |

## 4. 待上机（老三版，按顺序）

1. **渲染 hook 差分**（一次进世界即可）：临时探针挂"每次绘制同步入口"，每次调用沿帧指针链取 12 层 LR（减 slide 记日志，去重计数）；第三人称与第一人称各采 5 秒——只在第三人称出现的调用链即本地玩家身体绘制链，链上从下往上依次是网格绘制→模型渲染→Mob 渲染器 render→分发器；回 IDA 认函数、看签名。
2. **朝向 diff**：站定拖视角、再走一圈，扫玩家对象前 0x2000 字节 float 变化，定视角/身体/头三组。
3. 1.2.15 以 1.4.3 结果为模板在 IDA 里按调用结构/常量比对定位（设备未装，标"未验"）。

## 5. 移植形态（定案后照抄 0.10）

- 相机：1.1.7 读全局三栈顶；其余版本在同步入口 hook 里缓存相机指针，进实体渲染时读三栈顶算 `P·V·W`。
- 玩家：分发器 hook 判 `Actor == 本版本地玩家指针`（各版 tick hook 已维护：gPlayer117/143/1215/1133），抓相对坐标、不调 orig、调 `MWBGLBDraw`；第一人称不进分发器，天然不画。
- 落位：`T = 平移(相对坐标, 脚) · 绕Y(π−身体yaw) · 缩放`，节点世界与 web/0.10 逐元一致。
