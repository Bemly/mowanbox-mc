// web/js/viewer-ref.js — 参考实现（viewer index.html 原逻辑搬运，供左视口 + 对照基线）
// 对应 ~/Downloads/大肥鱼_3js_viewer/index.html：trackVal / updateVisibility / molang 由 plugin-molang.js 提供（同语义）。
// 本文件只包参考侧的场景管理：GLTFLoader 加载、动作切换、常驻层叠加、可见计数。
import { molVal } from './plugin-molang.js';

function trackVal(track, t, env, loop, length) { // viewer 230-248 行原样
  let tt = t;
  if (loop === 1 && isFinite(length) && length > 0) tt = ((t % length) + length) % length;
  else if (isFinite(length)) tt = Math.min(t, length);
  const kfs = track;
  if (tt <= kfs[0][0]) return kfs[0][2].map((v) => molVal(v, env));
  for (let i = 0; i < kfs.length - 1; i++) {
    const a = kfs[i], b = kfs[i + 1];
    if (tt >= a[0] && tt <= b[0]) {
      if (a[1] === 1 || b[0] === a[0]) return a[2].map((v) => molVal(v, env));
      const f = (tt - a[0]) / (b[0] - a[0]);
      return [0, 1, 2].map((k) => {
        const va = molVal(a[2][k], env), vb = molVal(b[2][k], env);
        return va + (vb - va) * f;
      });
    }
  }
  return kfs[kfs.length - 1][2].map((v) => molVal(v, env));
}

// 与 viewer updateVisibility 等价，但改为纯函数：输入节点表，输出 {shown,total,scales}
// layers: order 常驻层 + 当前动作（后者覆盖），与插件 computePose 的叠加顺序一致。
function viewerVisibility(nodeNames, vis, curName, tMain, tVis, roaming) {
  const env = { roaming, t: tMain };
  const layers = [...(vis.order || []), curName];
  const computed = new Map();
  for (const an of layers) {
    const A = vis.scale[an];
    if (!A) continue;
    for (const bn in A.tracks) computed.set(bn, { A, track: A.tracks[bn] });
  }
  let shown = 0, total = 0;
  const scales = new Map();
  for (const name of nodeNames) {
    const hit = computed.get(name);
    if (!hit) { scales.set(name, null); continue; } // 无轨道：保持可见（viewer 266 行）
    const t = hit.A === vis.scale[curName] ? tMain : tVis;
    const len = (typeof hit.A.length === 'number' && isFinite(hit.A.length)) ? hit.A.length : Infinity;
    const s = trackVal(hit.track, t, env, hit.A.loop, len);
    const hide = s.some((c) => Math.abs(c) < 1e-3);
    total++;
    if (hide) scales.set(name, null);
    else { scales.set(name, s); shown++; }
  }
  return { shown, total, scales };
}

export { trackVal, viewerVisibility };
