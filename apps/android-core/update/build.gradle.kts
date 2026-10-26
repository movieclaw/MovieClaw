// App 自身更新：问自己的服务器有没有新版、经服务器下载 APK、校验后交给系统安装器（手机、电视共用）
plugins {
    id("com.android.library")
}

android {
    namespace = "io.movieclaw.core.update"
    compileSdk = 37
    defaultConfig { minSdk = 23 }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    api(project(":core:network"))
    implementation(shared.kotlinx.coroutines.android)
    testImplementation(shared.junit)
    testImplementation(shared.okhttp.mockwebserver)
    testImplementation(shared.kotlinx.coroutines.test)
}
