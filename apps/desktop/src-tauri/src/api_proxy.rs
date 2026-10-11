use base64::Engine;
use reqwest::{header, Client, Method};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::sync::{
    atomic::{AtomicU64, Ordering},
    LazyLock, Mutex,
};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tokio_util::sync::CancellationToken;
use url::Url;

// Credentials belong to one configured server base URL, including path and port. Legacy global
// cookies cannot safely be assigned to a server and are deliberately not imported.
type CookieStore = HashMap<String, HashMap<String, SavedCookie>>;
static COOKIES: LazyLock<Mutex<CookieStore>> = LazyLock::new(|| Mutex::new(load_cookies()));
struct PendingRequest {
    cancellation: CancellationToken,
    generation: u64,
}
static REQUESTS: LazyLock<Mutex<HashMap<String, PendingRequest>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));
static NEXT_REQUEST: AtomicU64 = AtomicU64::new(1);
static CLIENT: LazyLock<Client> = LazyLock::new(|| {
    Client::builder()
        .connect_timeout(Duration::from_secs(5))
        .read_timeout(Duration::from_secs(20))
        .redirect(reqwest::redirect::Policy::none())
        .build()
        .expect("HTTP client configuration")
});

#[derive(Clone, Serialize, Deserialize)]
struct SavedCookie {
    value: String,
    path: String,
    secure: bool,
    expires_at: Option<i64>,
}

fn now_seconds() -> i64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}

fn cookie_file_path() -> std::path::PathBuf {
    crate::connect::config_dir().join("cookies-v2.json")
}

fn load_cookies() -> CookieStore {
    // Old cookies have no server identity. Retaining them would leave usable
    // unscoped credentials on disk after the migration.
    let _ = std::fs::remove_file(crate::connect::config_dir().join("cookies.json"));
    let bytes = std::fs::read(cookie_file_path()).unwrap_or_default();
    let store = crate::credential_vault::unprotect_disk(&bytes)
        .ok()
        .and_then(|plain| serde_json::from_slice(&plain).ok())
        .unwrap_or_default();
    #[cfg(windows)]
    if !bytes.is_empty() && !bytes.starts_with(b"MC-DPAPI1\n") {
        let _ = save_cookies(&store);
    }
    store
}

fn save_cookies(store: &CookieStore) -> Result<(), String> {
    let path = cookie_file_path();
    let json = serde_json::to_vec(store).map_err(|e| e.to_string())?;
    // The temporary file also prevents a terminated write from corrupting the jar.
    let temp = path.with_extension("tmp");
    let protected = crate::credential_vault::protect_disk(&json)?;
    std::fs::write(&temp, protected).map_err(|e| format!("保存登录状态失败: {e}"))?;
    #[cfg(windows)]
    if path.exists() {
        std::fs::remove_file(&path).map_err(|e| e.to_string())?;
    }
    std::fs::rename(temp, path).map_err(|e| format!("保存登录状态失败: {e}"))
}

fn cookie_header_for(store: &CookieStore, base: &Url, url: &Url) -> Option<String> {
    if !crate::connect::url_in_server_scope(base, url) {
        return None;
    }
    let jar = store.get(&crate::connect::server_namespace(base))?;
    let mut values: Vec<_> = jar
        .iter()
        .filter(|(_, c)| {
            let path_matches = url.path() == c.path
                || (url.path().starts_with(&c.path)
                    && (c.path.ends_with('/')
                        || url.path().as_bytes().get(c.path.len()) == Some(&b'/')));
            path_matches
                && (!c.secure || url.scheme() == "https")
                && c.expires_at.is_none_or(|expiry| expiry > now_seconds())
        })
        .map(|(name, c)| format!("{name}={}", c.value))
        .collect();
    values.sort();
    if values.is_empty() {
        None
    } else {
        Some(values.join("; "))
    }
}

fn cookie_header(base: &Url, url: &Url) -> Option<String> {
    cookie_header_for(&COOKIES.lock().unwrap(), base, url)
}
#[cfg(test)]
fn cookie_header_from(store: &CookieStore, url: &Url) -> Option<String> {
    cookie_header_for(
        store,
        &Url::parse(&url.origin().ascii_serialization()).unwrap(),
        url,
    )
}
#[cfg(test)]
pub(crate) fn test_cookie_header(url: &Url) -> Option<String> {
    cookie_header(
        &Url::parse(&url.origin().ascii_serialization()).unwrap(),
        url,
    )
}
#[derive(Clone, Default)]
pub(crate) struct CookieSnapshot {
    store: CookieStore,
    base: Option<Url>,
}
impl CookieSnapshot {
    pub(crate) fn header(&self, url: &Url) -> Option<String> {
        cookie_header_for(&self.store, self.base.as_ref()?, url)
    }
    #[cfg(test)]
    pub(crate) fn test_cookie(url: &Url, name: &str, value: &str, path: &str) -> Self {
        Self {
            base: Some(Url::parse(&url.origin().ascii_serialization()).unwrap()),
            store: HashMap::from([(
                url.origin().ascii_serialization(),
                HashMap::from([(
                    name.into(),
                    SavedCookie {
                        value: value.into(),
                        path: path.into(),
                        secure: false,
                        expires_at: None,
                    },
                )]),
            )]),
        }
    }
}
pub(crate) fn cookie_snapshot(base: &Url) -> CookieSnapshot {
    let name = crate::connect::server_namespace(base);
    let jar = COOKIES.lock().unwrap().get(&name).cloned();
    CookieSnapshot {
        base: Some(base.clone()),
        store: jar
            .map(|jar| HashMap::from([(name, jar)]))
            .unwrap_or_default(),
    }
}

fn cookie_domain_matches(host: &str, domain: &str) -> bool {
    let domain = domain.trim_start_matches('.').to_ascii_lowercase();
    let host = host.to_ascii_lowercase();
    !domain.is_empty()
        && (host == domain
            || (host.parse::<std::net::IpAddr>().is_err() && host.ends_with(&format!(".{domain}"))))
}

fn capture_cookies(resp: &reqwest::Response, base: &Url, url: &Url) -> Result<(), String> {
    let mut store = COOKIES.lock().unwrap();
    let mut changed = false;
    for val in resp.headers().get_all(header::SET_COOKIE) {
        let Ok(text) = val.to_str() else { continue };
        let Ok(parsed) = cookie::Cookie::parse(text) else {
            continue;
        };
        // A cookie's Domain may narrow storage but never cross an origin.
        if let Some(domain) = parsed.domain() {
            if !url
                .host_str()
                .is_some_and(|host| cookie_domain_matches(host, domain))
            {
                continue;
            }
        }
        let expires_at = parsed
            .max_age()
            .map(|age| now_seconds() + age.whole_seconds())
            .or_else(|| parsed.expires_datetime().map(|date| date.unix_timestamp()));
        let jar = store
            .entry(crate::connect::server_namespace(base))
            .or_default();
        if parsed.value().is_empty() || expires_at.is_some_and(|expiry| expiry <= now_seconds()) {
            jar.remove(parsed.name());
        } else {
            jar.insert(
                parsed.name().to_owned(),
                SavedCookie {
                    value: parsed.value().to_owned(),
                    path: parsed.path().unwrap_or("/").to_owned(),
                    secure: parsed.secure().unwrap_or(false),
                    expires_at,
                },
            );
        }
        changed = true;
    }
    if changed {
        save_cookies(&store)?;
    }
    Ok(())
}

struct RequestRegistration(String);
impl Drop for RequestRegistration {
    fn drop(&mut self) {
        REQUESTS.lock().unwrap().remove(&self.0);
    }
}

fn register_request(
    request_id: Option<String>,
    generation: u64,
) -> Result<(RequestRegistration, CancellationToken), String> {
    let id = request_id
        .unwrap_or_else(|| format!("rust-{}", NEXT_REQUEST.fetch_add(1, Ordering::Relaxed)));
    if id.is_empty() || id.len() > 128 {
        return Err("无效的请求标识".into());
    }
    let token = CancellationToken::new();
    let mut requests = REQUESTS.lock().unwrap();
    if requests.contains_key(&id) {
        return Err("请求标识正在使用".into());
    }
    requests.insert(
        id.clone(),
        PendingRequest {
            cancellation: token.clone(),
            generation,
        },
    );
    Ok((RequestRegistration(id), token))
}

#[tauri::command]
pub fn cancel_proxy_request(request_id: String) -> bool {
    let requests = REQUESTS.lock().unwrap();
    if let Some(request) = requests.get(&request_id) {
        request.cancellation.cancel();
        true
    } else {
        false
    }
}

pub fn cancel_all_requests() {
    for request in REQUESTS.lock().unwrap().values() {
        request.cancellation.cancel();
    }
}
pub(crate) fn cancel_requests_before(epoch: u64) {
    for request in REQUESTS
        .lock()
        .unwrap()
        .values()
        .filter(|request| request.generation < epoch)
    {
        request.cancellation.cancel();
    }
}

#[derive(Serialize)]
pub struct ProxyResponse {
    pub status: u16,
    pub body: String,
    pub headers: HashMap<String, String>,
}

#[derive(Clone, Copy)]
enum ResponseKind {
    Api,
    Image,
    Stream,
}

fn resolve_request(server: &str, path: &str) -> Result<(Url, ResponseKind), String> {
    let (target, kind) = if path.starts_with("/__image__?") || path.starts_with("/__stream__?") {
        let (prefix, query) = path.split_once('?').unwrap();
        let target = url::form_urlencoded::parse(query.as_bytes())
            .find(|(name, _)| name == "url")
            .map(|(_, value)| value.into_owned())
            .ok_or("缺少资源地址")?;
        let full = if target.starts_with("http://") || target.starts_with("https://") {
            target
        } else {
            format!(
                "{}/{}",
                server.trim_end_matches('/'),
                target.trim_start_matches('/')
            )
        };
        (
            full,
            if prefix == "/__image__" {
                ResponseKind::Image
            } else {
                ResponseKind::Stream
            },
        )
    } else {
        if !path.starts_with('/') || path.starts_with("//") {
            return Err("API 路径必须以 / 开头".into());
        }
        (
            format!("{}/api/v1{path}", server.trim_end_matches('/')),
            ResponseKind::Api,
        )
    };
    Ok((crate::connect::validate_http_url(&target)?, kind))
}

#[tauri::command]
pub async fn proxy_api(
    method: String,
    path: String,
    body: Option<String>,
    headers: Option<HashMap<String, String>>,
    request_id: Option<String>,
) -> Result<ProxyResponse, String> {
    let context = crate::native_auth::load_context()?;
    let server = &context.server;
    let base = crate::connect::validate_http_url(&server)?;
    let (url, kind) = resolve_request(&server, &path)?;
    let username = url
        .query_pairs()
        .find(|(name, _)| name == "mc_account")
        .map(|(_, value)| value.into_owned());
    let identity = crate::native_auth::identity(&server, username.as_deref())?;
    let (_registration, cancellation) = crate::native_auth::with_current(&context, || {
        register_request(request_id, context.generation)
    })?;
    tokio::select! {
        biased;
        _ = cancellation.cancelled() => Err("请求已取消".into()),
        _ = context.cancellation.cancelled() => Err("服务器或账号已更改".into()),
        result = tokio::time::timeout(
            Duration::from_secs(if matches!(kind, ResponseKind::Api) { 30 } else { 90 }),
            fetch(&CLIENT, url, base, method, body, headers.unwrap_or_default(), kind, identity, Some(context.generation))
        ) => result.map_err(|_| "请求超时".to_owned())?,
    }
}

pub(crate) async fn cookie_api(
    server: &str,
    context_cancellation: &CancellationToken,
    context_generation: u64,
    method: &str,
    path: &str,
    body: Option<String>,
) -> Result<ProxyResponse, String> {
    let base = crate::connect::validate_http_url(server)?;
    let (url, kind) = resolve_request(server, path)?;
    let (_registration, cancellation) = register_request(None, context_generation)?;
    tokio::select! {
        biased;
        _ = cancellation.cancelled() => Err("请求已取消".into()),
        _ = context_cancellation.cancelled() => Err("服务器或账号已更改".into()),
        result = tokio::time::timeout(Duration::from_secs(30), fetch(&CLIENT, url, base, method.to_owned(), body, HashMap::new(), kind, None, Some(context_generation))) => result.map_err(|_| "请求超时".to_owned())?,
    }
}

async fn fetch(
    client: &Client,
    mut url: Url,
    credential_base: Url,
    method: String,
    body: Option<String>,
    headers: HashMap<String, String>,
    kind: ResponseKind,
    identity: Option<crate::native_auth::Identity>,
    context_generation: Option<u64>,
) -> Result<ProxyResponse, String> {
    let mut method = Method::from_bytes(method.as_bytes()).map_err(|_| "无效的请求方法")?;
    if !matches!(
        method.as_str(),
        "GET" | "HEAD" | "POST" | "PUT" | "PATCH" | "DELETE" | "OPTIONS"
    ) {
        return Err("不支持的请求方法".into());
    }
    let mut body = body;
    let timeout = if matches!(kind, ResponseKind::Api) {
        30
    } else {
        90
    };
    for hop in 0..=5 {
        if identity
            .as_ref()
            .is_some_and(|v| v.generation != crate::native_auth::generation())
        {
            return Err("服务器或账号已更改".into());
        }
        let mut req = client
            .request(method.clone(), url.clone())
            .timeout(Duration::from_secs(timeout));
        if matches!(kind, ResponseKind::Api) {
            req = req.header(header::ACCEPT, "application/json");
        }
        for (name, value) in &headers {
            // Browser callers cannot inject another account's credentials or alter
            // routing. Range and conditional requests pass through unchanged.
            if !matches!(
                name.to_ascii_lowercase().as_str(),
                "accept"
                    | "content-type"
                    | "range"
                    | "if-range"
                    | "if-none-match"
                    | "if-modified-since"
                    | "cache-control"
            ) {
                return Err(format!("不允许的请求头: {name}"));
            }
            req = req.header(name, value);
        }
        if crate::connect::url_in_server_scope(&credential_base, &url) {
            if let Some(identity) = &identity {
                req = req.bearer_auth(&identity.token);
            } else {
                let value = if let Some(epoch) = context_generation {
                    crate::native_auth::with_generation(epoch, || {
                        Ok(
                            if crate::native_auth::cookie_credentials_allowed(&credential_base) {
                                cookie_header(&credential_base, &url)
                            } else {
                                None
                            },
                        )
                    })?
                } else {
                    cookie_header(&credential_base, &url)
                };
                if let Some(value) = value {
                    req = req.header(header::COOKIE, value);
                }
            }
        }
        if let Some(value) = &body {
            req = req
                .header(header::CONTENT_TYPE, "application/json")
                .body(value.clone());
        }
        let mut response = req.send().await.map_err(|e| format!("请求失败: {e}"))?;
        let status = response.status().as_u16();
        if status == 401 && crate::connect::url_in_server_scope(&credential_base, &url) {
            if let Some(identity) = &identity {
                crate::native_auth::invalidate(identity);
            }
        }
        if crate::connect::url_in_server_scope(&credential_base, &url) {
            if let Some(epoch) = context_generation {
                crate::native_auth::with_generation(epoch, || {
                    capture_cookies(&response, &credential_base, &url)
                })?;
            } else {
                capture_cookies(&response, &credential_base, &url)?;
            }
        }
        if matches!(status, 301 | 302 | 303 | 307 | 308) {
            if let Some(location) = response
                .headers()
                .get(header::LOCATION)
                .and_then(|v| v.to_str().ok())
            {
                if hop == 5 {
                    return Err("重定向次数过多".into());
                }
                let next = url.join(location).map_err(|_| "无效的重定向地址")?;
                crate::connect::validate_http_url(next.as_str())?;
                if !crate::connect::url_in_server_scope(&credential_base, &next)
                    && !matches!(method, Method::GET | Method::HEAD)
                {
                    return Err("拒绝向另一服务器重定向请求正文".into());
                }
                if url.scheme() == "https" && next.scheme() != "https" {
                    return Err("拒绝 HTTPS 降级重定向".into());
                }
                if status == 303 || ((status == 301 || status == 302) && method == Method::POST) {
                    method = Method::GET;
                    body = None;
                }
                url = next;
                continue;
            }
        }
        let response_headers: HashMap<String, String> = response
            .headers()
            .iter()
            // Credentials remain in Rust, never in webview response metadata.
            .filter(|(name, _)| **name != header::SET_COOKIE)
            .filter_map(|(name, value)| {
                value
                    .to_str()
                    .ok()
                    .map(|v| (name.as_str().to_owned(), v.to_owned()))
            })
            .collect();
        let content_type = response_headers
            .get("content-type")
            .cloned()
            .unwrap_or_default();
        let limit = if matches!(kind, ResponseKind::Api) {
            16 * 1024 * 1024
        } else {
            64 * 1024 * 1024
        };
        let mut bytes = Vec::new();
        while let Some(chunk) = response
            .chunk()
            .await
            .map_err(|e| format!("读取响应失败: {e}"))?
        {
            if bytes.len() + chunk.len() > limit {
                return Err("响应超过大小限制".into());
            }
            bytes.extend_from_slice(&chunk);
        }
        let success = (200..300).contains(&status);
        let binary = matches!(kind, ResponseKind::Stream)
            && (content_type.contains("video")
                || content_type.contains("audio")
                || content_type.contains("octet-stream")
                || url.path().ends_with(".m4s")
                || url.path().ends_with(".ts")
                || url.path().ends_with(".mp4"));
        let body = if matches!(kind, ResponseKind::Image) && success {
            format!(
                "data:{};base64,{}",
                content_type
                    .split(';')
                    .next()
                    .filter(|v| !v.is_empty())
                    .unwrap_or("image/jpeg"),
                base64::engine::general_purpose::STANDARD.encode(bytes)
            )
        } else if binary && success {
            base64::engine::general_purpose::STANDARD.encode(bytes)
        } else {
            String::from_utf8_lossy(&bytes).into_owned()
        };
        return Ok(ProxyResponse {
            status,
            body,
            headers: response_headers,
        });
    }
    Err("重定向次数过多".into())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use std::net::TcpListener;

    fn local_server(reply: &'static str) -> (Url, std::thread::JoinHandle<String>) {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = Url::parse(&format!("http://{}", listener.local_addr().unwrap())).unwrap();
        let handle = std::thread::spawn(move || {
            let (mut socket, _) = listener.accept().unwrap();
            socket
                .set_read_timeout(Some(Duration::from_secs(3)))
                .unwrap();
            let mut buffer = [0; 4096];
            let n = socket.read(&mut buffer).unwrap();
            socket.write_all(reply.as_bytes()).unwrap();
            String::from_utf8_lossy(&buffer[..n]).into_owned()
        });
        (url, handle)
    }

    #[test]
    fn cookies_are_scoped_to_origin_path_and_expiration() {
        let a = Url::parse("http://127.0.0.1:3000/api/v1/me").unwrap();
        let b = Url::parse("http://127.0.0.1:3001/api/v1/me").unwrap();
        let mut store = CookieStore::new();
        let jar = store.entry(a.origin().ascii_serialization()).or_default();
        jar.insert(
            "session".into(),
            SavedCookie {
                value: "a-only".into(),
                path: "/api".into(),
                secure: false,
                expires_at: None,
            },
        );
        jar.insert(
            "expired".into(),
            SavedCookie {
                value: "bad".into(),
                path: "/".into(),
                secure: false,
                expires_at: Some(0),
            },
        );
        jar.insert(
            "secure".into(),
            SavedCookie {
                value: "bad".into(),
                path: "/".into(),
                secure: true,
                expires_at: None,
            },
        );
        assert_eq!(
            cookie_header_from(&store, &a).as_deref(),
            Some("session=a-only")
        );
        assert!(cookie_header_from(&store, &b).is_none());
        assert!(cookie_header_from(
            &store,
            &Url::parse("http://127.0.0.1:3000/apiculture").unwrap()
        )
        .is_none());
        assert!(cookie_domain_matches("www.example.com", ".EXAMPLE.com"));
        assert!(!cookie_domain_matches("badexample.com", ".example.com"));
        assert!(!cookie_domain_matches("127.0.0.1", "0.0.1"));
    }

    #[tokio::test]
    async fn multiple_account_cookies_are_captured_together() {
        let (url, handle) = local_server("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nSet-Cookie: mc_accounts_bag=bag-value; Domain=127.0.0.1; Path=/; HttpOnly\r\nSet-Cookie: mc_active_account=active-value; Path=/; HttpOnly\r\nConnection: close\r\n\r\nok");
        let result = fetch(
            &CLIENT,
            url.clone(),
            Url::parse(&url.origin().ascii_serialization()).unwrap(),
            "GET".into(),
            None,
            HashMap::new(),
            ResponseKind::Api,
            None,
            None,
        )
        .await
        .unwrap();
        assert!(!result.headers.contains_key("set-cookie"));
        let header = test_cookie_header(&url).unwrap();
        assert!(header.contains("mc_accounts_bag=bag-value"));
        assert!(header.contains("mc_active_account=active-value"));
        COOKIES
            .lock()
            .unwrap()
            .remove(&url.origin().ascii_serialization());
        handle.join().unwrap();
    }

    #[tokio::test]
    async fn independent_server_prefix_cookie_jars_and_redirects_are_isolated() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let host = format!("http://{}", listener.local_addr().unwrap());
        let a = Url::parse(&format!("{host}/a")).unwrap();
        let b = Url::parse(&format!("{host}/b")).unwrap();
        let handler = std::thread::spawn(move || {
            for (path, cookie, reply) in [
                (
                    "/a/login",
                    false,
                    "HTTP/1.1 200 OK\r\nSet-Cookie: private=a-cookie; Path=/; HttpOnly\r\n",
                ),
                ("/b/me", false, "HTTP/1.1 200 OK\r\n"),
                (
                    "/a/media",
                    true,
                    "HTTP/1.1 302 Found\r\nLocation: /b/media\r\n",
                ),
                ("/b/media", false, "HTTP/1.1 200 OK\r\n"),
            ] {
                let (mut socket, _) = listener.accept().unwrap();
                socket
                    .set_read_timeout(Some(Duration::from_secs(3)))
                    .unwrap();
                let mut bytes = [0; 4096];
                let count = socket.read(&mut bytes).unwrap();
                let text = String::from_utf8_lossy(&bytes[..count]).to_ascii_lowercase();
                assert_eq!(
                    text.lines().next().unwrap().split_whitespace().nth(1),
                    Some(path)
                );
                assert_eq!(text.contains("cookie: private=a-cookie"), cookie);
                socket
                    .write_all(
                        format!("{reply}Content-Length: 2\r\nConnection: close\r\n\r\nok")
                            .as_bytes(),
                    )
                    .unwrap();
            }
        });
        for (target, base) in [
            (format!("{host}/a/login"), a.clone()),
            (format!("{host}/b/me"), b.clone()),
            (format!("{host}/a/media"), a.clone()),
        ] {
            fetch(
                &CLIENT,
                Url::parse(&target).unwrap(),
                base,
                "GET".into(),
                None,
                HashMap::new(),
                ResponseKind::Api,
                None,
                None,
            )
            .await
            .unwrap();
        }
        let snapshot = cookie_snapshot(&a);
        assert!(snapshot
            .header(&Url::parse(&format!("{host}/a/media")).unwrap())
            .is_some());
        assert!(snapshot
            .header(&Url::parse(&format!("{host}/b/media")).unwrap())
            .is_none());
        assert!(snapshot
            .header(&Url::parse(&format!("{host}/a2/media")).unwrap())
            .is_none());
        COOKIES
            .lock()
            .unwrap()
            .remove(&crate::connect::server_namespace(&a));
        tokio::task::spawn_blocking(move || handler.join().unwrap())
            .await
            .unwrap();
    }
    #[tokio::test]
    async fn range_206_and_server_timing_survive_the_proxy() {
        let (url, handle) = local_server("HTTP/1.1 206 Partial Content\r\nContent-Type: video/mp4\r\nContent-Length: 3\r\nContent-Range: bytes 10-12/100\r\nServer-Timing: prep;dur=3\r\nConnection: close\r\n\r\nabc");
        let result = fetch(
            &CLIENT,
            url.clone(),
            Url::parse(&url.origin().ascii_serialization()).unwrap(),
            "GET".into(),
            None,
            HashMap::from([("Range".into(), "bytes=10-12".into())]),
            ResponseKind::Stream,
            None,
            None,
        )
        .await
        .unwrap();
        assert_eq!(result.status, 206);
        assert_eq!(result.body, "YWJj");
        assert_eq!(result.headers["content-range"], "bytes 10-12/100");
        assert_eq!(result.headers["server-timing"], "prep;dur=3");
        assert!(handle
            .join()
            .unwrap()
            .to_lowercase()
            .contains("range: bytes=10-12"));
    }

    #[tokio::test]
    async fn credentials_are_not_forwarded_to_an_external_origin_or_redirect() {
        let (external, outside) =
            local_server("HTTP/1.1 200 OK\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok");
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let own = Url::parse(&format!("http://{}", listener.local_addr().unwrap())).unwrap();
        COOKIES
            .lock()
            .unwrap()
            .entry(own.origin().ascii_serialization())
            .or_default()
            .insert(
                "session".into(),
                SavedCookie {
                    value: "secret".into(),
                    path: "/".into(),
                    secure: false,
                    expires_at: None,
                },
            );
        let location = external.to_string();
        let redirect = std::thread::spawn(move || {
            let (mut socket, _) = listener.accept().unwrap();
            let mut buf = [0; 4096];
            let n = socket.read(&mut buf).unwrap();
            socket.write_all(format!("HTTP/1.1 302 Found\r\nLocation: {location}\r\nContent-Length: 0\r\nConnection: close\r\n\r\n").as_bytes()).unwrap();
            String::from_utf8_lossy(&buf[..n]).into_owned()
        });
        fetch(
            &CLIENT,
            own.clone(),
            own.clone(),
            "GET".into(),
            None,
            HashMap::new(),
            ResponseKind::Api,
            None,
            None,
        )
        .await
        .unwrap();
        assert!(redirect.join().unwrap().contains("secret"));
        assert!(!outside.join().unwrap().to_lowercase().contains("cookie:"));
        COOKIES
            .lock()
            .unwrap()
            .remove(&own.origin().ascii_serialization());
    }

    #[tokio::test]
    async fn cancellation_drops_an_in_flight_response_body() {
        let listener = TcpListener::bind("127.0.0.1:0").unwrap();
        let url = Url::parse(&format!("http://{}", listener.local_addr().unwrap())).unwrap();
        let (started_tx, started_rx) = tokio::sync::oneshot::channel();
        let server = std::thread::spawn(move || {
            let (mut socket, _) = listener.accept().unwrap();
            let mut buf = [0; 4096];
            socket.read(&mut buf).unwrap();
            socket
                .write_all(
                    b"HTTP/1.1 200 OK\r\nContent-Length: 1000000\r\nConnection: close\r\n\r\na",
                )
                .unwrap();
            started_tx.send(()).unwrap();
            socket
                .set_read_timeout(Some(Duration::from_secs(2)))
                .unwrap();
            // Dropping the reqwest future must close the actual connection.
            match socket.read(&mut buf) {
                Ok(0) => true,
                Err(error) => matches!(
                    error.kind(),
                    std::io::ErrorKind::ConnectionReset
                        | std::io::ErrorKind::BrokenPipe
                        | std::io::ErrorKind::UnexpectedEof
                ),
                _ => false,
            }
        });
        let (registration, token) = register_request(Some("cancel-test".into()), u64::MAX).unwrap();
        let task = tokio::spawn(async move {
            let _registration = registration;
            tokio::select! {
                _ = token.cancelled() => Err("cancelled".to_owned()),
                result = fetch(&CLIENT, url.clone(), Url::parse(&url.origin().ascii_serialization()).unwrap(), "GET".into(), None, HashMap::new(), ResponseKind::Api, None, None) => result,
            }
        });
        started_rx.await.unwrap();
        assert!(cancel_proxy_request("cancel-test".into()));
        assert_eq!(task.await.unwrap().err().as_deref(), Some("cancelled"));
        assert!(server.join().unwrap());
        assert!(!cancel_proxy_request("cancel-test".into()));
    }
}
