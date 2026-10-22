// MWBYSMCodec.mm — 魔玩盒子 .ysm 模型解码器实现
// 只新建本文件与 MWBYSMCodec.h，不改动仓库任何已有文件。
// 算法逐行照抄开源参考 OpenYSMDev/YSMParser（MIT，见下方出处与 LICENSE 头）：
// 仓库外路径 /Users/bemly/Projects/mcpe-refs/YSMParser/，已用官方 CLI 验证可解 大肥鱼_1.0.ysm。
// 流程：容器解析 → CityHash64 校验 → 魔改 XChaCha 解密 → MT19937_64 异或 → 去 nonce 头
// → YSM 魔改 zstd 洗白 → vendored zstd 标准解压 → 二进制 walk → 骨骼盒子还原。
// 依赖说明：
// 1) CityHash64（YSM 魔改版 k0/k1/k2 常量）与 XChaCha20 源码直接内嵌在本文件
// （为遵守只新增文件的铁律，这两处未按任务原话拆成独立 vendor 文件）；LICENSE 头保留如下。
// 2) zstd 解压：原计划优先 iOS12 系统 <compression.h> 的 COMPRESSION_ZSTD，
// 实测该枚举在苹果 SDK 中根本不存在（macOS15/iOS SDK 的 compression.h 只有
// LZVN/LZFSE/ZLIB/LZMA/LZ4/BROTLI 等，libcompression 无 zstd，dlopen 实测调不通），
// 故按任务 fallback 直接 vendor 官方单文件解码器 zstddeclib.c（本仓库新增文件，
// 由官方脚本 build/single_file_libs/combine.py 从 external/zstd 生成，BSD 许可，
// 头部完整保留，解压输出已验证与官方 CLI逐字节一致）。合并时主程序员只需把
// zstddeclib.c 加入 Makefile 的 mowanbox_FILES 即可；本文件仅前向声明所用符号。
// 3) 不用 nlohmann（直接组装 NSArray/NSDictionary）；BufferReader 自己写 C 结构。
//
// CityHash 出处与 LICENSE（Google, BSD 风格 MIT）：
// Copyright (c) 2011 Google, Inc.
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.
// 注意：YSM 用的 CityHash 常量被魔改过（k0/k1/k2 见下），与官方版本哈希值不同，照抄参考实现。
//
// XChaCha20 出处与 LICENSE（Bryan Hawkins, BSD-3）：
// Copyright 2019 Bryan Hawkins <spcnvdrr@protonmail.com>
// Redistribution and use in source and binary forms, with or without
// modification, are permitted provided that the following conditions are met:
// 1. Redistributions of source code must retain the above copyright notice,
// this list of conditions and the following disclaimer.
// 2. Redistributions in binary form must reproduce the above copyright notice,
// this list of conditions and the following disclaimer in the documentation
// and/or other materials provided with the distribution.
// 3. Neither the name of the copyright holder nor the names of its contributors
// may be used to endorse or promote products derived from this software without
// specific prior written permission.
// THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
// AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
// IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
// ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
// LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
// CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
// SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
// INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
// CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
// ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
// POSSIBILITY OF SUCH DAMAGE.

#import "MWBYSMCodec.h"
#include <vector>
#include <string>
#include <map>
#include <set>
#include <cmath>
#include <cstring>
#include <cstdint>
#include <random>
#include <limits>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

// 错误域
static NSString *const kMWBYSMErrDomain = @"MWBYSMCodec";

namespace MWBYSM {

// 解密种子（照抄 CryptoAlgorithms.hpp）
static const uint64_t kSeedKeyDerivation = 0xD017CBBA7B5D3581ULL;
static const uint64_t kSeedResVerification = 0xA62B1A2C43842BC3ULL;
static const uint64_t kSeedFileVerification = 0x9E5599DB80C67C29ULL;

// ---------- 小端读取（ARM 上禁用非对齐强转，一律 memcpy） ----------
static __attribute__((unused)) uint16_t ReadU16(const uint8_t *p) { uint16_t v; memcpy(&v, p, 2); return v; }
static uint32_t ReadU32(const uint8_t *p) { uint32_t v; memcpy(&v, p, 4); return v; }
static uint64_t ReadU64(const uint8_t *p) { uint64_t v; memcpy(&v, p, 8); return v; }
static __attribute__((unused)) float ReadF32(const uint8_t *p) { float v; memcpy(&v, p, 4); return v; }

// ---------- CityHash64（YSM 魔改常量版，照抄 city.cc 所需子集） ----------
static const uint64_t k0 = 0xE4986A230E5AAA17ULL;
static const uint64_t k1 = 0x91AF10802CAB25A5ULL;
static const uint64_t k2 = 0xAF29CE778879D9C7ULL;
static uint64_t Fetch64(const char *p) { uint64_t v; memcpy(&v, p, 8); return v; }
static uint32_t Fetch32(const char *p) { uint32_t v; memcpy(&v, p, 4); return v; }
static uint64_t Rot64(uint64_t v, int s) { return s == 0 ? v : ((v >> s) | (v << (64 - s))); }
static uint64_t ShiftMix64(uint64_t v) { return v ^ (v >> 47); }
static uint64_t Hash128to64(uint64_t 低, uint64_t 高) {
  // YSM 魔改版（city.cc 517-531）：常量与算法都与官方不同，照抄
  const uint64_t kMul = 0xDE0F6EE09BDBAB91ULL;
  uint64_t 内 = ShiftMix64((低 ^ 高) * kMul);
  uint64_t 中 = kMul * (内 ^ 低);
  return kMul * ShiftMix64(中);
}
static uint64_t HashLen16b(uint64_t u, uint64_t v) { return Hash128to64(u, v); }
static uint64_t HashLen16m(uint64_t u, uint64_t v, uint64_t m) {
  uint64_t a = (u ^ v) * m; a ^= (a >> 47); uint64_t b = (v ^ a) * m;
  b ^= (b >> 47); b *= m; return b;
}
static uint64_t Hash0to16(const char *s, size_t n) {
  if (n >= 8) {
    uint64_t m = k2 + n * 2, a = Fetch64(s) + k2, b = Fetch64(s + n - 8);
    return HashLen16m(Rot64(b, 37) * m + a, (Rot64(a, 25) + b) * m, m);
  }
  if (n >= 4) {
    uint64_t m = k2 + n * 2, a = Fetch32(s);
    return HashLen16m(n + (a << 3), Fetch32(s + n - 4), m);
  }
  if (n > 0) {
    uint8_t a = s[0], b = s[n >> 1], c = s[n - 1];
    uint32_t y = (uint32_t)a + ((uint32_t)b << 8), z = (uint32_t)n + ((uint32_t)c << 2);
    return ShiftMix64((uint64_t)y * k2 ^ (uint64_t)z * k0) * k2;
  }
  return k2;
}
static uint64_t Hash17to32(const char *s, size_t n) {
  uint64_t m = k2 + n * 2, a = Fetch64(s) * k1, b = Fetch64(s + 8);
  uint64_t c = Fetch64(s + n - 8) * m, d = Fetch64(s + n - 16) * k2;
  return HashLen16m(Rot64(a + b, 43) + Rot64(c, 30) + d, a + Rot64(b + k2, 18) + c, m);
}
static std::pair<uint64_t,uint64_t> WeakHash5(uint64_t w, uint64_t x, uint64_t y, uint64_t z, uint64_t a, uint64_t b) {
  a += w; b = Rot64(b + a + z, 21); uint64_t c = a; a += x; a += y;
  b += Rot64(a, 44); return std::make_pair(a + z, b + c);
}
static std::pair<uint64_t,uint64_t> WeakHashStr(const char *s, uint64_t a, uint64_t b) {
  return WeakHash5(Fetch64(s), Fetch64(s + 8), Fetch64(s + 16), Fetch64(s + 24), a, b);
}
static uint64_t Hash33to64(const char *s, size_t n) {
  uint64_t m = k2 + n * 2, a = Fetch64(s) * k2, b = Fetch64(s + 8);
  uint64_t c = Fetch64(s + n - 24), d = Fetch64(s + n - 32), e = Fetch64(s + 16) * k2;
  uint64_t f = Fetch64(s + 24) * 9, g = Fetch64(s + n - 8), h = Fetch64(s + n - 16) * m;
  uint64_t u = Rot64(a + g, 43) + (Rot64(b, 30) + c) * 9;
  uint64_t v = ((a + g) ^ d) + f + 1, w = __builtin_bswap64((u + v) * m) + h;
  uint64_t x = Rot64(e + f, 42) + c, y = (__builtin_bswap64((v + w) * m) + g) * m;
  uint64_t z = e + f + c;
  a = __builtin_bswap64((x + z) * m + y) + b;
  b = ShiftMix64((z + a) * m + d + h) * m;
  return b + x;
}
static uint64_t CityHash64Ysm(const char *s, size_t n) {
  if (n <= 32) return n <= 16 ? Hash0to16(s, n) : Hash17to32(s, n);
  if (n <= 64) return Hash33to64(s, n);
  uint64_t x = Fetch64(s + n - 40), y = Fetch64(s + n - 16) + Fetch64(s + n - 56);
  uint64_t z = HashLen16b(Fetch64(s + n - 48) + n, Fetch64(s + n - 24));
  std::pair<uint64_t,uint64_t> v = WeakHashStr(s + n - 64, n, z);
  std::pair<uint64_t,uint64_t> w = WeakHashStr(s + n - 32, y + k1, x);
  x = x * k1 + Fetch64(s); n = (n - 1) & ~(size_t)63;
  do {
    x = Rot64(x + y + v.first + Fetch64(s + 8), 37) * k1;
    y = Rot64(y + v.second + Fetch64(s + 48), 42) * k1;
    x ^= w.second; y += v.first + Fetch64(s + 40);
    z = Rot64(z + w.first, 33) * k1;
    v = WeakHashStr(s, v.second * k1, x + w.first);
    w = WeakHashStr(s + 32, z + w.second, y + Fetch64(s + 16));
    uint64_t t = z; z = x; x = t; s += 64; n -= 64;
  } while (n != 0);
  return HashLen16b(HashLen16b(v.first, w.first) + ShiftMix64(y) * k1 + z, HashLen16b(v.second, w.second) + x);
}
static uint64_t CityHashSeed(const char *s, size_t n, uint64_t seed) {
  return HashLen16b(CityHash64Ysm(s, n) - k2, seed);
}

// ---------- XChaCha20（照抄 xchacha20.cc，魔改点：轮数可变 + HChaCha 传轮数） ----------
struct ChaChaCtx { uint32_t input[16]; uint32_t rounds; };
#define ROTL32X(v,n) (uint32_t)(((uint32_t)(v) << (n)) | ((uint32_t)(v) >> (32 - (n))))
#define U8TO32(p) ((uint32_t)((p)[0]) | ((uint32_t)((p)[1]) << 8) | ((uint32_t)((p)[2]) << 16) | ((uint32_t)((p)[3]) << 24))
#define U32TO8(p,v) do { (p)[0]=(uint8_t)(v); (p)[1]=(uint8_t)((v)>>8); (p)[2]=(uint8_t)((v)>>16); (p)[3]=(uint8_t)((v)>>24); } while(0)
#define QROUND(a,b,c,d) a+=(b); d^=(a); d=ROTL32X(d,16); c+=(d); b^=(c); b=ROTL32X(b,12); a+=(b); d^=(a); d=ROTL32X(d,8); c+=(d); b^=(c); b=ROTL32X(b,7);
static void HChaCha20(uint8_t *out, const uint8_t *in, const uint8_t *key, uint32_t rounds) {
  uint32_t x0=0x61707865,x1=0x3320646e,x2=0x79622d32,x3=0x6b206574;
  uint32_t x4=U8TO32(key+0),x5=U8TO32(key+4),x6=U8TO32(key+8),x7=U8TO32(key+12);
  uint32_t x8=U8TO32(key+16),x9=U8TO32(key+20),x10=U8TO32(key+24),x11=U8TO32(key+28);
  uint32_t x12=U8TO32(in+0),x13=U8TO32(in+4),x14=U8TO32(in+8),x15=U8TO32(in+12);
  for (uint32_t i = 0; i < rounds; i += 2) {
    QROUND(x0,x4,x8,x12); QROUND(x1,x5,x9,x13);
    QROUND(x2,x6,x10,x14); QROUND(x3,x7,x11,x15);
    QROUND(x0,x5,x10,x15); QROUND(x1,x6,x11,x12);
    QROUND(x2,x7,x8,x13); QROUND(x3,x4,x9,x14);
  }
  U32TO8(out+0,x0); U32TO8(out+4,x1); U32TO8(out+8,x2); U32TO8(out+12,x3);
  U32TO8(out+16,x12); U32TO8(out+20,x13); U32TO8(out+24,x14); U32TO8(out+28,x15);
}
static void KeySetup(ChaChaCtx *ctx, const uint8_t *key, const uint8_t *iv) {
  uint8_t subkey[32];
  HChaCha20(subkey, iv, key, ctx->rounds);
  ctx->input[0]=0x61707865; ctx->input[1]=0x3320646e; ctx->input[2]=0x79622d32; ctx->input[3]=0x6b206574;
  for (int i = 0; i < 8; i++) ctx->input[4+i] = U8TO32(subkey + i*4);
  ctx->input[12]=0; ctx->input[13]=0;
  ctx->input[14]=U8TO32(iv+16); ctx->input[15]=U8TO32(iv+20);
}
static void CryptBytes(ChaChaCtx *ctx, const uint8_t *src, uint8_t *dst, uint32_t len) {
  if (!len) return;
  uint32_t j0=ctx->input[0],j1=ctx->input[1],j2=ctx->input[2],j3=ctx->input[3];
  uint32_t j4=ctx->input[4],j5=ctx->input[5],j6=ctx->input[6],j7=ctx->input[7];
  uint32_t j8=ctx->input[8],j9=ctx->input[9],j10=ctx->input[10],j11=ctx->input[11];
  uint32_t j12=ctx->input[12],j13=ctx->input[13],j14=ctx->input[14],j15=ctx->input[15];
  uint8_t tmp[64], stream[64];
  for (;;) {
    uint32_t x0=j0,x1=j1,x2=j2,x3=j3,x4=j4,x5=j5,x6=j6,x7=j7;
    uint32_t x8=j8,x9=j9,x10=j10,x11=j11,x12=j12,x13=j13,x14=j14,x15=j15;
    for (uint32_t i = ctx->rounds; i > 0; i -= 2) {
      QROUND(x0,x4,x8,x12); QROUND(x1,x5,x9,x13);
      QROUND(x2,x6,x10,x14); QROUND(x3,x7,x11,x15);
      QROUND(x0,x5,x10,x15); QROUND(x1,x6,x11,x12);
      QROUND(x2,x7,x8,x13); QROUND(x3,x4,x9,x14);
    }
    x0+=j0; x1+=j1; x2+=j2; x3+=j3; x4+=j4; x5+=j5; x6+=j6; x7+=j7;
    x8+=j8; x9+=j9; x10+=j10; x11+=j11; x12+=j12; x13+=j13; x14+=j14; x15+=j15;
    U32TO8(stream+0,x0); U32TO8(stream+4,x1); U32TO8(stream+8,x2); U32TO8(stream+12,x3);
    U32TO8(stream+16,x4); U32TO8(stream+20,x5); U32TO8(stream+24,x6); U32TO8(stream+28,x7);
    U32TO8(stream+32,x8); U32TO8(stream+36,x9); U32TO8(stream+40,x10); U32TO8(stream+44,x11);
    U32TO8(stream+48,x12); U32TO8(stream+52,x13); U32TO8(stream+56,x14); U32TO8(stream+60,x15);
    uint32_t blk = len > 64 ? 64 : len;
    for (uint32_t i = 0; i < blk; i++) tmp[i] = src[i];
    for (uint32_t i = 0; i < blk; i++) dst[i] = tmp[i] ^ stream[i];
    j12++; if (!j12) j13++;
    if (len <= 64) break;
    len -= 64; src += 64; dst += 64;
  }
  ctx->input[12] = j12; ctx->input[13] = j13;
}

// 魔改状态反馈（照抄 CryptoAlgorithms.cpp）
static size_t UpdateState(ChaChaCtx *ctx, uint64_t h) {
  ctx->rounds = 10 * (h % 3) + 10;
  uint32_t lo = (uint32_t)(h & 0xFFFFFFFF), hi = (uint32_t)((h >> 32) & 0xFFFFFFFF);
  for (int i = 4; i < 16; i++) ctx->input[i] ^= (i % 2 == 0) ? lo : hi;
  return (size_t)(((h & 0x3F) | 0x40) << 6);
}
// 魔改 ChaCha 解密（先对密文块解密，再对明文块哈希反馈更新状态）
static void ModDecrypt(const std::vector<uint8_t> &enc, const uint8_t *key, const uint8_t *iv,
                       std::vector<uint8_t> &dec) {
  uint8_t keyiv[56]; memcpy(keyiv, key, 32); memcpy(keyiv + 32, iv, 24);
  uint64_t h2 = CityHashSeed((const char *)keyiv, 56, kSeedResVerification);
  size_t next = ((h2 & 0x3F) | 0x40) << 6, pos = 0;
  ChaChaCtx ctx; ctx.rounds = 10 * (h2 % 3) + 10; KeySetup(&ctx, key, iv);
  dec.clear(); dec.reserve(enc.size());
  while (pos < enc.size()) {
    if (pos + next > enc.size()) next = enc.size() - pos;
    std::vector<uint8_t> blk(next);
    CryptBytes(&ctx, enc.data() + pos, blk.data(), (uint32_t)next);
    pos += next;
    uint64_t bh = CityHashSeed((const char *)blk.data(), blk.size(), kSeedResVerification);
    next = UpdateState(&ctx, bh);
    dec.insert(dec.end(), blk.begin(), blk.end());
  }
}
// MT19937_64 异或（必须原样用 std::mt19937_64，按小端拆 8 字节）
static void MTXor(std::vector<uint8_t> &data, const uint8_t *key, const uint8_t *iv) {
  uint8_t keyiv[56]; memcpy(keyiv, key, 32); memcpy(keyiv + 32, iv, 24);
  uint64_t seed = CityHashSeed((const char *)keyiv, 56, kSeedKeyDerivation);
  std::mt19937_64 gen(seed);
  size_t i = 0;
  while (i < data.size()) {
    uint64_t r = gen();
    for (int j = 0; j < 8 && i < data.size(); j++, i++)
      data[i] ^= (uint8_t)((r >> (j * 8)) & 0xFF);
  }
}

// ---------- YSM 魔改 zstd 洗白（照抄 YsmZstd.hpp wash） ----------
static int FrameHeadLen(uint8_t fhd) {
  int single = ((fhd >> 5) & 1) ? 1 : 0;
  int dict = (fhd & 3) == 1 ? 1 : ((fhd & 3) == 2 ? 2 : ((fhd & 3) == 3 ? 4 : 0));
  int fcs = ((fhd >> 6) & 3) == 0 ? (single ? 1 : 0)
          : ((fhd >> 6) & 3) == 1 ? 2 : ((fhd >> 6) & 3) == 2 ? 4 : 8;
  return 1 + (single ? 0 : 1) + dict + fcs;
}
static bool Wash(const std::vector<uint8_t> &in, std::vector<uint8_t> &out) {
  if (in.size() < 5) return false;
  std::vector<uint8_t> d = in;
  if (ReadU32(d.data()) != 0xFD2FB528) return false;
  uint8_t fhd = d[4];
  d[4] = fhd & 0xFB;
  size_t off = 4 + (size_t)FrameHeadLen(fhd); // 注意用原始 fhd 算长度
  while (off + 3 <= d.size()) {
    uint32_t b0 = d[off], b1 = d[off+1], b2 = d[off+2];
    uint32_t last = (b0 >> 7) & 1, ysmType = (b0 >> 5) & 3;
    uint32_t rawSize = ((b0 & 0x1F) << 16) | b1 | (b2 << 8);
    uint32_t size = rawSize ^ 0xD4E9, stdType = 0;
    switch (ysmType) { case 0: stdType = 2; break; case 1: stdType = 1; break;
                       case 2: stdType = 3; break; case 3: stdType = 0; break; default: return false; }
    uint32_t head = last | (stdType << 1) | (size << 3);
    d[off] = head & 0xFF; d[off+1] = (head >> 8) & 0xFF; d[off+2] = (head >> 16) & 0xFF;
    off += 3 + (stdType == 1 ? 1 : (size_t)size);
    if (last == 1) break;
  }
  out = d; return true;
}

// ---------- 标准 zstd 解压（vendored zstddeclib.c，前向声明所用符号，ABI 与 zstd.h 一致） ----------
extern "C" {
size_t ZSTD_decompress(void *dst, size_t dstCapacity, const void *src, size_t srcSize);
unsigned ZSTD_isError(size_t code);
}
static bool SystemZstd(const std::vector<uint8_t> &in, std::vector<uint8_t> &out) {
  // 内容尺寸未知（帧头无 FCS 字段），容量翻倍试探（4MB→256MB），损坏流在各级容量都失败
  for (size_t cap = 4 * 1024 * 1024; cap <= 256 * 1024 * 1024; cap *= 2) {
    std::vector<uint8_t> buf(cap);
    size_t r = ZSTD_decompress(buf.data(), cap, in.data(), in.size());
    if (!ZSTD_isError(r)) {
      if (r == 0) return false;
      buf.resize(r); out.swap(buf); return true;
    }
  }
  return false;
}

// ---------- 二进制游标（照抄 BufferReader.hpp 语义，ARM 用 memcpy） ----------
struct Cursor {
  const uint8_t *data; size_t len; size_t off; bool ok;
  Cursor(const uint8_t *d, size_t n) : data(d), len(n), off(0), ok(true) {}
  uint8_t byte() {
    if (!ok || off >= len) { ok = false; return 0; }
    return data[off++];
  }
  uint64_t varint() { // 无符号 LEB128
    uint64_t v = 0, sh = 0; uint8_t b = 0;
    do {
      b = byte(); if (!ok) return 0;
      v |= ((uint64_t)(b & 0x7F) << sh); sh += 7;
      if (sh > 70) { ok = false; return 0; }
    } while (b & 0x80);
    return v;
  }
  float f32() {
    if (!ok || off + 4 > len) { ok = false; return 0; }
    float v; memcpy(&v, data + off, 4); off += 4; return v;
  }
  void vec3(float &x, float &y, float &z) { x = f32(); y = f32(); z = f32(); }
  void skipStr() { // string = 变长长度 + 字节，读后丢弃
    uint64_t n = varint(); if (!ok) return;
    if (off + n > len) { ok = false; return; }
    off += (size_t)n;
  }
  std::string getStr() {
    uint64_t n = varint(); if (!ok) return std::string();
    if (off + n > len) { ok = false; return std::string(); }
    std::string s((const char *)(data + off), (size_t)n);
    off += (size_t)n; return s;
  }
  std::vector<uint8_t> getBytes() { // 字节序列 = 变长长度 + 原字节
    uint64_t n = varint(); if (!ok) return std::vector<uint8_t>();
    if (off + n > len) { ok = false; return std::vector<uint8_t>(); }
    std::vector<uint8_t> v(data + off, data + off + (size_t)n);
    off += (size_t)n; return v;
  }
};

// ---------- 各段跳过（只推进游标，结果丢弃；纹理/模型除外） ----------
// 关键帧通道：molangs==0 缺席；每帧 时间浮点 + lerp变长 + 3组(类型字节:1浮点/2字符串) + [pre 三元组]
static void SkipChannel(Cursor &r) {
  uint64_t n = r.varint(); if (!r.ok) return;
  if (n == 0) return;
  for (uint64_t i = 0; i < n && r.ok; i++) {
    r.f32(); r.varint();
    for (int k = 0; k < 3 && r.ok; k++) {
      uint8_t t = r.byte(); if (!r.ok) return;
      if (t == 0x01) r.f32(); else if (t == 0x02) r.skipStr();
      else { r.ok = false; return; }
    }
    uint64_t pre = r.varint(); if (!r.ok) return;
    if (pre >= 2) { r.ok = false; return; }
    if (pre) for (int k = 0; k < 3 && r.ok; k++) {
      uint8_t t = r.byte(); if (!r.ok) return;
      if (t == 0x01) r.f32(); else if (t == 0x02) r.skipStr();
      else { r.ok = false; return; }
    }
  }
}
static void SkipTimeline(Cursor &r) {
  uint64_t n = r.varint(); if (!r.ok || n == 0) return;
  for (uint64_t i = 0; i < n && r.ok; i++) {
    uint64_t m = r.varint();
    for (uint64_t j = 0; j < m && r.ok; j++) r.skipStr();
    r.f32();
  }
}
static void SkipEffect(Cursor &r) {
  uint64_t n = r.varint(); if (!r.ok || n == 0) return;
  for (uint64_t i = 0; i < n && r.ok; i++) { r.skipStr(); r.f32(); }
}
// 动画：哈希串 + 数量 + 每段(名称 + 时长 + 循环 + [两变长0 + 混合权重 + 变长0] + 骨骼通道 + 时间线 + 音效)
static void SkipAnims(Cursor &r) {
  r.skipStr(); // 哈希（format 32 恒有）
  uint64_t n = r.varint();
  for (uint64_t a = 0; a < n && r.ok; a++) {
    r.skipStr(); r.f32(); r.varint();
    if (r.varint() != 0) { r.ok = false; return; }
    if (r.varint() != 0) { r.ok = false; return; }
    uint64_t mix = r.varint();
    for (uint64_t m = 0; m < mix && r.ok; m++) {
      uint8_t t = r.byte();
      if (t == 0x01) r.f32(); else if (t == 0x02) r.skipStr();
      else { r.ok = false; return; }
    }
    if (r.varint() != 0) { r.ok = false; return; }
    uint64_t bones = r.varint();
    for (uint64_t i = 0; i < bones && r.ok; i++) {
      r.skipStr(); SkipChannel(r); SkipChannel(r); SkipChannel(r);
    }
    SkipTimeline(r); SkipEffect(r);
  }
}
// 控制器：数量 + 每段(名称 + 初始态 + 状态数 + 每态…)
static void SkipControllers(Cursor &r) {
  uint64_t n = r.varint();
  for (uint64_t a = 0; a < n && r.ok; a++) {
    r.skipStr(); r.skipStr();
    uint64_t states = r.varint();
    for (uint64_t i = 0; i < states && r.ok; i++) {
      r.skipStr();
      uint64_t an = r.varint();
      for (uint64_t j = 0; j < an && r.ok; j++) { r.skipStr(); r.skipStr(); }
      uint64_t tr = r.varint();
      for (uint64_t j = 0; j < tr && r.ok; j++) { r.skipStr(); r.skipStr(); }
      uint64_t en = r.varint();
      for (uint64_t j = 0; j < en && r.ok; j++) r.skipStr();
      uint64_t ex = r.varint();
      for (uint64_t j = 0; j < ex && r.ok; j++) r.skipStr();
      if (r.varint() != 0) r.f32();
      else {
        uint64_t bn = r.varint();
        for (uint64_t j = 0; j < bn && r.ok; j++) { r.f32(); r.f32(); }
      }
      r.varint(); // 最短路径标志
      uint64_t se = r.varint(); // format>26 音效
      for (uint64_t j = 0; j < se && r.ok; j++) r.skipStr();
    }
  }
}
static std::vector<uint8_t> GetSpecial(Cursor &r) {
  r.skipStr(); return r.getBytes(); // 哈希串 + 字节序列
}
static void SkipSounds(Cursor &r) {
  uint64_t n = r.varint();
  for (uint64_t i = 0; i < n && r.ok; i++) { r.skipStr(); r.skipStr(); r.skipStr(); }
}
static void SkipFuncs(Cursor &r) {
  uint64_t n = r.varint();
  for (uint64_t i = 0; i < n && r.ok; i++) { r.skipStr(); r.skipStr(); r.skipStr(); }
}
static void SkipLangs(Cursor &r) {
  uint64_t n = r.varint();
  for (uint64_t i = 0; i < n && r.ok; i++) {
    r.skipStr(); r.skipStr();
    uint64_t m = r.varint();
    for (uint64_t j = 0; j < m && r.ok; j++) { r.skipStr(); r.skipStr(); }
  }
}

// ---------- 模型原始结构 ----------
struct Vertex { float x, y, z, u, v; };
struct Face { float n[3]; Vertex v[4]; };
struct RawCube { std::vector<Face> faces; };
struct RawBone { std::string parent, name; std::vector<RawCube> cubes; float pivot[3], rot[3]; };

// 模型段：sha256 + 骨骼数 + 每骨(父串 + 方块[面数 + 每面(法线 + 4×(坐标+uv))] + 3变长 + 名称 + 5变长 + 枢 + 转)
// 注意：描述里先读 texture_height 再读 texture_width（与参考一致）。
// 只有 keep 为 true（modelId==1）时保留骨骼，否则只推进游标。
static bool WalkModel(Cursor &r, bool keep, std::vector<RawBone> &out, float &texW, float &texH) {
  r.skipStr(); // sha256（format>15 恒有）
  uint64_t nb = r.varint();
  for (uint64_t i = 0; i < nb && r.ok; i++) {
    RawBone b; b.parent = r.getStr();
    uint64_t nc = r.varint();
    for (uint64_t j = 0; j < nc && r.ok; j++) {
      RawCube c; uint64_t nf = r.varint();
      for (uint64_t k = 0; k < nf && r.ok; k++) {
        Face f; r.vec3(f.n[0], f.n[1], f.n[2]);
        for (int q = 0; q < 4 && r.ok; q++) {
          r.vec3(f.v[q].x, f.v[q].y, f.v[q].z);
          f.v[q].u = r.f32(); f.v[q].v = r.f32();
        }
        c.faces.push_back(f);
      }
      b.cubes.push_back(c);
      r.varint(); r.varint(); r.varint();
    }
    b.name = r.getStr();
    r.varint();
    if (r.varint() != 0) return false;
    if (r.varint() != 0) return false;
    if (r.varint() != 0) return false;
    r.varint();
    r.vec3(b.pivot[0], b.pivot[1], b.pivot[2]);
    r.vec3(b.rot[0], b.rot[1], b.rot[2]);
    if (keep) out.push_back(b);
  }
  if (!r.ok) return false;
  r.skipStr(); // 标识
  texH = r.f32(); texW = r.f32(); // 先高后宽
  r.f32(); r.f32(); // 包围盒高/宽
  uint64_t no = r.varint();
  for (uint64_t i = 0; i < no && r.ok; i++) r.f32();
  r.f32(); r.f32(); // 缩放
  if (r.varint() > 0) { // 附加信息
    r.skipStr(); r.skipStr();
    uint64_t ex = r.varint();
    for (uint64_t i = 0; i < ex && r.ok; i++) r.skipStr();
    uint64_t au = r.varint();
    for (uint64_t i = 0; i < au && r.ok; i++) r.skipStr();
    r.skipStr(); r.varint();
  }
  r.varint(); r.varint(); r.varint();
  return r.ok;
}

// 子实体段（载具/投掷物）：动画? 控制器? 基础纹理 + 子纹理 + 模型 + 尾部
static void SkipSubEntity(Cursor &r) {
  // format 32 > 26，无头部子模块名
  if (r.varint()) SkipAnims(r);
  if (r.varint()) { r.skipStr(); SkipControllers(r); }
  GetSpecial(r);
  r.varint(); r.varint(); r.varint(); r.varint(); // uv 宽高格式标志
  uint64_t n = r.varint();
  for (uint64_t i = 0; i < n && r.ok; i++) {
    r.varint(); GetSpecial(r);
    r.varint(); r.varint(); r.varint(); r.varint();
  }
  std::vector<RawBone> drop; float w = 0, h = 0;
  WalkModel(r, false, drop, w, h);
  uint64_t tail = r.varint(); // format>26 多子模型
  for (uint64_t j = 0; j < tail && r.ok; j++) r.skipStr();
}

// ---------- 数学与盒子还原（整段照抄 restore_blockbench_cube 逻辑） ----------
struct V3 { float x, y, z; };
static V3 vAdd(V3 a, V3 b) { return {a.x+b.x, a.y+b.y, a.z+b.z}; }
static V3 vSub(V3 a, V3 b) { return {a.x-b.x, a.y-b.y, a.z-b.z}; }
static V3 vMul(V3 a, float s) { return {a.x*s, a.y*s, a.z*s}; }
static V3 vDiv(V3 a, float s) { return {a.x/s, a.y/s, a.z/s}; }
static V3 vEMul(V3 a, V3 b) { return {a.x*b.x, a.y*b.y, a.z*b.z}; }
static float vDot(V3 a, V3 b) { return a.x*b.x + a.y*b.y + a.z*b.z; }
static V3 vCross(V3 a, V3 b) {
  return {a.y*b.z-a.z*b.y, a.z*b.x-a.x*b.z, a.x*b.y-a.y*b.x};
}
static float vLen(V3 a) { return sqrtf(vDot(a, a)); }
static V3 vNorm(V3 a) { float l = vLen(a); return l > 1e-8f ? vMul(a, 1/l) : V3{0,0,0}; }
static V3 vRound(V3 a) { return {roundf(a.x), roundf(a.y), roundf(a.z)}; }
struct Mat3 { V3 c[3];
  float det() const { return vDot(c[0], vCross(c[1], c[2])); }
  V3 tmul(V3 v) const { return {vDot(c[0],v), vDot(c[1],v), vDot(c[2],v)}; }
};
static V3 MatToEuler(Mat3 m) { // P' = Rz*Ry*Rx*P，返回角度
  float sy = sqrtf(m.c[0].x*m.c[0].x + m.c[0].y*m.c[0].y);
  float ex, ey, ez, deg = (float)(180.0 / M_PI);
  if (sy >= 1e-6f) {
    ex = atan2f(m.c[1].z, m.c[2].z); ey = atan2f(-m.c[0].z, sy); ez = atan2f(m.c[0].y, m.c[0].x);
  } else { ex = atan2f(-m.c[2].y, m.c[1].y); ey = atan2f(-m.c[0].z, sy); ez = 0; }
  return {ex*deg, ey*deg, ez*deg};
}
static void ExpectUV(V3 n, V3 &U, V3 &V) {
  V3 r = vRound(n); U = {0,0,0}; V = {0,0,0};
  if (r.x==-1) { U={0,0,1}; V={0,-1,0}; return; }
  if (r.x==1) { U={0,0,-1}; V={0,-1,0}; return; }
  if (r.y==1) { U={-1,0,0}; V={0,0,-1}; return; }
  if (r.y==-1) { U={-1,0,0}; V={0,0,1}; return; }
  if (r.z==-1) { U={-1,0,0}; V={0,-1,0}; return; }
  if (r.z==1) { U={1,0,0}; V={0,-1,0}; return; }
}
struct UVBox { float u, v, du, dv; };
struct BBCube { V3 origin, size, pivot, rot; std::map<std::string,UVBox> uv; };
static float Clean4(float v) { return roundf(v * 10000.0f) / 10000.0f; }
static BBCube RestoreCube(const std::vector<Face> &faces, int texW, int texH) {
  std::set<std::tuple<float,float,float>> pts;
  struct FI { V3 n, tu, tv; const Face *f; };
  std::vector<FI> infos; std::vector<V3> cand;
  for (size_t fi = 0; fi < faces.size(); fi++) {
    const Face &f = faces[fi];
    V3 w[4];
    for (int i = 0; i < 4; i++) {
      w[i] = vMul(V3{f.v[i].x, f.v[i].y, f.v[i].z}, 16.0f);
      pts.insert(std::make_tuple(roundf(w[i].x*10000)/10000, roundf(w[i].y*10000)/10000, roundf(w[i].z*10000)/10000));
    }
    V3 n = {f.n[0], f.n[1], f.n[2]}, tu = {0,0,0}, tv = {0,0,0};
    for (int i = 0; i < 4; i++) {
      int j = (i+1) % 4;
      V3 d = vSub(w[i], w[j]);
      float du = f.v[i].u - f.v[j].u, dv = f.v[i].v - f.v[j].v, l = vLen(d);
      if (l < 1e-5f) continue;
      if (fabsf(du) > 1e-5f && fabsf(dv) < 1e-5f) tu = vMul(vDiv(d, l), du > 0 ? 1 : -1);
      if (fabsf(dv) > 1e-5f && fabsf(du) < 1e-5f) tv = vMul(vDiv(d, l), dv > 0 ? 1 : -1);
    }
    infos.push_back({n, tu, tv, &f});
    cand.push_back(n);
    if (vLen(tu) > 0.5f) cand.push_back(tu);
    if (vLen(tv) > 0.5f) cand.push_back(tv);
  }
  std::vector<V3> axes;
  for (size_t i = 0; i < cand.size() && axes.size() < 3; i++) {
    V3 n = vNorm(cand[i]); bool has = false;
    for (size_t k = 0; k < axes.size(); k++) if (fabsf(vDot(n, axes[k])) > 0.95f) { has = true; break; }
    if (!has) axes.push_back(n);
  }
  if (axes.size() == 1) {
    V3 t = fabsf(axes[0].x) < 0.9f ? V3{1,0,0} : V3{0,1,0};
    V3 u = vNorm(vCross(axes[0], t)); axes.push_back(u); axes.push_back(vNorm(vCross(axes[0], u)));
  } else if (axes.size() == 2) {
    V3 w = vCross(axes[0], axes[1]);
    if (vLen(w) > 1e-5f) axes.push_back(vNorm(w));
  } else if (axes.empty()) { axes.push_back({1,0,0}); axes.push_back({0,1,0}); axes.push_back({0,0,1}); }
  float best = -std::numeric_limits<float>::infinity(), bestE = std::numeric_limits<float>::infinity();
  Mat3 bestM = {{{1,0,0},{0,1,0},{0,0,1}}}; V3 bestEu = {0,0,0};
  int perm[6][3] = {{0,1,2},{0,2,1},{1,0,2},{1,2,0},{2,0,1},{2,1,0}};
  float sgn[8][3] = {{1,1,1},{1,1,-1},{1,-1,1},{1,-1,-1},{-1,1,1},{-1,1,-1},{-1,-1,1},{-1,-1,-1}};
  for (int pi = 0; pi < 6; pi++) for (int si = 0; si < 8; si++) {
    Mat3 m; for (int c = 0; c < 3; c++) m.c[c] = vMul(axes[perm[pi][c]], sgn[si][c]);
    if (m.det() < 0.9f) continue;
    Mat3 w; w.c[0] = vNorm(m.c[0]);
    w.c[1] = vNorm(vSub(m.c[1], vMul(w.c[0], vDot(m.c[1], w.c[0]))));
    w.c[2] = vNorm(vCross(w.c[0], w.c[1]));
    float s = 0;
    for (size_t k = 0; k < infos.size(); k++) {
      V3 nl = w.tmul(infos[k].n), ul = w.tmul(infos[k].tu), vl = w.tmul(infos[k].tv);
      V3 eu, ev; ExpectUV(nl, eu, ev);
      s += fabsf(vDot(ul, eu)) + fabsf(vDot(vl, ev));
    }
    V3 eu = MatToEuler(w);
    float es = fabsf(eu.x) + fabsf(eu.y) + fabsf(eu.z);
    if (s > best + 1e-4f || (fabsf(s - best) <= 1e-4f && es < bestE)) {
      best = s; bestM = w; bestEu = eu; bestE = es;
    }
  }
  V3 mn = {1e9f,1e9f,1e9f}, mx = {-1e9f,-1e9f,-1e9f};
  for (auto &p : pts) {
    V3 wp = {std::get<0>(p), std::get<1>(p), std::get<2>(p)};
    V3 l = bestM.tmul(wp);
    mn.x=fminf(mn.x,l.x); mn.y=fminf(mn.y,l.y); mn.z=fminf(mn.z,l.z);
    mx.x=fmaxf(mx.x,l.x); mx.y=fmaxf(mx.y,l.y); mx.z=fmaxf(mx.z,l.z);
  }
  V3 lc = {(mn.x+mx.x)/2, (mn.y+mx.y)/2, (mn.z+mx.z)/2};
  V3 dc = vAdd(vAdd(vMul(bestM.c[0],lc.x), vMul(bestM.c[1],lc.y)), vMul(bestM.c[2],lc.z));
  V3 pivot = {-dc.x, dc.y, dc.z};
  V3 sgnS = {1,1,1};
  for (int ax = 0; ax < 3; ax++) {
    V3 lax = bestM.c[ax];
    for (size_t k = 0; k < infos.size(); k++) {
      V3 nl = bestM.tmul(infos[k].n);
      float comp = ax==0 ? nl.x : (ax==1 ? nl.y : nl.z);
      if (fabsf(comp) > 0.5f) {
        V3 fc = {0,0,0};
        for (int i = 0; i < 4; i++) fc = vAdd(fc, vMul(V3{infos[k].f->v[i].x, infos[k].f->v[i].y, infos[k].f->v[i].z}, 16.0f));
        fc = vMul(fc, 0.25f);
        V3 off = vSub(fc, dc);
        float d = vDot(off, lax);
        if (fabsf(d) > 1e-3f && d * comp < 0) {
          if (ax==0) sgnS.x=-1; else if (ax==1) sgnS.y=-1; else sgnS.z=-1;
        }
        break;
      }
    }
  }
  V3 brot = {-bestEu.x, -bestEu.y, bestEu.z};
  float ex=0, ey=0, ez=0;
  for (auto &p : pts) {
    V3 wp = {std::get<0>(p), std::get<1>(p), std::get<2>(p)};
    V3 d = vSub(wp, dc);
    ex=fmaxf(ex,fabsf(vDot(d,bestM.c[0])));
    ey=fmaxf(ey,fabsf(vDot(d,bestM.c[1])));
    ez=fmaxf(ez,fabsf(vDot(d,bestM.c[2])));
  }
  V3 bsize = {ex*2*sgnS.x, ey*2*sgnS.y, ez*2*sgnS.z};
  V3 borig = vSub(pivot, vMul(bsize, 0.5f));
  BBCube res; res.origin = borig; res.size = bsize; res.pivot = pivot; res.rot = brot;
  for (size_t k = 0; k < infos.size(); k++) {
    V3 nl = bestM.tmul(infos[k].n);
    V3 ul = bestM.tmul(infos[k].tu), vl = bestM.tmul(infos[k].tv);
    V3 rU, rV; ExpectUV(nl, rU, rV);
    V3 eU = vEMul(rU, sgnS), eV = vEMul(rV, sgnS);
    float umn=1e9,vmn=1e9,umx=-1e9,vmx=-1e9;
    for (int i = 0; i < 4; i++) {
      float u = infos[k].f->v[i].u * texW, v = infos[k].f->v[i].v * texH;
      umn=fminf(umn,u); umx=fmaxf(umx,u); vmn=fminf(vmn,v); vmx=fmaxf(vmx,v);
    }
    float su=umn, sv=vmn, du=umx-umn, dv=vmx-vmn;
    if (vDot(ul, eU) < -0.2f) { su = umx; du = -du; }
    if (vDot(vl, eV) < -0.2f) { sv = vmx; dv = -dv; }
    UVBox box = {Clean4(su), Clean4(sv), Clean4(du), Clean4(dv)};
    if (nl.x > 0.9f) res.uv["east"] = box;
    else if (nl.x < -0.9f) res.uv["west"] = box;
    else if (nl.y > 0.9f) res.uv["up"] = box;
    else if (nl.y < -0.9f) res.uv["down"] = box;
    else if (nl.z > 0.9f) res.uv["south"] = box;
    else if (nl.z < -0.9f) res.uv["north"] = box;
  }
  return res;
}

} // namespace MWBYSM

@implementation MWBYSMCodec

// 几何数值修约（参考 clean_number 保留 5 位小数）
static NSNumber *Round5(float v) {
  if (fabsf(v) < 1e-9f) v = 0;
  float r = roundf(v);
  double o = (fabs(v - r) < 1e-6) ? r : round(v * 100000.0) / 100000.0;
  return @(o);
}

#define MWB_FAIL(代码, 格式, ...) do { \
  if (err) *err = [NSError errorWithDomain:kMWBYSMErrDomain code:(代码) \
    userInfo:@{NSLocalizedDescriptionKey: [NSString stringWithFormat:(格式), ##__VA_ARGS__]}]; \
  NSLog(@"[魔玩盒子] 解码失败：%@", (*err).localizedDescription); \
  return NO; } while (0)

+ (BOOL)loadYSM:(NSURL *)url
          bones:(NSArray **)outBones
     texturePNG:(NSData **)outPNG
            texW:(int *)w
            texH:(int *)h
           error:(NSError **)err {
  if (!url) { MWB_FAIL(1, @"缺少文件地址"); }
  NSData *文件 = [NSData dataWithContentsOfURL:url options:0 error:err];
  if (!文件) { NSLog(@"[魔玩盒子] 解码失败：读不到文件"); return NO; }
  const uint8_t *字节 = (const uint8_t *)文件.bytes;
  size_t 总长 = 文件.length;
  if (总长 < 8 + 4 + 64) { MWB_FAIL(2, @"文件太短，不是合法 .ysm"); }

  // 1) 容器：BOM + YSGP + CRLF 头文本 + 0x00，遇首个 NUL 截断取 <format>
  if (!(字节[0] == 0xEF && 字节[1] == 0xBB && 字节[2] == 0xBF &&
        字节[3] == 'Y' && 字节[4] == 'S' && 字节[5] == 'G' && 字节[6] == 'P')) {
    MWB_FAIL(3, @"缺少 YSGP 容器头");
  }
  size_t 头止 = 0;
  for (size_t i = 7; i < 总长; i++) { if (字节[i] == 0x00) { 头止 = i; break; } }
  if (头止 == 0) { MWB_FAIL(4, @"找不到头文本结束符"); }
  NSString *头文本 = [[NSString alloc] initWithBytes:字节 length:头止 encoding:NSUTF8StringEncoding];
  if (!头文本) { MWB_FAIL(5, @"头文本不是合法 UTF-8"); }
  NSRange 格式位 = [头文本 rangeOfString:@"<format>"];
  if (格式位.location == NSNotFound) { MWB_FAIL(6, @"头文本缺少 <format>"); }
  NSString *格式尾 = [[头文本 substringFromIndex:格式位.location + 格式位.length]
    stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  int 格式号 = 0; NSScanner *扫描 = [NSScanner scannerWithString:格式尾];
  if (![扫描 scanInt:&格式号] || 格式号 != 32) { MWB_FAIL(7, @"只支持 format 32，读到 %d", 格式号); }

  // 尾 64 字节：key32 + iv24 + fileHash LE64
  const uint8_t *尾 = 字节 + 总长 - 64;
  const uint8_t *密钥 = 尾, *iv = 尾 + 32;
  uint64_t 文件哈希 = MWBYSM::ReadU64(尾 + 56);

  // 2) 校验：CityHash64WithSeed(全文件除末 8 字节)
  uint64_t 算哈希 = MWBYSM::CityHashSeed((const char *)字节, 总长 - 8, MWBYSM::kSeedFileVerification);
  if (算哈希 != 文件哈希) { MWB_FAIL(8, @"文件校验失败（哈希对不上，文件可能损坏）"); }

  // 二进制段：头止+1 开始，先读 LE32 crypto，必须 == 3
  size_t 二进制始 = 头止 + 1;
  if (二进制始 + 4 > 总长 - 64) { MWB_FAIL(9, @"二进制段缺失"); }
  if (MWBYSM::ReadU32(字节 + 二进制始) != 3) { MWB_FAIL(10, @"只支持 crypto 3"); }
  std::vector<uint8_t> 密文(字节 + 二进制始 + 4, 字节 + 总长 - 64);

  // 3) 解密 A：魔改 XChaCha；B：MT19937_64 异或；然后 n 取 2+n 字节头
  std::vector<uint8_t> 明文;
  MWBYSM::ModDecrypt(密文, 密钥, iv, 明文);
  MWBYSM::MTXor(明文, 密钥, iv);
  if (明文.size() < 2) { MWB_FAIL(11, @"解密后数据太短"); }
  uint16_t n = (uint16_t)(明文[0] | (明文[1] << 8)); n &= 0x3FF;
  if ((size_t)2 + n > 明文.size()) { MWB_FAIL(12, @"解密头长度越界"); }
  std::vector<uint8_t> 待解压(明文.begin() + 2 + n, 明文.end());

  // 4) 洗白 + 标准 zstd 解压
  std::vector<uint8_t> 洗后;
  if (!MWBYSM::Wash(待解压, 洗后)) { MWB_FAIL(13, @"不是合法的魔改 zstd 流"); }
  std::vector<uint8_t> 解压后;
  if (!MWBYSM::SystemZstd(洗后, 解压后)) {
    MWB_FAIL(14, @"zstd 解压失败（数据损坏或内存不足）");
  }

  // 5) 二进制 walk：顺序流按序推进
  MWBYSM::Cursor 读(解压后.data(), 解压后.size());
  if (读.off + 4 > 读.len) { MWB_FAIL(15, @"解压数据缺版本号"); }
  uint32_t 版本 = MWBYSM::ReadU32(读.data + 读.off); 读.off += 4; // LE32，必须 == format
  if ((int)版本 != 格式号) { MWB_FAIL(16, @"版本号 %u 与头 format 不一致", 版本); }

  MWBYSM::SkipSounds(读);
  MWBYSM::SkipFuncs(读);
  MWBYSM::SkipLangs(读);
  if (!读.ok) { MWB_FAIL(17, @"声音/函数/语言段损坏"); }
  // format 32 现代分支：载具[] + 投掷物[]
  uint64_t 载具数 = 读.varint();
  for (uint64_t i = 0; i < 载具数 && 读.ok; i++) MWBYSM::SkipSubEntity(读);
  uint64_t 弹数 = 读.varint();
  for (uint64_t i = 0; i < 弹数 && 读.ok; i++) MWBYSM::SkipSubEntity(读);
  if (读.varint() != 1) { MWB_FAIL(18, @"子实体尾标志不是 1"); }
  // 动画[]（modelId + 动画体）
  uint64_t 动画数 = 读.varint();
  for (uint64_t i = 0; i < 动画数 && 读.ok; i++) { 读.varint(); MWBYSM::SkipAnims(读); }
  // 控制器[]（名称 + 哈希 + 控制器体）
  uint64_t 控数 = 读.varint();
  for (uint64_t i = 0; i < 控数 && 读.ok; i++) {
    读.skipStr(); 读.skipStr(); MWBYSM::SkipControllers(读);
  }
  if (!读.ok) { MWB_FAIL(19, @"动画/控制器段损坏"); }

  // 纹理[]：只保留 name=="white" 的 PNG 原字节（现代路径纹理即 PNG 字节直存）
  NSData *白图 = nil; int 白宽 = 0, 白高 = 0;
  {
    uint64_t 纹数 = 读.varint();
    for (uint64_t i = 0; i < 纹数 && 读.ok; i++) {
      std::string 名称 = 读.getStr(); 读.skipStr(); // 名称 + 哈希
      std::vector<uint8_t> 原字节 = 读.getBytes();
      uint64_t 纹宽 = 读.varint(), 纹高 = 读.varint();
      读.varint(); 读.varint(); // 图片格式 + 未知标志（只告警不断言）
      uint64_t 子数 = 读.varint();
      for (uint64_t s = 0; s < 子数 && 读.ok; s++) {
        读.varint(); MWBYSM::GetSpecial(读);
        读.varint(); 读.varint(); 读.varint(); 读.varint();
      }
      if (名称 == "white" && !白图 && !原字节.empty()) {
        白图 = [NSData dataWithBytes:原字节.data() length:原字节.size()];
        白宽 = (int)纹宽; 白高 = (int)纹高;
      }
    }
  }
  if (!读.ok) { MWB_FAIL(20, @"纹理段损坏"); }
  if (!白图) { MWB_FAIL(21, @"没找到名为 white 的纹理"); }

  // 模型[]：只保留 modelId==1 的完整模型
  std::vector<MWBYSM::RawBone> 主骨骼; float 主纹宽 = 0, 主纹高 = 0; bool 拿到主模型 = NO;
  {
    uint64_t 模型数 = 读.varint();
    for (uint64_t i = 0; i < 模型数 && 读.ok; i++) {
      uint64_t 模型号 = 读.varint();
      std::vector<MWBYSM::RawBone> 骨; float 纹宽 = 0, 纹高 = 0;
      if (!MWBYSM::WalkModel(读, 模型号 == 1, 骨, 纹宽, 纹高)) break;
      if (模型号 == 1 && !拿到主模型) {
        主骨骼 = 骨; 主纹宽 = 纹宽; 主纹高 = 纹高; 拿到主模型 = YES;
      }
    }
  }
  if (!读.ok) { MWB_FAIL(22, @"模型段损坏"); }
  if (!拿到主模型) { MWB_FAIL(23, @"没找到 modelId==1 的主模型"); }
  // 读完 models 直接返回，不进 ParseYSMJson
  if (主纹宽 <= 0) 主纹宽 = (float)白宽;
  if (主纹高 <= 0) 主纹高 = (float)白高;

  // 6) 盒子还原 + 组装输出
  NSMutableArray *骨骼数组 = [NSMutableArray new];
  for (size_t bi = 0; bi < 主骨骼.size(); bi++) {
    const MWBYSM::RawBone &骨 = 主骨骼[bi];
    NSMutableArray *方块数组 = [NSMutableArray new];
    for (size_t ci = 0; ci < 骨.cubes.size(); ci++) {
      MWBYSM::BBCube 盒 = MWBYSM::RestoreCube(骨.cubes[ci].faces, (int)主纹宽, (int)主纹高);
      NSMutableDictionary *uv表 = [NSMutableDictionary new];
      static const char *面序[6] = {"east","west","up","down","south","north"};
      for (int fi = 0; fi < 6; fi++) {
        std::string 键 = 面序[fi];
        auto 找 = 盒.uv.find(键);
        if (找 != 盒.uv.end())
          uv表[@(面序[fi])] = @[@(找->second.u), @(找->second.v),
                                @(找->second.du), @(找->second.dv)];
      }
      [方块数组 addObject:@{
        @"origin": @[Round5(盒.origin.x), Round5(盒.origin.y), Round5(盒.origin.z)],
        @"size": @[Round5(盒.size.x), Round5(盒.size.y), Round5(盒.size.z)],
        @"pivot": @[Round5(盒.pivot.x), Round5(盒.pivot.y), Round5(盒.pivot.z)],
        @"rotation": @[Round5(盒.rot.x), Round5(盒.rot.y), Round5(盒.rot.z)],
        @"uv": uv表,
      }];
    }
    // 枢轴 X 翻转；旋转 X/Y 翻转并转度（与参考一致）
    float 度 = (float)(180.0 / M_PI);
    NSString *名 = [NSString stringWithUTF8String:骨.name.c_str()];
    if (!名) 名 = @"";
    NSString *父 = [NSString stringWithUTF8String:骨.parent.c_str()];
    if (!父) 父 = @"";
    [骨骼数组 addObject:@{
      @"name": 名, @"parent": 父,
      @"pivot": @[Round5(-骨.pivot[0]), Round5(骨.pivot[1]), Round5(骨.pivot[2])],
      @"rotation": @[Round5(-骨.rot[0]*度), Round5(-骨.rot[1]*度), Round5(骨.rot[2]*度)],
      @"cubes": 方块数组,
    }];
  }

  if (outBones) *outBones = 骨骼数组;
  if (outPNG) *outPNG = 白图;
  if (w) *w = 白宽; if (h) *h = 白高;
  NSLog(@"[魔玩盒子] 解码成功：骨骼 %lu，白图 %lu 字节 %dx%d",
    (unsigned long)骨骼数组.count, (unsigned long)白图.length, 白宽, 白高);
  return YES;
}

@end
