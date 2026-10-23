// web/js/ysm-anim.js — YSM 动画运行时（直接吃 fatfish_anim.json 原始关键帧），逐行对应 MWBYSMAnim.mm
// 取代旧链路（GLB 四元数 clip + scale sidecar）。旧链路的错：
//  1) 转换器把含 molang 的整条通道丢掉（头发/裙子物理、头随视角、呼吸全没了）；
//  2) mode=2 是 catmull-rom，被当线性；pre/post 双值只取 post；
//  3) 欧拉关键帧被转成四元数 slerp（大角度走最短弧，和 YSM 欧拉线性插值不同）；
//  4) 只播一个 clip，pre_parallel / parallel 层与控制器、player_update 函数全缺。
// 语义（GeckoLib/YSM 同款，按层覆盖）：
//  层序 pre_parallel0..7（低优先级）→ 主动画 → parallel0..7（高优先级），同骨同通道后层覆盖前层；
//  骨骼 = 静止角 + 动画值；旋转 YSM→渲染空间 (-x,-y,+z)，位移 (-x,+y,+z)/16（BoneMatrixComputer）；
//  local = T(相对父轴心 + 位移) · Rz·Ry·Rx · S（GLB 顶点已相对自身轴心）。
//  头随视角：主动画未自己写 ysm.head_* 时，Head 骨叠加 (pitch, 头相对身体 yaw)。
'use strict';
import { compile, ev } from './ysm-molang.js';

const D2R = Math.PI / 180;
const MAIN_FADE = 0.2; // 主动画切换淡入（秒）

// ---- 预处理：关键帧分量编译成 数字|AST ----
function prepVal(v) {
  if (v == null) return 0;
  if (typeof v === 'number') return v;
  return compile(v) || 0;
}
function prepKfs(kfs) {
  return kfs.map((k) => ({ t: k[0], mode: k[1], pre: k[2] ? k[2].map(prepVal) : null, post: (k[3] || [0, 0, 0]).map(prepVal) }));
}
function prepAnim(name, a, name2idx) {
  const bones = [];
  let molangBone = null;
  for (const [bn, e] of a.bones) {             // 有序数组：求值顺序 = YSM 原序（同名二阶先调者定值）
    const b = { name: bn, ni: name2idx.has(bn) ? name2idx.get(bn) : -1,
      r: e.r ? prepKfs(e.r) : null, p: e.p ? prepKfs(e.p) : null, s: e.s ? prepKfs(e.s) : null };
    if (bn === 'molang') molangBone = b;            // 脚本骨：先算（v.bv 等变量给后面用）
    else if (b.ni >= 0) bones.push(b);              // 模型里没有的骨跳过
  }
  let headScripted = false;                        // 主动画自己写了 ysm.head_* → 不再自动叠头
  const hbe = a.bones.find((x) => x[0] === 'Head'), hb = hbe ? hbe[1] : null;
  if (hb && hb.r) headScripted = JSON.stringify(hb.r).includes('ysm.head');
  return { name, len: a.len == null ? Infinity : a.len, loop: a.loop, bones, molangBone, headScripted,
    tl: (a.tl || []).map((x) => ({ t: x[0], ast: compile(x[1]) })) };
}

// ---- 时间 ----
function wrapTime(an, t) {
  if (an.loop === 1) return (isFinite(an.len) && an.len > 0) ? t % an.len : t;
  return isFinite(an.len) ? Math.min(t, an.len) : t; // 2=停最后一帧 3=播一次（同样停住）
}

// ---- 采样一个通道（3 分量），返回到 out ----
function cv(v, env) { return typeof v === 'number' ? v : ev(v, env); }
function vec(arr, env, out) { out[0] = cv(arr[0], env); out[1] = cv(arr[1], env); out[2] = cv(arr[2], env); }
const _A = [0, 0, 0], _B = [0, 0, 0], _P0 = [0, 0, 0], _P3 = [0, 0, 0];
function sample(kfs, t, env, out) {
  const n = kfs.length;
  if (t <= kfs[0].t || n === 1) { vec(kfs[0].pre || kfs[0].post, env, out); return; }
  if (t >= kfs[n - 1].t) { vec(kfs[n - 1].post, env, out); return; }
  let i = 0;
  while (i + 1 < n && kfs[i + 1].t <= t) i++;
  const a = kfs[i], b = kfs[i + 1];
  if (a.mode === 1) { vec(a.post, env, out); return; }   // 阶跃
  const f = (t - a.t) / (b.t - a.t);
  vec(a.post, env, _A); vec(b.pre || b.post, env, _B);
  if (a.mode === 2 || b.mode === 2) {                    // catmull-rom（Blockbench 同款取邻点）
    if (i > 0) vec(kfs[i - 1].post, env, _P0); else { _P0[0] = _A[0]; _P0[1] = _A[1]; _P0[2] = _A[2]; }
    if (i + 2 < n) vec(kfs[i + 2].pre || kfs[i + 2].post, env, _P3); else { _P3[0] = _B[0]; _P3[1] = _B[1]; _P3[2] = _B[2]; }
    const f2 = f * f, f3 = f2 * f;
    for (let c = 0; c < 3; c++) {
      const p0 = _P0[c], p1 = _A[c], p2 = _B[c], p3 = _P3[c];
      out[c] = 0.5 * (2 * p1 + (-p0 + p2) * f + (2 * p0 - 5 * p1 + 4 * p2 - p3) * f2 + (-p0 + 3 * p1 - 3 * p2 + p3) * f3);
    }
    return;
  }
  for (let c = 0; c < 3; c++) out[c] = _A[c] + (_B[c] - _A[c]) * f;
}

// ---- 二阶动力学（ysm.second_order(名, 目标, f, ζ, r)，t3ssel8r 经典式；同名每帧只推进一次） ----
function secondOrder(st, frame, dt, x, f, z, r) {
  if (!st.init) { st.init = true; st.xp = x; st.y = x; st.yd = 0; st.frame = frame; return st.y; }
  if (st.frame === frame || dt <= 0) return st.y;
  st.frame = frame;
  f = Math.max(f, 1e-3);
  const k1 = z / (Math.PI * f), k2 = 1 / ((2 * Math.PI * f) * (2 * Math.PI * f)), k3 = r * z / (2 * Math.PI * f);
  const xd = (x - st.xp) / dt; st.xp = x;
  const k2s = Math.max(k2, dt * dt / 2 + dt * k1 / 2, dt * k1);
  st.y += dt * st.yd;
  st.yd += dt * (x + k3 * xd - st.y - k1 * st.yd) / k2s;
  return st.y;
}

// ---- 主动画选择（YSM 内置优先级，按 0.10 可得信号裁剪） ----
function pickMain(rig, inp) {
  const s = inp.groundSpeed;
  if (s > 5.4) rig.loco = 2; else if (s < 4.6 && rig.loco === 2) rig.loco = 1;
  if (s > 0.6 && rig.loco === 0) rig.loco = 1; else if (s < 0.35) rig.loco = 0;
  const moving = rig.loco > 0;
  if (inp.dead) return 'death';
  if (inp.sleeping) return 'sleep';
  if (inp.inWater) return moving ? 'swim' : 'swim_stand';
  if (inp.flying) return 'fly';
  if (!inp.onGround) return 'jump';
  if (inp.sneaking) return moving ? 'sneak' : 'sneaking';
  if (rig.loco === 2) return 'run';
  return moving ? 'walk' : 'idle';
}

function createRig(side, parsed, sharedRoaming) {
  const { nodes, name2idx, rootSet } = parsed;
  const anims = new Map();
  for (const name in side.anims) anims.set(name, prepAnim(name, side.anims[name], name2idx));
  // 静止欧拉角（弧度）：sidecar 给；缺省按 0（GLB 四元数只做兜底不参与叠加）
  const rest = nodes.map((nd) => side.rest[nd.name] || null);
  const ctrl = side.ctrls ? side.ctrls['player.parallel_7'] : null;
  const ctrlStates = ctrl ? new Map(ctrl.states.map((s) => [s.name, {
    name: s.name, anim: s.animations[''] || Object.values(s.animations)[0] || null,
    tr: s.transitions.map(([c, to]) => ({ ast: compile(c), to })),
    entry: s.on_entry.map(compile), exit: s.on_exit.map(compile) }])) : null;
  const funcs = (side.funcs || []).map((f) => ({ name: f[0], ast: compile(f[1]) }));
  const roaming = sharedRoaming || {};               // 模型设置（v.roaming.*），页面/插件面板共用
  const rig = {
    frame: 0, life: 0, dt: 0, vars: new Map(), so: new Map(), loco: 0,
    main: 'idle', mainT: 0, prevMain: null, prevT: 0, fade: 1,
    cstate: ctrl ? ctrl.initial : null, cT: 0, inp: null, animT: 0,
    roaming, anims, nodes, rootSet, name2idx,
  };
  const env = {
    get(n) {
      if (n.startsWith('v.')) { if (n.startsWith('v.roaming.')) return roaming[n.slice(10)] ?? 0; return rig.vars.get(n); }
      if (n.startsWith('t.')) return rig.vars.get(n);
      if (n.startsWith('ctrl.')) { if (n === 'ctrl.playing_extra_animation') return 0; return rig.main === n.slice(5) ? 1 : 0; }
      const I = rig.inp || {};
      switch (n) {
        case 'q.anim_time': return rig.animT;
        case 'q.life_time': return rig.life;
        case 'q.ground_speed': return I.groundSpeed || 0;
        case 'q.vertical_speed': return I.vertSpeed || 0;
        case 'q.yaw_speed': return I.yawSpeed || 0;
        case 'q.is_on_ground': return I.onGround ? 1 : 0;
        case 'q.is_in_water': case 'q.is_in_water_or_rain': return I.inWater ? 1 : 0;
        case 'q.is_sneaking': return I.sneaking ? 1 : 0;
        case 'q.head_x_rotation': case 'ysm.head_pitch': return I.headPitch || 0;
        case 'q.head_y_rotation': case 'ysm.head_yaw': return I.headYaw || 0;
        case 'ysm.time_delta': return rig.dt;
        case 'ysm.swinging': case 'ysm.swinging_arm': return I.swinging ? 1 : 0;
        case 'ysm.has_elytra': case 'ysm.elytra_rot_z': return 0;
      }
      return undefined;
    },
    set(n, v) { if (n.startsWith('v.roaming.')) roaming[n.slice(10)] = v; else rig.vars.set(n, v); },
    call(f, args) {
      if (f === 'ysm.second_order') {
        const id = args[0] && args[0].k === 'str' ? args[0].v : '';
        let st = rig.so.get(id); if (!st) { st = {}; rig.so.set(id, st); }
        const x = ev(args[1], env), fr = args[2] ? ev(args[2], env) : 1, z = args[3] ? ev(args[3], env) : 1, r = args[4] ? ev(args[4], env) : 0;
        return secondOrder(st, rig.frame, rig.dt, x, fr, z, r);
      }
      return undefined;
    },
  };
  rig.env = env;

  // 时间轴事件：from→to 区间（含环绕）跨过的事件执行一次
  function fireTimeline(an, t0, t1) {
    if (!an || !an.tl.length) return;
    const a = wrapTime(an, t0), b = wrapTime(an, t1);
    for (const e of an.tl) {
      const hit = (b >= a) ? (e.t > a && e.t <= b) : (e.t > a || e.t <= b);
      if (hit && e.ast) ev(e.ast, env);
    }
  }

  rig.tick = function (dt, inp) {
    rig.frame++; rig.dt = dt; rig.life += dt; rig.inp = inp;
    for (const f of funcs) if (f.ast) ev(f.ast, env);            // player_update
    const want = inp.forceMain || pickMain(rig, inp);
    if (want !== rig.main && anims.has(want)) {
      rig.prevMain = rig.main; rig.prevT = rig.mainT; rig.fade = 0;
      rig.main = want; rig.mainT = 0;
    } else {
      const t0 = rig.mainT; rig.mainT += dt; fireTimeline(anims.get(rig.main), t0, rig.mainT);
    }
    rig.prevT += dt;
    rig.fade = Math.min(1, rig.fade + dt / MAIN_FADE);
    if (rig.fade > 0.999) rig.fade = 1; // 边界定死（float/double 累加落点不同会让旧主动画多跑一帧，与插件分叉）
    if (ctrlStates && rig.cstate) {                                 // parallel_7 控制器
      const st = ctrlStates.get(rig.cstate);
      if (st) {
        for (const tr of st.tr) {
          if (tr.ast && ev(tr.ast, env) !== 0 && ctrlStates.has(tr.to)) {
            st.exit.forEach((x) => x && ev(x, env));
            rig.cstate = tr.to; rig.cT = 0;
            ctrlStates.get(tr.to).entry.forEach((x) => x && ev(x, env));
            break;
          }
        }
      }
      const cur = ctrlStates.get(rig.cstate);
      const t0 = rig.cT; rig.cT += dt;
      if (cur && cur.anim) fireTimeline(anims.get(cur.anim), t0, rig.cT);
    }
  };

  // ---- 层求值：结果写入 R/P/S（每节点 3 分量）+ 标记 ----
  const N = nodes.length;
  const R = new Float32Array(N * 3), P = new Float32Array(N * 3), S = new Float32Array(N * 3);
  const hasR = new Uint8Array(N), hasP = new Uint8Array(N), hasS = new Uint8Array(N);
  const tmp = [0, 0, 0];
  function applyAnim(an, t, w) { // w<1 只给主动画淡入用：与已有值（或静止）插值
    if (!an) return;
    rig.animT = wrapTime(an, t);
    const tt = rig.animT;
    if (an.molangBone) { const mb = an.molangBone; if (mb.r) sample(mb.r, tt, env, tmp); if (mb.p) sample(mb.p, tt, env, tmp); if (mb.s) sample(mb.s, tt, env, tmp); }
    for (const b of an.bones) {
      const o = b.ni * 3;
      if (b.r) { sample(b.r, tt, env, tmp); put(R, hasR, b.ni, o, tmp, w, 0); }
      if (b.p) { sample(b.p, tt, env, tmp); put(P, hasP, b.ni, o, tmp, w, 0); }
      if (b.s) { sample(b.s, tt, env, tmp); put(S, hasS, b.ni, o, tmp, w, 1); }
    }
  }
  function put(arr, has, ni, o, v, w, def) {
    if (w >= 1) { arr[o] = v[0]; arr[o + 1] = v[1]; arr[o + 2] = v[2]; has[ni] = 1; return; }
    const b0 = has[ni] ? arr[o] : def, b1 = has[ni] ? arr[o + 1] : def, b2 = has[ni] ? arr[o + 2] : def;
    arr[o] = b0 + (v[0] - b0) * w; arr[o + 1] = b1 + (v[1] - b1) * w; arr[o + 2] = b2 + (v[2] - b2) * w; has[ni] = 1;
  }

  rig.pose = function () {
    hasR.fill(0); hasP.fill(0); hasS.fill(0);
    const L = rig.life;
    for (let i = 0; i < 8; i++) applyAnim(anims.get('pre_parallel' + i), L, 1);
    // 主动画：淡入期先铺旧主动画，再按权重盖新主动画
    if (rig.fade < 1 && rig.prevMain) applyAnim(anims.get(rig.prevMain), rig.prevT, 1);
    const mainAn = anims.get(rig.main);
    applyAnim(mainAn, rig.mainT, rig.fade < 1 && rig.prevMain ? rig.fade : 1);
    for (let i = 0; i < 7; i++) applyAnim(anims.get('parallel' + i), L, 1);
    if (ctrlStates && rig.cstate) {
      const cur = ctrlStates.get(rig.cstate);
      if (cur && cur.anim) applyAnim(anims.get(cur.anim), rig.cT, 1);
    } else applyAnim(anims.get('parallel7'), L, 1);
    // 头随视角（主动画没自己写 ysm.head_* 时）
    const hi = name2idx.get('Head');
    if (hi != null && !(mainAn && mainAn.headScripted) && rig.inp) {
      const o = hi * 3;
      if (!hasR[hi]) { R[o] = R[o + 1] = R[o + 2] = 0; hasR[hi] = 1; }
      R[o] += rig.inp.headPitch || 0; R[o + 1] += rig.inp.headYaw || 0;
    }
    // 局部矩阵 → 世界矩阵
    const world = new Float32Array(N * 16), hidden = new Array(N).fill(false);
    for (const ni of rootSet) {
      const nd = nodes[ni], o = ni * 3, m = world.subarray(ni * 16, ni * 16 + 16);
      const rs = rest[ni] || [0, 0, 0];
      let rx = rs[0], ry = rs[1], rz = rs[2];
      if (hasR[ni]) { rx += -R[o] * D2R; ry += -R[o + 1] * D2R; rz += R[o + 2] * D2R; }
      let tx = nd.t[0], ty = nd.t[1], tz = nd.t[2];
      if (hasP[ni]) { tx += -P[o] / 16; ty += P[o + 1] / 16; tz += P[o + 2] / 16; }
      let sx = 1, sy = 1, sz = 1;
      if (hasS[ni]) { sx = S[o]; sy = S[o + 1]; sz = S[o + 2]; hidden[ni] = Math.abs(sx) < 1e-3 || Math.abs(sy) < 1e-3 || Math.abs(sz) < 1e-3; }
      eulerMat(rx, ry, rz, tx, ty, tz, sx, sy, sz, m);
    }
    const rootIdx = name2idx.has('Root') ? name2idx.get('Root') : rootSet[0];
    const dfs = [], st = [rootIdx];
    while (st.length) { const c = st.pop(); dfs.push(c); nodes[c].children.forEach((k) => st.push(k)); }
    const W = new Float32Array(16);
    for (let di = 1; di < dfs.length; di++) {
      const ni = dfs[di], pi = nodes[ni].parent;
      mul(world.subarray(pi * 16, pi * 16 + 16), world.subarray(ni * 16, ni * 16 + 16), W);
      world.set(W, ni * 16);
    }
    const visOK = new Array(N).fill(false);
    visOK[rootIdx] = !hidden[rootIdx];
    for (let di = 1; di < dfs.length; di++) { const ni = dfs[di]; visOK[ni] = visOK[nodes[ni].parent] && !hidden[ni]; }
    let shown = 0; for (const ni of rootSet) if (visOK[ni] && nodes[ni].mesh >= 0) shown++;
    return { world, hidden, visOK, dfs, rootIdx, shown, total: rootSet.length, animFound: !!mainAn, main: rig.main, ctrl: rig.cstate };
  };
  return rig;
}

// local = T·Rz·Ry·Rx·S（列主序）
function eulerMat(rx, ry, rz, tx, ty, tz, sx, sy, sz, m) {
  const cx = Math.cos(rx), sxn = Math.sin(rx), cy = Math.cos(ry), syn = Math.sin(ry), cz = Math.cos(rz), szn = Math.sin(rz);
  m[0] = cz * cy * sx; m[1] = szn * cy * sx; m[2] = -syn * sx; m[3] = 0;
  m[4] = (cz * syn * sxn - szn * cx) * sy; m[5] = (szn * syn * sxn + cz * cx) * sy; m[6] = cy * sxn * sy; m[7] = 0;
  m[8] = (cz * syn * cx + szn * sxn) * sz; m[9] = (szn * syn * cx - cz * sxn) * sz; m[10] = cy * cx * sz; m[11] = 0;
  m[12] = tx; m[13] = ty; m[14] = tz; m[15] = 1;
}
function mul(a, b, o) {
  for (let c = 0; c < 4; c++) for (let r = 0; r < 4; r++)
    o[c * 4 + r] = a[r] * b[c * 4] + a[4 + r] * b[c * 4 + 1] + a[8 + r] * b[c * 4 + 2] + a[12 + r] * b[c * 4 + 3];
}

export { createRig, sample, secondOrder, eulerMat, wrapTime };
