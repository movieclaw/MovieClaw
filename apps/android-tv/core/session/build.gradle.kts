// 会话：服务器探测、登录、账号库（AndroidKeyStore 加密令牌）
plugins {
    alias(libs.plugins.android.library)
    alias(libs.plugins.kotlin.serialization)
}

android {
    namespace = "io.movieclaw.androidtv.core.session"
    compileSdk = 37
    defaultConfig { minSdk = 23 }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    api(project(":core:network"))
    implementation(libs.kotlinx.coroutines.android)
    testImplementation(libs.junit)
}
