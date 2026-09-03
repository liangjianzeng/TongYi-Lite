// Chaquopy 插件 apply 时检查 root 项目 buildscript classpath 是否同时含
// AGP 与 Chaquopy 插件 jar（否则报 "Failed to find plugin ... in your
// top-level build.gradle file"）。Flutter 的 AGP 经 includeBuild 注入，
// root classpath 没有坐标，需显式声明（Chaquopy 版本与 settings plugins 一致）。
buildscript {
    repositories {
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        maven { url = uri("https://maven.aliyun.com/repository/public") }
        maven { url = uri("https://maven.chaquo.com/maven/") }
        google()
        mavenCentral()
    }
    dependencies {
        classpath("com.android.tools.build:gradle:8.7.0")
        classpath("com.chaquo.python:gradle:16.1.0")
    }
}

allprojects {
    repositories {
        // 国内镜像优先（解决 dl.google.com 超时）
        maven { url = uri("https://maven.aliyun.com/repository/google") }
        maven { url = uri("https://maven.aliyun.com/repository/public") }
        maven { url = uri("https://maven.aliyun.com/repository/gradle-plugin") }
        google()
        mavenCentral()
    }
}

val newBuildDir: Directory = rootProject.layout.buildDirectory.dir("../../build").get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
