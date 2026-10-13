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
/// Windows 版发布的标签前缀，服务器和其他客户端的发布各有自己的前缀。
const TAG_PREFIX: &str = "windows-v";
/// 最近一次检查更新找到的 Windows 发布标签，打开发布页时用。
static LATEST_TAG: std::sync::Mutex<Option<String>> = std::sync::Mutex::new(None);

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
    if format!("{TAG_PREFIX}{}", build.version) != tag {
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
/// 支持格式: "0.2.100", "windows-v0.2.100"
fn parse_version(v: &str) -> (u64, u64, u64) {
    let cleaned = v.trim().trim_start_matches(TAG_PREFIX);
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
        let expected_name = format!("MovieClaw-Windows-{version}{suffix}");
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

/// 本渠道的 Windows 正式版标签，按版本从高到低。只列 windows-v* 引用，
/// 不翻 Release 列表：同仓库还有服务器和其他客户端的发布，Windows 版可能排不进第一页。
fn windows_tags(refs: &serde_json::Value) -> Vec<&str> {
    let mut tags: Vec<&str> = refs
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|item| item.get("ref")?.as_str()?.strip_prefix("refs/tags/"))
        .filter(|tag| verified::valid_tag(tag))
        .collect();
    tags.sort_by_key(|tag| std::cmp::Reverse(parse_version(tag)));
    tags
}

fn installable(release: &serde_json::Value) -> bool {
    release.get("draft").and_then(|v| v.as_bool()) == Some(false)
        && release.get("prerelease").and_then(|v| v.as_bool()) == Some(false)
        && windows_download_url(release).is_some()
}

fn not_found(error: &str) -> bool {
    serde_json::from_str::<serde_json::Value>(error).is_ok_and(|v| v["code"] == "UPDATE_NOT_FOUND")
}

/// 不低于当前版本的最新可安装 Windows 发布。打了标签还没发布、草稿、预发布、
/// 缺 Windows x64 包的跳过，退到下一个较低的标签。
async fn latest_windows_release() -> Result<Option<serde_json::Value>, String> {
    let floor = parse_version(CURRENT_VERSION);
    let url = format!("https://api.github.com/repos/{GITHUB_REPO}/git/matching-refs/tags/{TAG_PREFIX}");
    let bytes = verified::small(verified::delivery_url(&url)?, 1024 * 1024).await?;
    let refs: serde_json::Value =
        serde_json::from_slice(&bytes).map_err(|_| "更新发布信息无效".to_owned())?;
    for tag in windows_tags(&refs) {
        if parse_version(tag) < floor {
            break;
        }
        let url = format!("https://api.github.com/repos/{GITHUB_REPO}/releases/tags/{tag}");
        let bytes = match verified::small(verified::delivery_url(&url)?, 1024 * 1024).await {
            Ok(bytes) => bytes,
            Err(error) if not_found(&error) => continue,
            Err(error) => return Err(error),
        };
        let release: serde_json::Value =
            serde_json::from_slice(&bytes).map_err(|_| "更新发布信息无效".to_owned())?;
        if release.get("tag_name").and_then(|t| t.as_str()) == Some(tag) && installable(&release) {
            return Ok(Some(release));
        }
    }
    Ok(None)
}

/// 检查 GitHub Releases 是否有新版本
#[tauri::command]
pub async fn check_for_updates() -> Result<UpdateInfo, String> {
    let current_ver = parse_version(CURRENT_VERSION);
    let best_release = latest_windows_release().await?;
    let best_release = best_release.as_ref();
    if let Ok(mut latest) = LATEST_TAG.lock() {
        *latest = best_release.and_then(|release| Some(release.get("tag_name")?.as_str()?.to_owned()));
    }
    let mut has_update = best_release
        .and_then(|release| release.get("tag_name")?.as_str())
        .is_some_and(|tag| parse_version(tag) > current_ver);

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

/// 检查更新找到过 Windows 发布就打开它的页面，否则按标题搜 Windows 发布。
/// 不用 releases/latest：那是服务器的发布，没有 Windows 安装包。
fn windows_release_page(tag: Option<&str>) -> String {
    match tag {
        Some(tag) => format!("https://github.com/{GITHUB_REPO}/releases/tag/{tag}"),
        None => format!("https://github.com/{GITHUB_REPO}/releases?q=%22MovieClaw+for+Windows%22&expanded=true"),
    }
}

fn open_windows_release_page() -> Result<bool, String> {
    let tag = LATEST_TAG.lock().ok().and_then(|tag| tag.clone());
    let url = windows_release_page(tag.as_deref());
    open::that(&url).map_err(|e| format!("打开浏览器失败: {e}"))?;
    Ok(true)
}

/// 在浏览器中打开下载页面
#[tauri::command]
pub fn open_download_page() -> Result<bool, String> {
    open_windows_release_page()
}

/// 打开最新 Windows 版本的 release 页面
#[tauri::command]
pub fn open_release_page() -> Result<bool, String> {
    open_windows_release_page()
}

fn truncate_notes(notes: &str) -> String {
    notes.chars().take(500).collect()
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn version_prefixes_and_unicode_notes_are_safe() {
        assert_eq!(parse_version("windows-v0.2.111"), (0, 2, 111));
        assert_eq!(parse_version("0.2.111"), (0, 2, 111));
        assert_eq!(truncate_notes(&"更".repeat(700)).chars().count(), 500);
        assert_eq!(truncate_notes("short"), "short");
    }

    #[test]
    fn discovery_only_considers_windows_tags_from_highest_version() {
        let refs = serde_json::json!(["windows-v0.2.9", "windows-v0.10.0", "windows-v0.2.10", "windows-v0.3.0-beta", "windows-v01.0.0"]
            .iter().map(|tag| serde_json::json!({"ref": format!("refs/tags/{tag}")}))
            .chain([serde_json::json!({"ref": "refs/heads/windows-v9.9.9"}), serde_json::json!({})])
            .collect::<Vec<_>>());
        assert_eq!(windows_tags(&refs), ["windows-v0.10.0", "windows-v0.2.10", "windows-v0.2.9"]);
        assert!(windows_tags(&serde_json::json!({"message": "Not Found"})).is_empty());
        assert!(not_found(r#"{"code":"UPDATE_NOT_FOUND","message":"x"}"#));
        assert!(!not_found(r#"{"code":"UPDATE_HTTP","message":"x"}"#));
    }

    #[test]
    fn release_page_points_at_windows_releases_not_the_server_latest() {
        assert_eq!(windows_release_page(Some("windows-v0.1.0")), format!("https://github.com/{GITHUB_REPO}/releases/tag/windows-v0.1.0"));
        assert!(windows_release_page(None).contains("/releases?q=%22MovieClaw+for+Windows%22"));
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
        let url = |name: &str| format!("https://github.com/{GITHUB_REPO}/releases/download/windows-v0.2.112/{name}");
        let installer = url("MovieClaw-Windows-0.2.112-Setup-x64.exe");
        let foreign = if GITHUB_REPO == "another/repository" { "other/repository" } else { "another/repository" };
        let release = serde_json::json!({"tag_name":"windows-v0.2.112", "assets": [
            {"name": "server-linux.zip", "browser_download_url": "https://example.test/linux"},
            {"name": "MovieClaw-Windows-0.2.112-portable-x64.zip", "browser_download_url": url("MovieClaw-Windows-0.2.112-portable-x64.zip")},
            {"name": "MovieClaw-Windows-0.2.112-Setup-x64.exe", "browser_download_url": installer}
        ]});
        assert_eq!(
            windows_download_url(&release),
            Some(installer.as_str())
        );
        assert!(installable(&serde_json::json!({"draft": false, "prerelease": false, "tag_name": release["tag_name"], "assets": release["assets"]})));
        for (draft, prerelease) in [(true, false), (false, true)] {
            assert!(!installable(&serde_json::json!({"draft": draft, "prerelease": prerelease, "tag_name": release["tag_name"], "assets": release["assets"]})));
        }
        assert_eq!(
            windows_download_url(&serde_json::json!({"assets": []})),
            None
        );
        let wrong_arch = serde_json::json!({"tag_name":"windows-v0.2.112", "assets": [
            {"name": "MovieClaw-Windows-0.2.112-Setup-arm64.exe", "browser_download_url": "https://example.test/arm"}
        ]});
        assert_eq!(windows_download_url(&wrong_arch), None);
        for (name, url) in [
            ("Another-App-Setup-x64.exe", url("Another-App-Setup-x64.exe")),
            ("MovieClaw-Windows-0.2.112-Setup-x64.exe", format!("https://github.com/{foreign}/releases/download/windows-v0.2.112/MovieClaw-Windows-0.2.112-Setup-x64.exe")),
            ("MovieClaw-Windows-0.2.111-Setup-x64.exe", url("MovieClaw-Windows-0.2.111-Setup-x64.exe")),
        ] {
            assert_eq!(windows_download_url(&serde_json::json!({"tag_name":"windows-v0.2.112", "assets":[{"name":name,"browser_download_url":url}]})), None);
        }
    }
}
