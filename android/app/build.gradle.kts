import java.util.Properties
import java.io.FileInputStream

plugins {
    id("com.android.application")
    id("org.jetbrains.kotlin.android")
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.dgxspark.tongyilite"
    compileSdk = 36

    defaultConfig {
        applicationId = "com.dgxspark.tongyilite"
        minSdk = 33
        targetSdk = 36
        versionCode = 4
        versionName = "0.1.3"

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
        }
    }

    // JNI libs from llama.cpp pre-build
    sourceSets["main"].jniLibs.srcDirs("src/main/jniLibs")
}

flutter {
    source = "../.."
}

//llama.cpp doesn't publish to Maven; we build from source via CMake
