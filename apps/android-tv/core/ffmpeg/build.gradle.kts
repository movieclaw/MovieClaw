// FFmpeg 音频软解（Media3 decoder_ffmpeg 扩展，docs/design/androidtv-app.md §4.3）。
// Java 与 JNI 胶水层取自 Media3 1.11.1（Apache 2.0，包名不变：DefaultRenderersFactory 按类名反射加载
// androidx.media3.decoder.ffmpeg.FfmpegAudioRenderer）；FFmpeg 本身按 LGPL-2.1 编成独立共享库动态链接，
// 由 native/ffmpeg/build.sh 编到 src/main/jni/ffmpeg/（不入库）。没编过时模块是纯 Java：FfmpegLibrary
// 报不可用，Exo 不选它，其余照常。
plugins {
    alias(libs.plugins.android.library)
}

android {
    namespace = "io.movieclaw.androidtv.core.ffmpeg"
    compileSdk = 37
    ndkVersion = "27.3.13750724"
    defaultConfig {
        minSdk = 23
        consumerProguardFiles("proguard-rules.txt")
        ndk { abiFilters += listOf("arm64-v8a", "armeabi-v7a") }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    if (project.file("src/main/jni/ffmpeg/android-libs").exists()) {
        externalNativeBuild { cmake { path = file("src/main/jni/CMakeLists.txt"); version = "3.22.1" } }
        // FFmpeg 的共享库原样打进 APK（JNI 胶水层运行时由系统链接器按 NEEDED 加载它们）
        sourceSets { getByName("main").jniLibs.directories.add("src/main/jni/ffmpeg/android-libs") }
    }
}

dependencies {
    implementation(libs.media3.exoplayer)
    implementation(libs.media3.decoder)
    implementation(libs.androidx.annotation)
    // Media3 源码里的空值注解（只编译期用）
    compileOnly(libs.checker.qual)
}
