#include <cassert>
#include <chrono>
#include <iostream>
#include <thread>
#include <atomic>
#include <dirent.h>
#include "../../app/src/main/cpp/iso_native.cpp"

// 卷夹具只替代 UDF 解析：真实生产 accept/连接线程、远端socket、shutdown 和缓冲释放均参与测试。
struct udfread { int magic = 1234; std::atomic<int> files{0}; };
struct udfread_file { udfread *volume; };
struct udfread_dir { bool emitted = false; };
static std::atomic<int> volumes{0};
static std::atomic<int> blockedReads{0};
extern "C" {
udfread *udfread_init() { ++volumes; return new udfread; }
int udfread_open_input(udfread *, udfread_block_input *) { return 0; }
void udfread_close(udfread *v) { assert(v->magic == 1234 && v->files == 0); v->magic = 0; delete v; --volumes; }
UDFDIR *udfread_opendir(udfread *, const char *) { return new udfread_dir; }
udfread_dirent *udfread_readdir(UDFDIR *dir, udfread_dirent *entry) {
    if (dir->emitted) return nullptr;
    dir->emitted = true; entry->d_name = "00001.m2ts"; entry->d_type = UDF_DT_REG; return entry;
}
void udfread_closedir(UDFDIR *dir) { delete dir; }
UDFFILE *udfread_file_open(udfread *v, const char *) { assert(v && v->magic == 1234); ++v->files; return new udfread_file{v}; }
int64_t udfread_file_size(UDFFILE *) { return 1024; }
void udfread_file_close(UDFFILE *f) { assert(f->volume->magic == 1234); --f->volume->files; delete f; }
int64_t udfread_file_seek(UDFFILE *, int64_t pos, int) { return pos; }
ssize_t udfread_file_read(UDFFILE *f, void *buf, size_t) {
    ++blockedReads;
    // 远端夹具不回复此 Range，生产 shutdown 必须打断 recv，之后才可释放卷。
    int result = http_read_range(16, static_cast<uint8_t *>(buf), 16);
    assert(f->volume->magic == 1234);
    --blockedReads;
    return result < 0 ? 0 : 16;
}
}
static int makeListener(int *port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0); assert(fd >= 0);
    sockaddr_in addr{}; addr.sin_family = AF_INET; addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    assert(bind(fd, reinterpret_cast<sockaddr *>(&addr), sizeof(addr)) == 0);
    assert(listen(fd, 8) == 0);
    socklen_t len = sizeof(addr); getsockname(fd, reinterpret_cast<sockaddr *>(&addr), &len);
    *port = ntohs(addr.sin_port); return fd;
}
static int connectLocal(int port) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    sockaddr_in addr{}; addr.sin_family = AF_INET; addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK); addr.sin_port = htons(port);
    assert(connect(fd, reinterpret_cast<sockaddr *>(&addr), sizeof(addr)) == 0); return fd;
}
static int countDescriptors() {
    DIR *dir = opendir("/proc/self/fd"); assert(dir);
    int count = 0; while (readdir(dir)) ++count;
    closedir(dir); return count;
}
int main() {
    JNIEnv env;
    const int descriptorsBefore = countDescriptors();
    int port;
    int remote = makeListener(&port);
    std::atomic<bool> running{true};
    std::thread fixture([&] {
        while (running) {
            int fd = accept(remote, nullptr, nullptr); if (fd < 0) break;
            char header[4096]; if (recv_header(fd, header, sizeof(header)) >= 0) {
                if (strstr(header, "bytes=0-15")) {
                    const char *reply = "HTTP/1.1 206 Partial Content\r\nContent-Range: bytes 0-15/4096\r\nContent-Length: 16\r\n\r\n0123456789abcdef";
                    send(fd, reply, strlen(reply), MSG_NOSIGNAL);
                } else { char byte; recv(fd, &byte, 1, 0); }
            }
            close(fd);
        }
    });
    std::string url = "http://127.0.0.1:" + std::to_string(port) + "/image.iso";
    assert(!Java_io_movieclaw_android_core_playback_IsoBridge_nativeOpenIso(&env, nullptr, "https://example.org/image.iso"));
    for (int attempt = 0; attempt < 60; ++attempt) {
        const char *local = Java_io_movieclaw_android_core_playback_IsoBridge_nativeOpenIso(&env, nullptr, url.c_str());
        assert(local && volumes == 1);
        free(const_cast<char *>(local));
        int client = connectLocal(g_server_port);
        if (attempt % 2 == 0) {
            const char *request = "GET /stream.m2ts HTTP/1.1\r\n\r\n";
            send(client, request, strlen(request), MSG_NOSIGNAL);
            auto until = std::chrono::steady_clock::now() + std::chrono::seconds(2);
            while (blockedReads == 0 && std::chrono::steady_clock::now() < until) std::this_thread::yield();
            assert(blockedReads == 1);
        } // Odd cycles: worker is parked in recv waiting for the request header.
        auto start = std::chrono::steady_clock::now();
        Java_io_movieclaw_android_core_playback_IsoBridge_nativeCloseIso(&env, nullptr);
        assert(std::chrono::steady_clock::now() - start < std::chrono::seconds(2));
        assert(volumes == 0 && blockedReads == 0 && !g_server_thread_running && !g_ra_thread_running);
        for (auto *buffer : g_ra_buf) assert(!buffer);
        close(client);
    }
    // Consecutive open without close must retire the previous listener/volume first.
    const char *one = Java_io_movieclaw_android_core_playback_IsoBridge_nativeOpenIso(&env, nullptr, url.c_str());
    const char *two = Java_io_movieclaw_android_core_playback_IsoBridge_nativeOpenIso(&env, nullptr, url.c_str());
    assert(one && two && volumes == 1);
    free(const_cast<char *>(one)); free(const_cast<char *>(two));
    Java_io_movieclaw_android_core_playback_IsoBridge_nativeCloseIso(&env, nullptr);
    Java_io_movieclaw_android_core_playback_IsoBridge_nativeCloseIso(&env, nullptr);
    assert(volumes == 0);
    running = false; shutdown(remote, SHUT_RDWR); fixture.join(); close(remote);
    assert(countDescriptors() == descriptorsBefore);
    // 背压写入也必须能停止：未读取的 socketpair 令 send 阻塞。
    SocketWorkers workers;
    for (int attempt = 0; attempt < 30; ++attempt) {
        workers.reset();
        int pair[2]; assert(socketpair(AF_UNIX, SOCK_STREAM, 0, pair) == 0);
        int small = 1024; setsockopt(pair[0], SOL_SOCKET, SO_SNDBUF, &small, sizeof(small));
        std::atomic<bool> started{false};
        assert(workers.start(pair[0], [&](int fd) {
            char bytes[65536]{}; started = true;
            while (send(fd, bytes, sizeof(bytes), MSG_NOSIGNAL) > 0) {}
        }));
        while (!started) std::this_thread::yield();
        std::this_thread::sleep_for(std::chrono::milliseconds(2));
        auto start = std::chrono::steady_clock::now();
        workers.stopAndJoin();
        assert(std::chrono::steady_clock::now() - start < std::chrono::seconds(2));
        close(pair[1]);
    }
    assert(countDescriptors() == descriptorsBefore);
    std::cout << "ISO lifecycle: 60 blocked-read/header cycles, 30 blocked-send cycles, reopen/repeated-close/no-fd-leak passed\n";
}
