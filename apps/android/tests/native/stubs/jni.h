#pragma once
#include <cstdlib>
#include <cstring>
#include <map>
#include <cassert>
#include <cstdint>
#define JNIEXPORT
#define JNICALL
#define JNI_TRUE 1
#define JNI_FALSE 0
#define JNI_OK 0
#define JNI_VERSION_1_6 0x00010006
using jboolean = bool;
using jlong = int64_t;
using jint = int;
using jclass = void *;
using jobject = void *;
using jstring = const char *;
using jmethodID = void *;
struct JNIEnv;
struct JavaVMAttachArgs { int version; const char *name; void *group; };
struct JavaVM {
    int AttachCurrentThread(JNIEnv **, JavaVMAttachArgs *) { return -1; }
    void DetachCurrentThread() {}
};
struct JNIEnv {
    JavaVM vm;
    std::map<jobject, int> refs;
    int GetJavaVM(JavaVM **out) { *out = &vm; return 0; }
    jobject NewGlobalRef(jobject value) { if (value) ++refs[value]; return value; }
    void DeleteGlobalRef(jobject value) { assert(refs[value] > 0); if (--refs[value] == 0) refs.erase(value); }
    const char *GetStringUTFChars(jstring value, void *) { return strdup(value); }
    void ReleaseStringUTFChars(jstring, const char *value) { free(const_cast<char *>(value)); }
    jstring NewStringUTF(const char *value) { return strdup(value); }
    void CallVoidMethod(jobject, jmethodID) {}
    jclass GetObjectClass(jobject value) { return value; }
    jmethodID GetMethodID(jclass, const char *, const char *) { return nullptr; }
};
