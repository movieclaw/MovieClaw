import java.net.URI
import java.security.MessageDigest
import java.util.Properties
import java.util.zip.ZipInputStream
import org.gradle.api.DefaultTask
import org.gradle.api.provider.Property
import org.gradle.api.file.DirectoryProperty
import org.gradle.api.tasks.Input
import org.gradle.api.tasks.Internal
import org.gradle.api.tasks.OutputDirectory
import org.gradle.api.tasks.TaskAction

plugins {
    alias(libs.plugins.android.application)
    alias(libs.plugins.kotlin.android)
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
    compileSdk = 36
    buildToolsVersion = "36.0.0"
    ndkVersion = "28.2.13676358"

    defaultConfig {
        applicationId = "io.movieclaw.android"
        minSdk = 26
        targetSdk = 36
        versionCode = appVersionCode
        versionName = appVersionName
        ndk {
            // libmp2.so(libmpv 全量内核)仅随 arm64 分发,包体控制见设计方案 §附录 B
            abiFilters += listOf("arm64-v8a")
        }
    }

    externalNativeBuild {
        cmake {
            path = file("src/main/cpp/CMakeLists.txt")
            version = "3.22.1"
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
    buildFeatures { compose = true }
    testOptions.unitTests.isIncludeAndroidResources = true
    testOptions.unitTests.all {
        it.maxHeapSize = "2g"
        it.systemProperty("robolectric.dependency.repo.url", "https://repo.maven.apache.org/maven2")
    }
    packaging {
        resources.excludes += setOf("META-INF/{AL2.0,LGPL2.1}", "META-INF/LICENSE.md", "META-INF/LICENSE-notice.md")
    }
}

// ---------------------------------------------------------------------------
// 预编译原生库（FFmpeg / mpv / libass 的 arm64-v8a 产物）
//
// 它们体积大、又是第三方二进制（分发另有许可要求），所以不入库，放在 Release 附件里。
// 缺了它们照样能编出可用的 APK（纯 Exo 内核），所以**不阻塞构建**：
//   · 想要全功能包：构建时自动下载一次（约 38MB）→ 校验 sha256 → 解压到 jniLibs
//   · 离线 / 下载失败：打一行提示后继续，出的是仅 Exo 内核的包
//
// 任务写成一个**类**而不是 script 里的闭包：执行期闭包会捕获脚本对象，
// 配置缓存（org.gradle.configuration-cache=true）会直接拒绝序列化它们。
// ---------------------------------------------------------------------------

/**
 * 下载并解压 arm64-v8a 预编译原生库。
 *
 * 所有输入都是 Gradle 托管的属性（`Property` / `DirectoryProperty`），
 * 任务动作里只碰 JDK API —— 这样才与配置缓存兼容。
 */
abstract class DownloadNativeLibsTask : DefaultTask() {

    @get:Input
    abstract val required: Property<Boolean>

    @get:Input
    abstract val zipUrl: Property<String>

    @get:Input
    abstract val zipSha256: Property<String>

    /** 产物落点：jniLibs 是 AGP 的约定目录 */
    @get:OutputDirectory
    abstract val targetDir: DirectoryProperty

    /** 下载中转目录 */
    @get:Internal
    abstract val workDir: DirectoryProperty

    @TaskAction
    fun download() {
        val dir = targetDir.get().asFile
        if (File(dir, "libmp2.so").exists()) {
            logger.lifecycle("预编译原生库已就位：${dir.path}（要重下先删掉这个目录）")
            return
        }
        dir.mkdirs()
        val tmp = workDir.get().asFile.also { it.mkdirs() }
        val zip = File(tmp, "native-libs.zip")
        try {
            logger.lifecycle("下载预编译原生库（约 38MB，仅首次）…")
            URI(zipUrl.get()).toURL().openStream().use { input ->
                zip.outputStream().use { output -> input.copyTo(output) }
            }
            val actual = MessageDigest.getInstance("SHA-256")
                .digest(zip.readBytes())
                .joinToString("") { "%02x".format(it) }
            if (!actual.equals(zipSha256.get(), ignoreCase = true)) {
                throw GradleException(
                    "预编译原生库校验失败：期望 ${zipSha256.get()}，实际 $actual。已丢弃下载内容，" +
                        "请重试或改 gradle.properties 里的 nativeLibsUrl / nativeLibsSha256。",
                )
            }
            // 包结构：arm64-v8a/*.so（NOTICE.md 在包根）→ 只取 so，平铺进 jniLibs。
            // 条目名可能带反斜杠（PowerShell 的 Compress-Archive 就是这样），统一按 / 判定。
            var count = 0
            ZipInputStream(zip.inputStream().buffered()).use { zis ->
                var entry = zis.nextEntry
                while (entry != null) {
                    val name = entry.name.replace('\\', '/')
                    if (!entry.isDirectory && name.startsWith("arm64-v8a/") && name.endsWith(".so")) {
                        File(dir, name.substringAfterLast('/')).outputStream().use { out ->
                            zis.copyTo(out)
                        }
                        count++
                    }
                    zis.closeEntry()
                    entry = zis.nextEntry
                }
            }
            logger.lifecycle("原生库就位：$count 个 .so → ${dir.path}")
        } catch (e: Exception) {
            if (required.get()) {
                throw GradleException("正式 APK 必须包含预编译原生库，拒绝降级发布", e)
            }
            // 拉不到就拉倒：没有这些库也能编出可用的 Exo 内核包，不能让它挡住构建
            logger.lifecycle(
                "预编译原生库下载失败（${e.message}）。本次构建为**仅 Exo 内核**的 APK：" +
                    "没有 ISO / BDMV 原盘直读与 MPV 软解、HDR、ASS 特效字幕。联网后重跑即会重试。",
            )
        } finally {
            zip.delete()
        }
    }
}

/**
 * 发布附件地址与校验和（换版本改 gradle.properties 里那两行）。
 * 覆盖优先级：`-P` > `local.properties`（机器本地、不入库）> `gradle.properties` > 这里的默认值
 * ——所以镜像 / fork / 本地文件都不必改仓库里的文件（见 README 的「预编译依赖」一节）。
 */
fun localProperty(key: String): String? {
    val file = rootProject.file("local.properties")
    if (!file.isFile) return null
    return Properties().apply { file.inputStream().use(::load) }.getProperty(key)
}

val cliProperties = project.gradle.startParameter.projectProperties
val nativeLibsUrl: String = cliProperties["nativeLibsUrl"]
    ?: localProperty("nativeLibsUrl")
    ?: (findProperty("nativeLibsUrl") as String?)
    ?: "https://github.com/anlan-home/movieclaw-android-libs/releases/download/android-native-libs/movieclaw-android-native-arm64-v8a.zip"
val nativeLibsSha256: String = cliProperties["nativeLibsSha256"]
    ?: localProperty("nativeLibsSha256")
    ?: (findProperty("nativeLibsSha256") as String?)
    ?: "c64766c609d6e8b1096385e0fdac46ba810e06a30b81176d809ad96ff7277f72"

/** 跳过自动下载（离线打包用 -PskipNativeLibsDownload=true） */
val skipNativeLibsDownload = (findProperty("skipNativeLibsDownload") as String?) == "true"

val downloadNativeLibs = tasks.register<DownloadNativeLibsTask>("downloadNativeLibs") {
    group = "build"
    description = "下载并解压 arm64-v8a 预编译原生库（FFmpeg / mpv / libass）"
    zipUrl.set(nativeLibsUrl)
    zipSha256.set(nativeLibsSha256)
    required.set((findProperty("requireNativeLibs") as String?) == "true")
    targetDir.set(layout.projectDirectory.dir("src/main/jniLibs/arm64-v8a"))
    workDir.set(layout.buildDirectory.dir("tmp/nativeLibs"))
}

if (!skipNativeLibsDownload) {
    tasks.named("preBuild") { dependsOn(downloadNativeLibs) }
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
    testImplementation("org.robolectric:robolectric:4.16")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.10.2")
    testImplementation("com.squareup.okhttp3:mockwebserver:4.12.0")
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
    implementation(libs.okhttp)
    implementation(libs.okhttp.sse)
    implementation(libs.okhttp.logging)
    implementation(libs.kotlinx.serialization.json)

    implementation(libs.coil.compose)
    implementation(libs.coil.network.okhttp)

    // 本机通知的周期检查（纯客户端，不动服务端）
    implementation(libs.androidx.work.runtime)

    // 底栏玻璃的真背景模糊（内容层 hazeSource + 玻璃件 hazeEffect）
    implementation(libs.haze)

    implementation(libs.hilt.android)
    ksp(libs.hilt.compiler)
    implementation(libs.hilt.navigation.compose)

    // 播放内核(M1):Exo 直连 + 服务端 HLS;MPV 内核按设计方案 §6 接入
    implementation(libs.media3.exoplayer)
    implementation(libs.media3.hls)
    implementation(libs.media3.ui)
    // 后台播放与锁屏控制(M1d):MediaSessionService + MediaSession
    implementation(libs.media3.session)
}
