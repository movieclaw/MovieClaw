/*
 * MovieClaw 播放器 NAPI 模块：ArkTS ↔ libmpv client API 桥接。
 *
 * 对应 scripts/mpv-ohos/ 交叉编译出的 libmpv.so（dex2oat/mpv OHOS 移植，
 * vo_gpu + --gpu-context=ohos(EGL) + hwdec=ohcodec + ao_ohaudio）。
 *
 * 设计要点：
 * - 事件泵：独立线程 mpv_wait_event，经 napi_threadsafe_function 推给 ArkTS；
 * - surfaceId 经 mpv 的 'wid' 选项传入（fork 的 ohos 输出层用它创建 OHNativeWindow）；
 * - 音频焦点：libmpv.so 里打补丁导出函数指针 mpv_ohos_interrupt_hook，
 *   initEngine 时赋值指向本文件的转发函数 → ArkTS 'audio-interrupt' 事件。
 */
#include <atomic>
#include <cstring>
#include <limits>
#include <map>
#include <mutex>
#include <pthread.h>
#include <string>
#include <vector>

#include "napi/native_api.h"
#include <mpv/client.h>

namespace {

struct MpvInstance {
  mpv_handle *mpv = nullptr;
  std::atomic<bool> shuttingDown{false};
  std::atomic<bool> initialized{false};
  napi_threadsafe_function tsfn = nullptr;
  pthread_t pump{};
  bool pumpStarted = false;
};

std::mutex g_mutex;
std::map<int64_t, MpvInstance *> g_instances;
int64_t g_nextId = 1;
/** 焦点中断钩子的目标集合（理论上同时只有一个播放器页；登记制避免多实例互相顶掉） */
std::vector<MpvInstance *> g_active;

/** 跨线程事件载荷（JS 线程消费后 delete） */
struct EventMsg {
  std::string type;   // 事件名
  std::string name;   // property 名 / log prefix
  std::string sval;   // 字符串值 / log text
  std::string s2;     // log level
  double dval = 0;    // double 值
  int ival = 0;       // flag 值 / end-file reason / audio hint
  int ival2 = 0;      // audio force type
};

void PostEvent(MpvInstance *inst, EventMsg &&msg) {
  if (inst->tsfn == nullptr) {
    return;
  }
  EventMsg *heap = new EventMsg(std::move(msg));
  napi_status st = napi_call_threadsafe_function(inst->tsfn, heap, napi_tsfn_nonblocking);
  if (st != napi_ok) {
    delete heap;
  }
}

/** audio/ao_ohaudio.c 补丁导出的钩子（libmpv.so 里的全局函数指针） */
extern "C" {
extern void (*mpv_ohos_interrupt_hook)(int type, int hint);
}

void SetString(napi_env env, napi_value obj, const char *key, const std::string &v) {
  napi_value val;
  napi_create_string_utf8(env, v.c_str(), v.length(), &val);
  napi_set_named_property(env, obj, key, val);
}

void SetInt(napi_env env, napi_value obj, const char *key, int32_t v) {
  napi_value val;
  napi_create_int32(env, v, &val);
  napi_set_named_property(env, obj, key, val);
}

void SetDouble(napi_env env, napi_value obj, const char *key, double v) {
  napi_value val;
  napi_create_double(env, v, &val);
  napi_set_named_property(env, obj, key, val);
}

/** TSFN 回调（JS 线程）：EventMsg → 普通对象 → 调 ArkTS 回调 */
void CallJs(napi_env env, napi_value jsCb, void * /*context*/, void *data) {
  EventMsg *msg = static_cast<EventMsg *>(data);
  if (msg == nullptr) {
    return;
  }
  if (env != nullptr && jsCb != nullptr) {
    napi_handle_scope scope;
    napi_open_handle_scope(env, &scope);
    do {
      napi_value obj;
      napi_create_object(env, &obj);
      SetString(env, obj, "event", msg->type);
      if (msg->type == "property-change") {
        SetString(env, obj, "name", msg->name);
        napi_value val;
        switch (msg->ival) { // ival 这里存 mpv_format
          case MPV_FORMAT_STRING:
            napi_create_string_utf8(env, msg->sval.c_str(), msg->sval.length(), &val);
            napi_set_named_property(env, obj, "value", val);
            break;
          case MPV_FORMAT_DOUBLE:
            napi_create_double(env, msg->dval, &val);
            napi_set_named_property(env, obj, "value", val);
            break;
          case MPV_FORMAT_FLAG:
            napi_get_boolean(env, msg->ival2 != 0, &val);
            napi_set_named_property(env, obj, "value", val);
            break;
          default:
            break; // MPV_FORMAT_NONE：属性暂不可用，不给 value
        }
        SetInt(env, obj, "format", msg->ival);
      } else if (msg->type == "end-file") {
        SetInt(env, obj, "reason", msg->ival);
      } else if (msg->type == "audio-interrupt") {
        SetInt(env, obj, "hint", msg->ival);
        SetInt(env, obj, "type", msg->ival2);
      } else if (msg->type == "log") {
        SetString(env, obj, "prefix", msg->name);
        SetString(env, obj, "level", msg->s2);
        SetString(env, obj, "text", msg->sval);
      }
      napi_value undefined;
      napi_get_undefined(env, &undefined);
      napi_call_function(env, undefined, jsCb, 1, &obj, nullptr);
    } while (false);
    napi_close_handle_scope(env, scope);
  }
  delete msg;
}

/** 事件泵：独立线程阻塞等事件；shuttingDown 或 SHUTDOWN 时退出 */
void *PumpThread(void *arg) {
  MpvInstance *inst = static_cast<MpvInstance *>(arg);
  while (!inst->shuttingDown.load()) {
    mpv_event *ev = mpv_wait_event(inst->mpv, 1.0);
    if (ev == nullptr) {
      continue;
    }
    mpv_event_id id = ev->event_id;
    if (id == MPV_EVENT_NONE) {
      continue;
    }
    if (id == MPV_EVENT_SHUTDOWN) {
      break;
    }
    EventMsg msg;
    bool post = true;
    switch (id) {
      case MPV_EVENT_START_FILE:
        msg.type = "start-file";
        break;
      case MPV_EVENT_END_FILE: {
        auto *e = static_cast<mpv_event_end_file *>(ev->data);
        msg.type = "end-file";
        msg.ival = static_cast<int>(e->reason);
        break;
      }
      case MPV_EVENT_FILE_LOADED:
        msg.type = "file-loaded";
        break;
      case MPV_EVENT_PLAYBACK_RESTART:
        msg.type = "playback-restart";
        break;
      case MPV_EVENT_VIDEO_RECONFIG:
        msg.type = "video-reconfig";
        break;
      case MPV_EVENT_IDLE:
        msg.type = "idle";
        break;
      case MPV_EVENT_PROPERTY_CHANGE: {
        auto *p = static_cast<mpv_event_property *>(ev->data);
        msg.type = "property-change";
        msg.name = p->name != nullptr ? p->name : "";
        msg.ival = static_cast<int>(p->format);
        switch (p->format) {
          case MPV_FORMAT_STRING:
            if (p->data != nullptr) {
              msg.sval = *(static_cast<char **>(p->data));
            }
            break;
          case MPV_FORMAT_DOUBLE:
            if (p->data != nullptr) {
              msg.dval = *(static_cast<double *>(p->data));
            }
            break;
          case MPV_FORMAT_FLAG:
            if (p->data != nullptr) {
              msg.ival2 = *(static_cast<int *>(p->data));
            }
            break;
          default:
            break; // MPV_FORMAT_NONE
        }
        break;
      }
      case MPV_EVENT_LOG_MESSAGE: {
        auto *m = static_cast<mpv_event_log_message *>(ev->data);
        // warn 及以上送 ArkTS（MpvPlayer 转 hilog）；info/debug 丢弃避免刷爆。
        // warn 必须转发：ohdec.c 的 HISI 10-bit 布局诊断走 AV_LOG_WARNING。
        if (m->level == nullptr || (strcmp(m->level, "error") != 0
            && strcmp(m->level, "fatal") != 0
            && strcmp(m->level, "warn") != 0)) {
          post = false;
          break;
        }
        msg.type = "log";
        msg.name = m->prefix != nullptr ? m->prefix : "";
        msg.s2 = m->level != nullptr ? m->level : "";
        msg.sval = m->text != nullptr ? m->text : "";
        break;
      }
      default:
        post = false;
        break;
    }
    if (post) {
      PostEvent(inst, std::move(msg));
    }
  }
  return nullptr;
}

MpvInstance *FindInstance(int64_t handle) {
  std::lock_guard<std::mutex> lock(g_mutex);
  auto it = g_instances.find(handle);
  return it != g_instances.end() ? it->second : nullptr;
}

// ---------- NAPI 导出 ----------

napi_value CreateEngine(napi_env env, napi_callback_info info) {
  (void)info;
  mpv_handle *mpv = mpv_create();
  if (mpv == nullptr) {
    napi_throw_error(env, nullptr, "mpv_create failed");
    return nullptr;
  }
  auto *inst = new MpvInstance();
  inst->mpv = mpv;
  std::lock_guard<std::mutex> lock(g_mutex);
  int64_t id = g_nextId++;
  g_instances[id] = inst;
  napi_value result;
  napi_create_int64(env, id, &result);
  return result;
}

napi_value InitEngine(napi_env env, napi_callback_info info) {
  size_t argc = 3;
  napi_value args[3];
  napi_value thisArg;
  void *data = nullptr;
  napi_get_cb_info(env, info, &argc, args, &thisArg, &data);
  if (argc < 3) {
    napi_throw_error(env, nullptr, "initEngine(handle, options, callback)");
    return nullptr;
  }
  int64_t handle = 0;
  napi_get_value_int64(env, args[0], &handle);
  MpvInstance *inst = FindInstance(handle);
  if (inst == nullptr || inst->mpv == nullptr) {
    napi_throw_error(env, nullptr, "bad engine handle");
    return nullptr;
  }

  // options: Record<string, string>，全部走 mpv_set_option_string（initialize 前生效）
  napi_value options = args[1];
  napi_value names;
  uint32_t count = 0;
  napi_get_property_names(env, options, &names);
  napi_get_array_length(env, names, &count);
  for (uint32_t i = 0; i < count; i++) {
    napi_value key, val;
    size_t klen = 0, vlen = 0;
    napi_get_element(env, names, i, &key);
    napi_get_property(env, options, key, &val);
    char kbuf[128] = {0};
    char vbuf[1024] = {0};
    napi_get_value_string_utf8(env, key, kbuf, sizeof(kbuf), &klen);
    napi_get_value_string_utf8(env, val, vbuf, sizeof(vbuf), &vlen);
    int err = mpv_set_option_string(inst->mpv, kbuf, vbuf);
    if (err < 0) {
      // 未知选项不该毁掉播放（例如 fork 版本差异），忽略并继续
      (void)err;
    }
  }

  int err = mpv_initialize(inst->mpv);
  if (err < 0) {
    napi_throw_error(env, nullptr, mpv_error_string(err));
    return nullptr;
  }
  inst->initialized.store(true);

  // warn 及以上进 JS（MpvPlayer 转 hilog），info 以下丢弃
  mpv_request_log_messages(inst->mpv, "warn");

  // 事件回调 → threadsafe function
  napi_value resource;
  napi_create_string_utf8(env, "mpvEvent", strlen("mpvEvent"), &resource);
  napi_create_threadsafe_function(env, args[2], nullptr, resource, 0, 1,
                                  nullptr, nullptr, nullptr, CallJs, &inst->tsfn);

  // 接上音频焦点钩子（libmpv.so 里 ao_ohaudio.c 补丁导出的函数指针）。
  // 钩子把中断广播给所有存活实例（登记制：先 init 的先收到；destroy 时注销自己）。
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_active.push_back(inst);
    mpv_ohos_interrupt_hook = [](int type, int hint) {
      std::vector<MpvInstance *> targets;
      {
        std::lock_guard<std::mutex> lock(g_mutex);
        targets = g_active;
      }
      for (MpvInstance *target : targets) {
        EventMsg msg;
        msg.type = "audio-interrupt";
        msg.ival = hint;
        msg.ival2 = type;
        PostEvent(target, std::move(msg));
      }
    };
  }

  if (pthread_create(&inst->pump, nullptr, PumpThread, inst) == 0) {
    inst->pumpStarted = true;
  }

  napi_value result;
  napi_get_boolean(env, true, &result);
  return result;
}

napi_value DestroyEngine(napi_env env, napi_callback_info info) {
  size_t argc = 1;
  napi_value args[1];
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  int64_t handle = 0;
  napi_get_value_int64(env, args[0], &handle);
  MpvInstance *inst = nullptr;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    auto it = g_instances.find(handle);
    if (it != g_instances.end()) {
      inst = it->second;
      g_instances.erase(it);
    }
    for (size_t i = 0; i < g_active.size(); i++) {
      if (g_active[i] == inst) {
        g_active.erase(g_active.begin() + static_cast<long>(i));
        break;
      }
    }
    if (g_active.empty()) {
      mpv_ohos_interrupt_hook = nullptr;
    }
  }
  if (inst == nullptr) {
    return nullptr;
  }
  inst->shuttingDown.store(true);
  if (inst->initialized.load() && inst->mpv != nullptr) {
    const char *quit[] = {"quit", nullptr};
    mpv_command(inst->mpv, quit);
  }
  if (inst->pumpStarted) {
    pthread_join(inst->pump, nullptr);
  }
  if (inst->tsfn != nullptr) {
    napi_release_threadsafe_function(inst->tsfn, napi_tsfn_release);
    inst->tsfn = nullptr;
  }
  if (inst->mpv != nullptr) {
    mpv_terminate_destroy(inst->mpv);
    inst->mpv = nullptr;
  }
  delete inst;
  return nullptr;
}

napi_value Command(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value args[2];
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  int64_t handle = 0;
  napi_get_value_int64(env, args[0], &handle);
  MpvInstance *inst = FindInstance(handle);
  if (inst == nullptr || inst->mpv == nullptr) {
    return nullptr;
  }
  uint32_t count = 0;
  napi_get_array_length(env, args[1], &count);
  std::vector<const char *> parts;
  std::vector<std::string> keep;
  keep.reserve(count);
  for (uint32_t i = 0; i < count; i++) {
    napi_value item;
    napi_get_element(env, args[1], i, &item);
    size_t len = 0;
    napi_get_value_string_utf8(env, item, nullptr, 0, &len);
    // 返回的 len 不含 NUL；缓冲区要多给 1 字节，否则末字符会被 NUL 顶掉（loadfile→loadfil）
    std::string s(len + 1, '\0');
    if (len > 0) {
      napi_get_value_string_utf8(env, item, &s[0], s.size(), &len);
    }
    s.resize(len);
    keep.push_back(std::move(s));
  }
  for (const auto &s : keep) {
    parts.push_back(s.c_str());
  }
  parts.push_back(nullptr);
  mpv_command(inst->mpv, parts.data());
  return nullptr;
}

napi_value SetPropertyString(napi_env env, napi_callback_info info) {
  size_t argc = 3;
  napi_value args[3];
  char name[128] = {0};
  char value[1024] = {0};
  size_t len = 0;
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  int64_t handle = 0;
  napi_get_value_int64(env, args[0], &handle);
  napi_get_value_string_utf8(env, args[1], name, sizeof(name), &len);
  napi_get_value_string_utf8(env, args[2], value, sizeof(value), &len);
  MpvInstance *inst = FindInstance(handle);
  if (inst != nullptr && inst->mpv != nullptr) {
    mpv_set_property_string(inst->mpv, name, value);
  }
  return nullptr;
}

napi_value SetPropertyNumber(napi_env env, napi_callback_info info) {
  size_t argc = 3;
  napi_value args[3];
  char name[128] = {0};
  size_t len = 0;
  double value = 0;
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  int64_t handle = 0;
  napi_get_value_int64(env, args[0], &handle);
  napi_get_value_string_utf8(env, args[1], name, sizeof(name), &len);
  napi_get_value_double(env, args[2], &value);
  MpvInstance *inst = FindInstance(handle);
  if (inst != nullptr && inst->mpv != nullptr) {
    mpv_set_property(inst->mpv, name, MPV_FORMAT_DOUBLE, &value);
  }
  return nullptr;
}

napi_value SetPropertyFlag(napi_env env, napi_callback_info info) {
  size_t argc = 3;
  napi_value args[3];
  char name[128] = {0};
  size_t len = 0;
  bool value = false;
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  int64_t handle = 0;
  napi_get_value_int64(env, args[0], &handle);
  napi_get_value_string_utf8(env, args[1], name, sizeof(name), &len);
  napi_get_value_bool(env, args[2], &value);
  MpvInstance *inst = FindInstance(handle);
  if (inst != nullptr && inst->mpv != nullptr) {
    int flag = value ? 1 : 0;
    mpv_set_property(inst->mpv, name, MPV_FORMAT_FLAG, &flag);
  }
  return nullptr;
}

napi_value GetPropertyString(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value args[2];
  char name[128] = {0};
  size_t len = 0;
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  int64_t handle = 0;
  napi_get_value_int64(env, args[0], &handle);
  napi_get_value_string_utf8(env, args[1], name, sizeof(name), &len);
  MpvInstance *inst = FindInstance(handle);
  char *result = nullptr;
  if (inst != nullptr && inst->mpv != nullptr) {
    result = mpv_get_property_string(inst->mpv, name);
  }
  napi_value out;
  if (result != nullptr) {
    napi_create_string_utf8(env, result, strlen(result), &out);
    mpv_free(result);
  } else {
    napi_get_null(env, &out);
  }
  return out;
}

napi_value GetPropertyNumber(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value args[2];
  char name[128] = {0};
  size_t len = 0;
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  int64_t handle = 0;
  napi_get_value_int64(env, args[0], &handle);
  napi_get_value_string_utf8(env, args[1], name, sizeof(name), &len);
  MpvInstance *inst = FindInstance(handle);
  double out = std::numeric_limits<double>::quiet_NaN();
  if (inst != nullptr && inst->mpv != nullptr) {
    mpv_get_property(inst->mpv, name, MPV_FORMAT_DOUBLE, &out);
  }
  napi_value result;
  napi_create_double(env, out, &result);
  return result;
}

napi_value GetPropertyFlag(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value args[2];
  char name[128] = {0};
  size_t len = 0;
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  int64_t handle = 0;
  napi_get_value_int64(env, args[0], &handle);
  napi_get_value_string_utf8(env, args[1], name, sizeof(name), &len);
  MpvInstance *inst = FindInstance(handle);
  int flag = 0;
  if (inst != nullptr && inst->mpv != nullptr) {
    mpv_get_property(inst->mpv, name, MPV_FORMAT_FLAG, &flag);
  }
  napi_value out;
  napi_get_boolean(env, flag != 0, &out);
  return out;
}

napi_value Observe(napi_env env, napi_callback_info info) {
  size_t argc = 3;
  napi_value args[3];
  char name[128] = {0};
  char fmt[32] = {0};
  size_t len = 0;
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  int64_t handle = 0;
  napi_get_value_int64(env, args[0], &handle);
  napi_get_value_string_utf8(env, args[1], name, sizeof(name), &len);
  napi_get_value_string_utf8(env, args[2], fmt, sizeof(fmt), &len);
  mpv_format format = MPV_FORMAT_NONE;
  if (strcmp(fmt, "string") == 0) {
    format = MPV_FORMAT_STRING;
  } else if (strcmp(fmt, "double") == 0) {
    format = MPV_FORMAT_DOUBLE;
  } else if (strcmp(fmt, "flag") == 0) {
    format = MPV_FORMAT_FLAG;
  }
  napi_value out;
  MpvInstance *inst = FindInstance(handle);
  if (inst != nullptr && inst->mpv != nullptr) {
    uint64_t id = mpv_observe_property(inst->mpv, 0, name, format);
    napi_create_int64(env, static_cast<int64_t>(id), &out);
  } else {
    napi_create_int64(env, 0, &out);
  }
  return out;
}

napi_value Unobserve(napi_env env, napi_callback_info info) {
  size_t argc = 2;
  napi_value args[2];
  napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
  int64_t handle = 0;
  int64_t id = 0;
  napi_get_value_int64(env, args[0], &handle);
  napi_get_value_int64(env, args[1], &id);
  MpvInstance *inst = FindInstance(handle);
  if (inst != nullptr && inst->mpv != nullptr) {
    mpv_unobserve_property(inst->mpv, static_cast<uint64_t>(id));
  }
  return nullptr;
}

napi_value ModuleInit(napi_env env, napi_value exports) {
  const napi_property_attributes flags =
      static_cast<napi_property_attributes>(napi_writable | napi_enumerable | napi_configurable);
  const napi_property_descriptor props[] = {
    {"createEngine", nullptr, CreateEngine, nullptr, nullptr, nullptr, flags, nullptr},
    {"initEngine", nullptr, InitEngine, nullptr, nullptr, nullptr, flags, nullptr},
    {"destroyEngine", nullptr, DestroyEngine, nullptr, nullptr, nullptr, flags, nullptr},
    {"command", nullptr, Command, nullptr, nullptr, nullptr, flags, nullptr},
    {"setPropertyString", nullptr, SetPropertyString, nullptr, nullptr, nullptr, flags, nullptr},
    {"setPropertyNumber", nullptr, SetPropertyNumber, nullptr, nullptr, nullptr, flags, nullptr},
    {"setPropertyFlag", nullptr, SetPropertyFlag, nullptr, nullptr, nullptr, flags, nullptr},
    {"getPropertyString", nullptr, GetPropertyString, nullptr, nullptr, nullptr, flags, nullptr},
    {"getPropertyNumber", nullptr, GetPropertyNumber, nullptr, nullptr, nullptr, flags, nullptr},
    {"getPropertyFlag", nullptr, GetPropertyFlag, nullptr, nullptr, nullptr, flags, nullptr},
    {"observe", nullptr, Observe, nullptr, nullptr, nullptr, flags, nullptr},
    {"unobserve", nullptr, Unobserve, nullptr, nullptr, nullptr, flags, nullptr},
  };
  napi_define_properties(env, exports, sizeof(props) / sizeof(props[0]), props);
  return exports;
}

napi_module g_mpvModule = {
  .nm_version = 1,
  .nm_flags = 0,
  .nm_filename = nullptr,
  .nm_register_func = ModuleInit,
  .nm_modname = "movieclaw_mpv",
  .nm_priv = nullptr,
  .reserved = {0},
};

} // namespace

extern "C" __attribute__((constructor)) void RegisterMovieClawMpvModule(void) {
  napi_module_register(&g_mpvModule);
}
