// tools/fishconv.mjs — YSM/geo.json → 烘焙 C 数组（一次性转换，勿在设备上跑）
// 用法：node tools/fishconv.mjs <main.json> <out前缀> [骨上限]
// 骨上限带父级闭包：只保留前 N 个骨，父被砍掉的挂到根（-1），保证无孤儿。
import fs from 'fs';
const [jsonPath, outPrefix, limitArg] = process.argv.slice(2);
if (!jsonPath || !outPrefix) { console.error('用法：node tools/fishconv.mjs <main.json> <out前缀> [骨上限]'); process.exit(1); }
const limit = limitArg ? parseInt(limitArg) : -1;
const SCALE = 1;
const g = (arr) => arr.map((v) => f(v * SCALE)); // 整体放大（坐标/尺寸/轴心同乘，旋转/UV不动）
const j = JSON.parse(fs.readFileSync(jsonPath, 'utf8'));
const bones = j['minecraft:geometry'][0].bones;
const idx = new Map(bones.map((b, i) => [b.name, i]));
const keep = new Set();
if (process.env.FISHMODE === 'single' && limit > 0) {
  // 单个首个带盒骨，父强制 -1，无子无递归（定位递归/层级嫌疑）
  for (let i = 0; i < bones.length && keep.size < limit; i++) {
    if ((bones[i].cubes || []).length) keep.add(i);
  }
} else if (process.env.FISHMODE === 'cubed' && limit > 0) {
  // 前 limit 个带盒骨 + 全部祖先（保证看得见东西且不断链）
  const addAnc = (i) => { let g = i; while (g >= 0 && !keep.has(g)) { keep.add(g); const p = bones[g].parent; g = p ? (idx.get(p) ?? -1) : -1; } };
  let n = 0;
  for (let i = 0; i < bones.length && n < limit; i++) {
    if ((bones[i].cubes || []).length) { addAnc(i); n++; }
  }
} else if (process.env.FISHMODE === 'avatar') {
  // 穿戴体：砍场景件（Gui/Brand/电饭煲/雨滴/武器/鞘翅）连带整棵子树，保证无孤儿错位
  const rx = /Gui|Rainfall|raindrop|^molang$/i;
  const drop = new Set();
  const isDrop = (i) => {
    if (drop.has(i)) return true;
    const b = bones[i];
    if (rx.test(b.name)) { drop.add(i); return true; }
    if (b.parent) { const p = idx.get(b.parent); if (p !== undefined && isDrop(p)) { drop.add(i); return true; } }
    return false;
  };
  bones.forEach((_, i) => { if (!isDrop(i)) keep.add(i); });
} else {
  for (let i = 0; i < bones.length && (limit < 0 || keep.size < limit); i++) keep.add(i);
}
const f = (n) => (typeof n !== 'number' || !isFinite(n)) ? '0' : (+n.toFixed(4)).toString();
const par = (b) => {
  if (!b.parent) return -1;
  const p = idx.get(b.parent);
  return (p === undefined || !keep.has(p)) ? -1 : p;
};
let h = '// ' + outPrefix + '.h — 烘焙几何（机器生成，勿手改，用 tools/fishconv.mjs 重生）\n#pragma once\n';
h += 'extern const int MWBFishBoneCount;\nextern const int MWBFishBoneParent[];\nextern const float MWBFishBonePivot[][3];\nextern const float MWBFishBoneRot[][3];\nextern const int MWBFishCubeCount;\nextern const int MWBFishCubeBone[];\nextern const float MWBFishCubeOrigin[][3];\nextern const float MWBFishCubeSize[][3];\n';
let c = '// ' + outPrefix + '.c — 烘焙几何数据（机器生成，勿手改）\n#include "' + outPrefix.split('/').pop() + '.h"\n';
const kb = bones.filter((_, i) => keep.has(i));
const newIdx = new Map(kb.map((b, i) => [b.name, i]));
// 0.10 part 轴心/盒子坐标都是相对父骨的，Bedrock 给的是模型绝对值，此处烘焙成相对值。
// rel_pivot = abs - parent_abs（根保持原样）；cube origin 减去所在骨的绝对轴心。
const absPiv = kb.map((b) => (b.pivot || [0,0,0]).slice());
const relPiv = kb.map((b, ni) => {
  const p = newIdx.get(b.parent);
  if (p === undefined) return absPiv[ni];
  return [0,1,2].map((k) => absPiv[ni][k] - absPiv[p][k]);
});
c += 'const int MWBFishBoneCount = ' + kb.length + ';\n';
c += 'const int MWBFishBoneParent[] = {' + kb.map((b) => {
  if (!b.parent) return -1;
  const p = newIdx.get(b.parent);
  return p === undefined ? -1 : p;
}).join(',') + '};\n';
c += 'const float MWBFishBonePivot[][3] = {' + kb.map((b) => '{' + g(relPiv[kb.indexOf(b)]).join(',') + '}').join(',') + '};\n';
const D2R = Math.PI/180;
c += 'const float MWBFishBoneRot[][3] = {' + kb.map((b) => '{' + (b.rotation || [0,0,0]).map((v) => f(v*D2R)).join(',') + '}').join(',') + '};\n';
let cb = 0;
const cBone = [], cOrg = [], cSize = [];
kb.forEach((b, ni) => {
  const bp = absPiv[ni];
  for (const cu of (b.cubes || [])) {
    cu.origin = [0,1,2].map((k) => cu.origin[k] - bp[k]);
    // 原生零盒跳过；其余截断后夹到 ≥1（0.45 薄片留 1 保形状，0.10 整数盒子下限）
    if (cu.size[0] === 0 || cu.size[1] === 0 || cu.size[2] === 0) continue;
    cu.size = cu.size.map((v) => Math.max(1, Math.trunc(v)));
    const td = cu.size;
    cb++; cBone.push(ni); cOrg.push('{' + g(cu.origin).join(',') + '}'); cSize.push('{' + g(cu.size).join(',') + '}'); }
});
c += 'const int MWBFishCubeCount = ' + cb + ';\n';
c += 'const int MWBFishCubeBone[] = {' + cBone.join(',') + '};\n';
c += 'const float MWBFishCubeOrigin[][3] = {' + cOrg.join(',') + '};\n';
c += 'const float MWBFishCubeSize[][3] = {' + cSize.join(',') + '};\n';
fs.writeFileSync(outPrefix + '.h', h);
fs.writeFileSync(outPrefix + '.c', c);
const jb = kb.map((b, ni) => ({name: b.name, parent: (() => { const p = newIdx.get(b.parent); return p === undefined ? -1 : p; })(), pivot: relPiv[ni], rot: (b.rotation || [0,0,0])}));
const jc = [];
kb.forEach((b, ni) => { for (const cu of (b.cubes || [])) { const t = cu.size.map((v) => Math.trunc(v)); if (t[0] <= 0 || t[1] <= 0 || t[2] <= 0) continue; jc.push({bone: ni, o: cu.origin, s: cu.size, uv: cu.uv}); } });
fs.writeFileSync(outPrefix + '.json', JSON.stringify({bones: jb, cubes: jc}));
console.log('bones=' + kb.length + ' cubes=' + cb);
