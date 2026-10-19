//! Same UDP 7359 discovery contract as the Mac client (docs/design/lan-discovery.md).
//! Each target is asked twice: MovieClaw's own query (a list of addresses) and
//! the Jellyfin one (older servers only answer that). Advertisements are only
//! candidates; an unauthenticated MovieClaw health response must validate them.
use serde_json::{json, Value};
use std::{
    collections::HashSet,
    net::{Ipv4Addr, SocketAddr, UdpSocket},
    time::{Duration, Instant},
};

const PORT: u16 = 7359;
const QUERIES: [&[u8]; 2] = [b"who is MovieClawServer?", b"who is JellyfinServer?"];

fn candidates(bytes: &[u8], sender: SocketAddr) -> Vec<(String, String)> {
    let Ok(value) = serde_json::from_slice::<Value>(bytes) else {
        return vec![];
    };
    let native = value["type"] == "movieclaw.discovery";
    let advertised: Vec<&str> = if native {
        value["addresses"]
            .as_array()
            .map(|list| list.iter().filter_map(Value::as_str).collect())
            .unwrap_or_default()
    } else {
        match value["Address"]
            .as_str()
            .or_else(|| value["EndpointAddress"].as_str())
        {
            Some(address) => vec![address],
            None => return vec![],
        }
    };
    let name = value[if native { "name" } else { "Name" }]
        .as_str()
        .filter(|v| !v.is_empty())
        .unwrap_or("MovieClaw")
        .chars()
        .take(128)
        .collect::<String>();
    let parsed: Vec<_> = advertised
        .iter()
        .take(8)
        .filter_map(|v| crate::connect::validate_http_url(v).ok())
        .collect();
    let mut targets: Vec<(String, String)> = Vec::new();
    let mut push = |url: String| {
        if !targets.iter().any(|(target, _)| target == &url) {
            targets.push((url, name.clone()));
        }
    };
    for url in &parsed {
        push(url.as_str().trim_end_matches('/').to_owned());
    }
    let ip = if sender.is_ipv6() {
        format!("[{}]", sender.ip())
    } else {
        sender.ip().to_string()
    };
    for port in parsed.iter().filter_map(|v| v.port()).chain([3000]) {
        push(format!("http://{ip}:{port}"));
    }
    targets
}

#[cfg(windows)]
fn interfaces() -> Vec<(Ipv4Addr, u8)> {
    use windows::Win32::{
        NetworkManagement::{
            IpHelper::{
                GetAdaptersAddresses, GET_ADAPTERS_ADDRESSES_FLAGS, IP_ADAPTER_ADDRESSES_LH,
            },
            Ndis::IfOperStatusUp,
        },
        Networking::WinSock::{AF_INET, SOCKADDR_IN},
    };
    let mut size = 15 * 1024u32;
    for _ in 0..3 {
        // u64 allocation supplies the alignment required by native pointer fields.
        let mut storage = vec![0u64; (size as usize + 7) / 8];
        let first = storage.as_mut_ptr().cast::<IP_ADAPTER_ADDRESSES_LH>();
        let result = unsafe {
            GetAdaptersAddresses(
                AF_INET.0 as u32,
                GET_ADAPTERS_ADDRESSES_FLAGS(0),
                None,
                Some(first),
                &mut size,
            )
        };
        if result == 111 && size <= 1024 * 1024 {
            continue;
        }
        if result != 0 {
            return vec![];
        }
        let mut found = Vec::new();
        let mut adapter = first;
        unsafe {
            while !adapter.is_null() {
                if (*adapter).OperStatus == IfOperStatusUp {
                    let mut address = (*adapter).FirstUnicastAddress;
                    while !address.is_null() {
                        let socket = (*address).Address;
                        if !socket.lpSockaddr.is_null()
                            && socket.iSockaddrLength >= std::mem::size_of::<SOCKADDR_IN>() as i32
                            && (*socket.lpSockaddr).sa_family == AF_INET
                        {
                            let addr = &*(socket.lpSockaddr.cast::<SOCKADDR_IN>());
                            let parts = addr.sin_addr.S_un.S_un_b;
                            let ip = Ipv4Addr::new(parts.s_b1, parts.s_b2, parts.s_b3, parts.s_b4);
                            if ip.is_private() {
                                found.push((ip, (*address).OnLinkPrefixLength));
                            }
                        }
                        address = (*address).Next;
                    }
                }
                adapter = (*adapter).Next;
            }
        }
        found.sort();
        found.dedup();
        return found;
    }
    vec![]
}
#[cfg(not(windows))]
fn interfaces() -> Vec<(Ipv4Addr, u8)> {
    vec![]
}
fn targets(interfaces: &[(Ipv4Addr, u8)]) -> Vec<SocketAddr> {
    let mut found = HashSet::from([SocketAddr::from((Ipv4Addr::BROADCAST, PORT))]);
    for (ip, prefix) in interfaces {
        if !ip.is_private() || *prefix > 30 {
            continue;
        }
        let prefix = (*prefix).max(24);
        let mask = u32::MAX << (32 - prefix);
        let network = u32::from(*ip) & mask;
        let broadcast = network | !mask;
        found.insert(SocketAddr::from((Ipv4Addr::from(broadcast), PORT)));
        for host in network + 1..broadcast {
            if found.len() >= 1024 {
                break;
            }
            found.insert(SocketAddr::from((Ipv4Addr::from(host), PORT)));
        }
        if found.len() >= 1024 {
            break;
        }
    }
    found.into_iter().collect()
}
fn receive() -> Result<Vec<(String, String)>, String> {
    let socket = UdpSocket::bind("0.0.0.0:0")
        .map_err(|_| "无法使用局域网发现，请检查防火墙权限或手动输入服务器地址")?;
    socket
        .set_broadcast(true)
        .map_err(|_| "无法发送局域网发现，请手动输入服务器地址")?;
    socket
        .set_read_timeout(Some(Duration::from_millis(100)))
        .map_err(|_| "无法配置局域网发现")?;
    let targets = targets(&interfaces());
    let mut found = Vec::new();
    let mut buffer = [0u8; 8192];
    for _ in 0..2 {
        for (i, target) in targets.iter().enumerate() {
            for query in QUERIES {
                let _ = socket.send_to(query, target);
            }
            if i % 16 == 15 {
                std::thread::sleep(Duration::from_millis(2));
            }
        }
        let deadline = Instant::now() + Duration::from_millis(1200);
        while Instant::now() < deadline && found.len() < 32 {
            if let Ok((size, sender)) = socket.recv_from(&mut buffer) {
                for target in candidates(&buffer[..size], sender) {
                    if !found.contains(&target) {
                        found.push(target);
                    }
                }
            }
        }
    }
    Ok(found)
}
#[tauri::command]
pub async fn discover_servers() -> Result<Vec<Value>, String> {
    let generation = crate::native_auth::generation();
    let advertised = tauri::async_runtime::spawn_blocking(receive)
        .await
        .map_err(|_| "局域网发现任务中断")??;
    let client = reqwest::Client::builder()
        .redirect(reqwest::redirect::Policy::none())
        .timeout(Duration::from_millis(2500))
        .build()
        .map_err(|_| "无法配置服务器检测")?;
    let mut tasks = tokio::task::JoinSet::new();
    let permits = std::sync::Arc::new(tokio::sync::Semaphore::new(8));
    for (order, (url, name)) in advertised.into_iter().enumerate() {
        let client = client.clone();
        let permits = permits.clone();
        tasks.spawn(async move {
        let _permit=permits.acquire_owned().await.ok()?;
        let mut response=client.get(format!("{url}/api/v1/health")).send().await.ok()?;
        if !response.status().is_success() {return None;}
        let mut bytes=Vec::new();
        while let Some(chunk)=response.chunk().await.ok()? { if bytes.len()+chunk.len()>16*1024 {return None;} bytes.extend_from_slice(&chunk); }
        let health:Value=serde_json::from_slice(&bytes).ok()?;
        if health["status"]!="ok" {return None;}
        let instance=health.get("instance_id").and_then(Value::as_str).unwrap_or_default().to_owned();
        Some((order, instance, json!({"name":name,"url":url,"version":health.get("version").cloned().unwrap_or(Value::Null)})))
    });
    }
    let mut passed = Vec::new();
    while let Some(result) = tasks.join_next().await {
        if generation != crate::native_auth::generation() {
            tasks.abort_all();
            return Ok(vec![]);
        }
        if let Ok(Some(value)) = result {
            passed.push(value);
        }
    }
    // One row per server: the same instance often answers on several candidates
    // (LAN address and public domain); keep its most trusted one.
    passed.sort_by_key(|(order, _, _)| *order);
    let mut found: Vec<Value> = Vec::new();
    let mut instances = HashSet::new();
    for (_, instance, value) in passed {
        if !instance.is_empty() && !instances.insert(instance) {
            continue;
        }
        if !found.iter().any(|v| v["url"] == value["url"]) {
            found.push(value);
        }
    }
    found.sort_by(|a, b| a["url"].as_str().cmp(&b["url"].as_str()));
    Ok(found)
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn discovery_uses_movieclaw_health_after_jellyfin_compatible_advertisement() {
        let sender = "192.168.1.25:7359".parse().unwrap();
        let values = candidates(
            br#"{"Address":"http://old-name:3010","Name":"NAS"}"#,
            sender,
        );
        assert_eq!(
            values.iter().map(|v| v.0.as_str()).collect::<Vec<_>>(),
            vec![
                "http://old-name:3010",
                "http://192.168.1.25:3010",
                "http://192.168.1.25:3000"
            ]
        );
        assert_eq!(
            candidates(b"MOVIECLAW_SERVER_V1|NAS|0.1|3000", sender),
            vec![]
        );
        assert_eq!(candidates(br#"{"Name":"NAS"}"#, sender), vec![]);
    }
    #[test]
    fn native_reply_lists_addresses_then_sender_ports() {
        let sender = "192.168.1.25:7359".parse().unwrap();
        let values = candidates(
            br#"{"type":"movieclaw.discovery","version":1,"name":"NAS","addresses":["http://10.0.0.5:3300","https://m.example.com",7]}"#,
            sender,
        );
        assert_eq!(
            values.iter().map(|v| v.0.as_str()).collect::<Vec<_>>(),
            vec![
                "http://10.0.0.5:3300",
                "https://m.example.com",
                "http://192.168.1.25:3300",
                "http://192.168.1.25:3000"
            ]
        );
        assert!(values.iter().all(|v| v.1 == "NAS"));
        // Bridge deployment that has not learned the host address yet
        let empty = candidates(br#"{"type":"movieclaw.discovery","addresses":[]}"#, sender);
        assert_eq!(empty, vec![("http://192.168.1.25:3000".to_owned(), "MovieClaw".to_owned())]);
    }
    #[test]
    fn subnet_probe_is_private_and_bounded() {
        let hosts = targets(&[
            (Ipv4Addr::new(10, 1, 2, 3), 16),
            (Ipv4Addr::new(192, 168, 1, 2), 24),
            (Ipv4Addr::new(172, 16, 1, 2), 24),
            (Ipv4Addr::new(10, 4, 1, 2), 24),
            (Ipv4Addr::new(10, 5, 1, 2), 24),
        ]);
        assert!(hosts.len() <= 1024);
        assert!(hosts.contains(&SocketAddr::from((Ipv4Addr::BROADCAST, 7359))));
        assert!(hosts.iter().all(|v| v.ip().is_ipv4()));
    }
}
