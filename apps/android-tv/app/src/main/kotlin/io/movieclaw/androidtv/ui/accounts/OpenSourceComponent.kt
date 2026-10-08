package io.movieclaw.androidtv.ui.accounts

/**
 * 随包分发的一个开源组件（Apple 端 Shared/About/OpenSourceComponent.swift）：名称、许可、源码地址、
 * 随包许可全文的文件名（app/src/main/assets/licenses/<licenseFile>.txt）。
 *
 * 清单按 Android 版实际打进安装包的依赖写（gradle/libs.versions.toml）；以后加了 FFmpeg 等组件要同步补上。
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
        )

        fun named(name: String): OpenSourceComponent? = all.firstOrNull { it.name == name }
    }
}
