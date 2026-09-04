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
#include <fstream>
#include <cstdlib>
#include <sys/stat.h>

// llama.cpp headers
#include "llama.h"
#include "common.h"
#include "speculative.h"   // official MTP/NextN speculative decoding driver
#include "sampling.h"      // common_sampler / common_sampler_sample_and_accept_n
#include "ggml-backend.h"

// mtmd — llama.cpp mainline vision/multimodal library (mmproj + image encoding)
#include "mtmd.h"
#include "mtmd-helper.h"

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
// Generation stats — captured at completion time, surfaced to Dart so the UI
// shows the SAME tokens/sec the native log reports (real llama.cpp token count
// / pure generation time), not emitted-character count over wall-clock time
// that also includes prompt prefill. Written by completion(), read by
// Java_..._nativeGetLastStats().
// ============================================================================
struct GenStats {
    int    n_gen       = 0;   // real llama.cpp decoded tokens (tok/s numerator)
    double t_gen_ms    = 0;   // pure generation wall time (tok/s denom, excludes prefill)
    double t_prompt_ms = 0;   // prompt prefill time (diagnostics only)
    double t_vision_ms = 0;   // image-encode (vision) wall time, ms — "识图时间"
    double t_audio_ms  = 0;   // audio-encode (speech) wall time, ms — "听音时间"
};
static GenStats g_last_stats;

// ============================================================================
// CPU topology — count big cores for the thread pool
// ============================================================================
// Reads /proc/cpuinfo and counts how many cores are "big" (performance) vs
// "little" (efficiency). Rationale: for inference thread count we want ALL
// cores when the SoC has no little cluster (e.g. Snapdragon 8s Gen 4 =
// 1×X4 + 7×A720, all big), but only the big cores when the SoC is big.LITTLE
// (little cores are slower and cause contention / thermal issues). The old
// heuristic `nt = hc/2` wasted half the machine on all-big SoCs (measured:
// 8 cores → 4 threads → 27B Q1_0 CPU 0.8 tok/s, 4B Q4_K_M CPU 6.8 tok/s).
// ARM Cortex part IDs (from /proc/cpuinfo "CPU part"):
//   little: A53=0xd03, A55=0xd05, A510=0xd46, A520=0xd80
//   big:    A72=0xd08, A73=0xd09, A75=0xd40, A76=0xd41, A77=0xd42, A78=0xd44,
//           A710=0xd47, A715=0xd48, A720=0xd81, A725=0xd4b, X1=0xd45, X2=0xd46,
//           X3=0xd4a, X4=0xd82, X925=0xd84, X930=0xd85
// Returns number of big cores, or -1 if /proc/cpuinfo cannot be parsed.
static int detect_big_core_count() {
    std::ifstream f("/proc/cpuinfo");
    if (!f.is_open()) {
        LOGW("detect_big_core_count: cannot open /proc/cpuinfo");
        return -1;
    }
    int big = 0, little = 0;
    std::string line;
    while (std::getline(f, line)) {
        // "CPU part\t: 0xd81"
        size_t p = line.find("CPU part");
        if (p == std::string::npos) continue;
        size_t colon = line.find(':');
        if (colon == std::string::npos) continue;
        unsigned long part = strtoul(line.c_str() + colon + 1, nullptr, 16);
        switch (part) {
            case 0xd03: // A53
            case 0xd05: // A55
            case 0xd46: // A510
            case 0xd80: // A520
                little++;
                break;
            default:
                // Unknown part — treat as big (all cores on modern SoCs are
                // performance-class; unknown ARMv9 parts are A7xx/X-class).
                big++;
                break;
        }
    }
    if (big + little == 0) return -1;
    LOGI("CPU topology: big=%d little=%d", big, little);
    return big;
}

// ============================================================================
// LoadingCallback — C-side callback interface for loading progress logs
// ============================================================================

// ============================================================================
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

// Length of the common prefix of two token vectors. Used by cross-turn KV
// incremental prefill to decide how many KV positions can be kept.
static int longest_common_prefix(const std::vector<llama_token> &a,
                                 const std::vector<llama_token> &b) {
    const size_t n = std::min(a.size(), b.size());
    size_t i = 0;
    while (i < n && a[i] == b[i]) ++i;
    return (int)i;
}

struct InferenceEngine {
    llama_model *model   = nullptr;
    const struct llama_vocab *vocab = nullptr; // extracted from model for new API
    llama_context *context = nullptr;
    llama_context *mtp_ctx = nullptr;  // second context running only the NextN/MTP head
    llama_model *draft_model = nullptr; // dspark draft model (independent GGUF head)
    llama_context *dspark_ctx = nullptr; // draft context for DFlash/DSpark speculative
    bool dspark_enabled = false;        // dspark head loaded and usable
    llama_model_params model_params;
    llama_context_params ctx_params;

    // Vision: mtmd context for the loaded mmproj (multimodal projector).
    // null when no mmproj was loaded -> the model is text-only even if its
    // catalog type is vision. vision_loaded mirrors mmproj != nullptr.
    mtmd_context *mmproj = nullptr;
    bool vision_loaded = false;
    // Audio: whether the loaded mmproj also ships an audio encoder (Gemma 4 E2B
    // native speech). Mirrors mtmd_support_audio(mmproj) at load time so the
    // Dart UI can gate the mic button and the completion path can reject audio
    // when the current model cannot understand it.
    bool audio_loaded = false;
    int  audio_sample_rate = -1;

    // MTP (multi-token prediction) speculative decoding. Enabled at load time iff
    // the model contains NextN layers (llama_model_n_layer_nextn > 0). The MTP head
    // drafts several tokens cheaply; the target model then verifies them all in a
    // single forward pass, so one decode step yields several accepted tokens.
    bool mtp_enabled = false;
    int  n_draft_max = 2;   // how many tokens the MTP head drafts per step (upper bound).
                            // Default 2 (was 3): on compute-bound 4B the verify batch
                            // (1+n_draft) must be repaid by acceptance a>=n_draft, so a
                            // smaller budget lowers the break-even point and curbs the
                            // negative-benefit window; the adaptive logic still drops to
                            // 1 when the head is doing badly.

    // Adaptive draft budget. Speculative gain hinges on ACCEPTANCE: each iteration
    // verifies a (1+n_draft)-token batch on the target, which on a compute-bound
    // model costs ~(1+n_draft) single-token decodes. If the head keeps producing
    // rejected drafts, that verify cost is pure waste. We track a running acceptance
    // rate and shrink n_draft (so the verify batch shrinks) when the head is doing
    // badly — the llama.cpp server does the same "draft only what pays off" idea
    // (slot.get_n_draft_max + per-slot acceptance stats).
    float  mtp_accept_sum   = 0;  // accepted draft tokens (running window)
    float  mtp_draft_sum    = 0;  // drafted tokens (running window)
    int    mtp_adaptive_max = n_draft_max;

    // Cross-turn KV incremental prefill. Instead of wiping the whole KV and
    // re-prefilling the entire conversation every turn, we keep the common prefix
    // of the previous turn's prompt and only prefill the newly-added suffix.
    // prev_prompt_tokens is cached AFTER truncation so it matches the KV exactly.
    std::vector<llama_token> prev_prompt_tokens; // last turn's full prompt tokens (+gen)
    bool                     have_prev_kv = false; // KV currently == prev_prompt_tokens

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
    double t_vision_ms = 0;   // vision image-encode wall time (识图时间)
    double t_audio_ms  = 0;   // audio-encode wall time (听音时间)

    // Persistent KV-cache write cursor. We use the proven com.arm.aichat design:
    // each turn APPENDS its tokens at monotonically increasing positions into the
    // SAME context, instead of clearing the cache and re-decoding from 0 every turn.
    // Clearing + re-decode collides with the hybrid recurrent cache's length tracking
    // on Adreno and corrupts multi-turn output (degenerate loop on round 2+).
    // kv_position is reset to 0 only for a brand-new conversation (resetContext()).
    llama_pos kv_position = 0;

    // Actual on-disk size of the loaded .gguf (bytes). The model is mmap'd, so
    // its resident memory footprint is bounded by this size — a far more honest
    // number than n_params*sizeof(float), which over-estimates quantized models
    // by ~8-16x (e.g. a 2.4 GB Q4_K_M reported as 16 GB). 0 when no model loaded.
    int64_t model_file_size_bytes_ = 0;

    bool load(const char *model_path, int requested_n_ctx = 4096,
              bool enable_gpu = true, int gpu_layers = 20,
              const char *gpu_backend = "auto", bool enable_mtp = false,
              const char *mmproj_path = nullptr,
              const char *draft_path = nullptr) {
        // Unload previous model FIRST — without holding the mutex during callbacks.
        unload();

        LOGI("Loading model from: %s", model_path);
        reportLoadingLog("正在加载 GGUF 模型文件...");

        // Model params
        model_params = llama_model_default_params();
        // GPU offloading policy (driven by the UI toggle + layer setting):
        //   - enable_gpu == false                   -> pure CPU (n_gpu_layers = 0)
        //   - gpu_backend == "cpu"                  -> pure CPU
        //   - gpu_backend == "vulkan"|"opencl"      -> force that backend (if device present)
        //   - gpu_backend == "auto" (default)       -> pick first working GPU backend
        // The backend is selected here by scanning the ggml backend registry for
        // devices of the requested type; llama.cpp then offloads layers only to
        // that backend because we only keep it in the devices list.
        // NOTE(2026-08-04, revised): Vulkan was earlier suspected numerically
        // corrupt on Adreno 825 (padding-token collapse), but on-device retests
        // with V0.1.3 show Vulkan decodes correctly and at throughput within ~2%
        // of OpenCL for both 4B (Q4_K_M) and 27B (Q1_0). The earlier collapse
        // was caused by unrelated pipeline bugs (n_ubatch=512 + missing
        // llama_sampler_accept), now fixed. OpenCL is still preferred in auto
        // mode because Adreno's OpenCL driver is highly optimized; Vulkan is a
        // fully usable alternative the user can select for comparison.
        std::string backend = gpu_backend ? gpu_backend : "auto";
        int effective_gpu_layers = 0;
        bool vulkan_ok = false, opencl_ok = false;
        if (enable_gpu) {
            // Probe the registry for backend devices of each type.
            const size_t n_dev = ggml_backend_dev_count();
            for (size_t i = 0; i < n_dev; i++) {
                ggml_backend_dev_t dev = ggml_backend_dev_get(i);
                if (!dev) continue;
                const char *dev_name = ggml_backend_dev_name(dev);
                const enum ggml_backend_dev_type type = ggml_backend_dev_type(dev);
                if (type != GGML_BACKEND_DEVICE_TYPE_GPU &&
                    type != GGML_BACKEND_DEVICE_TYPE_IGPU) {
                    continue;
                }
                LOGI("  gpu dev[%zu] name=%s type=%d", i, dev_name ? dev_name : "?", (int)type);
                std::string dn = dev_name ? dev_name : "";
                if (dn.find("Vulkan") != std::string::npos ||
                    dn.find("vulkan") != std::string::npos) {
                    vulkan_ok = true;
                }
                if (dn.find("OpenCL") != std::string::npos ||
                    dn.find("opencl") != std::string::npos ||
                    dn.find("CL") != std::string::npos) {
                    opencl_ok = true;
                }
            }

            if (backend == "cpu") {
                LOGI("GPU backend forced to CPU");
                reportLoadingLog("已选择 CPU 推理");
            } else if (backend == "vulkan") {
                if (vulkan_ok) {
                    // Vulkan verified working on Adreno 825 (V0.1.3): correct
                    // output, throughput within ~2% of OpenCL.
                    LOGI("Vulkan selected — verified OK on Adreno 825 (Q4_K_M & Q1_0).");
                    reportLoadingLog("已选择 Vulkan 后端");
                    effective_gpu_layers = gpu_layers;
                } else {
                    LOGW("Vulkan backend requested but not available -> CPU");
                    reportLoadingLog("Vulkan 不可用，回落 CPU");
                }
            } else if (backend == "opencl") {
                if (opencl_ok) {
                    LOGI("OpenCL selected");
                    reportLoadingLog("已选择 OpenCL 后端");
                    effective_gpu_layers = gpu_layers;
                } else {
                    LOGW("OpenCL backend requested but not available -> CPU");
                    reportLoadingLog("OpenCL 不可用，回落 CPU");
                }
            } else { // auto: prefer OpenCL (well-optimized on Adreno; Vulkan equivalent)
                if (opencl_ok) {
                    LOGI("auto -> OpenCL");
                    reportLoadingLog("自动选择 OpenCL 后端");
                    effective_gpu_layers = gpu_layers;
                } else if (vulkan_ok) {
                    LOGI("auto -> Vulkan (equivalent to OpenCL on Adreno 825)");
                    reportLoadingLog("自动选择 Vulkan 后端");
                    effective_gpu_layers = gpu_layers;
                } else {
                    LOGI("auto -> no GPU backend found, CPU fallback");
                    reportLoadingLog("未检测到可用 GPU 后端，回落 CPU");
                }
            }
        } else {
            LOGI("GPU acceleration disabled by user -> pure CPU");
            reportLoadingLog("已关闭 GPU 加速，使用 CPU 推理");
        }
        model_params.n_gpu_layers = effective_gpu_layers;
        LOGI("n_gpu_layers = %d", model_params.n_gpu_layers);

        // Pure-CPU path: make sure NO GPU device reaches the llama scheduler.
        // llama_prepare_model_devices() fills model->devices from the ggml
        // registry whenever split_mode is LAYER (the default), so on SoCs whose
        // only GPU backend is Vulkan (e.g. MediaTek Mali: OpenCL unavailable)
        // the scheduler still registers that Vulkan backend even with
        // n_gpu_layers=0. sched_reserve() then calls a null backend callback
        // -> SIGSEGV (observed: fault addr 0x0 in libggml-vulkan.so on Dimensity).
        // split_mode=NONE + main_gpu=-1 makes llama_prepare_model_devices()
        // call devices.clear(), so the scheduler is CPU-only.
        if (effective_gpu_layers == 0) {
            model_params.split_mode = LLAMA_SPLIT_MODE_NONE;
            model_params.main_gpu = -1;
            LOGI("pure-CPU mode: devices cleared (split_mode=NONE, main_gpu=-1)");
        }

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

        // Record the real on-disk size for the memory panel (mmap'd weights).
        {
            struct stat st{};
            if (::stat(model_path, &st) == 0) {
                model_file_size_bytes_ = (int64_t)st.st_size;
                LOGI("Model file size: %.1f MB", model_file_size_bytes_ / (1024.0 * 1024.0));
            } else {
                model_file_size_bytes_ = 0;
            }
        }

        vocab = llama_model_get_vocab(model);

        const int n_embd  = llama_model_n_embd(model);
        const int n_layer = llama_model_n_layer(model);
        const int n_nextn = llama_model_n_layer_nextn(model); // MTP head depth (0 = none)
        const int64_t n_params = llama_model_n_params(model);
        LOGI("GGUF model loaded. params=%lld, n_embd=%d, n_layer=%d, n_nextn=%d",
             (long long)n_params, n_embd, n_layer, n_nextn);

        // MTP is only possible when the model ships NextN (MTP) layers AND the user
        // opted in via the UI toggle (enable_mtp). Probe the head once here so both
        // n_rs_seq (below) and the completion() path know whether to run the
        // speculative driver. Keep mtp_enabled false if no head or no user opt-in.
        mtp_enabled = enable_mtp && (n_nextn > 0);

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
        // n_batch  = logical max tokens per llama_decode call (prompt chunk size).
        // n_ubatch = physical max tokens processed per internal compute pass.
        // BOTH must be LARGE for fast prefill: llama.cpp only engages BLAS / parallel
        // matmul when the physical ubatch is >= ~32. The previous build used
        // n_ubatch = 16 here, which forced llama_decode to process the prompt in
        // 16-token physical passes -> prefill (TTFT) was 10-30x slower than it
        // should be. The real cause of the old "large-batch garbage logits" bug was
        // the CLASSIC (non-unified) KV backend, NOT large batches per se: the
        // official llama.android example uses the UNIFIED KV buffer + large batches
        // and works fine. We now enable the unified buffer (kv_unified=true) so
        // large batches are correct, and raise both batch sizes to 512.
        ctx_params.n_batch  = 512;
        // n_ubatch: physical prefill chunk size. On the CPU backend, ubatch >= 32
        // makes ggml-cpu dispatch to the quantized GEMM path, which on this build
        // (armv8.4-a+dotprod+i8mm) emits garbage logits when the prompt exceeds 32
        // tokens (verified on-device: turn 2 → nonsense). ubatch=16 forces the
        // correct vec_dot path, so CPU mode MUST stay at 16. On the GPU backend
        // (OpenCL/Vulkan) prefill runs on the GPU kernel and does NOT hit that CPU
        // GEMM bug, so we raise ubatch to 512 for fast prefill there.
        ctx_params.n_ubatch = enable_gpu ? 512 : 16;
        LOGI("n_ubatch = %d (%s backend)", ctx_params.n_ubatch,
             enable_gpu ? "GPU" : "CPU");
        // Flash attention: AUTO enables it on backends that support it (e.g. Vulkan
        // GPU on Android). NOTE: on CPU this llama.cpp build also implements
        // FLASH_ATTN_EXT (ggml-cpu/ops.cpp), so AUTO does NOT no-op on CPU — it
        // enables flash attn there too. That combination (unified KV + flash attn +
        // seq_rm per turn) produced garbage logits from the very first sampled
        // token on turn 2 (KV reused after seq_rm), verified on-device
        // (turn 1 OK 15 tokens; turn 2: 386 tokens of "rekl bytesRead,}" noise).
        // Use DISABLED until the flash-attn-after-seq_rm state reset is verified.
        ctx_params.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_DISABLED;
        // Thread strategy: use ALL cores on all-big SoCs (e.g. Snapdragon 8s Gen 4
        // = 1×X4 + 7×A720), or only the big cores on big.LITTLE SoCs (little cores
        // cause contention / thermal issues). Falls back to all cores if topology
        // cannot be read. The old `hc/2` heuristic halved throughput on all-big
        // SoCs (measured: 8 cores → 4 threads). Applies to generation + batch.
        {
            unsigned hc = std::thread::hardware_concurrency();
            int big = detect_big_core_count();
            int nt;
            if (big > 0) {
                nt = big; // big.LITTLE → big cores only; all-big → all cores
            } else {
                nt = (int)hc; // fallback: all cores
            }
            if (nt < 1) nt = 1;
            ctx_params.n_threads       = nt;
            ctx_params.n_threads_batch = nt;
            LOGI("n_threads = %d (hardware_concurrency=%u, big=%d)", nt, hc, big);
        }
        // Unified KV buffer: REQUIRED for large-batch prefill to be correct on this
        // build (eliminates the old classic-KV large-batch garbage-logits bug).
        // Per-turn KV clearing still uses llama_memory_seq_rm(0,0,n_ctx), which is
        // the documented API and works correctly on the unified buffer.
        ctx_params.kv_unified = true;

        // For MTP speculative decoding, partial draft acceptance is rolled back via
        // the rollback-sequence (RS) mechanism: llama_memory_seq_rm() removes the
        // unaccepted draft tokens past the commit point without a full state
        // checkpoint. Reserve enough RS slots for the worst case (all drafts
        // rejected) so the driver never needs checkpoints. Harmless when mtp_enabled
        // is false (n_rs_seq=0 leaves the context in the current non-RS layout).
        ctx_params.n_rs_seq = mtp_enabled ? (n_draft_max + 1) : 0;

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

        // MTP: create a second context that runs ONLY the NextN head, reusing the
        // already-loaded target model. The driver (common_speculative) mirrors the
        // target hidden states into this context and uses it to draft tokens. See
        // llama.cpp tools/server/server-context.cpp + common/speculative.cpp for the
        // canonical setup (ctx_type=LLAMA_CONTEXT_TYPE_MTP, ctx_other=main ctx).
        if (mtp_enabled) {
            llama_context_params mtp_params = llama_context_default_params();
            mtp_params.ctx_type  = LLAMA_CONTEXT_TYPE_MTP;
            mtp_params.ctx_other = context;                       // main target context
            mtp_params.n_ctx     = (uint32_t)ctx_val;
            mtp_params.n_batch   = ctx_params.n_batch;            // room for [id_last + drafts]
            mtp_params.n_ubatch  = ctx_params.n_ubatch;
            mtp_params.n_rs_seq  = 0;                             // MTP ctx needs no rollback
            mtp_params.n_threads = ctx_params.n_threads;
            mtp_params.n_threads_batch = ctx_params.n_threads_batch;
            mtp_params.kv_unified = true;

            mtp_ctx = llama_init_from_model(model, mtp_params);
            if (mtp_ctx) {
                LOGI("MTP context created (n_ctx=%d, n_draft_max=%d). Speculative decoding ON.",
                     ctx_val, n_draft_max);
            } else {
                // Not fatal: fall back to the single-token autoregressive path.
                mtp_enabled = false;
                mtp_ctx = nullptr;
                LOGW("MTP context creation failed (OOM?) -> falling back to plain decoding");
            }
        } else {
            LOGI("Model has no NextN layers -> MTP disabled (plain autoregressive decoding)");
        }

        // ------------------------------------------------------------------
        // DSpark speculative decoding: load an independent draft model (e.g.
        // Bonsai-27B-dspark-Q4_1.gguf, a DFlash + Markov head). The draft ctx
        // uses the DEFAULT context type (only MTP needs the special type); the
        // common_speculative driver mirrors target hidden states into it.
        // Failure is NOT fatal: falls back to MTP or plain decoding.
        // ------------------------------------------------------------------
        if (mtp_enabled) {
            LOGI("MTP enabled -> dspark draft head ignored (mutually exclusive)");
        } else if (draft_path && draft_path[0] != '\0') {
            LOGI("Loading dspark draft model: %s", draft_path);
            reportLoadingLog("正在加载投机草稿模型（dspark 加速）...");
            llama_model_params draft_params = llama_model_default_params();
            // Draft model runs on CPU (tiny head; offload wastes memory).
            draft_params.n_gpu_layers = 0;
            draft_model = llama_model_load_from_file(draft_path, draft_params);
            if (!draft_model) {
                LOGE("Failed to load dspark draft model -> dspark disabled");
                draft_model = nullptr;
            } else {
                llama_context_params dspark_params = llama_context_default_params();
                dspark_params.ctx_other = context;          // mirror target hidden states
                dspark_params.n_ctx     = (uint32_t)ctx_val;
                dspark_params.n_batch   = ctx_params.n_batch;
                dspark_params.n_ubatch  = ctx_params.n_ubatch;
                dspark_params.n_rs_seq  = 0;
                dspark_params.n_threads = ctx_params.n_threads;
                dspark_params.n_threads_batch = ctx_params.n_threads_batch;
                dspark_params.kv_unified = true;
                dspark_ctx = llama_init_from_model(draft_model, dspark_params);
                if (!dspark_ctx) {
                    LOGE("Failed to create dspark draft context -> dspark disabled");
                    llama_model_free(draft_model);
                    draft_model = nullptr;
                } else {
                    dspark_enabled = true;
                    LOGI("DSpark draft context created (n_ctx=%d). Speculative decoding ON.", ctx_val);
                }
            }
        } else {
            LOGI("No dspark draft path -> dspark disabled");
        }

        // ------------------------------------------------------------------
        // Vision: load the mmproj projector via mtmd (if provided).
        // mtmd_init_from_file needs the already-loaded text model to validate
        // embedding dims. Failure is NOT fatal: the model falls back to
        // text-only inference (vision_loaded stays false).
        // ------------------------------------------------------------------
        if (mmproj_path && mmproj_path[0] != '\0') {
            LOGI("Loading mmproj: %s", mmproj_path);
            reportLoadingLog("正在加载 mmproj 投影器（图像理解）...");
            mtmd_context_params mparams = mtmd_context_params_default();
            // 视觉编码后端跟随主推理后端选择（避免"主 Vulkan + 视觉 OpenCL"
            // 的不一致）：
            //   - 主后端为 Vulkan  -> MTMD_BACKEND_DEVICE=Vulkan（天玑 Mali 上
            //     OpenCL 不可用，且旧版强制 OpenCL 会显示矛盾并回退 CPU）
            //   - 主后端为 OpenCL  -> MTMD_BACKEND_DEVICE=OpenCL（Adreno 专项优化）
            //   - 主后端为 CPU    -> use_gpu=false（纯 CPU 编码）
            //
            // 历史：vision tower 曾在 Vulkan backend 下 SIGSEGV（fault addr 0x0），
            // 故旧实现一刀切强制 OpenCL/CPU。但本版本已修复 ggml-vulkan 的天玑
            // 崩溃（vkGetDeviceQueue2 -> vkGetDeviceQueue，见 ggml-vulkan.cpp），
            // Vulkan 视觉编码已可安全使用。
            std::string mm_backend;
            if (!enable_gpu) {
                mm_backend = "CPU";
            } else if (backend == "opencl") {
                mm_backend = "OpenCL";
            } else {
                mm_backend = "Vulkan";
            }
            mparams.use_gpu   = (mm_backend != "CPU");
            mparams.n_threads = ctx_params.n_threads;
            mparams.warmup    = true;
            // Adreno 上 ViT GPU offload 必须开 flash-attn：关闭会尝试分配 ~9.4GB
            // 缓冲导致失败（#25771/#23800）。用 AUTO 让 mtmd warmup 探测后启用。
            mparams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_AUTO;
            // 硬上限：单图 token 数（配合 Dart 侧图像缩小），控制 GPU 显存预算，
            // 规避 #23422 类显存不足 NULL 解引用崩溃。
            mparams.image_max_tokens = 512;
            if (mm_backend != "CPU") {
                setenv("MTMD_BACKEND_DEVICE", mm_backend.c_str(), 1);
            } else {
                unsetenv("MTMD_BACKEND_DEVICE");
            }
            LOGI("mmproj: attempting %s GPU encode (flash_attn=AUTO)", mm_backend.c_str());
            mmproj = mtmd_init_from_file(mmproj_path, model, mparams);
            if (mmproj) {
                vision_loaded = true;
                audio_loaded = mtmd_support_audio(mmproj);
                audio_sample_rate = mtmd_get_audio_sample_rate(mmproj);
                const char *marker = mtmd_get_marker(mmproj);
                LOGI("mmproj loaded OK on %s (marker=%s, audio=%d, sr=%d)",
                     mm_backend.c_str(), marker ? marker : "?", (int)audio_loaded, audio_sample_rate);
                reportLoadingLog((std::string("mmproj 投影器加载完成 ✓ 图像理解 (")
                                 + mm_backend + " GPU 编码)"
                                 + (audio_loaded ? " + 🎧 语音理解" : "")).c_str());
            } else {
                // GPU 初始化失败（backend 不可用 / 显存不足返回错误而非崩溃）
                // → 回退 CPU 编码，避免一刀切丢失视觉能力。
                LOGW("mmproj %s GPU load FAILED -> retry CPU encode", mm_backend.c_str());
                reportLoadingLog("mmproj GPU 编码不可用，回退 CPU 编码");
                mparams.use_gpu   = false;
                mparams.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_DISABLED;
                mmproj = mtmd_init_from_file(mmproj_path, model, mparams);
                if (mmproj) {
                    vision_loaded = true;
                    audio_loaded = mtmd_support_audio(mmproj);
                    audio_sample_rate = mtmd_get_audio_sample_rate(mmproj);
                    const char *marker = mtmd_get_marker(mmproj);
                    LOGI("mmproj loaded OK on CPU (marker=%s, audio=%d, sr=%d)",
                         marker ? marker : "?", (int)audio_loaded, audio_sample_rate);
                    reportLoadingLog((std::string("mmproj 投影器加载完成 ✓ 支持图像理解 (CPU 编码)")
                                     + (audio_loaded ? " + 🎧 语音理解" : "")).c_str());
                } else {
                    vision_loaded = false;
                    mmproj = nullptr;
                    LOGW("mmproj load FAILED -> text-only inference");
                    reportLoadingLog("mmproj 投影器加载失败，将仅文本推理");
                }
            }
        } else {
            LOGI("No mmproj provided -> text-only model");
        }

        char buf3[128];
        snprintf(buf3, sizeof(buf3), "推理上下文初始化完成 (n_ctx=%d)%s%s%s", ctx_val,
                 mtp_enabled ? "，MTP 加速已启用" : "",
                 vision_loaded ? "，视觉已启用" : "",
                 audio_loaded ? "，语音已启用" : "");
        reportLoadingLog(buf3);
        return true;
    }

    void unload() {
        const int v = static_cast<int>(n_ctx.load());
        LOGI("unload() ENTER: context=%p model=%p n_ctx=%d is_running=%d", (void*)context, (void*)model, v, (int)is_running.load());
        std::lock_guard<std::mutex> lock(mtx);
        const int v2 = static_cast<int>(n_ctx.load());
        LOGI("unload() LOCK ACQUIRED: context=%p model=%p n_ctx=%d", (void*)context, (void*)model, v2);
        if (mtp_ctx)  { llama_free(mtp_ctx);   mtp_ctx = nullptr; }
        if (dspark_ctx) { llama_free(dspark_ctx); dspark_ctx = nullptr; }
        if (context)  { llama_free(context);  context = nullptr; }
        if (mmproj)   { mtmd_free(mmproj);     mmproj = nullptr; }
        vision_loaded = false;
        audio_loaded = false;
        audio_sample_rate = -1;
        if (model)        { llama_model_free(model);        model = nullptr; }
        if (draft_model)  { llama_model_free(draft_model);  draft_model = nullptr; }
        vocab = nullptr;
        mtp_enabled = false;
        dspark_enabled = false;
        prev_prompt_tokens.clear();
        have_prev_kv = false;
        n_ctx = 0;
        is_running = false;
        model_file_size_bytes_ = 0;
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
        if (mtp_ctx != nullptr) {
            llama_memory_seq_rm(llama_get_memory(mtp_ctx), 0, 0, (llama_pos)llama_n_ctx(mtp_ctx));
        }
        kv_position = 0;
        prev_prompt_tokens.clear();
        have_prev_kv = false;
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
    // Vision completion — self-contained mtmd flow.
    // 1. Format chatml template, injecting the mmproj media marker into the
    //    LAST (current) user message so mtmd_tokenize can attach the image.
    // 2. Decode the image file to an RGB bitmap (mtmd_helper).
    // 3. mtmd_tokenize -> TEXT/IMAGE chunks.
    // 4. mtmd_helper_eval_chunks: text chunks -> llama_decode, image chunks ->
    //    mtmd encode + embedding decode. Tracks n_past into kv_position.
    // 5. Plain autoregressive generation (MTP is disabled on the vision path).
    // The text path in completion() is left 100% untouched; this is a separate
    // branch used only when mmproj is loaded AND an image is provided.
    // ------------------------------------------------------------------
    std::string completion_with_media(
        const std::vector<llama_chat_message> &history,
        const char *media_path,
        int max_tokens,
        float temperature,
        float top_p,
        std::function<bool(const std::string &)> on_token) {

        // 1. Chatml template with the media marker on the last user message.
        std::vector<llama_chat_message> chat_vec = history;
        std::string last_with_marker;
        {
            const char *marker = mtmd_get_marker(mmproj);
            const std::string m = (marker && marker[0]) ? std::string(marker) : "<__media__>";
            last_with_marker = std::string(chat_vec.back().content) + "\n" + m;
            chat_vec.back().content = last_with_marker.c_str();
        }

        char buf[16384];
        int32_t n = llama_chat_apply_template(
            "chatml", chat_vec.data(), chat_vec.size(), true, buf, sizeof(buf));
        std::string formatted_prompt;
        if (n > 0 && n < (int32_t)sizeof(buf)) {
            formatted_prompt.assign(buf, n);
            // Qwen3 thinking suppression (same rule as the text path).
            const char *mtmpl = llama_model_chat_template(model, nullptr);
            const bool supports_think =
                mtmpl && std::string(mtmpl).find("think") != std::string::npos;
            const std::string asst_marker = "assistant\n";
            if (!enable_thinking.load() &&
                formatted_prompt.size() >= asst_marker.size() &&
                formatted_prompt.compare(formatted_prompt.size() - asst_marker.size(),
                                         asst_marker.size(), asst_marker) == 0) {
                formatted_prompt += " thinking\n\n response\n\n";
            }
        } else {
            LOGW("vision: chatml template failed (n=%d) -> abort", n);
            return "[ERROR: 模板生成失败]";
        }
        LOGI("vision formatted_prompt (%zu chars): %.*s",
             formatted_prompt.size(),
             (int)std::min((size_t)300, formatted_prompt.size()),
             formatted_prompt.c_str());

        // 2. Decode the media file (image OR audio — mtmd_helper auto-detects by
        //    magic bytes: jpg/png/bmp for images, wav/mp3/flac for audio) to a bitmap.
        struct mtmd_helper_bitmap_wrapper wrap =
            mtmd_helper_bitmap_init_from_file(mmproj, media_path, /*placeholder=*/false);
        if (!wrap.bitmap) {
            LOGW("vision: failed to decode media %s", media_path);
            return "[ERROR: 媒体文件解码失败]";
        }
        mtmd_bitmap *bm = wrap.bitmap;

        // 3. Tokenize text + image into chunks.
        const bool add_bos = llama_vocab_get_add_bos(vocab);
        mtmd_input_text text{ formatted_prompt.c_str(), formatted_prompt.size(),
                              /*add_special=*/add_bos, /*parse_special=*/true };
        mtmd_input_chunks *chunks = mtmd_input_chunks_init();
        const mtmd_bitmap *bms[] = { bm };
        int32_t res = mtmd_tokenize(mmproj, chunks, &text, bms, 1);
        if (res != 0) {
            LOGW("vision: mtmd_tokenize failed res=%d", res);
            mtmd_input_chunks_free(chunks);
            mtmd_bitmap_free(bm);
            return "[ERROR: 图像预处理失败]";
        }
        const size_t n_prompt_tokens = mtmd_helper_get_n_tokens(chunks);
        LOGI("vision: %zu chunks, %zu prompt tokens",
             mtmd_input_chunks_size(chunks), n_prompt_tokens);

        // 4. Full KV clear — vision + token-based incremental prefill don't mix.
        llama_memory_seq_rm(llama_get_memory(context), 0, 0, (llama_pos)llama_n_ctx(context));
        kv_position = 0;

        // 5. Eval all chunks (text -> llama_decode, media -> encode + decode).
        //    手动遍历 chunks，单独累计「图像编码」(识图) 与「音频编码」(听音)
        //    耗时 t_vision_ms / t_audio_ms —— 媒体编码是多媒体回复的主要耗时。
        auto t_start = std::chrono::high_resolution_clock::now();
        t_vision_ms = 0.0;
        t_audio_ms  = 0.0;
        llama_pos n_past = 0;
        {
            const size_t n_chunks = mtmd_input_chunks_size(chunks);
            for (size_t i = 0; i < n_chunks; i++) {
                auto chunk = mtmd_input_chunks_get(chunks, i);
                const bool chunk_logits_last = (i == n_chunks - 1);
                auto s = std::chrono::high_resolution_clock::now();
                res = mtmd_helper_eval_chunk_single(mmproj, context, chunk, n_past,
                                                    /*seq_id=*/0,
                                                    (int32_t)ctx_params.n_batch,
                                                    chunk_logits_last, &n_past);
                auto e = std::chrono::high_resolution_clock::now();
                const auto ctype = mtmd_input_chunk_get_type(chunk);
                if (ctype == MTMD_INPUT_CHUNK_TYPE_IMAGE) {
                    t_vision_ms += std::chrono::duration<double, std::milli>(e - s).count();
                } else if (ctype == MTMD_INPUT_CHUNK_TYPE_AUDIO) {
                    t_audio_ms += std::chrono::duration<double, std::milli>(e - s).count();
                }
                if (res != 0) break;
            }
        }
        kv_position = n_past;
        auto t_end = std::chrono::high_resolution_clock::now();
        t_prompt_ms = std::chrono::duration<double, std::milli>(t_end - t_start).count();
        LOGI("vision: eval chunks done, n_past=%lld, prompt %.0fms, 识图 %.0fms, 听音 %.0fms",
             (long long)n_past, t_prompt_ms, t_vision_ms, t_audio_ms);

        mtmd_input_chunks_free(chunks);
        mtmd_bitmap_free(bm);

        if (res != 0) {
            LOGW("vision: mtmd_helper_eval_chunks failed res=%d", res);
            return "[ERROR: 图像编码失败]";
        }

        // 6. Plain autoregressive generation (MTP disabled on vision path).
        std::string result;
        std::string gen_utf8_buf;
        std::string flush_buf;
        bool gen_stopped = false;
        const llama_token eos = llama_vocab_eos(vocab);
        std::vector<llama_token> gen_tokens;
        const size_t kFlushBatchSize = 8;
        n_gen = 0;
        t_gen_ms = 0;

        auto emit_token = [&](llama_token tok) -> bool {
            char tbuf[256];
            int tn = llama_token_to_piece(vocab, tok, tbuf, sizeof(tbuf), 0, false);
            if (tn <= 0) return true;
            gen_tokens.push_back(tok);
            gen_utf8_buf.append(tbuf, tn);
            size_t consumed = 0;
            while (consumed < gen_utf8_buf.size()) {
                int adv = utf8_seq_len(gen_utf8_buf, consumed);
                if (adv == 0) break;
                if (adv < 0) { consumed += 1; continue; }
                std::string one = gen_utf8_buf.substr(consumed, adv);
                consumed += adv;
                sp_space_to_ascii(one);
                result += one;
                flush_buf += one;
                if (flush_buf.size() >= kFlushBatchSize) {
                    if (on_token && !on_token(flush_buf)) {
                        gen_stopped = true;
                        flush_buf.clear();
                        return false;
                    }
                    flush_buf.clear();
                }
            }
            gen_utf8_buf.erase(0, consumed);
            return !gen_stopped;
        };

        struct llama_sampler_chain_params sparams = llama_sampler_chain_default_params();
        struct llama_sampler * smpl_chain = llama_sampler_chain_init(sparams);
        llama_sampler_chain_add(smpl_chain, llama_sampler_init_penalties(llama_vocab_n_tokens(vocab), 64, 1.1f, 0.0f, 0.0f));
        llama_sampler_chain_add(smpl_chain, llama_sampler_init_top_k(128));
        llama_sampler_chain_add(smpl_chain, llama_sampler_init_top_p(top_p, 1));
        llama_sampler_chain_add(smpl_chain, llama_sampler_init_temp(temperature));
        llama_sampler_chain_add(smpl_chain, llama_sampler_init_dist((uint32_t)llama_time_us()));

        while (n_gen < max_tokens && !should_stop) {
            llama_token new_token = llama_sampler_sample(smpl_chain, context, -1);
            llama_sampler_accept(smpl_chain, new_token);
            if (new_token == eos) { LOGI("vision: EOS at gen=%d", n_gen); break; }
            if (!emit_token(new_token)) { gen_stopped = true; break; }
            const int32_t decode_pos = kv_position + n_gen;
            if (decode_pos >= (int32_t)llama_n_ctx(context)) {
                LOGW("vision: decode_pos %d >= n_ctx, stop", decode_pos);
                break;
            }
            auto s2 = std::chrono::high_resolution_clock::now();
            llama_batch token_batch = llama_batch_init(1, 0, 1);
            token_batch.n_tokens    = 1;
            token_batch.token[0]    = new_token;
            token_batch.pos[0]      = decode_pos;
            token_batch.n_seq_id[0] = 1;
            token_batch.seq_id[0][0]= 0;
            token_batch.logits[0]   = true;
            int32_t dec_ret = llama_decode(context, token_batch);
            llama_batch_free(token_batch);
            if (dec_ret != 0) { LOGE("vision: gen decode failed ret=%d", dec_ret); break; }
            n_gen++;
            auto e2 = std::chrono::high_resolution_clock::now();
            t_gen_ms += std::chrono::duration<double, std::milli>(e2 - s2).count();
        }
        llama_sampler_free(smpl_chain);

        kv_position += n_gen;

        if (!flush_buf.empty()) { if (on_token) on_token(flush_buf); flush_buf.clear(); }
        if (!gen_stopped && !gen_utf8_buf.empty()) {
            size_t consumed = 0;
            while (consumed < gen_utf8_buf.size()) {
                int adv = utf8_seq_len(gen_utf8_buf, consumed);
                if (adv <= 0) break;
                std::string one = gen_utf8_buf.substr(consumed, adv);
                consumed += adv;
                sp_space_to_ascii(one);
                result += one;
                if (on_token) on_token(one);
            }
            gen_utf8_buf.clear();
        }

        // Vision leaves image embeddings in the KV — no clean token prefix for
        // incremental prefill. Force a full clear on the next turn.
        have_prev_kv = false;
        prev_prompt_tokens.clear();

        is_running = false;

        // 媒体路径也必须回写 g_last_stats，否则 Dart 读到的是上一次（或默认 0）
        // stats → UI 的 tok/s 一直显示 0.0。
        g_last_stats.n_gen       = n_gen;
        g_last_stats.t_gen_ms    = t_gen_ms;
        g_last_stats.t_prompt_ms = t_prompt_ms;
        g_last_stats.t_vision_ms = t_vision_ms;
        g_last_stats.t_audio_ms  = t_audio_ms;
        LOGI("vision generation done: %d tokens, %.1f tok/s (prompt %.0fms, gen %.0fms, 识图 %.0fms, 听音 %.0fms)",
             n_gen, t_gen_ms > 0 ? (n_gen * 1000.0 / t_gen_ms) : 0.0,
             t_prompt_ms, t_gen_ms, t_vision_ms, t_audio_ms);
        return result;
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
        const std::vector<llama_chat_message> *history = nullptr,
        // Optional on-disk media path (image OR audio, mmproj must be loaded).
        // When set, completion routes to the mtmd media path. Audio is only
        // accepted if the loaded mmproj ships an audio encoder (mtmd_support_audio).
        const char *image_path = nullptr,
        const char *audio_path = nullptr
    ) {
        const int ctx_val = static_cast<int>(n_ctx.load());
        LOGI("completion() ENTER: model=%p context=%p n_ctx=%d is_running=%d",
             (void*)model, (void*)context, ctx_val, (int)is_running.load());
        LOGI("===== TongYiLite JNI unified-kv+ubatch(16)+no-fa+penalty+accept BUILD 20260804 V0.1.3 =====");
        // Hold the lock for the ENTIRE duration of completion to prevent unload()
        // from running concurrently and destroying model/context mid-inference.
        std::lock_guard<std::mutex> lock(mtx);
        LOGI("completion() LOCK ACQUIRED: model=%p context=%p n_ctx=%d",
             (void*)model, (void*)context, ctx_val);

        if (!is_loaded()) {
            LOGE("completion() aborted INSIDE LOCK: no model loaded");
            return "[ERROR: No model loaded]";
        }

        // ================================================================
        // Media path — mmproj loaded + a media file (image/audio) this turn.
        // Routes to completion_with_media() (self-contained mtmd flow).
        // ================================================================
        const char *media_path = nullptr;
        bool media_is_audio = false;
        if (audio_path && audio_path[0] != '\0') {
            if (!audio_loaded) {
                LOGW("media path: audio requested but mmproj has NO audio encoder -> reject");
                return "[ERROR: 当前模型不支持语音理解，请加载 Gemma 4 E2B 或开启语音的模型]";
            }
            media_path = audio_path;
            media_is_audio = true;
        } else if (image_path && image_path[0] != '\0') {
            media_path = image_path;
        }
        if (mmproj && vision_loaded && media_path && history && !history->empty()) {
            is_running = true;
            should_stop = false;
            LOGI("media completion path (mmproj=%p %s=%s)", (void*)mmproj,
                 media_is_audio ? "audio" : "image", media_path);
            try {
                std::string res = completion_with_media(
                    *history, media_path, max_tokens, temperature, top_p, on_token);
                is_running = false;
                return res;
            } catch (const std::exception &e) {
                LOGE("media completion exception: %s", e.what());
                is_running = false;
                return std::string("[ERROR: media completion failed]");
            }
        }

        try {
            is_running  = true;
            should_stop = false;

            // Multi-turn strategy: KEEP the single context created at load().
            // KV clearing is now DEFERRED until after tokenization+truncation so
            // we can do cross-turn INCREMENTAL prefill: keep the common prefix of
            // the previous turn's prompt (saving the re-prefill of all history)
            // and only wipe/prefill the newly-added suffix. See the block after
            // "Prompt: %d tokens" below. When no prefix can be reused we fall back
            // to the previous full-wipe behavior (llama_memory_seq_rm + clear).
            // NOTE: per-turn llama_init_from_model was abandoned — on this build the
            // re-inited context's KV was NOT pristine for longer (multi-turn)
            // prompts and produced flat/garbage logits ("coln魔魔魔").
            if (context == nullptr) {
                LOGE("completion(): context is null (model not loaded?)");
                is_running = false;
                return "[ERROR: Context not initialized]";
            }

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

            // ================================================================
            // Cross-turn KV INCREMENTAL prefill. Compute the common prefix of the
            // previous turn's cached prompt and this turn's prompt; keep the prefix
            // KV (double-write to context + mtp_ctx, which share the KV buffer but
            // maintain separate sequence views) and wipe only the divergent suffix.
            // When no prefix can be reused we fall back to a full wipe (old behavior).
            // ================================================================
            auto full_clear = [&]() {
                llama_memory_seq_rm(llama_get_memory(context), 0, 0, (llama_pos)ctx_val2);
                if (mtp_ctx) llama_memory_seq_rm(llama_get_memory(mtp_ctx), 0, 0, (llama_pos)ctx_val2);
                kv_position = 0;
                have_prev_kv = false;
                LOGI("KV full clear for new completion");
            };

            // Incremental reuse only pays off when a meaningful prefix survives.
            // In practice the chatml template's assistant trigger ("thinking\n\n response")
            // diverges from the re-rendered reply right after "<|im_start|>assistant\n",
            // so the cross-turn LCP rarely spans the whole history (it stops at the last
            // trigger). We still require a small floor (16) to skip degenerate tiny
            // prefixes; the unified-KV memory-slot decode failure that a tiny kept
            // prefix used to trigger (empty replies on alternating turns) is now
            // handled by the decode-fail -> full-clear retry below, so the floor no
            // longer needs to be 128. A floor that high silently disabled incremental
            // prefill on every short/medium conversation (LCP < 128 -> full clear),
            // which is why multi-turn TTFT never improved.
            const int MIN_INCREMENTAL_PREFIX = 16;
            int prefix_len = 0;
            if (have_prev_kv && !prev_prompt_tokens.empty() && !prompt_tokens.empty()) {
                prefix_len = longest_common_prefix(prev_prompt_tokens, prompt_tokens);
                if (prefix_len >= MIN_INCREMENTAL_PREFIX && prefix_len < n_prompt) {
                    // keep [0, prefix_len), drop [prefix_len, end)
                    llama_memory_seq_rm(llama_get_memory(context), 0, prefix_len, (llama_pos)ctx_val2);
                    if (mtp_ctx) llama_memory_seq_rm(llama_get_memory(mtp_ctx), 0, prefix_len, (llama_pos)ctx_val2);
                    kv_position = prefix_len;   // critical: do NOT reset to 0
                    LOGI("KV incremental: kept prefix=%d, will prefill %d tokens (saved %d)",
                         prefix_len, n_prompt - prefix_len, prefix_len);
                } else {
                    full_clear();
                }
            } else {
                full_clear();
            }

            LOGI("eos token id = %d, n_vocab = %d",
                 (int)llama_vocab_eos(vocab), (int)llama_vocab_n_tokens(vocab));

            // ================================================================
            // MTP speculative setup — must run BEFORE prefill so the driver can
            // mirror the target hidden states into the MTP context during prompt
            // decoding (common_speculative_process), and so its ctor call to
            // llama_set_embeddings_nextn(ctx_tgt,...) is in effect for prefill.
            // ================================================================
            common_speculative *mtp_spec = nullptr;
            struct common_sampler *mtp_smpl = nullptr;
            llama_tokens mtp_prompt_tgt;      // all prompt tokens EXCEPT the last
            llama_token  mtp_id_last = 0;
            int mtp_n_past = 0;
            if ((mtp_enabled || dspark_enabled) && n_prompt > 1) {
                common_params_speculative spec_params;
                // MTP: head lives inside the target model; DSpark: independent
                // draft model (DFlash + Markov head). Mutually exclusive at load.
                if (mtp_enabled) {
                    spec_params.types = { COMMON_SPECULATIVE_TYPE_DRAFT_MTP };
                } else {
                    spec_params.types = { COMMON_SPECULATIVE_TYPE_DRAFT_DSPARK };
                }
                spec_params.draft.n_max   = n_draft_max;
                spec_params.draft.n_min   = 1;   // always draft at least one token
                // Early-stop drafting once the head's confidence drops below p_min.
                // The official speculative impl (speculative.cpp draft-mtp) uses this
                // to avoid spending a verify batch on garbage drafts: at p_min=0 it
                // ALWAYS drafts n_max tokens even when the head is guessing, which
                // wastes the target verify forward. A moderate threshold lets us
                // "draft only high-confidence tokens" — the single biggest lever to
                // stop the observed negative benefit.
                spec_params.draft.p_min   = 0.3f;
                spec_params.draft.ctx_tgt = context;
                spec_params.draft.ctx_dft = mtp_enabled ? mtp_ctx : dspark_ctx;
                mtp_spec = common_speculative_init(spec_params, /*n_seq=*/1);
                if (!mtp_spec) {
                    LOGW("MTP spec init failed -> falling back to plain decoding");
                    mtp_enabled = false;
                } else {
                    // Target-side sampler for the verification step. Mirrors the
                    // raw llama_sampler_chain in the plain path below: repeat
                    // penalty (critical against repetition loops) + top_k + top_p
                    // + temperature; common_sampler_init appends the dist sampler.
                    common_params_sampling sparams;
                    sparams.seed = (uint32_t)llama_time_us();
                    sparams.penalty_last_n = 64;
                    sparams.penalty_repeat = 1.1f;
                    sparams.penalty_freq   = 0.0f;
                    sparams.penalty_present= 0.0f;
                    sparams.top_k = 128;
                    sparams.top_p = top_p;
                    sparams.temp  = temperature;
                    sparams.samplers = { COMMON_SAMPLER_TYPE_PENALTIES,
                                         COMMON_SAMPLER_TYPE_TOP_K,
                                         COMMON_SAMPLER_TYPE_TOP_P,
                                         COMMON_SAMPLER_TYPE_TEMPERATURE };
                    mtp_smpl = common_sampler_init(model, sparams);
                    mtp_prompt_tgt.assign(prompt_tokens.begin(), prompt_tokens.end() - 1);
                    mtp_id_last = prompt_tokens.back();
                    mtp_n_past  = n_prompt - 1;
                }
            }

            // 2. Decode the prompt in batches. We now feed up to n_batch (512) tokens
            // per llama_decode call, and the unified KV buffer lets llama.cpp process
            // them in large physical ubatches (512) for fast prefill with BLAS.
            // (Previously this loop used n_ubatch=16, which forced 16-token physical
            // passes and made TTFT 10-30x slower than necessary.)
            t_prompt_ms = 0;
            t_gen_ms = 0;
            n_gen = 0;
            // With incremental prefill we continue from the kept prefix's end rather
            // than position 0; otherwise (full clear) this is 0 as before.
            llama_pos cur_pos = (llama_pos)prefix_len;

            auto t_start = std::chrono::high_resolution_clock::now();
            const int32_t n_batch = (int32_t)ctx_params.n_batch;   // 512: large, fast prefill
            int i = prefix_len;   // skip the already-prefilled prefix
            // Decode the prompt. On the FIRST attempt we may be resuming from a kept
            // prefix (incremental). If that decode is rejected by the unified KV cache
            // (memory-slot error — observed as empty replies on alternating turns),
            // fall back to a full wipe and redo the whole prompt from position 0.
            // On the MTP path we keep the LAST prompt token OUT of the KV cache:
            // it is decoded as `id_last` at the start of every speculative iteration
            // (see speculative-simple.cpp). Prefill therefore fills [prefix_len,
            // n_prompt-1) and leaves position n_prompt-1 free for id_last. The plain
            // path prefills the whole prompt as before.
            const int prefill_end = (mtp_spec != nullptr) ? n_prompt - 1 : n_prompt;

            bool done = false;
            for (int attempt = 0; attempt < 2 && !done; ++attempt) {
                bool failed = false;
                while (i < prefill_end) {
                    const int32_t chunk = std::min((int32_t)n_batch, prefill_end - i);
                    llama_batch tok_batch = llama_batch_init(chunk, 0, 1);
                    tok_batch.n_tokens = chunk;
                    for (int32_t j = 0; j < chunk; ++j) {
                        tok_batch.token[j] = prompt_tokens[i + j];
                        tok_batch.pos[j]   = cur_pos + j;
                        tok_batch.n_seq_id[j]  = 1;
                        tok_batch.seq_id[j][0] = 0;
                        tok_batch.logits[j] = (i + j == prefill_end - 1) ? 1 : 0;
                    }
                    if (llama_decode(context, tok_batch) != 0) {
                        llama_batch_free(tok_batch);
                        if (attempt == 0 && prefix_len > 0) {
                            // incremental prefix keep rejected -> full clear and retry once
                            LOGW("incremental prefill decode failed at token %d (pos=%d) -> full clear retry",
                                 i, (int)cur_pos);
                            full_clear();
                            cur_pos = 0;
                            i = 0;
                            failed = true;
                            break;
                        }
                        LOGE("llama_decode() failed on prompt batch starting at token %d (pos=%d)", i, (int)cur_pos);
                        is_running = false;
                        have_prev_kv = false;   // KV is now partially populated -> don't trust cache
                        return "[ERROR: Prompt decode failed]";
                    }
                    // MTP: mirror the target hidden states (t_h_nextn) into the MTP
                    // context so the draft head can predict from the full prompt.
                    if (mtp_spec) {
                        if (!common_speculative_process(mtp_spec, tok_batch)) {
                            LOGE("common_speculative_process() failed on prefill batch %d", i);
                            llama_batch_free(tok_batch);
                            is_running = false;
                            have_prev_kv = false;   // KV may be inconsistent -> don't trust cache
                            return "[ERROR: MTP process failed]";
                        }
                    }
                    llama_batch_free(tok_batch);
                    cur_pos += chunk;
                    i += chunk;
                }
                done = !failed;
            }
            // Plain path: == n_prompt (full prompt in KV). MTP path: == n_prompt-1
            // (last prompt token is left out of the cache; the speculative loop
            // decodes it as id_last at n_prompt-1 and continues from there).
            kv_position = cur_pos;

            // MTP: tell the driver the full prompt is now in the target context.
            if (mtp_spec) {
                common_speculative_begin(mtp_spec, /*seq_id=*/0, mtp_prompt_tgt);
            }

            auto t_end = std::chrono::high_resolution_clock::now();
            t_prompt_ms = std::chrono::duration<double, std::milli>(t_end - t_start).count();

            // 3. Auto-generate tokens
            std::string result;
            std::string gen_utf8_buf;   // raw token bytes; forwarded only as complete UTF-8
            std::string flush_buf;      // batches complete UTF-8 sequences before calling on_token
            bool gen_stopped = false;
            const llama_token eos = llama_vocab_eos(vocab);
            // Tokens generated this turn (both the MTP and plain loops append via
            // the shared emit_token lambda). Written back at turn end so the NEXT
            // turn's incremental prefill can find the common prefix through the
            // assistant reply and stop at the new user message.
            std::vector<llama_token> gen_tokens;
            // Batch size for on_token callbacks — accumulating characters
            // before crossing the JNI/EventChannel boundary reduces per-token
            // overhead from the C++→JNI→Dart round-trip.
            // 8 bytes ≈ 2 CJK chars: small enough to feel character-by-character
            // streaming, big enough to avoid a JNI hop per byte. (64 was too
            // coarse: ~21 chars per chunk read like block output.)
            const size_t kFlushBatchSize = 8;

            // Shared token-emit helper (used by the MTP loop; the plain loop below
            // keeps its own inline copy to stay untouched). Converts a token piece
            // to text, buffers only COMPLETE UTF-8 sequences (so a multi-byte char
            // is never split across JNI calls), batches them into flush_buf before
            // calling on_token, and renders SentencePiece's "▁" as a space. Returns
            // false if the UI callback asked to stop (user pressed stop).
            auto emit_token = [&](llama_token tok) -> bool {
                char buf[256];
                // special=false: skip control/special tokens (render nothing).
                int n = llama_token_to_piece(vocab, tok, buf, sizeof(buf), 0, false);
                if (n <= 0) return true;
                gen_tokens.push_back(tok);   // for the next turn's incremental prefill
                gen_utf8_buf.append(buf, n);
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
                            gen_stopped = true;
                            flush_buf.clear();
                            return false;
                        }
                        flush_buf.clear();
                    }
                }
                gen_utf8_buf.erase(0, consumed);
                return !gen_stopped;
            };

            if (mtp_spec) {
                // ============================================================
                // MTP speculative decoding loop (model has a NextN head)
                // ============================================================
                // Each iteration decodes [id_last, draft0..draftN-1] in ONE forward
                // pass. The MTP head drafts N cheap tokens (common_speculative_draft);
                // the target model then verifies them all at once, and we accept the
                // longest matching prefix (common_sampler_sample_and_accept_n).
                // Rejected drafts are rolled back via the RS mechanism (n_rs_seq on
                // the main context), so no state checkpoints are needed — this is the
                // speculative-simple RS path, with the MTP process() hook keeping the
                // draft context in sync (see llama.cpp server-context.cpp).
                LOGI("MTP generation start: n_draft_max=%d", n_draft_max);
                // Per-completion: reset the adaptive window and start at the full budget.
                mtp_accept_sum   = 0;
                mtp_draft_sum    = 0;
                mtp_adaptive_max = n_draft_max;
                llama_tokens draft;
                struct llama_batch batch_tgt = llama_batch_init(llama_n_batch(context), 0, 1);
                const llama_seq_id seq_id = 0;
                t_gen_ms = 0;
                while (n_gen < max_tokens && !should_stop) {
                    // 1) generate a fresh draft from the MTP head
                    if (draft.empty()) {
                        // Adaptive draft budget: shrink n_draft when the head's recent
                        // acceptance is low so the target verify batch stays small and
                        // we stop paying for drafts that get rejected. Restore the full
                        // budget once the head recovers. (See member docs above.)
                        if (mtp_draft_sum >= 12.0f) {
                            const float rate = mtp_accept_sum / mtp_draft_sum;
                            mtp_adaptive_max = (rate >= 0.75f) ? n_draft_max :
                                               (rate >= 0.50f) ? 2 : 1;
                            LOGI("[MTP] adaptive n_draft=%d (accept_rate=%.2f)",
                                 mtp_adaptive_max, rate);
                        }
                        // Clamp n_max to the remaining KV budget so we never decode
                        // past n_ctx (same overflow guard as the plain path).
                        const int n_max = std::max(1, std::min(mtp_adaptive_max,
                            (int)((int32_t)llama_n_ctx(context) - mtp_n_past - 1)));
                        common_speculative_get_draft_params(mtp_spec, seq_id) = {
                            /*.drafting =*/ true,
                            /*.n_max    =*/ n_max,
                            /*.n_past   =*/ mtp_n_past,
                            /*.id_last  =*/ mtp_id_last,
                            /*.prompt   =*/ &mtp_prompt_tgt,
                            /*.result   =*/ &draft,
                        };
                        common_speculative_draft(mtp_spec);
                        LOGI("[MTP] drafted %zu tokens", draft.size());
                        if (!draft.empty()) {
                            // Trim the MTP context back to the pre-draft base. The draft
                            // stage decoded id_last at mtp_n_past plus the draft tokens
                            // after it; we must wipe ALL of that (>= mtp_n_past) so the
                            // subsequent common_speculative_process() re-decodes id_last
                            // at mtp_n_past as a fresh position. Keeping id_last here made
                            // that re-decode collide with an already-filled KV slot, so
                            // process() returned false and produced an empty reply.
                            llama_memory_seq_rm(llama_get_memory(mtp_ctx), seq_id, mtp_n_past, -1);
                        }
                    }

                    // 2) evaluate [id_last, draft0..N] on the target model
                    common_batch_clear(batch_tgt);
                    common_batch_add(batch_tgt, mtp_id_last, mtp_n_past++, { seq_id }, true);
                    for (size_t k = 0; k < draft.size(); ++k) {
                        common_batch_add(batch_tgt, draft[k], mtp_n_past + k, { seq_id }, true);
                    }
                    t_start = std::chrono::high_resolution_clock::now();
                    LOGI("[MTP] verify batch: id_last=%d n_past=%d n_draft=%zu", mtp_id_last, mtp_n_past - 1, draft.size());
                    const int dec_ret = llama_decode(context, batch_tgt);
                    t_end = std::chrono::high_resolution_clock::now();
                    t_gen_ms += std::chrono::duration<double, std::milli>(t_end - t_start).count();
                    if (dec_ret != 0) {
                        LOGE("[MTP] llama_decode failed ret=%d at n_past=%d", dec_ret, mtp_n_past - 1);
                        break;
                    }

                    // 3) keep the MTP context in sync with the target batch. Only when
                    //    a non-empty draft exists: p_min early-stop can make the head
                    //    produce an empty draft, and process() would fail because the
                    //    draft context never decoded anything for this batch. In that
                    //    case this iteration degrades to a plain single-token step
                    //    (verify decodes [id_last] alone) and the next loop iteration
                    //    re-drafts from the trimmed base — same as official speculative
                    //    empty-draft fallback.
                    if (!draft.empty()) {
                        const bool proc_ok = common_speculative_process(mtp_spec, batch_tgt);
                        LOGI("[MTP] process ok=%d", (int)proc_ok);
                        if (!proc_ok) {
                            LOGE("[MTP] common_speculative_process failed");
                            break;
                        }
                    }

                    // 4) sample the target logits, accept as many drafts as match
                    auto ids = common_sampler_sample_and_accept_n(mtp_smpl, context, draft);
                    LOGI("[MTP] sampled ids.size=%zu draft.size=%zu", ids.size(), draft.size());
                    if (ids.empty()) break;
                    common_speculative_accept(mtp_spec, seq_id, (uint16_t)(ids.size() - 1));
                    LOGI("[MTP] accepted %zu/%zu draft tokens", ids.size() - 1, draft.size());

                    // Feed the running acceptance window (draft.size() is captured
                    // here before the vector is cleared below).
                    mtp_accept_sum += (float)(ids.size() - 1);
                    mtp_draft_sum  += (float)draft.size();

                    // 5) commit accepted tokens: ids[0] is the new sampled token,
                    //    ids[1..] are the verified draft tokens.
                    bool hit_eos = false;
                    for (size_t k = 0; k < ids.size(); ++k) {
                        const llama_token tok = ids[k];
                        if (tok == eos) { hit_eos = true; break; }
                        if (n_gen >= max_tokens) break;
                        if (n_gen < 6) {
                            char pbuf[64];
                            int pn = llama_token_to_piece(vocab, tok, pbuf, sizeof(pbuf), 0, false);
                            std::string phex; char tmp[4];
                            for (int x = 0; x < pn && x < 32; ++x) { snprintf(tmp, sizeof(tmp), "%02X ", (unsigned char)pbuf[x]); phex += tmp; }
                            LOGI("[MTP] gen#%d token=%d piece_hex: %s", n_gen, tok, phex.c_str());
                        }
                        mtp_prompt_tgt.push_back(mtp_id_last);
                        mtp_id_last = tok;
                        n_gen++;
                        if (!emit_token(tok)) { break; }
                    }
                    // n_past advances by the number of accepted tokens (ids.size()-1)
                    // on top of the id_last slot consumed above (mtp_n_past already
                    // incremented once in the batch add).
                    mtp_n_past += (int)ids.size() - 1;
                    draft.clear();

                    // 6) roll back any unaccepted draft tokens (RS) on BOTH contexts
                    llama_memory_seq_rm(llama_get_memory(context), seq_id, mtp_n_past, -1);
                    llama_memory_seq_rm(llama_get_memory(mtp_ctx),  seq_id, mtp_n_past, -1);

                    if (hit_eos)  { LOGI("[MTP] EOS at gen=%d", n_gen); break; }
                    if (gen_stopped) { LOGI("[MTP] stopped by callback at gen=%d", n_gen); break; }
                }
                llama_batch_free(batch_tgt);
                {
                    const float rate = (mtp_draft_sum > 0) ? (mtp_accept_sum / mtp_draft_sum) : 0.0f;
                    LOGI("MTP generation done: %d tokens, accept_rate=%.3f, adaptive_n_draft=%d",
                         n_gen, rate, mtp_adaptive_max);
                }
            } else {
                // ============================================================
                // Plain single-token autoregressive loop (no NextN head)
                // ============================================================
                // Create the sampler chain once and reuse it for every generated token.
            // This replaces the per-token O(vocab) allocation of 150k+
            // llama_token_data entries with the built-in llama.cpp sampler
            // which reuses internal buffers across calls.
            struct llama_sampler_chain_params sparams = llama_sampler_chain_default_params();
            struct llama_sampler * smpl_chain = llama_sampler_chain_init(sparams);
            llama_sampler_chain_add(smpl_chain, llama_sampler_init_penalties(
                llama_vocab_n_tokens(vocab), // n_vocab: vocab size for penalty normalization
                64,                    // penalty_last_n: penalize the last 64 tokens
                1.1f,                  // penalty_repeat: 1.0 = disabled, >1 penalizes repeats
                0.0f,                  // penalty_freq
                0.0f));                // penalty_present
            // CRITICAL: repeat penalty is what prevents degenerate repetition loops.
            // Without it (previous builds), a model that drifts toward one token in a
            // later turn (e.g. 100893/47384 on a 2nd-turn prompt) would repeat that
            // token forever, never hitting EOS. The official llama.android example
            // (ai_chat.cpp) also relies on a penalty-equipped sampler for this reason.
            llama_sampler_chain_add(smpl_chain, llama_sampler_init_top_k(128));
            llama_sampler_chain_add(smpl_chain, llama_sampler_init_top_p(top_p, 1));
            llama_sampler_chain_add(smpl_chain, llama_sampler_init_temp(temperature));
            // CRITICAL: the chain MUST end with a sampling sampler (dist) that
            // actually draws the token and sets cur_p.selected. penalties /
            // top_k / top_p / temp only re-rank or re-weight candidates — without
            // dist, llama_sampler_sample() hits GGML_ASSERT(cur_p.selected >= 0)
            // at llama-sampler.cpp:870 and aborts the process (SIGABRT) in debug
            // builds (verified via tombstone + disassembly). Seed from time so
            // successive generations differ.
            llama_sampler_chain_add(smpl_chain, llama_sampler_init_dist((uint32_t)llama_time_us()));

            while (n_gen < max_tokens && !should_stop) {
                llama_token new_token = 0;

                // Use the built-in llama.cpp sampler for efficient top-k /
                // top-p / temperature sampling. This avoids the per-token
                // O(vocab) allocation and partial_sort of the previous
                // manual implementation.
                new_token = llama_sampler_sample(smpl_chain, context, -1);
                // CRITICAL: feed the sampled token back into the sampler chain.
                // Without llama_sampler_accept, stateful samplers (penalties /
                // top_k / dist RNG) never update their internal history, so the
                // repeat penalty NEVER fires → degenerate repetition loops
                // (e.g. tokens 9841/57699 repeating forever on turn 2, no EOS).
                // Matches llama.android ai_chat.cpp: common_sampler_accept().
                llama_sampler_accept(smpl_chain, new_token);

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

                // Emit via the shared helper (also records gen_tokens for the next
                // turn's incremental prefill). Stops the loop if the UI callback
                // asked to halt. Same UTF-8 buffering/streaming semantics as the
                // inline code it replaces (see the emit_token lambda above).
                if (!emit_token(new_token)) {
                    gen_stopped = true;
                    break;
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
            } // end else (plain loop)

            // Free MTP driver + sampler if the speculative path was set up.
            if (mtp_smpl) { common_sampler_free(mtp_smpl); mtp_smpl = nullptr; }
            if (mtp_spec) { common_speculative_free(mtp_spec); mtp_spec = nullptr; }

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
            // Surface real stats to Dart so the UI's tok/s matches this log line.
            g_last_stats.n_gen       = n_gen;
            g_last_stats.t_gen_ms    = t_gen_ms;
            g_last_stats.t_prompt_ms = t_prompt_ms;
            // 文本回复无图像编码，识图时间清零避免残留上次视觉回复的值。
            g_last_stats.t_vision_ms = 0.0;
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

            // Write back the cached prompt for NEXT turn's incremental prefill:
            // this turn's (post-truncation) prompt + this turn's generated tokens.
            // The next turn's prompt = template(all history + new user msg), whose
            // common prefix with this cache stops exactly at the new user message,
            // so only that suffix needs to be prefilled.
            prev_prompt_tokens = prompt_tokens;
            prev_prompt_tokens.insert(prev_prompt_tokens.end(),
                                      gen_tokens.begin(), gen_tokens.end());
            have_prev_kv = true;
            LOGI("Cached prev prompt for incremental prefill: %zu tokens (+%zu gen)",
                 prompt_tokens.size(), gen_tokens.size());

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
        // Report the real mmap'd file size when known; fall back to the
        // (heavily over-estimated) params*4 figure only if stat() failed.
        if (model_file_size_bytes_ > 0) return model_file_size_bytes_;
        if (!model) return 0;
        return llama_model_n_params(model) * sizeof(float); // approximate
    }

    // KV-cache allocation size (bytes). llama.cpp does not expose a direct
    // "kv_cache_total_bytes" API in this vendored build, so compute it from
    // the context/model dimensions. This matches the actual pre-allocated KV
    // buffer (default f16) and is non-zero as soon as the context is created.
    int64_t get_kv_cache_bytes() const {
        if (!model || !context) return 0;
        const int n_embd    = llama_model_n_embd(model);
        const int n_head    = llama_model_n_head(model);
        const int n_head_kv = llama_model_n_head_kv(model);
        const int n_layer   = llama_model_n_layer(model);
        const uint32_t n_ctx = llama_n_ctx(context);
        if (n_head <= 0 || n_ctx == 0) return 0;

        // Head dimension. For GQA, n_head_kv < n_head; for MHA they are equal.
        const int head_dim = n_embd / n_head;
        // One layer's K (or V) buffer = n_ctx positions * n_head_kv heads * head_dim * f16.
        const int64_t kv_per_layer = (int64_t)n_ctx * n_head_kv * head_dim * sizeof(uint16_t);
        return 2LL * n_layer * kv_per_layer; // K + V
    }
};

// ============================================================================
// Global engine instance
// ============================================================================
static InferenceEngine g_engine;
static JavaVM *g_jvm = nullptr;

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
    JNIEnv *env, jobject, jstring jpath, jint n_ctx, jboolean j_enable_gpu, jint j_gpu_layers,
    jstring j_gpu_backend, jboolean j_enable_mtp, jstring j_mmproj_path,
    jstring j_draft_path
) {
    std::string path = jstring_to_std(env, jpath);
    std::string gpu_backend = j_gpu_backend ? jstring_to_std(env, j_gpu_backend) : "auto";
    std::string mmproj_path = j_mmproj_path ? jstring_to_std(env, j_mmproj_path) : "";
    std::string draft_path = j_draft_path ? jstring_to_std(env, j_draft_path) : "";

    // Mali（天玑/麒麟等 ARM GPU）驱动的 Vulkan 后端对部分 compute 特性
    // dispatch 有缺陷（社区已知：llama.cpp #16881、Gio #274、ppsspp #17426）：
    //   - bufferDeviceAddress 上报 true 但 vkGetBufferDeviceAddress 调用崩（已在 ggml-vulkan 内禁用）
    //   - integer dot product / FP16 shader 首次 submit 时驱动内部空指针崩溃
    // Mali（天玑）驱动的真实崩溃根因是 vkGetDeviceQueue2 返回坏 queue（已在
    // ggml-vulkan 内改用 vkGetDeviceQueue 修复），与 FP16/integer-dot 无关。
    // 崩溃修复后不再禁用任何特性——Mali-G68（天玑 900）的 FP16 是量化
    // matmul 的加速路径，禁用会掉到 FP32 慢路径（实测 tok/s 只有 CPU 1/3）。
    // PR #18493 的"强制 FP32"结论仅针对 Mali G720 架构，不适用于本机。
    if (gpu_backend == "vulkan") {
        // 无额外禁用：全部特性走默认路径（integer-dot/FP16/async 均开启）
        LOGI("vulkan backend: all features enabled (no Mali-safe disables)");
    }

    bool ok = g_engine.load(path.c_str(), n_ctx,
                            j_enable_gpu == JNI_TRUE, (int)j_gpu_layers,
                            gpu_backend.c_str(), j_enable_mtp == JNI_TRUE,
                            mmproj_path.c_str(), draft_path.c_str());

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
// Minimal JSON helpers for parseMessagesJson.

static void json_skip_ws(const std::string &s, size_t &i) {
    while (i < s.size()) {
        char c = s[i];
        if (c == ' ' || c == '\t' || c == '\n' || c == '\r') ++i;
        else break;
    }
}

// Parse a JSON string literal starting at s[i] == '"', decoding escapes
// (\" \\ \/ \b \f \n \r \t \uXXXX incl. surrogate pairs) into UTF-8 bytes.
// Returns false on malformed input; on success i points past the closing quote.
static bool json_parse_string(const std::string &s, size_t &i, std::string &out) {
    if (i >= s.size() || s[i] != '"') return false;
    ++i;
    out.clear();
    while (i < s.size()) {
        char c = s[i];
        if (c == '"') { ++i; return true; }
        if (c != '\\') { out += c; ++i; continue; }

        ++i;
        if (i >= s.size()) return false;
        char e = s[i++];
        switch (e) {
            case '"':  out += '"';  break;
            case '\\': out += '\\'; break;
            case '/':  out += '/';  break;
            case 'b':  out += '\b'; break;
            case 'f':  out += '\f'; break;
            case 'n':  out += '\n'; break;
            case 'r':  out += '\r'; break;
            case 't':  out += '\t'; break;
            case 'u': {
                if (i + 4 > s.size()) return false;
                unsigned int cp = 0;
                for (int k = 0; k < 4; ++k) {
                    char h = s[i + (size_t)k];
                    unsigned int v;
                    if (h >= '0' && h <= '9')      v = (unsigned int)(h - '0');
                    else if (h >= 'a' && h <= 'f') v = (unsigned int)(h - 'a' + 10);
                    else if (h >= 'A' && h <= 'F') v = (unsigned int)(h - 'A' + 10);
                    else return false;
                    cp = (cp << 4) | v;
                }
                i += 4;
                // Surrogate pair: high surrogate followed by \uDCxx-\uDFFF —
                // combine into one code point before UTF-8 encoding.
                if (cp >= 0xD800 && cp <= 0xDBFF && i + 6 <= s.size() &&
                    s[i] == '\\' && s[i + 1] == 'u') {
                    unsigned int lo = 0;
                    bool ok = true;
                    for (int k = 0; k < 4; ++k) {
                        char h = s[i + 2 + (size_t)k];
                        unsigned int v;
                        if (h >= '0' && h <= '9')      v = (unsigned int)(h - '0');
                        else if (h >= 'a' && h <= 'f') v = (unsigned int)(h - 'a' + 10);
                        else if (h >= 'A' && h <= 'F') v = (unsigned int)(h - 'A' + 10);
                        else { ok = false; break; }
                        lo = (lo << 4) | v;
                    }
                    if (ok && lo >= 0xDC00 && lo <= 0xDFFF) {
                        cp = 0x10000u + ((cp - 0xD800u) << 10) + (lo - 0xDC00u);
                        i += 6; // consume the low surrogate's \uXXXX
                    }
                }
                if (cp < 0x80) {
                    out += (char) cp;
                } else if (cp < 0x800) {
                    out += (char)(0xC0 | (cp >> 6));
                    out += (char)(0x80 | (cp & 0x3F));
                } else if (cp < 0x10000) {
                    out += (char)(0xE0 | (cp >> 12));
                    out += (char)(0x80 | ((cp >> 6) & 0x3F));
                    out += (char)(0x80 | (cp & 0x3F));
                } else {
                    out += (char)(0xF0 | (cp >> 18));
                    out += (char)(0x80 | ((cp >> 12) & 0x3F));
                    out += (char)(0x80 | ((cp >> 6) & 0x3F));
                    out += (char)(0x80 | (cp & 0x3F));
                }
                break;
            }
            default: return false;
        }
    }
    return false; // unterminated string literal
}

static std::vector<llama_chat_message> parseMessagesJson(JNIEnv *env, jstring jjson,
                                                         std::deque<std::string> &store) {
    std::vector<llama_chat_message> msgs;
    if (!jjson) return msgs;
    std::string json = jstring_to_std(env, jjson);

    // Structural parser for [{"role":"...","content":"..."}, ...]. The previous
    // find('}')-based extractor silently emptied any message whose content
    // contained '{'/'}' (pasted code/JSON), left \n and \" escapes undecoded so
    // multi-line prompts reached the model as literal "\n", and mis-detected
    // quotes preceded by a backslash. Object boundaries are now tracked
    // structurally and strings are decoded per the JSON spec. On any malformed
    // input we return whatever was parsed so far instead of guessing.
    size_t i = 0;
    json_skip_ws(json, i);
    if (i >= json.size() || json[i] != '[') return msgs;
    ++i;

    while (true) {
        json_skip_ws(json, i);
        if (i >= json.size() || json[i] == ']') break;
        if (json[i] != '{') return msgs; // unexpected token: keep what we have
        ++i;

        std::string role, content;
        bool have_role = false;

        json_skip_ws(json, i);
        if (i < json.size() && json[i] == '}') {
            ++i; // empty object
        } else {
            while (true) {
                json_skip_ws(json, i);
                std::string key;
                if (!json_parse_string(json, i, key)) return msgs;
                json_skip_ws(json, i);
                if (i >= json.size() || json[i] != ':') return msgs;
                ++i;
                json_skip_ws(json, i);
                if (i >= json.size()) return msgs;
                // role/content must be strings; the Dart producer
                // (chat_provider messagesForTemplate) never emits other types.
                if (json[i] != '"') return msgs;
                std::string value;
                if (!json_parse_string(json, i, value)) return msgs;
                if (key == "role") { role = std::move(value); have_role = true; }
                else if (key == "content") { content = std::move(value); }

                json_skip_ws(json, i);
                if (i < json.size() && json[i] == ',') { ++i; continue; }
                if (i < json.size() && json[i] == '}') { ++i; break; }
                return msgs;
            }
        }

        if (have_role) {
            // Move into the caller-owned backing store so the pointers
            // stay alive; deque never invalidates element references on
            // push_back, so these c_str() pointers are stable.
            store.push_back(std::move(role));
            store.push_back(std::move(content));
            const std::string &r = store[store.size() - 2];
            const std::string &c = store[store.size() - 1];
            msgs.push_back({ r.c_str(), c.c_str() });
        }

        json_skip_ws(json, i);
        if (i < json.size() && json[i] == ',') { ++i; continue; }
        if (i >= json.size() || json[i] == ']') break;
        return msgs;
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
    jobject jcallback,
    jstring j_image_path,    // optional on-disk image path for vision
    jstring j_audio_path     // optional on-disk audio path for speech (Gemma E2B)
) {
    const int eng_n_ctx = static_cast<int>(g_engine.n_ctx.load());
    LOGI("nativeCompletionWithMessages ENTER: is_loaded=%d n_ctx=%d image=%s audio=%s",
         g_engine.is_loaded(), eng_n_ctx, j_image_path ? "set" : "null",
         j_audio_path ? "set" : "null");
    if (!g_engine.is_loaded()) {
        LOGE("nativeCompletionWithMessages ABORT: no model loaded");
        return env->NewStringUTF("[ERROR: No model loaded]");
    }

    jobject cb_copy = env->NewLocalRef(jcallback);
    std::string prompt   = jstring_to_std(env, jprompt);
    std::string image_path = j_image_path ? jstring_to_std(env, j_image_path) : "";
    std::string audio_path = j_audio_path ? jstring_to_std(env, j_audio_path) : "";
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
            &history,   // pass history to completion() for chatml template application
            image_path.empty() ? nullptr : image_path.c_str(),  // image path (optional)
            audio_path.empty() ? nullptr : audio_path.c_str()   // audio path (optional)
        );
    } catch (const std::exception &e) {
        LOGE("nativeCompletionWithMessages caught C++ exception: %s", e.what());
        result = std::string("[ERROR: ") + e.what() + "]";
    } catch (...) {
        LOGE("nativeCompletionWithMessages caught unknown C++ exception");
        result = "[ERROR: Unknown C++ exception in completion()]";
    }

    env->DeleteLocalRef(cb_copy);

    LOGI("nativeCompletionWithMessages done, result len=%zu", result.length());
    return utf8_to_jstring(env, result);
}

// --- Audio capability (surfaced to Dart so the mic button can be gated) ---

JNIEXPORT jboolean JNICALL
Java_com_dgxspark_tongyilite_InferenceEngine_nativeSupportsAudio(JNIEnv *env, jobject) {
    return g_engine.audio_loaded ? JNI_TRUE : JNI_FALSE;
}

JNIEXPORT jint JNICALL
Java_com_dgxspark_tongyilite_InferenceEngine_nativeGetAudioSampleRate(JNIEnv *env, jobject) {
    return (jint)g_engine.audio_sample_rate;
}

// --- Last generation stats (surfaced to Dart for accurate tok/s) ---

JNIEXPORT jstring JNICALL
Java_com_dgxspark_tongyilite_InferenceEngine_nativeGetLastStats(JNIEnv *env, jobject) {
    char buf[256];
    snprintf(buf, sizeof(buf),
             "{\"n_gen\":%d,\"t_gen_ms\":%.1f,\"t_prompt_ms\":%.1f,\"t_vision_ms\":%.1f,\"t_audio_ms\":%.1f}",
             g_last_stats.n_gen, g_last_stats.t_gen_ms, g_last_stats.t_prompt_ms,
             g_last_stats.t_vision_ms, g_last_stats.t_audio_ms);
    return utf8_to_jstring(env, buf);
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

JNIEXPORT jlong JNICALL
Java_com_dgxspark_tongyilite_InferenceEngine_nativeGetKvCacheBytes(JNIEnv *, jobject) {
    return g_engine.get_kv_cache_bytes();
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
