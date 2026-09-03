import java.util.Properties
import java.io.FileInputStream
import com.chaquo.python.ChaquopyExtension

// Kotlin DSL 脚本编译需要 Chaquopy 类型（否则 `python {}` Unresolved reference）。
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
    // Chaquopy：Android 嵌入式 CPython（python_exec 工具运行时）
    id("com.chaquo.python")
}

android {
    namespace = "com.dgxspark.tongyilite"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.dgxspark.tongyilite"
        minSdk = 33
        targetSdk = 36
        versionCode = 7
        versionName = "0.1.6"

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

// Chaquopy：python_exec 工具运行时。首期不装第三方库（标准库足够），
// 避免构建网络依赖；后续按需在 pip 块声明（requests/numpy 等）。
// Kotlin DSL 下 `python {}` accessor 不可静态解析；Chaquopy 注册的扩展名是
// `chaquopy`（defaultConfig 内配置 Python 运行时），改用显式扩展配置。
extensions.configure<ChaquopyExtension>("chaquopy") {
    defaultConfig {
        // 17.x 默认 3.10；显式 3.11 以匹配主机 buildPython（3.11，版本必须一致）。
        version = "3.11"
        // 主机 Python 用于构建时交叉编译标准库：构建命令把 Python 加入 PATH，
        // 此处用 "python"（跨机兼容；其他机器只要 PATH 里有 python 即可）。
        buildPython("python")
        pip {
            // 不声明任何依赖：CPython 标准库即可跑脚本（json/re/urllib 等）。
        }
    }
}

flutter {
    source = "../.."
}

//llama.cpp doesn't publish to Maven; we build from source via CMake
