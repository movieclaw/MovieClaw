pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}
dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
    // 与手机版共用的模块（apps/android-core）的依赖版本
    versionCatalogs {
        create("shared") { from(files("../android-core/gradle/shared.versions.toml")) }
    }
}
rootProject.name = "MovieClawAndroidTV"
include(":app", ":core:model", ":core:network", ":core:session", ":core:playback", ":core:ffmpeg")
// 播放引擎、接口与模型、FFmpeg 音频扩展与手机版共用，源码在 apps/android-core（iOS 的 Shared/ 同理）
listOf("model", "network", "playback", "ffmpeg").forEach { project(":core:$it").projectDir = file("../android-core/$it") }
