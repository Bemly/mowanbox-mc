# web/ — 4D皮肤 GLB 移植验证页（web 先行，web 对了才部署 iPad）

## 工作流程（新）

1. 改逻辑先改 `web/js/`（插件 C++ 的逐行 JS 移植），在本页验证。
2. 本页三判定全过（双视口逐帧对照一致 ✅＋肉眼形态对＋日志与插件同格式），再把同样的改动搬回插件 `.mm`。
3. 上机只验证 iPad 专属部分（GLES 真机行为、WVP 直读、性能），CPU 逻辑不再上机调。

## 文件对照（插件 ↔ web）

| 插件（iPad） | Web 移植 | 说明 |
|---|---|---|
| `MWBGLBMolang.mm` | `web/js/plugin-molang.js` | 分词/递归下降/求值逐行对应，注释标 mm 行号 |
| `MWBGLBModel.mm`（解析/姿势/vis叠加/数学） | `web/js/plugin-glb.js` | `parseGLB`/`computePose`/slerp/采样，行号对应 |
| `MWBGLBModel.mm`（自家 shader/VBO/绘制） | `web/index.html` 内 `drawPlugin` | 同款 vs/fs（alphaTest 0.5 discard＋Nearest＋双面），MVP=WVP·world |
| viewer `index.html`（参考） | `web/js/viewer-ref.js`＋左视口 | `trackVal`/`updateVisibility` 原样搬运 |
| `tools/bake_fatfish.py` 等烘焙脚本 | 未搬（下一步） | 烘焙链不在"正确加载 GLB"主路上，GLB 对了再对烘焙 |

## 关键语义（两边必须一致，出分歧先查这里）

- 单位：解析时位移/顶点 **×16** 进游戏单位；UV flipY（`1-v`）。
- 网格：只读 float32 POSITION＋uint16 索引；**解析网格数≠JSON 网格数则整轮不画**（插件行为，原样保留）。
- 动画：只取纯数字 rot/pos 通道；STEP 保持；scale 永远走 vis，不从 GLB 取。
- vis 叠加：常驻层按 `order` 先算，当前动作后算覆盖；任一分量 `|c|<1e-3` 即整组隐藏（含子树）。
- 双时钟：`tMain`（动作）/`tVis`（常驻层），dt 钳 0.1。
- WVP：iPad 上是游戏 `WORLDVIEWPROJ` 直读；本页是 **SIM**（右相机=左相机×16，矩阵数值保持插件单位）。

## 运行

```bash
cd web && python3 -m http.server 8129
# 打开 http://127.0.0.1:8129/index.html
```

testdata（`fatfish.glb`＋`fatfish_vis.json`）在 `.gitignore` 中，不提交。
首次运行把 `~/Downloads/大肥鱼_3js_viewer/` 下同名两文件拷进 `web/testdata/` 即可。
