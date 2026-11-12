package com.dgxspark.tongyilite

import android.content.Context
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import android.util.Log
import java.io.File

/**
 * [npu-line M2 Phase C-2, C-3 review rework] NPU 链资产解包器。
 *
 * W^X 布局（P0-3）：targetSdk34 untrusted_app 对 app_data_file 禁 execve
 * （本仓 build.gradle.kts 的 W^X 红线注同源），filesDir 解包的二进制跑不了。
 * 因此可执行体全部走 **jniLibs**：
 *
 *   src/main/jniLibs/arm64-v8a/libchain_run5_exec.so   链二进制（原 chain_run5
 *                                                        改名，AGP 原样入包）
 *   src/main/jniLibs/arm64-v8a/  QNN 运行库 4 件：libQnnHtp、
 *                                  libQnnHtpV73Skel、libQnnHtpV73Stub、
 *                                  libQnnSystem（均 .so 后缀）
 *
 * 配 packaging.jniLibs.useLegacyPackaging=true（build.gradle.kts 已有）安装
 * 期解出真文件到 nativeLibraryDir（system_file 标签，App uid 可 execve/
 * dlopen）。InferenceEngine.startHybridPrefill 把 chainBin/qnnLibDir 指到
 * nativeLibraryDir。
 *
 * 本类负责 assets/npu_libs（manifest 等非可执行件）解包到 filesDir/npu_m1
 * （chain_run5 的 cwd 与产物目录，必须可写），并把 chainDir/lib 建成指向
 * nativeLibraryDir 的**符号链接**——chain_run5 的 dlopen 字符串是
 * "./lib/libQnnHtp.so"（chain_run5.cpp:209，相对 cwd 解析），symlink 让该
 * 相对路径解析到 jniLibs 真身，产物仍落可写 chainDir。
 *
 *   assets/npu_libs/manifest_pre2_A|B|C   三段链 manifest（dec2 冻结件）
 *
 * 幂等：目标文件存在且大小一致则跳过；force=true 全量重写。旧版本遗留的
 * chainDir/lib 真目录（assets 时代）会在本函数里清掉换成 symlink，避免陈旧
 * .so 遮蔽。
 */
object NpuAssets {
    private const val TAG = "NpuAssets"
    private const val ASSET_ROOT = "npu_libs"

    /** chainDir = App 私有链目录（与 hyb_jni 默认 chainDir 约定一致）。 */
    fun chainDir(context: Context): File = File(context.filesDir, "npu_m1")

    /** 解包 npu_libs 目录树 → filesDir/npu_m1；返回 {相对路径 -> copied/skipped}。 */
    fun extract(context: Context, force: Boolean = false): Map<String, String> {
        val result = LinkedHashMap<String, String>()
        val root = chainDir(context)
        if (!root.exists() && !root.mkdirs()) {
            Log.e(TAG, "cannot create ${root.absolutePath}")
            return result
        }
        val am = context.assets
        try {
            walk(am, ASSET_ROOT, root, force, result)
        } catch (e: Exception) {
            Log.e(TAG, "extract failed", e)
        }
        // [P0-3] chainDir/lib → nativeLibraryDir 符号链接（chain_run5 的
        // dlopen("./lib/libQnnHtp.so") 相对 cwd 解析到 jniLibs 真身）。
        ensureLibSymlink(root, File(context.applicationInfo.nativeLibraryDir))
        // 旧 assets 时代遗留：filesDir 里的 chain_run5 真身删除（execve 本来
        // 就被 SELinux 拒；留着只占地）。lib 真目录已在 symlink 步骤处理。
        File(root, "chain_run5").takeIf { it.isFile }?.delete()
        Log.i(TAG, "extract: ${result.size} entries into ${root.absolutePath}")
        return result
    }

    /** chainDir/lib → [target]（绝对路径）；旧真目录/错向链接一律重建。 */
    private fun ensureLibSymlink(root: File, target: File) {
        val link = File(root, "lib")
        val want = target.absolutePath
        val existing = try {
            val st = Os.lstat(link.absolutePath)
            if (OsConstants.S_ISLNK(st.st_mode)) Os.readlink(link.absolutePath) else ""
        } catch (e: ErrnoException) {
            null // ENOENT：什么都不在
        }
        when {
            existing == want -> return // 已是目标 symlink，幂等快路径
            existing != null && existing.isNotEmpty() -> {
                // 错向 symlink：只删链接本身（File.delete 不跟随；绝不
                // deleteRecursively——那会跟进链接删掉目标目录内容）
                if (!link.delete()) {
                    Log.w(TAG, "stale symlink ${link} delete failed")
                    return
                }
            }
            existing != null -> {
                // 真目录 / 真文件（旧 assets 时代解包的 lib/）：清空重建
                if (link.isDirectory && !link.deleteRecursively()) {
                    Log.w(TAG, "stale dir ${link} replace failed")
                    return
                }
                if (link.exists() && !link.delete()) {
                    Log.w(TAG, "stale ${link} delete failed")
                    return
                }
            }
        }
        try {
            Os.symlink(want, link.absolutePath)
            Log.i(TAG, "symlink ${link.absolutePath} -> $want")
        } catch (e: ErrnoException) {
            Log.e(TAG, "symlink ${link} -> $want failed: errno=${e.errno}", e)
        }
    }

    private fun walk(
        am: android.content.res.AssetManager,
        assetPath: String,
        destDir: File,
        force: Boolean,
        result: MutableMap<String, String>,
    ) {
        val entries = am.list(assetPath) ?: return
        if (entries.isEmpty()) return
        // assets.list 对文件返回自身单元素（API<30 行为），需要 stat 区分：
        // 用 open() 试流 —— list 返回多元素即目录；单元素再试探。
        for (name in entries) {
            val childAsset = "$assetPath/$name"
            val child = am.list(childAsset)
            if (child != null && child.size > 1 || (child != null && child.size == 1 && child[0] != name)) {
                // 目录
                val sub = File(destDir, name).apply { if (!exists()) mkdirs() }
                walk(am, childAsset, sub, force, result)
            } else {
                copyOne(am, childAsset, File(destDir, name), force, result)
            }
        }
    }

    private fun copyOne(
        am: android.content.res.AssetManager,
        assetPath: String,
        target: File,
        force: Boolean,
        result: MutableMap<String, String>,
    ) {
        val rel = assetPath.removePrefix("$ASSET_ROOT/")
        if (!force && target.exists() && target.length() > 0) {
            // 大小一致即跳过（资产字节固定；换版资产请 force 或清数据）。
            try {
                am.open(assetPath).use { ins ->
                    val n = ins.available()
                    if (n.toLong() == target.length()) {
                        result[rel] = "skipped"
                        return
                    }
                }
            } catch (_: Exception) { /* fall through to copy */ }
        }
        target.parentFile?.mkdirs()
        try {
            am.open(assetPath).use { ins ->
                target.outputStream().use { os -> ins.copyTo(os, 65536) }
            }
            result[rel] = "copied"
        } catch (e: Exception) {
            Log.e(TAG, "copy $assetPath -> $target failed", e)
            result[rel] = "error:${e.message}"
        }
    }
}
