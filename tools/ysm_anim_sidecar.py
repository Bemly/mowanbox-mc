#!/usr/bin/env python3
"""YSM 动画全量 sidecar：fatfish_anim.json（取代只含 scale 的 fatfish_vis.json）。
输入：ysm_parse.py 的输出目录（anims_main.pkl / model_type1.pkl / summary.json）＋ 解密载荷（抽函数源码）。
内容：
  rest      骨骼静止欧拉角（弧度，YSM 几何原值；GLB 里只存了四元数，运行时要在欧拉空间叠加动画）
  anims     每个动画 {len(无穷→null), loop, bones:[[骨, {r,p,s}]...], tl:[[t, 脚本]]}
            bones 用有序数组：同名 ysm.second_order 每帧只推进一次、先调者定值，求值顺序必须保持 YSM 原序
            （NSJSONSerialization 字典无序，用对象会让插件与 web 分叉）
            关键帧 [t, mode(0线性/1阶跃/2catmullrom), pre|null, post]，分量为数字或 molang 原文
  ctrls     动画控制器（parallel_7 等；transitions 转成有序 [[条件, 目标]...]）
  funcs     player_update 函数 [[名, 源码]]（维护 v.fall_timer / v.timer）
  settings  模型设置面板（与 fatfish_vis.json 同格式）
用法：python3 ysm_anim_sidecar.py <parse目录> <decrypted.bin> [输出路径]
     （与 viewer 的 tools/ysm_parse.py 放同目录跑，函数源码靠它的读取器）
"""
import json, os, pickle, sys


def kf_list(kfs):
    return [[k['t'], k['mode'], k['pre'], k['post']] for k in kfs]


def read_funcs(bin_path):
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    try:
        import ysm_parse as P
    except ImportError:
        print('找不到 ysm_parse.py，funcs 留空')
        return []
    r = P.R(open(bin_path, 'rb').read())
    r.u32()
    for _ in range(r.varint()):
        r.string(); r.string(); r.bytearray()
    out = []
    for _ in range(r.varint()):
        nm = r.string(); r.string(); d = r.bytearray()
        out.append([nm, d.decode('utf-8', 'replace')])
    return out


def main():
    wd, binp = sys.argv[1], sys.argv[2]
    outp = sys.argv[3] if len(sys.argv) > 3 else os.path.join(wd, 'fatfish_anim.json')
    anims = pickle.load(open(os.path.join(wd, 'anims_main.pkl'), 'rb'))['animations']
    geo = pickle.load(open(os.path.join(wd, 'model_type1.pkl'), 'rb'))['geo']
    summ = json.load(open(os.path.join(wd, 'summary.json')))
    out = {'rest': {}, 'anims': {}, 'ctrls': {}, 'funcs': read_funcs(binp), 'settings': []}
    for b in geo['bones']:
        out['rest'][b['name']] = [float(x) for x in b['rotation']]
    for name, a in anims.items():
        bones = []
        for bn, ch in a['bones'].items():
            e = {}
            for key, src in (('r', 'rotation'), ('p', 'position'), ('s', 'scale')):
                if ch[src]:
                    e[key] = kf_list(ch[src])
            if e:
                bones.append([bn, e])
        ln = a['length']
        out['anims'][name] = {
            'len': ln if ln != float('inf') and ln == ln else None,
            'loop': a['loop'], 'bones': bones,
            'tl': [[t['t'], ''.join(t['events'])] for t in a['timeline']],
        }
    for f in summ.get('controllers', []):
        for cn, c in f['controllers'].items():
            for st in c['states']:
                st['transitions'] = [[k, v] for k, v in st['transitions'].items()]
            out['ctrls'][cn] = c
    for b in summ['props'].get('buttons', []):
        forms = []
        for f in b['forms']:
            d = f.get('default', '')
            forms.append({'type': f['type'], 'title': f['title'], 'var': d[2:] if d.startswith('v.') else d,
                          'min': f['min'], 'max': f['max'], 'step': f['step'], 'labels': f.get('labels', {})})
        out['settings'].append({'id': b['id'], 'name': b['name'], 'forms': forms})
    json.dump(out, open(outp, 'w'), ensure_ascii=False, separators=(',', ':'))
    nmol = sum(1 for a in out['anims'].values() for _, e in a['bones'] for ks in e.values()
               for k in ks for v in (k[3] or []) + (k[2] or []) if isinstance(v, str))
    print('动画=%d 骨骼=%d 控制器=%d 函数=%d molang值=%d 字节=%d' % (
        len(out['anims']), len(out['rest']), len(out['ctrls']), len(out['funcs']), nmol, os.path.getsize(outp)))


if __name__ == '__main__':
    main()
