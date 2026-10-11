//! Verified update downloads. UI callers supply a release tag or an opaque handle.
use reqwest::{Client, Url};
use serde::Serialize;
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    io::{Read, Write},
    path::{Path, PathBuf},
    sync::{
        atomic::{AtomicBool, Ordering},
        LazyLock, Mutex,
    },
    time::{Duration, Instant},
};
use tauri::Emitter;
use tokio_util::sync::CancellationToken;

const LIMIT: u64 = 512 * 1024 * 1024;
static HTTP: LazyLock<Client> = LazyLock::new(|| {
    Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .connect_timeout(Duration::from_secs(10))
        .read_timeout(Duration::from_secs(30))
        .user_agent("MovieClaw-Desktop")
        .build()
        .expect("update client")
});
static PENDING: LazyLock<Mutex<HashMap<String, CancellationToken>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));
static SHUTTING_DOWN: AtomicBool = AtomicBool::new(false);
static CLEANUP_FAILED: AtomicBool = AtomicBool::new(false);
static VERIFIED: LazyLock<Mutex<HashMap<String, CachedUpdate>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DownloadedUpdate {
    pub download_id: String,
    pub version: String,
    pub size: u64,
    pub sha256: String,
    pub signature: String,
    pub signer: Option<String>,
    pub format: String,
    pub filename: String,
}
#[derive(Clone)]
struct CachedUpdate {
    metadata: DownloadedUpdate,
    path: PathBuf,
    created: Instant,
}
struct Cleanup {
    id: String,
    directory: PathBuf,
    keep: bool,
}
type SignatureTask = tokio::task::JoinHandle<Result<(String, Option<String>), String>>;

async fn settle_verifier(task: &mut Option<SignatureTask>, cancellation: &CancellationToken) {
    if let Some(task) = task.take() {
        cancellation.cancel();
        // A running spawn_blocking task cannot be aborted. Wait until its child
        // has been killed/reaped before Cleanup can remove the downloaded file.
        let _ = task.await;
    }
}
impl Drop for Cleanup {
    fn drop(&mut self) {
        if !self.keep {
            if let Err(error) = std::fs::remove_dir_all(&self.directory) {
                if error.kind() != std::io::ErrorKind::NotFound {
                    CLEANUP_FAILED.store(true, Ordering::SeqCst);
                }
            }
        }
        // Retire only after handles are settled and cleanup has been attempted.
        PENDING.lock().unwrap().remove(&self.id);
    }
}
fn register_download(id: &str, cancellation: &CancellationToken) -> Result<(), String> {
    let mut pending = PENDING.lock().unwrap();
    if SHUTTING_DOWN.load(Ordering::SeqCst) {
        return Err(error("UPDATE_SHUTDOWN", "程序正在退出，不能开始更新下载"));
    }
    if !pending.is_empty() {
        return Err(error("UPDATE_BUSY", "已有更新正在下载"));
    }
    pending.insert(id.to_owned(), cancellation.clone());
    Ok(())
}

pub(crate) async fn cancel_all_and_wait(deadline: Duration) -> bool {
    {
        // Registration and retirement share this lock, closing the late-start gap.
        let pending = PENDING.lock().unwrap();
        SHUTTING_DOWN.store(true, Ordering::SeqCst);
        for cancellation in pending.values() {
            cancellation.cancel();
        }
    }
    tokio::time::timeout(deadline, async {
        loop {
            if PENDING.lock().unwrap().is_empty() {
                return !CLEANUP_FAILED.load(Ordering::SeqCst);
            }
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
    })
    .await
    .unwrap_or(false)
}
fn error(code: &str, message: &str) -> String {
    json!({"code":code,"message":message}).to_string()
}
pub(super) fn valid_tag(tag: &str) -> bool {
    let Some(version) = tag
        .strip_prefix("desktop-v")
        .or_else(|| tag.strip_prefix('v'))
    else {
        return false;
    };
    let parts: Vec<_> = version.split('.').collect();
    parts.len() == 3
        && parts.iter().all(|v| {
            !v.is_empty()
                && v.len() <= 9
                && v.bytes().all(|c| c.is_ascii_digit())
                && (v.len() == 1 || !v.starts_with('0'))
        })
}
pub(super) fn delivery_url(value: &str) -> Result<Url, String> {
    let url = Url::parse(value).map_err(|_| error("UPDATE_URL", "更新下载地址无效"))?;
    if url.scheme() != "https"
        || url.port().is_some_and(|v| v != 443)
        || !url.username().is_empty()
        || url.password().is_some()
        || url.fragment().is_some()
        || !matches!(
            url.host_str(),
            Some(
                "github.com"
                    | "api.github.com"
                    | "release-assets.githubusercontent.com"
                    | "objects.githubusercontent.com"
            )
        )
    {
        return Err(error("UPDATE_URL", "更新地址不属于受信任的 GitHub 发布源"));
    }
    Ok(url)
}
fn asset_url(asset: &Value, tag: &str, name: &str) -> Result<Url, String> {
    let expected = format!(
        "https://github.com/{}/releases/download/{tag}/{name}",
        super::GITHUB_REPO
    );
    let value = asset["browser_download_url"]
        .as_str()
        .ok_or_else(|| error("UPDATE_ASSET", "发布资源缺少下载地址"))?;
    if value != expected {
        return Err(error("UPDATE_ASSET", "发布资源的仓库或文件名不匹配"));
    }
    delivery_url(value)
}
async fn response(mut url: Url) -> Result<reqwest::Response, String> {
    for hop in 0..=5 {
        let result = tokio::time::timeout(
            Duration::from_secs(30),
            HTTP.get(url.clone())
                .header("Cache-Control", "no-cache")
                .header(
                    "Accept",
                    if url.host_str() == Some("api.github.com") {
                        "application/vnd.github+json"
                    } else {
                        "application/octet-stream"
                    },
                )
                .send(),
        )
        .await
        .map_err(|_| error("UPDATE_TIMEOUT", "更新服务器响应超时"))?
        .map_err(|_| error("UPDATE_NETWORK", "更新服务器暂时无法连接"))?;
        if result.status().is_redirection() {
            if hop == 5 {
                return Err(error("UPDATE_REDIRECT", "更新下载重定向过多"));
            }
            let location = result
                .headers()
                .get("location")
                .and_then(|v| v.to_str().ok())
                .ok_or_else(|| error("UPDATE_REDIRECT", "更新重定向无效"))?;
            url = delivery_url(
                url.join(location)
                    .map_err(|_| error("UPDATE_REDIRECT", "更新重定向无效"))?
                    .as_str(),
            )?;
            continue;
        }
        if !result.status().is_success() {
            return Err(error("UPDATE_HTTP", "发布资源暂时不可用，请稍后重试"));
        }
        return Ok(result);
    }
    unreachable!()
}
pub(super) async fn small(url: Url, max: usize) -> Result<Vec<u8>, String> {
    small_with_deadline(url, max, Duration::from_secs(30)).await
}
async fn small_with_deadline(url: Url, max: usize, deadline: Duration) -> Result<Vec<u8>, String> {
    // Bound the complete redirect/header/body operation, including a server that
    // continuously sends tiny chunks before the HTTP client's idle timeout.
    tokio::time::timeout(deadline, async {
        let mut result = response(url).await?;
        let mut output = Vec::new();
        while let Some(bytes) = result
            .chunk()
            .await
            .map_err(|_| error("UPDATE_NETWORK", "更新响应中断"))?
        {
            if output.len() + bytes.len() > max {
                return Err(error("UPDATE_RESPONSE", "更新响应超过大小限制"));
            }
            output.extend_from_slice(&bytes);
        }
        Ok(output)
    })
    .await
    .map_err(|_| error("UPDATE_TIMEOUT", "更新服务器响应超时"))?
}
fn checksum(text: &str, filename: &str) -> Result<String, String> {
    let mut found = None;
    for line in text.lines() {
        let fields: Vec<_> = line.split_whitespace().collect();
        if fields.len() != 2 || fields[1].trim_start_matches('*') != filename {
            continue;
        }
        let hash = fields[0];
        if found.is_some() || hash.len() != 64 || !hash.bytes().all(|v| v.is_ascii_hexdigit()) {
            return Err(error("UPDATE_HASH", "发布校验清单无效"));
        }
        found = Some(hash.to_ascii_lowercase());
    }
    found.ok_or_else(|| {
        error(
            "UPDATE_HASH_MISSING",
            "该版本缺少 SHA-256 校验清单，请使用发布页手动下载",
        )
    })
}
fn progress(
    app: &tauri::AppHandle,
    id: &str,
    version: &str,
    state: &str,
    received: u64,
    total: u64,
) {
    let _ = app.emit("movieclaw:update-progress", json!({"downloadId":id,"version":version,"state":state,"received":received,"total":total,"percent":if total>0 {Some((received as f64/total as f64*100.0).min(100.0))} else {None}}));
}
fn cache_directory() -> PathBuf {
    crate::connect::config_dir().join("updates")
}
fn clean_cache() {
    let mut cache = VERIFIED.lock().unwrap();
    cache.retain(|_, item| {
        if item.created.elapsed() < Duration::from_secs(86400) {
            true
        } else {
            let _ = std::fs::remove_dir_all(item.path.parent().unwrap());
            false
        }
    });
    // Unregistered files from a terminated application are never executable update handles.
    if let Ok(entries) = std::fs::read_dir(cache_directory()) {
        for entry in entries.flatten() {
            let directory = entry.path();
            let active = cache
                .values()
                .any(|item| item.path.parent() == Some(directory.as_path()))
                || PENDING
                    .lock()
                    .unwrap()
                    .contains_key(&entry.file_name().to_string_lossy().into_owned());
            if !active {
                let _ = std::fs::remove_dir_all(directory);
            }
        }
    }
}

#[tauri::command]
pub async fn download_update(
    app: tauri::AppHandle,
    version: String,
) -> Result<DownloadedUpdate, String> {
    if SHUTTING_DOWN.load(Ordering::SeqCst) {
        return Err(error("UPDATE_SHUTDOWN", "程序正在退出，不能开始更新下载"));
    }
    if !valid_tag(&version)
        || super::parse_version(&version) < super::parse_version(super::CURRENT_VERSION)
    {
        return Err(error("UPDATE_VERSION", "只能下载较新的正式版本"));
    }
    clean_cache();
    let id = crate::credential_vault::random_id()?;
    let cancellation = CancellationToken::new();
    register_download(&id, &cancellation)?;
    let directory = cache_directory().join(&id);
    let mut cleanup = Cleanup {
        id: id.clone(),
        directory: directory.clone(),
        keep: false,
    };
    progress(&app, &id, &version, "downloading", 0, 0);
    let mut verifier = None;
    let operation = async {
        let release_url = delivery_url(&format!(
            "https://api.github.com/repos/{}/releases/tags/{version}",
            super::GITHUB_REPO
        ))?;
        let release: Value = serde_json::from_slice(&small(release_url, 1024 * 1024).await?)
            .map_err(|_| error("UPDATE_RELEASE", "发布信息无效"))?;
        if release["tag_name"] != version
            || release["draft"].as_bool() != Some(false)
            || release["prerelease"].as_bool() != Some(false)
        {
            return Err(error("UPDATE_RELEASE", "该版本不是可安装的正式发布"));
        }
        if super::parse_version(&version) == super::parse_version(super::CURRENT_VERSION)
            && super::same_version_update(&release).await?.is_none()
        {
            return Err(error("UPDATE_VERSION", "该版本没有较新的构建"));
        }
        let assets = release["assets"]
            .as_array()
            .ok_or_else(|| error("UPDATE_RELEASE", "发布资源为空"))?;
        let numeric = super::parse_version(&version);
        let name_version = format!("{}.{}.{}", numeric.0, numeric.1, numeric.2);
        let mut selected = None;
        for (suffix, format) in [("Setup-x64.exe", "nsis"), ("portable-x64.zip", "portable")] {
            let name = format!("MovieClaw-Desktop-{name_version}-{suffix}");
            if let Some(asset) = assets
                .iter()
                .find(|asset| asset["name"].as_str() == Some(name.as_str()))
            {
                selected = Some((asset, name, format));
                break;
            }
        }
        let (asset, filename, format) =
            selected.ok_or_else(|| error("UPDATE_ASSET", "发布没有 Windows x64 安装包"))?;
        let size = asset["size"]
            .as_u64()
            .filter(|v| *v > 0 && *v <= LIMIT)
            .ok_or_else(|| error("UPDATE_SIZE", "更新包大小无效"))?;
        let url = asset_url(asset, &version, &filename)?;
        let list = assets
            .iter()
            .find(|v| v["name"] == "SHA256SUMS.txt")
            .ok_or_else(|| {
                error(
                    "UPDATE_HASH_MISSING",
                    "该版本缺少 SHA-256 校验清单，请使用发布页手动下载",
                )
            })?;
        let sums = small(asset_url(list, &version, "SHA256SUMS.txt")?, 64 * 1024).await?;
        let expected = checksum(
            std::str::from_utf8(&sums).map_err(|_| error("UPDATE_HASH", "发布校验清单无效"))?,
            &filename,
        )?;
        if let Some(digest) = asset["digest"].as_str() {
            if digest != format!("sha256:{expected}") {
                return Err(error("UPDATE_HASH", "GitHub 资源摘要与发布校验清单不一致"));
            }
        }
        std::fs::create_dir_all(&directory)
            .map_err(|_| error("UPDATE_STORAGE", "无法创建更新缓存"))?;
        let temporary = directory.join("download.part");
        let source = response(url).await?;
        let mut last = Instant::now();
        progress(&app, &id, &version, "downloading", 0, size);
        let actual = download_file(source, &temporary, size, |received| {
            if last.elapsed() >= Duration::from_millis(200) {
                progress(&app, &id, &version, "downloading", received, size);
                last = Instant::now();
            }
        })
        .await?;
        if actual != expected {
            return Err(error("UPDATE_HASH", "更新包 SHA-256 校验失败，文件已丢弃"));
        }
        let received = size;
        progress(&app, &id, &version, "verifying", received, size);
        let path = directory.join(&filename);
        std::fs::rename(&temporary, &path)
            .map_err(|_| error("UPDATE_STORAGE", "无法提交更新缓存"))?;
        let signature_path = path.clone();
        let (signature, signer) = if format == "nsis" {
            let verification_cancellation = cancellation.clone();
            verifier = Some(tokio::task::spawn_blocking(move || {
                signature(&signature_path, &verification_cancellation)
            }));
            let result = verifier.as_mut().unwrap().await;
            verifier.take();
            result.map_err(|_| error("UPDATE_SIGNATURE", "签名验证无法完成"))??
        } else {
            ("unsigned".into(), None)
        };
        let metadata = DownloadedUpdate {
            download_id: id.clone(),
            version: version.clone(),
            size,
            sha256: expected,
            signature,
            signer,
            format: format.into(),
            filename,
        };
        VERIFIED.lock().unwrap().insert(
            id.clone(),
            CachedUpdate {
                metadata: metadata.clone(),
                path,
                created: Instant::now(),
            },
        );
        Ok(metadata)
    };
    let result = tokio::select! { biased; _=cancellation.cancelled()=>Err(error("UPDATE_CANCELLED", "更新下载已取消")), result=operation=>result };
    settle_verifier(&mut verifier, &cancellation).await;
    match &result {
        Ok(metadata) => {
            cleanup.keep = true;
            progress(&app, &id, &version, "ready", metadata.size, metadata.size);
        }
        Err(_) => {
            VERIFIED.lock().unwrap().remove(&id);
            progress(
                &app,
                &id,
                &version,
                if cancellation.is_cancelled() {
                    "cancelled"
                } else {
                    "error"
                },
                0,
                0,
            );
        }
    }
    result
}

async fn download_file(
    mut source: reqwest::Response,
    temporary: &Path,
    size: u64,
    mut update: impl FnMut(u64),
) -> Result<String, String> {
    if source.content_length().is_some_and(|v| v != size) {
        return Err(error("UPDATE_SIZE", "更新包长度与发布信息不符"));
    }
    let mut file = std::fs::OpenOptions::new()
        .create_new(true)
        .write(true)
        .open(temporary)
        .map_err(|_| error("UPDATE_STORAGE", "无法创建更新文件"))?;
    let mut hasher = Sha256::new();
    let mut received = 0;
    while let Some(bytes) = source
        .chunk()
        .await
        .map_err(|_| error("UPDATE_NETWORK", "更新下载中断"))?
    {
        received += bytes.len() as u64;
        if received > size || received > LIMIT {
            return Err(error("UPDATE_SIZE", "更新包超过声明大小"));
        }
        file.write_all(&bytes)
            .map_err(|_| error("UPDATE_STORAGE", "更新文件无法保存"))?;
        hasher.update(&bytes);
        update(received);
    }
    if received != size {
        return Err(error("UPDATE_SIZE", "更新包下载不完整"));
    }
    file.sync_all()
        .map_err(|_| error("UPDATE_STORAGE", "更新文件无法同步"))?;
    Ok(format!("{:x}", hasher.finalize()))
}

#[tauri::command]
pub fn cancel_update_download(download_id: String) -> bool {
    if let Some(token) = PENDING.lock().unwrap().get(&download_id) {
        token.cancel();
        return true;
    }
    if let Some(item) = VERIFIED.lock().unwrap().remove(&download_id) {
        let _ = std::fs::remove_dir_all(item.path.parent().unwrap());
        return true;
    }
    false
}
fn cached(id: &str) -> Result<CachedUpdate, String> {
    VERIFIED
        .lock()
        .unwrap()
        .get(id)
        .filter(|v| v.created.elapsed() < Duration::from_secs(86400))
        .cloned()
        .ok_or_else(|| error("UPDATE_HANDLE", "更新缓存已失效，请重新下载"))
}
fn verify_file(item: &CachedUpdate) -> Result<std::fs::File, String> {
    let mut options = std::fs::OpenOptions::new();
    options.read(true);
    #[cfg(windows)]
    {
        use std::os::windows::fs::OpenOptionsExt;
        options.share_mode(1);
    }
    let mut file = options
        .open(&item.path)
        .map_err(|_| error("UPDATE_STORAGE", "更新文件已不可用"))?;
    let mut hash = Sha256::new();
    let mut buffer = [0; 64 * 1024];
    let mut length = 0;
    loop {
        let n = file
            .read(&mut buffer)
            .map_err(|_| error("UPDATE_STORAGE", "更新文件无法读取"))?;
        if n == 0 {
            break;
        }
        hash.update(&buffer[..n]);
        length += n as u64;
    }
    if length != item.metadata.size || format!("{:x}", hash.finalize()) != item.metadata.sha256 {
        return Err(error("UPDATE_HASH", "更新缓存已被更改，不能安装"));
    }
    Ok(file)
}
#[tauri::command]
pub async fn install_downloaded_update(
    app: tauri::AppHandle,
    download_id: String,
    allow_unsigned: Option<bool>,
) -> Result<Value, String> {
    let item = cached(&download_id)?;
    if item.metadata.format != "nsis" {
        return Err(error("UPDATE_PORTABLE", "便携包请关闭程序后手动解压替换"));
    }
    #[cfg(not(windows))]
    {
        let _ = (app, allow_unsigned);
        return Err(error("UPDATE_PLATFORM", "安装更新仅支持 Windows"));
    }
    #[cfg(windows)]
    {
        let process = tokio::task::spawn_blocking(move || {
            let _lock = verify_file(&item)?;
            let (signature, _) = signature(&item.path, &CancellationToken::new())?;
            if signature == "unsigned" && !allow_unsigned.unwrap_or(false) {
                return Err(error(
                    "UPDATE_UNSIGNED",
                    "此更新没有发行者签名，请确认后再安装",
                ));
            }
            std::process::Command::new(&item.path)
                .current_dir(item.path.parent().unwrap())
                .spawn()
                .map_err(|_| error("UPDATE_INSTALL", "无法启动安装程序"))?;
            Ok::<(), String>(())
        })
        .await
        .map_err(|_| error("UPDATE_INSTALL", "无法启动安装程序"))??;
        let _ = process;
        crate::request_shutdown(&app);
        Ok(json!({"installing":true}))
    }
}
#[tauri::command]
pub fn open_downloaded_update(download_id: String) -> Result<bool, String> {
    let item = cached(&download_id)?;
    let _guard = verify_file(&item)?;
    #[cfg(windows)]
    {
        std::process::Command::new(system_directory()?.parent().unwrap().join("explorer.exe"))
            .arg("/select,")
            .arg(&item.path)
            .spawn()
            .map_err(|_| error("UPDATE_OPEN", "无法显示下载的更新"))?;
    }
    #[cfg(not(windows))]
    {
        return Err(error("UPDATE_PLATFORM", "此功能仅支持 Windows"));
    }
    #[cfg(windows)]
    {
        Ok(true)
    }
}
#[cfg(windows)]
fn system_directory() -> Result<PathBuf, String> {
    #[link(name = "kernel32")]
    extern "system" {
        fn GetSystemDirectoryW(buffer: *mut u16, size: u32) -> u32;
    }
    let mut buffer = [0u16; 32768];
    let length = unsafe { GetSystemDirectoryW(buffer.as_mut_ptr(), buffer.len() as u32) } as usize;
    if length == 0 || length >= buffer.len() {
        return Err(error("UPDATE_PLATFORM", "无法定位 Windows 系统目录"));
    }
    Ok(PathBuf::from(String::from_utf16_lossy(&buffer[..length])))
}
#[cfg(any(windows, test))]
struct VerifierProcess(std::process::Child);
#[cfg(windows)]
const POWERSHELL_JSON_OUTPUT: &str = r#"
function Write-MovieClawJson($value) {
    $json = ConvertTo-Json -InputObject $value -Compress -Depth 4;
    $writer = [System.IO.StreamWriter]::new([Console]::OpenStandardOutput(), [System.Text.UTF8Encoding]::new($false));
    try { $writer.Write($json); $writer.Flush(); } finally { $writer.Dispose(); }
}
"#;
#[cfg(any(windows, test))]
fn signature_process_error(exit_code: Option<i32>, output: &str) -> String {
    let value: Value =
        serde_json::from_str(output.trim_start_matches('\u{feff}')).unwrap_or(Value::Null);
    let identifier = |key: &str| {
        value[key].as_str().filter(|value| {
            !value.is_empty()
                && value.len() <= 128
                && value
                    .bytes()
                    .all(|v| v.is_ascii_alphanumeric() || matches!(v, b'.' | b'_' | b'-'))
        })
    };
    // Only fixed stage/type/version identifiers and numeric HRESULTs survive.
    // Never include stderr, exception messages, paths or raw script output.
    json!({"code":"UPDATE_SIGNATURE", "message":"Windows 签名验证失败", "exitCode":exit_code,
        "diagnostics":{"stage":identifier("stage"), "exceptionType":identifier("exceptionType"),
            "powershell":identifier("powershell"), "hresult":value["hresult"].as_i64()}})
    .to_string()
}
#[cfg(any(windows, test))]
impl Drop for VerifierProcess {
    fn drop(&mut self) {
        let _ = self.0.kill();
        let _ = self.0.wait();
    }
}
#[cfg(any(windows, test))]
fn verifier_output(
    child: std::process::Child,
    cancellation: &CancellationToken,
    deadline: Duration,
) -> Result<String, String> {
    let mut child = VerifierProcess(child);
    let start = Instant::now();
    let status = loop {
        if cancellation.is_cancelled() {
            return Err(error("UPDATE_CANCELLED", "更新下载已取消"));
        }
        match child.0.try_wait() {
            Ok(Some(status)) => break status,
            Err(_) => return Err(error("UPDATE_SIGNATURE", "无法读取签名验证进程状态")),
            Ok(None) if start.elapsed() >= deadline => {
                return Err(error("UPDATE_SIGNATURE", "Windows 签名验证超时"));
            }
            Ok(None) => std::thread::sleep(Duration::from_millis(50)),
        }
    };
    let mut output = String::new();
    child
        .0
        .stdout
        .take()
        .ok_or_else(|| error("UPDATE_SIGNATURE", "签名验证响应无效"))?
        .take(16 * 1024)
        .read_to_string(&mut output)
        .map_err(|_| error("UPDATE_SIGNATURE", "签名验证响应无效"))?;
    if !status.success() {
        return Err(signature_process_error(status.code(), &output));
    }
    Ok(output)
}
fn signature(
    path: &Path,
    cancellation: &CancellationToken,
) -> Result<(String, Option<String>), String> {
    if cancellation.is_cancelled() {
        return Err(error("UPDATE_CANCELLED", "更新下载已取消"));
    }
    #[cfg(not(windows))]
    {
        let _ = path;
        Err(error("UPDATE_PLATFORM", "签名验证仅支持 Windows"))
    }
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        let executable = system_directory()?.join("WindowsPowerShell/v1.0/powershell.exe");
        // A child started through Rust inherits PowerShell 7's module paths.
        // Windows PowerShell 5.1 cannot load those Security module versions.
        // Select its system modules and import Security by its absolute path.
        // Write JSON directly as UTF-8, independently of console code pages.
        let script = format!(
            "{POWERSHELL_JSON_OUTPUT}\n{}",
            r#"
$ErrorActionPreference='Stop';
$stage='import-security';
try {
    Import-Module -Name (Join-Path $PSHOME 'Modules\Microsoft.PowerShell.Security\Microsoft.PowerShell.Security.psd1') -ErrorAction Stop;
    $stage='authenticode';
    $s=Microsoft.PowerShell.Security\Get-AuthenticodeSignature -LiteralPath $env:MOVIECLAW_UPDATE_FILE;
    $signer=if ($s.SignerCertificate) { $s.SignerCertificate.Subject } else { $null };
    $stage='serialize';
    Write-MovieClawJson @{status=$s.Status.ToString();signer=$signer};
} catch {
    $exception=$_.Exception;
    while ($exception.InnerException) { $exception=$exception.InnerException; }
    Write-MovieClawJson @{stage=$stage;exceptionType=$exception.GetType().FullName;hresult=$exception.HResult;powershell=$PSVersionTable.PSVersion.ToString()};
    exit 1;
}
"#
        );
        let child = std::process::Command::new(executable)
            .args([
                "-NoLogo",
                "-NoProfile",
                "-NonInteractive",
                "-Command",
                &script,
            ])
            .env(
                "PSModulePath",
                system_directory()?.join("WindowsPowerShell/v1.0/Modules"),
            )
            .env("MOVIECLAW_UPDATE_FILE", path)
            .creation_flags(0x08000000)
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null())
            .spawn()
            .map_err(|_| error("UPDATE_SIGNATURE", "无法启动 Windows 签名验证"))?;
        let output = verifier_output(child, cancellation, Duration::from_secs(20))?;
        let value: Value = serde_json::from_str(output.trim_start_matches('\u{feff}'))
            .map_err(|_| error("UPDATE_SIGNATURE", "签名验证响应无效"))?;
        match value["status"].as_str() {
            Some("Valid") => Ok(("valid".into(), value["signer"].as_str().map(str::to_owned))),
            Some("NotSigned") => Ok(("unsigned".into(), None)),
            _ => Err(error(
                "UPDATE_SIGNATURE_INVALID",
                "更新包的签名无效，不能安装",
            )),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    static SERIAL_PENDING: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());
    struct ResetShutdown;
    impl Drop for ResetShutdown {
        fn drop(&mut self) {
            SHUTTING_DOWN.store(false, Ordering::SeqCst);
            CLEANUP_FAILED.store(false, Ordering::SeqCst);
        }
    }
    #[test]
    fn verifier_failure_diagnostics_keep_only_bounded_identifiers_and_hresult() {
        let output = json!({"stage":"authenticode", "exceptionType":"System.IO.IOException",
            "hresult":-2147024890i64, "powershell":"5.1.20348.1",
            "message":"secret C:\\Users\\private\\download.exe", "stderr":"token=secret"})
        .to_string();
        let diagnostic: Value =
            serde_json::from_str(&signature_process_error(Some(1), &output)).unwrap();
        assert_eq!(diagnostic["diagnostics"]["hresult"], -2147024890i64);
        assert_eq!(
            diagnostic["diagnostics"]["exceptionType"],
            "System.IO.IOException"
        );
        assert!(!diagnostic.to_string().contains("secret"));
        let rejected: Value = serde_json::from_str(&signature_process_error(Some(1),
            &json!({"stage":"C:\\Users\\private", "exceptionType":"https://signed.example/?token=x",
                "powershell":"x".repeat(129), "hresult":"secret"}).to_string())).unwrap();
        assert_eq!(
            rejected["diagnostics"],
            json!({"stage":null,"exceptionType":null,"powershell":null,"hresult":null})
        );
    }
    #[test]
    fn release_tags_and_delivery_urls_are_strict() {
        for v in ["v0.2.112", "desktop-v1.0.0"] {
            assert!(valid_tag(v));
        }
        for v in [
            "v0.2.112-beta",
            "../tag",
            "v0.2.112/evil",
            "v00.2.112",
            "v0.2.112.1",
        ] {
            assert!(!valid_tag(v));
        }
        for v in [
            "http://github.com/x",
            "https://github.com.evil/x",
            "https://u:p@github.com/x",
            "https://github.com:443/x#fragment",
            "https://evil/x",
        ] {
            assert!(delivery_url(v).is_err());
        }
    }
    #[test]
    fn checksum_requires_unique_exact_filename() {
        let name = "MovieClaw-Desktop-0.2.112-Setup-x64.exe";
        let hash = "a".repeat(64);
        assert_eq!(checksum(&format!("{hash}  {name}\n"), name).unwrap(), hash);
        assert!(checksum(&format!("{hash}  ../{name}\n"), name).is_err());
        assert!(checksum(&format!("{hash}  {name}\n{hash}  {name}"), name).is_err());
    }
    #[test]
    fn changed_download_cannot_be_installed_or_opened() {
        let directory = std::env::temp_dir().join(format!(
            "movieclaw-update-test-{}",
            crate::credential_vault::random_id().unwrap()
        ));
        std::fs::create_dir_all(&directory).unwrap();
        let path = directory.join("test.exe");
        std::fs::write(&path, b"valid").unwrap();
        let metadata = DownloadedUpdate {
            download_id: "test".into(),
            version: "v9.0.0".into(),
            size: 5,
            sha256: format!("{:x}", Sha256::digest(b"valid")),
            signature: "unsigned".into(),
            signer: None,
            format: "nsis".into(),
            filename: "test.exe".into(),
        };
        let item = CachedUpdate {
            metadata,
            path,
            created: Instant::now(),
        };
        assert!(verify_file(&item).is_ok());
        std::fs::write(&item.path, b"changed").unwrap();
        assert!(verify_file(&item).is_err());
        std::fs::remove_dir_all(directory).unwrap();
    }
    #[tokio::test]
    async fn cancelled_transfer_closes_upstream_and_deletes_partial_cache() {
        let _serial = SERIAL_PENDING.lock().await;
        transfer_cleanup(false).await;
    }
    #[tokio::test]
    async fn shutdown_cancels_transfer_and_waits_for_socket_and_partial_cleanup() {
        let _serial = SERIAL_PENDING.lock().await;
        let _reset = ResetShutdown;
        transfer_cleanup(true).await;
    }
    async fn transfer_cleanup(shutdown: bool) {
        use std::io::{Read, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let url = Url::parse(&format!("http://{}/update", listener.local_addr().unwrap())).unwrap();
        let handler = std::thread::spawn(move || {
            let (mut socket, _) = listener.accept().unwrap();
            socket
                .set_read_timeout(Some(Duration::from_secs(3)))
                .unwrap();
            let mut buffer = [0; 4096];
            socket.read(&mut buffer).unwrap();
            socket.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 1048576\r\nConnection: close\r\n\r\npartial-download").unwrap();
            match socket.read(&mut buffer) {
                Ok(0) => {}
                Err(error)
                    if matches!(
                        error.kind(),
                        std::io::ErrorKind::ConnectionReset | std::io::ErrorKind::ConnectionAborted
                    ) => {}
                other => panic!("download socket was retained: {other:?}"),
            }
        });
        let id = crate::credential_vault::random_id().unwrap();
        let directory = std::env::temp_dir().join(format!("movieclaw-download-{id}"));
        std::fs::create_dir_all(&directory).unwrap();
        let cleanup = Cleanup {
            id: id.clone(),
            directory: directory.clone(),
            keep: false,
        };
        let path = directory.join("download.part");
        let result = response(url).await.unwrap();
        let cancellation = CancellationToken::new();
        let _cancel_on_failure = cancellation.clone().drop_guard();
        register_download(&id, &cancellation).unwrap();
        let stop = cancellation.clone();
        let (send, receive) = tokio::sync::oneshot::channel();
        let operation = tokio::spawn(async move {
            let mut send = Some(send);
            let operation = download_file(result, &path, 1048576, move |received| {
                if received > 0 {
                    if let Some(send) = send.take() {
                        let _ = send.send(());
                    }
                }
            });
            tokio::select! {biased; _=stop.cancelled()=>{}, result=operation=>panic!("expected cancellation, got {result:?}")}
            drop(cleanup);
        });
        tokio::time::timeout(Duration::from_secs(3), receive)
            .await
            .unwrap()
            .unwrap();
        assert!(directory.join("download.part").exists());
        if shutdown {
            assert!(cancel_all_and_wait(Duration::from_secs(3)).await);
            assert!(
                register_download("late-download", &CancellationToken::new())
                    .unwrap_err()
                    .contains("UPDATE_SHUTDOWN")
            );
        } else {
            assert!(cancel_update_download(id.clone()));
        }
        operation.await.unwrap();
        assert!(!directory.exists());
        assert!(!PENDING.lock().unwrap().contains_key(&id));
        tokio::task::spawn_blocking(move || handler.join().unwrap())
            .await
            .unwrap();
    }
    #[tokio::test]
    async fn cancelled_verifier_is_reaped_before_partial_cache_and_handle_are_removed() {
        let _serial = SERIAL_PENDING.lock().await;
        verifier_cleanup(false).await;
    }
    #[tokio::test]
    async fn shutdown_waits_for_real_verifier_before_removing_partial_cache() {
        let _serial = SERIAL_PENDING.lock().await;
        let _reset = ResetShutdown;
        verifier_cleanup(true).await;
    }
    async fn verifier_cleanup(shutdown: bool) {
        use std::sync::{
            atomic::{AtomicBool, Ordering},
            Arc,
        };
        let id = crate::credential_vault::random_id().unwrap();
        let directory = std::env::temp_dir().join(format!("movieclaw-verifier-{id}"));
        std::fs::create_dir_all(&directory).unwrap();
        let file = directory.join("download.part");
        let ready = directory.join("process-ready");
        std::fs::write(&file, b"partial-update").unwrap();
        let cancellation = CancellationToken::new();
        let _cancel_on_failure = cancellation.clone().drop_guard();
        register_download(&id, &cancellation).unwrap();
        let cleanup = Cleanup {
            id: id.clone(),
            directory: directory.clone(),
            keep: false,
        };
        #[cfg(windows)]
        let mut command = {
            use std::os::windows::process::CommandExt;
            let mut command = std::process::Command::new(
                system_directory()
                    .unwrap()
                    .join("WindowsPowerShell/v1.0/powershell.exe"),
            );
            // FileShare.Read denies deletion until this real verifier process exits.
            command.args(["-NoLogo", "-NoProfile", "-NonInteractive", "-Command",
                "$ErrorActionPreference='Stop'; $f=[IO.File]::Open($env:MOVIECLAW_UPDATE_FILE,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read); [IO.File]::WriteAllText($env:MOVIECLAW_UPDATE_READY,'ready'); Start-Sleep -Seconds 30"]);
            command.creation_flags(0x08000000);
            command
        };
        #[cfg(not(windows))]
        let mut command = {
            let mut command = std::process::Command::new("/bin/sh");
            command.args([
                "-c",
                "printf ready > \"$MOVIECLAW_UPDATE_READY\"; exec sleep 30",
            ]);
            command
        };
        let child = command
            .env("MOVIECLAW_UPDATE_FILE", &file)
            .env("MOVIECLAW_UPDATE_READY", &ready)
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::null())
            .spawn()
            .unwrap();
        let stopped = Arc::new(AtomicBool::new(false));
        let stopped_task = stopped.clone();
        let verification_cancellation = cancellation.clone();
        let mut verifier: Option<SignatureTask> = Some(tokio::task::spawn_blocking(move || {
            let result =
                verifier_output(child, &verification_cancellation, Duration::from_secs(20));
            assert!(result.unwrap_err().contains("UPDATE_CANCELLED"));
            stopped_task.store(true, Ordering::SeqCst);
            Err(error("UPDATE_CANCELLED", "更新下载已取消"))
        }));
        let started = Instant::now();
        while !ready.exists() {
            assert!(
                started.elapsed() < Duration::from_secs(10),
                "verifier did not acquire its file"
            );
            tokio::time::sleep(Duration::from_millis(10)).await;
        }
        let shutdown_task = if shutdown {
            Some(tokio::spawn(cancel_all_and_wait(Duration::from_secs(3))))
        } else {
            assert!(cancel_update_download(id.clone()));
            None
        };
        tokio::time::timeout(Duration::from_secs(1), cancellation.cancelled())
            .await
            .unwrap();
        assert!(directory.exists());
        assert!(PENDING.lock().unwrap().contains_key(&id));
        if let Some(task) = &shutdown_task {
            assert!(
                !task.is_finished(),
                "shutdown returned before verifier cleanup"
            );
        }
        tokio::time::timeout(
            Duration::from_secs(3),
            settle_verifier(&mut verifier, &cancellation),
        )
        .await
        .unwrap();
        assert!(stopped.load(Ordering::SeqCst));
        assert!(verifier.is_none());
        drop(cleanup);
        assert!(
            !directory.exists(),
            "verifier retained a file handle during cleanup"
        );
        assert!(!PENDING.lock().unwrap().contains_key(&id));
        if let Some(task) = shutdown_task {
            assert!(task.await.unwrap());
        }
    }
    #[tokio::test]
    async fn shutdown_deadline_is_bounded_and_blocks_late_download_registration() {
        let _serial = SERIAL_PENDING.lock().await;
        let _reset = ResetShutdown;
        let id = crate::credential_vault::random_id().unwrap();
        let cancellation = CancellationToken::new();
        register_download(&id, &cancellation).unwrap();
        let started = Instant::now();
        assert!(!cancel_all_and_wait(Duration::from_millis(50)).await);
        assert!(cancellation.is_cancelled());
        assert!(started.elapsed() < Duration::from_secs(1));
        assert!(PENDING.lock().unwrap().contains_key(&id));
        assert!(
            register_download("late-download", &CancellationToken::new())
                .unwrap_err()
                .contains("UPDATE_SHUTDOWN")
        );
        PENDING.lock().unwrap().remove(&id);
    }
    #[tokio::test]
    async fn shutdown_reports_incomplete_cleanup_when_the_filesystem_rejects_deletion() {
        let _serial = SERIAL_PENDING.lock().await;
        let _reset = ResetShutdown;
        let id = crate::credential_vault::random_id().unwrap();
        let directory = std::env::temp_dir().join(format!("movieclaw-rejected-cleanup-{id}"));
        // A real filesystem error: the cache-directory path is occupied by a file.
        std::fs::write(&directory, b"unremovable-as-directory").unwrap();
        register_download(&id, &CancellationToken::new()).unwrap();
        drop(Cleanup {
            id,
            directory: directory.clone(),
            keep: false,
        });
        assert!(directory.exists());
        assert!(!cancel_all_and_wait(Duration::from_millis(50)).await);
        std::fs::remove_file(directory).unwrap();
    }
    #[tokio::test]
    async fn metadata_deadline_closes_continuously_trickling_response() {
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let url = Url::parse(&format!(
            "http://{}/metadata",
            listener.local_addr().unwrap()
        ))
        .unwrap();
        let handler = std::thread::spawn(move || {
            let (mut socket, _) = listener.accept().unwrap();
            socket
                .set_read_timeout(Some(Duration::from_secs(2)))
                .unwrap();
            let mut request = [0; 4096];
            socket.read(&mut request).unwrap();
            socket
                .write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 1000\r\nConnection: close\r\n\r\n")
                .unwrap();
            // This response never reaches a per-read idle timeout while active.
            for _ in 0..100 {
                if socket.write_all(b"x").is_err() {
                    return;
                }
                std::thread::sleep(Duration::from_millis(10));
            }
            panic!("metadata deadline retained the upstream socket");
        });
        let started = Instant::now();
        let result = small_with_deadline(url, 2048, Duration::from_millis(100)).await;
        assert!(result.unwrap_err().contains("UPDATE_TIMEOUT"));
        assert!(started.elapsed() < Duration::from_secs(1));
        tokio::task::spawn_blocking(move || handler.join().unwrap())
            .await
            .unwrap();
    }
    #[cfg(windows)]
    #[test]
    fn windows_consoleless_powershell_writes_utf8_without_console_code_page() {
        use std::os::windows::process::CommandExt;
        let script = format!(
            "{POWERSHELL_JSON_OUTPUT}\n{}",
            r#"
$ErrorActionPreference='Stop';
$legacy=@{hresult=$null;exceptionType=$null};
try { [Console]::OutputEncoding=[System.Text.UTF8Encoding]::new($false); } catch {
    $exception=$_.Exception;
    while ($exception.InnerException) { $exception=$exception.InnerException; }
    $legacy=@{hresult=$exception.HResult;exceptionType=$exception.GetType().FullName};
}
Write-MovieClawJson @{signer='发行者 München';legacyConsoleEncoding=$legacy;powershell=$PSVersionTable.PSVersion.ToString()};
"#
        );
        let child = std::process::Command::new(
            system_directory()
                .unwrap()
                .join("WindowsPowerShell/v1.0/powershell.exe"),
        )
        .args([
            "-NoLogo",
            "-NoProfile",
            "-NonInteractive",
            "-Command",
            &script,
        ])
        .creation_flags(0x08000000)
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::null())
        .spawn()
        .unwrap();
        let output =
            verifier_output(child, &CancellationToken::new(), Duration::from_secs(20)).unwrap();
        let value: Value = serde_json::from_str(&output).unwrap();
        assert_eq!(value["signer"], "发行者 München");
        eprintln!(
            "consoleless PowerShell UTF-8 regression: {}",
            json!({
            "powershell":value["powershell"], "legacyConsoleEncoding":value["legacyConsoleEncoding"]})
        );
    }
    #[cfg(windows)]
    #[test]
    fn windows_signature_verifies_actual_unsigned_test_executable() {
        let (state, signer) =
            signature(&std::env::current_exe().unwrap(), &CancellationToken::new()).unwrap();
        assert_eq!(state, "unsigned");
        assert!(signer.is_none());
    }
}
