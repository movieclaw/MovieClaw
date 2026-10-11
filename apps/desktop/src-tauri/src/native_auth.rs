//! Native device authentication. JavaScript receives identity metadata, never credentials.
use crate::{api_proxy, connect, credential_vault as vault};
use reqwest::{Client, Method};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::{
    collections::HashMap,
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        LazyLock, Mutex,
    },
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use tokio_util::sync::CancellationToken;

static GENERATION: AtomicU64 = AtomicU64::new(1);
static SHUTTING_DOWN: AtomicBool = AtomicBool::new(false);
static CONTEXT_CANCEL: LazyLock<Mutex<CancellationToken>> =
    LazyLock::new(|| Mutex::new(CancellationToken::new()));
static MUTATION: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());
static STORE: LazyLock<Mutex<HashMap<String, SavedOrigin>>> =
    LazyLock::new(|| Mutex::new(load_store()));
static PAIRS: LazyLock<Mutex<HashMap<String, Pairing>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));
static CLIENT: LazyLock<Client> = LazyLock::new(|| {
    Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .connect_timeout(Duration::from_secs(5))
        .timeout(Duration::from_secs(15))
        .build()
        .expect("native auth client")
});

#[derive(Clone, Default, Serialize, Deserialize)]
struct SavedOrigin {
    active: Option<String>,
    accounts: Vec<Value>,
    #[serde(default)]
    supports_native: Option<bool>,
    #[serde(default)]
    initialized: bool,
    #[serde(default)]
    pending_revocations: Vec<String>,
}
#[derive(Clone)]
pub(crate) struct Context {
    pub server: String,
    namespace: String,
    pub generation: u64,
    pub cancellation: CancellationToken,
}
#[derive(Clone)]
struct Pairing {
    context: Context,
    device_code: String,
    cancellation: CancellationToken,
    expires_at: u64,
    interval: u64,
    next_poll: u64,
}
#[derive(Clone)]
pub(crate) struct Identity {
    pub namespace: String,
    pub username: String,
    pub token: String,
    pub generation: u64,
}

fn now() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
}
fn fail(status: u16, code: &str, message: &str) -> String {
    json!({"status":status,"code":code,"message":message}).to_string()
}
pub(crate) fn load_context() -> Result<Context, String> {
    let cancellation = CONTEXT_CANCEL.lock().unwrap();
    if SHUTTING_DOWN.load(Ordering::SeqCst) {
        return Err(fail(409, "APP_SHUTTING_DOWN", "应用正在退出"));
    }
    let server = connect::read_server_url_unlocked()?;
    if server.is_empty() {
        return Err(fail(400, "NO_SERVER", "请先选择服务器"));
    }
    Ok(Context {
        namespace: server.clone(),
        server,
        generation: generation(),
        cancellation: cancellation.clone(),
    })
}
fn ensure_current_unlocked(context: &Context) -> Result<(), String> {
    if SHUTTING_DOWN.load(Ordering::SeqCst)
        || context.generation != generation()
        || context.cancellation.is_cancelled()
    {
        return Err(fail(409, "CONTEXT_CHANGED", "服务器或账号已更改，请重试"));
    }
    Ok(())
}
fn ensure_current(context: &Context) -> Result<(), String> {
    with_current(context, || Ok(()))
}
pub(crate) fn with_context_read<T>(operation: impl FnOnce() -> T) -> T {
    let _context = CONTEXT_CANCEL.lock().unwrap();
    operation()
}
pub(crate) fn with_current<T>(
    context: &Context,
    operation: impl FnOnce() -> Result<T, String>,
) -> Result<T, String> {
    let _guard = CONTEXT_CANCEL.lock().unwrap();
    ensure_current_unlocked(context)?;
    operation()
}
pub(crate) fn with_generation<T>(
    expected: u64,
    operation: impl FnOnce() -> Result<T, String>,
) -> Result<T, String> {
    let _guard = CONTEXT_CANCEL.lock().unwrap();
    if SHUTTING_DOWN.load(Ordering::SeqCst) || expected != generation() {
        return Err(fail(409, "CONTEXT_CHANGED", "服务器或账号已更改，请重试"));
    }
    operation()
}
pub(crate) fn generation() -> u64 {
    GENERATION.load(Ordering::SeqCst)
}
fn advance(token: &mut CancellationToken) -> u64 {
    token.cancel();
    *token = CancellationToken::new();
    GENERATION.fetch_add(1, Ordering::SeqCst) + 1
}
fn clean_old_contexts(epoch: u64) {
    PAIRS.lock().unwrap().retain(|_, pair| {
        if pair.context.generation < epoch {
            pair.cancellation.cancel();
            false
        } else {
            true
        }
    });
    api_proxy::cancel_requests_before(epoch);
    crate::media_stream::revoke_before(epoch);
}
/// Called after JavaScript has flushed playback progress, never before it.
/// Retire pending authentication/QR work and prevent a late response from
/// installing a credential while the application is tearing down.
pub(crate) fn retire_for_shutdown() {
    let epoch = {
        let mut token = CONTEXT_CANCEL.lock().unwrap();
        if SHUTTING_DOWN.swap(true, Ordering::SeqCst) {
            return;
        }
        advance(&mut token)
    };
    clean_old_contexts(epoch);
}
pub(crate) fn change_server(operation: impl FnOnce() -> Result<(), String>) -> Result<(), String> {
    let epoch = {
        let mut token = CONTEXT_CANCEL.lock().unwrap();
        if SHUTTING_DOWN.load(Ordering::SeqCst) {
            return Err(fail(409, "APP_SHUTTING_DOWN", "应用正在退出"));
        }
        operation()?;
        advance(&mut token)
    };
    clean_old_contexts(epoch);
    Ok(())
}
fn commit_context(
    context: &Context,
    operation: impl FnOnce() -> Result<(), String>,
) -> Result<Context, String> {
    let next = {
        let mut token = CONTEXT_CANCEL.lock().unwrap();
        ensure_current_unlocked(context)?;
        operation()?;
        let epoch = advance(&mut token);
        Context {
            generation: epoch,
            cancellation: token.clone(),
            ..context.clone()
        }
    };
    clean_old_contexts(next.generation);
    Ok(next)
}
fn load_store() -> HashMap<String, SavedOrigin> {
    std::fs::read(connect::config_dir().join("accounts.json"))
        .ok()
        .and_then(|v| serde_json::from_slice(&v).ok())
        .unwrap_or_default()
}
fn persist(store: &HashMap<String, SavedOrigin>) -> Result<(), String> {
    let path = connect::config_dir().join("accounts.json");
    let temp = path.with_extension("tmp");
    std::fs::write(
        &temp,
        serde_json::to_vec(store).map_err(|_| fail(500, "LOCAL_STORAGE", "账号信息无法保存"))?,
    )
    .map_err(|_| fail(500, "LOCAL_STORAGE", "账号信息无法保存"))?;
    #[cfg(windows)]
    if path.exists() {
        std::fs::remove_file(&path).map_err(|_| fail(500, "LOCAL_STORAGE", "账号信息无法保存"))?;
    }
    std::fs::rename(temp, path).map_err(|_| fail(500, "LOCAL_STORAGE", "账号信息无法保存"))
}
fn account(session: &Value, active: bool, authenticated: bool) -> Value {
    json!({"username":session["username"],"nickname":session["nickname"],"avatar_url":session["avatar_url"],"role":session.get("role").cloned().unwrap_or(json!("admin")),"active":active,"authenticated":authenticated})
}
fn accounts(namespace: &str) -> Result<Vec<Value>, String> {
    let record = STORE
        .lock()
        .unwrap()
        .get(namespace)
        .cloned()
        .unwrap_or_default();
    record
        .accounts
        .iter()
        .map(|v| {
            let username = v["username"].as_str().unwrap_or_default();
            Ok(account(
                v,
                record.active.as_deref() == Some(username),
                vault::read(&vault::token_key(namespace, username))?.is_some(),
            ))
        })
        .collect()
}
pub(crate) fn identity(server: &str, username: Option<&str>) -> Result<Option<Identity>, String> {
    let _context = CONTEXT_CANCEL.lock().unwrap();
    if SHUTTING_DOWN.load(Ordering::SeqCst) || server != connect::read_server_url_unlocked()? {
        return Err(fail(409, "CONTEXT_CHANGED", "服务器或账号已更改，请重试"));
    }
    let captured_generation = generation();
    let namespace = connect::server_namespace(&connect::validate_http_url(server)?);
    let record = STORE
        .lock()
        .unwrap()
        .get(&namespace)
        .cloned()
        .unwrap_or_default();
    // A server rollback may retain an old device account in the vault. Once
    // bootstrap selects Cookie compatibility, that secret must stay dormant.
    if record.supports_native == Some(false) {
        return Ok(None);
    }
    let selected = username.map(str::to_owned).or(record.active);
    let Some(username) = selected else {
        return Ok(None);
    };
    let token = vault::read(&vault::token_key(&namespace, &username))?;
    if captured_generation != generation() {
        return Err(fail(409, "CONTEXT_CHANGED", "服务器或账号已更改，请重试"));
    }
    Ok(token.map(|token| Identity {
        namespace,
        username,
        token,
        generation: captured_generation,
    }))
}
pub(crate) fn cookie_credentials_allowed(base: &url::Url) -> bool {
    STORE
        .lock()
        .unwrap()
        .get(&connect::server_namespace(base))
        .is_none_or(|record| record.supports_native != Some(true))
}
pub(crate) fn invalidate(identity: &Identity) {
    let _context = CONTEXT_CANCEL.lock().unwrap();
    if identity.generation != generation() {
        return;
    }
    let key = vault::token_key(&identity.namespace, &identity.username);
    if vault::read(&key).ok().flatten().as_deref() == Some(identity.token.as_str()) {
        let _ = vault::delete(&key);
    }
}
async fn request(
    context: &Context,
    method: Method,
    path: &str,
    body: Option<Value>,
    token: Option<&str>,
    cancellation: Option<&CancellationToken>,
) -> Result<(u16, Value), String> {
    ensure_current(context)?;
    let mut req = CLIENT
        .request(method, format!("{}/api/v1{path}", context.server))
        .header("Accept", "application/json");
    if let Some(token) = token {
        req = req.bearer_auth(token);
    }
    if let Some(body) = body {
        req = req.json(&body);
    }
    let operation = async {
        let mut response = req
            .send()
            .await
            .map_err(|_| fail(0, "NETWORK", "服务器暂时无法连接，请重试"))?;
        let status = response.status().as_u16();
        if (300..400).contains(&status) {
            return Err(fail(
                status,
                "REDIRECT",
                "认证接口不能重定向，请检查服务器地址",
            ));
        }
        let mut bytes = Vec::new();
        while let Some(chunk) = response
            .chunk()
            .await
            .map_err(|_| fail(0, "NETWORK", "服务器响应中断"))?
        {
            if bytes.len() + chunk.len() > 256 * 1024 {
                return Err(fail(502, "INVALID_RESPONSE", "认证响应过大"));
            }
            bytes.extend_from_slice(&chunk);
        }
        let data: Value = serde_json::from_slice(&bytes)
            .map_err(|_| fail(status, "INVALID_RESPONSE", "服务器返回的认证数据无效"))?;
        Ok((status, data))
    };
    let pair_token = cancellation.cloned().unwrap_or_else(CancellationToken::new);
    tokio::select! { biased;
        _ = context.cancellation.cancelled() => Err(fail(409,"CONTEXT_CHANGED","服务器或账号已更改，请重试")),
        _ = pair_token.cancelled() => Err(fail(409,"PAIR_CANCELLED","配对已取消")),
        result = operation => { ensure_current(context)?; result }
    }
}
fn data(status: u16, value: Value) -> Result<Value, String> {
    if !(200..300).contains(&status) {
        return Err(fail(
            status,
            value["code"].as_str().unwrap_or("AUTH_FAILED"),
            value["message"].as_str().unwrap_or("认证请求失败"),
        ));
    }
    Ok(value.get("data").cloned().unwrap_or(Value::Null))
}
async fn cookie_request(
    context: &Context,
    method: &str,
    path: &str,
    body: Option<Value>,
) -> Result<Value, String> {
    ensure_current(context)?;
    let response = api_proxy::cookie_api(
        &context.server,
        &context.cancellation,
        context.generation,
        method,
        path,
        body.map(|v| v.to_string()),
    )
    .await
    .map_err(|_| {
        if context.cancellation.is_cancelled() {
            fail(409, "CONTEXT_CHANGED", "服务器或账号已更改，请重试")
        } else {
            fail(0, "NETWORK", "服务器暂时无法连接，请重试")
        }
    })?;
    ensure_current(context)?;
    if response.status == 204 {
        return Ok(Value::Null);
    }
    data(
        response.status,
        serde_json::from_str(&response.body)
            .map_err(|_| fail(502, "INVALID_RESPONSE", "服务器返回的数据无效"))?,
    )
}
async fn capabilities(context: &Context) -> Result<(Context, bool, bool), String> {
    let (status, value) =
        request(context, Method::GET, "/auth/bootstrap", None, None, None).await?;
    let info = data(status, value)?;
    let initialized = info["initialized"]
        .as_bool()
        .ok_or_else(|| fail(502, "INVALID_RESPONSE", "该地址不是有效的 MovieClaw 服务器"))?;
    let supports = info["native_device_kinds"]
        .as_array()
        .is_some_and(|v| v.iter().any(|kind| kind.as_str() == Some("windows")));
    let (next, changed) = {
        let mut token = CONTEXT_CANCEL.lock().unwrap();
        ensure_current_unlocked(context)?;
        let mut store = STORE.lock().unwrap();
        let mut updated = store.clone();
        let entry = updated.entry(context.namespace.clone()).or_default();
        let changed = entry.supports_native != Some(supports);
        entry.supports_native = Some(supports);
        entry.initialized = initialized;
        persist(&updated)?;
        *store = updated;
        let next = if changed {
            Context {
                generation: advance(&mut token),
                cancellation: token.clone(),
                ..context.clone()
            }
        } else {
            context.clone()
        };
        (next, changed)
    };
    if changed {
        clean_old_contexts(next.generation);
    }
    Ok((next, initialized, supports))
}
async fn removal_capabilities(context: &Context) -> Result<(Context, bool, bool), String> {
    ensure_current(context)?;
    let cached = STORE
        .lock()
        .unwrap()
        .get(&context.namespace)
        .cloned()
        .unwrap_or_default();
    if cached.supports_native == Some(true) {
        return Ok((context.clone(), cached.initialized, true));
    }
    match capabilities(context).await {
        Ok(value) => Ok(value),
        Err(error) if error_status(&error) == 0 => {
            ensure_current(context)?;
            let entry = STORE
                .lock()
                .unwrap()
                .get(&context.namespace)
                .cloned()
                .unwrap_or_default();
            if entry.supports_native == Some(true) {
                Ok((context.clone(), entry.initialized, true))
            } else {
                Err(error)
            }
        }
        Err(error) => Err(error),
    }
}
fn offline_status(context: &Context, initialized: bool) -> Result<Value, String> {
    with_current(context, || {
        let entry = STORE
            .lock()
            .unwrap()
            .get(&context.namespace)
            .cloned()
            .unwrap_or_default();
        let me = entry
            .accounts
            .iter()
            .find(|v| v["username"].as_str() == entry.active.as_deref())
            .cloned();
        Ok(
            json!({"mode":"device","initialized":initialized,"session":me,"accounts":accounts(&context.namespace)?,"pairing_supported":true,"compatibility_reason":null,"context_generation":context.generation,"offline":true}),
        )
    })
}
async fn removal_status(
    context: &Context,
    initialized: bool,
    supports: bool,
) -> Result<Value, String> {
    match tokio::time::timeout(
        Duration::from_secs(2),
        status(context, initialized, supports),
    )
    .await
    {
        Ok(Err(error)) if supports && error_status(&error) == 0 => {
            offline_status(context, initialized)
        }
        Ok(result) => result,
        Err(_) if supports => offline_status(context, initialized),
        Err(_) => Err(fail(0, "NETWORK", "服务器暂时无法连接")),
    }
}
fn revocation_key(namespace: &str, id: &str) -> String {
    format!("MovieClaw.Windows/revoke/{namespace}#{id}")
}
fn retry_revocations(context: Context) {
    tauri::async_runtime::spawn(async move {
        let Ok(_mutation) = MUTATION.try_lock() else {
            return;
        };
        let pending = STORE
            .lock()
            .unwrap()
            .get(&context.namespace)
            .map(|v| v.pending_revocations.clone())
            .unwrap_or_default();
        for id in pending.into_iter().take(2) {
            if ensure_current(&context).is_err() {
                break;
            }
            let key = revocation_key(&context.namespace, &id);
            let Ok(Some(token)) = vault::read(&key) else {
                continue;
            };
            let result = tokio::time::timeout(
                Duration::from_secs(2),
                request(
                    &context,
                    Method::DELETE,
                    "/auth/devices/current",
                    None,
                    Some(&token),
                    None,
                ),
            )
            .await;
            let done = matches!(result, Ok(Ok((status,_))) if (200..300).contains(&status) || status == 401 || status == 404);
            if done {
                let _ = with_current(&context, || {
                    let mut store = STORE.lock().unwrap();
                    let mut updated = store.clone();
                    if let Some(entry) = updated.get_mut(&context.namespace) {
                        entry.pending_revocations.retain(|v| v != &id);
                    }
                    persist(&updated)?;
                    vault::delete(&key)?;
                    *store = updated;
                    Ok(())
                });
            }
        }
    });
}
async fn session(context: &Context, token: &str) -> Result<Value, String> {
    let (status, value) =
        request(context, Method::GET, "/auth/me", None, Some(token), None).await?;
    data(status, value)
}
fn activate(context: &Context, session: &Value, token: &str) -> Result<Context, String> {
    let username = session["username"]
        .as_str()
        .filter(|v| !v.is_empty())
        .ok_or_else(|| fail(502, "INVALID_RESPONSE", "服务器未返回账号身份"))?;
    commit_context(context, || {
        let key = vault::token_key(&context.namespace, username);
        let previous = vault::read(&key)?;
        vault::write(&key, token)?;
        let mut store = STORE.lock().unwrap();
        let mut updated = store.clone();
        let entry = updated.entry(context.namespace.clone()).or_default();
        entry
            .accounts
            .retain(|v| v["username"].as_str() != Some(username));
        entry.accounts.push(account(session, true, true));
        entry.active = Some(username.to_owned());
        if let Err(error) = persist(&updated) {
            match previous {
                Some(value) => {
                    let _ = vault::write(&key, &value);
                }
                None => {
                    let _ = vault::delete(&key);
                }
            }
            return Err(error);
        }
        *store = updated;
        Ok(())
    })
}

async fn status(context: &Context, initialized: bool, supports: bool) -> Result<Value, String> {
    if !supports {
        let me = match cookie_request(&context, "GET", "/auth/me", None).await {
            Ok(v) => Some(v),
            Err(e) if error_status(&e) == 401 => None,
            Err(e) => return Err(e),
        };
        let list = if me.is_some() {
            cookie_request(&context, "GET", "/auth/accounts", None).await?
        } else {
            json!([])
        };
        ensure_current(context)?;
        return Ok(
            json!({"mode":"cookie","initialized":initialized,"session":me,"accounts":list,"pairing_supported":false,"compatibility_reason":"服务器尚未支持 Windows 设备登录，当前使用兼容登录；升级服务器后可使用设备配对。","context_generation":context.generation}),
        );
    }
    let me = if let Some(identity) = identity(&context.server, None)? {
        match session(context, &identity.token).await {
            Ok(v) => Some(v),
            Err(e) if error_status(&e) == 401 => {
                invalidate(&identity);
                None
            }
            Err(e) => return Err(e),
        }
    } else {
        None
    };
    let list = accounts(&context.namespace)?;
    ensure_current(context)?;
    Ok(
        json!({"mode":"device","initialized":initialized,"session":me,"accounts":list,"pairing_supported":true,"compatibility_reason":null,"context_generation":context.generation}),
    )
}
fn error_status(error: &str) -> u16 {
    serde_json::from_str::<Value>(error)
        .ok()
        .and_then(|v| v["status"].as_u64())
        .unwrap_or_default() as u16
}
fn client() -> Result<Value, String> {
    Ok(
        json!({"kind":"windows","installation_id":vault::installation_id()?,"name":std::env::var("COMPUTERNAME").unwrap_or_else(|_|"Windows PC".into()).chars().take(64).collect::<String>(),"platform":format!("Windows · {}",std::env::consts::ARCH),"client_version":env!("CARGO_PKG_VERSION")}),
    )
}

#[tauri::command]
pub async fn native_auth_status() -> Result<Value, String> {
    let context = load_context()?;
    let (context, initialized, supports) = capabilities(&context).await?;
    let value = status(&context, initialized, supports).await?;
    if supports {
        retry_revocations(context);
    }
    Ok(value)
}
#[tauri::command]
pub async fn native_password_login(username: String, password: String) -> Result<Value, String> {
    let _guard = MUTATION.lock().await;
    let (mut context, initialized, supports) = capabilities(&load_context()?).await?;
    if !initialized {
        return Err(fail(409, "NEEDS_SETUP", "服务器尚未完成初始化"));
    }
    if supports {
        let (code, value) = request(
            &context,
            Method::POST,
            "/auth/device/login",
            Some(json!({"username":username,"password":password,"client":client()?})),
            None,
            None,
        )
        .await?;
        let login = data(code, value)?;
        let token = login["token"]
            .as_str()
            .ok_or_else(|| fail(502, "INVALID_RESPONSE", "服务器未返回设备凭证"))?;
        context = activate(&context, &login["session"], token)?;
    } else {
        cookie_request(
            &context,
            "POST",
            "/auth/login",
            Some(json!({"username":username,"password":password,"remember":true})),
        )
        .await?;
        context = commit_context(&context, || Ok(()))?;
    }
    status(&context, initialized, supports).await
}
#[tauri::command]
pub async fn native_select_account(username: String) -> Result<Value, String> {
    let _guard = MUTATION.lock().await;
    let (mut context, initialized, supports) = capabilities(&load_context()?).await?;
    if supports {
        let selected = identity(&context.server, Some(&username))?
            .ok_or_else(|| fail(401, "NEEDS_PASSWORD", "这个账号需要重新登录"))?;
        let me = match session(&context, &selected.token).await {
            Ok(v) => v,
            Err(e) => {
                if error_status(&e) == 401 {
                    invalidate(&selected);
                }
                return Err(e);
            }
        };
        context = activate(&context, &me, &selected.token)?;
    } else {
        cookie_request(
            &context,
            "POST",
            "/auth/accounts/switch",
            Some(json!({"username":username})),
        )
        .await?;
        context = commit_context(&context, || Ok(()))?;
    }
    status(&context, initialized, supports).await
}
async fn remove(context: &Context, username: &str) -> Result<Context, String> {
    let selected = identity(&context.server, Some(username))?;
    let mut pending = None;
    if let Some(identity) = &selected {
        let result = tokio::time::timeout(
            Duration::from_secs(2),
            request(
                context,
                Method::DELETE,
                "/auth/devices/current",
                None,
                Some(&identity.token),
                None,
            ),
        )
        .await;
        let done = matches!(result, Ok(Ok((status,_))) if (200..300).contains(&status) || status == 401 || status == 404);
        if !done {
            pending = Some(vault::random_id()?);
        }
    }
    commit_context(context, || {
        let mut store = STORE.lock().unwrap();
        let mut updated = store.clone();
        let entry = updated.entry(context.namespace.clone()).or_default();
        if let (Some(id), Some(identity)) = (&pending, &selected) {
            // Each pending secret stays in Credential Manager; JSON stores opaque IDs only.
            if entry.pending_revocations.len() >= 16 {
                return Err(fail(
                    503,
                    "REVOCATION_QUEUE_FULL",
                    "待撤销设备较多，请连接服务器后重试",
                ));
            }
            vault::write(&revocation_key(&context.namespace, id), &identity.token)?;
            entry.pending_revocations.push(id.clone());
        }
        entry
            .accounts
            .retain(|v| v["username"].as_str() != Some(username));
        if entry.active.as_deref() == Some(username) {
            entry.active = None;
        }
        if let Err(error) = persist(&updated) {
            if let Some(id) = &pending {
                let _ = vault::delete(&revocation_key(&context.namespace, id));
            }
            return Err(error);
        }
        vault::delete(&vault::token_key(&context.namespace, username))?;
        *store = updated;
        Ok(())
    })
}

async fn activate_remaining(context: &Context) -> Result<Context, String> {
    ensure_current(context)?;
    if identity(&context.server, None)?.is_some() {
        return Ok(context.clone());
    }
    for candidate in accounts(&context.namespace)? {
        let Some(username) = candidate["username"].as_str() else {
            continue;
        };
        if let Some(identity) = identity(&context.server, Some(username))? {
            match tokio::time::timeout(Duration::from_secs(2), session(context, &identity.token))
                .await
                .unwrap_or_else(|_| Err(fail(0, "NETWORK", "服务器暂时无法连接")))
            {
                Ok(me) => return activate(context, &me, &identity.token),
                Err(e) if error_status(&e) == 401 => invalidate(&identity),
                Err(e) if error_status(&e) == 409 => return Err(e),
                Err(e) if error_status(&e) == 0 => {
                    return activate(context, &candidate, &identity.token)
                }
                Err(_) => {}
            }
        }
    }
    ensure_current(context)?;
    Ok(context.clone())
}
#[tauri::command]
pub async fn native_remove_account(username: String) -> Result<Value, String> {
    let _guard = MUTATION.lock().await;
    let (mut context, initialized, supports) = removal_capabilities(&load_context()?).await?;
    if supports {
        context = remove(&context, &username).await?;
        context = activate_remaining(&context).await?;
    } else {
        cookie_request(
            &context,
            "DELETE",
            &format!(
                "/auth/accounts/{}",
                url::form_urlencoded::byte_serialize(username.as_bytes()).collect::<String>()
            ),
            None,
        )
        .await?;
        context = commit_context(&context, || Ok(()))?;
    }
    removal_status(&context, initialized, supports).await
}
#[tauri::command]
pub async fn native_logout(all: Option<bool>) -> Result<Value, String> {
    let _guard = MUTATION.lock().await;
    let (mut context, initialized, supports) = removal_capabilities(&load_context()?).await?;
    if supports {
        let names = if all.unwrap_or(false) {
            accounts(&context.namespace)?
                .iter()
                .filter_map(|v| v["username"].as_str().map(str::to_owned))
                .collect()
        } else {
            identity(&context.server, None)?
                .map(|v| vec![v.username])
                .unwrap_or_default()
        };
        for username in names {
            context = remove(&context, &username).await?;
        }
        if !all.unwrap_or(false) {
            context = activate_remaining(&context).await?;
        }
    } else {
        cookie_request(
            &context,
            "POST",
            "/auth/logout",
            Some(json!({"all":all.unwrap_or(false)})),
        )
        .await?;
        context = commit_context(&context, || Ok(()))?;
    }
    removal_status(&context, initialized, supports).await
}

#[tauri::command]
pub async fn native_pair_begin() -> Result<Value, String> {
    let (context, initialized, supports) = capabilities(&load_context()?).await?;
    if !initialized || !supports {
        return Err(fail(
            422,
            "WINDOWS_DEVICE_UNSUPPORTED",
            "请升级并初始化服务器后使用 Windows 配对登录",
        ));
    }
    let client = client()?;
    let (status,value)=request(&context,Method::POST,"/auth/device/authorize",Some(json!({"client_type":"windows","client_name":client["name"],"installation_id":client["installation_id"],"platform":client["platform"],"client_version":client["client_version"]})),None,None).await?;
    let info = data(status, value)?;
    let device_code = info["device_code"]
        .as_str()
        .ok_or_else(|| fail(502, "INVALID_RESPONSE", "服务器未返回配对凭据"))?
        .to_owned();
    let interval = info["interval"].as_u64().unwrap_or(5).clamp(1, 60);
    let expires_at = now() + info["expires_in"].as_u64().unwrap_or(300).min(900);
    let id = vault::random_id()?;
    let uri = info["verification_uri_complete"]
        .as_str()
        .ok_or_else(|| fail(502, "INVALID_RESPONSE", "服务器未返回配对地址"))?;
    connect::validate_http_url(uri)?;
    with_current(&context, || {
        let mut pairs = PAIRS.lock().unwrap();
        for (_, pair) in pairs.drain() {
            pair.cancellation.cancel();
        }
        pairs.insert(
            id.clone(),
            Pairing {
                context: context.clone(),
                device_code,
                cancellation: CancellationToken::new(),
                expires_at,
                interval,
                next_poll: now(),
            },
        );
        Ok(())
    })?;
    Ok(
        json!({"pairing_id":id,"user_code":info["user_code"],"verification_uri":info["verification_uri"],"verification_uri_complete":uri,"expires_at":expires_at,"interval":interval}),
    )
}
#[tauri::command]
pub async fn native_pair_cancel(pairing_id: String) -> bool {
    let cancelled = if let Some(pair) = PAIRS.lock().unwrap().remove(&pairing_id) {
        pair.cancellation.cancel();
        true
    } else {
        false
    };
    // Return only after an in-flight poll has settled, including a commit that
    // won the race before cancellation. The UI can then restore current status.
    let _guard = MUTATION.lock().await;
    cancelled
}
#[tauri::command]
pub async fn native_pair_poll(pairing_id: String) -> Result<Value, String> {
    let _guard = MUTATION.lock().await;
    let pair = {
        let mut pairs = PAIRS.lock().unwrap();
        let Some(pair) = pairs.get_mut(&pairing_id) else {
            return Ok(json!({"status":"cancelled"}));
        };
        if pair.expires_at <= now() {
            pairs.remove(&pairing_id);
            return Ok(json!({"status":"expired"}));
        }
        if pair.next_poll > now() {
            return Ok(json!({"status":"pending","interval":pair.next_poll-now()}));
        }
        pair.next_poll = now() + pair.interval;
        pair.clone()
    };
    let response = request(
        &pair.context,
        Method::POST,
        "/auth/device/token",
        Some(json!({"device_code":pair.device_code})),
        None,
        Some(&pair.cancellation),
    )
    .await;
    if pair.cancellation.is_cancelled() {
        return Ok(json!({"status":"cancelled"}));
    }
    let (status, value) = response?;
    if status == 202 || status == 429 {
        return Ok(
            json!({"status":"pending","interval":if status==429 {pair.interval+5} else {pair.interval}}),
        );
    }
    if status == 400 {
        PAIRS.lock().unwrap().remove(&pairing_id);
        return Ok(
            json!({"status":if value["message"].as_str().unwrap_or_default().contains("拒绝") {"denied"} else {"expired"}}),
        );
    }
    let login = data(status, value)?;
    let token = login["token"]
        .as_str()
        .ok_or_else(|| fail(502, "INVALID_RESPONSE", "服务器未返回设备凭证"))?;
    let verified = request(
        &pair.context,
        Method::GET,
        "/auth/me",
        None,
        Some(token),
        Some(&pair.cancellation),
    )
    .await;
    if pair.cancellation.is_cancelled() {
        return Ok(json!({"status":"cancelled"}));
    }
    let (code, value) = verified?;
    let me = data(code, value)?;
    // Cancellation and installation share the same lock: a successful cancel cannot
    // race a late poll into installing a credential or switching the active account.
    let mut pairs = PAIRS.lock().unwrap();
    if pair.cancellation.is_cancelled() || !pairs.contains_key(&pairing_id) {
        return Ok(json!({"status":"cancelled"}));
    }
    pairs.remove(&pairing_id);
    drop(pairs);
    activate(&pair.context, &me, token)?;
    Ok(json!({"status":"approved","session":me,"interval":pair.interval}))
}

#[cfg(test)]
mod tests {
    use super::*;
    static CONTEXT_TEST: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());
    #[test]
    fn account_metadata_contains_no_secret() {
        let v = account(
            &json!({"username":"member","nickname":"成员","role":"member","token":"secret"}),
            true,
            true,
        );
        assert_eq!(v["username"], "member");
        assert!(v.get("token").is_none());
        assert_eq!(v["active"], true);
    }
    #[tokio::test]
    async fn native_login_contract_does_not_send_cookie_or_return_token_metadata() {
        let _guard = CONTEXT_TEST.lock().await;
        use std::io::{Read, Write};
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let server = format!("http://{}", listener.local_addr().unwrap());
        let handler = std::thread::spawn(move || {
            let (mut socket, _) = listener.accept().unwrap();
            socket
                .set_read_timeout(Some(Duration::from_secs(3)))
                .unwrap();
            let mut bytes = Vec::new();
            let mut buffer = [0u8; 4096];
            loop {
                let n = socket.read(&mut buffer).unwrap();
                bytes.extend_from_slice(&buffer[..n]);
                if let Some(end) = bytes.windows(4).position(|v| v == b"\r\n\r\n") {
                    let header = String::from_utf8_lossy(&bytes[..end]);
                    let length = header
                        .lines()
                        .find_map(|v| {
                            v.to_ascii_lowercase()
                                .strip_prefix("content-length: ")
                                .and_then(|v| v.parse::<usize>().ok())
                        })
                        .unwrap_or_default();
                    if bytes.len() >= end + 4 + length {
                        break;
                    }
                }
            }
            let request = String::from_utf8(bytes).unwrap();
            assert!(request.starts_with("POST /api/v1/auth/device/login "));
            assert!(!request.to_ascii_lowercase().contains("cookie:"));
            assert!(request.contains("\"kind\":\"windows\""));
            let body = r#"{"data":{"token":"private-device-token","session":{"username":"member","nickname":"成员","role":"member"}}}"#;
            socket
                .write_all(
                    format!(
                        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                        body.len()
                    )
                    .as_bytes(),
                )
                .unwrap();
        });
        let context = Context {
            namespace: server.clone(),
            server,
            generation: generation(),
            cancellation: CancellationToken::new(),
        };
        let (code, value) = request(
            &context,
            Method::POST,
            "/auth/device/login",
            Some(json!({"username":"member","password":"test","client":{"kind":"windows"}})),
            None,
            None,
        )
        .await
        .unwrap();
        let login = data(code, value).unwrap();
        assert_eq!(login["token"], "private-device-token");
        assert!(account(&login["session"], true, true)
            .get("token")
            .is_none());
        handler.join().unwrap();
    }
    #[tokio::test]
    async fn switching_server_cancels_old_login_and_rejects_late_identity_commit() {
        use std::io::{Read, Write};
        let _guard = CONTEXT_TEST.lock().await;
        let previous = connect::load_server_url().unwrap();
        let a = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let b = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        b.set_nonblocking(true).unwrap();
        let server_a = format!("http://{}", a.local_addr().unwrap());
        let server_b = format!("http://{}", b.local_addr().unwrap());
        connect::save_server_url(server_a.clone()).unwrap();
        let old = load_context().unwrap();
        let (sent, received) = tokio::sync::oneshot::channel();
        let (finish, unblock) = std::sync::mpsc::channel();
        let handler = std::thread::spawn(move || {
            let (mut socket, _) = a.accept().unwrap();
            socket
                .set_read_timeout(Some(Duration::from_secs(3)))
                .unwrap();
            let mut bytes = Vec::new();
            let mut buffer = [0; 4096];
            loop {
                let n = socket.read(&mut buffer).unwrap();
                if n == 0 {
                    break;
                }
                bytes.extend_from_slice(&buffer[..n]);
                if let Some(end) = bytes.windows(4).position(|v| v == b"\r\n\r\n") {
                    let header = String::from_utf8_lossy(&bytes[..end]);
                    let length = header
                        .lines()
                        .find_map(|v| {
                            v.to_ascii_lowercase()
                                .strip_prefix("content-length: ")
                                .and_then(|v| v.parse::<usize>().ok())
                        })
                        .unwrap_or_default();
                    if bytes.len() >= end + 4 + length {
                        break;
                    }
                }
            }
            let text = String::from_utf8(bytes).unwrap();
            assert!(text.starts_with("POST /api/v1/auth/login "));
            assert!(text.contains("only-server-a-password"));
            sent.send(()).unwrap();
            unblock.recv_timeout(Duration::from_secs(3)).unwrap();
            let body = r#"{"data":{"username":"old-a"}}"#;
            let _ = socket.write_all(format!("HTTP/1.1 200 OK\r\nSet-Cookie: obsolete=late-a; Path=/\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).as_bytes());
        });
        let request_context = old.clone();
        let operation = tokio::spawn(async move {
            cookie_request(
                &request_context,
                "POST",
                "/auth/login",
                Some(json!({"username":"old-a","password":"only-server-a-password"})),
            )
            .await
        });
        tokio::time::timeout(Duration::from_secs(3), received)
            .await
            .unwrap()
            .unwrap();
        connect::save_server_url(server_b.clone()).unwrap();
        let current = load_context().unwrap();
        assert_eq!(current.server, server_b);
        assert!(current.generation > old.generation);
        assert!(old.cancellation.is_cancelled());
        assert!(operation.await.unwrap().is_err());
        finish.send(()).unwrap();
        handler.join().unwrap();
        assert_eq!(
            b.accept().unwrap_err().kind(),
            std::io::ErrorKind::WouldBlock
        );
        assert_eq!(
            error_status(
                &activate(&old, &json!({"username":"old-a"}), "late-token")
                    .err()
                    .unwrap()
            ),
            409
        );
        assert!(identity(&current.server, None).unwrap().is_none());
        assert!(
            api_proxy::test_cookie_header(&connect::validate_http_url(&server_a).unwrap())
                .is_none()
        );
        if previous.is_empty() {
            connect::clear_server_url().unwrap();
        } else {
            connect::save_server_url(previous).unwrap();
        }
    }

    #[tokio::test]
    async fn cancelling_pair_waits_for_inflight_verification_and_never_installs_late_token() {
        use std::io::{Read, Write};
        let _guard = CONTEXT_TEST.lock().await;
        let previous = connect::load_server_url().unwrap();
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let server = format!("http://{}", listener.local_addr().unwrap());
        connect::save_server_url(server.clone()).unwrap();
        let context = load_context().unwrap();
        let (waiting, verification) = tokio::sync::oneshot::channel();
        let (finish, unblock) = std::sync::mpsc::channel();
        let handler = std::thread::spawn(move || {
            let (mut socket, _) = listener.accept().unwrap();
            let mut buffer = [0; 8192];
            let count = socket.read(&mut buffer).unwrap();
            assert!(String::from_utf8_lossy(&buffer[..count])
                .starts_with("POST /api/v1/auth/device/token "));
            let body = r#"{"data":{"token":"late-pair-token"}}"#;
            socket
                .write_all(
                    format!(
                        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                        body.len()
                    )
                    .as_bytes(),
                )
                .unwrap();
            let (mut socket, _) = listener.accept().unwrap();
            let count = socket.read(&mut buffer).unwrap();
            assert!(String::from_utf8_lossy(&buffer[..count]).starts_with("GET /api/v1/auth/me "));
            waiting.send(()).unwrap();
            unblock.recv_timeout(Duration::from_secs(3)).unwrap();
            let body = r#"{"data":{"username":"late-pair-member","nickname":"Late"}}"#;
            let _ = socket.write_all(
                format!(
                    "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                    body.len()
                )
                .as_bytes(),
            );
        });
        let id = "test-private-pairing".to_owned();
        PAIRS.lock().unwrap().insert(
            id.clone(),
            Pairing {
                context: context.clone(),
                device_code: "private-code".into(),
                cancellation: CancellationToken::new(),
                expires_at: now() + 30,
                interval: 1,
                next_poll: 0,
            },
        );
        let poll_id = id.clone();
        let poll = tokio::spawn(async move { native_pair_poll(poll_id).await });
        tokio::time::timeout(Duration::from_secs(3), verification)
            .await
            .unwrap()
            .unwrap();
        assert!(
            tokio::time::timeout(Duration::from_secs(3), native_pair_cancel(id))
                .await
                .unwrap()
        );
        assert_eq!(poll.await.unwrap().unwrap()["status"], "cancelled");
        finish.send(()).unwrap();
        handler.join().unwrap();
        assert!(
            vault::read(&vault::token_key(&context.namespace, "late-pair-member"))
                .unwrap()
                .is_none()
        );
        assert!(identity(&server, None).unwrap().is_none());
        if previous.is_empty() {
            connect::clear_server_url().unwrap();
        } else {
            connect::save_server_url(previous).unwrap();
        }
    }

    #[tokio::test]
    async fn shutdown_retires_auth_socket_rejects_late_commit_and_new_requests() {
        use std::io::{Read, Write};
        let _guard = CONTEXT_TEST.lock().await;
        let previous = connect::load_server_url().unwrap();
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let server = format!("http://{}", listener.local_addr().unwrap());
        connect::save_server_url(server).unwrap();
        let context = load_context().unwrap();
        let (started, waiting) = tokio::sync::oneshot::channel();
        let handler = std::thread::spawn(move || {
            let (mut socket, _) = listener.accept().unwrap();
            socket
                .set_read_timeout(Some(Duration::from_secs(3)))
                .unwrap();
            let mut bytes = [0; 4096];
            socket.read(&mut bytes).unwrap();
            socket.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 1000000\r\nConnection: close\r\n\r\n{\"data\":").unwrap();
            started.send(()).unwrap();
            match socket.read(&mut bytes) {
                Ok(0) => true,
                Err(error) => matches!(
                    error.kind(),
                    std::io::ErrorKind::ConnectionReset | std::io::ErrorKind::ConnectionAborted
                ),
                _ => false,
            }
        });
        let captured = context.clone();
        let operation = tokio::spawn(async move {
            request(
                &captured,
                Method::GET,
                "/auth/me",
                None,
                Some("private-auth-token"),
                None,
            )
            .await
        });
        waiting.await.unwrap();
        retire_for_shutdown();
        assert!(context.cancellation.is_cancelled());
        assert_eq!(error_status(&operation.await.unwrap().err().unwrap()), 409);
        assert!(load_context().err().unwrap().contains("APP_SHUTTING_DOWN"));
        assert_eq!(
            error_status(
                &activate(
                    &context,
                    &json!({"username":"late-exit-account"}),
                    "late-exit-secret"
                )
                .err()
                .unwrap()
            ),
            409
        );
        assert!(
            vault::read(&vault::token_key(&context.namespace, "late-exit-account"))
                .unwrap()
                .is_none()
        );
        assert!(tokio::task::spawn_blocking(move || handler.join().unwrap())
            .await
            .unwrap());
        // The actual process never resumes after shutdown; only the isolated
        // test host resets this flag so subsequent tests can create contexts.
        with_context_read(|| SHUTTING_DOWN.store(false, Ordering::SeqCst));
        if previous.is_empty() {
            connect::clear_server_url().unwrap();
        } else {
            connect::save_server_url(previous).unwrap();
        }
    }
    #[tokio::test]
    async fn separate_server_prefixes_never_share_device_credentials_or_invalidation() {
        use std::io::{Read, Write};
        let _guard = CONTEXT_TEST.lock().await;
        let previous = connect::load_server_url().unwrap();
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let host = format!("http://{}", listener.local_addr().unwrap());
        let a = format!("{host}/a");
        let b = format!("{host}/b");
        connect::save_server_url(a.clone()).unwrap();
        let context_a = activate(
            &load_context().unwrap(),
            &json!({"username":"a-member"}),
            "a-device-token",
        )
        .unwrap();
        with_current(&context_a, || {
            let mut store = STORE.lock().unwrap();
            store.get_mut(&a).unwrap().supports_native = Some(true);
            persist(&store)
        })
        .unwrap();
        let retired_identity = identity(&a, None).unwrap().unwrap();
        let handler = std::thread::spawn(move || {
            for (path, secret, redirect) in [
                ("/b/api/v1/direct", None, None),
                (
                    "/a/api/v1/probe",
                    Some("a-device-token"),
                    Some("/a2/api/v1/probe"),
                ),
                ("/a2/api/v1/probe", None, None),
                (
                    "/a/api/v1/media",
                    Some("a-device-token"),
                    Some("/b/api/v1/media"),
                ),
                ("/b/api/v1/media", None, None),
                ("/b/api/v1/probe", None, None),
                ("/b/api/v1/probe", Some("b-device-token"), None),
            ] {
                let (mut socket, _) = listener.accept().unwrap();
                socket
                    .set_read_timeout(Some(Duration::from_secs(3)))
                    .unwrap();
                let mut buffer = [0; 4096];
                let count = socket.read(&mut buffer).unwrap();
                let text = String::from_utf8_lossy(&buffer[..count]).to_ascii_lowercase();
                assert_eq!(
                    text.lines().next().unwrap().split_whitespace().nth(1),
                    Some(path)
                );
                match secret {
                    Some(secret) => {
                        assert!(text.contains(&format!("authorization: bearer {secret}")))
                    }
                    None => assert!(!text.contains("authorization:")),
                }
                assert!(!text.contains("cookie:"));
                let body = r#"{"data":{"ok":true}}"#;
                let header = match redirect {
                    Some(location) => format!("HTTP/1.1 302 Found\r\nLocation: {location}\r\n"),
                    None => "HTTP/1.1 401 Unauthorized\r\n".into(),
                };
                socket
                    .write_all(
                        format!(
                            "{header}Content-Length: {}\r\nConnection: close\r\n\r\n{body}",
                            body.len()
                        )
                        .as_bytes(),
                    )
                    .unwrap();
            }
        });
        assert_eq!(
            api_proxy::proxy_api(
                "GET".into(),
                format!(
                    "/__image__?{}",
                    url::form_urlencoded::Serializer::new(String::new())
                        .append_pair("url", &format!("{b}/api/v1/direct"))
                        .finish()
                ),
                None,
                None,
                None
            )
            .await
            .unwrap()
            .status,
            401
        );
        assert_eq!(
            api_proxy::proxy_api("GET".into(), "/probe".into(), None, None, None)
                .await
                .unwrap()
                .status,
            401
        );
        let stream = crate::media_stream::grant_native("/api/v1/media").unwrap();
        assert_eq!(reqwest::get(&stream.url).await.unwrap().status(), 401);
        crate::media_stream::release(&stream.stream_id);
        assert_eq!(
            vault::read(&vault::token_key(&a, "a-member"))
                .unwrap()
                .as_deref(),
            Some("a-device-token")
        );
        connect::save_server_url(b.clone()).unwrap();
        invalidate(&retired_identity);
        assert_eq!(
            vault::read(&vault::token_key(&a, "a-member"))
                .unwrap()
                .as_deref(),
            Some("a-device-token")
        );
        assert!(identity(&b, None).unwrap().is_none());
        assert_eq!(
            api_proxy::proxy_api("GET".into(), "/probe".into(), None, None, None)
                .await
                .unwrap()
                .status,
            401
        );
        let context_b = activate(
            &load_context().unwrap(),
            &json!({"username":"b-member"}),
            "b-device-token",
        )
        .unwrap();
        assert_eq!(
            api_proxy::proxy_api("GET".into(), "/probe".into(), None, None, None)
                .await
                .unwrap()
                .status,
            401
        );
        // A's vault entry survives B's unauthorized response; B alone is revoked.
        assert!(vault::read(&vault::token_key(&b, "b-member"))
            .unwrap()
            .is_none());
        assert_eq!(
            vault::read(&vault::token_key(&a, "a-member"))
                .unwrap()
                .as_deref(),
            Some("a-device-token")
        );
        vault::delete(&vault::token_key(&a, "a-member")).unwrap();
        tokio::task::spawn_blocking(move || handler.join().unwrap())
            .await
            .unwrap();
        with_current(&context_b, || {
            let mut store = STORE.lock().unwrap();
            store.remove(&a);
            store.remove(&b);
            persist(&store)
        })
        .unwrap();
        if previous.is_empty() {
            connect::clear_server_url().unwrap();
        } else {
            connect::save_server_url(previous).unwrap();
        }
    }
    #[tokio::test]
    async fn server_device_downgrade_uses_cookie_identity_for_api_and_streaming() {
        use std::io::{Read, Write};
        let _guard = CONTEXT_TEST.lock().await;
        let previous = connect::load_server_url().unwrap();
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let server = format!("http://{}", listener.local_addr().unwrap());
        connect::save_server_url(server.clone()).unwrap();
        let initial = load_context().unwrap();
        let old = activate(
            &initial,
            &json!({"username":"old-device-a"}),
            "old-device-private-token",
        )
        .unwrap();
        with_current(&old, || {
            let mut store = STORE.lock().unwrap();
            store.get_mut(&old.namespace).unwrap().supports_native = Some(true);
            persist(&store)
        })
        .unwrap();
        assert!(identity(&server, None).unwrap().is_some());
        let old_stream = crate::media_stream::grant_native("/api/v1/media").unwrap();
        let handler = std::thread::spawn(move || {
            for expected in [
                "/api/v1/auth/bootstrap",
                "/api/v1/auth/login",
                "/api/v1/auth/me",
                "/api/v1/auth/accounts",
                "/api/v1/probe",
                "/api/v1/media",
            ] {
                let (mut socket, _) = listener.accept().unwrap();
                socket
                    .set_read_timeout(Some(Duration::from_secs(3)))
                    .unwrap();
                let mut bytes = Vec::new();
                let mut buffer = [0; 4096];
                loop {
                    let n = socket.read(&mut buffer).unwrap();
                    assert!(n > 0);
                    bytes.extend_from_slice(&buffer[..n]);
                    if let Some(end) = bytes.windows(4).position(|v| v == b"\r\n\r\n") {
                        let header = String::from_utf8_lossy(&bytes[..end]);
                        let length = header
                            .lines()
                            .find_map(|v| {
                                v.to_ascii_lowercase()
                                    .strip_prefix("content-length: ")
                                    .and_then(|v| v.parse::<usize>().ok())
                            })
                            .unwrap_or_default();
                        if bytes.len() >= end + 4 + length {
                            break;
                        }
                    }
                }
                let text = String::from_utf8(bytes).unwrap();
                assert_eq!(
                    text.lines().next().unwrap().split_whitespace().nth(1),
                    Some(expected)
                );
                assert!(!text.to_ascii_lowercase().contains("authorization:"));
                if !matches!(expected, "/api/v1/auth/bootstrap" | "/api/v1/auth/login") {
                    assert!(text
                        .to_ascii_lowercase()
                        .contains("cookie: compatibility=cookie-b"));
                }
                let (body, extra) = match expected {
                    "/api/v1/auth/bootstrap" => (
                        r#"{"data":{"initialized":true,"native_device_kinds":["macos"]}}"#,
                        "",
                    ),
                    "/api/v1/auth/login" => {
                        assert!(text.contains("cookie-b-password"));
                        (
                            r#"{"data":{"username":"cookie-b"}}"#,
                            "Set-Cookie: compatibility=cookie-b; Path=/; HttpOnly\r\n",
                        )
                    }
                    "/api/v1/auth/accounts" => {
                        (r#"{"data":[{"username":"cookie-b","active":true}]}"#, "")
                    }
                    _ => (r#"{"data":{"username":"cookie-b"}}"#, ""),
                };
                socket.write_all(format!("HTTP/1.1 200 OK\r\n{extra}Content-Length: {}\r\nConnection: close\r\n\r\n{body}", body.len()).as_bytes()).unwrap();
            }
        });
        let logged_in = native_password_login("cookie-b".into(), "cookie-b-password".into())
            .await
            .unwrap();
        assert_eq!(logged_in["mode"], "cookie");
        assert_eq!(logged_in["session"]["username"], "cookie-b");
        assert!(old.cancellation.is_cancelled());
        assert!(identity(&server, None).unwrap().is_none());
        assert!(identity(&server, Some("old-device-a")).unwrap().is_none());
        assert_eq!(
            error_status(
                &activate(&old, &json!({"username":"old-device-a"}), "late-token")
                    .err()
                    .unwrap()
            ),
            409
        );
        // Downgrading mode retires previously granted streams before compatibility
        // login, so an old Bearer lease cannot leak into the new Cookie session.
        let client = reqwest::Client::new();
        assert_eq!(
            client.get(old_stream.url).send().await.unwrap().status(),
            410
        );
        let response = api_proxy::proxy_api("GET".into(), "/probe".into(), None, None, None)
            .await
            .unwrap();
        assert!(response.body.contains("cookie-b"));
        let stream = crate::media_stream::grant_native("/api/v1/media").unwrap();
        assert!(client
            .get(&stream.url)
            .send()
            .await
            .unwrap()
            .text()
            .await
            .unwrap()
            .contains("cookie-b"));
        crate::media_stream::release(&stream.stream_id);
        assert_eq!(
            vault::read(&vault::token_key(&old.namespace, "old-device-a"))
                .unwrap()
                .as_deref(),
            Some("old-device-private-token")
        );
        vault::delete(&vault::token_key(&old.namespace, "old-device-a")).unwrap();
        tokio::task::spawn_blocking(move || handler.join().unwrap())
            .await
            .unwrap();
        with_current(&load_context().unwrap(), || {
            let mut store = STORE.lock().unwrap();
            store.remove(&old.namespace);
            persist(&store)
        })
        .unwrap();
        if previous.is_empty() {
            connect::clear_server_url().unwrap();
        } else {
            connect::save_server_url(previous).unwrap();
        }
    }

    #[tokio::test]
    async fn offline_account_forgetting_keeps_only_vault_revocation_until_reconnect() {
        let _guard = CONTEXT_TEST.lock().await;
        let previous = connect::load_server_url().unwrap();
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let address = listener.local_addr().unwrap();
        drop(listener);
        let server = format!("http://{address}");
        connect::save_server_url(server.clone()).unwrap();
        let context = load_context().unwrap();
        let current = activate(
            &context,
            &json!({"username":"offline-member","nickname":"Offline"}),
            "offline-private-token",
        )
        .unwrap();
        with_current(&current, || {
            let mut store = STORE.lock().unwrap();
            let entry = store.get_mut(&current.namespace).unwrap();
            entry.supports_native = Some(true);
            entry.initialized = true;
            persist(&store)
        })
        .unwrap();
        let result = native_remove_account("offline-member".into())
            .await
            .unwrap();
        assert!(result["session"].is_null());
        assert!(result["accounts"].as_array().unwrap().is_empty());
        let pending = STORE
            .lock()
            .unwrap()
            .get(&current.namespace)
            .unwrap()
            .pending_revocations
            .clone();
        assert_eq!(pending.len(), 1);
        let key = revocation_key(&current.namespace, &pending[0]);
        assert_eq!(
            vault::read(&key).unwrap().as_deref(),
            Some("offline-private-token")
        );
        assert!(
            vault::read(&vault::token_key(&current.namespace, "offline-member"))
                .unwrap()
                .is_none()
        );
        assert!(
            !std::fs::read_to_string(connect::config_dir().join("accounts.json"))
                .unwrap()
                .contains("offline-private-token")
        );
        let listener = std::net::TcpListener::bind(address).unwrap();
        let handler = std::thread::spawn(move || {
            use std::io::{Read, Write};
            let (mut socket, _) = listener.accept().unwrap();
            let mut buffer = [0; 8192];
            let count = socket.read(&mut buffer).unwrap();
            let text = String::from_utf8_lossy(&buffer[..count]);
            assert!(text.starts_with("DELETE /api/v1/auth/devices/current "));
            assert!(text
                .to_ascii_lowercase()
                .contains("authorization: bearer offline-private-token"));
            socket
                .write_all(
                    concat!(
                        "HTTP/1.1 200 OK\r\nContent-Length: 11\r\nConnection: close\r\n\r\n",
                        r#"{"data":{}}"#
                    )
                    .as_bytes(),
                )
                .unwrap();
        });
        retry_revocations(load_context().unwrap());
        tokio::time::timeout(Duration::from_secs(3), async {
            loop {
                if STORE
                    .lock()
                    .unwrap()
                    .get(&current.namespace)
                    .unwrap()
                    .pending_revocations
                    .is_empty()
                {
                    break;
                }
                tokio::time::sleep(Duration::from_millis(10)).await;
            }
        })
        .await
        .unwrap();
        assert!(vault::read(&key).unwrap().is_none());
        tokio::task::spawn_blocking(move || handler.join().unwrap())
            .await
            .unwrap();
        with_current(&load_context().unwrap(), || {
            let mut store = STORE.lock().unwrap();
            store.remove(&current.namespace);
            persist(&store)
        })
        .unwrap();
        if previous.is_empty() {
            connect::clear_server_url().unwrap();
        } else {
            connect::save_server_url(previous).unwrap();
        }
    }
}
