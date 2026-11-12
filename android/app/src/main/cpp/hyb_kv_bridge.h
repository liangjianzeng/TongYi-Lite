/*
 * [npu-line M2 Phase C] NPU prefill KV -> llama.cpp sequence-state bridge.
 *
 * Converts the NPU (QNN/HTP, chain_run5 protocol) per-layer kc/vc raw dumps
 * into a container accepted by the official llama.cpp channel
 * llama_state_seq_load_file(). Byte-for-byte equivalent to the frozen
 * reference writer npu-line/probe_m1/dec2/mcp5_95_kv_bridge.py (Phase A,
 * plan §6.1/§6.2 — spec frozen there; acceptance = zero-byte diff against
 * E:/MyLLM_exp/hyb/bridged172.state, see hyb_kv_bridge_selftest.sh).
 *
 * Source layout (plan §6.2, gold-checked):
 *   one file per layer per tensor: [NC=512][HD=128][NKV=2] fp16,
 *   S-major, kv-head fastest axis == HF post-rope space.
 *   kv-head j slice of token s = raw[s, :, j] (128 fp16, stride NKV).
 *
 * Container layout (plan §6.1, golden-backed, leftover=0; llama-kv-cache.cpp
 * state_seq writer, no io_magic on the file path):
 *   [u32 magic 0x67677371][u32 ver][u32 n_tok][tokens x i32]
 *   [u32 n_stream=1][u32 cell_count]
 *   per cell {i32 pos, u32 n_seq=1, i32 sids x n_seq}      (token order)
 *   [u32 v_trans=0][u32 n_layer]
 *   v4 only (lc fork c1a2cb0 = App lineage): [u32 n_rot_k=0][u32 n_rot_v=0]
 *     (F16 cache => attn_rot off; loader validates at llama-kv-cache.cpp:2703)
 *   per layer K: {i32 type=1(F16), u64 row_bytes} + cell_count rows
 *   per layer V: same shape
 *   row = concat over j of head j's HD fp16 values (row_bytes = HD*NKV*2).
 *
 * State container version: the App embeds the lc-fork lineage (c1a2cb0) whose
 * loader is STATE_SEQ VERSION 4, so the default here is v4. v3 matches the
 * upstream 5c200e0 toolchain used in Phase A (acceptance golden of the old
 * run). Override at build time with -DHYB_BRIDGE_DEFAULT_VER=3/4 or per-call
 * via hyb_kv_params::state_ver.
 *
 * Bridge recipe (plan §6.2, judge-graded):
 *   K row per head: half2inter  out[0::2]=x[:HD/2]; out[1::2]=x[HD/2:]
 *   V row per head: plain copy
 *   cell order = token order; cell_count == n_real (eos-pad cells MUST be
 *   cut — protocol-level requirement, the decode causal mask cannot
 *   exclude pads otherwise).
 *
 * Pure C11 + stdio only: compiles for Android (NDK, part of libtongyilite_jni)
 * AND for the host (gcc/mingw/clang) so the selftest can run the exact same
 * translation unit the APK ships.
 */
#ifndef HYB_KV_BRIDGE_H
#define HYB_KV_BRIDGE_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/* Frozen protocol constants (plan §6.1/§6.2; MiniCPM5-2B, chain_run5). */
#define HYB_STATE_MAGIC   0x67677371u /* "qsgg" little-endian stream magic */
/* Default container version: 4 = lc fork (c1a2cb0) = App-inlined llama.
 * 3 = upstream 5c200e0 (Phase A toolchain). Per-call override in params. */
#ifndef HYB_BRIDGE_DEFAULT_VER
#define HYB_BRIDGE_DEFAULT_VER 4
#endif
#define HYB_STATE_VER_MIN 3
#define HYB_STATE_VER_MAX 4
#define HYB_KV_TYPE_F16   1
#define HYB_NC_DEFAULT    512  /* chain window NC (static 512-shape protocol) */
#define HYB_HD_DEFAULT    128  /* head dim (fp16 elems)                      */
#define HYB_NKV_DEFAULT   2    /* kv heads (unexpanded, HF post-rope space)  */
#define HYB_NL_DEFAULT    42   /* n_layer of MiniCPM5-2B                     */
#define HYB_P0_DEFAULT    88   /* pos base of the frozen A5/172 protocol     */

/* Structured error codes (shared with the JNI layer; keep stable). */
#define HYB_OK              0
#define HYB_ERR_NOT_ENABLED (-1)  /* feature gate closed / device side absent */
#define HYB_ERR_BAD_PARAM   (-2)
#define HYB_ERR_IO          (-3)  /* input missing / short / uncreatable out  */
#define HYB_ERR_FORMAT      (-4)  /* input size / value sanity failure        */
#define HYB_ERR_INTERNAL    (-5)
#define HYB_ERR_BUSY        (-6)  /* engine claimed by another generation     */

typedef struct {
    /* Directory holding the per-layer raws. */
    const char *kv_dir;
    /* printf-style file name templates (layer index substituted);
     * NULL => "d2q_kc_%d.raw" / "d2q_vc_%d.raw" (chain_run5 cache dump names). */
    const char *kc_fmt;
    const char *vc_fmt;
    /* Token ids: little-endian i32, at least n_real entries (e.g. ids.raw). */
    const char *ids_path;
    /* Output container path (fwrite'd; parent dir must exist). */
    const char *out_path;

    /* NREAL: real token count. eos-pad cells (n_real..nc-1) are cut. */
    int n_real;
    int n_layers;   /* 0 => HYB_NL_DEFAULT */
    int nc;         /* chain window NC     */
    int hd;         /* 0 => HYB_HD_DEFAULT */
    int nkv;        /* 0 => HYB_NKV_DEFAULT */
    long long pos_base; /* cell pos = pos_base + token_index */
    int v_h2i;      /* 0 => V plain copy (frozen recipe); 1 => V half2inter  */
    int state_ver;  /* state container version; 0 => HYB_BRIDGE_DEFAULT_VER  */
} hyb_kv_params;

/*
 * Run the full conversion. Returns HYB_OK or a negative HYB_ERR_* code.
 * On failure `err` (may be NULL) receives a one-line human-readable reason,
 * and the output file — if created — is removed (no half-written containers).
 */
int hyb_kv_bridge_convert(const hyb_kv_params *p, char *err, size_t errlen);

#ifdef __cplusplus
}
#endif

#endif /* HYB_KV_BRIDGE_H */
