/**
 * MainActivity — Flutter entry point with MethodChannel bridge.
 *
 * The MethodChannel connects Dart UI → Kotlin → JNI → C++ llama.cpp.
 * This is the ONLY communication channel (no HTTP server).
 */

package com.dgxspark.tongyilite

import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.util.Log
import androidx.annotation.NonNull
import com.dgxspark.tongyilite.service.InferenceService
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel


class MainActivity : FlutterActivity() {

    companion object {
        const val TAG = "TongYiLite"
    }

    private lateinit var engine: InferenceEngine
    private val mainHandler = Handler(Looper.getMainLooper())

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
                "stopGeneration"          -> handleStop(result)
                "benchmark"     -> handleBenchmark(call, result)
                "getModelInfo"  -> handleGetModelInfo(result)
                "getMemoryInfo" -> handleGetMemoryInfo(result)
                else            -> result.notImplemented()
            }
        }
    }

    // ------------------------------------------------------------------
    // MethodChannel handlers
    // ------------------------------------------------------------------

    private fun handleLoadModel(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")!!
        val nCtx = call.argument<Int>("nCtx") ?: 4096
        val enableGpu = call.argument<Boolean>("enableGpu") ?: true
        val gpuLayers = call.argument<Int>("gpuLayers") ?: 20

        logI("handleLoadModel", "path=$path, nCtx=$nCtx, enableGpu=$enableGpu, gpuLayers=$gpuLayers")

        Thread {
            try {
                val ok = engine.loadModel(path, nCtx, enableGpu, gpuLayers, object : LoadingLogCallback {
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

        logI("handleCompletionWithMessages", "prompt=${prompt.take(50)}, msgsJsonLen=${messagesJson.length}")

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
        val rt = Runtime.getRuntime()
        mainHandler.post {
            try {
                result.success(mapOf(
                    "totalMB" to rt.totalMemory() / 1_048_576,
                    "freeMB" to rt.freeMemory() / 1_048_576,
                    "usedMB" to (rt.totalMemory() - rt.freeMemory()) / 1_048_576,
                    "maxMB" to rt.maxMemory() / 1_048_576
                ))
            } catch (e: Exception) {
                logE("handleGetMemoryInfo", "result.success failed", e)
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
