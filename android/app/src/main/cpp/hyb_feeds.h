/* [npu-line M2 Phase C-3] NPU 链 prompt feeds 生成器（d2q_* 家族）。
 *
 * 正解化 C-2 的 stage=prefill_feeds 设备缺口：prep77b（npu-line/probe_m1/
 * dec2/mcp5_95_prep77b.py）主机侧用 HF fp16 产的 d2q_* 输入，本模块在端侧
 * 按同一协议逐字节同构地生成，喂给 chain_run5（manifest 以 cwd 相对名引用，
 * 见 mcp5_79_gen_pre2_manifests.py；S=128/NC=512/HD=128/NKV=2/P0=88 冻结，
 * hid/theta 是模型量、由调用方给）：
 *
 *   d2q_emb_{c}.raw  每 chunk embedding，(hid, s) 块（HF e.T.contiguous()
 *                    语义）：out[(c*hid+h)*s+i] = rows[t][h]，t=c*s+i。
 *                    rows 由调用方预取好（端侧 = GGUF token_embd 按 id 逐行
 *                    读 + 反量化；ids 尾部 pad 到 chunks*s 由调用方负责，
 *                    链侧恒满 NC——无-pad 剪 cell 只发生在桥处）。
 *   d2q_am_{c}.raw   fp16 [S, NC+S] ravel：0；列 [0,pad)=NEG、列 [NC,NC+S)
 *                    上三角(diag=1)=NEG；pad=NC-c*S；NEG=fp16(-1e4)。
 *   d2q_cos_table.raw  chunks 个 (HD, S) 块堆叠（方形 [S,HD] 张量的设备转置
 *   d2q_sin_table.raw  规则）：out[(c*HD+j)*s+i] = trig(pos_base+t, j%(HD/2))，
 *                    freq_j = theta^(-2j/HD)（HF rotary half-duplication）。
 *   d2q_kc0.raw      (NC, HD, NKV) fp16 全零；设备链从 0 滚窗。
 *   d2q_vc0.raw      同。
 *
 * 纯 C11 + stdio + libm，无 llama/ggml 依赖 → 主机可编译可单测
 * （hyb_feeds_selftest.sh：WSL torch 参考逐字节对拍）。embedding 稠密
 * fp16 行表由调用方提供（端侧 = tongyilite_jni.cpp read_embd_rows：
 * GGUF 直读 token_embd + ggml type-traits 反量化到 f16）。
 */
#ifndef HYB_FEEDS_H
#define HYB_FEEDS_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* 冻结协议默认值（链侧；hid/theta 是模型量不在此列）。 */
#define HYB_FEEDS_S_DEFAULT      128
#define HYB_FEEDS_NC_DEFAULT     512
#define HYB_FEEDS_CHUNKS_DEFAULT 4
#define HYB_FEEDS_HD_DEFAULT     128
#define HYB_FEEDS_NKV_DEFAULT    2
#define HYB_FEEDS_P0_DEFAULT     88
#define HYB_FEEDS_PREFIX         "d2q_"
#define HYB_FEEDS_NEG            (-10000.0f) /* amask 屏蔽值（fp16 前） */

/* f32 → IEEE half bits（round-to-nearest-even）。 */
uint16_t hyb_f32_to_f16(float f);

/* 各生成器写 dir/<prefix><file>，已存在即覆盖（生成即权威，调用方只在
 * 缺件时调用）。成功 0；失败 -1 填 err 并清半成品。 */

/* kc0/vc0：(NC, HD, NKV) fp16 全零 ×2（NC=chunks*s 由调用方保证）。 */
int hyb_feeds_gen_kc0(const char *dir, int nc, int hd, int nkv,
                      char *err, size_t errlen);

/* am_0..am_{chunks-1}：协议 mask，行 ravel [s, nc+s]（纯协议，逐字节判卷）。 */
int hyb_feeds_gen_am(const char *dir, int chunks, int s, int nc,
                     char *err, size_t errlen);

/* cos/sin 表：chunks×(hd, s)，pos 自 pos_base 连续 chunks*s 行。
 * theta<=0 / hd 奇数<=2 视为参数错误。 */
int hyb_feeds_gen_rope(const char *dir, long long pos_base, int chunks, int s,
                       int hd, double theta, char *err, size_t errlen);

/* emb_0..emb_{chunks-1}：chunks×(hid, s)。rows = 调用方预取的稠密 fp16 行
 * （total×hid，total=chunks*s，含 eos-pad 尾部——prep77b 语义）；本函数只做
 * 布局转置，不看 vocab。 */
int hyb_feeds_gen_emb(const char *dir, const uint16_t *rows, int total,
                      int s, int hid, char *err, size_t errlen);

#ifdef __cplusplus
}
#endif

#endif /* HYB_FEEDS_H */
