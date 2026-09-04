/**
 * TongYi-Lite Inference Engine
 *
 * Kotlin wrapper around the C++ JNI bridge.
 * Design: direct JNI calls (NO HTTP server), validated against llama.cpp b10173.
 */

package com.dgxspark.tongyilite

import android.content.Context
import android.util.Log
import java.io.File
import java.util.concurrent.Executors
import kotlin.concurrent.thread

/**
 * Token-by-token callback interface.
 * Implemented in Dart via MethodChannel proxy.
 */
interface InferenceCallback {
    /** Called for each generated token. Return false to stop generation. */
    fun onToken(token: String): Boolean
}

/**
 * Model loading progress log callback.
 * Receives human-readable status messages from native C++ during model load.
 */
interface LoadingLogCallback {
    /** Called with a loading status message (e.g. "正在加载 GGUF 模型文件..."). */
    fun onLoadingLog(message: String)
}

/**
 * Thread-safe wrapper for native inference engine.
 */
class InferenceEngine(private val context: Context) {

    companion object {
        private const val TAG = "InferenceEngine"
        private const val DEFAULT_N_CTX = 4096

        init {
            // useLegacyPackaging=true in build.gradle.kts ensures .so files
            // are extracted to /data/app/<pkg>/lib/arm64-v8a/ on install,
            // making System.loadLibrary() work reliably.
            System.loadLibrary("tongyilite_jni")
        }
    }

    private val executor = Executors.newSingleThreadExecutor()
    @Volatile private var initialized = false

    // --- JNI native methods (implemented in tongyilite_jni.cpp) ---

    private external fun nativeInit(): Boolean
    private external fun nativeLoadModel(path: String, nCtx: Int, enableGpu: Boolean, gpuLayers: Int, gpuBackend: String, enableMtp: Boolean, mmprojPath: String?, draftPath: String?): Boolean
    private external fun nativeSetLoadingCallback(callback: LoadingLogCallback?)
    private external fun nativeUnloadModel()
    private external fun nativeIsLoaded(): Boolean
    private external fun nativeStop()
    private external fun nativeSetEnableThinking(enable: Boolean)
    private external fun nativeResetContext()
    private external fun nativeDestroy()
    private external fun nativeCompletion(
        prompt: String,
        maxTokens: Int,
        temperature: Float,
        topP: Float,
        callback: InferenceCallback
    ): String

    /**
     * Completion with chat history — applies chatml template before tokenization.
     * @param messagesJson JSON array of {role, content} pairs, e.g.
     *   '[{"role":"user","content":"hello"}]'
     */
    private external fun nativeCompletionWithMessages(
        prompt: String,
        messagesJson: String,
        maxTokens: Int,
        temperature: Float,
        topP: Float,
        callback: InferenceCallback,
        imagePath: String?,
        audioPath: String?
    ): String

    /** Whether the currently loaded mmproj ships an audio (speech) encoder. */
    private external fun nativeSupportsAudio(): Boolean

    /** Required microphone sample rate (Hz) for the loaded model; -1 if no audio. */
    private external fun nativeGetAudioSampleRate(): Int

    private external fun nativeBenchmark(
        prompt: String,
        nRepeats: Int
    ): DoubleArray  // [tok_per_sec, prompt_ms, gen_ms]

    private external fun nativeGetModelSizeBytes(): Long
    private external fun nativeGetKvCacheBytes(): Long
    private external fun nativeGetModelInfo(): String
    private external fun nativeGetLastStats(): String

    // --- Public API ---

    fun init(): Boolean {
        if (initialized) return true
        initialized = nativeInit()
        Log.i(TAG, "init: $initialized")
        return initialized
    }

    fun loadModel(
        modelPath: String,
        nCtx: Int = DEFAULT_N_CTX,
        enableGpu: Boolean = true,
        gpuLayers: Int = 20,
        gpuBackend: String = "auto",
        enableMtp: Boolean = false,
        mmprojPath: String? = null,
        draftPath: String? = null,
        loadingCallback: LoadingLogCallback? = null
    ): Boolean {
        val file = File(modelPath)
        if (!file.exists()) {
            Log.e(TAG, "Model file not found: $modelPath")
            loadingCallback?.onLoadingLog("模型文件不存在：$modelPath")
            return false
        }

        // Set the native-side callback before invoking load (static ref in C++)
        if (loadingCallback != null) {
            nativeSetLoadingCallback(loadingCallback)
        } else {
            nativeSetLoadingCallback(null)
        }

        Log.i(TAG, "loadModel: $modelPath (enableGpu=$enableGpu, gpuLayers=$gpuLayers, gpuBackend=$gpuBackend, enableMtp=$enableMtp, mmproj=$mmprojPath, draft=$draftPath)")
        val ok = nativeLoadModel(modelPath, nCtx, enableGpu, gpuLayers, gpuBackend, enableMtp, mmprojPath, draftPath)
        Log.i(TAG, "loadModel result: $ok")

        if (ok) {
            loadingCallback?.onLoadingLog("模型加载成功 ✓")
        } else {
            loadingCallback?.onLoadingLog("模型加载失败，请检查日志")
        }
        return ok
    }

    fun unloadModel() {
        executor.submit { nativeUnloadModel() }
    }

    fun isLoaded(): Boolean = nativeIsLoaded()

    fun stopGeneration() {
        nativeStop()
    }

    /** Toggle Qwen3-style "thinking" (<think> chain). false = answer directly. */
    fun setEnableThinking(enable: Boolean) {
        nativeSetEnableThinking(enable)
    }

    /** Clear the KV cache to start a brand-new conversation (multi-turn append-only). */
    fun resetContext() {
        nativeResetContext()
    }

    /**
     * Synchronous completion with token streaming.
     * Must be called from a background thread (NOT the UI thread).
     *
     * @return the full generated text
     */
    fun completion(
        prompt: String,
        maxTokens: Int = 2048,
        temperature: Float = 0.7f,
        topP: Float = 0.9f,
        onToken: ((String) -> Boolean)? = null
    ): String {
        val callback = if (onToken != null) {
            object : InferenceCallback {
                override fun onToken(token: String): Boolean = onToken.invoke(token)
            }
        } else {
            object : InferenceCallback {
                override fun onToken(token: String): Boolean = true
            }
        }
        return nativeCompletion(prompt, maxTokens, temperature, topP, callback)
    }

    /**
     * Completion with chat history — applies chatml template before tokenization.
     * @param messagesJson JSON array of {role, content} pairs for conversation history.
     *   The [prompt] is appended as the final user message before generation.
     */
    fun completionWithMessages(
        prompt: String,
        messagesJson: String,
        maxTokens: Int = 2048,
        temperature: Float = 0.7f,
        topP: Float = 0.9f,
        imagePath: String? = null,
        audioPath: String? = null,
        onToken: ((String) -> Boolean)? = null
    ): String {
        val callback = if (onToken != null) {
            object : InferenceCallback {
                override fun onToken(token: String): Boolean = onToken.invoke(token)
            }
        } else {
            object : InferenceCallback {
                override fun onToken(token: String): Boolean = true
            }
        }
        return nativeCompletionWithMessages(prompt, messagesJson, maxTokens, temperature, topP, callback, imagePath, audioPath)
    }

    /** Whether the currently loaded mmproj supports speech (audio) input. */
    fun supportsAudio(): Boolean = nativeSupportsAudio()

    /** Required microphone sample rate (Hz) for the loaded model; -1 if unsupported. */
    fun getAudioSampleRate(): Int = nativeGetAudioSampleRate()

    /**
     * Async completion — runs on executor thread, calls back on same thread.
     */
    fun completionAsync(
        prompt: String,
        maxTokens: Int = 2048,
        temperature: Float = 0.7f,
        topP: Float = 0.9f,
        onToken: ((String) -> Boolean)? = null,
        onComplete: ((String) -> Unit)? = null,
        onError: ((String) -> Unit)? = null
    ) {
        executor.submit {
            try {
                val result = completion(prompt, maxTokens, temperature, topP, onToken)
                onComplete?.invoke(result)
            } catch (e: Exception) {
                Log.e(TAG, "completionAsync error", e)
                onError?.invoke(e.message ?: "Unknown error")
            }
        }
    }

    /**
     * Run a quick benchmark. Returns [tokPerSec, avgPromptMs, avgGenMs].
     */
    fun benchmark(prompt: String = "Hello, how are you?", nRepeats: Int = 3): BenchmarkResult {
        val arr = nativeBenchmark(prompt, nRepeats)
        return BenchmarkResult(
            tokensPerSecond = arr[0],
            promptMs = arr[1],
            generationMs = arr[2]
        )
    }

    fun getModelInfo(): ModelInfo {
        val json = nativeGetModelInfo()
        // Simple JSON parse (no external dependency needed)
        val params = extractLong(json, "n_params")
        val ctx    = extractInt(json, "n_ctx")
        val embd   = extractInt(json, "n_embd")
        val layers = extractInt(json, "n_layer")
        val vocab  = extractInt(json, "n_vocab")
        return ModelInfo(
            paramsBillion = params / 1_000_000_000.0,
            contextSize = ctx,
            embeddingDim = embd,
            layers = layers,
            vocabSize = vocab,
            fileSizeBytes = nativeGetModelSizeBytes()
        )
    }

    /** Returns JSON {n_gen, t_gen_ms, t_prompt_ms} for the last completed generation. */
    fun getLastStats(): String = nativeGetLastStats()

    /** Model weights size in bytes (0 if no model loaded). Useful for UI memory display. */
    fun getModelSizeBytes(): Long = nativeGetModelSizeBytes()

    /** KV-cache allocation size in bytes (0 when no model loaded). */
    fun getKvCacheBytes(): Long = nativeGetKvCacheBytes()

    fun destroy() {
        executor.submit {
            nativeDestroy()
            initialized = false
        }
        executor.shutdown()
    }

    // --- JSON parsing helpers (minimal, no external lib) ---
    private fun extractLong(json: String, key: String): Long {
        val pattern = "\"$key\":(\\d+)".toRegex()
        return pattern.find(json)?.groupValues?.get(1)?.toLongOrNull() ?: 0L
    }
    private fun extractInt(json: String, key: String): Int {
        val pattern = "\"$key\":(\\d+)".toRegex()
        return pattern.find(json)?.groupValues?.get(1)?.toIntOrNull() ?: 0
    }
}

data class BenchmarkResult(
    val tokensPerSecond: Double,
    val promptMs: Double,
    val generationMs: Double
)

data class ModelInfo(
    val paramsBillion: Double,
    val contextSize: Int,
    val embeddingDim: Int,
    val layers: Int,
    val vocabSize: Int,
    val fileSizeBytes: Long
) {
    val fileSizeMB: Double get() = fileSizeBytes / 1_048_576.0
    val displayParams: String get() =
        if (paramsBillion >= 1.0) "%.1fB".format(paramsBillion)
        else "%.0fM".format(paramsBillion * 1000)
}
