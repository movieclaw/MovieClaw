// All blocking libmpv operations run on NAPI workers. JS owns a numeric handle,
// workers own shared_ptr leases; release removes the handle before joining the pump.
#include <atomic>
#include <memory>
#include <mutex>
#include <map>
#include <string>
#include <thread>
#include <vector>
#include "napi/native_api.h"
#include <mpv/client.h>

namespace {
struct Engine {
  mpv_handle *mpv = nullptr;
  std::atomic<bool> closing{false};
  std::mutex operation;
  std::mutex events;
  napi_threadsafe_function callback = nullptr;
  std::thread pump;
};
struct Event {
  std::string type, name, text;
  double value = 0;
  int format = 0, code = 0, reason = 0;
};
std::mutex registryMutex;
std::map<int64_t, std::shared_ptr<Engine>> registry;
int64_t nextHandle = 1;
extern "C" { extern void (*mpv_ohos_interrupt_hook)(int type, int hint); }

std::string String(napi_env env, napi_value value) {
  size_t size = 0;
  napi_get_value_string_utf8(env, value, nullptr, 0, &size);
  std::string result(size + 1, '\0');
  napi_get_value_string_utf8(env, value, result.data(), result.size(), &size);
  result.resize(size);
  return result;
}
void Text(napi_env env, napi_value object, const char *key, const std::string &text) {
  napi_value value;
  napi_create_string_utf8(env, text.data(), text.size(), &value);
  napi_set_named_property(env, object, key, value);
}
void Number(napi_env env, napi_value object, const char *key, double number) {
  napi_value value;
  napi_create_double(env, number, &value);
  napi_set_named_property(env, object, key, value);
}
void Dispatch(napi_env env, napi_value callback, void *, void *data) {
  std::unique_ptr<Event> event(static_cast<Event *>(data));
  if (!env || !callback) return;
  napi_value object, undefined;
  napi_create_object(env, &object);
  Text(env, object, "type", event->type);
  Text(env, object, "name", event->name);
  Text(env, object, "text", event->text);
  Number(env, object, "value", event->value);
  Number(env, object, "code", event->code);
  Number(env, object, "reason", event->reason);
  napi_get_undefined(env, &undefined);
  napi_call_function(env, undefined, callback, 1, &object, nullptr);
}
void Post(Engine &engine, Event event) {
  std::lock_guard<std::mutex> lock(engine.events);
  if (engine.closing || !engine.callback) return;
  auto *message = new Event(std::move(event));
  if (napi_call_threadsafe_function(engine.callback, message,
      message->type == "ready" || message->type == "end" ? napi_tsfn_blocking : napi_tsfn_nonblocking) != napi_ok) delete message;
}
void Pump(Engine *engine) {
  while (!engine->closing) {
    mpv_event *raw = mpv_wait_event(engine->mpv, 0.2);
    if (!raw || raw->event_id == MPV_EVENT_NONE) continue;
    Event event;
    switch (raw->event_id) {
      case MPV_EVENT_SHUTDOWN: return;
      case MPV_EVENT_LOG_MESSAGE: {
        const auto *message = static_cast<mpv_event_log_message *>(raw->data);
        event.type = "diagnostic"; event.text = std::string(message->prefix) + ": " + message->text;
        break;
      }
      case MPV_EVENT_FILE_LOADED: event.type = "ready"; break;
      case MPV_EVENT_PLAYBACK_RESTART: event.type = "playbackRestart"; break;
      case MPV_EVENT_END_FILE: {
        const auto *end = static_cast<mpv_event_end_file *>(raw->data);
        event.type = "end"; event.reason = end->reason; event.code = end->error;
        break;
      }
      case MPV_EVENT_PROPERTY_CHANGE: {
        const auto *property = static_cast<mpv_event_property *>(raw->data);
        if (!property->data) continue;
        event.type = "property"; event.name = property->name;
        if (property->format == MPV_FORMAT_DOUBLE) event.value = *static_cast<double *>(property->data);
        else if (property->format == MPV_FORMAT_FLAG) event.value = *static_cast<int *>(property->data);
        else continue;
        break;
      }
      default: continue;
    }
    Post(*engine, std::move(event));
  }
}
void Interrupt(int type, int hint) {
  std::vector<std::shared_ptr<Engine>> targets;
  { std::lock_guard<std::mutex> lock(registryMutex);
    for (const auto &item : registry) targets.push_back(item.second); }
  for (const auto &engine : targets) {
    Event event; event.type = "interrupt"; event.code = hint; event.reason = type;
    Post(*engine, std::move(event));
  }
}

// Track lists use MPV_FORMAT_NODE; the human-readable STRING form is not JSON.
std::string Quote(const std::string &value) {
  std::string result = "\"";
  for (unsigned char c : value) {
    if (c == '"' || c == '\\') { result += '\\'; result += c; }
    else if (c < 32) { const char hex[] = "0123456789abcdef"; result += "\\u00"; result += hex[c >> 4]; result += hex[c & 15]; }
    else result += c;
  }
  return result + '"';
}
std::string Json(const mpv_node &node) {
  switch (node.format) {
    case MPV_FORMAT_STRING: return Quote(node.u.string ? node.u.string : "");
    case MPV_FORMAT_FLAG: return node.u.flag ? "true" : "false";
    case MPV_FORMAT_INT64: return std::to_string(node.u.int64);
    case MPV_FORMAT_DOUBLE: return std::to_string(node.u.double_);
    case MPV_FORMAT_NODE_ARRAY:
    case MPV_FORMAT_NODE_MAP: {
      bool map = node.format == MPV_FORMAT_NODE_MAP;
      std::string result = map ? "{" : "[";
      for (int i = 0; i < node.u.list->num; ++i) {
        if (i) result += ',';
        if (map) result += Quote(node.u.list->keys[i]) + ':';
        result += Json(node.u.list->values[i]);
      }
      return result + (map ? '}' : ']');
    }
    default: return "null";
  }
}
struct Work {
  napi_async_work work = nullptr;
  napi_deferred deferred = nullptr;
  std::shared_ptr<Engine> engine;
  std::string action, result;
  std::vector<std::string> args;
  std::vector<std::pair<std::string, std::string>> options;
  int error = 0;
};
void Execute(napi_env, void *data) {
  auto &work = *static_cast<Work *>(data);
  auto &engine = *work.engine;
  std::lock_guard<std::mutex> lock(engine.operation);
  if (work.action == "release") {
    if (engine.pump.joinable()) engine.pump.join();
    if (engine.mpv) { mpv_terminate_destroy(engine.mpv); engine.mpv = nullptr; }
    std::lock_guard<std::mutex> eventLock(engine.events);
    if (engine.callback) {
      napi_release_threadsafe_function(engine.callback, napi_tsfn_release);
      engine.callback = nullptr;
    }
    return;
  }
  if (engine.closing) { work.error = MPV_ERROR_UNINITIALIZED; return; }
  if (work.action == "init") {
    engine.mpv = mpv_create();
    if (!engine.mpv) { work.error = MPV_ERROR_UNINITIALIZED; return; }
    for (const auto &option : work.options) {
      work.error = mpv_set_option_string(engine.mpv, option.first.c_str(), option.second.c_str());
      if (work.error < 0) return;
    }
    work.error = mpv_initialize(engine.mpv);
    if (work.error < 0) return;
    mpv_request_log_messages(engine.mpv, "warn");
    uint64_t observer = 1;
    for (const char *property : {"time-pos", "duration", "width", "height", "demuxer-cache-duration"}) {
      work.error = mpv_observe_property(engine.mpv, observer++, property, MPV_FORMAT_DOUBLE);
      if (work.error < 0) return;
    }
    for (const char *property : {"pause", "paused-for-cache", "eof-reached"}) {
      work.error = mpv_observe_property(engine.mpv, observer++, property, MPV_FORMAT_FLAG);
      if (work.error < 0) return;
    }
    try { engine.pump = std::thread(Pump, &engine); }
    catch (...) { work.error = MPV_ERROR_GENERIC; }
  } else if (!engine.mpv) {
    work.error = MPV_ERROR_UNINITIALIZED;
  } else if (work.action == "tracks") {
    mpv_node node{};
    work.error = mpv_get_property(engine.mpv, "track-list", MPV_FORMAT_NODE, &node);
    if (work.error >= 0) { work.result = Json(node); mpv_free_node_contents(&node); }
  } else {
    std::vector<const char *> args;
    for (const auto &arg : work.args) args.push_back(arg.c_str());
    args.push_back(nullptr);
    work.error = mpv_command(engine.mpv, args.data());
  }
}
void Complete(napi_env env, napi_status status, void *data) {
  std::unique_ptr<Work> work(static_cast<Work *>(data));
  napi_value value;
  if (status != napi_ok || work->error < 0) {
    napi_value message;
    napi_create_string_utf8(env, "Native player operation failed", NAPI_AUTO_LENGTH, &message);
    napi_create_error(env, nullptr, message, &value);
    Number(env, value, "code", work->error);
    napi_reject_deferred(env, work->deferred, value);
  } else {
    if (work->action == "tracks") napi_create_string_utf8(env, work->result.data(), work->result.size(), &value);
    else napi_get_undefined(env, &value);
    napi_resolve_deferred(env, work->deferred, value);
  }
  napi_delete_async_work(env, work->work);
}
napi_value Queue(napi_env env, Work *work) {
  napi_value promise, name;
  napi_create_promise(env, &work->deferred, &promise);
  napi_create_string_utf8(env, "movieclawPlayer", NAPI_AUTO_LENGTH, &name);
  napi_status status = napi_create_async_work(env, nullptr, name, Execute, Complete, work, &work->work);
  if (status == napi_ok) status = napi_queue_async_work(env, work->work);
  if (status != napi_ok) Complete(env, status, work);
  return promise;
}
napi_value Create(napi_env env, napi_callback_info) {
  std::lock_guard<std::mutex> lock(registryMutex);
  int64_t handle = nextHandle++;
  registry[handle] = std::make_shared<Engine>();
  napi_value value; napi_create_int64(env, handle, &value); return value;
}
napi_value Operation(napi_env env, napi_callback_info info) {
  size_t count = 3; napi_value args[3]; void *action = nullptr;
  napi_get_cb_info(env, info, &count, args, nullptr, &action);
  int64_t handle = 0;
  if (count == 0 || napi_get_value_int64(env, args[0], &handle) != napi_ok) {
    napi_throw_type_error(env, nullptr, "Invalid player handle"); return nullptr;
  }
  auto work = std::make_unique<Work>(); work->action = static_cast<const char *>(action);
  {
    std::lock_guard<std::mutex> lock(registryMutex);
    auto it = registry.find(handle);
    if (it == registry.end()) { napi_throw_error(env, nullptr, "Released player handle"); return nullptr; }
    work->engine = it->second;
    if (work->action == "release") { work->engine->closing = true; registry.erase(it); }
  }
  if (work->action == "init") {
    if (count < 3) { napi_throw_type_error(env, nullptr, "Expected options and callback"); return nullptr; }
    napi_value keys; uint32_t length = 0;
    napi_get_property_names(env, args[1], &keys); napi_get_array_length(env, keys, &length);
    for (uint32_t i = 0; i < length; i++) {
      napi_value key, value; napi_get_element(env, keys, i, &key); napi_get_property(env, args[1], key, &value);
      work->options.emplace_back(String(env, key), String(env, value));
    }
    napi_value name; napi_create_string_utf8(env, "movieclawEvents", NAPI_AUTO_LENGTH, &name);
    napi_threadsafe_function callback = nullptr;
    if (napi_create_threadsafe_function(env, args[2], nullptr, name, 256, 1,
        nullptr, nullptr, nullptr, Dispatch, &callback) != napi_ok) {
      napi_throw_error(env, nullptr, "Cannot create player event queue"); return nullptr;
    }
    { std::lock_guard<std::mutex> lock(work->engine->events); work->engine->callback = callback; }
  } else if (work->action == "command") {
    if (count < 2) { napi_throw_type_error(env, nullptr, "Expected command"); return nullptr; }
    uint32_t length = 0; napi_get_array_length(env, args[1], &length);
    for (uint32_t i = 0; i < length; i++) { napi_value value; napi_get_element(env, args[1], i, &value); work->args.push_back(String(env, value)); }
  }
  return Queue(env, work.release());
}
napi_value Init(napi_env env, napi_value exports) {
  // Install once. The callback never captures raw instance pointers.
  mpv_ohos_interrupt_hook = Interrupt;
  const napi_property_descriptor properties[] = {
    {"createEngine", nullptr, Create, nullptr, nullptr, nullptr, napi_default, nullptr},
    {"initEngine", nullptr, Operation, nullptr, nullptr, nullptr, napi_default, (void *)"init"},
    {"command", nullptr, Operation, nullptr, nullptr, nullptr, napi_default, (void *)"command"},
    {"tracks", nullptr, Operation, nullptr, nullptr, nullptr, napi_default, (void *)"tracks"},
    {"destroyEngine", nullptr, Operation, nullptr, nullptr, nullptr, napi_default, (void *)"release"}
  };
  napi_define_properties(env, exports, sizeof(properties) / sizeof(properties[0]), properties);
  return exports;
}
napi_module module = {1, 0, nullptr, Init, "movieclaw_mpv", nullptr, {0}};
}
extern "C" __attribute__((constructor)) void RegisterMovieClawMpvModule() { napi_module_register(&module); }
