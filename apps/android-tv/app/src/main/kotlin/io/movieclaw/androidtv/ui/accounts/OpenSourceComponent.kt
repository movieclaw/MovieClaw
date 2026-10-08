package io.movieclaw.androidtv.ui.accounts

/**
 * 随包分发的一个开源组件（Apple 端 Shared/About/OpenSourceComponent.swift）：名称、许可、源码地址、
 * 随包许可全文的文件名（app/src/main/assets/licenses/<licenseFile>.txt）。
 *
 * 清单按 Android 版实际打进安装包的依赖写（gradle/libs.versions.toml、core/ffmpeg）；加了组件要同步补上。
 */
data class OpenSourceComponent(
    val name: String,
    val license: String,
    val source: String,
    val licenseFiles: List<String>,
) {
    companion object {
        private const val APACHE = "Apache License 2.0"
        private val apacheText = listOf("License-Apache-2.0")

        val all: List<OpenSourceComponent> = listOf(
            OpenSourceComponent("AndroidX Media3（ExoPlayer）", APACHE, "https://github.com/androidx/media", apacheText),
            OpenSourceComponent("Jetpack Compose 与 AndroidX", APACHE, "https://android.googlesource.com/platform/frameworks/support", apacheText),
            OpenSourceComponent("Kotlin 标准库与 kotlinx.coroutines", APACHE, "https://github.com/JetBrains/kotlin、https://github.com/Kotlin/kotlinx.coroutines", apacheText),
            OpenSourceComponent("kotlinx.serialization", APACHE, "https://github.com/Kotlin/kotlinx.serialization", apacheText),
            OpenSourceComponent("OkHttp 与 Okio", APACHE, "https://github.com/square/okhttp", apacheText),
            OpenSourceComponent("Coil", APACHE, "https://github.com/coil-kt/coil", apacheText),
            OpenSourceComponent("ZXing", APACHE, "https://github.com/zxing/zxing", apacheText),
            OpenSourceComponent("思源宋体（Noto Serif SC，欢迎页子集）", "SIL Open Font License 1.1", "https://github.com/notofonts/noto-cjk", listOf("OFL")),
            // 只编了音频解码器，LGPL-2.1，独立共享库动态链接（libavcodec / libavutil / libswresample）
            OpenSourceComponent(
                "FFmpeg 6.0.1（音频解码）",
                "GNU LGPL 2.1 或更新版本",
                "https://ffmpeg.org/releases/ffmpeg-6.0.1.tar.xz；编译脚本 apps/android-tv/native/ffmpeg/build.sh（https://github.com/movieclaw/movieclaw）",
                listOf("LGPL-2.1"),
            ),
        )

        fun named(name: String): OpenSourceComponent? = all.firstOrNull { it.name == name }
    }
}
