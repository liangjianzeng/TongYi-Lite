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

    private lateinit var engine: InferenceEngine
    private val mainHandler = Handler(Looper.getMainLooper())

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
                "completion"    -> handleCompletion(call, result)
                "stopGeneration"-> handleStop(result)
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

        Thread {
            try {
                val ok = engine.loadModel(path, nCtx, object : LoadingLogCallback {
                    override fun onLoadingLog(message: String) {
                        mainHandler.post {
                            LoadingLogStream.sink?.success(message)
                        }
                    }
                })
                // Clear loading logs on completion (whether success or failure)
                mainHandler.post {
                    LoadingLogStream.sink?.success(null) // null signals end of batch
                    result.success(ok)
                }
            } catch (e: Exception) {
                mainHandler.post {
                    LoadingLogStream.sink?.success("加载异常: ${e.message}")
                    LoadingLogStream.sink?.success(null)
                    result.error("LOAD_FAILED", e.message, null)
                }
            }
        }.start()
    }

    private fun handleUnloadModel(result: MethodChannel.Result) {
        engine.unloadModel()
        result.success(true)
    }

    private fun handleIsLoaded(result: MethodChannel.Result) {
        result.success(engine.isLoaded())
    }

    /**
     * Streaming completion: tokens are sent back to Dart via `tokens` event channel.
     */
    private fun handleCompletion(call: MethodCall, result: MethodChannel.Result) {
        val prompt      = call.argument<String>("prompt")!!
        val maxTokens   = call.argument<Int>("maxTokens") ?: 2048
        val temperature = call.argument<Double>("temperature")?.toFloat() ?: 0.7f
        val topP        = call.argument<Double>("topP")?.toFloat() ?: 0.9f

        // Get the event sink for streaming tokens
        val sink = TokenStream.sink

        // Update foreground notification
        updateServiceStatus("AI 思考中...")

        Thread {
            try {
                val fullText = engine.completion(
                    prompt = prompt,
                    maxTokens = maxTokens,
                    temperature = temperature,
                    topP = topP,
                    onToken = { token ->
                        sink?.success(token)
                        true
                    }
                )
                updateServiceStatus("就绪")
                mainHandler.post { result.success(fullText) }
            } catch (e: Exception) {
                updateServiceStatus("推理出错")
                mainHandler.post { result.error("COMPLETION_ERROR", e.message, null) }
            }
        }.start()
    }

    private fun handleStop(result: MethodChannel.Result) {
        engine.stopGeneration()
        result.success(true)
    }

    private fun handleBenchmark(call: MethodCall, result: MethodChannel.Result) {
        val prompt   = call.argument<String>("prompt") ?: "Hello, how are you?"
        val nRepeats = call.argument<Int>("nRepeats") ?: 3

        Thread {
            try {
                val b = engine.benchmark(prompt, nRepeats)
                mainHandler.post {
                    result.success(mapOf(
                        "tokensPerSecond" to b.tokensPerSecond,
                        "promptMs" to b.promptMs,
                        "generationMs" to b.generationMs
                    ))
                }
            } catch (e: Exception) {
                mainHandler.post { result.error("BENCHMARK_ERROR", e.message, null) }
            }
        }.start()
    }

    private fun handleGetModelInfo(result: MethodChannel.Result) {
        try {
            val info = engine.getModelInfo()
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
            result.error("MODEL_INFO_ERROR", e.message, null)
        }
    }

    private fun handleGetMemoryInfo(result: MethodChannel.Result) {
        val rt = Runtime.getRuntime()
        result.success(mapOf(
            "totalMB" to rt.totalMemory() / 1_048_576,
            "freeMB" to rt.freeMemory() / 1_048_576,
            "usedMB" to (rt.totalMemory() - rt.freeMemory()) / 1_048_576,
            "maxMB" to rt.maxMemory() / 1_048_576
        ))
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
