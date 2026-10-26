//! Secrets remain in the current Windows user's local Credential Manager.
//! Account labels may be saved in JSON; tokens and installation identifiers may not.
#[cfg(not(windows))]
use std::sync::atomic::{AtomicU64, Ordering};

const PREFIX: &str = "MovieClaw.Windows/";

pub fn token_key(origin: &str, username: &str) -> String {
    format!("{PREFIX}token/{origin}#{}", username.to_lowercase())
}

pub fn read(key: &str) -> Result<Option<String>, String> {
    backend::read(key)
}

pub fn write(key: &str, value: &str) -> Result<(), String> {
    if !key.starts_with(PREFIX) || value.is_empty() || value.len() > 2560 {
        return Err("无效的原生凭证".into());
    }
    backend::write(key, value)
}

pub fn delete(key: &str) -> Result<(), String> {
    backend::delete(key)
}

// The legacy cookie bag may exceed Credential Manager's per-credential limit.
// DPAPI protects its disk representation using the same Windows user identity.
pub fn protect_disk(bytes: &[u8]) -> Result<Vec<u8>, String> {
    #[cfg(windows)]
    {
        let mut output = b"MC-DPAPI1\n".to_vec();
        output.extend(dpapi(bytes, true)?);
        Ok(output)
    }
    #[cfg(not(windows))]
    {
        Ok(bytes.to_vec())
    }
}

pub fn unprotect_disk(bytes: &[u8]) -> Result<Vec<u8>, String> {
    #[cfg(windows)]
    {
        if let Some(data) = bytes.strip_prefix(b"MC-DPAPI1\n") {
            dpapi(data, false)
        } else {
            Ok(bytes.to_vec())
        }
    }
    #[cfg(not(windows))]
    {
        Ok(bytes.to_vec())
    }
}

#[cfg(windows)]
fn dpapi(bytes: &[u8], protect: bool) -> Result<Vec<u8>, String> {
    use std::ffi::c_void;
    #[repr(C)]
    struct Blob {
        size: u32,
        data: *mut u8,
    }
    #[link(name = "crypt32")]
    extern "system" {
        fn CryptProtectData(
            input: *const Blob,
            description: *const u16,
            entropy: *const Blob,
            reserved: *mut c_void,
            prompt: *mut c_void,
            flags: u32,
            output: *mut Blob,
        ) -> i32;
        fn CryptUnprotectData(
            input: *const Blob,
            description: *mut *mut u16,
            entropy: *const Blob,
            reserved: *mut c_void,
            prompt: *mut c_void,
            flags: u32,
            output: *mut Blob,
        ) -> i32;
    }
    #[link(name = "kernel32")]
    extern "system" {
        fn LocalFree(memory: *mut c_void) -> *mut c_void;
    }
    if bytes.len() > u32::MAX as usize {
        return Err("凭证数据过大".into());
    }
    let input = Blob {
        size: bytes.len() as u32,
        data: bytes.as_ptr() as *mut u8,
    };
    let mut output = Blob {
        size: 0,
        data: std::ptr::null_mut(),
    };
    let success = unsafe {
        if protect {
            CryptProtectData(
                &input,
                std::ptr::null(),
                std::ptr::null(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                1,
                &mut output,
            )
        } else {
            CryptUnprotectData(
                &input,
                std::ptr::null_mut(),
                std::ptr::null(),
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                1,
                &mut output,
            )
        }
    };
    if success == 0 {
        return Err(format!(
            "Windows 凭证保护失败: {}",
            std::io::Error::last_os_error()
        ));
    }
    let data = unsafe { std::slice::from_raw_parts(output.data, output.size as usize).to_vec() };
    unsafe {
        LocalFree(output.data.cast());
    }
    Ok(data)
}

pub fn installation_id() -> Result<String, String> {
    let key = format!("{PREFIX}installation-id");
    if let Some(value) = read(&key)? {
        return Ok(value);
    }
    let id = format!("windows-{}", random_id()?);
    write(&key, &id)?;
    Ok(id)
}

pub fn random_id() -> Result<String, String> {
    #[cfg(windows)]
    {
        use std::ffi::c_void;
        #[link(name = "ole32")]
        extern "system" {
            fn CoCreateGuid(guid: *mut c_void) -> i32;
        }
        let mut bytes = [0u8; 16];
        if unsafe { CoCreateGuid(bytes.as_mut_ptr().cast()) } < 0 {
            return Err("无法生成随机标识".into());
        }
        Ok(bytes.iter().map(|v| format!("{v:02x}")).collect())
    }
    #[cfg(not(windows))]
    {
        // Non-Windows builds are compilation/test hosts, not a credential fallback.
        static NEXT: AtomicU64 = AtomicU64::new(1);
        Ok(format!(
            "test-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ))
    }
}

#[cfg(windows)]
mod backend {
    use std::ffi::c_void;
    #[repr(C)]
    struct Credential {
        flags: u32,
        kind: u32,
        target: *mut u16,
        comment: *mut u16,
        written: [u32; 2],
        blob_size: u32,
        blob: *mut u8,
        persist: u32,
        attribute_count: u32,
        attributes: *mut c_void,
        alias: *mut u16,
        username: *mut u16,
    }
    #[link(name = "advapi32")]
    extern "system" {
        fn CredReadW(
            target: *const u16,
            kind: u32,
            flags: u32,
            credential: *mut *mut Credential,
        ) -> i32;
        fn CredWriteW(credential: *const Credential, flags: u32) -> i32;
        fn CredDeleteW(target: *const u16, kind: u32, flags: u32) -> i32;
        fn CredFree(buffer: *mut c_void);
    }
    fn wide(value: &str) -> Vec<u16> {
        value.encode_utf16().chain(Some(0)).collect()
    }
    fn failure() -> String {
        format!(
            "Windows 凭证管理器不可用: {}",
            std::io::Error::last_os_error()
        )
    }
    pub fn read(key: &str) -> Result<Option<String>, String> {
        let name = wide(key);
        let mut credential = std::ptr::null_mut();
        if unsafe { CredReadW(name.as_ptr(), 1, 0, &mut credential) } == 0 {
            return if std::io::Error::last_os_error().raw_os_error() == Some(1168) {
                Ok(None)
            } else {
                Err(failure())
            };
        }
        let result = unsafe {
            let item = &*credential;
            if item.blob_size == 0 || item.blob_size > 2560 || item.blob.is_null() {
                Err("Windows 凭证数据无效".into())
            } else {
                String::from_utf8(
                    std::slice::from_raw_parts(item.blob, item.blob_size as usize).to_vec(),
                )
                .map(Some)
                .map_err(|_| "Windows 凭证编码无效".into())
            }
        };
        unsafe { CredFree(credential.cast()) };
        result
    }
    pub fn write(key: &str, value: &str) -> Result<(), String> {
        let mut target = wide(key);
        let mut username = wide("MovieClaw");
        let item = Credential {
            flags: 0,
            kind: 1,
            target: target.as_mut_ptr(),
            comment: std::ptr::null_mut(),
            written: [0; 2],
            blob_size: value.len() as u32,
            blob: value.as_ptr() as *mut u8,
            persist: 2,
            attribute_count: 0,
            attributes: std::ptr::null_mut(),
            alias: std::ptr::null_mut(),
            username: username.as_mut_ptr(),
        };
        if unsafe { CredWriteW(&item, 0) } == 0 {
            Err(failure())
        } else {
            Ok(())
        }
    }
    pub fn delete(key: &str) -> Result<(), String> {
        let name = wide(key);
        if unsafe { CredDeleteW(name.as_ptr(), 1, 0) } == 0
            && std::io::Error::last_os_error().raw_os_error() != Some(1168)
        {
            Err(failure())
        } else {
            Ok(())
        }
    }
}

#[cfg(not(windows))]
mod backend {
    #[cfg(test)]
    use std::{
        collections::HashMap,
        sync::{LazyLock, Mutex},
    };
    #[cfg(test)]
    static VALUES: LazyLock<Mutex<HashMap<String, String>>> =
        LazyLock::new(|| Mutex::new(HashMap::new()));
    pub fn read(key: &str) -> Result<Option<String>, String> {
        #[cfg(test)]
        {
            return Ok(VALUES.lock().unwrap().get(key).cloned());
        }
        #[cfg(not(test))]
        {
            let _ = key;
            Err("原生凭证仅支持 Windows".into())
        }
    }
    pub fn write(key: &str, value: &str) -> Result<(), String> {
        #[cfg(test)]
        {
            VALUES
                .lock()
                .unwrap()
                .insert(key.to_owned(), value.to_owned());
            return Ok(());
        }
        #[cfg(not(test))]
        {
            let _ = (key, value);
            Err("原生凭证仅支持 Windows".into())
        }
    }
    pub fn delete(key: &str) -> Result<(), String> {
        #[cfg(test)]
        {
            VALUES.lock().unwrap().remove(key);
            return Ok(());
        }
        #[cfg(not(test))]
        {
            let _ = key;
            Err("原生凭证仅支持 Windows".into())
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn credential_manager_roundtrip_is_origin_and_account_scoped() {
        let user = format!("ci-{}", random_id().unwrap());
        let a = token_key("https://server:444", &user);
        let b = token_key("https://server:445", &user);
        assert_ne!(a, b);
        write(&a, "roundtrip-test-token").unwrap();
        assert_eq!(read(&a).unwrap().as_deref(), Some("roundtrip-test-token"));
        assert_eq!(read(&b).unwrap(), None);
        delete(&a).unwrap();
        assert_eq!(read(&a).unwrap(), None);
    }
    #[cfg(windows)]
    #[test]
    fn legacy_cookie_disk_storage_is_dpapi_encrypted() {
        let plain = br#"{"session":"test-secret"}"#;
        let protected = protect_disk(plain).unwrap();
        assert!(!protected
            .windows(b"test-secret".len())
            .any(|v| v == b"test-secret"));
        assert_eq!(unprotect_disk(&protected).unwrap(), plain);
    }
}
