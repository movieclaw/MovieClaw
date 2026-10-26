import org.jetbrains.kotlin.gradle.dsl.JvmTarget

// 接口数据模型：纯 Kotlin，生成物在 generated/（apps/android-core/scripts/gen_api.py）
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
    api(shared.kotlinx.serialization.json)
}
