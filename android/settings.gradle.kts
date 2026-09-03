pluginManagement {
    val flutterSdkPath = run {
        val properties = java.util.Properties()
        file("local.properties").inputStream().use { properties.load(it) }
        val flutterSdkPath = properties.getProperty("flutter.sdk")
        require(flutterSdkPath != null) { "flutter.sdk not set in local.properties" }
        flutterSdkPath
    }

    includeBuild("$flutterSdkPath/packages/flutter_tools/gradle")

    repositories {
        // 国内镜像优先（解决 dl.google.com 超时）
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        maven { url = uri("https://maven.aliyun.com/repository/public") }
        maven { url = uri("https://maven.aliyun.com/repository/gradle-plugin") }
        // Chaquopy（Android 嵌入式 CPython）官方仓库
        maven { url = uri("https://maven.chaquo.com/maven/") }
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

plugins {
    id("dev.flutter.flutter-plugin-loader") version "1.0.0"
    id("com.android.application") version "8.7.0" apply false
    id("org.jetbrains.kotlin.android") version "1.8.22" apply false
    // Chaquopy 插件（Android 嵌入式 CPython + pip）——17.x 支持 AGP 7.3~9.2 / minSdk 24+
    id("com.chaquo.python") version "17.0.0" apply false
}

// 运行时依赖解析仓库（含 Chaquopy runtime）：统一走 settings 声明，
// 避免 project repositories 与 settings 策略冲突。
dependencyResolutionManagement {
    repositories {
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        maven { url = uri("https://maven.aliyun.com/repository/public") }
        maven { url = uri("https://maven.chaquo.com/maven/") }
        google()
        mavenCentral()
    }
}

include(":app")
