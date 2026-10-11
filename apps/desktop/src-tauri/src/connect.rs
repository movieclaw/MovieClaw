use serde::{Deserialize, Serialize};
use std::{fs, path::PathBuf};
use url::Url;

#[derive(Debug, Serialize, Deserialize)]
pub struct ConnectResult {
    pub ok: bool,
    pub message: String,
}

pub(crate) fn config_dir() -> PathBuf {
    if let Some(path) = std::env::var_os("MOVIECLAW_DATA_DIR") {
        let dir = PathBuf::from(path);
        let _ = fs::create_dir_all(&dir);
        return dir;
    }
    #[cfg(test)]
    let base = std::env::temp_dir().join(format!("movieclaw-rust-tests-{}", std::process::id()));
    #[cfg(all(windows, not(test)))]
    let base = std::env::var_os("APPDATA")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("."));
    #[cfg(all(not(windows), not(test)))]
    let base = std::env::var_os("HOME")
        .map(|h| PathBuf::from(h).join(".config"))
        .unwrap_or_else(|| PathBuf::from("."));
    let dir = base.join("movieclaw-desktop");
    let _ = fs::create_dir_all(&dir);
    dir
}

fn config_path() -> PathBuf {
    config_dir().join("server.json")
}

pub(crate) fn validate_http_url(value: &str) -> Result<Url, String> {
    let url = Url::parse(value).map_err(|_| "无效的服务器地址")?;
    if !matches!(url.scheme(), "http" | "https")
        || url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.fragment().is_some()
    {
        return Err("地址必须是 HTTP(S)，且不能包含用户名、密码或片段".into());
    }
    Ok(url)
}

pub(crate) fn url_in_server_scope(base: &Url, target: &Url) -> bool {
    if base.origin() != target.origin() {
        return false;
    }
    let prefix = base.path().trim_end_matches('/');
    prefix.is_empty()
        || target.path() == prefix
        || target
            .path()
            .strip_prefix(prefix)
            .is_some_and(|rest| rest.starts_with('/'))
}
pub(crate) fn server_namespace(base: &Url) -> String {
    base.as_str().trim_end_matches('/').to_owned()
}

fn normalize_server_url(value: &str) -> Result<String, String> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return Err("URL 不能为空".into());
    }
    let candidate = if trimmed.contains("://") {
        trimmed.to_owned()
    } else {
        format!("http://{trimmed}")
    };
    let url = validate_http_url(&candidate)?;
    if url.query().is_some() {
        return Err("服务器地址不能包含查询参数".into());
    }
    Ok(url.as_str().trim_end_matches('/').to_owned())
}

#[tauri::command]
pub fn save_server_url(url: String) -> Result<ConnectResult, String> {
    let normalized = normalize_server_url(&url)?;
    crate::native_auth::change_server(|| {
        fs::write(config_path(), &normalized).map_err(|e| format!("写入配置失败: {e}"))
    })?;
    Ok(ConnectResult {
        ok: true,
        message: normalized,
    })
}

#[tauri::command]
pub fn get_server_url() -> Result<String, String> {
    load_server_url()
}

#[tauri::command]
pub fn load_server_url() -> Result<String, String> {
    crate::native_auth::with_context_read(read_server_url_unlocked)
}
pub(crate) fn read_server_url_unlocked() -> Result<String, String> {
    match fs::read_to_string(config_path()) {
        Ok(s) => normalize_server_url(s.trim_start_matches('\u{FEFF}')),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(String::new()),
        Err(e) => Err(format!("读取服务器配置失败: {e}")),
    }
}

#[tauri::command]
pub fn clear_server_url() -> Result<ConnectResult, String> {
    crate::native_auth::change_server(|| {
        let path = config_path();
        if path.exists() {
            fs::remove_file(path).map_err(|e| format!("删除配置失败: {e}"))?;
        }
        Ok(())
    })?;
    Ok(ConnectResult {
        ok: true,
        message: "已断开服务器".into(),
    })
}

#[tauri::command]
pub async fn probe_server(url: String) -> Result<ConnectResult, String> {
    let normalized = normalize_server_url(&url)?;
    let response = reqwest::Client::new()
        .get(format!("{normalized}/api/v1/health"))
        .timeout(std::time::Duration::from_secs(5))
        .send()
        .await;
    let result = match response {
        Ok(resp) if resp.status().is_success() => ConnectResult {
            ok: true,
            message: "连接成功".into(),
        },
        Ok(resp) => ConnectResult {
            ok: false,
            message: format!("服务返回 {}", resp.status()),
        },
        Err(e) => ConnectResult {
            ok: false,
            message: format!("无法连接: {e}"),
        },
    };
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn server_scope_requires_origin_and_prefix_boundary() {
        let a = Url::parse("https://server/a").unwrap();
        for value in ["https://server/a", "https://server/a/api/v1/me"] {
            assert!(url_in_server_scope(&a, &Url::parse(value).unwrap()));
        }
        for value in [
            "https://server/b",
            "https://server/a2/me",
            "https://server/a/../b",
            "https://elsewhere/a/me",
        ] {
            assert!(!url_in_server_scope(&a, &Url::parse(value).unwrap()));
        }
    }
    #[test]
    fn validates_and_normalizes_server_addresses() {
        assert_eq!(
            normalize_server_url(" 127.0.0.1:3000/ ").unwrap(),
            "http://127.0.0.1:3000"
        );
        assert_eq!(
            normalize_server_url("https://EXAMPLE.com/movieclaw/").unwrap(),
            "https://example.com/movieclaw"
        );
        for bad in [
            "",
            "file:///tmp/x",
            "javascript:alert(1)",
            "https://u:p@server",
            "https://server/#fragment",
            "https://server/?token=x",
            "http://",
        ] {
            assert!(normalize_server_url(bad).is_err(), "accepted {bad}");
        }
    }
}
