/**
 * TongYi-Lite JNI Bridge
 *
 * Design principles (validated against llama.cpp b10173 official com.arm.aichat example):
 * 1. Direct JNI calls to llama C API — NO HTTP server inside the APK
 * 2. Token-by-token callback to Dart via JNI to achieve streaming typewriter effect
 * 3. Thread-safe: inference runs on a dedicated native thread, not the UI thread
 */

#include <android/log.h>
#include <jni.h>
#include <string>
#include <vector>
#include <mutex>
#include <thread>
#include <future>
#include <condition_variable>
#include <atomic>
#include <algorithm>
#include <cmath>
#include <functional>
#include <sstream>
#include <deque>

// llama.cpp headers
#include "llama.h"
#include "common.h"
#include "ggml-backend.h"

#define LOG_TAG "TongYiLite"
static void reportLoadingLog(const char *message);
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  LOG_TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN,  LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

// ============================================================================
// GPU detection
// ============================================================================
// Probe the ggml backend registry for a usable GPU device (Vulkan on Android).
// Returns the number of layers to offload: 0 when no GPU is present, or a
// large value ("all layers") when one is. Doing this at runtime — instead of
// hardcoding n_gpu_layers — keeps the same APK working on devices whose driver
// does not expose Vulkan, where blindly asking for GPU layers used to hang the
// loader while trying to reserve device memory.
static int detect_gpu_layers() {
    const size_t n_dev = ggml_backend_dev_count();
    LOGI("ggml backend devices: %zu", n_dev);

    int gpu_found = 0;
    for (size_t i = 0; i < n_dev; i++) {
        ggml_backend_dev_t dev = ggml_backend_dev_get(i);
        if (!dev) {
            continue;
        }
        const enum ggml_backend_dev_type type = ggml_backend_dev_type(dev);
        size_t free_mem = 0, total_mem = 0;
        ggml_backend_dev_memory(dev, &free_mem, &total_mem);
        LOGI("  device[%zu] name=%s desc=%s type=%d mem=%.0f/%.0f MiB",
             i,
             ggml_backend_dev_name(dev)        ? ggml_backend_dev_name(dev)        : "?",
             ggml_backend_dev_description(dev) ? ggml_backend_dev_description(dev) : "?",
             (int)type,
             free_mem  / 1048576.0,
             total_mem / 1048576.0);
        // Accept both discrete GPUs (GGML_BACKEND_DEVICE_TYPE_GPU) and
        // integrated GPUs (GGML_BACKEND_DEVICE_TYPE_IGPU). On Android the
        // Vulkan backend enumerates Adreno / Mali as IGPU (type=2), NOT as
        // GPU (type=1), so only checking GPU used to miss mobile Vulkan.
        if (type == GGML_BACKEND_DEVICE_TYPE_GPU ||
            type == GGML_BACKEND_DEVICE_TYPE_IGPU) {
            gpu_found = 1;
        }
    }

    if (!gpu_found) {
        LOGW("No GPU backend available -> CPU-only inference");
        return 0;
    }
    LOGI("GPU backend available -> offloading all layers");
    return 999;
}

// ============================================================================
// LoadingCallback — C-side callback interface for loading progress logs
// ============================================================================

// ============================================================================
static void reportLoadingLog(const char *message);
// InferenceEngine — wraps model + context + generation
// ============================================================================

// ----------------------------------------------------------------------------
// UTF-8 helpers — keep Java string construction crash-free
// ----------------------------------------------------------------------------
// llama.cpp emits token pieces as raw bytes. For bytes >= 0x80 with no matching
// vocab token it uses "byte-fallback" tokens that produce ONE byte at a time
// (e.g. a lone 0xBE). Passing such bytes straight to JNI's NewStringUTF() aborts
// the process ("input is not valid Modified UTF-8: illegal start byte"). We
// therefore (a) buffer raw bytes across tokens and only forward *complete* UTF-8
// sequences to the callback, and (b) build Java strings via UTF-16 so any stray
// byte becomes U+FFFD instead of crashing the app.
// ----------------------------------------------------------------------------
static int utf8_seq_len(const std::string &s, size_t pos) {
    if (pos >= s.size()) return 0;
    unsigned char c = (unsigned char)s[pos];
    int len;
    if      (c < 0x80)       len = 1;
    else if ((c & 0xE0) == 0xC0) len = 2;
    else if ((c & 0xF0) == 0xE0) len = 3;
    else if ((c & 0xF8) == 0xF0) len = 4;
    else return -1; // invalid lead byte -> consume 1 as replacement
    if (pos + (size_t)len > s.size()) return 0; // incomplete tail, wait for more
    for (int k = 1; k < len; k++) {
        unsigned char cc = (unsigned char)s[pos + k];
        if ((cc & 0xC0) != 0x80) return -1; // not a continuation byte -> invalid
    }
    return len;
}

static jstring utf8_to_jstring(JNIEnv *env, const std::string &s) {
    std::u16string u16;
    size_t i = 0;
    while (i < s.size()) {
        int adv = utf8_seq_len(s, i);
        if (adv <= 0) { u16.push_back(0xFFFD); i++; continue; } // invalid/incomplete -> replacement
        uint32_t cp = (unsigned char)s[i] &
                      ((adv == 1) ? 0x7F : (adv == 2) ? 0x1F : (adv == 3) ? 0x0F : 0x07);
        for (int k = 1; k < adv; k++) {
            cp = (cp << 6) | ((unsigned char)s[i + k] & 0x3F);
        }
        i += adv;
        if (cp <= 0xFFFF) {
            u16.push_back((char16_t)cp);
        } else {
            cp -= 0x10000;
            u16.push_back((char16_t)(0xD800 | (cp >> 10)));
            u16.push_back((char16_t)(0xDC00 | (cp & 0x3FF)));
        }
    }
    return env->NewString((const jchar *)u16.data(), (jsize)u16.size());
}

// SentencePiece encodes spaces as U+2581 ("▁"). Render it as a normal ASCII
// space so output doesn't show a missing-glyph box.
static void sp_space_to_ascii(std::string &s) {
    const char sp[3] = { (char)0xE2, (char)0x96, (char)0x81 }; // "▁" UTF-8
    size_t pos = 0;
    while ((pos = s.find(sp, pos, 3)) != std::string::npos) {
        s.replace(pos, 3, " ");
        pos += 1;
    }
}

struct InferenceEngine {
    llama_model *model   = nullptr;
    const struct llama_vocab *vocab = nullptr; // extracted from model for new API
    llama_context *context = nullptr;
    llama_model_params model_params;
    llama_context_params ctx_params;

    // Generation state
    std::vector<llama_token> prompt_tokens;
    int n_prompt = 0;

    // Chat history — maintained across turns for multi-turn conversations.
    // Each entry is a llama_chat_message with role ("user"/"assistant") and content.
    std::vector<llama_chat_message> chat_history;

    // Control
    std::mutex mtx;
    std::atomic<bool> is_running{false};
    std::atomic<bool> should_stop{false};
    // User toggle: whether Qwen3-style "thinking" (<think>...</think>) is allowed.
    // Default false -> thinking is suppressed so the model answers directly.
    std::atomic<bool> enable_thinking{false};

    // Stats — atomic to prevent stale reads from completion() on another thread.
    std::atomic<int32_t> n_ctx{0};
    double t_prompt_ms = 0;
    double t_gen_ms = 0;
    int32_t n_gen = 0;

    // Persistent KV-cache write cursor. We use the proven com.arm.aichat design:
    // each turn APPENDS its tokens at monotonically increasing positions into the
    // SAME context, instead of clearing the cache and re-decoding from 0 every turn.
    // Clearing + re-decode collides with the hybrid recurrent cache's length tracking
    // on Adreno and corrupts multi-turn output (degenerate loop on round 2+).
    // kv_position is reset to 0 only for a brand-new conversation (resetContext()).
    llama_pos kv_position = 0;

    bool load(const char *model_path, int requested_n_ctx = 4096,
              bool enable_gpu = true, int gpu_layers = 20) {
        // Unload previous model FIRST — without holding the mutex during callbacks.
        unload();

        LOGI("Loading model from: %s", model_path);
        reportLoadingLog("正在加载 GGUF 模型文件...");

        // Model params
        model_params = llama_model_default_params();
        // GPU offloading policy (driven by the UI toggle + layer setting):
        //   - enable_gpu == false           -> pure CPU (n_gpu_layers = 0)
        //   - enable_gpu == true && GPU found -> offload `gpu_layers` user layers (default 20)
        //   - enable_gpu == true && no GPU   -> safe CPU fallback (same APK works everywhere)
        int effective_gpu_layers = 0;
        if (enable_gpu) {
            int detected = detect_gpu_layers();
            if (detected > 0) {
                // Adreno 825 (小米 onyx) + ggml-vulkan: PARTIAL offload
                // (n_gpu_layers in 1..N-1) corrupts output from the 2nd generated
                // token onward (collapses to padding token 151935 / 乱码). The cause
                // is the per-token GPU<->CPU layer boundary plus host KV-cache sync
                // on this driver. FULL offload (all transformer layers on the GPU,
                // KV cache also GPU-resident) avoids the boundary and is the working
                // configuration on this device. Therefore GPU-on == full offload and
                // the user's layer slider has no effect while GPU is enabled.
                effective_gpu_layers = 999;
                LOGI("GPU acceleration ON: FULL offload (all layers) to avoid partial-offload corruption on Adreno");
                reportLoadingLog("检测到 GPU，启用 Vulkan 全量卸载加速");
            } else {
                LOGI("GPU acceleration requested but no GPU backend found -> CPU-only fallback");
                reportLoadingLog("未检测到 GPU，回落 CPU 推理");
            }
        } else {
            LOGI("GPU acceleration disabled by user -> pure CPU");
            reportLoadingLog("已关闭 GPU 加速，使用 CPU 推理");
        }
        model_params.n_gpu_layers = effective_gpu_layers;
        LOGI("n_gpu_layers = %d", model_params.n_gpu_layers);
        // Use mmap for loading — faster and lower peak memory than loading
        // the entire file into RAM. On Android internal storage (ext4/f2fs)
        // mmap works reliably; file-lock issues only affect FAT32/external SD.
        model_params.load_mode = LLAMA_LOAD_MODE_MMAP;

        // Use unique_lock so we can unlock before JNI callbacks to prevent deadlock.
        std::unique_lock<std::mutex> lock(mtx);
        model = llama_model_load_from_file(model_path, model_params);
        if (!model) {
            LOGE("Failed to load model from: %s", model_path);
            reportLoadingLog("模型文件加载失败，请检查文件是否完整");
            return false;
        }

        vocab = llama_model_get_vocab(model);

        const int n_embd  = llama_model_n_embd(model);
        const int n_layer = llama_model_n_layer(model);
        const int64_t n_params = llama_model_n_params(model);
        LOGI("GGUF model loaded. params=%lld, n_embd=%d, n_layer=%d",
             (long long)n_params, n_embd, n_layer);

        char buf[256];
        snprintf(buf, sizeof(buf), "模型文件加载完成 (%.1fM 参数)", n_params / 1'000'000.0);

        // Release lock before calling reportLoadingLog (JNI callback) to avoid deadlock.
        lock.unlock();
        reportLoadingLog(buf);

        // Context params — ensure n_ctx is valid before passing to llama.
        ctx_params = llama_context_default_params();

        const int trained_ctx = llama_model_n_ctx_train(model);
        int effective_n_ctx = (requested_n_ctx > 0) ? requested_n_ctx : ((trained_ctx > 0) ? trained_ctx : 512);

        if (requested_n_ctx <= 0 || requested_n_ctx != effective_n_ctx) {
            LOGW("Using effective n_ctx=%d (requested=%d, trained=%d)", effective_n_ctx, requested_n_ctx, trained_ctx);
        }

        ctx_params.n_ctx = effective_n_ctx;
        ctx_params.n_batch = 512;
        ctx_params.n_ubatch = 256;
        // Use more worker threads than the conservative default (4). Cap at 8 so we
        // engage the big cores without over-subscribing big.LITTLE little cores.
        {
            unsigned hc = std::thread::hardware_concurrency();
            int nt = (int)(hc > 0 ? hc : 8);
            if (nt > 8) nt = 8;
            if (nt < 4) nt = 4;
            ctx_params.n_threads = nt;
            ctx_params.n_threads_batch = nt;
            LOGI("n_threads = %d (hardware_concurrency=%u)", nt, hc);
        }
        // Keep the default (non-unified) KV buffer. On this llama.cpp build the
        // unified buffer interacts badly with per-turn KV clearing; we instead
        // re-initialize the context from the loaded model every turn (see
        // completion()), so a unified buffer buys nothing here.
        ctx_params.kv_unified = false;

        if (effective_n_ctx > trained_ctx) {
            LOGW("Requested n_ctx=%d > trained=%d, capping.", effective_n_ctx, requested_n_ctx);
            ctx_params.n_ctx = trained_ctx;
            char buf2[128];
            snprintf(buf2, sizeof(buf2), "上下文已限制为训练最大值 %d", trained_ctx);
            reportLoadingLog(buf2);
        }

        // llama_init_from_model can hang indefinitely on OOM (no error code returned).
        // Run it in a separate thread with a timeout to prevent blocking the JNI thread.
        LOGI("Spawning context-creation thread (timeout=60s)...");
        reportLoadingLog("正在初始化推理上下文（可能需要30秒）...");

        std::future<llama_context*> future_ctx;

        future_ctx = std::async(std::launch::async, [this]() -> llama_context* {
            LOGI("Context creation thread started");
            llama_context *ctx = llama_init_from_model(this->model, this->ctx_params);
            if (ctx) {
                LOGI("Context created successfully. n_ctx=%d", llama_n_ctx(ctx));
                return ctx;
            } else {
                LOGE("llama_init_from_model returned nullptr (OOM?)");
                return nullptr;
            }
        });

        auto wait_result = future_ctx.wait_for(std::chrono::seconds(60));
        if (wait_result == std::future_status::timeout) {
            LOGE("Context creation timed out after 60s — possible OOM or deadlock");
            reportLoadingLog("上下文初始化超时（内存不足或设备性能不够）");
            llama_model_free(model);
            model = nullptr;
            return false;
        }

        {
            std::lock_guard<std::mutex> ctx_lock(mtx);
            context = future_ctx.get();
        }
        if (!context) {
            LOGE("Failed to create context (OOM?)");
            reportLoadingLog("创建推理上下文失败（内存不足? 请尝试更小的模型）");
            llama_model_free(model);
            model = nullptr;
            return false;
        }

        this->n_ctx.store(static_cast<int32_t>(llama_n_ctx(context)));
        kv_position = 0; // fresh model -> fresh conversation

        const int ctx_val = static_cast<int>(this->n_ctx.load());
        const uint32_t n_ctx_seq = llama_n_ctx_seq(context);
        LOGI("Model loaded. n_ctx=%d, n_ctx_seq=%u, n_embd=%d, n_layer=%d",
             ctx_val, n_ctx_seq,
             llama_model_n_embd(model),
             llama_model_n_layer(model));
        char buf3[128];
        snprintf(buf3, sizeof(buf3), "推理上下文初始化完成 (n_ctx=%d)", ctx_val);
        reportLoadingLog(buf3);
        return true;
    }

    void unload() {
        const int v = static_cast<int>(n_ctx.load());
        LOGI("unload() ENTER: context=%p model=%p n_ctx=%d is_running=%d", (void*)context, (void*)model, v, (int)is_running.load());
        std::lock_guard<std::mutex> lock(mtx);
        const int v2 = static_cast<int>(n_ctx.load());
        LOGI("unload() LOCK ACQUIRED: context=%p model=%p n_ctx=%d", (void*)context, (void*)model, v2);
        if (context)  { llama_free(context);  context = nullptr; }
        if (model)    { llama_model_free(model); model = nullptr; }
        vocab = nullptr;
        n_ctx = 0;
        is_running = false;
        const int v3 = static_cast<int>(n_ctx.load());
        LOGI("unload() DONE: context=%p model=%p n_ctx=%d", (void*)context, (void*)model, v3);
    }

    bool is_loaded() const {
        // Must also verify n_ctx > 0 — pointers alone can be stale garbage after unload.
        return model != nullptr && context != nullptr && n_ctx > 0;
    }

    // Reset the conversation KV cache. Called on model load and when the user starts
    // a brand-new chat, so the OLD conversation does not bleed into the new one.
    // NOTE: llama_memory_clear() is a NO-OP on this build's hybrid/unified KV cache
    // (it does not reset the per-sequence length counter). We MUST use
    // llama_memory_seq_rm(0, 0, n_ctx) to actually empty sequence 0 and reset its
    // length, otherwise the next completion decodes on top of stale KV and the model
    // degenerates from round 2 onward.
    void resetContext() {
        if (context != nullptr) {
            llama_memory_seq_rm(llama_get_memory(context), 0, 0, (llama_pos)llama_n_ctx(context));
        }
        kv_position = 0;
        LOGI("resetContext(): KV cache cleared (seq_rm), kv_position=0 (new conversation)");
    }

    // ------------------------------------------------------------------
    // Tokenize prompt
    // ------------------------------------------------------------------
    std::vector<llama_token> tokenize(const char *text, bool add_bos) {
        int n_chars = text == nullptr ? 0 : (int)strlen(text);
        // Allocate extra space: llama_tokenize may need more than char count for multi-byte chars
        std::vector<llama_token> tokens(n_chars + 16);
        int n = llama_tokenize(vocab, text, n_chars, tokens.data(), tokens.size(), add_bos, true);
        if (n < 0) {
            // n is negative: |n| = required buffer size
            tokens.resize(-n);
            // Retry with correct size
            n = llama_tokenize(vocab, text, n_chars, tokens.data(), tokens.size(), add_bos, true);
        }
        if (n < 0) {
            LOGE("tokenize() failed: %d", n);
            return {};
        }
        tokens.resize(n);
        LOGI("tokenize(): '%s' -> %d tokens (add_bos=%d)", text, (int)tokens.size(), add_bos);
        return tokens;
    }

    // ------------------------------------------------------------------
    // Synchronous completion (blocking, used by JNI)
    // ------------------------------------------------------------------
    std::string completion(
        const char *prompt,
        int max_tokens = 2048,
        float temperature = 0.7f,
        float top_p = 0.9f,
        // callback: called for each generated token; return false to stop
        std::function<bool(const std::string &)> on_token = nullptr,
        // Optional chat history to apply template before tokenization.
        // If non-empty, the template is applied and 'prompt' is used as the
        // final user message appended to history.  Empty history falls back
        // to raw prompt (backward compatible).
        const std::vector<llama_chat_message> *history = nullptr
    ) {
        const int ctx_val = static_cast<int>(n_ctx.load());
        LOGI("completion() ENTER: model=%p context=%p n_ctx=%d is_running=%d",
             (void*)model, (void*)context, ctx_val, (int)is_running.load());
        LOGI("===== TongYiLite JNI keep-ctx+seq_rm+batch-prefill+sampler-chain BUILD 20260804f =====");
        // Hold the lock for the ENTIRE duration of completion to prevent unload()
        // from running concurrently and destroying model/context mid-inference.
        std::lock_guard<std::mutex> lock(mtx);
        LOGI("completion() LOCK ACQUIRED: model=%p context=%p n_ctx=%d",
             (void*)model, (void*)context, ctx_val);

        if (!is_loaded()) {
            LOGE("completion() aborted INSIDE LOCK: no model loaded");
            return "[ERROR: No model loaded]";
        }

        try {
            is_running  = true;
            should_stop = false;

            // Multi-turn strategy: KEEP the single context created at load() and
            // clear its KV cache each turn with llama_memory_seq_rm. On the
            // non-unified (classic) KV backend (kv_unified=false, set in load())
            // this reliably empties sequence 0 and resets its length counter,
            // giving a clean slate every turn. The Dart layer re-sends the full
            // conversation each turn, so no cross-turn KV bookkeeping is needed.
            // NOTE: per-turn llama_init_from_model was abandoned — on this build the
            // re-inited context's KV was NOT pristine for longer (multi-turn)
            // prompts and produced flat/garbage logits ("coln魔魔魔").
            if (context == nullptr) {
                LOGE("completion(): context is null (model not loaded?)");
                is_running = false;
                return "[ERROR: Context not initialized]";
            }
            if (!llama_memory_seq_rm(llama_get_memory(context), 0, 0, (llama_pos)ctx_val)) {
                LOGW("completion(): seq_rm returned false; falling back to llama_memory_clear");
                llama_memory_clear(llama_get_memory(context), true);
            }
            kv_position = 0;
            LOGI("KV cache cleared (seq_rm) for new completion");

            const int ctx_val2 = static_cast<int>(n_ctx.load());
            LOGI("completion() running: model=%p context=%p n_ctx=%d",
                 (void*)model, (void*)context, ctx_val2);

            // --- Apply chatml template if history is provided ---
            std::string formatted_prompt;
            if (history && !history->empty()) {
                // NOTE: Dart's completionWithMessages already includes the current
                // user message as the LAST element of messagesJson/history, so we
                // must NOT append `prompt` again here. Doing so duplicated the
                // turn-2 prompt ("... user:你会什么, user:你会什么") and corrupted
                // the chatml template, driving the model into a degenerate loop.
                // Use the history vector as-is (its last entry is the live prompt).
                std::vector<llama_chat_message> chat_vec = *history;

                char buf[16384];
                int32_t n = llama_chat_apply_template(
                    "chatml",   // Qwen3 / Gemma-3 both use chatml format
                    chat_vec.data(),
                    (size_t)chat_vec.size(),
                    true,       // add_ass → appends "assistant\n" at the end
                    buf,
                    sizeof(buf));

                if (n > 0 && n < (int32_t)sizeof(buf)) {
                    // The built-in chatml template with add_ass=true already
                    // appends "<|im_start|>assistant\n", which is the correct
                    // generation trigger for Qwen2.5 / Qwen3. Do NOT inject an
                    // extra "<|im_end|>" here: doing so creates a malformed
                    // prompt (an empty assistant turn followed by a second
                    // assistant marker) that drives the model into a degenerate
                    // loop emitting a single special token (151935) forever.
                    formatted_prompt = std::string(buf, n);
                    // Qwen3 "thinking" models emit a long <think>...</think> chain
                    // before the real answer; at on-device speeds that makes the UI
                    // spin for a very long time. When the user has NOT enabled
                    // thinking (enable_thinking == false) and the model is
                    // thinking-capable (its embedded chat template references
                    // "think"), append an empty think block so the model answers
                    // directly and stops. If the user enabled thinking, leave the
                    // prompt as-is so the model reasons first.
                    // Do NOT rely on llama_model_chat_template() for detection —
                    // some GGUF exports omit the embedded template (returns nullptr)
                    // and the empty think block would never be appended. The empty
                    // think block is the documented Qwen3 no-think trigger and is
                    // harmless for non-thinking chatml models, so append it whenever
                    // the user has thinking disabled and the prompt ends with the
                    // assistant generation marker.
                    const char *mtmpl = llama_model_chat_template(model, nullptr);
                    bool supports_think = false;
                    if (mtmpl) { supports_think = std::string(mtmpl).find("think") != std::string::npos; }
                    const std::string asst_marker = "assistant\n";  // 10 chars (9 + '\n')
                    if (!enable_thinking.load() &&
                        formatted_prompt.size() >= asst_marker.size() &&
                        formatted_prompt.compare(formatted_prompt.size() - asst_marker.size(),
                                                 asst_marker.size(), asst_marker) == 0) {
                        formatted_prompt += "<think>\n\n</think>\n\n";
                        LOGI("thinking disabled (user toggle, model_think_tpl=%d) -> empty think block appended",
                             (int)supports_think);
                    } else if (enable_thinking.load()) {
                        LOGI("thinking enabled (user toggle) -> model will reason before answering");
                    }
                    LOGI("chatml template applied: %d chars, %zu history msgs", n, history->size());
                } else {
                    LOGW("llama_chat_apply_template returned %d, falling back to raw prompt", n);
                    formatted_prompt = prompt;
                }
            } else {
                formatted_prompt = prompt;
            }

            // 1. Tokenize formatted prompt
            bool add_bos = llama_vocab_get_add_bos(vocab);
            prompt_tokens = tokenize(formatted_prompt.c_str(), add_bos);
            n_prompt = (int)prompt_tokens.size();
            LOGI("Tokenized: %d tokens, add_bos=%d", n_prompt, add_bos);
            // DIAG: dump the actual prompt the model will see (truncated) so we
            // can confirm the user message really made it into the context.
            LOGI("formatted_prompt (%zu chars): %.*s%s",
                 formatted_prompt.size(),
                 (int)std::min((size_t)500, formatted_prompt.size()),
                 formatted_prompt.c_str(),
                 formatted_prompt.size() > 500 ? "..." : "");
            // DIAG: hex dump of the first 160 prompt bytes so the exact prompt
            // content is visible even when it contains non-ASCII (the console
            // mangles UTF-8, but hex is unambiguous).
            {
                std::string phex;
                char tmp[4];
                size_t lim = std::min((size_t)160, formatted_prompt.size());
                for (size_t i = 0; i < lim; ++i) { snprintf(tmp, sizeof(tmp), "%02X ", (unsigned char)formatted_prompt[i]); phex += tmp; }
                LOGI("prompt hex[0..%zu): %s", lim, phex.c_str());
            }

            if (ctx_val2 <= 0 || context == nullptr) {
                LOGE("completion() aborted: invalid state n_ctx=%d", ctx_val2);
                is_running = false;
                return "[ERROR: Invalid context]";
            }

            // Reserve room for generation: the prompt must leave at least
            // `max_tokens` cells free in the KV cache. Otherwise the decode loop
            // below will push decode_pos past n_ctx and llama.cpp aborts the
            // whole process (ggml_abort -> abort -> SIGABRT). This is the root
            // cause of the "send a few chat messages then crash" reports.
            const int gen_budget = std::max(1, ctx_val2 - max_tokens - 4);
            if (n_prompt > gen_budget) {
                LOGW("Prompt (%d tokens) + max_tokens (%d) would exceed context (%d); "
                     "dropping %d oldest tokens, keeping the most recent context.",
                     n_prompt, max_tokens, ctx_val2, n_prompt - gen_budget);
                // Drop the OLDEST tokens. The latest user turn and the assistant
                // continuation prefix live at the END of the formatted prompt,
                // so keeping the tail preserves the active conversation.
                prompt_tokens.erase(prompt_tokens.begin(),
                                    prompt_tokens.begin() + (n_prompt - gen_budget));
                n_prompt = gen_budget;
            }

            LOGI("Prompt: %d tokens", n_prompt);

            // (KV cache already cleared via llama_memory_seq_rm at the top of completion())
            LOGI("eos token id = %d, n_vocab = %d",
                 (int)llama_vocab_eos(vocab), (int)llama_vocab_n_tokens(vocab));

            // 2. Decode the prompt in batches of up to n_batch tokens.
            // This leverages the n_batch=512 / n_ubatch=256 configuration
            // set in load() so the prompt is processed efficiently instead
            // of one token at a time (which inflated TTFT by 10-50x).
            t_prompt_ms = 0;
            t_gen_ms = 0;
            n_gen = 0;
            llama_pos cur_pos = 0;

            auto t_start = std::chrono::high_resolution_clock::now();
            const int32_t n_batch = ctx_params.n_batch;
            int i = 0;
            while (i < n_prompt) {
                const int32_t chunk = std::min((int32_t)n_batch, n_prompt - i);
                llama_batch tok_batch = llama_batch_init(chunk, 0, 1);
                tok_batch.n_tokens = chunk;
                for (int32_t j = 0; j < chunk; ++j) {
                    tok_batch.token[j] = prompt_tokens[i + j];
                    tok_batch.pos[j]   = cur_pos + j;
                    tok_batch.n_seq_id[j]  = 1;
                    tok_batch.seq_id[j][0] = 0;
                    tok_batch.logits[j] = (i + j == n_prompt - 1) ? 1 : 0;
                }
                if (llama_decode(context, tok_batch) != 0) {
                    LOGE("llama_decode() failed on prompt batch starting at token %d (pos=%d)", i, (int)cur_pos);
                    llama_batch_free(tok_batch);
                    is_running = false;
                    return "[ERROR: Prompt decode failed]";
                }
                llama_batch_free(tok_batch);
                cur_pos += chunk;
                i += chunk;
            }
            kv_position = cur_pos;   // == n_prompt; generation continues at n_prompt..

            auto t_end = std::chrono::high_resolution_clock::now();
            t_prompt_ms = std::chrono::duration<double, std::milli>(t_end - t_start).count();

            // 3. Auto-generate tokens
            std::string result;
            std::string gen_utf8_buf;   // raw token bytes; forwarded only as complete UTF-8
            std::string flush_buf;      // batches complete UTF-8 sequences before calling on_token
            bool gen_stopped = false;
            const llama_token eos = llama_vocab_eos(vocab);
            // Batch size for on_token callbacks — accumulating characters
            // before crossing the JNI/EventChannel boundary reduces per-token
            // overhead from the C++→JNI→Dart round-trip.
            const size_t kFlushBatchSize = 64;

            // Create the sampler chain once and reuse it for every generated token.
            // This replaces the per-token O(vocab) allocation of 150k+
            // llama_token_data entries with the built-in llama.cpp sampler
            // which reuses internal buffers across calls.
            struct llama_sampler_chain_params sparams = llama_sampler_chain_default_params();
            struct llama_sampler * smpl_chain = llama_sampler_chain_init(sparams);
            llama_sampler_chain_add(smpl_chain, llama_sampler_init_top_k(128));
            llama_sampler_chain_add(smpl_chain, llama_sampler_init_top_p(top_p, 1));
            llama_sampler_chain_add(smpl_chain, llama_sampler_init_temp(temperature));

            while (n_gen < max_tokens && !should_stop) {
                llama_token new_token = 0;

                // Use the built-in llama.cpp sampler for efficient top-k /
                // top-p / temperature sampling. This avoids the per-token
                // O(vocab) allocation and partial_sort of the previous
                // manual implementation.
                new_token = llama_sampler_sample(smpl_chain, context, -1);

                if (n_gen == 0) {
                    LOGI("[DIAG] chosen new_token=%d (sampler chain, n_vocab=%d)",
                         new_token, (int)llama_vocab_n_tokens(vocab));
                }

                // DIAG: decode the first few generated tokens to their raw piece
                // bytes so we can see exactly what the model is emitting (e.g.
                // whether 151935 is a real character or an empty/padding token).
                if (n_gen < 6) {
                    char pbuf[64];
                    int pn = llama_token_to_piece(vocab, new_token, pbuf, sizeof(pbuf), 0, false);
                    std::string phex; char tmp[4];
                    for (int i = 0; i < pn && i < 32; ++i) { snprintf(tmp, sizeof(tmp), "%02X ", (unsigned char)pbuf[i]); phex += tmp; }
                    LOGI("[DIAG] gen#%d token=%d piece_len=%d piece_hex: %s", n_gen, new_token, pn, phex.c_str());
                }

                if (new_token == eos) {
                    LOGI("EOS at gen=%d", n_gen);
                    break;
                }

                char buf[256];
                // special=false: skip control/special tokens (render nothing) instead
                // of emitting their literal text, which would show up as garbage.
                int n = llama_token_to_piece(vocab, new_token, buf, sizeof(buf), 0, false);
                if (n > 0) {
                    gen_utf8_buf.append(buf, n);
                    // Forward only COMPLETE UTF-8 sequences so a multi-byte
                    // character is never split across two callback calls (which
                    // would hand JNI a lone continuation byte and abort). Invalid
                    // bytes (e.g. a lone continuation byte from byte-fallback) are
                    // dropped; SentencePiece's "▁" marker is rendered as a space.
                    // Batch complete sequences into flush_buf before calling
                    // on_token to reduce C++→JNI→Dart round-trip overhead per token.
                    size_t consumed = 0;
                    while (consumed < gen_utf8_buf.size()) {
                        int adv = utf8_seq_len(gen_utf8_buf, consumed);
                        if (adv == 0) break;          // incomplete tail; wait for more bytes
                        if (adv < 0) { consumed += 1; continue; }  // invalid byte -> drop
                        std::string one = gen_utf8_buf.substr(consumed, adv);
                        consumed += adv;
                        sp_space_to_ascii(one);
                        result += one;
                        flush_buf += one;
                        if (flush_buf.size() >= kFlushBatchSize) {
                        if (on_token && !on_token(flush_buf)) {
                            LOGI("Stopped by callback at gen=%d", n_gen);
                            gen_stopped = true;
                            flush_buf.clear();
                            break;
                        }
                        flush_buf.clear();
                        }
                    }
                    gen_utf8_buf.erase(0, consumed);
                    if (gen_stopped) break;
                }

                // Decode at correct position (append after the prompt we just fed).
                // NOTE: n_gen is still the INDEX of the token we just sampled (it is
                // incremented AFTER the decode below). So this token belongs at
                // kv_position + n_gen — e.g. the first generated token goes at
                // position n_prompt, not n_prompt+1. Incrementing n_gen before the
                // decode produced a 1-position gap in the KV cache, which made
                // llama_decode() fail on the very next token (ret=-1) and truncated
                // every reply to a single token.
                const int32_t decode_pos = kv_position + n_gen;
                // Belt-and-suspenders: never decode beyond the KV cache, or
                // llama.cpp aborts the process. (Prompt budgeting above already
                // guarantees this, but guard against any off-by-one / future
                // change in n_ctx.)
                if (decode_pos >= (int32_t)llama_n_ctx(context)) {
                    LOGW("decode_pos %d >= n_ctx %d, stopping generation to avoid overflow.",
                         decode_pos, (int)llama_n_ctx(context));
                    break;
                }
                LOGI("gen token #%d: new_token=%d pos=%d n_ctx=%d", n_gen, new_token, decode_pos, (int)n_ctx.load());
                t_start = std::chrono::high_resolution_clock::now();
                llama_batch token_batch = llama_batch_init(1, 0, 1);
                // CRITICAL: llama_batch_init only allocates buffers; the actual
                // token count for THIS batch must be set explicitly, otherwise
                // llama_decode() sees n_tokens=0 and returns -1 (decode fails on
                // the very first generated token, so generation stops at 1 token).
                token_batch.n_tokens    = 1;
                token_batch.token[0]   = new_token;
                token_batch.pos[0]     = decode_pos;
                token_batch.n_seq_id[0]= 1;
                token_batch.seq_id[0][0]= 0;
                token_batch.logits[0]  = true;
                int32_t dec_ret = llama_decode(context, token_batch);
                if (dec_ret != 0) {
                    LOGE("llama_decode() failed on gen token #%d: ret=%d pos=%d n_ctx=%u",
                         n_gen, dec_ret, decode_pos, llama_n_ctx_seq(context));
                    llama_batch_free(token_batch);
                    break;
                }
                llama_batch_free(token_batch);
                n_gen++;   // advance AFTER decoding so decode_pos stays contiguous
                t_end = std::chrono::high_resolution_clock::now();
                t_gen_ms += std::chrono::duration<double, std::milli>(t_end - t_start).count();
            }
            llama_sampler_free(smpl_chain);

            // Extend the persistent KV cursor to include this turn's generated tokens
            // so the NEXT completion continues the conversation seamlessly.
            kv_position += n_gen;

            // Flush whatever remains. Incomplete trailing bytes at EOS are dropped
            // (better a missing char than a "�" box); valid sequences are still
            // forwarded so mid-stream text is never lost.
            // Also flush any accumulated on_token batch buffer.
            if (!flush_buf.empty()) {
                if (on_token) on_token(flush_buf);
                flush_buf.clear();
            }
            if (!gen_stopped && !gen_utf8_buf.empty()) {
                size_t consumed = 0;
                while (consumed < gen_utf8_buf.size()) {
                    int adv = utf8_seq_len(gen_utf8_buf, consumed);
                    if (adv <= 0) break;   // incomplete or invalid -> stop, drop rest
                    std::string one = gen_utf8_buf.substr(consumed, adv);
                    consumed += adv;
                    sp_space_to_ascii(one);
                    result += one;
                    if (on_token) on_token(one);
                }
                gen_utf8_buf.clear();
            }

            is_running = false;

            double tok_per_sec = n_gen > 0 ? (n_gen / (t_gen_ms / 1000.0)) : 0.0;
            {
                std::string hex;
                char tmp[4];
                for (unsigned char c : result) { snprintf(tmp, sizeof(tmp), "%02X ", c); hex += tmp; }
                LOGI("result hex (%zu bytes): %s", result.size(), hex.c_str());
            }
            LOGI("Generation done: %d tokens, %.1f tok/s (prompt %.0fms, gen %.0fms)",
                 n_gen, tok_per_sec, t_prompt_ms, t_gen_ms);

            // NOTE: conversation history is supplied fresh by the Dart side on every
            // turn (via the messages JSON), so we do not accumulate it natively here.
            // The previous code stored { role, result.c_str() } into the member
            // chat_history, but those pointers dangled the moment completion()
            // returned (result is a local) — and the member was never read for
            // templating anyway. Removed to avoid the use-after-free.

            return result;
        } catch (const std::exception &e) {
            LOGE("completion() caught C++ exception: %s", e.what());
            is_running = false;
            throw; // Re-throw so JNI layer can propagate to Java as a real exception.
        } catch (...) {
            LOGE("completion() caught unknown C++ exception");
            is_running = false;
            throw std::runtime_error("Unknown C++ exception in completion()");
        }
    }

    void stop() {
        should_stop = true;
    }

    // ------------------------------------------------------------------
    // Memory & device info
    // ------------------------------------------------------------------
    int64_t get_model_size_bytes() const {
        if (!model) return 0;
        return llama_model_n_params(model) * sizeof(float); // approximate
    }

    int64_t get_context_size_bytes() const {
        if (!context) return 0;
        return (int64_t)llama_state_get_size(context);
    }
};

// ============================================================================
// Global engine instance
// ============================================================================
static InferenceEngine g_engine;
static JavaVM *g_jvm = nullptr;
static jobject g_callback_obj = nullptr;

// ============================================================================
// JNI Helpers
// ============================================================================

static JNIEnv *get_env() {
    JNIEnv *env = nullptr;
    g_jvm->GetEnv(reinterpret_cast<void **>(&env), JNI_VERSION_1_6);
    return env;
}

static std::string jstring_to_std(JNIEnv *env, jstring jstr) {
    if (!jstr) return "";
    const char *cstr = env->GetStringUTFChars(jstr, nullptr);
    std::string result(cstr);
    env->ReleaseStringUTFChars(jstr, cstr);
    return result;
}

// ============================================================================
// JNI Methods
// ============================================================================

extern "C" {

JNIEXPORT jint JNI_OnLoad(JavaVM *vm, void *) {
    g_jvm = vm;
    LOGI("JNI_OnLoad");
    return JNI_VERSION_1_6;
}

// --- Lifecycle ---

JNIEXPORT jboolean JNICALL
Java_com_dgxspark_tongyilite_InferenceEngine_nativeInit(JNIEnv *env, jobject) {
    LOGI("nativeInit: initializing llama backend");
    llama_backend_init();
    return JNI_TRUE;
}

// Global ref for the loading callback object (set via nativeSetLoadingCallback, used during load)
static jobject g_loading_callback_obj = nullptr;

// Inline helper — calls onLoadingLog() on the Kotlin callback if it is set.
static void reportLoadingLog(const char *message) {
    if (!g_loading_callback_obj) return;
    JNIEnv *env = get_env();
    if (!env) return;
    jclass cls = env->GetObjectClass(g_loading_callback_obj);
    jmethodID mid = env->GetMethodID(cls, "onLoadingLog", "(Ljava/lang/String;)V");
    jstring jmsg = env->NewStringUTF(message);
    env->CallVoidMethod(g_loading_callback_obj, mid, jmsg);
    env->DeleteLocalRef(jmsg);
    env->DeleteLocalRef(cls);
}

JNIEXPORT jboolean JNICALL
Java_com_dgxspark_tongyilite_InferenceEngine_nativeLoadModel(
    JNIEnv *env, jobject, jstring jpath, jint n_ctx, jboolean j_enable_gpu, jint j_gpu_layers
) {
    std::string path = jstring_to_std(env, jpath);
    bool ok = g_engine.load(path.c_str(), n_ctx,
                            j_enable_gpu == JNI_TRUE, (int)j_gpu_layers);

    // Cleanup callback ref after load completes (success or failure)
    if (g_loading_callback_obj) {
        env->DeleteGlobalRef(g_loading_callback_obj);
        g_loading_callback_obj = nullptr;
    }

    return ok ? JNI_TRUE : JNI_FALSE;
}

// Called from Kotlin to register the loading callback before invoking nativeLoadModel.
JNIEXPORT void JNICALL
Java_com_dgxspark_tongyilite_InferenceEngine_nativeSetLoadingCallback(
    JNIEnv *env, jobject, jobject jcallback
) {
    if (g_loading_callback_obj) {
        env->DeleteGlobalRef(g_loading_callback_obj);
        g_loading_callback_obj = nullptr;
    }
    if (jcallback != nullptr) {
        g_loading_callback_obj = env->NewGlobalRef(jcallback);
    }
}

JNIEXPORT void JNICALL
Java_com_dgxspark_tongyilite_InferenceEngine_nativeUnloadModel(JNIEnv *, jobject) {
    g_engine.unload();
}

JNIEXPORT jboolean JNICALL
Java_com_dgxspark_tongyilite_InferenceEngine_nativeIsLoaded(JNIEnv *, jobject) {
    return g_engine.is_loaded() ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT void JNICALL
Java_com_dgxspark_tongyilite_InferenceEngine_nativeStop(JNIEnv *, jobject) {
    g_engine.stop();
}

// User-facing toggle for Qwen3-style thinking. Called from Dart whenever the
// setting changes (and once after model load) so completion() knows whether to
// suppress the <think> chain.
JNIEXPORT void JNICALL
Java_com_dgxspark_tongyilite_InferenceEngine_nativeSetEnableThinking(
    JNIEnv *, jobject, jboolean jenable
) {
    g_engine.enable_thinking.store(jenable == JNI_TRUE);
    LOGI("nativeSetEnableThinking: enable_thinking=%d", (int)g_engine.enable_thinking.load());
}

// Start a brand-new conversation: clear the persistent KV cache so a previous
// chat does not bleed into the new one (multi-turn append-only caching).
JNIEXPORT void JNICALL
Java_com_dgxspark_tongyilite_InferenceEngine_nativeResetContext(
    JNIEnv *, jobject
) {
    g_engine.resetContext();
}

JNIEXPORT void JNICALL
Java_com_dgxspark_tongyilite_InferenceEngine_nativeDestroy(JNIEnv *, jobject) {
    g_engine.unload();
    llama_backend_free();
    LOGI("nativeDestroy");
}

// --- Inference ---

JNIEXPORT jstring JNICALL
Java_com_dgxspark_tongyilite_InferenceEngine_nativeCompletion(
    JNIEnv *env, jobject,
    jstring jprompt,
    jint max_tokens,
    jfloat temperature,
    jfloat top_p,
    jobject jcallback  // InferenceCallback interface
) {
    const int eng_n_ctx = static_cast<int>(g_engine.n_ctx.load());
    LOGI("nativeCompletion ENTER: is_loaded=%d model=%p context=%p n_ctx=%d",
         g_engine.is_loaded(), (void*)g_engine.model, (void*)g_engine.context, eng_n_ctx);
    if (!g_engine.is_loaded()) {
        LOGE("nativeCompletion ABORT: no model loaded at JNI entry");
        return env->NewStringUTF("[ERROR: No model loaded]");
    }

    // Save callback object for token streaming. Keep a local ref copy so it stays alive
    // during the entire completion call (avoids GC between the global ref and its use).
    jobject cb_copy = env->NewLocalRef(jcallback);

    std::string prompt = jstring_to_std(env, jprompt);

    std::string result;
    try {
        result = g_engine.completion(
            prompt.c_str(),
            max_tokens,
            temperature,
            top_p,
            [cb_copy](const std::string &token) -> bool {
                if (!g_jvm || !cb_copy) return true;

                // Ensure we have a valid JNIEnv for this thread.
                JNIEnv *local_env = nullptr;
                int status = g_jvm->GetEnv(reinterpret_cast<void **>(&local_env), JNI_VERSION_1_6);
                bool need_detach = false;

                if (status == JNI_EDETACHED) {
                    if (g_jvm->AttachCurrentThread(&local_env, nullptr) != 0) return true;
                    need_detach = true;
                } else if (status != JNI_OK) {
                    return true;
                }

                // Use NewLocalRef on the copy to avoid GC during callback execution.
                jobject safe_cb = local_env->NewLocalRef(cb_copy);
                jclass cls = local_env->GetObjectClass(safe_cb);
                if (!cls) {
                    local_env->DeleteLocalRef(safe_cb);
                    if (need_detach) g_jvm->DetachCurrentThread();
                    return true;
                }

                jmethodID mid = local_env->GetMethodID(cls, "onToken", "(Ljava/lang/String;)Z");
                if (!mid) {
                    local_env->DeleteLocalRef(safe_cb);
                    local_env->DeleteLocalRef(cls);
                    if (need_detach) g_jvm->DetachCurrentThread();
                    return true;
                }

                jstring jtoken = utf8_to_jstring(local_env, token);
                jboolean should_continue = local_env->CallBooleanMethod(safe_cb, mid, jtoken);
                local_env->DeleteLocalRef(jtoken);
                local_env->DeleteLocalRef(safe_cb);
                local_env->DeleteLocalRef(cls);

                if (need_detach) g_jvm->DetachCurrentThread();
                return (should_continue != JNI_FALSE);
            }
        );
    } catch (const std::exception &e) {
        LOGE("nativeCompletion caught C++ exception: %s", e.what());
        result = std::string("[ERROR: ") + e.what() + "]";
    } catch (...) {
        LOGE("nativeCompletion caught unknown C++ exception");
        result = "[ERROR: Unknown C++ exception in completion()]";
    }

    // Release callback refs (always, even on error)
    env->DeleteLocalRef(cb_copy);
    if (g_callback_obj) {
        env->DeleteGlobalRef(g_callback_obj);
        g_callback_obj = nullptr;
    }

    return utf8_to_jstring(env, result);
}

// ============================================================================
// JSON helper — minimal parser for message array from Kotlin side
// Format: [{"role":"user","content":"..."},{"role":"assistant","content":"..."}]
// ============================================================================
// Parse the JSON messages array into llama_chat_message entries. The role/content
// strings are moved into `store` (a caller-owned deque) so the const char* pointers
// handed to llama_chat_message remain valid for the entire completion call.
// Previously the pointers referenced local std::strings that were destroyed on
// return -> dangling pointers -> the chat template read freed memory as garbage.
static std::vector<llama_chat_message> parseMessagesJson(JNIEnv *env, jstring jjson,
                                                         std::deque<std::string> &store) {
    std::vector<llama_chat_message> msgs;
    if (!jjson) return msgs;
    std::string json = jstring_to_std(env, jjson);

    // Simple state-machine parser: find "role" and "content" pairs
    size_t i = 0;
    while (i < json.size()) {
        // Find next opening brace
        size_t obj_start = json.find('{', i);
        if (obj_start == std::string::npos) break;
        size_t obj_end = json.find('}', obj_start);
        if (obj_end == std::string::npos) break;

        std::string obj = json.substr(obj_start, obj_end - obj_start + 1);
        // Extract role
        auto rpos = obj.find("\"role\"");
        if (rpos != std::string::npos) {
            size_t colon = obj.find(':', rpos);
            size_t q1 = obj.find('"', colon + 1);
            size_t q2 = obj.find('"', q1 + 1);
            if (q1 != std::string::npos && q2 != std::string::npos) {
                std::string role = obj.substr(q1 + 1, q2 - q1 - 1);
                // Extract content
                auto cpos = obj.find("\"content\"");
                if (cpos != std::string::npos) {
                    size_t ccolon = obj.find(':', cpos);
                    size_t cq1 = obj.find('"', ccolon + 1);
                    size_t cq2 = obj.find('"', cq1 + 1);
                    // Handle escaped quotes in content — find last quote before }
                    if (cq1 != std::string::npos) {
                        for (size_t k = cq1 + 1; k < obj.size(); ++k) {
                            if (obj[k] == '"') {
                                if (k > 0 && obj[k-1] != '\\') { cq2 = k; break; }
                            }
                        }
                    }
                    std::string content;
                    if (cq1 != std::string::npos && cq2 != std::string::npos && cq2 > cq1 + 1) {
                        content = obj.substr(cq1 + 1, cq2 - cq1 - 1);
                    }
                    // Move into the caller-owned backing store so the pointers
                    // stay alive; deque never invalidates element references on
                    // push_back, so these c_str() pointers are stable.
                    store.push_back(std::move(role));
                    store.push_back(std::move(content));
                    const std::string &r = store[store.size() - 2];
                    const std::string &c = store[store.size() - 1];
                    msgs.push_back({ r.c_str(), c.c_str() });
                }
            }
        }
        i = obj_end + 1;
    }
    return msgs;
}

// --- Completion with chat history (JSON messages array) ---

JNIEXPORT jstring JNICALL
Java_com_dgxspark_tongyilite_InferenceEngine_nativeCompletionWithMessages(
    JNIEnv *env, jobject,
    jstring jprompt,
    jstring jmessages_json,   // JSON array of {role, content} pairs
    jint max_tokens,
    jfloat temperature,
    jfloat top_p,
    jobject jcallback
) {
    const int eng_n_ctx = static_cast<int>(g_engine.n_ctx.load());
    LOGI("nativeCompletionWithMessages ENTER: is_loaded=%d n_ctx=%d",
         g_engine.is_loaded(), eng_n_ctx);
    if (!g_engine.is_loaded()) {
        LOGE("nativeCompletionWithMessages ABORT: no model loaded");
        return env->NewStringUTF("[ERROR: No model loaded]");
    }

    jobject cb_copy = env->NewLocalRef(jcallback);
    std::string prompt   = jstring_to_std(env, jprompt);
    // Backing store for history role/content strings; must outlive the completion
    // call so the llama_chat_message pointers stay valid.
    std::deque<std::string> history_store;
    auto history = parseMessagesJson(env, jmessages_json, history_store);
    LOGI("nativeCompletionWithMessages: prompt='%s', %zu history messages", prompt.c_str(), history.size());

    std::string result;
    try {
        result = g_engine.completion(
            prompt.c_str(), max_tokens, temperature, top_p,
            [cb_copy](const std::string &token) -> bool {
                if (!g_jvm || !cb_copy) return true;
                JNIEnv *local_env = nullptr;
                int status = g_jvm->GetEnv(reinterpret_cast<void **>(&local_env), JNI_VERSION_1_6);
                bool need_detach = false;
                if (status == JNI_EDETACHED) {
                    if (g_jvm->AttachCurrentThread(&local_env, nullptr) != 0) return true;
                    need_detach = true;
                } else if (status != JNI_OK) {
                    return true;
                }
                jobject safe_cb = local_env->NewLocalRef(cb_copy);
                jclass cls = local_env->GetObjectClass(safe_cb);
                if (!cls) {
                    local_env->DeleteLocalRef(safe_cb);
                    if (need_detach) g_jvm->DetachCurrentThread();
                    return true;
                }
                jmethodID mid = local_env->GetMethodID(cls, "onToken", "(Ljava/lang/String;)Z");
                if (!mid) {
                    local_env->DeleteLocalRef(safe_cb);
                    local_env->DeleteLocalRef(cls);
                    if (need_detach) g_jvm->DetachCurrentThread();
                    return true;
                }
                jstring jtoken = utf8_to_jstring(local_env, token);
                jboolean should_continue = local_env->CallBooleanMethod(safe_cb, mid, jtoken);
                local_env->DeleteLocalRef(jtoken);
                local_env->DeleteLocalRef(safe_cb);
                local_env->DeleteLocalRef(cls);
                if (need_detach) g_jvm->DetachCurrentThread();
                return (should_continue != JNI_FALSE);
            },
            &history   // pass history to completion() for chatml template application
        );
    } catch (const std::exception &e) {
        LOGE("nativeCompletionWithMessages caught C++ exception: %s", e.what());
        result = std::string("[ERROR: ") + e.what() + "]";
    } catch (...) {
        LOGE("nativeCompletionWithMessages caught unknown C++ exception");
        result = "[ERROR: Unknown C++ exception in completion()]";
    }

    env->DeleteLocalRef(cb_copy);
    if (g_callback_obj) {
        env->DeleteGlobalRef(g_callback_obj);
        g_callback_obj = nullptr;
    }

    LOGI("nativeCompletionWithMessages done, result len=%zu", result.length());
    return utf8_to_jstring(env, result);
}

// --- Benchmark ---

JNIEXPORT jdoubleArray JNICALL
Java_com_dgxspark_tongyilite_InferenceEngine_nativeBenchmark(
    JNIEnv *env, jobject,
    jstring jprompt,
    jint n_repeats
) {
    if (!g_engine.is_loaded()) {
        jdoubleArray arr = env->NewDoubleArray(3);
        jdouble vals[] = {0, 0, 0};
        env->SetDoubleArrayRegion(arr, 0, 3, vals);
        return arr;
    }

    std::string prompt = jstring_to_std(env, jprompt);

    // Warm-up run
    g_engine.completion(prompt.c_str(), 32, 0.7f, 0.9f, nullptr);

    double total_prompt_ms = 0;
    double total_gen_ms = 0;
    int total_gen = 0;

    for (int i = 0; i < n_repeats; i++) {
        g_engine.completion(prompt.c_str(), 128, 0.7f, 0.9f, nullptr);
        total_prompt_ms += g_engine.t_prompt_ms;
        total_gen_ms  += g_engine.t_gen_ms;
        total_gen     += g_engine.n_gen;
    }

    double avg_prompt_ms = total_prompt_ms / n_repeats;
    double avg_gen_ms   = total_gen_ms / n_repeats;
    double tok_per_sec  = total_gen > 0 ? (total_gen / (total_gen_ms / 1000.0)) : 0.0;

    LOGI("Benchmark (%d runs): prompt=%.0fms gen=%.0fms %.1f tok/s",
         n_repeats, avg_prompt_ms, avg_gen_ms, tok_per_sec);

    jdoubleArray arr = env->NewDoubleArray(3);
    jdouble vals[] = {tok_per_sec, avg_prompt_ms, avg_gen_ms};
    env->SetDoubleArrayRegion(arr, 0, 3, vals);
    return arr;
}

// --- Memory info ---

JNIEXPORT jlong JNICALL
Java_com_dgxspark_tongyilite_InferenceEngine_nativeGetModelSizeBytes(JNIEnv *, jobject) {
    return g_engine.get_model_size_bytes();
}

JNIEXPORT jstring JNICALL
Java_com_dgxspark_tongyilite_InferenceEngine_nativeGetModelInfo(JNIEnv *env, jobject) {
    if (!g_engine.is_loaded()) {
        return env->NewStringUTF("{}");
    }
    char buf[512];
    const int eng_ctx = static_cast<int>(g_engine.n_ctx.load());
    snprintf(buf, sizeof(buf),
             "{\"n_params\":%lld,\"n_ctx\":%d,\"n_embd\":%d,\"n_layer\":%d,\"n_vocab\":%d}",
             (long long)llama_model_n_params(g_engine.model),
             eng_ctx,
             llama_model_n_embd(g_engine.model),
             llama_model_n_layer(g_engine.model),
             llama_vocab_n_tokens(g_engine.vocab));
    return env->NewStringUTF(buf);
}

} // extern "C"
