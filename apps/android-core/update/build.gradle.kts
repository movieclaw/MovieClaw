// App 自身更新：问自己的服务器有没有新版、经服务器下载 APK、校验后交给系统安装器（手机、电视共用）
plugins {
    id("com.android.library")
}

android {
    namespace = "io.movieclaw.core.update"
    compileSdk = 37
    defaultConfig { minSdk = 23 }
    testOptions.unitTests.isIncludeAndroidResources = true
    testOptions.unitTests.all {
        it.systemProperty("robolectric.dependency.repo.url", "https://repo.maven.apache.org/maven2")
    }
    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }
}

dependencies {
    implementation(shared.androidx.core)
    testImplementation(shared.robolectric)
    api(project(":core:network"))
    implementation(shared.kotlinx.coroutines.android)
    testImplementation(shared.junit)
    testImplementation(shared.okhttp.mockwebserver)
    testImplementation(shared.kotlinx.coroutines.test)
}
