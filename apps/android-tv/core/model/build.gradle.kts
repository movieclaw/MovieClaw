import org.jetbrains.kotlin.gradle.dsl.JvmTarget

// 接口数据模型：纯 Kotlin，生成物在 generated/（apps/android-tv/scripts/gen_api.py）
plugins {
    alias(libs.plugins.kotlin.jvm)
    alias(libs.plugins.kotlin.serialization)
}

java {
    sourceCompatibility = JavaVersion.VERSION_17
    targetCompatibility = JavaVersion.VERSION_17
}

kotlin {
    compilerOptions { jvmTarget.set(JvmTarget.JVM_17) }
}

dependencies {
    api(libs.kotlinx.serialization.json)
}
