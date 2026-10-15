// 播放：能力探测、会话协议、Exo 引擎、进度 / 心跳上报（docs/design/androidtv-app.md §4）
plugins {
    id("com.android.library")
}

android {
    namespace = "io.movieclaw.core.playback"
    compileSdk = 37
    defaultConfig { minSdk = 23 }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
    // 原盘读取器的单测要真的跑 Exo 的 TS 解析器（用到 SparseArray 等 Android 类），跑在 Robolectric 上
    testOptions.unitTests.all {
        it.systemProperty("robolectric.dependency.repo.url", "https://repo.maven.apache.org/maven2")
    }
}

dependencies {
    api(project(":core:network"))
    api(shared.media3.exoplayer)
    implementation(shared.media3.exoplayer.hls)
    implementation(shared.media3.datasource.okhttp)
    // 系统「正在播放」、遥控器媒体键、语音助手（docs/design/androidtv-app.md §4.4）
    implementation(shared.media3.session)
    // FFmpeg 音频软解（能力申报要问它能解什么）
    implementation(project(":core:ffmpeg"))
    implementation(shared.ass.media)
    implementation(shared.kotlinx.coroutines.android)
    testImplementation(shared.junit)
    testImplementation(shared.okhttp.mockwebserver)
    testImplementation(shared.kotlinx.coroutines.test)
    testImplementation(shared.robolectric)
}
