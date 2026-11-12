import java.util.Properties
import java.io.FileInputStream
import com.chaquo.python.ChaquopyExtension

// Kotlin DSL 鑴氭湰缂栬瘧闇€瑕?Chaquopy 绫诲瀷锛堝惁鍒?`python {}` Unresolved reference锛夈€?
buildscript {
    repositories {
        maven { url = uri("https://maven.chaquo.com/maven/") }
        google()
    }
    dependencies {
        classpath("com.chaquo.python:gradle:17.0.0")
    }
}

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("dev.flutter.flutter-gradle-plugin")
    // Chaquopy锛欰ndroid 宓屽叆寮?CPython锛坧ython_exec 宸ュ叿杩愯鏃讹級
    id("com.chaquo.python")
}

android {
    namespace = "com.dgxspark.tongyilite"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.dgxspark.tongyilite"
        minSdk = 33
        targetSdk = 34
        // 版本单一真源 = pubspec.yaml 的 version:（Flutter 构建期注入
        // flutter.versionName / flutter.versionCode）。此前是硬编 31/"0.3.8"，
        // 把 pubspec 的号整个盖掉——0.3.9+32 发出去两个包都自报 0.3.8/31。
        // Dart 侧两处显示常量（about.dart 的 _appVersion、
        // host_capabilities.dart 的 kPluginHostAppVersion）由
        // test/meta/version_consistency_test.dart 钉住与 pubspec 一致。
        versionCode = flutter.versionCode
        versionName = flutter.versionName

        ndk {
            abiFilters += listOf("arm64-v8a")
        }
    }

    signingConfigs {
        create("custom") {
            val keyProps = Properties().apply {
                load(FileInputStream(File(rootDir, "key.properties")))
            }
            storeFile = file(keyProps.getProperty("storeFile"))
            storePassword = keyProps.getProperty("storePassword")
            keyAlias = keyProps.getProperty("keyAlias")
            keyPassword = keyProps.getProperty("keyPassword")
        }
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            isShrinkResources = false
            signingConfig = signingConfigs["custom"]
        }
        debug {
            isMinifyEnabled = false
            signingConfig = signingConfigs["custom"]
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = "17"
    }

    // PdfBox-Android 是 Android 库，PDFParser 内部调 android.util.Log.d（stubbed）。
    // isReturnDefaultValues=true 让未 mock 的 Android 方法返回默认值（0）而非抛
    // "Method d in android.util.Log not mocked"，从而可在纯 JVM 单测中跑 PdfBox。
    testOptions {
        unitTests {
            isReturnDefaultValues = true
        }
    }

    // CMake native build
    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"  // Use system-installed CMake (4.3.2) or SDK default
        }
    }

    // Force Android to extract .so files to /data/app/<pkg>/lib/ on install.
    // Default (extractNativeLibs=false) keeps .so inside the APK, but Flutter's
    // custom ClassLoader can't find them via System.loadLibrary(). Setting
    // useLegacyPackaging=true ensures .so files are extracted and loadable.
    packaging {
        jniLibs {
            useLegacyPackaging = true
            // [npu-line C-3 P0-3] NPU 链五件套保字节入库：libchain_run5_exec.so
            // 是伪装成 .so 的 ELF 可执行体，QNN 四件按 sha256 治理（README）；
            // AGP 默认 strip 会让包内字节 ≠ staging 源（实测 exec 被 strip 到
            // 52536B）。strip 对语义理论无害，但分发一致性优先，五件全豁免。
            // AGP 8.7 实证（StripDebugSymbolsDelegate 反汇编 + jshell NIO glob
            // + 全量重跑对拍）：豁免集 = jniLibs.keepDebugSymbols，它是
            // StripDebugSymbolsTask 的唯一消费口（8.7 的 jniLibs 块已无
            // doNotStrip；旧 packagingOptions.doNotStrip 桥接不保证）。匹配是
            // NIO PathMatcher，模式经 compileGlob **原样**拼进 "glob:"（实测
            // 裸名 "n.so" 与 "*n.so" 均不命中、显式 "**/n.so" 命中）；匹配
            // 对象是 merged_native_libs 的相对路径 "lib/<abi>/<n>.so"（实测
            // 探针）。注意 NIO 的 "**/" 要求 ≥1 段目录，所以文档常见的
            // "lib/arm64-v8a/n.so" 直写永远不命中。用 "**/文件名"。
            // 另：strip 任务是增量的——改豁免集后必须删
            // build/app/intermediates/stripped_native_libs/ 强制全量重跑，
            // 否则旧 stripped 产物会让验证假阴性。
            keepDebugSymbols += setOf(
                "**/libchain_run5_exec.so",
                "**/libQnnHtp.so",
                "**/libQnnHtpV73Skel.so",
                "**/libQnnHtpV73Stub.so",
                "**/libQnnSystem.so",
            )
            // CRITICAL: exclude the Vulkan validation layer. A stale
            // libVkLayer_khronos_validation.so got baked into the APK; Android's
            // Vulkan loader auto-injects ANY layer found in the APK's lib dir as
            // a global layer, which wraps vkQueueSubmit and crashes on Mali
            // (MediaTek) drivers at dispatch-table access (fault addr 0x0 in
            // vulkan::api::QueueSubmit). Flutter/Impeller doesn't need it either.
            excludes += "lib/arm64-v8a/libVkLayer_khronos_validation.so"
        }
    }

    // JNI libs from llama.cpp pre-build
    sourceSets["main"].jniLibs.srcDirs("src/main/jniLibs")

    // [npu-line M2 C-3 review rework] 可执行体（libchain_run5_exec.so + QNN
    // 四件）走上方 jniLibs + useLegacyPackaging（nativeLibraryDir 真身，
    // system_file 可 exec/dlopen）；assets/npu_libs 只剩 manifest 等非可执行
    // 件 → NpuAssets.extract 解包 filesDir/npu_m1（链 cwd/产物区）。assets
    // 的 so/bin/raw 保持 STORED：解包成纯字节拷贝（md5 与设备侧推送一致，
    // 便于核对）；.bin 条目留给未来改名的链二进制变体。
    androidResources {
        noCompress += "so"
        noCompress += "bin"     // chain_run5 staged as chain_run5.bin? (we keep
                                 // the plain name; this entry covers the
                                 // ".bin" variant if ever renamed)
        noCompress += "raw"     // 链 IO 探针（调试资产）
    }
}

// Chaquopy锛歱ython_exec 宸ュ叿杩愯鏃躲€傞鏈熶笉瑁呯涓夋柟搴擄紙鏍囧噯搴撹冻澶燂級锛?
// 閬垮厤鏋勫缓缃戠粶渚濊禆锛涘悗缁寜闇€鍦?pip 鍧楀０鏄庯紙requests/numpy 绛夛級銆?
// Kotlin DSL 涓?`python {}` accessor 涓嶅彲闈欐€佽В鏋愶紱Chaquopy 娉ㄥ唽鐨勬墿灞曞悕鏄?
// `chaquopy`锛坉efaultConfig 鍐呴厤缃?Python 杩愯鏃讹級锛屾敼鐢ㄦ樉寮忔墿灞曢厤缃€?
extensions.configure<ChaquopyExtension>("chaquopy") {
    defaultConfig {
        // 17.x 榛樿 3.10锛涙樉寮?3.11 浠ュ尮閰嶄富鏈?buildPython锛?.11锛岀増鏈繀椤讳竴鑷达級銆?
        version = "3.11"
        // 涓绘満 Python 鐢ㄤ簬鏋勫缓鏃朵氦鍙夌紪璇戞爣鍑嗗簱锛氭瀯寤哄懡浠ゆ妸 Python 鍔犲叆 PATH锛?
        // 姝ゅ鐢?"python"锛堣法鏈哄吋瀹癸紱鍏朵粬鏈哄櫒鍙 PATH 閲屾湁 python 鍗冲彲锛夈€?
        buildPython("python")
        pip {
            // 涓嶅０鏄庝换浣曚緷璧栵細CPython 鏍囧噯搴撳嵆鍙窇鑴氭湰锛坖son/re/urllib 绛夛級銆?
        }
    }
}

dependencies {
    // PDF 文本抽取：TomRoush/PdfBox-Android（Apache PDFBox 2.0.27 移植，类包名 com.tom_roush.pdfbox）。
    // 替代原手搓纯 Dart 解析器（2026-09-30 已删）；纯 JVM 依赖，不碰 NDK。
    // 瘦身（2026-10-08）：排除传递依赖 BouncyCastle（bcprov/bcpkix/bcutil）——
    // 仅 PDF 签名验证与加密算法（含 AES-256/PQC）需要它；文本抽取路径零引用。
    // bcprov 自带的 PQC 查表（picnic/sike .properties）压缩后就有 4.2MB。
    // 极端场景（需 BC 的加密 PDF）会抛 NoClassDefFoundError，已由
    // MainActivity.handleExtractPdfText 的 Throwable 兜底转成用户可读错误。
    implementation("com.tom-roush:pdfbox-android:2.0.27.0") {
        exclude(group = "org.bouncycastle")
    }
    // Dev Agent L1：本地 git = JGit 进程内执行（EDL 许可，零 exec —— targetSdk 34
    // W^X 限制下 app 数据目录不可 exec，没有 git 可执行文件可用）。
    implementation("org.eclipse.jgit:org.eclipse.jgit:6.10.0.202406032230-r")
    // PdfExtracter 的 JVM 单测（fixture PDF 在 src/test/resources）。
    testImplementation("junit:junit:4.13.2")
}

flutter {
    source = "../.."
}
//llama.cpp doesn't publish to Maven; we build from source via CMake
