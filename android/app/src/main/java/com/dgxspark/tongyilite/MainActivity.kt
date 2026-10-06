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
import com.tom_roush.pdfbox.android.PDFBoxResourceLoader
import com.tom_roush.pdfbox.pdmodel.encryption.InvalidPasswordException
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
                "shareText"  -> handleShareText(call, result)
                else         -> result.notImplemented()
            }
        }

        // PDF 文本抽取桥（WP-PDF）：智能体附件 PDF 解析。TomRoush/PdfBox-Android，
        // 替代原手搓纯 Dart 解析器；PDFBoxResourceLoader.init 惰性确保初始化。
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.dgxspark.tongyilite/pdf"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "extractPdfText" -> handleExtractPdfText(call, result)
                else             -> result.notImplemented()
            }
        }

        // App 桥：检测/拉起外部应用（Termux SSH 向导用——sshd 未启动时
        // 一键拉起 Termux，免去用户回桌面找图标）。
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.dgxspark.tongyilite/app"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "isAppInstalled" -> {
                    val pkg = call.argument<String>("package") ?: ""
                    result.success(isAppInstalled(pkg))
                }
                "launchApp" -> {
                    val pkg = call.argument<String>("package") ?: ""
                    result.success(launchApp(pkg))
                }
                // Termux 零粘贴（RUN_COMMAND intent）：向导安装命令自动执行。
                // 前置：本 app 声明 com.termux.permission.RUN_COMMAND（manifest）
                // + 用户在 Termux ~/.termux/termux.properties 开
                // allow-external-apps=true（一次性）。
                "runInTermux" -> {
                    val command = call.argument<String>("command") ?: ""
                    val background = call.argument<Boolean>("background") ?: false
                    result.success(runInTermux(command, background))
                }
                else -> result.notImplemented()
            }
        }

        // 开发环境桥（Dev Agent L1/L2）：native 信息 + Termux RUN_COMMAND
        // 免 SSH 通道 + Termux 伴侣 APK 下载/安装。
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.dgxspark.tongyilite/devenv"
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "nativeInfo" -> result.success(mapOf(
                    "nativeLibraryDir" to applicationInfo.nativeLibraryDir,
                    "filesDir" to filesDir.absolutePath,
                ))
                "runTermux" -> handleRunTermux(call, result)
                "canRequestInstall" -> result.success(canRequestInstall())
                "installApk" -> handleInstallApk(call, result)
                "downloadTermuxApk" -> handleDownloadTermuxApk(call, result)
                else -> result.notImplemented()
            }
        }

        // 本地 git 桥（Dev Agent L1）：JGit 进程内执行（零 exec，W^X 安全）。
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "com.dgxspark.tongyilite/devgit"
        ).setMethodCallHandler { call, result ->
            devGitExecutor.submit {
                val reply = try {
                    when (call.method) {
                        "status" -> DevGitPlugin.status(
                            call.argument<String>("root") ?: "")
                        "diff" -> DevGitPlugin.diff(
                            call.argument<String>("root") ?: "",
                            call.argument<Boolean>("staged") == true,
                            call.argument<String>("file"))
                        "log" -> DevGitPlugin.log(
                            call.argument<String>("root") ?: "",
                            call.argument<Number>("n")?.toInt() ?: 10)
                        "commit" -> DevGitPlugin.commit(
                            call.argument<String>("root") ?: "",
                            call.argument<List<String>>("files") ?: emptyList(),
                            call.argument<String>("message") ?: "")
                        "push" -> DevGitPlugin.push(
                            call.argument<String>("root") ?: "",
                            call.argument<String>("remote") ?: "origin",
                            call.argument<String>("branch"),
                            call.argument<String>("username"),
                            call.argument<String>("password"))
                        "clone" -> DevGitPlugin.clone(
                            call.argument<String>("url") ?: "",
                            call.argument<String>("target") ?: "",
                            call.argument<String>("username"),
                            call.argument<String>("password"),
                            call.argument<String>("branch"),
                            call.argument<Number>("depth")?.toInt())
                        else -> null
                    }
                } catch (e: Exception) {
                    logE("devgit", "${call.method} failed: ${e.message}", e)
                    mapOf("ok" to false, "output" to "git 操作异常：${e.message}")
                }
                runOnMain {
                    if (reply == null) result.notImplemented()
                    else result.success(reply)
                }
            }
        }
    }

    /** Termux RUN_COMMAND intent 发送（免 SSH 通道）。返回错误信息或 null。 */
    private fun handleRunTermux(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path").orEmpty()
        val args = call.argument<List<String>>("args") ?: emptyList()
        val workDir = call.argument<String>("workDir")
        if (path.isEmpty() || args.isEmpty()) {
            result.error("BAD_ARGS", "path/args 不能为空", null)
            return
        }
        try {
            val intent = Intent().apply {
                setClassName("com.termux", "com.termux.app.RunCommandService")
                action = "com.termux.RUN_COMMAND"
                putExtra("com.termux.RUN_COMMAND_PATH", path)
                putExtra("com.termux.RUN_COMMAND_ARGUMENTS", args.toTypedArray())
                if (!workDir.isNullOrEmpty()) {
                    putExtra("com.termux.RUN_COMMAND_WORKDIR", workDir)
                }
                putExtra("com.termux.RUN_COMMAND_BACKGROUND", true)
            }
            startService(intent)
            logI("handleRunTermux", "RUN_COMMAND sent: $path ${args.joinToString(" ").take(80)}")
            result.success(null)
        } catch (e: Exception) {
            logW("handleRunTermux", "send failed: ${e.message}", e)
            result.success("发送失败：${e.message}（Termux 未安装或未允许外部应用执行）")
        }
    }

    private fun canRequestInstall(): Boolean = try {
        packageManager.canRequestPackageInstalls()
    } catch (_: Exception) {
        false
    }

    /** FileProvider 拉起 APK 安装器（Termux 伴侣应用）。返回错误信息或 null。 */
    private fun handleInstallApk(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path").orEmpty()
        val f = File(path)
        if (path.isEmpty() || !f.isFile) {
            result.error("NOT_FOUND", "APK 不存在：$path", null)
            return
        }
        try {
            val uri = FileProvider.getUriForFile(this, "$packageName.fileprovider", f)
            val intent = Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(uri, "application/vnd.android.package-archive")
                addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_ACTIVITY_NEW_TASK)
            }
            startActivity(intent)
            logI("handleInstallApk", "installer opened for $path")
            result.success(null)
        } catch (e: Exception) {
            logW("handleInstallApk", "install failed: ${e.message}", e)
            result.success("安装器拉起失败：${e.message}")
        }
    }

    /** 系统 DownloadManager 下载 Termux APK 到 Download/TongYi-Lite/。 */
    private fun handleDownloadTermuxApk(call: MethodCall, result: MethodChannel.Result) {
        val url = call.argument<String>("url").orEmpty()
        if (url.isEmpty()) {
            result.error("BAD_ARGS", "url 不能为空", null)
            return
        }
        try {
            val req = android.app.DownloadManager.Request(Uri.parse(url)).apply {
                setTitle("Termux.apk")
                setDescription("TongYi-Lite 开发环境（Termux 伴侣应用）")
                setDestinationInExternalPublicDir(
                    android.os.Environment.DIRECTORY_DOWNLOADS, "TongYi-Lite/termux.apk")
                setNotificationVisibility(
                    android.app.DownloadManager.Request.VISIBILITY_VISIBLE_NOTIFY_COMPLETED)
            }
            val dm = getSystemService(android.app.DownloadManager::class.java)
            dm.enqueue(req)
            logI("handleDownloadTermuxApk", "enqueued $url")
            result.success(null)
        } catch (e: Exception) {
            logW("handleDownloadTermuxApk", "download failed: ${e.message}", e)
            result.success("下载失败：${e.message}")
        }
    }

    private fun isAppInstalled(pkg: String): Boolean = try {
        packageManager.getPackageInfo(pkg, 0)
        true
    } catch (_: Exception) {
        false
    }

    /// 通过 Termux RUN_COMMAND 服务执行命令。返回是否已派发 intent
    /// （Termux 未装/未开 allow-external-apps 时 Termux 侧会静默忽略或抛异常）。
    private fun runInTermux(command: String, background: Boolean): Boolean = try {
        val intent = Intent("com.termux.RUN_COMMAND").apply {
            setClassName("com.termux", "com.termux.app.RunCommandService")
            putExtra("com.termux.RUN_COMMAND_PATH",
                "/data/data/com.termux/files/usr/bin/sh")
            putExtra("com.termux.RUN_COMMAND_ARGUMENTS",
                arrayOf("-c", command))
            putExtra("com.termux.RUN_COMMAND_WORKDIR",
                "/data/data/com.termux/files/home")
            putExtra("com.termux.RUN_COMMAND_BACKGROUND", background)
        }
        if (!background && android.os.Build.VERSION.SDK_INT >= 26) {
            startForegroundService(intent)
        } else {
            startService(intent)
        }
        true
    } catch (_: Exception) {
        false
    }

    private fun launchApp(pkg: String): Boolean = try {
        val intent = packageManager.getLaunchIntentForPackage(pkg)
        if (intent == null) {
            false
        } else {
            intent.addFlags(android.content.Intent.FLAG_ACTIVITY_NEW_TASK)
            startActivity(intent)
            true
        }
    } catch (_: Exception) {
        false
    }

    // ------------------------------------------------------------------
    // 系统分享桥：纯文本 ACTION_SEND（用户在分享面板选微信/QQ 等目标）。
    // ------------------------------------------------------------------

    private fun handleShareText(call: MethodCall, result: MethodChannel.Result) {
        val text = call.argument<String>("text").orEmpty()
        val title = call.argument<String>("title") ?: "分享"
        if (text.isEmpty()) {
            result.error("EMPTY", "分享内容为空", null)
            return
        }
        try {
            val intent = Intent(Intent.ACTION_SEND).apply {
                type = "text/plain"
                putExtra(Intent.EXTRA_TEXT, text)
            }
            startActivity(Intent.createChooser(intent, title))
            logI("handleShareText", "share chooser opened (${text.length} chars)")
            result.success(true)
        } catch (e: Exception) {
            logE("handleShareText", "share failed: ${e.message}", e)
            result.error("SHARE_FAILED", "分享失败：${e.message}", null)
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
     * openFile：用系统查看器打开产物。分层回退（真机 ROM 对授权行为不一，
     * 尤其 MIUI/HyperOS 对 MediaStore URI 的 grant 挑剔）：
     * ① content:// URI 直开（exportFile 返回值）；
     * ② fallbackPath（工作区源文件）走 FileProvider——应用自有文件，授权必成；
     * ③ target 本身是文件路径 → FileProvider。
     * 每层失败再试 createChooser；全部失败才报错（带各层失败原因）。
     */
    private fun handleOpenFile(call: MethodCall, result: MethodChannel.Result) {
        val target = call.argument<String>("path")?.trim().orEmpty()
        val fallbackPath = call.argument<String>("fallbackPath")?.trim().orEmpty()
        if (target.isEmpty() && fallbackPath.isEmpty()) {
            result.error("NO_PATH", "缺少 path 参数", null)
            return
        }
        data class Attempt(val uri: Uri, val mime: String, val label: String)
        val attempts = mutableListOf<Attempt>()
        if (target.startsWith("content:")) {
            val uri = Uri.parse(target)
            attempts.add(Attempt(uri, contentResolver.getType(uri) ?: "*/*", "content-uri"))
        }
        for (p in listOf(fallbackPath, target)) {
            if (p.isEmpty() || p.startsWith("content:")) continue
            val f = File(p)
            if (f.isFile) {
                attempts.add(
                    Attempt(
                        FileProvider.getUriForFile(this, "$packageName.fileprovider", f),
                        mimeFor(f.name),
                        "fileprovider:${f.name}"
                    )
                )
            }
        }
        if (attempts.isEmpty()) {
            result.error("NOT_FOUND", "无可打开的文件：$target", null)
            return
        }
        val errors = StringBuilder()
        for (a in attempts) {
            try {
                val intent = Intent(Intent.ACTION_VIEW)
                    .setDataAndType(a.uri, a.mime)
                    .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                try {
                    startActivity(intent)
                } catch (e: Exception) {
                    // 部分 ROM 直开被拒/无处理器：chooser 兜底（flags 随行传递）。
                    startActivity(
                        Intent.createChooser(intent, null)
                            .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                    )
                }
                logI("handleOpenFile", "opened via ${a.label}")
                result.success(true)
                return
            } catch (e: Exception) {
                logW("handleOpenFile", "attempt ${a.label} failed: ${e.message}", e)
                errors.append('[').append(a.label).append("] ").append(e.message).append("; ")
            }
        }
        result.error("OPEN_FAILED", "所有打开方式被拒绝：$errors", null)
    }

    // ------------------------------------------------------------------
    // MethodChannel handlers
    // ------------------------------------------------------------------

    /**
     * MethodChannel result 必答守卫（2026-09-30 审查 P1）：业务块抛错时
     * 转成 result.error——此前多个 handler 的 catch 只打日志不回调，
     * Dart 侧 await 的 Future 永久挂死。
     */
    private inline fun replyGuard(
        result: MethodChannel.Result,
        tag: String,
        block: () -> Unit,
    ) {
        try {
            block()
        } catch (e: Exception) {
            logE(tag, "error: ${e.message}", e)
            try {
                result.error(tag.uppercase(), e.message ?: "unknown error", null)
            } catch (e2: Exception) {
                logE(tag, "result.error failed", e2)
            }
        }
    }

    // python_exec：单线程池执行脚本（串行防 GIL 争用），超时由 Future.get 兜底。
    private val pythonExecutor = Executors.newSingleThreadExecutor()

    // devgit：JGit 操作单线程池（串行防仓库句柄争用）。
    private val devGitExecutor = Executors.newSingleThreadExecutor()

    // pdf：PDF 抽取（TomRoush/PdfBox-Android）。
    // 单线程池执行 load+getText（原生/阻塞），主线程只收回调；init 惰性且只一次。
    private val pdfExecutor = Executors.newSingleThreadExecutor()
    private var pdfBoxInited = false

    private fun ensurePdfBoxInit() {
        if (!pdfBoxInited) {
            PDFBoxResourceLoader.init(this)
            pdfBoxInited = true
        }
    }

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

    private fun handleExtractPdfText(call: MethodCall, result: MethodChannel.Result) {
        val path = call.argument<String>("path")
        if (path.isNullOrBlank()) {
            result.error("NO_PATH", "缺少 path 参数", null)
            return
        }
        pdfExecutor.submit {
            try {
                ensurePdfBoxInit()
                val res = PdfExtracter.extract(path)
                runOnMain {
                    result.success(mapOf("ok" to true, "pageCount" to res.pageCount, "pages" to listOf(res.text)))
                }
            } catch (e: InvalidPasswordException) {
                runOnMain { result.error("ENCRYPTED", "PDF 加密且需要密码", null) }
            } catch (e: Exception) {
                logE("handleExtractPdfText", "extractPdfText error: ${e.message}", e)
                runOnMain { result.error("PDF_ERROR", e.message, null) }
            }
        }
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
        // unloadModel 现为阻塞式（带超时）→ 后台线程执行（channel 回调在主线程，
        // 直跑会 ANR）；失败/超时如实上报，Dart 侧不再在「以为卸载完了、
        // native 还在卸」的窗口里发起 load。
        Thread {
            val ok = try {
                engine.unloadModel()
            } catch (e: Exception) {
                logE("handleUnloadModel", "unload failed", e)
                false
            }
            mainHandler.post {
                try {
                    if (ok) {
                        result.success(true)
                    } else {
                        result.error("UNLOAD_FAILED", "模型卸载超时或失败，请重试", null)
                    }
                } catch (e: Exception) {
                    logE("handleUnloadModel", "result failed", e)
                }
            }
        }.start()
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

        // 入引擎单线程队列（与 load/unload/destroy 同一 executor，串行化）。
        // 此前裸 Thread 跑 JNI，与 onDestroy 的 nativeDestroy 竞态 → 退出时
        // SIGSEGV（2026-09-30 审查 P0）。executor 已 shutdown（销毁中）→
        // 立即报错，不让 Dart 侧挂死。
        val task = try {
            engine.onEngineThread {
                try {
                    logI("handleCompletion", "calling engine.completion() from engine thread")
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
            }
        } catch (e: Exception) {
            logW("handleCompletion", "engine executor rejected (destroying?)", e)
            mainHandler.post {
                result.error("ENGINE_DESTROYED", "推理引擎已销毁（应用退出中）", null)
            }
            null
        }
        task // keep reference alive until done (executor holds it anyway)
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

        // 入引擎单线程队列（同 handleCompletion，消灭退出竞态）。
        try {
            engine.onEngineThread {
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
            }
        } catch (e: Exception) {
            logW("handleCompletionWithMessages", "engine executor rejected (destroying?)", e)
            mainHandler.post {
                result.error("ENGINE_DESTROYED", "推理引擎已销毁（应用退出中）", null)
            }
        }
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
                // 重复 start：先停掉旧实例（审查 P1——直接覆盖会让旧录音线程
                // 与 AudioRecord 持续占用麦克风直到进程死亡）。
                audioRecorder?.let { old ->
                    try { old.stop() } catch (e: Exception) {
                        logW("handleStartRecording", "old recorder stop failed", e)
                    }
                }
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
            replyGuard(result, "handleSupportsAudio") {
                result.success(engine.supportsAudio())
            }
        }
    }

    private fun handleStop(result: MethodChannel.Result) {
        logI("handleStop", "")
        replyGuard(result, "handleStop") {
            engine.stopGeneration()
            result.success(true)
        }
    }

    private fun handleResetContext(result: MethodChannel.Result) {
        logI("handleResetContext", "")
        replyGuard(result, "handleResetContext") {
            engine.resetContext()
            result.success(true)
        }
    }

    private fun handleSetEnableThinking(call: MethodCall, result: MethodChannel.Result) {
        val enable = call.argument<Boolean>("enable") ?: false
        logI("handleSetEnableThinking", "enable=$enable")
        replyGuard(result, "handleSetEnableThinking") {
            engine.setEnableThinking(enable)
            result.success(true)
        }
    }

    /** OOM guard settings from the in-app UI (设置→推理引擎→内存守卫). */
    private fun handleSetOomGuard(call: MethodCall, result: MethodChannel.Result) {
        val enabled = call.argument<Boolean>("enabled") ?: true
        val preMb = call.argument<Int>("preHeadroomMb") ?: 768
        val postMb = call.argument<Int>("postHeadroomMb") ?: 1536
        logI("handleSetOomGuard", "enabled=$enabled, pre=${preMb}MB, post=${postMb}MB")
        replyGuard(result, "handleSetOomGuard") {
            engine.setOomGuardParams(enabled, preMb, postMb)
            result.success(true)
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
                logE("handleGetMemoryInfo", "error: ${e.message}", e)
                try {
                    result.error("HANDLEGETMEMORYINFO", e.message ?: "unknown error", null)
                } catch (e2: Exception) {
                    logE("handleGetMemoryInfo", "result.error failed", e2)
                }
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
            replyGuard(result, "handleGetInferenceStats") {
                result.success(engine.getLastStats())
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
        // 录音中销毁：先停麦克风（审查 P1：旧实例泄漏占用录音直到进程死亡）。
        try {
            audioRecorder?.stop()
            audioRecorder = null
        } catch (e: Exception) {
            logW("onDestroy", "audioRecorder stop failed", e)
        }
        // Chaquopy 单线程池随 Activity 销毁关闭（审查 P2）。
        try {
            pythonExecutor.shutdown()
        } catch (e: Exception) {
            logW("onDestroy", "pythonExecutor shutdown failed", e)
        }
        try {
            devGitExecutor.shutdown()
        } catch (e: Exception) {
            logW("onDestroy", "devGitExecutor shutdown failed", e)
        }
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
