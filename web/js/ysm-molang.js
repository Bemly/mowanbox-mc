// web/js/ysm-molang.js — molang 完整子集（YSM 动画运行时用），逐行对应 MWBYSMMolang.mm
// 相比旧 plugin-molang.js（只够 scale 显隐）补齐：
//  - 语句：`;` 分隔、`return x`、赋值 `v.x = …`（v/variable/t/temp），`//` 行注释
//  - 运算：`??`（左值未定义取右）、`a ? b`（无 else 回 0）、`a ? b : c`、比较/逻辑/算术、一元 ! -
//  - math.* 三角按角度（Bedrock 规定；旧实现按弧度是错的），另有 clamp/lerp/min/max/abs/pow/sqrt/floor/ceil/round/mod/trunc/exp/ln/random/pi
//  - 名字大小写不敏感，前缀统一：query.→q. variable.→v. temp.→t. context.→c.
//  - 未知查询/函数交给宿主 env.get(name) / env.call(name, args)，返回 undefined 视为“未定义”（?? 用）
'use strict';

function normName(s) {
  s = s.toLowerCase();
  if (s.startsWith('query.')) return 'q.' + s.slice(6);
  if (s.startsWith('variable.')) return 'v.' + s.slice(9);
  if (s.startsWith('temp.')) return 't.' + s.slice(5);
  if (s.startsWith('context.')) return 'c.' + s.slice(8);
  return s;
}

// ---- 分词 ----
function tokenize(src) {
  const toks = [];
  let i = 0;
  const L = src.length;
  const isDigit = (c) => c >= '0' && c <= '9';
  const isAlpha = (c) => (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c === '_';
  while (i < L) {
    const c = src[i];
    if (c === ' ' || c === '\t' || c === '\n' || c === '\r') { i++; continue; }
    if (c === '/' && src[i + 1] === '/') { while (i < L && src[i] !== '\n') i++; continue; }
    if (c === "'") {
      let j = i + 1;
      while (j < L && src[j] !== "'") j++;
      toks.push({ t: 'str', v: src.slice(i + 1, j) }); i = j + 1; continue;
    }
    if (isDigit(c) || (c === '.' && isDigit(src[i + 1] || ''))) {
      let j = i;
      while (j < L && (isDigit(src[j]) || src[j] === '.')) j++;
      if (j < L && (src[j] === 'e' || src[j] === 'E')) {
        j++; if (src[j] === '+' || src[j] === '-') j++;
        while (j < L && isDigit(src[j])) j++;
      }
      if (src[j] === 'f' || src[j] === 'F') { toks.push({ t: 'num', v: parseFloat(src.slice(i, j)) }); i = j + 1; continue; }
      toks.push({ t: 'num', v: parseFloat(src.slice(i, j)) }); i = j; continue;
    }
    if (isAlpha(c)) {
      let j = i;
      while (j < L && (isAlpha(src[j]) || isDigit(src[j]) || src[j] === '.')) j++;
      toks.push({ t: 'id', v: src.slice(i, j) }); i = j; continue;
    }
    const two = src.substr(i, 2);
    if (['==', '!=', '<=', '>=', '&&', '||', '??', '->'].includes(two)) { toks.push({ t: 'op', v: two }); i += 2; continue; }
    if ('+-*/%()<>,!?:;={}[]'.includes(c)) { toks.push({ t: 'op', v: c }); i++; continue; }
    throw new Error('molang 非法字符 ' + c);
  }
  return toks;
}

// ---- 解析为 AST ----
// 节点：{k:'num',v} {k:'str',v} {k:'var',n} {k:'call',n,a:[]} {k:'un',op,a} {k:'bin',op,a,b}
//      {k:'tern',a,b,c|null} {k:'set',n,a} {k:'seq',s:[], ret:bool}
function parse(src) {
  const t = tokenize(src);
  let p = 0;
  const peek = (v) => p < t.length && t[p].t === 'op' && t[p].v === v;
  const eat = (v) => { if (!peek(v)) throw new Error('molang 期望 ' + v); p++; };
  function prim() {
    const k = t[p];
    if (!k) throw new Error('molang 意外结尾');
    if (k.t === 'num') { p++; return { k: 'num', v: k.v }; }
    if (k.t === 'str') { p++; return { k: 'str', v: k.v }; }
    if (k.t === 'id') {
      p++;
      const n = normName(k.v);
      if (n === 'true') return { k: 'num', v: 1 };
      if (n === 'false') return { k: 'num', v: 0 };
      if (n === 'math.pi') return { k: 'num', v: Math.PI };
      if (peek('(')) {
        p++;
        const a = [];
        if (!peek(')')) { a.push(expr()); while (peek(',')) { p++; a.push(expr()); } }
        eat(')');
        return { k: 'call', n, a };
      }
      return { k: 'var', n };
    }
    if (peek('(')) { p++; const e = expr(); eat(')'); return e; }
    throw new Error('molang 意外记号 ' + k.v);
  }
  function un() {
    if (peek('!') || peek('-')) { const op = t[p++].v; return { k: 'un', op, a: un() }; }
    if (peek('+')) { p++; return un(); }
    return prim();
  }
  function bin(sub, ops) {
    return () => {
      let l = sub();
      while (p < t.length && t[p].t === 'op' && ops.includes(t[p].v)) { const op = t[p++].v; l = { k: 'bin', op, a: l, b: sub() }; }
      return l;
    };
  }
  const mul = bin(un, ['*', '/', '%']);
  const add = bin(mul, ['+', '-']);
  const cmp = bin(add, ['<', '>', '<=', '>=']);
  const eq = bin(cmp, ['==', '!=']);
  const and = bin(eq, ['&&']);
  const or = bin(and, ['||']);
  function coal() { // ?? 右结合，优先级低于 ||
    const l = or();
    if (peek('??')) { p++; return { k: 'bin', op: '??', a: l, b: coal() }; }
    return l;
  }
  function tern() {
    const c = coal();
    if (peek('?')) {
      p++;
      const b = tern();
      if (peek(':')) { p++; return { k: 'tern', a: c, b, c: tern() }; }
      return { k: 'tern', a: c, b, c: null };
    }
    return c;
  }
  function assign() {
    // 赋值：左边必须是 v./t. 变量
    if (t[p] && t[p].t === 'id' && t[p + 1] && t[p + 1].t === 'op' && t[p + 1].v === '=') {
      const n = normName(t[p].v);
      p += 2;
      return { k: 'set', n, a: assign() };
    }
    return tern();
  }
  function expr() { return assign(); }
  // 语句序列
  const s = [];
  let hasSemi = false, ret = false;
  while (p < t.length) {
    if (peek(';')) { p++; hasSemi = true; continue; }
    if (t[p].t === 'id' && t[p].v.toLowerCase() === 'return') { p++; s.push({ k: 'ret', a: expr() }); ret = true; continue; }
    s.push(expr());
  }
  if (s.length === 1 && !hasSemi && !ret) return s[0];
  return { k: 'seq', s };
}

// ---- 求值 ----
// env: { get(n) → number|undefined, set(n, v), call(n, args:number[], rawArgs:AST[]) → number|undefined }
function ev(n, env) {
  switch (n.k) {
    case 'num': return n.v;
    case 'str': return 0;
    case 'var': { const v = env.get(n.n); return v === undefined ? 0 : v; }
    case 'set': { const v = ev(n.a, env); env.set(n.n, v); return v; }
    case 'un': { const v = ev(n.a, env); return n.op === '!' ? (v === 0 ? 1 : 0) : -v; }
    case 'tern': return ev(n.a, env) !== 0 ? ev(n.b, env) : (n.c ? ev(n.c, env) : 0);
    case 'bin': {
      if (n.op === '??') {
        if (n.a.k === 'var') { const v = env.get(n.a.n); return v === undefined ? ev(n.b, env) : v; }
        return ev(n.a, env);
      }
      if (n.op === '&&') return (ev(n.a, env) !== 0 && ev(n.b, env) !== 0) ? 1 : 0;
      if (n.op === '||') return (ev(n.a, env) !== 0 || ev(n.b, env) !== 0) ? 1 : 0;
      const l = ev(n.a, env), r = ev(n.b, env);
      switch (n.op) {
        case '+': return l + r; case '-': return l - r; case '*': return l * r;
        case '/': return r === 0 ? 0 : l / r;
        case '%': return r === 0 ? 0 : l % r;
        case '<': return l < r ? 1 : 0; case '>': return l > r ? 1 : 0;
        case '<=': return l <= r ? 1 : 0; case '>=': return l >= r ? 1 : 0;
        case '==': return l === r ? 1 : 0; case '!=': return l !== r ? 1 : 0;
      }
      return 0;
    }
    case 'call': return callFn(n, env);
    case 'ret': return ev(n.a, env);
    case 'seq': {
      let last = 0;
      for (const st of n.s) { last = ev(st, env); if (st.k === 'ret') return last; }
      return last;
    }
  }
  return 0;
}

const D2R = Math.PI / 180;
function callFn(n, env) {
  const f = n.n;
  if (f.startsWith('math.')) {
    const a = n.a.map((x) => ev(x, env));
    switch (f.slice(5)) {
      case 'sin': return Math.sin(a[0] * D2R);
      case 'cos': return Math.cos(a[0] * D2R);
      case 'asin': return Math.asin(a[0]) / D2R;
      case 'acos': return Math.acos(a[0]) / D2R;
      case 'atan': return Math.atan(a[0]) / D2R;
      case 'atan2': return Math.atan2(a[0], a[1]) / D2R;
      case 'abs': return Math.abs(a[0]);
      case 'clamp': return Math.min(a[2], Math.max(a[1], a[0]));
      case 'lerp': return a[0] + (a[1] - a[0]) * a[2];
      case 'min': return Math.min(...a);
      case 'max': return Math.max(...a);
      case 'pow': return Math.pow(a[0], a[1]);
      case 'sqrt': return Math.sqrt(a[0]);
      case 'floor': return Math.floor(a[0]);
      case 'ceil': return Math.ceil(a[0]);
      case 'round': return Math.round(a[0]);
      case 'trunc': return Math.trunc(a[0]);
      case 'mod': return a[1] === 0 ? 0 : a[0] % a[1];
      case 'exp': return Math.exp(a[0]);
      case 'ln': return Math.log(a[0]);
      case 'random': return a[0] + Math.random() * (a[1] - a[0]);
      case 'random_integer': return Math.round(a[0] + Math.random() * (a[1] - a[0]));
      case 'hermite_blend': return 3 * a[0] * a[0] - 2 * a[0] * a[0] * a[0];
    }
    return 0;
  }
  const v = env.call ? env.call(f, n.a, env) : undefined;
  return v === undefined ? 0 : v;
}

// 编译缓存：字符串 → AST（失败记 null，日志一次）
const cache = new Map();
function compile(src) {
  if (cache.has(src)) return cache.get(src);
  let ast = null;
  try { ast = parse(src); } catch (e) { console.warn('[molang] 解析失败', src, e.message); }
  cache.set(src, ast);
  return ast;
}
function run(src, env) { const a = typeof src === 'string' ? compile(src) : src; return a ? ev(a, env) : 0; }

export { normName, tokenize, parse, ev, compile, run };
