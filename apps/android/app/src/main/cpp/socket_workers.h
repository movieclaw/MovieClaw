#pragma once

#include <atomic>
#include <functional>
#include <memory>
#include <mutex>
#include <thread>
#include <vector>
#include <sys/socket.h>
#include <unistd.h>

// 连接线程和 socket 归同一宿主所有。先 shutdown 打断阻塞 IO，join 完成后才可释放共享卷。
// handler 借用 fd，不负责 close；避免宿主关闭已复用成其他 socket 的旧 fd。
class SocketWorkers {
    struct Worker {
        int fd;
        std::atomic<bool> finished{false};
        std::thread thread;
        explicit Worker(int value) : fd(value) {}
    };
    std::mutex mutex_;
    bool stopping_ = false;
    std::vector<std::unique_ptr<Worker>> workers_;
public:
    void reset() {
        std::lock_guard<std::mutex> lock(mutex_);
        stopping_ = false;
    }
    bool start(int fd, std::function<void(int)> handler) {
        std::lock_guard<std::mutex> lock(mutex_);
        if (stopping_) { close(fd); return false; }
        // 已完成的请求及时回收，长时间播放不会累积 joinable 线程记录。
        for (auto it = workers_.begin(); it != workers_.end();) {
            if ((*it)->finished) {
                (*it)->thread.join();
                it = workers_.erase(it);
            } else ++it;
        }
        auto worker = std::make_unique<Worker>(fd);
        Worker *raw = worker.get();
        try {
            raw->thread = std::thread([this, raw, handler]() {
                handler(raw->fd);
                std::lock_guard<std::mutex> lock(mutex_);
                close(raw->fd);
                raw->fd = -1;
                raw->finished = true;
            });
        } catch (...) { close(fd); return false; }
        workers_.push_back(std::move(worker));
        return true;
    }
    void stopAndJoin() {
        std::vector<std::unique_ptr<Worker>> workers;
        {
            std::lock_guard<std::mutex> lock(mutex_);
            stopping_ = true;
            for (auto &worker : workers_) {
                if (worker->fd >= 0) shutdown(worker->fd, SHUT_RDWR);
            }
            workers.swap(workers_);
        }
        // 不持互斥等待：worker 收尾需要同一把锁，持锁 join 会死锁。
        for (auto &worker : workers) worker->thread.join();
    }
};
