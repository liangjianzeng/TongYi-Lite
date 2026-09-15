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
        targetSdk = 36
        versionCode = 8
        versionName = "0.2.0"

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

flutter {
    source = "../.."
}
//llama.cpp doesn't publish to Maven; we build from source via CMake
