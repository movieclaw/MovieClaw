#![cfg_attr(not(debug_assertions), windows_subsystem = "windows")]

mod about;
mod api_proxy;
mod connect;
mod credential_vault;
mod lan_discovery;
mod media_stream;
mod mpv_ipc;
mod native_auth;
mod native_playback_platform;
mod player_embedded;
mod updater;

use std::sync::atomic::{AtomicU8, Ordering};
use tauri::{Manager, WebviewUrl, WebviewWindowBuilder};

// 0 = running, 1 = JS flushing, 2 = cleanup queued, 3 = cleanup complete.
static SHUTDOWN: AtomicU8 = AtomicU8::new(0);

fn shutdown_trace(phase: &str) {
    if std::env::var("MOVIECLAW_DIAGNOSTICS").as_deref() != Ok("1") {
        return;
    }
    use std::io::Write;
    if let Ok(mut file) = std::fs::OpenOptions::new()
        .create(true)
        .append(true)
        .open(connect::config_dir().join("shutdown.log"))
    {
        let _ = writeln!(file, "{phase}");
    }
}

fn finish_shutdown(app: tauri::AppHandle) {
    if SHUTDOWN
        .compare_exchange(1, 2, Ordering::SeqCst, Ordering::SeqCst)
        .is_err()
    {
        return;
    }
    shutdown_trace("cleanup-queued");
    // Never dispatch inline while inside a Tauri window/IPC callback. The Wry
    // dispatcher can execute main-thread tasks immediately and re-enter locks.
    std::thread::spawn(move || {
        native_auth::retire_for_shutdown();
        api_proxy::cancel_all_requests();
        media_stream::revoke_all();
        tauri::async_runtime::spawn(async move {
            let settled =
                updater::verified::cancel_all_and_wait(std::time::Duration::from_millis(750)).await;
            shutdown_trace(if settled {
                "update-cleanup-settled"
            } else {
                "update-cleanup-deadline"
            });
            let cleanup_app = app.clone();
            if app
                .run_on_main_thread(move || {
                    shutdown_trace("native-cleanup-started");
                    native_playback_platform::shutdown(&cleanup_app);
                    let _ = player_embedded::stop_embedded_player(None);
                    SHUTDOWN.store(3, Ordering::SeqCst);
                    shutdown_trace("native-exit-requested");
                    cleanup_app.exit(0);
                })
                .is_err()
            {
                shutdown_trace("native-dispatch-failed");
            }
        });
    });
}

fn request_shutdown(app: &tauri::AppHandle) {
    if SHUTDOWN
        .compare_exchange(0, 1, Ordering::SeqCst, Ordering::SeqCst)
        .is_err()
    {
        return;
    }
    shutdown_trace("shutdown-requested");
    // Start the deadline before contacting WebView2. The close event callback
    // must return before any work attempts to acquire the window again.
    let fallback_app = app.clone();
    std::thread::spawn(move || {
        std::thread::sleep(std::time::Duration::from_millis(1500));
        shutdown_trace("deadline-reached");
        finish_shutdown(fallback_app);
    });
    let script_app = app.clone();
    std::thread::spawn(move || {
        shutdown_trace("js-dispatch");
        if let Some(window) = script_app.get_webview_window("main") {
            let result = window.eval(r#"Promise.resolve().then(() => window.__MOVIECLAW_SHUTDOWN__?.()).catch(() => {}).finally(() => window.__TAURI__.core.invoke("complete_shutdown"))"#);
            shutdown_trace(if result.is_ok() {
                "js-eval-queued"
            } else {
                "js-eval-failed"
            });
        }
    });
}

#[tauri::command]
fn complete_shutdown(app: tauri::AppHandle) {
    finish_shutdown(app);
}

#[tauri::command]
fn native_ready(app: tauri::AppHandle) -> Result<&'static str, String> {
    shutdown_trace("bridge-ready");
    if std::env::var("MOVIECLAW_DIAGNOSTICS").as_deref() == Ok("1") {
        std::fs::write(
            connect::config_dir().join("native-ready.json"),
            serde_json::json!({"version":env!("CARGO_PKG_VERSION"),"ready":true}).to_string(),
        )
        .map_err(|_| "无法写入启动诊断")?;
    }
    native_playback_platform::diagnostic_probe(app);
    Ok(env!("CARGO_PKG_VERSION"))
}

#[tauri::command]
fn get_app_version() -> &'static str {
    env!("CARGO_PKG_VERSION")
}

/// 获取主窗口 HWND
#[tauri::command]
fn get_main_window_hwnd(window: tauri::WebviewWindow) -> Result<isize, String> {
    #[cfg(target_os = "windows")]
    {
        use raw_window_handle::{HasWindowHandle, RawWindowHandle};
        match window.window_handle() {
            Ok(handle) => {
                if let RawWindowHandle::Win32(win32) = handle.as_raw() {
                    return Ok(win32.hwnd.get() as isize);
                }
                Err("无法获取窗口句柄".into())
            }
            Err(e) => Err(format!("获取窗口句柄失败: {e}")),
        }
    }
    #[cfg(not(target_os = "windows"))]
    {
        let _ = window;
        Err("仅支持 Windows".into())
    }
}

fn main() {
    shutdown_trace("main-start");
    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _args, _cwd| {
            if let Some(window) = app.get_webview_window("main") {
                let _ = window.set_focus();
            }
        }))
        .plugin(tauri_plugin_shell::init())
        .plugin(tauri_plugin_http::init())
        .setup(|app| {
            shutdown_trace("setup-enter");
            let start_url = connect::load_server_url().unwrap_or_default();
            let url = if start_url.is_empty() {
                WebviewUrl::App("connect.html".into())
            } else {
                WebviewUrl::App("desktop/index.html".into())
            };

            shutdown_trace("window-build-started");
            WebviewWindowBuilder::new(app, "main", url)
                .title("MovieClaw")
                .inner_size(1280.0, 800.0)
                .min_inner_size(960.0, 600.0)
                .center()
                .decorations(false)
                .build()?;
            shutdown_trace("window-built");

            // 系统托盘图标
            {
                shutdown_trace("tray-started");
                use tauri::tray::{TrayIconBuilder, TrayIconEvent};
                use tauri::menu::{Menu, MenuItem};

                let show = MenuItem::with_id(app, "show", "显示主窗口", true, None::<&str>)?;
                let reconnect = MenuItem::with_id(app, "reconnect", "更改服务器", true, None::<&str>)?;
                let check_update = MenuItem::with_id(app, "check_update", "检查更新", true, None::<&str>)?;
                let quit = MenuItem::with_id(app, "quit", "退出", true, None::<&str>)?;
                let menu = Menu::with_items(app, &[&show, &reconnect, &check_update, &quit])?;

                let _tray = TrayIconBuilder::with_id("main")
                    .icon(app.default_window_icon().unwrap().clone())
                    .menu(&menu)
                    .show_menu_on_left_click(false)
                    .on_menu_event(|app, event| match event.id.as_ref() {
                        "show" => {
                            if let Some(w) = app.get_webview_window("main") {
                                let _ = w.show();
                                let _ = w.set_focus();
                            }
                        }
                        "reconnect" => {
                            if let Some(w) = app.get_webview_window("main") {
                                let _ = w.show();
                                let _ = w.eval(r#"Promise.resolve().then(() => window.__MOVIECLAW_CHANGE_SERVER__ ? window.__MOVIECLAW_CHANGE_SERVER__() : window.__TAURI__.core.invoke("clear_server_url").then(() => { window.location.href = "/connect.html"; }))"#);
                                let _ = w.set_focus();
                            }
                        }
                        "check_update" => {
                            let app_handle = app.clone();
                            tauri::async_runtime::spawn(async move {
                                match updater::check_for_updates().await {
                                    Ok(info) => {
                                        if info.has_update {
                                            // 显示更新提示：弹窗 + 打开下载页
                                            use tauri::Emitter;
                                            let _ = app_handle.emit("update_available", serde_json::json!({
                                                "version": info.latest_version,
                                                "current": info.current_version,
                                                "message": info.message,
                                                "download_url": info.download_url,
                                                "release_notes": info.release_notes
                                            }));
                                        } else {
                                            use tauri::Emitter;
                                            let _ = app_handle.emit("update_check_result", serde_json::json!({
                                                "has_update": false,
                                                "message": info.message
                                            }));
                                        }
                                    }
                                    Err(e) => {
                                        use tauri::Emitter;
                                        let _ = app_handle.emit("update_check_result", serde_json::json!({
                                            "has_update": false,
                                            "message": format!("检查更新失败: {e}")
                                        }));
                                    }
                                }
                            });
                        }
                        "quit" => {
                            request_shutdown(app);
                        }
                        _ => {}
                    })
                    .on_tray_icon_event(|tray, event| {
                        if let TrayIconEvent::DoubleClick { .. } = event {
                            let app = tray.app_handle();
                            if let Some(w) = app.get_webview_window("main") {
                                let _ = w.show();
                                let _ = w.set_focus();
                            }
                        }
                    })
                    .build(app)?;
                shutdown_trace("tray-built");
            }

            // 启动后静默检查更新（延迟 5 秒，不影响启动速度）
            {
                let app_handle = app.handle().clone();
                tauri::async_runtime::spawn(async move {
                    tokio::time::sleep(std::time::Duration::from_secs(5)).await;
                    if let Ok(info) = updater::check_for_updates().await {
                        if info.has_update {
                            use tauri::Emitter;
                            let _ = app_handle.emit("update_available", serde_json::json!({
                                "version": info.latest_version,
                                "current": info.current_version,
                                "message": info.message,
                                "download_url": info.download_url,
                                "release_notes": info.release_notes
                            }));
                        }
                    }
                });
            }

            shutdown_trace("setup-ready");
            Ok(())
        })
        .on_window_event(|window, event| {
            if matches!(event, tauri::WindowEvent::ScaleFactorChanged { .. } | tauri::WindowEvent::Resized(_)) {
                native_playback_platform::window_changed(window);
            }
            if let tauri::WindowEvent::CloseRequested { api, .. } = event {
                shutdown_trace("close-requested");
                if SHUTDOWN.load(Ordering::SeqCst) != 3 {
                    api.prevent_close();
                    request_shutdown(window.app_handle());
                }
            }
        })
        .invoke_handler(tauri::generate_handler![
            native_auth::native_auth_status,
            native_auth::native_password_login,
            native_auth::native_select_account,
            native_auth::native_remove_account,
            native_auth::native_logout,
            native_auth::native_pair_begin,
            native_auth::native_pair_poll,
            native_auth::native_pair_cancel,
            media_stream::grant_media_stream,
            media_stream::release_media_stream,
            media_stream::renew_media_stream,
            native_playback_platform::begin_native_playback,
            native_playback_platform::update_native_playback,
            native_playback_platform::end_native_playback,
            native_playback_platform::set_native_picture_in_picture,
            native_ready,
            complete_shutdown,
            get_app_version,
            about::get_about_info,
            connect::save_server_url,
            connect::load_server_url,
            connect::clear_server_url,
            connect::get_server_url,
            connect::probe_server,
            updater::check_for_updates,
            updater::open_download_page,
            updater::open_release_page,
            connect::open_server_ai_settings,
            updater::verified::download_update,
            updater::verified::cancel_update_download,
            updater::verified::install_downloaded_update,
            updater::verified::open_downloaded_update,
            api_proxy::proxy_api,
            api_proxy::cancel_proxy_request,
            get_main_window_hwnd,
            lan_discovery::discover_servers,
            player_embedded::has_embedded_player,
            player_embedded::get_embedded_player_status,
            player_embedded::get_embedded_player_state,
            player_embedded::launch_embedded_player,
            player_embedded::resize_embedded_player,
            player_embedded::set_embedded_player_visible,
            player_embedded::stop_embedded_player,
            player_embedded::send_mpv_command_embedded,
        ])
        .build(tauri::generate_context!())
        .expect("error while building MovieClaw Desktop")
        .run(|app, event| {
            if let tauri::RunEvent::Ready = event { shutdown_trace("run-ready"); }
            if let tauri::RunEvent::ExitRequested { api, .. } = event {
                shutdown_trace("exit-requested-event");
                if SHUTDOWN.load(Ordering::SeqCst) != 3 {
                    api.prevent_exit();
                    request_shutdown(app);
                }
            }
        });
}
