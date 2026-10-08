# Retrofit + kotlinx.serialization
-keepattributes Signature, InnerClasses, EnclosingMethod, *Annotation*
-keepclassmembers class kotlinx.serialization.json.** { *** Companion; }
-keepclasseswithmembers class kotlinx.serialization.json.** { kotlinx.serialization.KSerializer serializer(...); }
-keep,includedescriptorclasses class io.movieclaw.android.**$$serializer { *; }
-keepclassmembers class io.movieclaw.android.** { *** Companion; }
-keepclasseswithmembers class io.movieclaw.android.** { kotlinx.serialization.KSerializer serializer(...); }
# OkHttp / Retrofit
-dontwarn okhttp3.**
-dontwarn retrofit2.**
-keepclassmembers,allowshrinking,allowobfuscation interface * { @retrofit2.http.* <methods>; }
