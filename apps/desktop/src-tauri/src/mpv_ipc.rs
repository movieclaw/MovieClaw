//! One cancellable named-pipe connection per mpv instance. Properties and commands
//! share the actor; a timed-out read never leaves an OS thread or pipe behind.
use serde_json::{json, Map, Value};
#[cfg(windows)]
use std::collections::HashMap;
#[cfg(windows)]
use std::io;
use std::sync::{Arc, Mutex};
use std::time::Duration;
#[cfg(windows)]
use tauri::Emitter;
#[cfg(windows)]
use tokio::net::windows::named_pipe::{ClientOptions, NamedPipeClient};
use tokio::sync::{mpsc, oneshot};
#[cfg(windows)]
use tokio::time::timeout;
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;

const PROPERTIES: &[&str] = &[
    "time-pos",
    "duration",
    "pause",
    "volume",
    "mute",
    "speed",
    "panscan",
    "aid",
    "sid",
    "sub-delay",
    "track-list",
    "chapter-list",
    "demuxer-cache-duration",
    "cache-speed",
    "paused-for-cache",
    "eof-reached",
    "seeking",
    "video-out-params",
    "video-target-params",
    "video-params",
    "hwdec-current",
    "hwdec",
    "video-codec",
    "frame-drop-count",
    "decoder-frame-drop-count",
    "container-fps",
    "sub-pos",
    "sub-scale",
];
const COMMAND_TIMEOUT: Duration = Duration::from_secs(3);
type Reply = oneshot::Sender<Result<Value, String>>;
#[cfg_attr(not(windows), allow(dead_code))]
struct Command {
    value: Vec<Value>,
    deadline: Instant,
    reply: Reply,
}

#[derive(Clone)]
pub struct Session {
    tx: mpsc::Sender<Command>,
    cancel: CancellationToken,
    state: Arc<Mutex<Map<String, Value>>>,
}

impl Session {
    pub fn start(pipe: String, instance: u64, app: Option<tauri::AppHandle>) -> Self {
        let (tx, rx) = mpsc::channel(64);
        let cancel = CancellationToken::new();
        let state = Arc::new(Mutex::new(Map::from_iter([
            ("ipc_connected".into(), json!(false)),
            ("ipc_connections".into(), json!(0)),
        ])));
        let session = Self {
            tx,
            cancel: cancel.clone(),
            state: state.clone(),
        };
        #[cfg(windows)]
        tauri::async_runtime::spawn(async move {
            let result = run(pipe, instance, app, rx, cancel, state.clone()).await;
            let mut data = state.lock().unwrap();
            data.insert("ipc_connected".into(), json!(false));
            if let Err(error) = result {
                data.insert("ipc_error".into(), json!(error));
            }
        });
        #[cfg(not(windows))]
        {
            let _ = (pipe, instance, app, rx);
            state.lock().unwrap().insert(
                "ipc_error".into(),
                json!("mpv named-pipe IPC requires Windows"),
            );
        }
        session
    }

    pub fn snapshot(&self) -> Value {
        Value::Object(self.state.lock().unwrap().clone())
    }
    pub fn stop(&self) {
        self.cancel.cancel();
    }

    pub async fn command(&self, value: Vec<Value>) -> Result<Value, String> {
        if value.is_empty()
            || value.len() > 16
            || serde_json::to_vec(&value).map_err(|e| e.to_string())?.len() > 65536
        {
            return Err("无效的 mpv 命令".into());
        }
        let operation = value[0].as_str().unwrap_or_default();
        let property = value.get(1).and_then(Value::as_str).unwrap_or_default();
        let allowed = match operation {
            "get_property" => value.len() == 2 && PROPERTIES.contains(&property),
            "set_property" => {
                value.len() == 3
                    && [
                        "pause",
                        "volume",
                        "mute",
                        "speed",
                        "panscan",
                        "aid",
                        "sid",
                        "sub-delay",
                        "sub-pos",
                        "sub-scale",
                    ]
                    .contains(&property)
            }
            "seek" => (3..=4).contains(&value.len()) && value[1].is_number(),
            _ => false,
        };
        if !allowed {
            return Err("播放器命令不在允许范围内".into());
        }
        let (reply, response) = oneshot::channel();
        let deadline = Instant::now() + COMMAND_TIMEOUT;
        self.tx
            .try_send(Command {
                value,
                deadline,
                reply,
            })
            .map_err(|_| "mpv 命令队列已满或已关闭")?;
        tokio::select! {
            _ = self.cancel.cancelled() => Err("播放请求已取消".into()),
            result = tokio::time::timeout_at(deadline, response) =>
                result.map_err(|_| "mpv IPC 超时".to_string())?.map_err(|_| "mpv IPC 已关闭".to_string())?,
        }
    }
}

#[cfg(windows)]
async fn write(
    pipe: &NamedPipeClient,
    value: Value,
    cancel: &CancellationToken,
) -> Result<(), String> {
    let mut bytes = serde_json::to_vec(&value).map_err(|e| e.to_string())?;
    bytes.push(b'\n');
    let operation = async {
        let mut offset = 0;
        while offset < bytes.len() {
            pipe.writable().await.map_err(|e| e.to_string())?;
            match pipe.try_write(&bytes[offset..]) {
                Ok(0) => return Err("mpv IPC 写入已关闭".into()),
                Ok(n) => offset += n,
                Err(error) if error.kind() == io::ErrorKind::WouldBlock => continue,
                Err(error) => return Err(format!("写 mpv IPC 失败: {error}")),
            }
        }
        Ok(())
    };
    tokio::select! {
        _ = cancel.cancelled() => Err("播放请求已取消".into()),
        result = timeout(COMMAND_TIMEOUT, operation) => result.map_err(|_| "mpv IPC 写入超时".to_string())?,
    }
}

#[cfg(windows)]
async fn run(
    name: String,
    instance: u64,
    app: Option<tauri::AppHandle>,
    mut rx: mpsc::Receiver<Command>,
    cancel: CancellationToken,
    state: Arc<Mutex<Map<String, Value>>>,
) -> Result<(), String> {
    let connect = async {
        loop {
            match ClientOptions::new().open(&name) {
                Ok(pipe) => return Ok(pipe),
                Err(error) if matches!(error.raw_os_error(), Some(2 | 231)) => {
                    tokio::time::sleep(Duration::from_millis(25)).await
                }
                Err(error) => return Err(format!("连接 mpv IPC 失败: {error}")),
            }
        }
    };
    let pipe = tokio::select! {
        _ = cancel.cancelled() => return Ok(()),
        result = timeout(Duration::from_secs(10), connect) => result.map_err(|_| "mpv IPC 连接超时")??,
    };
    {
        let mut data = state.lock().unwrap();
        data.insert("ipc_connected".into(), json!(true));
        data.insert("ipc_connections".into(), json!(1));
    }
    for (id, property) in PROPERTIES.iter().enumerate() {
        write(
            &pipe,
            json!({ "command": ["observe_property", id + 1, property] }),
            &cancel,
        )
        .await?;
    }
    let mut next_id = 100u64;
    let mut pending: HashMap<u64, (Instant, Reply)> = HashMap::new();
    let mut incoming = Vec::new();
    let mut expiry = tokio::time::interval(Duration::from_millis(50));
    loop {
        tokio::select! {
            biased;
            _ = cancel.cancelled() => break,
            _ = expiry.tick() => {
                let now = Instant::now();
                let expired: Vec<_> = pending.iter().filter(|(_, (deadline, reply))| reply.is_closed() || *deadline <= now).map(|(id, _)| *id).collect();
                for id in expired {
                    if let Some((_, reply)) = pending.remove(&id) { let _ = reply.send(Err("mpv IPC 超时".into())); }
                }
            }
            command = rx.recv(), if pending.len() < 64 => {
                let Some(command) = command else { break };
                if command.reply.is_closed() || command.deadline <= Instant::now() { continue; }
                next_id += 1;
                write(&pipe, json!({ "command": command.value, "request_id": next_id }), &cancel).await?;
                pending.insert(next_id, (command.deadline, command.reply));
            }
            ready = pipe.readable() => {
                ready.map_err(|e| e.to_string())?;
                let mut bytes = [0u8; 16384];
                match pipe.try_read(&mut bytes) {
                    Ok(0) => return Err("mpv IPC 已关闭".into()),
                    Ok(n) => incoming.extend_from_slice(&bytes[..n]),
                    Err(error) if error.kind() == io::ErrorKind::WouldBlock => continue,
                    Err(error) => return Err(format!("读 mpv IPC 失败: {error}")),
                }
                if incoming.len() > 1024 * 1024 { return Err("mpv IPC 响应超过大小限制".into()); }
                while let Some(end) = incoming.iter().position(|byte| *byte == b'\n') {
                    let line: Vec<_> = incoming.drain(..=end).collect();
                    let Ok(value) = serde_json::from_slice::<Value>(&line) else { continue };
                    if let Some(id) = value["request_id"].as_u64() {
                        if let Some((_, reply)) = pending.remove(&id) {
                            let result = if value["error"].as_str().is_some_and(|e| e != "success") {
                                Err(format!("mpv 命令失败: {}", value["error"]))
                            } else { Ok(value) };
                            let _ = reply.send(result);
                        }
                        continue;
                    }
                    if value["event"] == "property-change" {
                        if let Some(name) = value["name"].as_str() {
                            state.lock().unwrap().insert(name.into(), value["data"].clone());
                        }
                    } else if value["event"] == "end-file" {
                        state.lock().unwrap().insert("end_file".into(), value);
                    } else if value["event"] == "client-message" && value["args"][0] == "movieclaw-input" {
                        {
                            let mut data = state.lock().unwrap();
                            let count = data.get("input_events").and_then(Value::as_u64).unwrap_or(0);
                            data.insert("input_events".into(), json!(count.saturating_add(1)));
                        }
                        if let Some(app) = &app {
                            let _ = app.emit("movieclaw:player-input", json!({ "instanceId": instance, "args": value["args"] }));
                        }
                    }
                }
            }
        }
    }
    // Dropping NamedPipeClient cancels the registered overlapped I/O and closes the
    // only pipe handle. Pending oneshots fail; no read thread outlives the session.
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn stopped_session_cancels_connect_and_rejects_commands() {
        let session = Session::start(
            format!(r"\\.\pipe\movieclaw-missing-{}", std::process::id()),
            1,
            None,
        );
        session.stop();
        assert!(session
            .command(vec![json!("get_property"), json!("pause")])
            .await
            .is_err());
        tokio::time::sleep(Duration::from_millis(50)).await;
        assert_eq!(session.snapshot()["ipc_connections"], 0);
    }
    #[tokio::test]
    async fn rejects_process_and_file_access_commands() {
        let session = Session::start(
            format!(r"\\.\pipe\movieclaw-denied-{}", std::process::id()),
            2,
            None,
        );
        for command in [
            vec![json!("run"), json!("powershell")],
            vec![json!("loadfile"), json!("http://example.invalid")],
            vec![
                json!("set_property"),
                json!("input-ipc-server"),
                json!("bad"),
            ],
        ] {
            assert!(session
                .command(command)
                .await
                .unwrap_err()
                .contains("允许范围"));
        }
        session.stop();
    }

    #[cfg(windows)]
    fn test_pipe() -> String {
        use std::sync::atomic::{AtomicU32, Ordering};
        static ID: AtomicU32 = AtomicU32::new(0);
        format!(
            r"\\.\pipe\movieclaw-actor-test-{}-{}",
            std::process::id(),
            ID.fetch_add(1, Ordering::SeqCst)
        )
    }

    #[cfg(windows)]
    #[tokio::test]
    async fn persistent_connection_demultiplexes_properties_commands_and_cancels_handle() {
        use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
        use tokio::net::windows::named_pipe::ServerOptions;
        let name = test_pipe();
        let server = ServerOptions::new()
            .first_pipe_instance(true)
            .create(&name)
            .unwrap();
        let server_task = tokio::spawn(async move {
            server.connect().await.unwrap();
            let mut stream = BufReader::new(server);
            let mut line = String::new();
            let mut commands = 0;
            loop {
                line.clear();
                if stream.read_line(&mut line).await.unwrap() == 0 {
                    break;
                }
                let value: Value = serde_json::from_str(&line).unwrap();
                if let Some(id) = value["request_id"].as_u64() {
                    commands += 1;
                    // Events and command replies interleave and cross read boundaries.
                    let output = format!("{{\"event\":\"property-change\",\"name\":\"pause\",\"data\":false}}\n{{\"request_id\":{id},\"error\":\"success\",\"data\":true}}\n");
                    let middle = output.len() / 2;
                    stream
                        .get_mut()
                        .write_all(&output.as_bytes()[..middle])
                        .await
                        .unwrap();
                    stream
                        .get_mut()
                        .write_all(&output.as_bytes()[middle..])
                        .await
                        .unwrap();
                }
            }
            commands
        });
        let session = Session::start(name, 3, None);
        let mut jobs = Vec::new();
        for _ in 0..8 {
            let clone = session.clone();
            jobs.push(tokio::spawn(async move {
                clone
                    .command(vec![json!("get_property"), json!("pause")])
                    .await
            }));
        }
        for job in jobs {
            assert_eq!(job.await.unwrap().unwrap()["data"], true);
        }
        assert_eq!(session.snapshot()["ipc_connections"], 1);
        assert_eq!(session.snapshot()["pause"], false);
        session.stop();
        assert_eq!(
            timeout(Duration::from_secs(2), server_task)
                .await
                .unwrap()
                .unwrap(),
            8
        );
    }

    #[cfg(windows)]
    #[tokio::test]
    async fn deadline_does_not_spawn_an_orphan_read_and_stop_closes_the_connection() {
        use tokio::io::{AsyncBufReadExt, BufReader};
        use tokio::net::windows::named_pipe::ServerOptions;
        let name = test_pipe();
        let server = ServerOptions::new()
            .first_pipe_instance(true)
            .create(&name)
            .unwrap();
        let server_task = tokio::spawn(async move {
            server.connect().await.unwrap();
            let mut stream = BufReader::new(server);
            let mut line = String::new();
            loop {
                line.clear();
                if stream.read_line(&mut line).await.unwrap() == 0 {
                    break;
                }
            }
        });
        let session = Session::start(name, 4, None);
        let error = session
            .command(vec![json!("get_property"), json!("pause")])
            .await
            .unwrap_err();
        assert!(error.contains("超时"));
        assert_eq!(session.snapshot()["ipc_connections"], 1);
        assert_eq!(session.snapshot()["ipc_connected"], true);
        session.stop();
        timeout(Duration::from_secs(2), server_task)
            .await
            .unwrap()
            .unwrap();
    }
    /// Exercises the production actor against the pinned Windows runtime. Missing
    /// runtime is a CI setup failure; this test must never silently skip there.
    #[cfg(windows)]
    #[tokio::test]
    async fn real_mpv_session_observes_tracks_controls_input_seek_and_releases_pipe() {
        use std::path::{Path, PathBuf};
        use std::process::{Child, Command as Process, Stdio};
        struct Fixture {
            child: Child,
            dir: PathBuf,
        }
        impl Drop for Fixture {
            fn drop(&mut self) {
                let _ = self.child.kill();
                let _ = self.child.wait();
                let _ = std::fs::remove_dir_all(&self.dir);
            }
        }
        fn wav(path: &Path, hz: f64) {
            let samples = 8000u32 * 8;
            let size = samples * 2;
            let mut bytes = Vec::with_capacity((size + 44) as usize);
            bytes.extend_from_slice(b"RIFF");
            bytes.extend_from_slice(&(size + 36).to_le_bytes());
            bytes.extend_from_slice(b"WAVEfmt ");
            bytes.extend_from_slice(&16u32.to_le_bytes());
            bytes.extend_from_slice(&1u16.to_le_bytes());
            bytes.extend_from_slice(&1u16.to_le_bytes());
            bytes.extend_from_slice(&8000u32.to_le_bytes());
            bytes.extend_from_slice(&16000u32.to_le_bytes());
            bytes.extend_from_slice(&2u16.to_le_bytes());
            bytes.extend_from_slice(&16u16.to_le_bytes());
            bytes.extend_from_slice(b"data");
            bytes.extend_from_slice(&size.to_le_bytes());
            for n in 0..samples {
                let value =
                    ((n as f64 * hz * std::f64::consts::TAU / 8000.0).sin() * 4000.0) as i16;
                bytes.extend_from_slice(&value.to_le_bytes());
            }
            std::fs::write(path, bytes).unwrap();
        }
        fn video(path: &Path) {
            use std::io::Write;
            // A local Y4M file has a real byte-seekable timeline. A lavfi source
            // cannot prove that a backward seek reached the requested position.
            let mut file = std::fs::File::create(path).unwrap();
            file.write_all(b"YUV4MPEG2 W320 H180 F24:1 Ip A1:1 C420jpeg\n")
                .unwrap();
            let mut frame = vec![76u8; 320 * 180];
            frame.extend(vec![85u8; 320 * 180 / 4]);
            frame.extend(vec![255u8; 320 * 180 / 4]);
            for _ in 0..24 * 8 {
                file.write_all(b"FRAME\n").unwrap();
                file.write_all(&frame).unwrap();
            }
        }
        async fn raw(session: &Session, value: Vec<Value>) -> Value {
            // Test-only commands reach the same actor; production allowlist stays
            // closed to file/process access, including audio-add and quit.
            let (reply, response) = oneshot::channel();
            let deadline = Instant::now() + COMMAND_TIMEOUT;
            session
                .tx
                .send(Command {
                    value,
                    deadline,
                    reply,
                })
                .await
                .unwrap();
            tokio::time::timeout_at(deadline, response)
                .await
                .unwrap()
                .unwrap()
                .unwrap()
        }
        async fn wait_state(
            session: &Session,
            stage: &str,
            predicate: impl Fn(&Value) -> bool,
        ) -> Value {
            let deadline = Instant::now() + Duration::from_secs(10);
            loop {
                let snapshot = session.snapshot();
                if predicate(&snapshot) {
                    return snapshot;
                }
                assert!(
                    Instant::now() < deadline,
                    "mpv observed state deadline ({stage}): {snapshot}"
                );
                tokio::time::sleep(Duration::from_millis(25)).await;
            }
        }
        let runtime = PathBuf::from(
            std::env::var_os("MOVIECLAW_MPV_RUNTIME")
                .expect("Windows real IPC test needs MOVIECLAW_MPV_RUNTIME"),
        );
        let exe = if runtime.is_dir() {
            runtime.join("mpv.exe")
        } else {
            runtime
        };
        assert!(exe.is_file(), "pinned mpv.exe missing");
        let pipe = test_pipe();
        let dir = std::env::temp_dir().join(format!(
            "movieclaw-real-ipc-{}-{}",
            std::process::id(),
            pipe.rsplit('-').next().unwrap()
        ));
        std::fs::create_dir_all(&dir).unwrap();
        let a = dir.join("one.wav");
        let b = dir.join("two.wav");
        let c = dir.join("three.wav");
        wav(&a, 440.0);
        wav(&b, 550.0);
        wav(&c, 660.0);
        let movie = dir.join("movie.y4m");
        video(&movie);
        let sub = dir.join("caption.srt");
        std::fs::write(
            &sub,
            "1\n00:00:00,000 --> 00:00:08,000\nSynthetic caption\n",
        )
        .unwrap();
        let child = Process::new(exe)
            .args([
                "--no-config",
                "--vo=null",
                "--ao=null",
                "--pause=yes",
                "--idle=yes",
                "--keep-open=yes",
                "--hwdec=no",
                "--no-terminal",
            ])
            .arg(format!("--input-ipc-server={pipe}"))
            .arg(format!("--audio-file={}", a.display()))
            .arg(format!("--audio-file={}", b.display()))
            .arg(format!("--sub-file={}", sub.display()))
            .arg(&movie)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let mut fixture = Fixture { child, dir };
        let session = Session::start(pipe, 10, None);
        let state = wait_state(&session, "initial tracks", |s| {
            s["track-list"].as_array().is_some_and(|tracks| {
                tracks.iter().filter(|t| t["type"] == "audio").count() == 2
                    && tracks.iter().any(|t| t["type"] == "sub")
            })
        })
        .await;
        assert_eq!(state["ipc_connections"], 1);
        let audio: Vec<_> = state["track-list"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|t| t["type"] == "audio")
            .map(|t| t["id"].as_i64().unwrap())
            .collect();
        // mpv allocates max(existing ID)+1, so add the third track before
        // removing the middle one to create a real gap (1,3).
        raw(
            &session,
            vec![
                json!("audio-add"),
                json!(c.to_str().unwrap()),
                json!("select"),
            ],
        )
        .await;
        let state = wait_state(&session, "third audio added", |s| {
            s["track-list"].as_array().is_some_and(|ts| {
                ts.iter().any(|t| {
                    t["type"] == "audio" && t["id"].as_i64().is_some_and(|id| id > audio[1])
                })
            })
        })
        .await;
        let replacement = state["track-list"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|t| t["type"] == "audio")
            .map(|t| t["id"].as_i64().unwrap())
            .max()
            .unwrap();
        raw(&session, vec![json!("audio-remove"), json!(audio[1])]).await;
        let state = wait_state(&session, "middle audio removed", |s| {
            s["track-list"].as_array().is_some_and(|ts| {
                ts.iter().filter(|t| t["type"] == "audio").count() == 2
                    && !ts
                        .iter()
                        .any(|t| t["type"] == "audio" && t["id"] == audio[1])
            })
        })
        .await;
        assert!(!state["track-list"]
            .as_array()
            .unwrap()
            .iter()
            .any(|t| t["type"] == "audio" && t["id"] == audio[1]));
        let subtitle = state["track-list"]
            .as_array()
            .unwrap()
            .iter()
            .find(|t| t["type"] == "sub")
            .unwrap()["id"]
            .as_i64()
            .unwrap();
        session
            .command(vec![json!("set_property"), json!("sid"), json!(subtitle)])
            .await
            .unwrap();
        wait_state(&session, "subtitle enabled", |s| s["sid"] == subtitle).await;
        for (property, value) in [
            ("aid", json!(replacement)),
            ("sid", json!("no")),
            ("speed", json!(1.5)),
            ("sub-delay", json!(0.25)),
            ("sub-scale", json!(1.2)),
            ("pause", json!(false)),
        ] {
            session
                .command(vec![json!("set_property"), json!(property), value])
                .await
                .unwrap();
        }
        let state = wait_state(&session, "controls and subtitle off", |s| {
            s["pause"] == false
                && s["speed"] == 1.5
                && s["aid"] == replacement
                // The command accepts "no"; the JSON property reports false.
                && s["sid"] == false
                && s["sub-delay"] == 0.25
                && s["sub-scale"] == 1.2
        })
        .await;
        assert_eq!(state["hwdec-current"], "no");
        for value in [1, 0] {
            session
                .command(vec![json!("set_property"), json!("panscan"), json!(value)])
                .await
                .unwrap();
            wait_state(&session, "fullscreen frame mode", |s| s["panscan"].as_f64() == Some(value as f64)).await;
        }
        session
            .command(vec![json!("set_property"), json!("pause"), json!(true)])
            .await
            .unwrap();
        wait_state(&session, "paused before seek", |s| s["pause"] == true).await;
        // Seek both forwards and backwards while paused. A broad >= predicate
        // would incorrectly accept EOF as proof that the seek succeeded.
        for target in [5.0, 3.0] {
            session
                .command(vec![json!("seek"), json!(target), json!("absolute+exact")])
                .await
                .unwrap();
            wait_state(&session, "exact seek", |s| {
                s["time-pos"]
                    .as_f64()
                    .is_some_and(|n| (n - target).abs() < 0.15)
                    && s["pause"] == true
                    && s["seeking"] == false
                    && s["eof-reached"] == false
            })
            .await;
        }
        session
            .command(vec![json!("set_property"), json!("aid"), json!("no")])
            .await
            .unwrap();
        wait_state(&session, "audio off", |s| {
            s["pause"] == true && s["aid"] == false
        })
        .await;
        raw(
            &session,
            vec![
                json!("script-message"),
                json!("movieclaw-input"),
                json!("space"),
            ],
        )
        .await;
        wait_state(&session, "native input", |s| {
            s["input_events"].as_u64().is_some_and(|n| n >= 1)
        })
        .await;
        assert_eq!(session.snapshot()["ipc_connections"], 1);
        raw(&session, vec![json!("quit")]).await;
        session.stop();
        wait_state(&session, "pipe closed", |s| s["ipc_connected"] == false).await;
        assert!(session
            .command(vec![json!("get_property"), json!("pause")])
            .await
            .is_err());
        let deadline = Instant::now() + Duration::from_secs(3);
        loop {
            if let Some(exit) = fixture.child.try_wait().unwrap() {
                assert!(exit.success());
                break;
            }
            assert!(
                Instant::now() < deadline,
                "mpv did not exit after quit/Session.stop"
            );
            tokio::time::sleep(Duration::from_millis(25)).await;
        }
        println!("real mpv IPC: observed audio IDs {audio:?}->{replacement}, subtitle off, speed/delay/scale, seek, input, one pipe, process exit/cancel verified");
    }
}
