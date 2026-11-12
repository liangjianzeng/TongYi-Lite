/*
 * [npu-line M2 Phase C-2] Engine accessor for the hybrid path.
 *
 * The GPU inference engine lives in tongyilite_jni.cpp (static g_engine).
 * The hybrid entries (hyb_jni.cpp) need the loaded model/context and the
 * JVM handle without touching that 250KB TU's internals — this single
 * getter is the whole cross-TU surface (zero-regression discipline: the
 * GPU path is byte-unchanged; everything hybrid lives in hyb_jni.cpp).
 *
 * Threading contract (same discipline as the existing engine):
 *   - callers run on the Kotlin single-thread engine executor
 *     (MainActivity dispatches hybrid ops through engine.onEngineThread),
 *     which is the same queue as completion/destroy -> llama_* calls from
 *     hyb_jni.cpp serialize with GPU generation by construction;
 *   - begin_hybrid()/end_hybrid() additionally claim the engine (mirrors
 *     completion()'s is_running claim) so a hybrid generation and a GPU
 *     completion can never interleave even if a future caller forgets.
 */
#ifndef TONGYILITE_ENGINE_H
#define TONGYILITE_ENGINE_H

#include <stdint.h>
#include <jni.h> /* JNIEnv/jstring for build_prompt_ids (Android-only header) */

#ifdef __cplusplus
extern "C" {
#endif

/* ABI 3 (+kv_cache_type, +feeds_eos_id). KV-cache selector encoding is the
 * engine's own (nativeSetKvCacheType): 0=q4_0, 1=q8_0, 2=f16 — NOT the ggml
 * type enum. The hybrid path requires F16: the frozen state container is
 * written F16 and llama_state_seq_load_file hard-validates the context's
 * cache type, so a q4_0/q8_0 context can never load it (fail closed early
 * instead of burning chain time). */
#define TONGYILITE_ENGINE_ABI 3
#define TONGYI_KV_CACHE_Q4_0 0
#define TONGYI_KV_CACHE_Q8_0 1
#define TONGYI_KV_CACHE_F16  2

typedef struct TongYiLiteEngineHandle {
    int32_t abi;              /* == TONGYILITE_ENGINE_ABI               */

    /* Raw llama.cpp handles for the LOADED model. Valid only while
     * is_loaded() returns 1. Types erased to void* so this header stays
     * dependency-free; hyb_jni.cpp casts back via llama.h. */
    void *model;              /* llama_model *   (g_engine.model)   */
    void *context;            /* llama_context * (g_engine.context) */
    void *jvm;                /* JavaVM *        (JNI_OnLoad's vm)  */

    /* State guards (implemented over g_engine's atomics). */
    int (*is_loaded)(void);   /* 1 when model+context+n_ctx valid     */
    int (*begin_hybrid)(void);/* claim: 1 on success, 0 when busy.
                               * Also invalidates the cross-turn KV
                               * bookkeeping — the injected state makes
                               * prev_prompt_tokens/have_prev_kv stale. */
    void (*end_hybrid)(void);
    int (*should_stop)(void); /* user stopGeneration() observed       */

    /* Prompt -> token ids for the NPU chain, reusing the GPU path's own
     * helpers (parseMessagesJson + apply_chat_template_grown + tokenize +
     * add_bos == llama_vocab_get_add_bos). Chatml-route models only:
     * returns -2 for the GGUF-embedded-jinja gate models (clover /
     * bailing-ling / nanbeige) whose template parity is a C-3 device item.
     * messagesJson: JSON array [{"role","content"}...] as a jstring (last
     * element = live user message, same convention as completion);
     * prompt: raw text used only when messagesJson is empty/absent
     * (parity with nativeCompletion's raw path).
     * Returns token count, 0 on empty prompt, or negative:
     *   -1 not loaded | -2 template gate | -3 template render failed
     *   -4 empty input | -5 tokenizer failed | -6 out_cap too small      */
    int (*build_prompt_ids)(void *env, jstring messagesJson,
                            const char *prompt,
                            int32_t *out, int out_cap);

    /* ---- [npu-line M2 Phase C-3] prompt feeds 模型量 ----------------
     * Read from the LOADED model's own GGUF (direct gguf API, cached):
     * llama.embedding_length / llama.attention.head_count /
     * llama.rope.freq_base / token_embd tensor meta. Both return -1 when
     * nothing is loaded or the GGUF cannot be re-parsed — the caller then
     * keeps the structured stage=prefill_feeds failure (GPU fallback). */

    /* rope base theta (>0) + rotary dims hd (>0, even), embedding width hid
     * and vocab size. MiniCPM5 = full rotary, hd = hid / n_head. */
    int (*feeds_model_info)(double *theta, int *hd, int *hid, int *n_vocab);

    /* rows[i] = fp16 bit pattern of token_embd row ids[i]; out holds n*hid
     * uint16. Quantized token_embd is dequantized via ggml type traits
     * (GGUF F16 embeddings = pure bit copy). Returns 0, or -1 (ids/out null,
     * id >= n_vocab, GGUF/table unavailable). */
    int (*feeds_read_embd)(const int32_t *ids, int n, uint16_t *out);

    /* ---- [npu-line M2 C-3 review fixes] -------------------------------- */

    /* Engine KV cache selector (TONGYI_KV_CACHE_* above); the value the
     * context was actually built with (nativeSetKvCacheType). */
    int (*kv_cache_type)(void);

    /* Chain-protocol eos pad id, read from the model GGUF's own
     * tokenizer.ggml.eos_token_id[0] (the frozen gen_ids/A3b source — no
     * vocab guessing). Returns 0, or -1 when the key is absent/unusable
     * (caller must fail closed: chain ids pad is protocol-critical). */
    int (*feeds_eos_id)(int32_t *eos);
} TongYiLiteEngineHandle;

/* NULL until JNI_OnLoad has run; fields refreshed per call (model may be
 * reloaded between hybrid sessions — always re-read through the handle). */
const TongYiLiteEngineHandle *tongyilite_engine_handle(void);

#ifdef __cplusplus
}
#endif

#endif /* TONGYILITE_ENGINE_H */
