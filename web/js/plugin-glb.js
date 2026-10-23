// web/js/plugin-glb.js — GLB 直解 + 姿势 + vis 叠加 + 自家 shader 绘制
// 逐行对应 MWBGLBModel.mm，函数名后标 mm 行号；数学为列主序，与 GL 一致。
// 单位：游戏渲染就是 Bedrock/米制单位，解析零换算（手搓鱼烘焙路径同证）。
// UV：不翻转（GLTFLoader flipY=false，翻了会被 alphaTest 吃成锥体残件）。
import { molVal } from './plugin-molang.js';

// ---- 小数学（对应 mm 137-159 行，列主序） ----
function quatToMat(q, m) { // 对应 GLBQuatToMat
  const [x, y, z, w] = q;
  const xx = x * x, yy = y * y, zz = z * z, xy = x * y, xz = x * z, yz = y * z, wx = w * x, wy = w * y, wz = w * z;
  m[0] = 1 - 2 * (yy + zz); m[1] = 2 * (xy + wz);     m[2] = 2 * (xz - wy);     m[3] = 0;
  m[4] = 2 * (xy - wz);     m[5] = 1 - 2 * (xx + zz); m[6] = 2 * (yz + wx);     m[7] = 0;
  m[8] = 2 * (xz + wy);     m[9] = 2 * (yz - wx);     m[10] = 1 - 2 * (xx + yy); m[11] = 0;
  m[12] = 0; m[13] = 0; m[14] = 0; m[15] = 1;
}
function matMul(a, b, o) { // 对应 GLBMatMul（o = a·b，列主序）
  const r = new Float32Array(16);
  for (let c = 0; c < 4; c++) for (let rr = 0; rr < 4; rr++)
    r[c * 4 + rr] = a[rr] * b[c * 4] + a[4 + rr] * b[c * 4 + 1] + a[8 + rr] * b[c * 4 + 2] + a[12 + rr] * b[c * 4 + 3];
  o.set(r);
}
function localMat(t, q, s, m) { // 对应 GLBLocalMat：local = T·R·S
  const R = new Float32Array(16);
  quatToMat(q, R);
  for (let c = 0; c < 3; c++) for (let r = 0; r < 3; r++) m[c * 4 + r] = R[c * 4 + r] * s[c];
  m[3] = 0; m[7] = 0; m[11] = 0; m[15] = 1;
  m[12] = t[0]; m[13] = t[1]; m[14] = t[2];
}
function slerp(a, b, f, o) { // 对应 GLBSlerp
  let dot = a[0] * b[0] + a[1] * b[1] + a[2] * b[2] + a[3] * b[3];
  let b0 = b[0], b1 = b[1], b2 = b[2], b3 = b[3];
  if (dot < 0) { dot = -dot; b0 = -b0; b1 = -b1; b2 = -b2; b3 = -b3; }
  let s0, s1;
  if (dot > 0.9995) { s0 = 1 - f; s1 = f; }
  else {
    const th = Math.acos(Math.min(1, dot));
    const st = Math.sin(th);
    s0 = Math.sin((1 - f) * th) / st; s1 = Math.sin(f * th) / st;
  }
  o[0] = s0 * a[0] + s1 * b0; o[1] = s0 * a[1] + s1 * b1;
  o[2] = s0 * a[2] + s1 * b2; o[3] = s0 * a[3] + s1 * b3;
  const l = Math.hypot(o[0], o[1], o[2], o[3]);
  if (l > 1e-6) { o[0] /= l; o[1] /= l; o[2] /= l; o[3] /= l; }
}

// ---- 时间（对应 GLBWrapT，mm 178-188 行） ----
function wrapT(t, loop, length) {
  if (loop === 1) {
    if (isFinite(length) && length > 0) { let r = t % length; if (r < 0) r += length; return r; }
    return t;
  }
  if (isFinite(length)) return Math.min(t, length);
  return t;
}
const visLen = (v) => (typeof v === 'number' && isFinite(v) ? v : Infinity); // 对应 GLBLen（null→Infinity）

// ---- 关键帧采样（对应 GLBScaleAt/GLBRotAt/GLBPosAt，mm 189-253 行） ----
function scaleAt(kfs, t, env, loop, length, out) {
  if (!kfs || !kfs.length) { out[0] = out[1] = out[2] = 1; return; }
  const tt = wrapT(t, loop, length);
  if (tt <= kfs[0][0]) { for (let k = 0; k < 3; k++) out[k] = molVal(kfs[0][2][k], env); return; }
  for (let i = 0; i + 1 < kfs.length; i++) {
    const a = kfs[i], b = kfs[i + 1];
    if (tt >= a[0] && tt <= b[0]) {
      if (a[1] === 1 || b[0] === a[0]) { for (let k = 0; k < 3; k++) out[k] = molVal(a[2][k], env); return; }
      const f = (tt - a[0]) / (b[0] - a[0]);
      for (let k = 0; k < 3; k++) {
        const xa = molVal(a[2][k], env), xb = molVal(b[2][k], env);
        out[k] = xa + (xb - xa) * f;
      }
      return;
    }
  }
  const v = kfs[kfs.length - 1][2];
  for (let k = 0; k < 3; k++) out[k] = molVal(v[k], env);
}
function rotAt(keys, t, loop, length, out) {
  if (!keys || !keys.times.length) { out[0] = out[1] = out[2] = 0; out[3] = 1; return; }
  const tt = wrapT(t, loop, length);
  const n = keys.times.length;
  if (tt <= keys.times[0]) { for (let k = 0; k < 4; k++) out[k] = keys.vals[k]; return; }
  for (let i = 0; i + 1 < n; i++) {
    if (tt >= keys.times[i] && tt <= keys.times[i + 1]) {
      if (keys.step || keys.times[i + 1] === keys.times[i]) { for (let k = 0; k < 4; k++) out[k] = keys.vals[i * 4 + k]; return; }
      const f = (tt - keys.times[i]) / (keys.times[i + 1] - keys.times[i]);
      slerp(keys.vals.subarray(i * 4, i * 4 + 4), keys.vals.subarray((i + 1) * 4, (i + 1) * 4 + 4), f, out);
      return;
    }
  }
  for (let k = 0; k < 4; k++) out[k] = keys.vals[(n - 1) * 4 + k];
}
function posAt(keys, t, loop, length, out) { // 无 track 时调用方保留 base（mm 237 行）
  if (!keys || !keys.times.length) return;
  const tt = wrapT(t, loop, length);
  const n = keys.times.length;
  if (tt <= keys.times[0]) { for (let k = 0; k < 3; k++) out[k] = keys.vals[k]; return; }
  for (let i = 0; i + 1 < n; i++) {
    if (tt >= keys.times[i] && tt <= keys.times[i + 1]) {
      if (keys.step || keys.times[i + 1] === keys.times[i]) { for (let k = 0; k < 3; k++) out[k] = keys.vals[i * 3 + k]; return; }
      const f = (tt - keys.times[i]) / (keys.times[i + 1] - keys.times[i]);
      for (let c = 0; c < 3; c++) out[c] = keys.vals[i * 3 + c] + (keys.vals[(i + 1) * 3 + c] - keys.vals[i * 3 + c]) * f;
      return;
    }
  }
  for (let k = 0; k < 3; k++) out[k] = keys.vals[(n - 1) * 3 + k];
}

// ---- GLB 解析（对应 MWBGLBEnsureParsed，mm 270-425 行） ----
function readAcc(acc, views, bin, wantComp, wantType, wantCount) {
  const vi = acc.bufferView;
  if (vi == null || vi < 0 || vi >= views.length) return null;
  const v = views[vi];
  const off = (v.byteOffset || 0) + (acc.byteOffset || 0);
  if (acc.componentType !== wantComp) return null;
  if (acc.type !== wantType) return null;
  if (wantCount >= 0 && acc.count !== wantCount) return null;
  if (v.byteStride) return null; // 紧排才读（mm 265 行）
  return { ptr: off, count: acc.count };
}

function parseGLB(buf, log) {
  const b = new Uint8Array(buf);
  const dv = new DataView(buf);
  const fail = (msg) => { log && log('[GLB] ' + msg); return null; };
  if (b.length < 20) return fail('读不到 fatfish.glb');
  if (dv.getUint32(0, true) !== 0x46546c67) return fail('魔数不对');
  const jl = dv.getUint32(12, true);
  if (20 + jl > b.length) return fail('JSON 越界');
  let j;
  try { j = JSON.parse(new TextDecoder().decode(b.slice(20, 20 + jl))); }
  catch (e) { return fail('JSON 坏：' + e); }
  const binOff = 20 + jl + 8;
  if (binOff > b.length) return fail('无 BIN 段');
  const bin = b.slice(binOff);
  const jNodes = j.nodes, jMeshes = j.meshes, jAccs = j.accessors, jViews = j.bufferViews, jAnims = j.animations || [];
  if (!jNodes || !jMeshes || !jAccs || !jViews) return fail('缺段');
  const fb = new DataView(bin.buffer, bin.byteOffset, bin.byteLength);
  const f32 = (off) => fb.getFloat32(off, true);
  const u16 = (off) => fb.getUint16(off, true);

  // 节点（位移零换算，米制直用）
  const nodes = jNodes.map((n, i) => {
    const t = n.translation, q = n.rotation, sc = n.scale;
    // 单位：游戏渲染就是 Bedrock/米制单位，不乘 16（手搓鱼烘焙路径同证：pivot/origin 原值直写即对）。
    // 之前误乘 16 会把鱼放大 16 倍、相机包 inside，只能看到巨型多边形。
    return {
      name: typeof n.name === 'string' ? n.name : ('n' + i),
      t: t ? [t[0], t[1], t[2]] : [0, 0, 0],
      q: q ? [q[0], q[1], q[2], q[3]] : [0, 0, 0, 1],
      s: sc ? [sc[0], sc[1], sc[2]] : [1, 1, 1],
      mesh: (n.mesh == null ? -1 : n.mesh),
      children: (n.children || []).filter((c) => c >= 0 && c < jNodes.length),
      parent: -1,
    };
  });
  const name2idx = new Map(nodes.map((n, i) => [n.name, i]));
  nodes.forEach((n, i) => n.children.forEach((c) => { nodes[c].parent = i; }));

  // Root 子树（只画这些，mm 320-329 行）
  let roots = [];
  if (name2idx.has('Root')) roots = [name2idx.get('Root')];
  else nodes.forEach((n, i) => { if (n.parent < 0) roots.push(i); });
  const seen = new Array(nodes.length).fill(false);
  const rootSet = [];
  const stack = [...roots];
  while (stack.length) {
    const cur = stack.pop();
    if (seen[cur]) continue; seen[cur] = true; rootSet.push(cur);
    nodes[cur].children.forEach((c) => stack.push(c));
  }

  // 网格（只 POSITION+VEC3/TEXCOORD_0+索引 uint16；顶点/位移零换算，UV 不翻转）
  const meshes = [];
  let totalTris = 0;
  for (const jm of jMeshes) {
    const prim = jm.primitives[0];
    const attr = prim.attributes;
    const pi = attr.POSITION, ui = attr.TEXCOORD_0, ii = prim.indices;
    if (pi == null || ui == null || ii == null) continue;
    const pa = jAccs[pi], ua = jAccs[ii] && jAccs[ui], ia = jAccs[ii];
    const pr = readAcc(pa, jViews, bin, 5126, 'VEC3', -1);
    const ur = readAcc(jAccs[ui], jViews, bin, 5126, 'VEC2', pa.count);
    const ir = readAcc(ia, jViews, bin, 5123, 'SCALAR', -1);
    if (!pr || !ur || !ir) continue;
    const nv = pa.count, ni = ia.count;
    const pos = new Float32Array(nv * 3), uv = new Float32Array(nv * 2);
    for (let v = 0; v < nv; v++) {
      pos[v * 3] = f32(pr.ptr + v * 12);
      pos[v * 3 + 1] = f32(pr.ptr + v * 12 + 4);
      pos[v * 3 + 2] = f32(pr.ptr + v * 12 + 8);
      uv[v * 2] = f32(ur.ptr + v * 8);
      // 不翻转：GLTFLoader 对 glTF 贴图设 flipY=false（glTF 规定 UV 原点在左上，
      // 与 PNG 行序一致），采样即原样；之前误跟 three 通用贴图的 flipY 在此是反的，
      // 会把面片采到透明区被 alphaTest 吃掉（只剩裙子/锥体残件）。
      uv[v * 2 + 1] = f32(ur.ptr + v * 8 + 4);
    }
    const idx = new Uint16Array(ni);
    for (let k = 0; k < ni; k++) idx[k] = u16(ir.ptr + k * 2);
    totalTris += Math.floor(ni / 3);
    meshes.push({ pos, uv, idx, nvert: nv, nidx: ni });
  }
  // 网格序号对齐检查（mm 359-364 行：对不上整轮不画）
  if (meshes.length !== jMeshes.length) {
    fail(`网格对不上 parsed=${meshes.length} json=${jMeshes.length}，本轮不画`);
    return null;
  }

  // 动画（只取纯数字 rot/pos，molang 通道转的时候已跳过；位移与节点同单位零换算）
  const anims = new Map();
  for (const clip of jAnims) {
    const full = clip.name || '';
    const bare = full.startsWith('main:') ? full.slice(5) : full;
    const an = { loop: clip.extras && clip.extras.loop ? 1 : 2, length: (clip.extras && clip.extras.length) || 0, rot: new Map(), pos: new Map() };
    const chans = clip.channels || [], smps = clip.samplers || [];
    for (const ch of chans) {
      const ni = ch.target.node, path = ch.target.path;
      const sm = smps[ch.sampler];
      if (!sm) continue;
      const isRot = path === 'rotation', isPos = path === 'translation';
      if (!isRot && !isPos) continue; // scale 走 vis，不从 GLB 取
      const iAcc = jAccs[sm.input], oAcc = jAccs[sm.output];
      if (!iAcc || !oAcc) continue;
      const comp = isRot ? 4 : 3;
      const tr = readAcc(iAcc, jViews, bin, 5126, 'SCALAR', -1);
      const vr = readAcc(oAcc, jViews, bin, 5126, isRot ? 'VEC4' : 'VEC3', iAcc.count);
      if (!tr || !vr) continue;
      const nt = iAcc.count;
      const keys = { times: new Float32Array(nt), vals: new Float32Array(nt * comp), comp, step: sm.interpolation === 'STEP' };
      for (let f = 0; f < nt; f++) keys.times[f] = f32(tr.ptr + f * 4);
      for (let f = 0; f < nt * comp; f++) keys.vals[f] = f32(vr.ptr + f * 4);
      if (isRot) an.rot.set(ni, keys); else an.pos.set(ni, keys); // 位移与节点同单位，不换算
    }
    anims.set(bare, an);
  }

  // 贴图（images[0] 内嵌 PNG，mm 399-408 行）
  let texBytes = null;
  if (j.images && j.images.length) {
    const bvi = j.images[0].bufferView;
    if (bvi >= 0 && bvi < jViews.length) {
      const off = jViews[bvi].byteOffset || 0, len = jViews[bvi].byteLength || 0;
      if (off + len <= bin.length) texBytes = bin.slice(off, off + len);
    }
  }
  return { nodes, name2idx, rootSet, meshes, totalTris, anims, texBytes, jsonAnims: jAnims.length, jsonMeshes: jMeshes.length };
}

// ---- 姿势 + vis 叠加（对应 MWBGLBDraw 前半，mm 529-601 行） ----
function computePose(parsed, vis, animName, tMain, tVis, roaming) {
  const { nodes, name2idx, rootSet, anims } = parsed;
  // 当前动作（main: 前缀与裸名两种都试，mm 539-541 行）
  let an = anims.get(animName) || anims.get('main:' + animName) || null;
  const loop = an ? an.loop : 2, len = an ? an.length : 0;
  const env = { roaming: roaming || {}, t: tMain };
  // vis 叠加：常驻层 + 当前动作，后者覆盖（mm 548-560 行）
  const computed = new Map();
  const visScale = vis && vis.scale ? vis.scale : null;
  if (visScale) {
    for (const a of (vis.order || [])) {
      const A = visScale[a];
      if (!A) continue;
      for (const bn in A.tracks) computed.set(bn, { kfs: A.tracks[bn], loop: (A.loop == null ? 2 : A.loop), len: visLen(A.length), main: false });
    }
    const A = visScale[animName];
    if (A) for (const bn in A.tracks) computed.set(bn, { kfs: A.tracks[bn], loop: (A.loop == null ? 2 : A.loop), len: visLen(A.length), main: true });
  }
  const n = nodes.length;
  const world = new Float32Array(n * 16);
  const hidden = new Array(n).fill(false);
  const tmpS = [1, 1, 1], tmpT = [0, 0, 0], tmpQ = [0, 0, 0, 1];
  const L = new Float32Array(16);
  for (const ni of rootSet) {
    const nd = nodes[ni];
    let sc = nd.s;
    const hit = computed.get(nd.name);
    let hide = false;
    if (hit) {
      scaleAt(hit.kfs, hit.main ? tMain : tVis, env, hit.loop, hit.len, tmpS);
      sc = [tmpS[0], tmpS[1], tmpS[2]];
      hide = Math.abs(tmpS[0]) < 1e-3 || Math.abs(tmpS[1]) < 1e-3 || Math.abs(tmpS[2]) < 1e-3; // mm 578 行
    }
    hidden[ni] = hide;
    tmpT[0] = nd.t[0]; tmpT[1] = nd.t[1]; tmpT[2] = nd.t[2];
    tmpQ[0] = nd.q[0]; tmpQ[1] = nd.q[1]; tmpQ[2] = nd.q[2]; tmpQ[3] = nd.q[3];
    if (an) {
      if (an.rot.has(ni)) rotAt(an.rot.get(ni), tMain, loop, len, tmpQ);
      if (an.pos.has(ni)) posAt(an.pos.get(ni), tMain, loop, len, tmpT);
    }
    localMat(tmpT, tmpQ, sc, L);
    world.set(L, ni * 16);
  }
  // 父先子后合成世界矩阵（mm 591-601 行）
  const rootIdx = name2idx.has('Root') ? name2idx.get('Root') : rootSet[0];
  const dfs = [];
  const st = [rootIdx];
  while (st.length) { const c = st.pop(); dfs.push(c); nodes[c].children.forEach((k) => st.push(k)); }
  const W = new Float32Array(16);
  for (let di = 1; di < dfs.length; di++) {
    const ni = dfs[di], pi = nodes[ni].parent;
    matMul(world.subarray(pi * 16, pi * 16 + 16), world.subarray(ni * 16, ni * 16 + 16), W);
    world.set(W, ni * 16);
  }
  // 可见性（含子树继承，mm 646-651 行）
  const visOK = new Array(n).fill(false);
  visOK[rootIdx] = !hidden[rootIdx];
  for (let di = 1; di < dfs.length; di++) {
    const ni = dfs[di];
    visOK[ni] = visOK[nodes[ni].parent] && !hidden[ni];
  }
  let shown = 0, total = 0;
  for (const ni of rootSet) {
    if (computed.has(nodes[ni].name)) { total++; if (visOK[ni]) shown++; }
  }
  return { world, hidden, visOK, dfs, rootIdx, shown, total, animFound: !!an };
}

// ---- 首顶点 clip/ndc（对应 mm 670-679 行，免截图定位） ----
function firstVertexClip(parsed, pose, WVP) {
  for (const ni of pose.dfs) {
    if (!pose.visOK[ni]) continue;
    const mi = parsed.nodes[ni].mesh;
    if (mi < 0 || mi >= parsed.meshes.length) continue;
    const m = parsed.meshes[mi];
    if (!m.nvert) continue;
    const M = new Float32Array(16);
    matMul(WVP, pose.world.subarray(ni * 16, ni * 16 + 16), M);
    const x = m.pos[0], y = m.pos[1], z = m.pos[2];
    const cx = M[0] * x + M[4] * y + M[8] * z + M[12];
    const cy = M[1] * x + M[5] * y + M[9] * z + M[13];
    const cz = M[2] * x + M[6] * y + M[10] * z + M[14];
    const cw = M[3] * x + M[7] * y + M[11] * z + M[15];
    return {
      world: [x, y, z], clip: [cx, cy, cz, cw],
      ndc: cw !== 0 ? [cx / cw, cy / cw, cz / cw] : [999, 999, 999],
      node: parsed.nodes[ni].name,
    };
  }
  return null;
}

// ---- 插件同格式日志行（供与 iPad 日志逐行对账） ----
function fmtParseLog(parsed, visAnims) {
  return `[GLB] 解析成功 节点=${parsed.nodes.length} 网格=${parsed.meshes.length} 三角=${parsed.totalTris} Root子树=${parsed.rootSet.length} 动画=${parsed.anims.size} 贴图=${parsed.texBytes ? parsed.texBytes.length : 0}字节 sidecar=${visAnims ? '有' : '无'}`;
}
function fmtStats(parsed, animName, visAnims) {
  return `[GLB] 自检 节点=${parsed.nodes.length} 网格=${parsed.meshes.length} Root子树=${parsed.rootSet.length} 动画=${parsed.anims.size} 当前=${animName} sidecar动画=${visAnims}`;
}
function fmtFirstVertex(fv) {
  if (!fv) return '[GLB] 首顶点 无可见网格';
  const w = fv.world.map((v) => v.toFixed(1)).join(',');
  const c = fv.clip.map((v) => v.toFixed(1)).join(',');
  const n = fv.ndc.map((v) => v.toFixed(2)).join(',');
  return `[GLB] 首顶点 世界=(${w}) clip=(${c}) ndc=(${n}) @${fv.node}`;
}

export { quatToMat, matMul, localMat, slerp, wrapT, scaleAt, rotAt, posAt, parseGLB, computePose, firstVertexClip, fmtParseLog, fmtStats, fmtFirstVertex };
