#[path = "src/release_repository.rs"]
mod release_repository;

fn main() {
    use std::process::Command;
    println!("cargo:rerun-if-env-changed=MOVIECLAW_RELEASE_REPOSITORY");
    let repository = std::env::var("MOVIECLAW_RELEASE_REPOSITORY")
        .unwrap_or_else(|_| "movieclaw/MovieClaw".into());
    assert!(release_repository::valid_repository(&repository), "MOVIECLAW_RELEASE_REPOSITORY must be a GitHub owner/repository");
    println!("cargo:rustc-env=MOVIECLAW_RELEASE_REPOSITORY={repository}");
    println!("cargo:rerun-if-env-changed=GITHUB_SHA");
    let git = |args: &[&str]| {
        Command::new("git").args(args).output().ok()
            .filter(|result| result.status.success())
            .and_then(|result| String::from_utf8(result.stdout).ok())
            .map(|value| value.trim().to_owned())
    };
    if let Some(path) = git(&["rev-parse", "--git-path", "HEAD"]) {
        println!("cargo:rerun-if-changed={path}");
    }
    if let Some(reference) = git(&["symbolic-ref", "-q", "HEAD"]) {
        if let Some(path) = git(&["rev-parse", "--git-path", &reference]) {
            println!("cargo:rerun-if-changed={path}");
        }
    }
    let revision = std::env::var("GITHUB_SHA").ok().or_else(|| git(&["rev-parse", "HEAD"]))
        .filter(|value| value.len() == 40 && value.bytes().all(|byte| byte.is_ascii_hexdigit()))
        .unwrap_or_else(|| "unknown".into());
    let timestamp = git(&["show", "-s", "--format=%ct", &revision])
        .and_then(|value| value.parse::<u64>().ok()).unwrap_or(0);
    println!("cargo:rustc-env=MOVIECLAW_BUILD_REVISION={revision}");
    println!("cargo:rustc-env=MOVIECLAW_BUILD_TIMESTAMP={timestamp}");
    tauri_build::build()
}
