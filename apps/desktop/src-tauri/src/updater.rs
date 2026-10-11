use serde::{Deserialize, Serialize};
#[path = "updater/verified.rs"]
pub mod verified;

#[cfg(test)]
#[path = "release_repository.rs"]
mod release_repository;

const GITHUB_REPO: &str = env!("MOVIECLAW_RELEASE_REPOSITORY");
const CURRENT_VERSION: &str = env!("CARGO_PKG_VERSION");
const CURRENT_REVISION: &str = env!("MOVIECLAW_BUILD_REVISION");
const CURRENT_TIMESTAMP: &str = env!("MOVIECLAW_BUILD_TIMESTAMP");

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ReleaseBuild {
    version: String,
    source_revision: String,
    #[serde(default)]
    source_timestamp: u64,
}

impl ReleaseBuild {
    fn newer_than(&self, version: &str, revision: &str, timestamp: u64) -> bool {
        self.version == version
            && self.source_revision.len() == 40
            && self.source_revision.bytes().all(|byte| byte.is_ascii_hexdigit())
            && revision != "unknown"
            && self.source_revision != revision
            && self.source_timestamp > timestamp
    }
}

async fn release_build(release: &serde_json::Value) -> Result<Option<ReleaseBuild>, String> {
    let tag = release["tag_name"].as_str().ok_or("发布版本无效")?;
    if !verified::valid_tag(tag) { return Err("发布版本无效".into()); }
    let Some(asset) = release["assets"].as_array().and_then(|assets| assets.iter().find(|asset| asset["name"] == "release-manifest.json")) else { return Ok(None); };
    let expected = format!("https://github.com/{GITHUB_REPO}/releases/download/{tag}/release-manifest.json");
    if asset["browser_download_url"].as_str() != Some(&expected) { return Err("发布构建信息的仓库不匹配".into()); }
    let bytes = verified::small(verified::delivery_url(&expected)?, 64 * 1024).await?;
    let bytes = bytes.strip_prefix(&[0xef, 0xbb, 0xbf]).unwrap_or(&bytes);
    let build: ReleaseBuild = serde_json::from_slice(bytes).map_err(|_| "发布构建信息无效")?;
    if build.source_revision.len() != 40 || !build.source_revision.bytes().all(|byte| byte.is_ascii_hexdigit()) { return Err("发布构建标识无效".into()); }
    if format!("desktop-v{}", build.version) != tag && format!("v{}", build.version) != tag {
        return Err("发布构建版本与标签不一致".into());
    }
    Ok(Some(build))
}

async fn same_version_update(release: &serde_json::Value) -> Result<Option<String>, String> {
    Ok(release_build(release).await?.filter(|build| build.newer_than(CURRENT_VERSION, CURRENT_REVISION, CURRENT_TIMESTAMP.parse().unwrap_or(0)))
        .map(|build| build.source_revision))
}

#[derive(Debug, Serialize, Deserialize)]
pub struct UpdateInfo {
    pub has_update: bool,
    pub current_version: String,
    pub latest_version: String,
    pub download_url: String,
    pub release_notes: String,
    pub message: String,
}

/// 解析版本号字符串为 (major, minor, patch) 比较元组
/// 支持格式: "0.2.100", "v0.2.100", "desktop-v0.2.100", "desktop-0.2.100"
fn parse_version(v: &str) -> (u64, u64, u64) {
    // 移除所有前缀: "desktop-v", "desktop-", "v"
    let cleaned = v
        .trim()
        .trim_start_matches("desktop-v")
        .trim_start_matches("desktop-")
        .trim_start_matches('v');
    let parts: Vec<&str> = cleaned.split('.').collect();
    let major = parts.first().and_then(|s| s.parse().ok()).unwrap_or(0);
    let minor = parts.get(1).and_then(|s| s.parse().ok()).unwrap_or(0);
    let patch = parts.get(2).and_then(|s| s.parse().ok()).unwrap_or(0);
    (major, minor, patch)
}

fn windows_download_url(release: &serde_json::Value) -> Option<&str> {
    let tag = release.get("tag_name")?.as_str()?;
    if !verified::valid_tag(tag) {
        return None;
    }
    let version = parse_version(tag);
    let version = format!("{}.{}.{}", version.0, version.1, version.2);
    let assets = release.get("assets")?.as_array()?;
    for suffix in ["-Setup-x64.exe", "-portable-x64.zip"] {
        let expected_name = format!("MovieClaw-Desktop-{version}{suffix}");
        let expected_url =
            format!("https://github.com/{GITHUB_REPO}/releases/download/{tag}/{expected_name}");
        if let Some(url) = assets.iter().find_map(|asset| {
            let name = asset.get("name")?.as_str()?;
            let url = asset.get("browser_download_url")?.as_str()?;
            (name == expected_name && url == expected_url).then_some(url)
        }) {
            return Some(url);
        }
    }
    None
}

/// 检查 GitHub Releases 是否有新版本
#[tauri::command]
pub async fn check_for_updates() -> Result<UpdateInfo, String> {
    // 获取所有 releases，找最新的桌面版 release
    let url = format!("https://api.github.com/repos/{GITHUB_REPO}/releases?per_page=10");
    let bytes = verified::small(verified::delivery_url(&url)?, 1024 * 1024).await?;
    let releases: serde_json::Value =
        serde_json::from_slice(&bytes).map_err(|_| "更新发布信息无效".to_owned())?;

    let current_ver = parse_version(CURRENT_VERSION);

    // 找最新的包含 Setup exe 的桌面 release
    let mut best_release: Option<&serde_json::Value> = None;
    let mut best_ver = current_ver;
    let mut has_update = false;

    if let Some(arr) = releases.as_array() {
        for release in arr {
            if release
                .get("draft")
                .and_then(|v| v.as_bool())
                .unwrap_or(false)
                || release
                    .get("prerelease")
                    .and_then(|v| v.as_bool())
                    .unwrap_or(false)
            {
                continue;
            }
            let tag = release
                .get("tag_name")
                .and_then(|t| t.as_str())
                .unwrap_or("");
            if !verified::valid_tag(tag) {
                continue;
            }
            // 旧版 v* 与新版 desktop-v* 均须有可用的 Windows x64 桌面包。
            // 跳过尚未上传资源的 release，避免提示无法安装的更新。
            if windows_download_url(release).is_none() {
                continue;
            }

            let ver = parse_version(tag);
            if ver > best_ver || ver == best_ver && best_release.is_none() {
                best_ver = ver;
                best_release = Some(release);
                has_update = ver > current_ver;
            }
        }
    }

    let mut latest_revision = None;
    if !has_update {
        if let Some(release) = best_release {
            latest_revision = same_version_update(release).await?;
            has_update = latest_revision.is_some();
        }
    }
    let (latest_tag, download_url, release_notes) = if let Some(release) = best_release {
        let tag = release
            .get("tag_name")
            .and_then(|t| t.as_str())
            .unwrap_or("")
            .to_string();

        let url = windows_download_url(release)
            .unwrap_or_default()
            .to_string();

        let notes = release
            .get("body")
            .and_then(|b| b.as_str())
            .unwrap_or("")
            .to_string();

        (tag, url, notes)
    } else {
        (String::new(), String::new(), String::new())
    };

    let release_notes = truncate_notes(&release_notes);

    Ok(UpdateInfo {
        has_update,
        current_version: CURRENT_VERSION.to_string(),
        latest_version: latest_tag.clone(),
        download_url,
        release_notes,
        message: if let Some(revision) = latest_revision {
            format!("发现 {CURRENT_VERSION} 的新构建 {}（当前 {}）", &revision[..8], &CURRENT_REVISION[..8])
        } else if has_update {
            format!("发现新版本 {latest_tag}（当前 {CURRENT_VERSION}）")
        } else {
            format!("已是最新版本 ({CURRENT_VERSION})")
        },
    })
}

/// 在浏览器中打开下载页面
#[tauri::command]
pub fn open_download_page() -> Result<bool, String> {
    let url = format!("https://github.com/{GITHUB_REPO}/releases/latest");
    open::that(&url).map_err(|e| format!("打开浏览器失败: {e}"))?;
    Ok(true)
}

/// 打开指定版本的 release 页面
#[tauri::command]
pub fn open_release_page() -> Result<bool, String> {
    let url = format!("https://github.com/{GITHUB_REPO}/releases");
    open::that(&url).map_err(|e| format!("打开浏览器失败: {e}"))?;
    Ok(true)
}

fn truncate_notes(notes: &str) -> String {
    notes.chars().take(500).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn version_prefixes_and_unicode_notes_are_safe() {
        assert_eq!(parse_version("desktop-v0.2.111"), (0, 2, 111));
        assert_eq!(parse_version("v0.2.111"), (0, 2, 111));
        assert_eq!(truncate_notes(&"更".repeat(700)).chars().count(), 500);
        assert_eq!(truncate_notes("short"), "short");
    }

    #[test]
    fn same_version_build_updates_require_a_newer_matching_revision() {
        let mut build = ReleaseBuild { version: "1.0.0".into(), source_revision: "b".repeat(40), source_timestamp: 200 };
        assert!(build.newer_than("1.0.0", &"a".repeat(40), 100));
        assert!(!build.newer_than("1.0.0", &"b".repeat(40), 100));
        assert!(!build.newer_than("1.0.0", &"a".repeat(40), 200));
        assert!(!build.newer_than("1.0.0", &"a".repeat(40), 300));
        assert!(!build.newer_than("1.0.1", &"a".repeat(40), 100));
        assert!(!build.newer_than("1.0.0", "unknown", 0));
        build.source_timestamp = 0;
        assert!(!build.newer_than("1.0.0", &"a".repeat(40), 100));
        build.source_timestamp = 200; build.source_revision = "invalid".into();
        assert!(!build.newer_than("1.0.0", &"a".repeat(40), 100));
    }

    #[test]
    fn update_assets_require_usable_windows_x64_packages() {
        let url = |name: &str| format!("https://github.com/{GITHUB_REPO}/releases/download/desktop-v0.2.112/{name}");
        let installer = url("MovieClaw-Desktop-0.2.112-Setup-x64.exe");
        let foreign = if GITHUB_REPO == "another/repository" { "other/repository" } else { "another/repository" };
        let release = serde_json::json!({"tag_name":"desktop-v0.2.112", "assets": [
            {"name": "server-linux.zip", "browser_download_url": "https://example.test/linux"},
            {"name": "MovieClaw-Desktop-0.2.112-portable-x64.zip", "browser_download_url": url("MovieClaw-Desktop-0.2.112-portable-x64.zip")},
            {"name": "MovieClaw-Desktop-0.2.112-Setup-x64.exe", "browser_download_url": installer}
        ]});
        assert_eq!(
            windows_download_url(&release),
            Some(installer.as_str())
        );
        assert_eq!(
            windows_download_url(&serde_json::json!({"assets": []})),
            None
        );
        let wrong_arch = serde_json::json!({"tag_name":"desktop-v0.2.112", "assets": [
            {"name": "MovieClaw-Desktop-0.2.112-Setup-arm64.exe", "browser_download_url": "https://example.test/arm"}
        ]});
        assert_eq!(windows_download_url(&wrong_arch), None);
        for (name, url) in [
            ("Another-App-Setup-x64.exe", url("Another-App-Setup-x64.exe")),
            ("MovieClaw-Desktop-0.2.112-Setup-x64.exe", format!("https://github.com/{foreign}/releases/download/desktop-v0.2.112/MovieClaw-Desktop-0.2.112-Setup-x64.exe")),
            ("MovieClaw-Desktop-0.2.111-Setup-x64.exe", url("MovieClaw-Desktop-0.2.111-Setup-x64.exe")),
        ] {
            assert_eq!(windows_download_url(&serde_json::json!({"tag_name":"desktop-v0.2.112", "assets":[{"name":name,"browser_download_url":url}]})), None);
        }
    }
}
