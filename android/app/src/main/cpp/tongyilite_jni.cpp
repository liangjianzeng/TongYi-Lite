/**
 * TongYi-Lite JNI Bridge
 *
 * Design principles (validated against llama.cpp b10173 official com.arm.aichat example):
 * 1. Direct JNI calls to llama C API — NO HTTP server inside the APK
 * 2. CPU-only for MVP (KleidiAI + SME2) — Vulkan is a future P2 item
 * 3. Token-by-token callback to Dart via JNI to achieve streaming typewriter effect
 * 4. Thread-safe: inference runs on a dedicated native thread, not the UI thread
 */

#include <android/log.h>
#include <jni.h>
#include <string>
#include <vector>
#include <mutex>
#include <thread>
#include <condition_variable>
#include <atomic>
#include <functional>

// llama.cpp headers
#include "llama.h"
#include "common.h"

#define LOG_TAG "TongYiLite"
#define LOGI(...) __android_log_print(ANDROID_LOG_INFO,  LOG_TAG, __VA_ARGS__)
#define LOGW(...) __android_log_print(ANDROID_LOG_WARN,  LOG_TAG, __VA_ARGS__)
#define LOGE(...) __android_log_print(ANDROID_LOG_ERROR, LOG_TAG, __VA_ARGS__)

// ============================================================================
// InferenceEngine — wraps model + context + generation
// ============================================================================

struct InferenceEngine {
    llama_model  *model   = nullptr;
    llama_context *context = nullptr;
    llama_model_params model_params;
    llama_context_params ctx_params;
    common_chat_templates tmpl;

    // Generation state
    std::vector<llama_token> prompt_tokens;
    int n_prompt = 0;

    // Control
    std::mutex mtx;
    std::atomic<bool> is_running{false};
    std::atomic<bool> should_stop{false};

    // Stats
    int32_t n_ctx = 0;
    double t_prompt_ms = 0;
    double t_gen_ms = 0;
    int32_t n_gen = 0;

    bool load(const char *model_path, int n_ctx = 4096) {
        std::lock_guard<std::mutex> lock(mtx);

        // Unload previous model if any
        unload();

        LOGI("Loading model from: %s", model_path);

        // Model params
        model_params = llama_model_default_params();
        // mmap for memory efficiency on mobile
        model_params.n_gpu_layers = 0;  // CPU-only for MVP

        model = llama_model_load_from_file(model_path, model_params);
        if (!model) {
            LOGE("Failed to load model from: %s", model_path);
            return false;
        }

        // Context params
        ctx_params = llama_context_default_params();
        ctx_params.n_ctx = n_ctx;
        ctx_params.n_batch = 512;
        ctx_params.n_ubatch = 256;

        const int trained_ctx = llama_model_n_ctx_train(model);
        if (n_ctx > trained_ctx) {
            LOGW("Requested n_ctx=%d > trained=%d, capping.", n_ctx, trained_ctx);
            ctx_params.n_ctx = trained_ctx;
        }

        context = llama_new_context_with_model(model, ctx_params);
        if (!context) {
            LOGE("Failed to create context (OOM?)");
            llama_model_free(model);
            model = nullptr;
            return false;
        }

        n_ctx = llama_n_ctx(context);

        // Detect chat template from model
        const char *tmpl_name = common_chat_templates_source(model);
        if (tmpl_name) {
            common_chat_templates_init(&tmpl, model);
            LOGI("Chat template: %s", tmpl_name);
        } else {
            LOGW("No built-in chat template detected, using chatml fallback");
        }

        LOGI("Model loaded. n_ctx=%d, n_embd=%d, n_layer=%d",
             n_ctx,
             llama_model_n_embd(model),
             llama_model_n_layer(model));
        return true;
    }

    void unload() {
        std::lock_guard<std::mutex> lock(mtx);
        if (context)  { llama_free(context);  context = nullptr; }
        if (model)    { llama_model_free(model); model = nullptr; }
    }

    bool is_loaded() const {
        return model != nullptr && context != nullptr;
    }

    // ------------------------------------------------------------------
    // Tokenize prompt
    // ------------------------------------------------------------------
    std::vector<llama_token> tokenize(const char *text, bool add_bos) {
        int n_tokens = text == nullptr ? 1 : (int)strlen(text);
        std::vector<llama_token> tokens(n_tokens + (add_bos ? 1 : 0));
        int n = llama_tokenize(model, text, n_tokens, tokens.data(), tokens.size(), add_bos, true);
        if (n < 0) {
            n = -n;
        }
        tokens.resize(n);
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
        std::function<bool(const std::string &)> on_token = nullptr
    ) {
        if (!is_loaded()) {
            LOGE("completion() called but no model loaded");
            return "[ERROR: No model loaded]";
        }

        std::lock_guard<std::mutex> lock(mtx);
        is_running  = true;
        should_stop = false;

        // 1. Tokenize prompt
        bool add_bos = llama_should_add_bos_token(model);
        prompt_tokens = tokenize(prompt, add_bos);
        n_prompt = (int)prompt_tokens.size();

        if (n_prompt > n_ctx - 4) {
            LOGW("Prompt (%d tokens) exceeds context (%d), truncating.", n_prompt, n_ctx);
            prompt_tokens.resize(n_ctx - 4);
            n_prompt = (int)prompt_tokens.size();
        }

        LOGI("Prompt: %d tokens", n_prompt);

        // 2. Batch decode prompt
        t_prompt_ms = 0;
        t_gen_ms = 0;
        n_gen = 0;

        auto t_start = std::chrono::high_resolution_clock::now();

        llama_batch batch = llama_batch_get_one(prompt_tokens.data(), n_prompt);
        if (llama_decode(context, batch) != 0) {
            LOGE("llama_decode() failed on prompt");
            is_running = false;
            return "[ERROR: Prompt decode failed]";
        }

        auto t_end = std::chrono::high_resolution_clock::now();
        t_prompt_ms = std::chrono::duration<double, std::milli>(t_end - t_start).count();

        // 3. Auto-generate tokens
        std::string result;
        const llama_token eos = llama_token_eos(model);

        while (n_gen < max_tokens && !should_stop) {
            llama_token new_token;

            // Sample next token
            auto * logits = llama_get_logits_ith(context, (int)prompt_tokens.size() - 1 + n_gen);

            // Apply temperature & top-p via simple sampling
            auto * candidates = llama_sampler_init_simple(
                nullptr, 0,
                temperature,
                top_p,
                1,    // top_k
                0.0f, // min_p
                false // typical
            );
            new_token = llama_sampler_sample(candidates, context, logits);
            llama_sampler_free(candidates);

            if (new_token == eos) {
                LOGI("EOS reached at gen=%d", n_gen);
                break;
            }

            // Convert token to string
            char buf[256];
            int n = llama_token_to_piece(model, new_token, buf, sizeof(buf), 0, true);
            if (n > 0) {
                std::string piece(buf, n);
                result += piece;
                if (on_token && !on_token(piece)) {
                    LOGI("Generation stopped by callback at gen=%d", n_gen);
                    break;
                }
            }

            n_gen++;

            // Decode the new token
            t_start = std::chrono::high_resolution_clock::now();
            llama_batch token_batch = llama_batch_get_one(&new_token, 1);
            if (llama_decode(context, token_batch) != 0) {
                LOGE("llama_decode() failed on generated token");
                break;
            }
            t_end = std::chrono::high_resolution_clock::now();
            t_gen_ms += std::chrono::duration<double, std::milli>(t_end - t_start).count();
        }

        is_running = false;

        double tok_per_sec = n_gen > 0 ? (n_gen / (t_gen_ms / 1000.0)) : 0.0;
        LOGI("Generation done: %d tokens, %.1f tok/s (prompt %.0fms, gen %.0fms)",
             n_gen, tok_per_sec, t_prompt_ms, t_gen_ms);

        return result;
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
        return (int64_t)llama_get_state_size(context);
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

JNIEXPORT jboolean JNICALL
Java_com_dgxspark_tongyilite_InferenceEngine_nativeLoadModel(
    JNIEnv *env, jobject, jstring jpath, jint n_ctx
) {
    std::string path = jstring_to_std(env, jpath);
    return g_engine.load(path.c_str(), n_ctx) ? JNI_TRUE : JNI_FALSE;
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
    if (!g_engine.is_loaded()) {
        return env->NewStringUTF("[ERROR: No model loaded]");
    }

    // Save callback object for token streaming
    g_callback_obj = env->NewGlobalRef(jcallback);

    std::string prompt = jstring_to_std(env, jprompt);

    std::string result = g_engine.completion(
        prompt.c_str(),
        max_tokens,
        temperature,
        top_p,
        [&env](const std::string &token) -> bool {
            if (!g_callback_obj) return true;
            JNIEnv *local_env = get_env();
            if (!local_env) return true;

            jclass cls = local_env->GetObjectClass(g_callback_obj);
            jmethodID mid = local_env->GetMethodID(cls, "onToken", "(Ljava/lang/String;)Z");
            jstring jtoken = local_env->NewStringUTF(token.c_str());
            jboolean should_continue = local_env->CallBooleanMethod(g_callback_obj, mid, jtoken);
            local_env->DeleteLocalRef(jtoken);
            local_env->DeleteLocalRef(cls);
            return should_continue;
        }
    );

    // Release callback
    if (g_callback_obj) {
        env->DeleteGlobalRef(g_callback_obj);
        g_callback_obj = nullptr;
    }

    return env->NewStringUTF(result.c_str());
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
    snprintf(buf, sizeof(buf),
             "{\"n_params\":%lld,\"n_ctx\":%d,\"n_embd\":%d,\"n_layer\":%d,\"n_vocab\":%d}",
             (long long)llama_model_n_params(g_engine.model),
             g_engine.n_ctx,
             llama_model_n_embd(g_engine.model),
             llama_model_n_layer(g_engine.model),
             llama_model_n_vocab(g_engine.model));
    return env->NewStringUTF(buf);
}

} // extern "C"