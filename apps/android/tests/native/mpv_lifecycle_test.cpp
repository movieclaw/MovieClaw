#include <condition_variable>
#include <chrono>
#include <cassert>
#include <iostream>
#define HAS_MPV
#include "../../app/src/main/cpp/mpv_bridge.cpp"

struct FakeMpv {
    std::mutex mutex;
    std::condition_variable cv;
    bool wake = false;
    bool loaded = false;
    std::atomic<bool> waiting{false};
};
static bool failWid = false;
int main() {
    JNIEnv env;
    g_mpv_loaded = true;
    p_create = []() { return reinterpret_cast<mpv_handle *>(new FakeMpv); };
    p_init = [](mpv_handle *) { return 0; };
    p_setstr = [](mpv_handle *, const char *name, const char *) { return failWid && strcmp(name, "wid") == 0 ? -1 : 0; };
    p_logreq = [](mpv_handle *, const char *) { return 0; };
    p_error_string = [](int) { return "test error"; };
    p_av_set_java_vm = [](void *, void *) {};
    p_waitev = [](mpv_handle *handle, double) {
        auto *mpv = reinterpret_cast<FakeMpv *>(handle);
        std::unique_lock<std::mutex> lock(mpv->mutex);
        static thread_local mpv_event_stub event{};
        if (!mpv->loaded) {
            mpv->loaded = true; event.event_id = 8; return &event;
        }
        mpv->waiting = true;
        mpv->cv.wait(lock, [mpv] { return mpv->wake; });
        mpv->waiting = false;
        event.event_id = 0;
        return &event;
    };
    p_interrupt = [](mpv_handle *handle) {
        auto *mpv = reinterpret_cast<FakeMpv *>(handle);
        std::lock_guard<std::mutex> lock(mpv->mutex);
        mpv->wake = true; mpv->cv.notify_all();
    };
    p_terminate = [](mpv_handle *handle) {
        auto *mpv = reinterpret_cast<FakeMpv *>(handle);
        assert(!mpv->waiting); // Regression: never destroy a live wait_event client.
        delete mpv;
    };
    p_cmd = [](mpv_handle *, const char **) { return -1; };
    for (int attempt = 0; attempt < 200; ++attempt) {
        jobject firstSurface = reinterpret_cast<jobject>(1);
        jobject secondSurface = reinterpret_cast<jobject>(2);
        auto a = Java_io_movieclaw_android_core_playback_mpv_MpvNative_nativeCreate(&env, nullptr, firstSurface);
        auto b = Java_io_movieclaw_android_core_playback_mpv_MpvNative_nativeCreate(&env, nullptr, secondSurface);
        assert(a && b && env.refs.size() == 2);
        auto *fake = reinterpret_cast<FakeMpv *>(H(a));
        while (!fake->waiting) std::this_thread::yield();
        const char *generation = Java_io_movieclaw_android_core_playback_mpv_MpvNative_nativeGetProperty(&env, nullptr, a, "movieclaw-file-loaded");
        assert(strcmp(generation, "1") == 0);
        free(const_cast<char *>(generation));
        failWid = true;
        assert(!Java_io_movieclaw_android_core_playback_mpv_MpvNative_nativeAttachSurface(&env, nullptr, a, secondSurface));
        assert(I(a)->surface == firstSurface && env.refs[secondSurface] == 1);
        Java_io_movieclaw_android_core_playback_mpv_MpvNative_nativeDetachSurface(&env, nullptr, a);
        assert(env.refs[firstSurface] == 1); // Failed detach retains the still-referenced Surface.
        failWid = false;
        Java_io_movieclaw_android_core_playback_mpv_MpvNative_nativeCommand(&env, nullptr, a, "invalid-command");
        Java_io_movieclaw_android_core_playback_mpv_MpvNative_nativeDestroy(&env, nullptr, a);
        assert(env.refs.size() == 1 && env.refs[secondSurface] == 1);
        Java_io_movieclaw_android_core_playback_mpv_MpvNative_nativeDestroy(&env, nullptr, b);
        assert(env.refs.empty());
        failWid = true;
        auto failed = Java_io_movieclaw_android_core_playback_mpv_MpvNative_nativeCreate(&env, nullptr, firstSurface);
        assert(!failed && env.refs.empty()); // Failed attach joins and cleans up too.
        failWid = false;
    }
    std::cout << "MPV lifecycle: 200 cycles, per-instance Surface ownership and failed-create cleanup passed\n";
}
