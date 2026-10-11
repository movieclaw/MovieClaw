//! Desktop playback integration. Every platform mutation runs on the UI thread.
//! Session sequence guards also retire a begin operation which arrived after stop.
use serde::{Deserialize, Serialize};
use std::sync::{LazyLock, Mutex};
use tauri::{Emitter, LogicalSize, Manager, PhysicalPosition, WebviewWindow};

#[derive(Clone, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlaybackUpdate {
    pub instance_id: String,
    pub sequence: u64,
    pub paused: bool,
    pub position_ms: u64,
    pub duration_ms: u64,
    pub width: u32,
    pub height: u32,
    pub rate: f64,
    pub always_on_top: bool,
    pub fit_window: bool,
}

#[derive(Default, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PlatformStatus {
    active: bool,
    smtc_available: bool,
    sleep_inhibited: bool,
    on_top: bool,
    fitted: bool,
    aspect_locked: bool,
    picture_in_picture: bool,
    sequence: u64,
}

struct Session {
    instance_id: String,
    sequence: u64,
    size_before: LogicalSize<f64>,
    position_before: PhysicalPosition<i32>,
    maximized_before: bool,
    fullscreen_before: bool,
    on_top_before: bool,
    video_size: (u32, u32),
    settings: (bool, bool),
    last_fullscreen: bool,
    last_scale: f64,
    status: PlatformStatus,
    pip_before: Option<PipWindow>,
    #[cfg(windows)]
    controls: Option<MediaControls>,
    #[cfg(windows)]
    placement_before: WINDOWPLACEMENT,
}
struct PipWindow {
    size: LogicalSize<f64>,
    position: PhysicalPosition<i32>,
    maximized: bool,
    fullscreen: bool,
    on_top: bool,
    #[cfg(windows)]
    placement: WINDOWPLACEMENT,
}
#[derive(Default)]
struct State {
    latest_sequence: u64,
    session: Option<Session>,
}
static STATE: LazyLock<Mutex<State>> = LazyLock::new(|| Mutex::new(State::default()));
static WINDOW_CHANGE_QUEUED: std::sync::atomic::AtomicBool =
    std::sync::atomic::AtomicBool::new(false);
static PROBE_STARTED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
#[cfg(windows)]
static SLEEP_INHIBITED: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);

fn fitted_size(width: f64, aspect: f64, maximum: (f64, f64)) -> Option<LogicalSize<f64>> {
    if !width.is_finite() || !aspect.is_finite() || aspect <= 0.0 {
        return None;
    }
    let width = width.max(960.0).max(600.0 * aspect).min(maximum.0);
    let height = (width / aspect).min(maximum.1);
    let width = width.min(height * aspect);
    (width >= 959.0 && height >= 599.0).then_some(LogicalSize::new(width, height))
}
fn probe_video_dimensions(maximum: (f64, f64)) -> Option<(u32, u32)> {
    [(1920, 1080), (1024, 768)]
        .into_iter()
        .find(|&(width, height)| {
            fitted_size(1280.0, f64::from(width) / f64::from(height), maximum).is_some()
        })
}

async fn on_ui<T: Send + 'static>(
    app: tauri::AppHandle,
    operation: impl FnOnce() -> Result<T, String> + Send + 'static,
) -> Result<T, String> {
    let (send, receive) = tokio::sync::oneshot::channel();
    app.run_on_main_thread(move || {
        let _ = send.send(operation());
    })
    .map_err(|_| "平台服务已关闭")?;
    receive.await.map_err(|_| "平台服务已关闭")?
}

#[tauri::command]
pub async fn begin_native_playback(
    window: WebviewWindow,
    app: tauri::AppHandle,
    instance_id: String,
    sequence: u64,
    title: String,
) -> Result<PlatformStatus, String> {
    if instance_id.is_empty() || instance_id.len() > 128 || sequence == 0 {
        return Err("播放身份无效".into());
    }
    on_ui(app.clone(), move || {
        let mut state = STATE.lock().unwrap();
        if sequence <= state.latest_sequence {
            return Err("播放请求已失效".into());
        }
        if let Some(old) = state.session.take() {
            restore(&window, old);
        }
        state.latest_sequence = sequence;
        let scale = window.scale_factor().map_err(|_| "无法读取窗口缩放")?;
        let on_top_before = window.is_always_on_top().unwrap_or(false);
        let session = Session {
            instance_id: instance_id.clone(),
            sequence,
            size_before: window
                .inner_size()
                .map_err(|_| "无法读取窗口大小")?
                .to_logical(scale),
            position_before: window.outer_position().map_err(|_| "无法读取窗口位置")?,
            maximized_before: window.is_maximized().unwrap_or(false),
            fullscreen_before: window.is_fullscreen().unwrap_or(false),
            on_top_before,
            video_size: (0, 0),
            settings: (false, false),
            last_fullscreen: window.is_fullscreen().unwrap_or(false),
            last_scale: scale,
            status: PlatformStatus {
                active: true,
                sequence,
                on_top: on_top_before,
                ..Default::default()
            },
            pip_before: None,
            #[cfg(windows)]
            controls: make_controls(&window, &app, &instance_id, sequence, &title).ok(),
            #[cfg(windows)]
            placement_before: window_placement(&window)?,
        };
        #[cfg(windows)]
        let session = {
            let mut session = session;
            session.status.smtc_available = session.controls.is_some();
            session
        };
        #[cfg(not(windows))]
        let _ = (app, title);
        let status = session.status.clone();
        state.session = Some(session);
        Ok(status)
    })
    .await
}

#[tauri::command]
pub async fn update_native_playback(
    window: WebviewWindow,
    app: tauri::AppHandle,
    update: PlaybackUpdate,
) -> Result<PlatformStatus, String> {
    on_ui(app, move || {
        let mut state = STATE.lock().unwrap();
        let session = state
            .session
            .as_mut()
            .filter(|session| {
                session.instance_id == update.instance_id && session.sequence == update.sequence
            })
            .ok_or("播放请求已失效")?;
        let fullscreen = window.is_fullscreen().unwrap_or(false);
        let on_top = session.status.picture_in_picture || (update.always_on_top && !fullscreen);
        if on_top != session.status.on_top {
            window
                .set_always_on_top(on_top)
                .map_err(|_| "无法更改窗口置顶")?;
            session.status.on_top = on_top;
        }
        let dimensions = (update.width, update.height);
        let settings = (update.always_on_top, update.fit_window);
        if update.fit_window
            && !session.status.picture_in_picture
            && !fullscreen
            && dimensions.0 > 0
            && dimensions.1 > 0
            && (dimensions != session.video_size
                || settings != session.settings
                || !session.status.fitted)
        {
            session.status.fitted = fit(&window, dimensions);
        }
        session.video_size = dimensions;
        session.settings = settings;
        #[cfg(windows)]
        {
            session.status.aspect_locked = set_aspect_lock(
                &window,
                if session.status.picture_in_picture && update.width > 0 && update.height > 0 {
                    f64::from(update.width) / f64::from(update.height)
                } else if update.fit_window && !fullscreen && session.status.fitted {
                    f64::from(update.width) / f64::from(update.height)
                } else {
                    0.0
                },
            );
            session.status.sleep_inhibited = set_sleep(!update.paused);
            if let Some(controls) = &session.controls {
                let _ = controls.update(&update);
            }
        }
        #[cfg(not(windows))]
        let _ = (
            update.paused,
            update.position_ms,
            update.duration_ms,
            update.rate,
        );
        Ok(session.status.clone())
    })
    .await
}

fn restore_pip(window: &WebviewWindow, before: PipWindow) {
    #[cfg(windows)]
    PIP_SMALL_WINDOW.store(false, std::sync::atomic::Ordering::SeqCst);
    #[cfg(windows)]
    set_aspect_lock(window, 0.0);
    let _ = window.set_min_size(Some(LogicalSize::new(960.0, 600.0)));
    let _ = window.set_fullscreen(false);
    let _ = window.set_always_on_top(before.on_top);
    #[cfg(windows)]
    let restored = window.hwnd().is_ok_and(|hwnd| unsafe {
        SetWindowPlacement(HWND(hwnd.0), &before.placement).is_ok()
    });
    #[cfg(not(windows))]
    let restored = false;
    if !restored {
        let _ = window.unmaximize();
        let _ = window.set_size(before.size);
        let _ = window.set_position(before.position);
    }
    if before.maximized { let _ = window.maximize(); }
    let _ = window.set_fullscreen(before.fullscreen);
}

#[tauri::command]
pub async fn set_native_picture_in_picture(
    window: WebviewWindow,
    app: tauri::AppHandle,
    instance_id: String,
    sequence: u64,
    enabled: bool,
) -> Result<PlatformStatus, String> {
    on_ui(app, move || {
        let mut state = STATE.lock().unwrap();
        let session = state.session.as_mut()
            .filter(|s| s.instance_id == instance_id && s.sequence == sequence)
            .ok_or("播放请求已失效")?;
        if enabled == session.status.picture_in_picture { return Ok(session.status.clone()); }
        if enabled {
            let scale = window.scale_factor().map_err(|_| "无法读取窗口缩放")?;
            let before = PipWindow {
                size: window.inner_size().map_err(|_| "无法读取窗口大小")?.to_logical(scale),
                position: window.outer_position().map_err(|_| "无法读取窗口位置")?,
                maximized: window.is_maximized().unwrap_or(false),
                fullscreen: window.is_fullscreen().unwrap_or(false),
                on_top: window.is_always_on_top().unwrap_or(false),
                #[cfg(windows)]
                placement: window_placement(&window)?,
            };
            let aspect = if session.video_size.0 > 0 && session.video_size.1 > 0 {
                f64::from(session.video_size.0) / f64::from(session.video_size.1)
            } else { 16.0 / 9.0 };
            let height = (480.0 / aspect).clamp(180.0, 480.0);
            #[cfg(windows)]
            PIP_SMALL_WINDOW.store(true, std::sync::atomic::Ordering::SeqCst);
            let result = (|| {
                window.set_fullscreen(false).map_err(|_| "无法退出全屏")?;
                window.unmaximize().map_err(|_| "无法恢复窗口")?;
                window.set_min_size(Some(LogicalSize::new(320.0, 180.0))).map_err(|_| "无法设置小窗尺寸")?;
                window.set_size(LogicalSize::new(480.0, height)).map_err(|_| "无法调整小窗")?;
                window.set_always_on_top(true).map_err(|_| "无法置顶小窗")?;
                if let Ok(Some(monitor)) = window.current_monitor() {
                    let area = monitor.work_area();
                    let x = area.position.x + (area.size.width as i32 - (480.0 * scale) as i32 - 24).max(0);
                    let y = area.position.y + (area.size.height as i32 - (height * scale) as i32 - 24).max(0);
                    window.set_position(PhysicalPosition::new(x, y)).map_err(|_| "无法定位小窗")?;
                }
                Ok::<_, &str>(())
            })();
            if let Err(error) = result { restore_pip(&window, before); return Err(error.into()); }
            session.pip_before = Some(before);
        } else if let Some(before) = session.pip_before.take() {
            restore_pip(&window, before);
        }
        session.status.picture_in_picture = enabled;
        session.status.on_top = window.is_always_on_top().unwrap_or(false);
        session.status.fitted = false;
        Ok(session.status.clone())
    }).await
}

#[tauri::command]
pub async fn end_native_playback(
    window: WebviewWindow,
    app: tauri::AppHandle,
    instance_id: String,
    sequence: u64,
) -> Result<(), String> {
    on_ui(app, move || {
        let mut state = STATE.lock().unwrap();
        state.latest_sequence = state.latest_sequence.max(sequence);
        if state
            .session
            .as_ref()
            .is_some_and(|s| s.instance_id == instance_id && s.sequence == sequence)
        {
            if let Some(session) = state.session.take() {
                restore(&window, session);
            }
        }
        Ok(())
    })
    .await
}

fn fit(window: &WebviewWindow, dimensions: (u32, u32)) -> bool {
    let Ok(scale) = window.scale_factor() else {
        return false;
    };
    let Ok(current) = window.inner_size() else {
        return false;
    };
    let Ok(Some(monitor)) = window.current_monitor() else {
        return false;
    };
    let area = monitor.work_area();
    let maximum = (
        f64::from(area.size.width) / scale,
        f64::from(area.size.height) / scale,
    );
    let Some(size) = fitted_size(
        f64::from(current.width) / scale,
        f64::from(dimensions.0) / f64::from(dimensions.1),
        maximum,
    ) else {
        return false;
    };
    if window.set_size(size).is_err() {
        return false;
    }
    // Keep the current corner when possible, including monitors left of the primary.
    if let Ok(position) = window.outer_position() {
        let width = (size.width * scale).round() as i32;
        let height = (size.height * scale).round() as i32;
        let x = position.x.clamp(
            area.position.x,
            (area.position.x + area.size.width as i32 - width).max(area.position.x),
        );
        let y = position.y.clamp(
            area.position.y,
            (area.position.y + area.size.height as i32 - height).max(area.position.y),
        );
        let _ = window.set_position(tauri::PhysicalPosition::new(x, y));
    }
    true
}

fn restore(window: &WebviewWindow, session: Session) {
    #[cfg(windows)]
    PIP_SMALL_WINDOW.store(false, std::sync::atomic::Ordering::SeqCst);
    if session.pip_before.is_some() {
        let _ = window.set_min_size(Some(LogicalSize::new(960.0, 600.0)));
    }
    #[cfg(windows)]
    {
        set_aspect_lock(window, 0.0);
        set_sleep(false);
    }
    let _ = window.set_always_on_top(session.on_top_before);
    let _ = window.set_fullscreen(session.fullscreen_before);
    if !session.fullscreen_before {
        #[cfg(windows)]
        let restored = window.hwnd().is_ok_and(|hwnd| unsafe {
            SetWindowPlacement(HWND(hwnd.0), &session.placement_before).is_ok()
        });
        #[cfg(not(windows))]
        let restored = false;
        if !restored {
            let _ = window.unmaximize();
            let _ = window.set_size(session.size_before);
            let _ = window.set_position(session.position_before);
        }
        // SetWindowPlacement preserves rcNormalPosition while restoring zoomed
        // state. set_size alone would overwrite those bounds and unmaximize.
        if session.maximized_before {
            let _ = window.maximize();
        } else {
            let _ = window.unmaximize();
        }
    }
}

// Called only from the main-thread final cleanup, also when JavaScript is unavailable.
pub fn shutdown(app: &tauri::AppHandle) {
    if let Some(session) = STATE.lock().unwrap().session.take() {
        if let Some(window) = app.get_webview_window("main") {
            restore(&window, session);
        }
    }
    #[cfg(windows)]
    set_sleep(false);
}

pub fn diagnostic_probe(app: tauri::AppHandle) {
    if std::env::var("MOVIECLAW_PLATFORM_SMOKE").as_deref() != Ok("1")
        || PROBE_STARTED.swap(true, std::sync::atomic::Ordering::SeqCst)
    {
        return;
    }
    tauri::async_runtime::spawn(async move {
        let result = async {
            let window = app.get_webview_window("main").ok_or("主窗口未就绪")?;
            let before = window.inner_size().map_err(|_| "无法读取原窗口")?;
            let before_position = window.outer_position().map_err(|_| "无法读取原窗口位置")?;
            let before_maximized = window.is_maximized().map_err(|_| "无法读取最大化状态")?;
            let before_top = window.is_always_on_top().map_err(|_| "无法读取置顶")?;
            let scale = window.scale_factor().map_err(|_| "无法读取窗口缩放")?;
            let monitor = window.current_monitor().map_err(|_| "无法读取显示器")?.ok_or("显示器不可用")?;
            let work_area = monitor.work_area();
            let dimensions = probe_video_dimensions((f64::from(work_area.size.width) / scale,
                f64::from(work_area.size.height) / scale)).ok_or("工作区无法容纳窗口贴合测试")?;
            let target_aspect = f64::from(dimensions.0) / f64::from(dimensions.1);
            let began = begin_native_playback(window.clone(), app.clone(), "ci-platform-probe".into(), 1, "Synthetic platform lifecycle".into()).await?;
            let update = PlaybackUpdate { instance_id: "ci-platform-probe".into(), sequence: 1,
                paused: false, position_ms: 10_000, duration_ms: 30_000, width: dimensions.0, height: dimensions.1,
                rate: 1.0, always_on_top: true, fit_window: true };
            let playing = update_native_playback(window.clone(), app.clone(), update.clone()).await?;
            let playing_size = window.inner_size().map_err(|_| "无法读取播放窗口")?;
            let playing_top = window.is_always_on_top().map_err(|_| "无法读取播放置顶")?;
            let fit_ok = playing.fitted && (f64::from(playing_size.width) / f64::from(playing_size.height) - target_aspect).abs() < 0.01;
            let compact = set_native_picture_in_picture(window.clone(), app.clone(), "ci-platform-probe".into(), 1, true).await?;
            let compact_size = window.inner_size().map_err(|_| "无法读取小窗大小")?;
            let pip_ok = compact.picture_in_picture && window.is_always_on_top().unwrap_or(false)
                && (f64::from(compact_size.width) / scale - 480.0).abs() < 2.0;
            let normal = set_native_picture_in_picture(window.clone(), app.clone(), "ci-platform-probe".into(), 1, false).await?;
            let pip_restored = !normal.picture_in_picture && playing_size == window.inner_size().map_err(|_| "无法读取小窗恢复大小")?;
            set_native_picture_in_picture(window.clone(), app.clone(), "ci-platform-probe".into(), 1, true).await?;
            let paused = update_native_playback(window.clone(), app.clone(), PlaybackUpdate { paused: true, ..update.clone() }).await?;
            end_native_playback(window.clone(), app.clone(), "ci-platform-probe".into(), 1).await?;
            let stale_pip_rejected = set_native_picture_in_picture(window.clone(), app.clone(), "ci-platform-probe".into(), 1, true).await.is_err();
            let after = window.inner_size().map_err(|_| "无法读取还原窗口")?;
            let position_restored = before_position == window.outer_position().map_err(|_| "无法读取还原窗口位置")?;
            let restored = before == after && position_restored
                && before_maximized == window.is_maximized().unwrap_or(!before_maximized)
                && before_top == window.is_always_on_top().unwrap_or(!before_top);
            let normal_geometry = (window.inner_size().map_err(|_| "无法读取正常窗口大小")?,
                window.outer_position().map_err(|_| "无法读取正常窗口位置")?);
            #[cfg(windows)]
            let normal_placement = {
                let window = window.clone();
                on_ui(app.clone(), move || window_placement(&window)).await?
            };
            let maximize_window = window.clone();
            on_ui(app.clone(), move || maximize_window.maximize().map_err(|_| "无法最大化测试窗口".into())).await?;
            begin_native_playback(window.clone(), app.clone(), "ci-maximized-probe".into(), 2, "Maximized restore lifecycle".into()).await?;
            update_native_playback(window.clone(), app.clone(), PlaybackUpdate {
                instance_id: "ci-maximized-probe".into(), sequence: 2, ..update
            }).await?;
            end_native_playback(window.clone(), app.clone(), "ci-maximized-probe".into(), 2).await?;
            let maximized_restored = window.is_maximized().map_err(|_| "无法读取最大化恢复状态")?;
            let unmaximize_window = window.clone();
            on_ui(app.clone(), move || unmaximize_window.unmaximize().map_err(|_| "无法还原测试窗口".into())).await?;
            let normal_geometry_restored = normal_geometry == (window.inner_size().map_err(|_| "无法读取正常恢复大小")?,
                window.outer_position().map_err(|_| "无法读取正常恢复位置")?);
            #[cfg(windows)]
            let normal_placement_restored = {
                let window = window.clone();
                on_ui(app.clone(), move || window_placement(&window)).await?.rcNormalPosition == normal_placement.rcNormalPosition
            };
            #[cfg(not(windows))]
            let normal_placement_restored = normal_geometry_restored;
            // Simulate a begin callback delivered after the user has already stopped it.
            end_native_playback(window.clone(), app.clone(), "retired-platform-probe".into(), 3).await?;
            let retired_rejected = begin_native_playback(window.clone(), app.clone(), "retired-platform-probe".into(), 3, "retired".into()).await.is_err();
            let released = STATE.lock().unwrap().session.is_none();
            #[cfg(windows)]
            let power_ok = playing.sleep_inhibited && !paused.sleep_inhibited
                && !SLEEP_INHIBITED.load(std::sync::atomic::Ordering::SeqCst);
            #[cfg(windows)]
            let aspect_ok = playing.aspect_locked;
            #[cfg(not(windows))]
            let power_ok = true;
            #[cfg(not(windows))]
            let aspect_ok = true;
            Ok::<_, String>(serde_json::json!({ "passed": restored && maximized_restored && normal_geometry_restored && normal_placement_restored && released && retired_rejected && power_ok && fit_ok && aspect_ok && playing_top && pip_ok && pip_restored && stale_pip_rejected,
                "pictureInPicture": pip_ok, "pictureInPictureRestored": pip_restored, "stalePictureInPictureRejected": stale_pip_rejected,
                "smtcAvailable": began.smtc_available,
                "smtcRegistrationStatus": if began.smtc_available { "passed" } else { "unavailable" },
                "playing": playing, "paused": paused,
                "fixtureDimensions": [dimensions.0, dimensions.1], "targetAspect": target_aspect,
                "windowRestored": restored, "sessionReleased": released, "retiredBeginRejected": retired_rejected,
                "positionRestored": position_restored, "maximizedRestored": maximized_restored,
                "normalGeometryRestored": normal_geometry_restored, "normalPlacementRestored": normal_placement_restored,
                "onTopApplied": playing_top, "fittedAspectValid": fit_ok, "aspectLockRegistered": playing.aspect_locked,
                "powerRestored": power_ok, "scope": "window and power lifecycle; SMTC availability reported separately; no decoded media or physical media-key validation" }))
        }.await;
        let cleanup_app = app.clone();
        let _ = on_ui(app, move || {
            shutdown(&cleanup_app);
            Ok(())
        })
        .await;
        let value = match result {
            Ok(value) => value,
            Err(_) => serde_json::json!({"passed":false,"error":"PLATFORM_PROBE_FAILED"}),
        };
        let _ = std::fs::write(
            crate::connect::config_dir().join("platform-smoke.json"),
            value.to_string(),
        );
    });
}

pub fn window_changed(window: &tauri::Window) {
    if window.label() != "main" {
        return;
    }
    if STATE.try_lock().is_ok_and(|state| state.session.is_none()) {
        return;
    }
    if WINDOW_CHANGE_QUEUED.swap(true, std::sync::atomic::Ordering::SeqCst) {
        return;
    }
    // Do not call window methods while inside a Wry window event callback.
    let app = window.app_handle().clone();
    tauri::async_runtime::spawn(async move {
        let callback_app = app.clone();
        let result = app.run_on_main_thread(move || {
            WINDOW_CHANGE_QUEUED.store(false, std::sync::atomic::Ordering::SeqCst);
            let Some(window) = callback_app.get_webview_window("main") else {
                return;
            };
            let mut state = STATE.lock().unwrap();
            if let Some(session) = state.session.as_mut() {
                if session.status.picture_in_picture { return; }
                let fullscreen = window.is_fullscreen().unwrap_or(false);
                let scale = window.scale_factor().unwrap_or(session.last_scale);
                if fullscreen == session.last_fullscreen && scale == session.last_scale {
                    return;
                }
                session.last_fullscreen = fullscreen;
                session.last_scale = scale;
                let on_top = session.settings.0 && !fullscreen;
                let _ = window.set_always_on_top(on_top);
                session.status.on_top = on_top;
                if !fullscreen && session.settings.1 && session.video_size.0 > 0 {
                    session.status.fitted = fit(&window, session.video_size);
                }
                #[cfg(windows)]
                {
                    session.status.aspect_locked = set_aspect_lock(
                        &window,
                        if !fullscreen && session.status.fitted && session.settings.1 {
                            f64::from(session.video_size.0) / f64::from(session.video_size.1)
                        } else {
                            0.0
                        },
                    );
                }
            }
            let _ = window.emit("movieclaw:window-scale-changed", ());
        });
        if result.is_err() {
            WINDOW_CHANGE_QUEUED.store(false, std::sync::atomic::Ordering::SeqCst);
        }
    });
}

#[cfg(windows)]
use windows::{
    Foundation::{TimeSpan, TypedEventHandler},
    Media::{
        MediaPlaybackStatus, MediaPlaybackType, PlaybackPositionChangeRequestedEventArgs,
        SystemMediaTransportControls, SystemMediaTransportControlsButton as Button,
        SystemMediaTransportControlsButtonPressedEventArgs,
        SystemMediaTransportControlsTimelineProperties,
    },
    Win32::{
        Foundation::HWND,
        System::{
            Power::{
                SetThreadExecutionState, ES_CONTINUOUS, ES_DISPLAY_REQUIRED, ES_SYSTEM_REQUIRED,
            },
            WinRT::{
                ISystemMediaTransportControlsInterop, RoInitialize, RoUninitialize,
                RO_INIT_SINGLETHREADED,
            },
        },
        UI::WindowsAndMessaging::{GetWindowPlacement, SetWindowPlacement, WINDOWPLACEMENT},
    },
};

#[cfg(windows)]
fn window_placement(window: &WebviewWindow) -> Result<WINDOWPLACEMENT, String> {
    let hwnd = window.hwnd().map_err(|_| "无法读取窗口句柄")?;
    let mut placement = WINDOWPLACEMENT {
        length: std::mem::size_of::<WINDOWPLACEMENT>() as u32,
        ..Default::default()
    };
    unsafe { GetWindowPlacement(HWND(hwnd.0), &mut placement) }
        .map_err(|_| "无法读取窗口还原状态")?;
    Ok(placement)
}

#[cfg(windows)]
struct MediaControls {
    value: SystemMediaTransportControls,
    button_token: i64,
    position_token: i64,
    _runtime: WinRtInitialization,
}
#[cfg(windows)]
struct WinRtInitialization(bool);
#[cfg(windows)]
impl Drop for WinRtInitialization {
    fn drop(&mut self) {
        if self.0 {
            unsafe {
                RoUninitialize();
            }
        }
    }
}
#[cfg(windows)]
impl Drop for MediaControls {
    fn drop(&mut self) {
        let _ = self.value.RemoveButtonPressed(self.button_token);
        let _ = self
            .value
            .RemovePlaybackPositionChangeRequested(self.position_token);
        let _ = self.value.SetPlaybackStatus(MediaPlaybackStatus::Closed);
        let _ = self.value.SetIsEnabled(false);
        if let Ok(display) = self.value.DisplayUpdater() {
            let _ = display.ClearAll();
            let _ = display.Update();
        }
    }
}
#[cfg(windows)]
impl MediaControls {
    fn update(&self, update: &PlaybackUpdate) -> windows::core::Result<()> {
        self.value.SetPlaybackStatus(if update.paused {
            MediaPlaybackStatus::Paused
        } else {
            MediaPlaybackStatus::Playing
        })?;
        let timeline = SystemMediaTransportControlsTimelineProperties::new()?;
        let ticks = |ms: u64| TimeSpan {
            Duration: ms.min(i64::MAX as u64 / 10_000) as i64 * 10_000,
        };
        timeline.SetStartTime(ticks(0))?;
        timeline.SetMinSeekTime(ticks(0))?;
        timeline.SetEndTime(ticks(update.duration_ms))?;
        timeline.SetMaxSeekTime(ticks(update.duration_ms))?;
        timeline.SetPosition(ticks(update.position_ms.min(update.duration_ms)))?;
        self.value.UpdateTimelineProperties(&timeline)?;
        if update.rate.is_finite() && (0.25..=4.0).contains(&update.rate) {
            self.value.SetPlaybackRate(update.rate)?;
        }
        Ok(())
    }
}
#[cfg(windows)]
fn make_controls(
    window: &WebviewWindow,
    app: &tauri::AppHandle,
    id: &str,
    sequence: u64,
    title: &str,
) -> windows::core::Result<MediaControls> {
    // Balance successful S_OK/S_FALSE initialization on this same UI thread.
    let runtime = WinRtInitialization(unsafe { RoInitialize(RO_INIT_SINGLETHREADED).is_ok() });
    let factory = windows::core::factory::<
        SystemMediaTransportControls,
        ISystemMediaTransportControlsInterop,
    >()?;
    let hwnd = window.hwnd().map_err(|_| {
        windows::core::Error::from_hresult(windows::core::HRESULT(0x80004005u32 as i32))
    })?;
    let value: SystemMediaTransportControls = unsafe { factory.GetForWindow(HWND(hwnd.0))? };
    value.SetIsEnabled(false)?;
    value.SetIsPlayEnabled(true)?;
    value.SetIsPauseEnabled(true)?;
    value.SetIsStopEnabled(true)?;
    value.SetIsNextEnabled(true)?;
    value.SetIsPreviousEnabled(true)?;
    value.SetIsFastForwardEnabled(true)?;
    value.SetIsRewindEnabled(true)?;
    let display = value.DisplayUpdater()?;
    display.SetType(MediaPlaybackType::Video)?;
    display
        .VideoProperties()?
        .SetTitle(&windows::core::HSTRING::from(
            title.chars().take(256).collect::<String>(),
        ))?;
    display.Update()?;
    let handle = app.clone();
    let instance = id.to_owned();
    let button_token = value.ButtonPressed(&TypedEventHandler::<
        SystemMediaTransportControls,
        SystemMediaTransportControlsButtonPressedEventArgs,
    >::new(move |_, args| {
        let Some(args) = args.as_ref() else {
            return Ok(());
        };
        let action = match args.Button()? {
            Button::Play => "play",
            Button::Pause => "pause",
            Button::Stop => "stop",
            Button::Next => "next",
            Button::Previous => "previous",
            Button::FastForward => "forward",
            Button::Rewind => "rewind",
            _ => return Ok(()),
        };
        let _ = handle.emit(
            "movieclaw:media-command",
            serde_json::json!({"instanceId":instance,"sequence":sequence,"action":action}),
        );
        Ok(())
    }))?;
    let handle = app.clone();
    let instance = id.to_owned();
    let position_token = match value.PlaybackPositionChangeRequested(&TypedEventHandler::<SystemMediaTransportControls,
        PlaybackPositionChangeRequestedEventArgs>::new(move |_, args| {
        let Some(args) = args.as_ref() else { return Ok(()); };
        let position = args.RequestedPlaybackPosition()?.Duration.max(0) / 10_000;
        let _ = handle.emit("movieclaw:media-command", serde_json::json!({"instanceId":instance,"sequence":sequence,"action":"seek","positionMs":position}));
        Ok(())
    })) { Ok(token) => token, Err(error) => { let _ = value.RemoveButtonPressed(button_token); let _ = value.SetIsEnabled(false); return Err(error); } };
    let controls = MediaControls {
        value,
        button_token,
        position_token,
        _runtime: runtime,
    };
    controls.value.SetIsEnabled(true)?;
    Ok(controls)
}
#[cfg(windows)]
fn set_sleep(playing: bool) -> bool {
    let flags = if playing {
        ES_CONTINUOUS | ES_DISPLAY_REQUIRED | ES_SYSTEM_REQUIRED
    } else {
        ES_CONTINUOUS
    };
    let succeeded = unsafe { SetThreadExecutionState(flags).0 != 0 };
    if succeeded {
        SLEEP_INHIBITED.store(playing, std::sync::atomic::Ordering::SeqCst);
    }
    SLEEP_INHIBITED.load(std::sync::atomic::Ordering::SeqCst)
}

#[cfg(windows)]
static ASPECT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
#[cfg(windows)]
static PIP_SMALL_WINDOW: std::sync::atomic::AtomicBool = std::sync::atomic::AtomicBool::new(false);
#[cfg(windows)]
type SubclassProc = unsafe extern "system" fn(isize, u32, usize, isize, usize, usize) -> isize;
#[cfg(windows)]
#[link(name = "comctl32")]
unsafe extern "system" {
    fn SetWindowSubclass(
        hwnd: isize,
        callback: Option<SubclassProc>,
        id: usize,
        data: usize,
    ) -> i32;
    fn RemoveWindowSubclass(hwnd: isize, callback: Option<SubclassProc>, id: usize) -> i32;
    fn DefSubclassProc(hwnd: isize, message: u32, wparam: usize, lparam: isize) -> isize;
}
#[cfg(windows)]
#[link(name = "user32")]
unsafe extern "system" {
    fn GetDpiForWindow(hwnd: isize) -> u32;
}
#[cfg(windows)]
unsafe extern "system" fn aspect_proc(
    hwnd: isize,
    message: u32,
    edge: usize,
    rect: isize,
    _: usize,
    _: usize,
) -> isize {
    let aspect = f64::from_bits(ASPECT.load(std::sync::atomic::Ordering::SeqCst));
    if message == 0x0214 && rect != 0 && aspect > 0.0 {
        let rect = &mut *(rect as *mut windows::Win32::Foundation::RECT);
        let scale = f64::from(GetDpiForWindow(hwnd).max(96)) / 96.0;
        let compact = PIP_SMALL_WINDOW.load(std::sync::atomic::Ordering::SeqCst);
        let minimum_width = if compact { 320.0 } else { 960.0 } * scale;
        let minimum_height = if compact { 180.0 } else { 600.0 } * scale;
        let width = f64::from(rect.right - rect.left).max(minimum_width);
        let height = f64::from(rect.bottom - rect.top).max(minimum_height);
        let (width, height) = if edge == 3 || edge == 6 {
            (
                (height * aspect).max(minimum_width),
                height.max(minimum_width / aspect),
            )
        } else {
            (
                width.max(minimum_height * aspect),
                (width / aspect).max(minimum_height),
            )
        };
        if matches!(edge, 1 | 4 | 7) {
            rect.left = rect.right - width.round() as i32;
        } else {
            rect.right = rect.left + width.round() as i32;
        }
        if matches!(edge, 3 | 4 | 5) {
            rect.top = rect.bottom - height.round() as i32;
        } else {
            rect.bottom = rect.top + height.round() as i32;
        }
        return 1;
    }
    DefSubclassProc(hwnd, message, edge, rect)
}
#[cfg(windows)]
fn set_aspect_lock(window: &WebviewWindow, aspect: f64) -> bool {
    ASPECT.store(aspect.to_bits(), std::sync::atomic::Ordering::SeqCst);
    if let Ok(hwnd) = window.hwnd() {
        unsafe {
            if aspect > 0.0 {
                return SetWindowSubclass(hwnd.0 as isize, Some(aspect_proc), 0x4d43, 0) != 0;
            } else {
                RemoveWindowSubclass(hwnd.0 as isize, Some(aspect_proc), 0x4d43);
            }
        }
    }
    false
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn fitting_respects_minimum_work_area_and_invalid_video() {
        let fitted = fitted_size(1280.0, 16.0 / 9.0, (1920.0, 1040.0)).unwrap();
        assert_eq!(fitted, LogicalSize::new(1280.0, 720.0));
        assert!(fitted_size(960.0, 2.4, (1024.0, 768.0)).is_none());
        assert!(fitted_size(1280.0, f64::NAN, (1920.0, 1080.0)).is_none());
        let fitted = fitted_size(2000.0, 16.0 / 9.0, (1600.0, 900.0)).unwrap();
        assert_eq!(fitted, LogicalSize::new(1600.0, 900.0));
    }
    #[test]
    fn diagnostic_fixture_requires_real_fitting_in_the_available_work_area() {
        assert_eq!(probe_video_dimensions((1920.0, 1040.0)), Some((1920, 1080)));
        assert_eq!(probe_video_dimensions((1024.0, 728.0)), Some((1024, 768)));
        assert_eq!(probe_video_dimensions((950.0, 600.0)), None);
    }
}
