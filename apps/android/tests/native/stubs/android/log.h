#pragma once
#include <cstdarg>
#include <cstdio>
#define ANDROID_LOG_INFO 1
#define ANDROID_LOG_WARN 2
#define ANDROID_LOG_ERROR 3
inline int __android_log_print(int, const char *, const char *format, ...) {
    char message[4096];
    va_list args; va_start(args, format);
    int n = vsnprintf(message, sizeof(message), format, args);
    va_end(args); return n;
}
