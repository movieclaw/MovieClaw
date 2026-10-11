pub fn valid_repository(value: &str) -> bool {
    let Some((owner, repo)) = value.split_once('/') else { return false; };
    !owner.is_empty() && owner.len() <= 39 && !owner.starts_with('-') && !owner.ends_with('-')
        && owner.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
        && !repo.is_empty() && repo.len() <= 100 && repo != "." && repo != ".."
        && repo.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'-' | b'_' | b'.'))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn release_channel_accepts_explicit_github_owner_and_repository() {
        for value in ["movieclaw/MovieClaw", "community-owner/MovieClaw-Windows", "owner/repo_name.git"] {
            assert!(valid_repository(value), "{value}");
        }
        for value in ["", "MovieClaw", "/repo", "owner/", "-owner/repo", "owner-/repo",
            "owner/../repo", "owner/..", "owner/.", "owner/repo?token=x", "https://github.com/owner/repo", "owner/repo\n"] {
            assert!(!valid_repository(value), "{value}");
        }
    }
}
