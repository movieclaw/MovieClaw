import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
}

val versions = Properties().apply { rootProject.file("version.properties").inputStream().use(::load) }
require(versions.getProperty("versionName").matches(Regex("\\d+\\.\\d+\\.\\d+"))) { "Android TV versionName 必须为 X.Y.Z" }
require(versions.getProperty("versionCode").toInt() in 1..2100000000) { "Android TV versionCode 超出允许范围" }

android {
    namespace = "io.movieclaw.androidtv"
    compileSdk = 37
    defaultConfig {
        applicationId = "io.movieclaw.androidtv"
        minSdk = 23
        targetSdk = 37
        versionName = versions.getProperty("versionName")
        versionCode = versions.getProperty("versionCode").toInt()
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
    }
    // 正式签名与手机版共用同一把密钥（ANDROID_KEYSTORE_* 环境变量，发版作业从 GitHub Secrets 解出）；
    // 没给密钥时（CI、本机）照常出未签名的 release 包
    val keystore = providers.environmentVariable("ANDROID_KEYSTORE_PATH").orNull
    signingConfigs {
        create("release") {
            if (keystore != null) {
                storeFile = file(keystore)
                storePassword = providers.environmentVariable("ANDROID_KEYSTORE_PASSWORD").get()
                keyAlias = providers.environmentVariable("ANDROID_KEY_ALIAS").get()
                keyPassword = providers.environmentVariable("ANDROID_KEY_PASSWORD").get()
            }
        }
    }
    buildTypes {
        release {
            if (keystore != null) signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = true
            isShrinkResources = true
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
        // 性能压测用（docs/perf/androidtv-home-scroll-2026-10.md）：与正式包同样混淆优化、不可调试，
        // 用调试密钥签名（能覆盖安装在已登录的 debug 包上），并允许 perfetto 采样
        create("benchmark") {
            initWith(getByName("release"))
            signingConfig = signingConfigs.getByName("debug")
            matchingFallbacks += "release"
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    buildFeatures {
        compose = true
        buildConfig = true
    }
}

dependencies {
    implementation(project(":core:session"))
    implementation(project(":core:playback"))
    // FFmpeg 音频软解：Exo 按类名反射加载，只要在 APK 里（§4.3）
    implementation(project(":core:ffmpeg"))
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)
    implementation(libs.androidx.lifecycle.runtime.compose)
    implementation(libs.androidx.lifecycle.viewmodel.compose)
    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.foundation)
    implementation(libs.tv.material)
    implementation(libs.compose.material.icons)
    implementation(libs.zxing.core)
    implementation(libs.androidx.tvprovider)
    implementation(libs.media3.ui.compose)
    implementation(libs.media3.datasource.okhttp)
    implementation(libs.coil.compose)
    implementation(libs.coil.network.okhttp)
    debugImplementation(libs.compose.ui.tooling)
    testImplementation(libs.junit)
    androidTestImplementation(libs.androidx.test.junit)
    androidTestImplementation(libs.androidx.test.runner)
    androidTestImplementation(libs.androidx.test.uiautomator)
}
