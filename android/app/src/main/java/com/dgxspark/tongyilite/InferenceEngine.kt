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

    /**
     * 引擎销毁门闩（2026-09-30 审查 P0）：destroy 置位后，所有会触碰 native
     * 的入口快速失败——此前「裸线程跑 completion vs onDestroy 里 nativeDestroy」
     * 无互斥，推理中退出应用可 SIGSEGV。
     */
    @Volatile private var destroyed = false

    private fun checkNotDestroyed() {
        if (destroyed) throw IllegalStateException("engine destroyed")
    }

    /**
     * 引擎单线程调度器访问：把长任务（load/unload/completion）统一入队到
     * 与 destroy 同一个 executor，天然串行化，杜绝并发操作 g_engine。
     */
    fun <T> onEngineThread(block: () -> T): java.util.concurrent.Future<T> =
        executor.submit(block)

    // --- JNI native methods (implemented in tongyilite_jni.cpp) ---

    private external fun nativeInit(): Boolean
    private external fun nativeLoadModel(path: String, nCtx: Int, enableGpu: Boolean, gpuLayers: Int, gpuBackend: String, enableMtp: Boolean, mmprojPath: String?, draftPath: String?, nUbatch: Int, vkNoSubgroup: Boolean, moeManifest: String?, moeBank: Int, moeSlotBytes: Long, moeExpertsBytes: Long, moeResidentBytes: Long): Boolean
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
    private external fun nativeGetLastLoadingMessage(): String

    /** Push OOM-guard settings from the UI (设置→推理引擎→内存守卫) into native env. */
    private external fun nativeSetOomGuardParams(enabled: Boolean, preHeadroomMb: Int, postHeadroomMb: Int)
    private external fun nativeSetKvCacheType(type: String)
    private external fun nativeSetFlashAttn(enabled: Boolean)

    // --- [NPU·M2 Phase C] 混合调度（NPU prefill + GPU decode，hyb_jni.cpp）---
    // 返回结构化 JSON：{ok, code, stage, message, ...}；code ∈ HYB_*。
    // Dart 侧（lib/agent/llm/hybrid_bridge.dart）按 ok/code 自动回退纯 GPU。
    private external fun nativeStartHybridPrefill(
        kvDir: String,
        idsPath: String,
        chainDir: String,
        chainBin: String,
        qnnLibDir: String,
        manifestsCsv: String,
        nChunks: Int,
        prompt: String?,
        messagesJson: String,
        nRealCap: Int,
        timeoutMs: Int
    ): String

    private external fun nativeBridgeAndResumeDecode(
        kvDir: String,
        idsPath: String,
        outPath: String,
        nReal: Int,
        posBase: Long,
        firstTok: Int,
        maxTokens: Int,
        temperature: Float,
        topP: Float,
        callback: InferenceCallback?
    ): String

    // --- Public API ---

    fun init(): Boolean {
        checkNotDestroyed()
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
        nUbatch: Int = 0,
        vkNoSubgroup: Boolean = false,
        moeManifest: String? = null,
        moeBank: Int = 0,
        moeSlotBytes: Long = 0,
        moeExpertsBytes: Long = 0,
        moeResidentBytes: Long = 0,
        loadingCallback: LoadingLogCallback? = null
    ): Boolean {
        checkNotDestroyed()
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

        Log.i(TAG, "loadModel: $modelPath (enableGpu=$enableGpu, gpuLayers=$gpuLayers, gpuBackend=$gpuBackend, enableMtp=$enableMtp, mmproj=$mmprojPath, draft=$draftPath, moe=$moeManifest/$moeBank/$moeSlotBytes/$moeExpertsBytes)")
        val ok = nativeLoadModel(modelPath, nCtx, enableGpu, gpuLayers, gpuBackend, enableMtp, mmprojPath, draftPath, nUbatch, vkNoSubgroup, moeManifest, moeBank, moeSlotBytes, moeExpertsBytes, moeResidentBytes)
        Log.i(TAG, "loadModel result: $ok")

        if (ok) {
            loadingCallback?.onLoadingLog("模型加载成功 ✓")
        } else {
            // Surface the native-side refusal reason (oom-guard numbers, file
            // errors...) instead of a bare "check the logs" line.
            val reason = try { nativeGetLastLoadingMessage() } catch (_: Throwable) { "" }
            loadingCallback?.onLoadingLog(
                if (reason.isNotBlank()) "模型加载失败：$reason" else "模型加载失败，请检查日志"
            )
        }
        return ok
    }

    /**
     * 卸载模型并**等待完成**（带超时）。此前 fire-and-forget 立即返回，
     * Dart 侧以为卸载完成随即 load，native 侧 unload/load 竞态操作 g_engine
     * （2026-09-30 审查 P1）。返回 false = 超时/失败，调用方应报错而非继续。
     */
    fun unloadModel(timeoutSec: Long = 20): Boolean {
        checkNotDestroyed()
        val future = executor.submit { nativeUnloadModel() }
        return try {
            future.get(timeoutSec, java.util.concurrent.TimeUnit.SECONDS)
            true
        } catch (e: Exception) {
            Log.e(TAG, "unloadModel failed/timeout", e)
            false
        }
    }

    fun isLoaded(): Boolean = nativeIsLoaded()

    fun stopGeneration() {
        nativeStop()
    }

    /** Toggle Qwen3-style "thinking" (<think> chain). false = answer directly. */
    fun setEnableThinking(enable: Boolean) {
        nativeSetEnableThinking(enable)
    }

    /**
     * Configure the OOM guard (设置→推理引擎→内存守卫). Called before every
     * model load; native reads these at load time via getenv.
     * @param enabled false = 完全跳过守卫拒绝（风险：整台机器硬死机重启）
     * @param preHeadroomMb  预检余量（加载前判定，默认 768）
     * @param postHeadroomMb 加载后余量（KV/图计算预算，默认 1536）
     */
    fun setOomGuardParams(enabled: Boolean, preHeadroomMb: Int, postHeadroomMb: Int) {
        nativeSetOomGuardParams(enabled, preHeadroomMb, postHeadroomMb)
    }

    /**
     * KV cache 精度（设置→推理引擎→KV 精度）。每次 loadModel 前调用，重载模型后生效。
     * 仅量化 K（"q4_0"/"q8_0"）；V 恒为 F16 —— V 量化要求开启 flash attention，
     * 本 app 保持关闭。不兼容的架构（MLA）原生层会自动回退 F16。
     */
    fun setKvCacheType(type: String) {
        nativeSetKvCacheType(type)
    }

    /**
     * [dspark 2026-10-14] P1: flash attention 开关（设置→推理引擎）。每次 loadModel
     * 前调用，重载模型后生效。开启后 V 跟随 K 的量化格式（OpenCL FA 内核要求 K/V
     * 同格式）；hybrid（recurrent 层）架构原生层会强制关闭并在日志说明。
     */
    fun setFlashAttn(enabled: Boolean) {
        nativeSetFlashAttn(enabled)
    }

    /** Clear the KV cache to start a brand-new conversation (multi-turn append-only). */
    fun resetContext() {
        nativeResetContext()
    }

    // ------------------------------------------------------------------
    // [NPU·M2 Phase C] Hybrid path (NPU prefill + KV bridge + GPU decode).
    // 与 completion 同一引擎线程队列调度（MainActivity 里 engine.onEngineThread），
    // 天然不与 GPU 生成交错；任何一步失败 Dart 侧自动回退纯 GPU 现路径。
    // ------------------------------------------------------------------

    /**
     * 拉起 NPU prefill helper（chain_run5/QNN）收 84 片 KV。
     *
     * 冻结设备侧语义 = npu-line/probe_m1/dec2/mcp5_95_run_a3b_seq.py：
     * 三段 manifest 串行拉起（env LD_LIBRARY_PATH/ADSP_LIBRARY_PATH、
     * CHAIN_KEEP=1 CR5_ROLL_SAVE=1、逐段等 CR5_DONE、进程消失即收
     * p{k}.log 尾巴进回包）。
     *
     * 路径缺省（[P0-3 review fix] W^X 布局）：chainDir = filesDir/npu_m1
     * （manifest/产物工作区，NpuAssets.extract），chainBin =
     * nativeLibraryDir/libchain_run5_exec.so、qnnLibDir = nativeLibraryDir
     * （jniLibs + useLegacyPackaging 安装期解出的真文件，system_file 标签，
     * App uid 可 execve/dlopen；app_data_file 不可 exec，见 build.gradle.kts
     * 的 W^X 红线注）。chainDir/lib 由 NpuAssets.extract 建为指向
     * nativeLibraryDir 的符号链接，chain_run5 的 dlopen("./lib/libQnnHtp.so")
     * 按 cwd=chainDir 相对解析即落真身。
     * 回包 {ok, code, stage, message, n_real, ids_path, first_tok, ...}；
     * n_real = native tokenize 的真实 token 数（无-pad 协议）。
     */
    fun startHybridPrefill(
        kvDir: String,
        idsPath: String,
        chainDir: String? = null,
        chainBin: String? = null,
        qnnLibDir: String? = null,
        manifestsCsv: String? = null,
        nChunks: Int = 4,
        prompt: String? = null,
        messagesJson: String = "[]",
        nRealCap: Int = 512,
        timeoutMs: Int = 120000
    ): String {
        checkNotDestroyed()
        val cd = chainDir ?: NpuAssets.chainDir(context).absolutePath
        // [P0-3] 可执行体只认 nativeLibraryDir（system_file 可 exec/dlopen）
        val nlib = context.applicationInfo.nativeLibraryDir
        return nativeStartHybridPrefill(
            kvDir, idsPath, cd,
            chainBin ?: "$nlib/libchain_run5_exec.so",
            qnnLibDir ?: nlib,
            manifestsCsv ?: "", nChunks, prompt, messagesJson,
            nRealCap, timeoutMs
        )
    }

    /**
     * native 桥转（hyb_kv_bridge.c，官方 state 容器，冻结配方，v4 容器 =
     * lc fork loader）→ llama_state_seq_load_file → GPU 续 decode。
     * [firstTok] <0 时 native 先「重算末 prompt token 一步」取 argmax 作
     * 首 token（计划 §1.3 兜底路线）。回包
     * {ok, code, stage, n_gen, first_tok, load_ms, state_path, stopped, text}；
     * 整段文本一次带回（token 级流式 [onToken] 回调已备好，接线留 C-3）。
     */
    fun bridgeAndResumeDecode(
        kvDir: String,
        idsPath: String,
        outPath: String,
        nReal: Int,
        posBase: Long,
        firstTok: Int,
        maxTokens: Int = 512,
        temperature: Float = 0.7f,
        topP: Float = 0.9f,
        onToken: ((String) -> Boolean)? = null
    ): String {
        checkNotDestroyed()
        val callback = if (onToken != null) {
            object : InferenceCallback {
                override fun onToken(token: String): Boolean = onToken.invoke(token)
            }
        } else {
            object : InferenceCallback {
                override fun onToken(token: String): Boolean = true
            }
        }
        return nativeBridgeAndResumeDecode(
            kvDir, idsPath, outPath, nReal, posBase, firstTok,
            maxTokens, temperature, topP, callback
        )
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
        checkNotDestroyed()
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
        checkNotDestroyed()
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
        if (destroyed) return
        destroyed = true
        // 先置 native 停止标记，尽快结束正在跑的生成，再入队销毁。
        try { stopGeneration() } catch (e: Exception) {
            Log.w(TAG, "destroy: stopGeneration failed", e)
        }
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
