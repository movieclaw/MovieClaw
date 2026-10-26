// MovieClaw Desktop — 嵌入式 mpv 播放器（杜比视界/全景声等高端内容）
// 通过 Win32 子窗口将 mpv 画面嵌入主窗口

use std::process::{Child, Command};
use std::sync::atomic::{AtomicIsize, AtomicU32, AtomicU64, Ordering};
use std::sync::Mutex;

// Win32 API FFI
#[allow(non_snake_case)]
mod win32 {
    pub type HWND = *mut core::ffi::c_void;
    type HINSTANCE = isize;
    type HMENU = isize;
    type LPCWSTR = *const u16;
    type LPVOID = *mut core::ffi::c_void;
    type WNDPROC = Option<unsafe extern "system" fn(HWND, u32, usize, isize) -> isize>;

    pub const WS_CHILD: u32 = 0x40000000;
    pub const WS_VISIBLE: u32 = 0x10000000;
    pub const WS_CLIPSIBLINGS: u32 = 0x04000000;
    pub const WS_CLIPCHILDREN: u32 = 0x02000000;
    pub const SWP_SHOWWINDOW: u32 = 0x0040;
    /// SetWindowPos 的 hWndInsertAfter：压到兄弟 z-order 最底，保证 WebView2 永远浮在视频子窗口之上
    pub const HWND_BOTTOM: isize = 1;
    /// CombineRgn 的 fnMode：dst = src1 \ src2
    pub const RGN_DIFF: i32 = 3;
    pub const BLACK_BRUSH: i32 = 4;

    #[repr(C)]
    pub struct POINT {
        pub x: i32,
        pub y: i32,
    }

    #[repr(C)]
    pub struct RECT {
        pub left: i32,
        pub top: i32,
        pub right: i32,
        pub bottom: i32,
    }

    #[repr(C)]
    pub struct WNDCLASSW {
        pub style: u32,
        pub lpfnWndProc: WNDPROC,
        pub cbClsExtra: i32,
        pub cbWndExtra: i32,
        pub hInstance: HINSTANCE,
        pub hIcon: isize,
        pub hCursor: isize,
        pub hbrBackground: isize,
        pub lpszMenuName: LPCWSTR,
        pub lpszClassName: LPCWSTR,
    }

    #[link(name = "user32")]
    extern "system" {
        pub fn CreateWindowExW(
            dwExStyle: u32,
            lpClassName: LPCWSTR,
            lpWindowName: LPCWSTR,
            dwStyle: u32,
            x: i32,
            y: i32,
            nWidth: i32,
            nHeight: i32,
            hWndParent: HWND,
            hMenu: HMENU,
            hInstance: HINSTANCE,
            lpParam: LPVOID,
        ) -> HWND;
        pub fn SetWindowPos(
            hWnd: HWND,
            hWndInsertAfter: HWND,
            X: i32,
            Y: i32,
            cx: i32,
            cy: i32,
            uFlags: u32,
        ) -> i32;
        pub fn ShowWindow(hWnd: HWND, nCmdShow: i32) -> i32;
        pub fn DestroyWindow(hWnd: HWND) -> i32;
        pub fn DefWindowProcW(hWnd: HWND, Msg: u32, wParam: usize, lParam: isize) -> isize;
        pub fn RegisterClassW(lpWndClass: *const WNDCLASSW) -> u16;
        pub fn FindWindowExW(
            hWndParent: HWND,
            hWndChildAfter: HWND,
            lpszClass: LPCWSTR,
            lpszWindow: LPCWSTR,
        ) -> HWND;
        pub fn GetWindowRect(hWnd: HWND, lpRect: *mut RECT) -> i32;
        pub fn ClientToScreen(hWnd: HWND, lpPoint: *mut POINT) -> i32;
        /// 区域所有权交给系统：成功后由系统负责释放 hRgn，调用方不得再 DeleteObject
        pub fn SetWindowRgn(hWnd: HWND, hRgn: isize, bRedraw: i32) -> i32;
    }

    #[link(name = "gdi32")]
    extern "system" {
        pub fn GetStockObject(object: i32) -> isize;
        pub fn CreateRectRgn(x1: i32, y1: i32, x2: i32, y2: i32) -> isize;
        pub fn CreateRoundRectRgn(x1: i32, y1: i32, x2: i32, y2: i32, ellipse_width: i32, ellipse_height: i32) -> isize;
        pub fn CombineRgn(hrgnDst: isize, hrgnSrc1: isize, hrgnSrc2: isize, fnMode: i32) -> i32;
        pub fn DeleteObject(hObject: isize) -> i32;
    }

    #[link(name = "kernel32")]
    extern "system" {
        pub fn GetModuleHandleW(lpModuleName: LPCWSTR) -> HINSTANCE;
    }
}

use win32::*;

static CHILD_HWND: AtomicIsize = AtomicIsize::new(0);
/// Tauri 主窗口 HWND（launch 时写入，stop 时清空）：挖洞/填洞都要回到它身上找 WebView2
static PARENT_HWND: AtomicIsize = AtomicIsize::new(0);
static MPV_PROCESS: Mutex<Option<Child>> = Mutex::new(None);
static MPV_PIPE_ID: AtomicU32 = AtomicU32::new(0);
/// 当前 mpv 实例的 IPC 管道名（launch 时写入，stop 时清空）
static MPV_PIPE: Mutex<Option<String>> = Mutex::new(None);
static MPV_INSTANCE_ID: AtomicU64 = AtomicU64::new(0);
static MPV_LIFECYCLE: Mutex<()> = Mutex::new(());
static MPV_IPC: Mutex<Option<crate::mpv_ipc::Session>> = Mutex::new(None);
static MPV_MEDIA_GRANTS: Mutex<Vec<String>> = Mutex::new(Vec::new());
static MPV_SUBTITLE_SOURCES: Mutex<Vec<String>> = Mutex::new(Vec::new());
static MPV_INPUT_FILE: Mutex<Option<std::path::PathBuf>> = Mutex::new(None);
static HOST_INPUT: Mutex<Option<(tauri::AppHandle, u64, Option<isize>)>> = Mutex::new(None);

fn wide(s: &str) -> Vec<u16> {
    s.encode_utf16().chain(std::iter::once(0)).collect()
}

/// 在 WebView2 上挖洞，让底下 mpv 子窗口的画面透出来。
///
/// 普通父子/兄弟窗口之间**不做逐像素 alpha 混合**：就算把 webview 背景色设成 alpha=0，
/// 它照样整块遮住下面的视频（有声音没画面的根因）。WS_EX_LAYERED 也不行——
/// 挂上会把整条 Chromium 渲染链打成全黑。实测唯一可行的是 SetWindowRgn 裁剪。
///
/// 副作用是洞里的网页层内容一起被剪掉，所以洞只能开在「纯视频带」上：
/// 带内仍要显示的浮层（加载层/设置面板）由 keep_rects 刨出去，留在网页层里画。
/// x/y/width/height 与 keep_rects 同坐标系（父窗口客户区，JS 的 viewport × devicePixelRatio）
fn set_webview_hole(
    parent_hwnd: isize,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    keep_rects: &[[i32; 4]],
    keep_radii: &[i32],
) {
    if parent_hwnd == 0 || width <= 0 || height <= 0 {
        return;
    }
    unsafe {
        let class_name = wide("WRY_WEBVIEW");
        let webview = FindWindowExW(
            parent_hwnd as *mut _,
            std::ptr::null_mut(),
            class_name.as_ptr(),
            std::ptr::null(),
        );
        if webview.is_null() {
            return;
        }
        // SetWindowRgn 用的是**窗口坐标**，JS 给的是父窗口客户区坐标，差一个 webview 原点
        let mut origin = POINT { x: 0, y: 0 };
        ClientToScreen(parent_hwnd as *mut _, &mut origin);
        let mut wv = RECT {
            left: 0,
            top: 0,
            right: 0,
            bottom: 0,
        };
        GetWindowRect(webview, &mut wv);
        let (dx, dy) = (wv.left - origin.x, wv.top - origin.y);

        let full = CreateRectRgn(0, 0, wv.right - wv.left, wv.bottom - wv.top);
        let hole = CreateRectRgn(x - dx, y - dy, x - dx + width, y - dy + height);
        for (index, k) in keep_rects.iter().enumerate() {
            let (kx, ky, kw, kh) = (k[0] - dx, k[1] - dy, k[2], k[3]);
            if kw <= 0 || kh <= 0 {
                continue;
            }
            let radius = keep_radii.get(index).copied().unwrap_or(0).clamp(0, kw.min(kh) / 2);
            let keep = if radius > 0 {
                CreateRoundRectRgn(kx, ky, kx + kw, ky + kh, radius * 2, radius * 2)
            } else {
                CreateRectRgn(kx, ky, kx + kw, ky + kh)
            };
            CombineRgn(hole, hole, keep, RGN_DIFF);
            DeleteObject(keep);
        }
        CombineRgn(full, full, hole, RGN_DIFF);
        DeleteObject(hole);
        // full 的所有权交给系统，这里不能再 DeleteObject
        SetWindowRgn(webview, full, 1);
    }
}

/// 把洞填回去（退出播放器/换片时）：否则主界面上会一直缺一块
fn clear_webview_hole(parent_hwnd: isize) {
    if parent_hwnd == 0 {
        return;
    }
    unsafe {
        let class_name = wide("WRY_WEBVIEW");
        let webview = FindWindowExW(
            parent_hwnd as *mut _,
            std::ptr::null_mut(),
            class_name.as_ptr(),
            std::ptr::null(),
        );
        if !webview.is_null() {
            SetWindowRgn(webview, 0, 1);
        }
    }
}

unsafe extern "system" fn host_wnd_proc(
    hwnd: HWND,
    msg: u32,
    wparam: usize,
    lparam: isize,
) -> isize {
    // mpv disables its --wid child on Windows. Mouse events arrive at this host.
    let context = HOST_INPUT.try_lock().ok().and_then(|mut guard| {
        let (app, instance, last_position) = guard.as_mut()?;
        let action = host_mouse_action(msg, lparam, last_position)?;
        Some((app.clone(), *instance, action))
    });
    if let Some((app, instance, action)) = context {
        use tauri::Emitter;
        let _ = app.emit("movieclaw:player-input", serde_json::json!({
            "instanceId": instance, "args": ["movieclaw-input", action]
        }));
        return 0;
    }
    DefWindowProcW(hwnd, msg, wparam, lparam)
}

fn host_mouse_action(message: u32, position: isize, last_position: &mut Option<isize>) -> Option<&'static str> {
    match message {
        // Win32 also sends WM_MOUSEMOVE after region/layout changes with a stationary cursor.
        0x0200 if *last_position == Some(position) => None,
        0x0200 => { *last_position = Some(position); Some("move") },
        0x0202 => Some("click"),
        0x0203 => Some("double-click"),
        0x0205 => Some("info"),
        _ => None,
    }
}

#[cfg(test)]
mod host_input_tests {
    #[test]
    fn disabled_mpv_child_mouse_messages_are_handled_by_the_host() {
        let mut last = None;
        assert_eq!(super::host_mouse_action(0x0200, 100, &mut last), Some("move"));
        assert_eq!(super::host_mouse_action(0x0200, 100, &mut last), None);
        assert_eq!(super::host_mouse_action(0x0200, 101, &mut last), Some("move"));
        assert_eq!(super::host_mouse_action(0x0202, 101, &mut last), Some("click"));
        assert_eq!(super::host_mouse_action(0x0203, 101, &mut last), Some("double-click"));
        assert_eq!(super::host_mouse_action(0x0205, 101, &mut last), Some("info"));
        assert_eq!(super::host_mouse_action(0x0201, 101, &mut last), None);
        assert_eq!(super::host_mouse_action(0x0005, 101, &mut last), None);
    }
}

/// 注册 mpv 宿主子窗口类（进程内一次）。CreateWindowExW 用自定义类必须先注册，
/// 否则返回 NULL，launch 只能以「创建视频子窗口失败」告终。返回模块句柄作 hInstance。
fn ensure_host_class() -> isize {
    use std::sync::Once;
    static INIT: Once = Once::new();
    let hinst = unsafe { GetModuleHandleW(std::ptr::null()) };
    INIT.call_once(|| {
        let class_name = wide("MovieClawMpvHost");
        let wc = WNDCLASSW {
            style: 0x0008, // CS_DBLCLKS: request WM_LBUTTONDBLCLK on the host.
            lpfnWndProc: Some(host_wnd_proc),
            cbClsExtra: 0,
            cbWndExtra: 0,
            hInstance: hinst,
            hIcon: 0,
            hCursor: 0,
            // The WebView hole opens before mpv's first frame is ready.
            // Paint it black rather than exposing the parent window's white background.
            hbrBackground: unsafe { GetStockObject(BLACK_BRUSH) },
            lpszMenuName: std::ptr::null(),
            lpszClassName: class_name.as_ptr(),
        };
        // 返回 0 且类已存在时算成功（重复注册同一类名）
        unsafe { RegisterClassW(&wc) };
    });
    hinst
}

fn find_mpv() -> Option<String> {
    if let Ok(p) = std::env::var("MOVIECLAW_MPV") {
        if std::path::Path::new(&p).exists() {
            return Some(p);
        }
    }
    // 发布版优先使用随应用固定的 runtime，避免 PATH 中旧 mpv 覆盖。
    if let Ok(exe_dir) = std::env::current_exe() {
        if let Some(dir) = exe_dir.parent() {
            for sub in &["mpv/mpv.exe", "mpv.exe"] {
                let p = dir.join(sub);
                if p.exists() {
                    return Some(p.to_string_lossy().to_string());
                }
            }
        }
    }
    // PATH — 直接扫文件系统，不 spawn `where`，避免 GUI 起播时新建 conhost。
    if let Some(path_var) = std::env::var_os("PATH") {
        for dir in std::env::split_paths(&path_var) {
            let p = dir.join("mpv.exe");
            if p.is_file() {
                return Some(p.to_string_lossy().to_string());
            }
        }
    }
    // 常见路径
    for p in &[
        r"C:\Program Files\mpv\mpv.exe",
        r"C:\Program Files (x86)\mpv\mpv.exe",
    ] {
        if std::path::Path::new(p).exists() {
            return Some(p.to_string());
        }
    }
    // scoop / 用户本地
    if let Ok(user) = std::env::var("USERPROFILE") {
        for sub in &[
            r"scoop\apps\mpv\current\mpv.exe",
            r"AppData\Local\Programs\mpv\mpv.exe",
        ] {
            let p = std::path::Path::new(&user).join(sub);
            if p.exists() {
                return Some(p.to_string_lossy().to_string());
            }
        }
    }
    None
}

/// 嵌入式 mpv 是否可用（只查路径，不启动进程）。
/// 起播前先问一句：能力申报要据此决定报不报 universal（全解码）——
/// mpv 不在场却报了 universal，服务端会把 HTML5 放不了的原片直通过来
#[tauri::command]
pub fn has_embedded_player() -> bool {
    find_mpv().is_some()
}

/// 启动嵌入式 mpv 播放器
/// parent_hwnd: Tauri 主窗口 HWND
/// x, y, width, height: 视频区域在父窗口中的位置
#[tauri::command]
pub fn launch_embedded_player(
    app: tauri::AppHandle,
    parent_hwnd: isize,
    stream_url: String,
    subtitle_urls: Option<Vec<String>>,
    start_ms: Option<u64>,
    title: Option<String>,
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    instance_id: Option<u64>,
    hardware_decode: Option<bool>,
) -> Result<serde_json::Value, String> {
    let _lifecycle = MPV_LIFECYCLE.lock().map_err(|_| "播放器生命周期锁不可用")?;
    // 先关闭已有实例
    stop_embedded_player_inner(None).ok();
    MPV_INSTANCE_ID.store(instance_id.unwrap_or(0), Ordering::SeqCst);
    *HOST_INPUT.lock().unwrap() = Some((app.clone(), instance_id.unwrap_or(0), None));
    PARENT_HWND.store(parent_hwnd, Ordering::SeqCst);

    let mpv = find_mpv().ok_or("未找到 mpv")?;
    // mpv sees revocable local capabilities, never global Authorization headers.
    let grants = (|| -> Result<(String, Vec<String>), String> {
        let media = crate::media_stream::grant_native(&stream_url)?;
        MPV_MEDIA_GRANTS.lock().unwrap().push(media.stream_id);
        let mut subtitles = Vec::new();
        for url in subtitle_urls.as_deref().unwrap_or_default() {
            let grant = crate::media_stream::grant_native(url)?;
            MPV_MEDIA_GRANTS.lock().unwrap().push(grant.stream_id);
            subtitles.push(grant.url);
        }
        Ok((media.url, subtitles))
    })();
    let (native_stream_url, native_subtitle_urls) = match grants {
        Ok(grants) => grants,
        Err(error) => {
            stop_embedded_player_inner(instance_id).ok();
            return Err(error);
        }
    };
    *MPV_SUBTITLE_SOURCES.lock().unwrap() = native_subtitle_urls.clone();
    let input_file = std::env::temp_dir().join(format!(
        "movieclaw-input-{}-{}.conf",
        std::process::id(),
        instance_id.unwrap_or(0)
    ));
    let bindings = "MOUSE_MOVE script-message movieclaw-input move\nMBTN_LEFT script-message movieclaw-input click\nMBTN_LEFT_DBL script-message movieclaw-input double-click\nSPACE script-message movieclaw-input play\nLEFT repeatable script-message movieclaw-input seek -10\nRIGHT repeatable script-message movieclaw-input seek 10\nShift+LEFT repeatable script-message movieclaw-input seek -1\nShift+RIGHT repeatable script-message movieclaw-input seek 1\nHOME script-message movieclaw-input home\nPGUP script-message movieclaw-input chapter -1\nPGDWN script-message movieclaw-input chapter 1\n[ script-message movieclaw-input speed -0.25\n] script-message movieclaw-input speed 0.25\ns script-message movieclaw-input subtitle-cycle\nCtrl+. script-message movieclaw-input close\nENTER script-message movieclaw-input enter\nCtrl+LEFT script-message movieclaw-input previous\nCtrl+RIGHT script-message movieclaw-input next\nUP repeatable script-message movieclaw-input volume 0.1\nDOWN repeatable script-message movieclaw-input volume -0.1\nm script-message movieclaw-input mute\nf script-message movieclaw-input fullscreen\nESC script-message movieclaw-input escape\n";
    let bindings = format!("{bindings}MBTN_RIGHT script-message movieclaw-input info\ni script-message movieclaw-input info\nI script-message movieclaw-input info\n");
    if let Err(error) = std::fs::write(&input_file, bindings) {
        stop_embedded_player_inner(instance_id).ok();
        return Err(format!("写播放器输入配置失败: {error}"));
    }
    *MPV_INPUT_FILE.lock().unwrap() = Some(input_file.clone());

    // 创建子窗口
    let class_name = wide("MovieClawMpvHost");
    let window_name = wide("MovieClaw Video");
    let hinst = ensure_host_class();

    let child_hwnd = unsafe {
        CreateWindowExW(
            0,
            class_name.as_ptr(),
            window_name.as_ptr(),
            WS_CHILD | WS_VISIBLE | WS_CLIPSIBLINGS | WS_CLIPCHILDREN,
            x,
            y,
            width,
            height,
            parent_hwnd as *mut _,
            0,
            hinst,
            std::ptr::null_mut(),
        )
    };

    if child_hwnd.is_null() {
        stop_embedded_player_inner(instance_id).ok();
        return Err("创建视频子窗口失败".into());
    }

    CHILD_HWND.store(child_hwnd as isize, Ordering::SeqCst);

    // 启动 mpv
    let start_secs = start_ms.map(|ms| ms as f64 / 1000.0);
    let title = title.unwrap_or_else(|| "MovieClaw".into());
    let pipe_id = MPV_PIPE_ID.fetch_add(1, Ordering::SeqCst);
    let pipe_name = format!(
        "\\\\.\\pipe\\movieclaw-mpv-embed-{}-{}",
        std::process::id(),
        pipe_id
    );

    let mut cmd = Command::new(&mpv);
    cmd.arg(&native_stream_url)
        .arg(format!("--title={title}"))
        .arg(format!("--wid={}", child_hwnd as usize))
        .arg("--force-window=immediate")
        .arg(if hardware_decode.unwrap_or(true) {
            "--hwdec=d3d11va"
        } else {
            "--hwdec=no"
        })
        .arg("--vo=gpu-next")
        .arg("--gpu-context=d3d11")
        .arg("--target-colorspace-hint=auto")
        // 保留文件与 eof-reached，宿主可准确收尾并支持重新 seek。
        .arg("--keep-open=yes")
        .arg("--osd-level=0")
        .arg("--no-border")
        .arg("--no-ontop")
        .arg("--no-terminal")
        // 洞里的鼠标会落到 mpv 子窗口上：mpv 默认绑定含 MBTN_LEFT_DBL 全屏，
        // 双击视频会弹出一个独立全屏窗，整个交互就串了。输入全走 IPC + 网页层控件
        .arg("--no-input-default-bindings")
        .arg("--osc=no")
        .arg("--sid=no")
        .arg("--cursor-autohide=3000")
        .arg(format!("--input-conf={}", input_file.display()))
        .arg("--input-ipc-server=".to_string() + &pipe_name);

    if let Some(s) = start_secs {
        cmd.arg(format!("--start={}", s));
    }

    for sub in native_subtitle_urls {
        cmd.arg(format!("--sub-file={sub}"));
    }

    let child = match cmd.spawn() {
        Ok(child) => child,
        Err(error) => {
            stop_embedded_player_inner(instance_id).ok();
            return Err(format!("启动 mpv 失败: {error}"));
        }
    };
    let pid = child.id();
    *MPV_PROCESS.lock().unwrap() = Some(child);
    // 管道名必须存下来：send_mpv_command_embedded 全靠它找到 mpv。
    // mpv 是异步建管道的，spawn 返回时管道可能还没就绪，首条命令偶发连不上属正常
    *MPV_PIPE.lock().unwrap() = Some(pipe_name.clone());
    *MPV_IPC.lock().unwrap() = Some(crate::mpv_ipc::Session::start(
        pipe_name.clone(),
        instance_id.unwrap_or(0),
        Some(app),
    ));

    // 视频子窗口在 WebView2 下面（见 resize 的 HWND_BOTTOM），网页层不挖空就整块黑掉没画面
    set_webview_hole(parent_hwnd, x, y, width, height, &[], &[]);

    eprintln!(
        "[embedded-player] mpv started, pid={}, hwnd={}, pipe={}",
        pid, child_hwnd as isize, pipe_name
    );

    Ok(serde_json::json!({
        "ok": true,
        "pid": pid,
        "hwnd": child_hwnd as isize,
        "pipe": pipe_name
    }))
}

/// 调整视频子窗口的位置和大小，同时把网页层的洞挪到同一块区域。
/// keep_rects: 带内仍要由网页层画的浮层矩形（加载层/设置面板等），挖洞时刨出去
#[tauri::command]
pub fn resize_embedded_player(
    x: i32,
    y: i32,
    width: i32,
    height: i32,
    keep_rects: Option<Vec<[i32; 4]>>,
    keep_radii: Option<Vec<i32>>,
) -> Result<bool, String> {
    let hwnd = CHILD_HWND.load(Ordering::SeqCst);
    if hwnd == 0 {
        return Ok(false);
    }
    unsafe {
        SetWindowPos(
            hwnd as *mut _,
            HWND_BOTTOM as *mut _,
            x,
            y,
            width,
            height,
            SWP_SHOWWINDOW,
        );
    }
    set_webview_hole(
        PARENT_HWND.load(Ordering::SeqCst),
        x,
        y,
        width,
        height,
        keep_rects.as_deref().unwrap_or(&[]),
        keep_radii.as_deref().unwrap_or(&[]),
    );
    Ok(true)
}

/// 显示/隐藏视频子窗口
#[tauri::command]
pub fn set_embedded_player_visible(visible: bool) -> Result<bool, String> {
    let hwnd = CHILD_HWND.load(Ordering::SeqCst);
    if hwnd == 0 {
        return Ok(false);
    }
    unsafe {
        if visible {
            ShowWindow(hwnd as *mut _, 5); // SW_SHOW
        } else {
            ShowWindow(hwnd as *mut _, 0); // SW_HIDE
        }
    }
    Ok(true)
}

/// 停止嵌入式播放器
#[tauri::command]
pub fn stop_embedded_player(instance_id: Option<u64>) -> Result<bool, String> {
    let _lifecycle = MPV_LIFECYCLE.lock().map_err(|_| "播放器生命周期锁不可用")?;
    stop_embedded_player_inner(instance_id)
}

fn stop_embedded_player_inner(instance_id: Option<u64>) -> Result<bool, String> {
    if instance_id.is_some_and(|id| id != MPV_INSTANCE_ID.load(Ordering::SeqCst)) {
        return Ok(false);
    }
    for id in MPV_MEDIA_GRANTS.lock().unwrap().drain(..) {
        crate::media_stream::release(&id);
    }
    MPV_SUBTITLE_SOURCES.lock().unwrap().clear();
    if let Some(ipc) = MPV_IPC.lock().unwrap().take() {
        ipc.stop();
    }
    // 停止 mpv 进程
    {
        let mut guard = MPV_PROCESS.lock().unwrap();
        if let Some(child) = guard.as_mut() {
            let _ = child.kill();
            let _ = child.wait();
            *guard = None;
        }
    }
    *MPV_PIPE.lock().unwrap() = None;
    if let Some(path) = MPV_INPUT_FILE.lock().unwrap().take() {
        let _ = std::fs::remove_file(path);
    }
    MPV_INSTANCE_ID.store(0, Ordering::SeqCst);
    *HOST_INPUT.lock().unwrap() = None;

    // 销毁子窗口
    let hwnd = CHILD_HWND.swap(0, Ordering::SeqCst);
    if hwnd != 0 {
        unsafe {
            DestroyWindow(hwnd as *mut _);
        }
    }

    // 网页层的洞填回去，否则主界面上会一直缺一块
    clear_webview_hole(PARENT_HWND.swap(0, Ordering::SeqCst));
    Ok(true)
}

/// 正常 EOF 由 eof-reached 表示；进程退出另行归因，不能伪装成播完。
#[tauri::command]
pub fn get_embedded_player_status(instance_id: Option<u64>) -> Result<serde_json::Value, String> {
    let _lifecycle = MPV_LIFECYCLE.lock().map_err(|_| "播放器生命周期锁不可用")?;
    player_status_inner(instance_id)
}

fn player_status_inner(instance_id: Option<u64>) -> Result<serde_json::Value, String> {
    if instance_id.is_some_and(|id| id != MPV_INSTANCE_ID.load(Ordering::SeqCst)) {
        return Ok(serde_json::json!({ "running": false, "stale": true }));
    }
    let mut process = MPV_PROCESS.lock().map_err(|_| "播放器进程锁不可用")?;
    let Some(child) = process.as_mut() else {
        return Ok(serde_json::json!({ "running": false }));
    };
    match child.try_wait().map_err(|error| error.to_string())? {
        None => Ok(serde_json::json!({ "running": true })),
        Some(status) => Ok(serde_json::json!({ "running": false, "exit_code": status.code() })),
    }
}

#[tauri::command]
pub fn get_embedded_player_state(instance_id: Option<u64>) -> Result<serde_json::Value, String> {
    let _lifecycle = MPV_LIFECYCLE.lock().map_err(|_| "播放器生命周期锁不可用")?;
    let status = player_status_inner(instance_id)?;
    if status["stale"] == true {
        return Ok(serde_json::json!({ "status": status, "properties": {} }));
    }
    for id in MPV_MEDIA_GRANTS.lock().unwrap().iter() {
        crate::media_stream::renew(id);
    }
    let mut properties = MPV_IPC
        .lock()
        .unwrap()
        .as_ref()
        .map(|ipc| ipc.snapshot())
        .unwrap_or_else(|| serde_json::json!({}));
    properties["subtitle-source-order"] =
        serde_json::json!(MPV_SUBTITLE_SOURCES.lock().unwrap().clone());
    Ok(serde_json::json!({ "status": status, "properties": properties }))
}

/// 发送一条命令到 mpv JSON IPC，返回 mpv 的响应对象。
/// 协议：管道上写一行 `{"command":[...],"request_id":N}`，再按 request_id 收响应；
/// 管道里还会混着 `{"event":...}` 异步事件，按 request_id 过滤掉
#[tauri::command]
pub async fn send_mpv_command_embedded(
    command: Vec<serde_json::Value>,
    instance_id: Option<u64>,
) -> Result<serde_json::Value, String> {
    let ipc = {
        let _lifecycle = MPV_LIFECYCLE.lock().map_err(|_| "播放器生命周期锁不可用")?;
        if instance_id.is_some_and(|id| id != MPV_INSTANCE_ID.load(Ordering::SeqCst)) {
            return Err("播放请求已被替换".into());
        }
        MPV_IPC.lock().unwrap().clone().ok_or("mpv 未运行")?
    };
    ipc.command(command).await
}
