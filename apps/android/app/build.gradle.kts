import java.util.Properties

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.compose)
    alias(libs.plugins.kotlin.serialization)
    alias(libs.plugins.ksp)
    alias(libs.plugins.hilt)
}

val appVersion = Properties().apply {
    rootProject.file("version.properties").inputStream().use(::load)
}
val appVersionName = appVersion.getProperty("versionName")
val appVersionCode = appVersion.getProperty("versionCode").toInt()
require(appVersionName.matches(Regex("\\d+\\.\\d+\\.\\d+"))) { "Android versionName 必须为 X.Y.Z" }
require(appVersionCode in 1..2100000000) { "Android versionCode 超出允许范围" }

android {
    namespace = "io.movieclaw.android"
    compileSdk = 37

    defaultConfig {
        applicationId = "io.movieclaw.android"
        minSdk = 26
        targetSdk = 36
        versionCode = appVersionCode
        versionName = appVersionName
        ndk {
            // 正式包只发 arm64（MovieClaw-Android-arm64.apk）；FFmpeg 音频扩展另编了 armv7，这里滤掉
            abiFilters += listOf("arm64-v8a")
        }
    }

    signingConfigs {
        create("release") {
            val keystore = providers.environmentVariable("ANDROID_KEYSTORE_PATH").orNull
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
            signingConfig = signingConfigs.getByName("release")
            isMinifyEnabled = false
            proguardFiles(getDefaultProguardFile("proguard-android-optimize.txt"), "proguard-rules.pro")
        }
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    // buildConfig：生成 BuildConfig.VERSION_NAME/VERSION_CODE 供 App 自报版本（TV 版同款）；
    // 以前没开，导致客户端版本是手写常量、发行后永远不动
    buildFeatures {
        compose = true
        buildConfig = true
    }
    testOptions.unitTests.isIncludeAndroidResources = true
    testOptions.unitTests.all {
        it.maxHeapSize = "2g"
        it.systemProperty("robolectric.dependency.repo.url", "https://repo.maven.apache.org/maven2")
    }
    packaging {
        resources.excludes += setOf("META-INF/{AL2.0,LGPL2.1}", "META-INF/LICENSE.md", "META-INF/LICENSE-notice.md")
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        freeCompilerArgs.addAll(
            "-opt-in=kotlinx.serialization.ExperimentalSerializationApi",
        )
    }
}

dependencies {
    testImplementation("junit:junit:4.13.2")
    testImplementation(platform(libs.compose.bom))
    testImplementation("androidx.compose.ui:ui-test-junit4")
    debugImplementation("androidx.compose.ui:ui-test-manifest")
    testImplementation("org.robolectric:robolectric:4.16")
    testImplementation(shared.kotlinx.coroutines.test)
    testImplementation(shared.okhttp.mockwebserver.legacy)
    implementation(libs.androidx.core.ktx)
    implementation(libs.androidx.activity.compose)

    implementation(platform(libs.compose.bom))
    implementation(libs.compose.ui)
    implementation(libs.compose.material3)
    implementation(libs.compose.material.icons)
    implementation(libs.compose.ui.tooling.preview)
    debugImplementation(libs.compose.ui.tooling)

    implementation(libs.lifecycle.runtime.compose)
    implementation(libs.lifecycle.viewmodel.compose)
    implementation(libs.navigation.compose)
    implementation(libs.datastore.preferences)

    implementation(libs.retrofit)
    implementation(libs.retrofit.kotlinx)
    implementation(shared.okhttp)
    implementation(shared.okhttp.sse)
    implementation(shared.okhttp.logging)
    implementation(shared.kotlinx.serialization.json)

    implementation(libs.coil.compose)
    implementation(libs.coil.network.okhttp)

    // 本机通知的周期检查（纯客户端，不动服务端）
    implementation(libs.androidx.work.runtime)

    // 底栏玻璃的真背景模糊（内容层 hazeSource + 玻璃件 hazeEffect）
    implementation(libs.haze)

    implementation(libs.hilt.android)
    ksp(libs.hilt.compiler)
    implementation(libs.hilt.navigation.compose)

    // 播放：与 TV 共用的统一引擎（apps/android-core：Exo + FFmpeg 音频软解 + libass，失败走服务端流逐级降档）
    implementation(project(":core:playback"))
    // FFmpeg 音频软解：Exo 按类名反射加载，只要在 APK 里
    implementation(project(":core:ffmpeg"))
    // 正片画面（ContentFrame）；刷片的画面槽仍是 PlayerView
    // 刷片的字节预取与片段取流用同一个 OkHttp 连接池
    implementation(shared.media3.datasource.okhttp)
    implementation(shared.media3.ui.compose)
    implementation(shared.media3.ui)
    // 后台播放与锁屏控制：MediaSessionService + MediaSession
    implementation(shared.media3.session)
}
