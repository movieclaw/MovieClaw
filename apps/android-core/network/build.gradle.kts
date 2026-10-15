import org.jetbrains.kotlin.gradle.dsl.JvmTarget

// 网络层：OkHttp 传输、信封拆包、错误、客户端标识、图片地址；生成的 McApi 在 generated/
plugins {
    id("org.jetbrains.kotlin.jvm")
    id("org.jetbrains.kotlin.plugin.serialization")
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

kotlin {
    compilerOptions { jvmTarget.set(JvmTarget.JVM_17) }
}

dependencies {
    api(project(":core:model"))
    api(shared.okhttp)
    api(shared.kotlinx.coroutines.core)
    testImplementation(shared.junit)
    testImplementation(shared.okhttp.mockwebserver)
    testImplementation(shared.kotlinx.coroutines.test)
}
