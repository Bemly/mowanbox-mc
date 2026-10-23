// web/js/plugin-molang.js — molang 子集求值，逐行对应 MWBGLBMolang.mm
// 对应关系：MTokenize→tokenize / MPrim..MTern→parse / MEval→evalNode / MWBMolangValue→molVal
// 语义与 viewer index.html 同款（只够 scale 显隐表达式），差异处已标 PLUGIN：
'use strict';

// ---- 分词（对应 MTokenize，规则与 viewer tokenize 一致） ----
function tokenize(s) {
  const toks = [];
  let i = 0;
  const L = s.length;
  const isSpace = (c) => /\s/.test(c);
  const isDigit = (c) => c >= '0' && c <= '9';
  const isAlpha = (c) => (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c === '_';
  const isIdC = (c) => isAlpha(c) || isDigit(c) || c === '.';
  while (i < L) {
    const c = s[i];
    if (isSpace(c)) { i++; continue; }
    if (c === "'") { // 单引号串（当 0）
      let j = i + 1, v = '';
      while (j < L && s[j] !== "'") v += s[j++];
      toks.push({ t: 'str', v }); i = (j < L) ? j + 1 : j; continue;
    }
    if (isDigit(c) || (c === '.' && i + 1 < L && isDigit(s[i + 1]))) {
      let j = i;
      while (j < L && (isDigit(s[j]) || s[j] === '.' || s[j] === 'e' || s[j] === 'E')) j++;
      // e/E 后面的符号只在紧跟 e/E 时吃掉（与 viewer /[eE]/ 判定一致，对应 mm 58-64 行）
      if (j < L && (s[j] === '+' || s[j] === '-') && j > i && (s[j - 1] === 'e' || s[j - 1] === 'E')) {
        j++;
        while (j < L && isDigit(s[j])) j++;
      }
      toks.push({ t: 'num', v: parseFloat(s.slice(i, j)) }); i = j; continue;
    }
    if (isAlpha(c)) {
      let j = i, v = '';
      while (j < L && isIdC(s[j])) v += s[j++];
      toks.push({ t: 'id', v }); i = j; continue;
    }
    const two = s.substr(i, 2);
    if (['==', '!=', '<=', '>=', '&&', '||'].includes(two)) { toks.push({ t: 'op', v: two }); i += 2; continue; }
    if ('+-*/%()<>,!?:'.includes(c)) { toks.push({ t: 'op', v: c }); i++; continue; }
    throw new Error('bad char: ' + c); // 对应 MTokenize 返回 -1（mm 98-99 行）
  }
  return toks;
}

// ---- 递归下降（对应 MPrim/MUn/MBin/MAdd/MMul/MCmp/MEq/MAnd/MOr/MTern，优先级与 viewer parseMolang 同） ----
function parseMolang(s) {
  const T = tokenize(s);
  let p = 0;
  const peek = () => T[p];
  const peekIs = (op) => p < T.length && T[p].t === 'op' && T[p].v === op;
  function prim() {
    const t = T[p++];
    if (!t) throw new Error('eof');
    if (t.t === 'num') return { k: 'n', v: t.v }; // MN_NUM
    if (t.t === 'str') return { k: 's', v: t.v }; // MN_STR
    if (t.t === 'id') {
      if (peekIs('(')) {
        p++;
        const a = [];
        if (!peekIs(')')) { a.push(expr()); while (peekIs(',')) { p++; a.push(expr()); } }
        if (!peekIs(')')) throw new Error('expect )');
        p++;
        return { k: 'c', f: t.v, a }; // MN_CALL
      }
      return { k: 'v', v: t.v }; // MN_VAR
    }
    if (t.t === 'op' && t.v === '(') { const e = expr(); if (!peekIs(')')) throw new Error('expect )'); p++; return e; }
    throw new Error('unexpected token');
  }
  function un() {
    if (peekIs('!') || peekIs('-')) { const o = T[p++].v; return { k: 'u', o, v: un() }; }
    return prim();
  }
  function bin(sub, ops) {
    let l = sub();
    for (;;) {
      const t = peek();
      if (!t || t.t !== 'op' || !ops.includes(t.v)) return l;
      const o = t.v; p++;
      l = { k: 'b', o, l, r: sub() };
    }
  }
  const mul = () => bin(un, ['*', '/', '%']);
  const add = () => bin(mul, ['+', '-']);
  const cmp = () => bin(add, ['<', '>', '<=', '>=']);
  const eq = () => bin(cmp, ['==', '!=']);
  const and = () => bin(eq, ['&&']);
  const or = () => bin(and, ['||']);
  function tern() {
    const c = or();
    if (peekIs('?')) { p++; const a = expr(); if (!peekIs(':')) throw new Error('expect :'); p++; const b = tern(); return { k: 't', c, a, b }; }
    return c;
  }
  function expr() { return tern(); }
  const r = expr();
  if (p < T.length) throw new Error('trailing tokens'); // 对应 mm 293 行尾随词作废
  return r;
}

// ---- 求值（对应 MEval，与 viewer evalMol 同语义） ----
const MATHF = {
  clamp: (v, a, b) => Math.min(b, Math.max(a, v)),
  cos: Math.cos, sin: Math.sin, lerp: (a, b, c) => a + (b - a) * c,
  abs: Math.abs, sqrt: Math.sqrt, floor: Math.floor, ceil: Math.ceil,
  pow: Math.pow, min: Math.min, max: Math.max,
  // PLUGIN 注：mm 只实现 clamp/cos/sin/lerp/abs/sqrt/floor/ceil/pow/min/max，
  // viewer 多一个 pi()，插件侧无，移植页以插件为准（pi 回 0）。
};
function evalNode(n, env) {
  if (!n) return 0;
  switch (n.k) {
    case 'n': return n.v;
    case 's': return 0; // 单引号串当 0
    case 'v': {
      const v = n.v;
      if (v.startsWith('v.roaming.')) return env.roaming[v.slice(10)] ?? 0;
      if (v === 'query.anim_time' || v === 'query.life_time') return env.t;
      return 0; // 其余 query/variable/v/c/t/ysm 全回 0
    }
    case 'c': {
      if (!n.f.startsWith('math.')) return 0;
      const f = MATHF[n.f.slice(5)];
      if (typeof f !== 'function') return 0;
      return f(...n.a.map((a) => evalNode(a, env)));
    }
    case 'u': { const v = evalNode(n.v, env); return n.o === '!' ? (v === 0 ? 1 : 0) : -v; }
    case 'b': {
      const l = evalNode(n.l, env), r = evalNode(n.r, env);
      switch (n.o) {
        case '+': return l + r; case '-': return l - r; case '*': return l * r;
        case '/': return r === 0 ? 0 : l / r;
        case '%': return r === 0 ? 0 : l % r;
        case '==': return l === r ? 1 : 0; case '!=': return l !== r ? 1 : 0;
        case '<': return l < r ? 1 : 0; case '>': return l > r ? 1 : 0;
        case '<=': return l <= r ? 1 : 0; case '>=': return l >= r ? 1 : 0;
        case '&&': return (l !== 0 && r !== 0) ? 1 : 0;
        case '||': return (l !== 0 || r !== 0) ? 1 : 0;
      }
      return 0;
    }
    case 't': return evalNode(n.c, env) !== 0 ? evalNode(n.a, env) : evalNode(n.b, env);
  }
  return 0;
}

const molCache = new Map(); // 对应 mm 的 cache（失败记 null，不反复抛错）
function molParse(s) {
  if (molCache.has(s)) return molCache.get(s);
  try { const r = parseMolang(s); molCache.set(s, r); return r; }
  catch (e) { molCache.set(s, null); return null; }
}
// 对应 MWBMolangValue：数字直回 / 字符串求值 / 其余回 0
function molVal(expr, env) {
  if (typeof expr === 'number') return expr;
  if (typeof expr !== 'string') return 0;
  const ast = molParse(expr);
  if (!ast) return 0;
  try { return evalNode(ast, env); } catch (e) { return 0; }
}

export { tokenize, parseMolang, evalNode, molVal, molParse, MATHF };
