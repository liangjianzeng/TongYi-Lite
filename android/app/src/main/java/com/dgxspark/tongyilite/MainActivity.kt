/**
 * MainActivity — Flutter entry point with MethodChannel bridge.
 *
 * The MethodChannel connects Dart UI → Kotlin → JNI → C++ llama.cpp.
 * This is the ONLY communication channel (no HTTP server).
 */

package com.dgxspark.tongyilite

import android.app.ActivityManager
import android.content.ContentValues
import android.content.Intent
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.provider.MediaStore
import android.util.Log
import android.webkit.MimeTypeMap
import androidx.annotation.NonNull
import androidx.core.content.FileProvider
import com.chaquo.python.Python
import com.chaquo.python.android.AndroidPlatform
import com.dgxspark.tongyilite.service.InferenceService
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.concurrent.Executors
import java.util.concurrent.TimeUnit
import java.util.concurrent.TimeoutException
import org.json.JSONObject


class MainActivity : FlutterActivity() {

    companion object {
        const val TAG = "TongYiLite"
    }

    private lateinit var engine: InferenceEngine
    private val mainHandler = Handler(Looper.getMainLooper())
    private var audioRecorder: AudioRecorder? = null

    // ---- Debug logging helpers (always visible in Release logcat) ----
    private fun logI(method: String, message: String) { Log.i(TAG, "[$method] $message") }
    private fun logW(method: String, message: String, t: Throwable? = null) { Log.w(TAG, "[$method] $message", t) }
    private fun logE(method: String, message: String, t: Throwable? = null) { Log.e(TAG, "[$method] $message", t) }

    override fun configureFlutterEngine(@NonNull flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        engine = InferenceEngine(applicationContext)

        // Start foreground service to keep inference alive in background
        try {
            InferenceService.start(this)
        } catch (e: Exception) {
            Log.w("MainActivity", "Could not start foreground service", e)
        }

        // Set up the token EventChannel for streaming
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.dgxspark.tongyilite/tokens"
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                TokenStream.sink = events
            }
            override fun onCancel(arguments: Any?) {
                TokenStream.sink = null
            }
        })

        // Set up the loading log EventChannel for model load progress messages
        EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.dgxspark.tongyilite/loading_logs"
        ).setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
                LoadingLogStream.sink = events
            }
            override fun onCancel(arguments: Any?) {
                LoadingLogStream.sink = null
            }
        })

        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.dgxspark.tongyilite/inference"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "init"          -> { engine.init(); result.success(true) }
                "loadModel"     -> handleLoadModel(call, result)
                "unloadModel"   -> handleUnloadModel(result)
                "isLoaded"      -> handleIsLoaded(result)
                "completion"              -> handleCompletion(call, result)
                "completionWithMessages"  -> handleCompletionWithMessages(call, result)
                "startRecording"          -> handleStartRecording(result)
                "stopRecording"           -> handleStopRecording(result)
                "supportsAudio"           -> handleSupportsAudio(result)
                "stopGeneration"          -> handleStop(result)
                "setEnableThinking"       -> handleSetEnableThinking(call, result)
                "setOomGuard"             -> handleSetOomGuard(call, result)
                "resetContext"            -> handleResetContext(result)
                "benchmark"     -> handleBenchmark(call, result)
                "getModelInfo"  -> handleGetModelInfo(result)
                "getMemoryInfo" -> handleGetMemoryInfo(result)
                "getInferenceStats" -> handleGetInferenceStats(result)
                "getDeviceInfo" -> handleGetDeviceInfo(result)
                else            -> result.notImplemented()
            }
        }

        // python_exec：Chaquopy 脚本执行桥（独立通道，与推理解耦）。
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.dgxspark.tongyilite/python"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "isAvailable" -> handlePythonAvailable(result)
                "runScript"   -> handleRunPythonScript(call, result)
                else         -> result.notImplemented()
            }
        }

        // 文件产物桥（WP6）：智能体报告/文档导出到公共下载目录 + 系统查看器打开。
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.dgxspark.tongyilite/files"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "exportFile" -> handleExportFile(call, result)
                "openFile"   -> handleOpenFile(call, result)
                else         -> result.notImplemented()
            }
        }
    }

    // ------------------------------------------------------------------
    // 文件产物桥（WP6）
    // ------------------------------------------------------------------

    /** 按扩展名推断 MIME（MimeTypeMap 缺 md/csv/svg 等时人工兜底）。 */
    private fun mimeFor(name: String): String {
        val ext = name.substringAfterLast('.', "").lowercase()
        return MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext)
            ?: when (ext) {
                "md" -> "text/markdown"
                "csv" -> "text/csv"
                "html", "htm" -> "text/html"
                "json" -> "application/json"
                "svg" -> "image/svg+xml"
                "log" -> "text/plain"
                else -> "application/octet-stream"
            }
    }

    /**
     * exportFile：把工作区文件复制到公共下载目录 `Download/TongYi-Lite/`。
     * targetSdk 33+ 必须走 MediaStore（直接 java.io 写公共目录会被拒绝）。
     * 返回 content:// URI 字符串（openFile 可直接用它打开）。
     */
    private fun handleExportFile(call: MethodCall, result: MethodChannel.Result) {
        val src = call.argument<String>("src")?.trim().orEmpty()
        val name = call.argument<String>("name")?.trim().orEmpty()
            .ifEmpty { File(src).name }
        if (src.isEmpty() || !File(src).isFile) {
            result.error("NOT_FOUND", "源文件不存在：$src", null)
            return
        }
        Thread {
            try {
                val values = ContentValues().apply {
                    put(MediaStore.Downloads.DISPLAY_NAME, name)
                    put(MediaStore.Downloads.MIME_TYPE, mimeFor(name))
                    put(MediaStore.Downloads.RELATIVE_PATH, "Download/TongYi-Lite")
                }
                val uri = contentResolver.insert(
                    MediaStore.Downloads.EXTERNAL_CONTENT_URI, values
                )
                if (uri == null) {
                    runOnMain { result.error("EXPORT_FAILED", "MediaStore 写入被拒绝", null) }
                    return@Thread
                }
                contentResolver.openOutputStream(uri)!!.use { out ->
                    File(src).inputStream().use { it.copyTo(out) }
                }
                logI("handleExportFile", "exported $name -> $uri")
                runOnMain { result.success(uri.toString()) }
            } catch (e: Exception) {
                logE("handleExportFile", "export failed: ${e.message}", e)
                runOnMain { result.error("EXPORT_FAILED", "导出失败：${e.message}", null) }
            }
        }.start()
    }

    /**
     * openFile：用系统查看器打开产物。接受 content:// URI（exportFile 返回值）
     * 或绝对文件路径（走 FileProvider，限应用目录内）。带图查看 html/png/pdf 等。
     */
    private fun handleOpenFile(call: MethodCall, result: MethodChannel.Result) {
        val target = call.argument<String>("path")?.trim().orEmpty()
        if (target.isEmpty()) {
            result.error("NO_PATH", "缺少 path 参数", null)
            return
        }
        try {
            val uri: Uri
            val mime: String
            if (target.startsWith("content:")) {
                uri = Uri.parse(target)
                mime = contentResolver.getType(uri) ?: "*/*"
            } else {
                val f = File(target)
                if (!f.isFile) {
                    result.error("NOT_FOUND", "文件不存在：$target", null)
                    return
                }
                uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", f)
                mime = mimeFor(f.name)
            }
            val intent = Intent(Intent.ACTION_VIEW)
                .setDataAndType(uri, mime)
                .addFlags(
                    Intent.FLAG_GRANT_READ_URI_PERMISSION
                        or Intent.FLAG_ACTIVITY_NEW_TASK
                )
            startActivity(intent)
            result.success(true)
        } catch (e: Exception) {
            logE("handleOpenFile", "open failed: ${e.message}", e)
            result.error("OPEN_FAILED", "无法打开（未安装可查看该格式的应用？）：${e.message}", null)
        }
    }

    // ------------------------------------------------------------------
    // MethodChannel handlers
    // ------------------------------------------------------------------

    // python_exec：单线程池执行脚本（串行防 GIL 争用），超时由 Future.get 兜底。
    private val pythonExecutor = Executors.newSingleThreadExecutor()

    /**
     * 确保 Chaquopy 已显式启动：文档要求 Android 上必须
     * `Python.start(AndroidPlatform(context))`，仅靠 getInstance() 的
     * GenericPlatform 无法加载 Android 运行时（assets/abi 路径）。
     * start 只能调用一次；context 为 Activity/Service/Application。
     */
    private fun ensurePythonStarted(context: android.content.Context): String? {
        try {
            if (!Python.isStarted()) {
                Python.start(AndroidPlatform(context))
            }
            return null // 无错误
        } catch (e: Exception) {
            logW("ensurePythonStarted", "start failed: ${e.message}", e)
            return "启动失败：${e.message}"
        }
    }

    private fun handlePythonAvailable(result: MethodChannel.Result) {
        // 返回 String："ok" = 可用；其他为具体错误（透传给 Dart 便于排查）。
        Thread {
            val probe = try {
                val startErr = ensurePythonStarted(this)
                if (startErr != null) {
                    startErr
                } else {
                    val py = Python.getInstance()
                    if (py.getModule("agent_runner") != null) "ok" else "模块 agent_runner 加载失败"
                }
            } catch (e: Exception) {
                logW("handlePythonAvailable", "python unavailable: ${e.message}", e)
                "初始化异常：${e.message}"
            }
            runOnMain { result.success(probe) }
        }.start()
    }

    private fun handleRunPythonScript(call: MethodCall, result: MethodChannel.Result) {
        val script = call.argument<String>("script")?.trim().orEmpty()
        if (script.isEmpty()) {
            result.error("NO_SCRIPT", "缺少 script 参数", null)
            return
        }
        val timeoutSec = call.argument<Number>("timeoutSec")?.toLong() ?: 15L
        // stdin：一次性批次输入（对齐 DSH）。提供时交给 agent_runner 接成 sys.stdin，
        // 脚本内 input() 可读到；不提供则 input() 收到 EOF。
        val stdinInput = call.argument<String>("stdin")
        logI("handleRunPythonScript", "script=${script.take(64)}..., timeout=${timeoutSec}s, stdin=${stdinInput?.length ?: 0}")

        // 脚本执行在线程池（不阻塞 UI）；先显式 start（幂等），再加载模块。
        val future = pythonExecutor.submit<Map<String, Any?>> {
            val startErr = ensurePythonStarted(this)
            if (startErr != null) {
                return@submit mapOf("ok" to false, "stdout" to "", "stderr" to "", "error" to startErr)
            }
            val py = Python.getInstance()
            val module = py.getModule("agent_runner")
            val raw = module.callAttr("run_script", script, stdinInput).toString()
            val json = JSONObject(raw)
            mapOf(
                "ok" to json.optBoolean("ok", false),
                "stdout" to json.optString("stdout"),
                "stderr" to json.optString("stderr"),
                "error" to json.optString("error", ""),
            )
        }
        // 独立等待线程：future.get 带超时（不阻塞主线程），结果回主线程。
        Thread {
            try {
                val output = future.get(timeoutSec, TimeUnit.SECONDS)
                val ok = output["ok"] as Boolean
                val stdout = output["stdout"] as String
                val stderr = output["stderr"] as String
                val error = output["error"] as String
                val content = if (ok) {
                    val sb = StringBuilder(stdout)
                    if (stderr.isNotEmpty()) {
                        if (sb.isNotEmpty() && !sb.toString().endsWith("\n")) sb.append("\n")
                        sb.append("[stderr] ").append(stderr)
                    }
                    sb.toString().trim()
                } else {
                    error.ifEmpty { "脚本执行失败" }
                }
                runOnMain {
                    if (ok) {
                        result.success(content)
                    } else {
                        result.error("SCRIPT_ERROR", content, null)
                    }
                }
            } catch (te: TimeoutException) {
                // 超时：Dart 侧立即拿到错误；线程池任务继续运行直至自行结束。
                runOnMain { result.error("SCRIPT_TIMEOUT", "脚本执行超时（${timeoutSec}s）", null) }
            } catch (e: Exception) {
                logW("handleRunPythonScript", "python error: ${e.message}", e)
                runOnMain { result.error("PYTHON_ERROR", "Python 执行失败：${e.message}", null) }
            }
        }.start()
    }

    /** 在主线程执行回调（MethodChannel.Result 需 @UiThread）。 */
    private fun runOnMain(block: () -> Unit) {
        mainHandler.post { block() }
    }

    private fun handleLoadModel(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")!!
        val nCtx = call.argument<Int>("nCtx") ?: 4096
        val enableGpu = call.argument<Boolean>("enableGpu") ?: true
        val gpuLayers = call.argument<Int>("gpuLayers") ?: 20
        val gpuBackend = call.argument<String>("gpuBackend") ?: "auto"
        val enableMtp = call.argument<Boolean>("enableMtp") ?: false
        val mmprojPath = call.argument<String>("mmprojPath")
        val draftPath = call.argument<String>("draftPath")

        logI("handleLoadModel", "path=$path, nCtx=$nCtx, enableGpu=$enableGpu, gpuLayers=$gpuLayers, gpuBackend=$gpuBackend, enableMtp=$enableMtp, mmproj=$mmprojPath, draft=$draftPath")

        Thread {
            try {
                val ok = engine.loadModel(path, nCtx, enableGpu, gpuLayers, gpuBackend, enableMtp, mmprojPath, draftPath, object : LoadingLogCallback {
                    override fun onLoadingLog(message: String) {
                        logI("onLoadingLog", message)
                        mainHandler.post {
                            LoadingLogStream.sink?.success(message)
                        }
                    }
                })
                logI("handleLoadModel", "loadModel result: $ok")
                // Clear loading logs on completion (whether success or failure)
                mainHandler.post {
                    LoadingLogStream.sink?.success(null) // null signals end of batch
                    try {
                        result.success(ok)
                    } catch (e: Exception) {
                        logE("handleLoadModel", "result.success failed", e)
                    }
                }
            } catch (e: Exception) {
                logW("handleLoadModel", "loadModel error: ${e.message}", e)
                mainHandler.post {
                    LoadingLogStream.sink?.success("加载异常: ${e.message}")
                    LoadingLogStream.sink?.success(null)
                    try {
                        result.error("LOAD_FAILED", e.message, null)
                    } catch (e2: Exception) {
                        logE("handleLoadModel", "result.error failed", e2)
                    }
                }
            }
        }.start()
    }

    private fun handleUnloadModel(result: MethodChannel.Result) {
        logI("handleUnloadModel", "")
        engine.unloadModel()
        mainHandler.post {
            try {
                result.success(true)
            } catch (e: Exception) {
                logE("handleUnloadModel", "result.success failed", e)
            }
        }
    }

    private fun handleIsLoaded(result: MethodChannel.Result) {
        mainHandler.post {
            try {
                result.success(engine.isLoaded())
            } catch (e: Exception) {
                logE("handleIsLoaded", "result.success failed", e)
            }
        }
    }

    /**
     * Streaming completion: tokens are sent back to Dart via `tokens` event channel.
     */
    private fun handleCompletion(call: MethodCall, result: MethodChannel.Result) {
        val prompt      = call.argument<String>("prompt")!!
        val maxTokens   = call.argument<Int>("maxTokens") ?: 2048
        val temperature = call.argument<Double>("temperature")?.toFloat() ?: 0.7f
        val topP        = call.argument<Double>("topP")?.toFloat() ?: 0.9f

        logI("handleCompletion", "prompt=${prompt.take(50)}..., maxTokens=$maxTokens, temp=$temperature, topP=$topP")

        // Get the event sink for streaming tokens
        val sink = TokenStream.sink

        // Update foreground notification — must be on main thread (may trigger @UiThread code)
        updateServiceStatus("AI 思考中...")

        Thread {
            try {
                logI("handleCompletion", "calling engine.completion() from background thread")
                val fullText = engine.completion(
                    prompt = prompt,
                    maxTokens = maxTokens,
                    temperature = temperature,
                    topP = topP,
                    onToken = { token ->
                        // EventChannel.EventSink must be called from the main thread.
                        mainHandler.post { sink?.success(token) }
                        true
                    }
                )
                logI("handleCompletion", "completion done, fullText length=${fullText.length}")
                updateServiceStatus("就绪")
                // result.success MUST be on main thread (MethodChannel.Result is @UiThread guarded)
                mainHandler.post {
                    try {
                        result.success(fullText)
                    } catch (e: Exception) {
                        logE("handleCompletion", "result.success failed", e)
                    }
                }
            } catch (e: Exception) {
                logW("handleCompletion", "completion error: ${e.message}", e)
                updateServiceStatus("推理出错")
                // result.error MUST be on main thread
                mainHandler.post {
                    try {
                        result.error("COMPLETION_ERROR", e.message ?: "Unknown error", null)
                    } catch (e2: Exception) {
                        logE("handleCompletion", "result.error failed", e2)
                    }
                }
            }
        }.start()
    }

    private fun handleCompletionWithMessages(call: MethodCall, result: MethodChannel.Result) {
        val prompt       = call.argument<String>("prompt")!!
        val messagesJson = call.argument<String>("messagesJson") ?: "[]"
        val maxTokens    = call.argument<Int>("maxTokens") ?: 2048
        val temperature  = call.argument<Double>("temperature")?.toFloat() ?: 0.7f
        val topP         = call.argument<Double>("topP")?.toFloat() ?: 0.9f
        val imagePath    = call.argument<String>("imagePath")
        val audioPath    = call.argument<String>("audioPath")

        logI("handleCompletionWithMessages", "prompt=${prompt.take(50)}, msgsJsonLen=${messagesJson.length}, image=${imagePath ?: "none"}, audio=${audioPath ?: "none"}")

        val sink = TokenStream.sink
        updateServiceStatus("AI 思考中...")

        Thread {
            try {
                logI("handleCompletionWithMessages", "calling engine.completionWithMessages()")
                val fullText = engine.completionWithMessages(
                    prompt = prompt,
                    messagesJson = messagesJson,
                    maxTokens = maxTokens,
                    temperature = temperature,
                    topP = topP,
                    imagePath = imagePath,
                    audioPath = audioPath,
                    onToken = { token ->
                        mainHandler.post { sink?.success(token) }
                        true
                    }
                )
                logI("handleCompletionWithMessages", "done, len=${fullText.length}")
                updateServiceStatus("就绪")
                mainHandler.post { result.success(fullText) }
            } catch (e: Exception) {
                logW("handleCompletionWithMessages", "error: ${e.message}", e)
                updateServiceStatus("推理出错")
                mainHandler.post { result.error("COMPLETION_ERROR", e.message, null) }
            }
        }.start()
    }

    /**
     * Start microphone capture for on-device speech input. The sample rate is
     * taken from the loaded model's audio encoder; refuses if the current model
     * has no audio support.
     */
    private fun handleStartRecording(result: MethodChannel.Result) {
        logI("handleStartRecording", "")
        Thread {
            try {
                if (!engine.supportsAudio()) {
                    mainHandler.post { result.error("NO_AUDIO", "当前模型不支持语音理解", null) }
                    return@Thread
                }
                val sr = engine.getAudioSampleRate().takeIf { it > 0 } ?: 16000
                val rec = AudioRecorder(applicationContext, sr)
                val ok = rec.start()
                if (ok) {
                    audioRecorder = rec
                    mainHandler.post { result.success(true) }
                } else {
                    mainHandler.post { result.error("RECORD_FAILED", "麦克风启动失败", null) }
                }
            } catch (e: Exception) {
                logW("handleStartRecording", "error: ${e.message}", e)
                mainHandler.post { result.error("RECORD_ERROR", e.message, null) }
            }
        }.start()
    }

    /** Stop recording and return the WAV file path (null when discarded). */
    private fun handleStopRecording(result: MethodChannel.Result) {
        logI("handleStopRecording", "")
        Thread {
            try {
                val path = audioRecorder?.stop()
                audioRecorder = null
                logI("handleStopRecording", "path=$path")
                mainHandler.post { result.success(path) }
            } catch (e: Exception) {
                logW("handleStopRecording", "error: ${e.message}", e)
                mainHandler.post { result.error("STOP_ERROR", e.message, null) }
            }
        }.start()
    }

    private fun handleSupportsAudio(result: MethodChannel.Result) {
        mainHandler.post {
            try {
                result.success(engine.supportsAudio())
            } catch (e: Exception) {
                logE("handleSupportsAudio", "error: ${e.message}", e)
            }
        }
    }

    private fun handleStop(result: MethodChannel.Result) {
        logI("handleStop", "")
        engine.stopGeneration()
        mainHandler.post {
            try {
                result.success(true)
            } catch (e: Exception) {
                logE("handleStop", "result.success failed", e)
            }
        }
    }

    private fun handleResetContext(result: MethodChannel.Result) {
        logI("handleResetContext", "")
        engine.resetContext()
        mainHandler.post {
            try {
                result.success(true)
            } catch (e: Exception) {
                logE("handleResetContext", "result.success failed", e)
            }
        }
    }

    private fun handleSetEnableThinking(call: MethodCall, result: MethodChannel.Result) {
        val enable = call.argument<Boolean>("enable") ?: false
        logI("handleSetEnableThinking", "enable=$enable")
        engine.setEnableThinking(enable)
        mainHandler.post {
            try {
                result.success(true)
            } catch (e: Exception) {
                logE("handleSetEnableThinking", "result.success failed", e)
            }
        }
    }

    /** OOM guard settings from the in-app UI (设置→推理引擎→内存守卫). */
    private fun handleSetOomGuard(call: MethodCall, result: MethodChannel.Result) {
        val enabled = call.argument<Boolean>("enabled") ?: true
        val preMb = call.argument<Int>("preHeadroomMb") ?: 768
        val postMb = call.argument<Int>("postHeadroomMb") ?: 1536
        logI("handleSetOomGuard", "enabled=$enabled, pre=${preMb}MB, post=${postMb}MB")
        engine.setOomGuardParams(enabled, preMb, postMb)
        mainHandler.post {
            try {
                result.success(true)
            } catch (e: Exception) {
                logE("handleSetOomGuard", "result.success failed", e)
            }
        }
    }

    private fun handleBenchmark(call: MethodCall, result: MethodChannel.Result) {
        val prompt   = call.argument<String>("prompt") ?: "Hello, how are you?"
        val nRepeats = call.argument<Int>("nRepeats") ?: 3

        logI("handleBenchmark", "prompt=${prompt.take(50)}, nRepeats=$nRepeats")

        Thread {
            try {
                val b = engine.benchmark(prompt, nRepeats)
                logI("handleBenchmark", "result: ${b.tokensPerSecond} tok/s")
                mainHandler.post {
                    try {
                        result.success(mapOf(
                            "tokensPerSecond" to b.tokensPerSecond,
                            "promptMs" to b.promptMs,
                            "generationMs" to b.generationMs
                        ))
                    } catch (e: Exception) {
                        logE("handleBenchmark", "result.success failed", e)
                    }
                }
            } catch (e: Exception) {
                logW("handleBenchmark", "error: ${e.message}", e)
                mainHandler.post {
                    try {
                        result.error("BENCHMARK_ERROR", e.message, null)
                    } catch (e2: Exception) {
                        logE("handleBenchmark", "result.error failed", e2)
                    }
                }
            }
        }.start()
    }

    private fun handleGetModelInfo(result: MethodChannel.Result) {
        try {
            val info = engine.getModelInfo()
            mainHandler.post {
                try {
                    result.success(mapOf(
                        "paramsBillion" to info.paramsBillion,
                        "contextSize" to info.contextSize,
                        "embeddingDim" to info.embeddingDim,
                        "layers" to info.layers,
                        "vocabSize" to info.vocabSize,
                        "fileSizeMB" to info.fileSizeMB,
                        "displayParams" to info.displayParams
                    ))
                } catch (e: Exception) {
                    logE("handleGetModelInfo", "result.success failed", e)
                }
            }
        } catch (e: Exception) {
            logW("handleGetModelInfo", "error: ${e.message}", e)
            mainHandler.post {
                try {
                    result.error("MODEL_INFO_ERROR", e.message, null)
                } catch (e2: Exception) {
                    logE("handleGetModelInfo", "result.error failed", e2)
                }
            }
        }
    }

    private fun handleGetMemoryInfo(result: MethodChannel.Result) {
        mainHandler.post {
            try {
                val am = getSystemService(ActivityManager::class.java)!!
                val memInfo = ActivityManager.MemoryInfo()
                am.getMemoryInfo(memInfo)
                val sysTotalMB = (memInfo.totalMem / 1_048_576).toInt()
                val sysAvailMB = (memInfo.availMem / 1_048_576).toInt()
                val sysUsedMB = (sysTotalMB - sysAvailMB).coerceAtLeast(0)
                // Process resident set size — includes llama.cpp model weights + KV cache
                // since the engine runs in-process. Best proxy for "llama.cpp memory".
                val procRssMB = readProcessRssMB()
                // Model weights (mmap'd .gguf file size; 0 when no model loaded).
                val modelMB = (engine.getModelSizeBytes() / 1_048_576).toInt()
                // KV-cache allocation size (0 when no model loaded).
                val kvCacheMB = (engine.getKvCacheBytes() / 1_048_576).toInt()
                result.success(
                    mapOf(
                        "sysTotalMB" to sysTotalMB,
                        "sysAvailMB" to sysAvailMB,
                        "sysUsedMB" to sysUsedMB,
                        "procRssMB" to procRssMB,
                        "modelMB" to modelMB,
                        "kvCacheMB" to kvCacheMB,
                    ),
                )
            } catch (e: Exception) {
                logE("handleGetMemoryInfo", "result.success failed", e)
            }
        }
    }

    /** Read VmRSS (resident set size in KB) of this process from /proc/self/status. */
    private fun readProcessRssMB(): Int {
        return try {
            val text = java.io.File("/proc/self/status").readText()
            val line = text.lineSequence().firstOrNull { it.startsWith("VmRSS:") }
            val kb = line?.replace(Regex("[^0-9]"), "")?.toLongOrNull() ?: 0L
            (kb / 1024).toInt()
        } catch (_: Exception) {
            0
        }
    }

    private fun handleGetInferenceStats(result: MethodChannel.Result) {
        mainHandler.post {
            try {
                result.success(engine.getLastStats())
            } catch (e: Exception) {
                logE("handleGetInferenceStats", "result.success failed", e)
            }
        }
    }

    private fun updateServiceStatus(status: String) {
        try {
            val intent = Intent(this, InferenceService::class.java)
            intent.putExtra("status", status)
            startService(intent)
        } catch (e: Exception) {
            // Service might not be running — ignore
        }
    }

    override fun onDestroy() {
        super.onDestroy()
        if (this::engine.isInitialized) {
            engine.destroy()
        }
        InferenceService.stop(this)
    }

    /**
     * Expose device hardware info (SoC) so the UI can gray out backends that
     * are known to be unsupported on the chip (e.g. OpenCL on MediaTek).
     */
    private fun handleGetDeviceInfo(result: MethodChannel.Result) {
        try {
            val board = Build.BOARD ?: ""
            val hardware = Build.HARDWARE ?: ""
            val socManufacturer = Build.SOC_MANUFACTURER ?: ""
            val socModel = Build.SOC_MODEL ?: ""
            val manufacturer = Build.MANUFACTURER ?: ""
            val model = Build.MODEL ?: ""
            logI("handleGetDeviceInfo", "board=$board hardware=$hardware socMfg=$socManufacturer soc=$socModel mfg=$manufacturer model=$model")
            result.success(mapOf(
                "board" to board,
                "hardware" to hardware,
                "socManufacturer" to socManufacturer,
                "socModel" to socModel,
                "manufacturer" to manufacturer,
                "model" to model,
            ))
        } catch (e: Exception) {
            logE("handleGetDeviceInfo", "failed", e)
            result.success(mapOf(
                "board" to "",
                "hardware" to "",
                "socManufacturer" to "",
                "socModel" to "",
                "manufacturer" to "",
                "model" to "",
            ))
        }
    }
}


/**
 * Singleton bridge for the token EventChannel.
 * Set from Dart via EventChannel setup.
 */
object TokenStream {
    var sink: io.flutter.plugin.common.EventChannel.EventSink? = null
}

/**
 * Singleton bridge for the loading log EventChannel.
 * Used to push model-loading progress messages to Dart.
 */
object LoadingLogStream {
    var sink: io.flutter.plugin.common.EventChannel.EventSink? = null
}
