#!/usr/bin/env python3
# tools/bake_fatfish.py — 大肥鱼 YSM 烘焙为 C 数组（离线跑，不上设备）
# 用法：python3 tools/bake_fatfish.py /tmp/fatfish <out目录>
# 输入：ysm_parse.py 产出的 model_type1.pkl + tex_white.png（512）
# 输出：MWBFatFishData.h/.c（local/ 下，gitignore，不提交）+ fatfish_baked.json（浏览器 viewer 用）
# 约定（中文注释）：
# - 只取 Root 子树（431 骨/1745 盒），Gui/Pattern2/riceCooker 菜单件不烘焙
# - 骨 pivot/rot 用 pkl 原值（Bedrock 单位，弧度），与 GLB viewer 绑定姿势同源，不翻转
#  （注：MWBYSMCodec 运行期路径做 -px/-rx,-ry，烘焙走 Skin4D/鱼路径用原值；P1 真机若镜像再翻）
# - 盒子由 faces min/max 还原：origin(部件本地 = min*16 - pivot)，size 截断取整夹 ≥1（Cube C1 只要 int）
# - 面 UV：归一化 → 512 像素取整，按法线固定顺序 east(+x)/west(-x)/up(+y)/down(-y)/south(+z)/north(-z)
import pickle, json, os, sys, math

TEX = 512
FACE_NAMES = ['east', 'west', 'up', 'down', 'south', 'north']
# 面角表（与 viewer/运行期共享：每面 4 角，部件本地分数坐标，顺序即 UV 角序）
FACE_CORNERS = {
    'east': [(1,0,0),(1,0,1),(1,1,1),(1,1,0)],
    'west': [(0,0,1),(0,0,0),(0,1,0),(0,1,1)],
    'up': [(0,1,1),(0,1,0),(1,1,0),(1,1,1)],
    'down': [(0,0,0),(0,0,1),(1,0,1),(1,0,0)],
    'south': [(1,0,1),(0,0,1),(0,1,1),(1,1,1)],
    'north': [(0,0,0),(1,0,0),(1,1,0),(0,1,0)],
}

def main():
    workdir = sys.argv[1] if len(sys.argv) > 1 else '/tmp/fatfish'
    outdir = sys.argv[2] if len(sys.argv) > 2 else os.path.join(workdir, 'baked')
    os.makedirs(outdir, exist_ok=True)
    g = pickle.load(open(os.path.join(workdir, 'model_type1.pkl'), 'rb'))['geo']
    bones = g['bones']
    kids = {}
    for b in bones:
        kids.setdefault(b['parent'] or '', []).append(b['name'])
    def subtree(r):
        out = [r]
        for c in kids.get(r, []):
            out += subtree(c)
        return out
    rset = set(subtree('Root'))
    rb = [b for b in bones if b['name'] in rset]
    new_idx = {b['name']: i for i, b in enumerate(rb)}
    jbones = []
    for b in rb:
        p = b['parent']
        jbones.append({
            'name': b['name'],
            'parent': new_idx[p] if p in new_idx else -1,
            'pivot': [round(float(v), 4) for v in b['pivot']],
            'rot': [round(float(v), 5) for v in b['rotation']],
        })
    jcubes = []
    skipped = 0
    for b in rb:
        bi = new_idx[b['name']]
        piv = b['pivot']
        for c in b.get('cubes', []):
            faces = c['faces']
            if len(faces) < 6:
                skipped += 1
                continue
            xs, ys, zs = [], [], []
            for f in faces:
                for v in f['pos']:
                    xs.append(v[0]); ys.append(v[1]); zs.append(v[2])
            # 世界（骨骼帧）单位 Bedrock：pos 是 piv/16 同单位的块单位，*16 回 Bedrock
            mn = [min(xs) * 16, min(ys) * 16, min(zs) * 16]
            mx = [max(xs) * 16, max(ys) * 16, max(zs) * 16]
            ctr = [(mn[i] + mx[i]) / 2 for i in range(3)]
            sz = [mx[i] - mn[i] for i in range(3)]
            size_i = [max(1, math.trunc(v)) for v in sz]
            org = [mn[i] - piv[i] for i in range(3)]
            # 面朝向走几何判定（pkl 法线多为 0 不可用）：四顶点在某轴上几乎无跨度即该轴面，
            # 符号看面心相对盒心。UV 角序按 FACE_CORNERS 与原始顶点就近匹配（旋转精确，不只记矩形）。
            # 同一朝向多面时取第一面（裙摆褶皱等非盒近似，P1 接受）。
            uv = {}
            for f in faces:
                us, vs = f['u'], f['v']
                vpx = [v[0] * 16 for v in f['pos']]
                vpy = [v[1] * 16 for v in f['pos']]
                vpz = [v[2] * 16 for v in f['pos']]
                ex = max(vpx) - min(vpx); ey = max(vpy) - min(vpy); ez = max(vpz) - min(vpz)
                axis = min(range(3), key=lambda i: (ex, ey, ez)[i])
                fc = [(min(vpx) + max(vpx)) / 2, (min(vpy) + max(vpy)) / 2,
                      (min(vpz) + max(vpz)) / 2]
                s = 1 if fc[axis] >= ctr[axis] else -1
                key = {(0, 1): 'east', (0, -1): 'west',
                       (1, 1): 'up', (1, -1): 'down',
                       (2, 1): 'south', (2, -1): 'north'}[(axis, s)]
                if key in uv:
                    continue
                corners = []
                for (fx, fy, fz) in FACE_CORNERS[key]:
                    cx = mn[0] + fx * sz[0]; cy = mn[1] + fy * sz[1]; cz = mn[2] + fz * sz[2]
                    bi_ = min(range(4), key=lambda k: abs(vpx[k] - cx) + abs(vpy[k] - cy) + abs(vpz[k] - cz))
                    corners += [int(round(us[bi_] * TEX)), int(round(vs[bi_] * TEX))]
                uv[key] = corners
            # 缺面补齐：先找对面，无对面记全 0（运行期走 Cube 默认 UV，viewer 品红标出）
            approx = 0
            opp = {'east': 'west', 'west': 'east', 'up': 'down',
                   'down': 'up', 'south': 'north', 'north': 'south'}
            for nm in FACE_NAMES:
                if nm not in uv:
                    approx += 1
                    uv[nm] = list(uv.get(opp[nm], [0, 0, 0, 0, 0, 0, 0, 0]))
            jcubes.append({
                'bone': bi,
                'origin': [round(v, 4) for v in org],
                'size': size_i,
                'size_f': [round(v, 4) for v in sz],
                'approx': approx,
                'uv': uv,
            })
    data = {'texW': TEX, 'texH': TEX, 'bones': jbones, 'cubes': jcubes,
            'skipped': skipped}
    json.dump(data, open(os.path.join(outdir, 'fatfish_baked.json'), 'w'),
              separators=(',', ':'))
    # ---- C 数组（local/，gitignore） ----
    f4 = lambda v: ('%.4f' % v).rstrip('0').rstrip('.') if isinstance(v, float) else str(v)
    h = ('// MWBFatFishData.h — 大肥鱼烘焙几何（机器生成，勿手改，用 tools/bake_fatfish.py 重生）\n'
         '// 第三方模型，local/ 下不提交仓库\n#pragma once\n'
         'extern const int MWBFatFishBoneCount;\n'
         'extern const int MWBFatFishBoneParent[];\n'
         'extern const float MWBFatFishBonePivot[][3];\n'
         'extern const float MWBFatFishBoneRot[][3];\n'
         'extern const int MWBFatFishCubeCount;\n'
         'extern const int MWBFatFishCubeBone[];\n'
         'extern const float MWBFatFishCubeOrigin[][3];\n'
         'extern const int MWBFatFishCubeSize[][3];\n'
         '// 面 UV（east/west/up/down/south/north 顺序，每面 4 角各 u,v 像素，512 纹理）\n'
         'extern const short MWBFatFishCubeUV[][6][8];\n')
    open(os.path.join(outdir, 'MWBFatFishData.h'), 'w').write(h)
    c = ('// MWBFatFishData.c — 大肥鱼烘焙几何（机器生成，勿手改）\n'
         '#include "MWBFatFishData.h"\n'
         'const int MWBFatFishBoneCount = %d;\n' % len(jbones))
    c += ('const int MWBFatFishBoneParent[] = {%s};\n'
          % ','.join(str(b['parent']) for b in jbones))
    c += ('const float MWBFatFishBonePivot[][3] = {%s};\n'
          % ','.join('{%s}' % ','.join(f4(v) for v in b['pivot']) for b in jbones))
    c += ('const float MWBFatFishBoneRot[][3] = {%s};\n'
          % ','.join('{%s}' % ','.join(f4(v) for v in b['rot']) for b in jbones))
    c += 'const int MWBFatFishCubeCount = %d;\n' % len(jcubes)
    c += ('const int MWBFatFishCubeBone[] = {%s};\n'
          % ','.join(str(x['bone']) for x in jcubes))
    c += ('const float MWBFatFishCubeOrigin[][3] = {%s};\n'
          % ','.join('{%s}' % ','.join(f4(v) for v in x['origin']) for x in jcubes))
    c += ('const int MWBFatFishCubeSize[][3] = {%s};\n'
          % ','.join('{%d,%d,%d}' % tuple(x['size']) for x in jcubes))
    c += ('const short MWBFatFishCubeUV[][6][8] = {%s};\n'
          % ','.join('{%s}' % ','.join('{%s}' % ','.join(str(v) for v in x['uv'][nm]) for nm in FACE_NAMES) for x in jcubes))
    open(os.path.join(outdir, 'MWBFatFishData.c'), 'w').write(c)
    # 统计
    sub1 = sum(1 for x in jcubes if min(x['size_f']) < 1)
    appx = sum(1 for x in jcubes if x['approx'])
    print('bones=%d cubes=%d skipped=%d sub1=%d approx=%d' % (len(jbones), len(jcubes), skipped, sub1, appx))
    print('wrote', outdir)

if __name__ == '__main__':
    main()
