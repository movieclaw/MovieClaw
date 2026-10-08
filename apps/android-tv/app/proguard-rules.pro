# kotlinx.serialization：生成的 @Serializable 模型靠编译期生成的 serializer，按官方规则保留
-keepattributes *Annotation*, InnerClasses
-keepclassmembers @kotlinx.serialization.Serializable class ** {
    *** Companion;
    kotlinx.serialization.KSerializer serializer(...);
}
