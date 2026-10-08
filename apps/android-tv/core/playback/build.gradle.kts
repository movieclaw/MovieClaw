// 播放：能力探测、会话协议、Exo 引擎、进度 / 心跳上报（docs/design/androidtv-app.md §4）
plugins {
    alias(libs.plugins.android.library)
}

android {
    namespace = "io.movieclaw.androidtv.core.playback"
    compileSdk = 37
    defaultConfig { minSdk = 23 }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    api(project(":core:network"))
    api(libs.media3.exoplayer)
    implementation(libs.media3.exoplayer.hls)
    implementation(libs.media3.datasource.okhttp)
    // 系统「正在播放」、遥控器媒体键、语音助手（docs/design/androidtv-app.md §4.4）
    implementation(libs.media3.session)
    // FFmpeg 音频软解（能力申报要问它能解什么）
    implementation(project(":core:ffmpeg"))
    implementation(libs.ass.media)
    implementation(libs.kotlinx.coroutines.android)
    testImplementation(libs.junit)
}
