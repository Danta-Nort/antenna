// SPDX-License-Identifier: AGPL-3.0-only
//! Local models and local agents (D-104, CONTROL §24) with real daemons and a stand-in runtime
//! (`tools/fake-llama-server.py`, which speaks llama-server's API on its unix socket and reports what its sandbox lets
//! it do). The download runs the real `curl` in the agent sandbox through the daemon's proxy against a loopback HTTPS
//! server; the real llama.cpp with a real model is `real_llama_server_answers_in_its_sandbox` (`#[ignore]`).

#[cfg(any(target_os = "linux", target_os = "macos"))]
mod common;

/// The stand-in runtime is a Python script: on Linux it runs in both sandbox modes. On macOS the check that matters is
/// the Seatbelt run of the real runtime (`real::real_llama_server_answers_in_its_sandbox`: Metal under the profile).
#[cfg(target_os = "linux")]
mod linux {
    use std::{
        io::{BufRead, BufReader},
        path::{Path, PathBuf},
        process::{Child, Command, Stdio},
        time::{Duration, Instant},
    };

    use serde_json::{Value, json};

    use super::common::{CleanEnv, Net, Node, last_json};

    fn hex_sha256(b: &[u8]) -> String {
        data_encoding::HEXLOWER.encode(&antenna_core::crypto::sha256(&[b]))
    }

    fn fake_runtime() -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../tools/fake-llama-server.py")
    }

    /// A model of the test catalog: its bytes, and a hash that may be wrong on purpose.
    struct TestModel {
        id: &'static str,
        bytes: Vec<u8>,
        wrong_hash: bool,
        memory: u64,
    }

    impl TestModel {
        fn new(id: &'static str, len: usize) -> Self {
            let bytes = (0..len).map(|i| (i * 7 + id.len()) as u8).collect();
            Self {
                id,
                bytes,
                wrong_hash: false,
                memory: 64 << 20,
            }
        }
    }

    /// A daemon with a test catalog, the stand-in runtime and its settings.
    struct Rig {
        _root: tempfile::TempDir,
        root: PathBuf,
        node: Node,
        runtime: PathBuf,
        files: PathBuf,
    }

    fn catalog(models: &[TestModel], template_sha: &str) -> Value {
        let builtin: Value = serde_json::from_str(antenna_proto::models::BUILTIN_JSON).unwrap();
        let base = builtin["models"][0].clone();
        let list: Vec<Value> = models
            .iter()
            .map(|m| {
                let mut v = base.clone();
                v["id"] = json!(m.id);
                v["name"] = json!(format!("Test {}", m.id));
                v["file"] = json!(format!("{}.gguf", m.id));
                v["size"] = json!(m.bytes.len());
                v["sha256"] = json!(if m.wrong_hash {
                    hex_sha256(b"something else")
                } else {
                    hex_sha256(&m.bytes)
                });
                v["memory"] = json!(m.memory.max(m.bytes.len() as u64));
                v["memory_metal"] = json!(m.memory.max(m.bytes.len() as u64));
                v["slot_memory"] = json!(1 << 20);
                v["chat_template"] =
                    json!({"file": "t.jinja", "sha256": template_sha, "source": "test"});
                v
            })
            .collect();
        json!({"version": 1, "runtime": builtin["runtime"], "models": list})
    }

    fn rig(name: &str, models: &[TestModel], settings: Value, extra: &[String]) -> Rig {
        let t = tempfile::tempdir().unwrap();
        let root = t.path().to_path_buf();
        let runtime = root.join("runtime");
        std::fs::create_dir_all(runtime.join("templates")).unwrap();
        std::fs::copy(fake_runtime(), runtime.join("llama-server")).unwrap();
        let template = b"{{ messages }}";
        std::fs::write(runtime.join("templates/t.jinja"), template).unwrap();
        std::fs::write(runtime.join("fake-llama-server.json"), settings.to_string()).unwrap();
        let files = root.join("files");
        std::fs::create_dir_all(&files).unwrap();
        for m in models {
            std::fs::write(files.join(format!("{}.gguf", m.id)), &m.bytes).unwrap();
        }
        let cat = root.join("catalog.json");
        std::fs::write(&cat, catalog(models, &hex_sha256(template)).to_string()).unwrap();
        let mut node = Node::new(&root, name, Net::Local);
        node.extra_args = vec![
            "--local-catalog".into(),
            cat.to_string_lossy().into_owned(),
            "--local-runtime".into(),
            runtime.join("llama-server").to_string_lossy().into_owned(),
        ];
        node.extra_args.extend(extra.iter().cloned());
        node.start();
        node.init();
        Rig {
            _root: t,
            root,
            node,
            runtime,
            files,
        }
    }

    impl Rig {
        fn models(&self) -> Value {
            self.node.json(&["local", "models"])
        }

        fn model(&self, id: &str) -> Value {
            self.models()["models"]
                .as_array()
                .unwrap()
                .iter()
                .find(|m| m["id"] == id)
                .cloned()
                .unwrap()
        }

        fn install_file(&self, id: &str) -> Value {
            let f = self.files.join(format!("{id}.gguf"));
            self.node.json(&[
                "local",
                "install",
                id,
                "--from-file",
                f.to_str().unwrap(),
                "--wait",
                "--timeout",
                "60s",
            ])
        }

        fn add(&self, name: &str, model: &str) -> Value {
            let out = self.node.x_stdin(
                &[
                    "--json",
                    "local",
                    "add",
                    name,
                    "--model",
                    model,
                    "--password-stdin",
                ],
                &format!("{}\n", self.node.password),
            );
            assert!(out.status.success(), "local add: {out:?}");
            last_json(&out.stdout)
        }

        /// `local say`: the deltas (events) and the end of the turn.
        fn say(&self, agent: &str, text: &str) -> (Vec<Value>, Value) {
            let out = self
                .node
                .x(&["--json", "local", "say", agent, text, "--timeout", "60s"]);
            let s = String::from_utf8_lossy(&out.stdout);
            let lines: Vec<Value> = s
                .lines()
                .filter(|l| !l.trim().is_empty())
                .map(|l| serde_json::from_str(l).unwrap_or_else(|e| panic!("{e}: {l}")))
                .collect();
            assert!(out.status.success(), "local say: {out:?}");
            let (last, deltas) = lines.split_last().unwrap();
            (deltas.to_vec(), last.clone())
        }

        fn say_spawn(&self, agent: &str, text: &str) -> Child {
            self.node
                .cmd()
                .args(["--json", "local", "say", agent, text, "--timeout", "60s"])
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .spawn()
                .unwrap()
        }

        fn agent_state(&self, name: &str) -> Value {
            self.models()["agents"]
                .as_array()
                .unwrap()
                .iter()
                .find(|a| a["name"] == name)
                .cloned()
                .unwrap()
        }

        fn wait_agent(&self, name: &str, state: &str, secs: u64) -> Value {
            let t = Instant::now();
            loop {
                let a = self.agent_state(name);
                if a["state"] == state {
                    return a;
                }
                assert!(
                    t.elapsed() < Duration::from_secs(secs),
                    "{name} never {state}: {a}"
                );
                std::thread::sleep(Duration::from_millis(100));
            }
        }
    }

    fn text_of(deltas: &[Value]) -> String {
        deltas.iter().filter_map(|d| d["delta"].as_str()).collect()
    }

    /// The whole path with the stand-in runtime: install from a file (checked), a local agent, a streamed reply, the
    /// conversation in the encrypted database, a restart that keeps it and replays it into the new loop, removal.
    #[test]
    fn a_local_agent_chats_and_its_conversation_survives_a_restart() {
        let mut r = rig("lm", &[TestModel::new("tiny", 300_000)], json!({}), &[]);
        let m = r.model("tiny");
        assert_eq!(m["state"], "available");
        assert_eq!(r.models()["runtime"]["available"], true, "{}", r.models());
        let ready = r.install_file("tiny");
        assert_eq!(ready["state"], "ready", "{ready}");
        // The checked file is read-only in the models folder.
        let path = r.node.dir.join("local/models/tiny.gguf");
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(
            std::fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o444
        );

        let a = r.add("helper", "tiny");
        assert_eq!(
            (a["name"].as_str(), a["runtime"].as_str()),
            (Some("helper"), Some("local")),
            "{a}"
        );
        // It is an ordinary agent of the node, with no links and no token file.
        let agents = r.node.json(&["agent", "list"]);
        let row = agents["agents"]
            .as_array()
            .unwrap()
            .iter()
            .find(|x| x["name"] == "helper")
            .cloned()
            .unwrap();
        assert_eq!(row["local_model"], "tiny", "{row}");
        assert_eq!(row["session"]["links"], json!([]), "{row}");
        assert!(!r.node.dir.join("agents/helper.token").exists());
        // Its token is never handed out.
        let out = r.node.x_stdin(
            &["--json", "agent", "token", "helper", "--password-stdin"],
            &format!("{}\n", r.node.password),
        );
        assert!(!out.status.success());
        assert_eq!(last_json(&out.stdout)["error"], "denied", "{out:?}");

        let (deltas, end) = r.say("helper", "hello there friend");
        assert_eq!(end["outcome"], "done", "{end}");
        assert_eq!(end["text"], "Echo: hello there friend");
        assert!(deltas.len() >= 3, "streamed in pieces: {deltas:?}");
        assert_eq!(text_of(&deltas), "Echo: hello there friend");
        assert_eq!(end["usage"]["output_tokens"], 4, "{end}");
        let (_, end2) = r.say("helper", "second");
        assert_eq!(end2["turn"], 2);

        let h = r.node.json(&["local", "history", "helper"]);
        let items: Vec<(String, String)> = h["items"]
            .as_array()
            .unwrap()
            .iter()
            .map(|i| {
                (
                    i["role"].as_str().unwrap().into(),
                    i["text"].as_str().unwrap().into(),
                )
            })
            .collect();
        assert_eq!(
            items,
            vec![
                ("owner".into(), "hello there friend".into()),
                ("agent".into(), "Echo: hello there friend".into()),
                ("owner".into(), "second".into()),
                ("agent".into(), "Echo: second".into()),
            ]
        );
        // Nothing of the conversation is in plain text on disk: only the encrypted database holds it.
        let found = Command::new("grep")
            .args(["-rl", "hello there friend"])
            .arg(&r.node.dir)
            .output()
            .unwrap();
        assert!(
            found.stdout.is_empty(),
            "plain text in {}",
            String::from_utf8_lossy(&found.stdout)
        );

        // A restart: the conversation is still there, and the new loop gets it as context.
        r.node.stop();
        r.node.start();
        r.node.unlock();
        let h = r.node.json(&["local", "history", "helper"]);
        assert_eq!(h["items"].as_array().unwrap().len(), 4, "{h}");
        let (_, end) = r.say("helper", "context");
        let seen = end["text"].as_str().unwrap();
        assert!(seen.starts_with("I see 6 messages"), "{seen}");
        assert!(
            seen.contains("user:hello there friend") && seen.contains("assistant:Echo: second"),
            "{seen}"
        );

        // A new conversation drops the old one.
        let a = r.node.json(&["local", "session", "helper", "reset"]);
        assert_eq!(a["turns"], 0, "{a}");
        assert!(
            r.node.json(&["local", "history", "helper"])["items"]
                .as_array()
                .unwrap()
                .is_empty()
        );

        // Removing the model keeps the agent, which now waits for its model.
        let m = r.node.json(&["local", "remove", "tiny"]);
        assert_eq!(m["state"], "available", "{m}");
        assert!(!path.exists());
        assert_eq!(r.agent_state("helper")["state"], "no_model");
        let (_, end) = r.say("helper", "are you there?");
        assert_eq!(end["outcome"], "failed", "{end}");
        assert!(
            end["detail"]
                .as_str()
                .unwrap()
                .contains("not on this computer"),
            "{end}"
        );
        // Removing the agent removes its conversation too.
        let out = r.node.x_stdin(
            &["--json", "agent", "remove", "helper", "--password-stdin"],
            &format!("{}\n", r.node.password),
        );
        assert!(out.status.success(), "{out:?}");
        assert!(r.models()["agents"].as_array().unwrap().is_empty());
    }

    /// A file that is not the model is refused: a different size before copying, a different hash after; the copy
    /// is deleted and the owner's original stays.
    #[test]
    fn a_file_that_does_not_match_the_release_is_deleted() {
        let mut bad = TestModel::new("bad", 200_000);
        bad.wrong_hash = true;
        let r = rig("lmbad", &[bad], json!({}), &[]);
        let src = r.files.join("bad.gguf");
        let out = r.node.x(&[
            "--json",
            "local",
            "install",
            "bad",
            "--from-file",
            src.to_str().unwrap(),
            "--wait",
            "--timeout",
            "60s",
        ]);
        assert!(!out.status.success());
        assert_eq!(last_json(&out.stdout)["error"], "hash_mismatch", "{out:?}");
        let m = r.model("bad");
        assert_eq!(
            (m["state"].as_str(), m["error_code"].as_str()),
            (Some("failed"), Some("hash_mismatch")),
            "{m}"
        );
        assert!(
            m["error"].as_str().unwrap().contains("does not match"),
            "{m}"
        );
        assert!(!r.node.dir.join("local/models/bad.gguf").exists());
        assert!(!r.node.dir.join("local/dl/bad").exists());
        assert!(src.exists(), "the owner's file stays");
        // A file of another size is refused before anything is copied.
        let short = r.root.join("short.gguf");
        std::fs::write(&short, b"GGUF").unwrap();
        let out = r.node.x(&[
            "--json",
            "local",
            "install",
            "bad",
            "--from-file",
            short.to_str().unwrap(),
        ]);
        assert_eq!(last_json(&out.stdout)["error"], "hash_mismatch", "{out:?}");
    }

    /// A model that was changed after its check is checked again before it is loaded, and refused.
    #[test]
    fn a_model_changed_after_its_check_is_not_loaded() {
        let r = rig("lmchg", &[TestModel::new("tiny", 100_000)], json!({}), &[]);
        r.install_file("tiny");
        r.add("helper", "tiny");
        let path = r.node.dir.join("local/models/tiny.gguf");
        // Same size, one byte different (we are the owner: the read-only mode does not stop us).
        let mut b = std::fs::read(&path).unwrap();
        b[10] ^= 0xff;
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
        std::fs::write(&path, &b).unwrap();
        let (_, end) = r.say("helper", "hi");
        assert_eq!(end["outcome"], "failed", "{end}");
        assert!(
            end["detail"].as_str().unwrap().contains("hash_mismatch"),
            "{end}"
        );
        assert!(!path.exists(), "the changed file is deleted");
    }

    /// What the runtime's sandbox lets it do, seen from the inside through the whole chat path, in both Linux modes,
    /// with a negative control: the same program outside the sandbox can do all of it.
    #[test]
    fn the_runtime_cannot_write_its_model_or_reach_anything() {
        let secret_dir = tempfile::tempdir().unwrap();
        let secret = secret_dir.path().join("id_ed25519");
        std::fs::write(&secret, "PRIVATE KEY").unwrap();
        let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        let port = listener.local_addr().unwrap().port();
        std::thread::spawn(move || for _ in listener.incoming() {});
        for mode in ["bwrap", "landlock"] {
            let extra: Vec<String> = if mode == "landlock" {
                vec!["--wake-landlock-only".into()]
            } else {
                vec![]
            };
            // The daemon socket's path is known only after the node exists: the probe settings name it.
            let name = format!("lmsb{}", &mode[..2]);
            let r = rig(&name, &[TestModel::new("tiny", 50_000)], json!({}), &extra);
            let settings = json!({
                "probe_tcp_port": port,
                "probe_paths": [secret.to_str().unwrap()],
                "probe_socket": r.node.dir.join("antennad.sock").to_str().unwrap(),
            });
            std::fs::write(
                r.runtime.join("fake-llama-server.json"),
                settings.to_string(),
            )
            .unwrap();
            r.install_file("tiny");
            r.add("helper", "tiny");
            let (_, end) = r.say("helper", "probe");
            let p = end["text"].as_str().unwrap().to_string();
            println!("FACT local runtime sandbox={mode} {p}");
            for want in [
                "read_model=ok",
                "write_model=denied",
                "tcp=denied",
                "read:id_ed25519=denied",
                "unix=denied",
            ] {
                assert!(p.contains(want), "{mode}: {want} not in {p}");
            }
            // The sandbox note: listen-only network.
            let log = std::fs::read_to_string(r.node.dir.with_extension("log")).unwrap_or_default();
            assert!(!log.contains("PRIVATE KEY"));
        }
        // Negative control: the same stand-in, unsandboxed, can do every one of these.
        let d = tempfile::tempdir().unwrap();
        let rt = d.path().join("rt");
        std::fs::create_dir_all(&rt).unwrap();
        std::fs::copy(fake_runtime(), rt.join("llama-server")).unwrap();
        let control_sock = d.path().join("control.sock");
        let _control = std::os::unix::net::UnixListener::bind(&control_sock).unwrap();
        std::fs::write(
            rt.join("fake-llama-server.json"),
            json!({"probe_tcp_port": port, "probe_paths": [secret.to_str().unwrap()], "probe_socket": control_sock})
                .to_string(),
        )
        .unwrap();
        let model = d.path().join("m.gguf");
        std::fs::write(&model, b"GGUF").unwrap();
        let sock = d.path().join("llm.sock");
        let mut child = Command::new(rt.join("llama-server"))
            .clean_env()
            .env("LLAMA_API_KEY", "k")
            .args([
                "-m",
                model.to_str().unwrap(),
                "--host",
                sock.to_str().unwrap(),
            ])
            .stderr(Stdio::piped())
            .spawn()
            .unwrap();
        let mut probes = String::new();
        let mut err = BufReader::new(child.stderr.take().unwrap());
        while err.read_line(&mut probes).unwrap() > 0 && !probes.contains("probes") {}
        let _ = child.kill();
        let _ = child.wait();
        println!("FACT unsandboxed control {}", probes.trim());
        for want in [
            "\"write_model\": \"allowed\"",
            "\"tcp\": \"allowed\"",
            "\"read:id_ed25519\": \"allowed\"",
            "\"unix\": \"allowed\"",
        ] {
            assert!(probes.contains(want), "{want} not in {probes}");
        }
    }

    /// The owner can end a turn in progress; what was written so far stays with `interrupted`.
    #[test]
    fn the_owner_interrupts_a_long_reply() {
        let words: Vec<String> = (0..60).map(|i| format!("w{i}")).collect();
        let r = rig(
            "lmint",
            &[TestModel::new("tiny", 50_000)],
            json!({"delay_ms": 150, "reply": words.join(" ")}),
            &[],
        );
        r.install_file("tiny");
        r.add("helper", "tiny");
        let child = r.say_spawn("helper", "talk a lot");
        r.wait_agent("helper", "busy", 30);
        std::thread::sleep(Duration::from_millis(800));
        let a = r.node.json(&["local", "session", "helper", "interrupt"]);
        assert!(a["name"] == "helper", "{a}");
        let out = child.wait_with_output().unwrap();
        let end = last_json(&out.stdout);
        assert_eq!(end["outcome"], "interrupted", "{end}");
        let text = end["text"].as_str().unwrap();
        assert!(text.starts_with("w0 w1") && !text.contains("w59"), "{text}");
        let h = r.node.json(&["local", "history", "helper"]);
        assert_eq!(h["items"][1]["outcome"], "interrupted", "{h}");
        assert_eq!(h["items"][1]["detail"], "stopped by the owner", "{h}");
        // The next turn works.
        std::fs::write(r.runtime.join("fake-llama-server.json"), "{}").unwrap();
        r.node.json(&["local", "session", "helper", "stop"]);
    }

    /// A runtime that dies in the middle of a reply: the turn fails with what was written; the next one starts it
    /// again.
    #[test]
    fn a_crash_fails_the_turn_and_the_next_turn_recovers() {
        let r = rig(
            "lmcrash",
            &[TestModel::new("tiny", 50_000)],
            json!({"exit_after_words": 2, "reply": "one two three four"}),
            &[],
        );
        r.install_file("tiny");
        r.add("helper", "tiny");
        let (_, end) = r.say("helper", "hi");
        assert_eq!(end["outcome"], "failed", "{end}");
        assert!(end["text"].as_str().unwrap().starts_with("one"), "{end}");
        let (_, end) = r.say("helper", "again");
        // The runtime started again (its settings still crash it): it answers, then fails again; the point is that a
        // new turn does not hang.
        assert!(
            matches!(end["outcome"].as_str(), Some("failed") | Some("done")),
            "{end}"
        );
    }

    /// Two models that do not fit together: the second waits for the first to go idle, then the first is unloaded;
    /// an idle model is unloaded after `--local-idle-secs`.
    #[test]
    fn models_that_do_not_fit_together_wait_and_idle_ones_unload() {
        let mut a = TestModel::new("ma", 50_000);
        let mut b = TestModel::new("mb", 60_000);
        a.memory = 600 << 20;
        b.memory = 600 << 20;
        let r = rig(
            "lmq",
            &[a, b],
            json!({"delay_ms": 100, "reply": "a b c d e f g h i j k l m n o"}),
            &[
                "--local-memory-budget".into(),
                (900u64 << 20).to_string(),
                "--local-idle-secs".into(),
                "3".into(),
            ],
        );
        r.install_file("ma");
        r.install_file("mb");
        r.add("first", "ma");
        r.add("second", "mb");
        let t0 = Instant::now();
        let c1 = r.say_spawn("first", "go");
        r.wait_agent("first", "busy", 30);
        let c2 = r.say_spawn("second", "go too");
        let w = r.wait_agent("second", "waiting", 10);
        println!("second while the first answers: {w}");
        let o1 = c1.wait_with_output().unwrap();
        let o2 = c2.wait_with_output().unwrap();
        assert_eq!(last_json(&o1.stdout)["outcome"], "done");
        let out2 = String::from_utf8_lossy(&o2.stdout);
        assert!(out2.contains("\"activity\":\"waiting\""), "{out2}");
        assert_eq!(last_json(&o2.stdout)["outcome"], "done", "{out2}");
        assert!(
            t0.elapsed() > Duration::from_millis(1400),
            "the second waited for the first"
        );
        // Only the second model is loaded now; after the idle time, none.
        let m = r.models();
        let loaded: Vec<&str> = m["models"]
            .as_array()
            .unwrap()
            .iter()
            .filter(|m| m["loaded"] == true)
            .map(|m| m["id"].as_str().unwrap())
            .collect();
        assert_eq!(loaded, ["mb"], "{m}");
        let t = Instant::now();
        while r.models()["models"]
            .as_array()
            .unwrap()
            .iter()
            .any(|m| m["loaded"] == true)
        {
            assert!(
                t.elapsed() < Duration::from_secs(20),
                "the idle model stayed loaded"
            );
            std::thread::sleep(Duration::from_millis(200));
        }
        r.wait_agent("second", "sleeping", 20);
    }

    /// The download: `curl` in the sandbox, through the proxy, from a loopback HTTPS server standing in for the hub
    /// (debug-only flags). It resumes after the connection drops; a file whose hash does not match is deleted; a
    /// redirect to a host the proxy does not allow fails.
    #[test]
    fn a_model_downloads_resumes_and_is_checked() {
        let t = tempfile::tempdir().unwrap();
        let hub = t.path().join("hub");
        std::fs::create_dir_all(&hub).unwrap();
        let (cert, key) = (t.path().join("cert.pem"), t.path().join("key.pem"));
        let ok = Command::new("openssl")
            .args([
                "req",
                "-x509",
                "-newkey",
                "rsa:2048",
                "-nodes",
                "-days",
                "1",
                "-subj",
                "/CN=127.0.0.1",
            ])
            .args(["-addext", "subjectAltName=IP:127.0.0.1"])
            .arg("-keyout")
            .arg(&key)
            .arg("-out")
            .arg(&cert)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .status()
            .unwrap();
        assert!(ok.success());
        let good = TestModel::new("good", 3_000_000);
        let mut bad = TestModel::new("bad", 1_000_000);
        bad.wrong_hash = true;
        let away = TestModel::new("away", 1_000);
        for m in [&good, &bad, &away] {
            std::fs::write(hub.join(format!("{}.gguf", m.id)), &m.bytes).unwrap();
        }
        let port_file = t.path().join("port");
        let log = t.path().join("hub.log");
        let mut server = Command::new("python3")
            .arg("-c")
            .arg(HUB)
            .arg(&hub)
            .arg(&port_file)
            .arg(&cert)
            .arg(&key)
            .arg(&log)
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let start = Instant::now();
        while !port_file.exists() || std::fs::read_to_string(&port_file).unwrap().is_empty() {
            assert!(
                start.elapsed() < Duration::from_secs(10),
                "hub did not start"
            );
            std::thread::sleep(Duration::from_millis(50));
        }
        let port = std::fs::read_to_string(&port_file).unwrap();
        let r = rig(
            "lmdl",
            &[good, bad, away],
            json!({}),
            &[
                "--local-hub".into(),
                format!("https://127.0.0.1:{port}"),
                "--local-hub-cacert".into(),
                cert.to_string_lossy().into_owned(),
            ],
        );
        let wait = |id: &str| {
            r.node.x(&[
                "--json",
                "local",
                "install",
                id,
                "--wait",
                "--timeout",
                "90s",
            ])
        };
        // The hub cuts the first transfer of `good` short: the second try asks for the rest.
        let out = wait("good");
        assert!(out.status.success(), "{out:?}");
        assert_eq!(last_json(&out.stdout)["state"], "ready");
        let reqs = std::fs::read_to_string(&log).unwrap();
        println!("hub requests:\n{reqs}");
        assert!(reqs.contains("good.gguf range=None"), "{reqs}");
        assert!(
            reqs.contains("good.gguf range=bytes=1000000-"),
            "resumed: {reqs}"
        );
        assert!(r.node.dir.join("local/models/good.gguf").exists());
        // A hash that does not match: deleted.
        let out = wait("bad");
        assert_eq!(last_json(&out.stdout)["error"], "hash_mismatch", "{out:?}");
        assert!(
            !r.node.dir.join("local/models/bad.gguf").exists()
                && !r.node.dir.join("local/dl/bad").exists()
        );
        // A redirect to another host: the proxy refuses it, and there is no second try.
        let t0 = Instant::now();
        let out = wait("away");
        let e = last_json(&out.stdout);
        assert_eq!(e["error"], "fetch_failed", "{e}");
        assert!(
            e["message"].as_str().unwrap().contains("refused localhost"),
            "{e}"
        );
        assert!(t0.elapsed() < Duration::from_secs(20));
        let _ = server.kill();
        let _ = server.wait();
    }

    /// A stand-in for the hub: `/<repo>/resolve/<commit>/<file>` from a folder, with `Range`; the first request for
    /// `good.gguf` is cut after 1,000,000 bytes; `away.gguf` redirects to `localhost`, which the proxy does not allow.
    const HUB: &str = r#"
import http.server, os, ssl, sys
root, port_file, cert, key, log = sys.argv[1:6]
cut = {"good.gguf"}
class H(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"
    def log_message(self, *a): pass
    def do_GET(self):
        name = self.path.rsplit("/", 1)[-1]
        rng = self.headers.get("Range")
        with open(log, "a") as f: f.write("GET %s range=%s\n" % (name, rng))
        if name == "away.gguf":
            port = self.server.server_address[1]
            self.send_response(302)
            self.send_header("Location", "https://localhost:%d/x/resolve/c/away.gguf" % port)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        p = os.path.join(root, name)
        if not os.path.isfile(p):
            self.send_response(404); self.send_header("Content-Length", "0"); self.end_headers(); return
        data = open(p, "rb").read()
        start = 0
        if rng and rng.startswith("bytes="):
            start = int(rng[6:].split("-")[0])
            self.send_response(206)
            self.send_header("Content-Range", "bytes %d-%d/%d" % (start, len(data) - 1, len(data)))
        else:
            self.send_response(200)
        body = data[start:]
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Accept-Ranges", "bytes")
        self.end_headers()
        if name in cut:
            cut.discard(name)
            self.wfile.write(body[:1000000]); self.wfile.flush()
            self.close_connection = True
            self.connection.shutdown(2)
            return
        self.wfile.write(body)
srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(cert, key)
srv.socket = ctx.wrap_socket(srv.socket, server_side=True)
open(port_file, "w").write(str(srv.server_address[1]))
srv.serve_forever()
"#;
}

#[cfg(any(target_os = "linux", target_os = "macos"))]
mod real {
    use std::time::Instant;

    use serde_json::Value;

    use super::common::{Net, Node, last_json};

    /// The real llama.cpp runtime with a real model, in its sandbox (`#[ignore]`: it needs the runtime build and a model
    /// file). `ANTENNA_TEST_LLAMA=<the llama/ folder of packaging/llama/build.sh>`, `ANTENNA_TEST_GGUF=<a model
    /// file>`, `ANTENNA_TEST_MODEL=<its catalog ID>` (default `qwen3.5-2b`), optionally `ANTENNA_TEST_THREADS`. On a
    /// Mac this is the run that checks Metal under the Seatbelt profile.
    #[test]
    #[ignore]
    fn real_llama_server_answers_in_its_sandbox() {
        let (Ok(rt), Ok(gguf)) = (
            std::env::var("ANTENNA_TEST_LLAMA"),
            std::env::var("ANTENNA_TEST_GGUF"),
        ) else {
            panic!("set ANTENNA_TEST_LLAMA and ANTENNA_TEST_GGUF");
        };
        let model = std::env::var("ANTENNA_TEST_MODEL").unwrap_or_else(|_| "qwen3.5-2b".into());
        let t = tempfile::tempdir().unwrap();
        let mut node = Node::new(t.path(), "real", Net::Local);
        node.extra_args = vec!["--local-runtime".into(), format!("{rt}/llama-server")];
        if let Ok(n) = std::env::var("ANTENNA_TEST_THREADS") {
            node.extra_args.extend(["--local-threads".into(), n]);
        }
        node.start();
        node.init();
        let t0 = Instant::now();
        let out = node.x(&[
            "--json",
            "local",
            "install",
            &model,
            "--from-file",
            &gguf,
            "--wait",
            "--timeout",
            "5m",
        ]);
        assert!(out.status.success(), "{out:?}");
        println!(
            "FACT install from file (copy + SHA-256): {:.1} s",
            t0.elapsed().as_secs_f64()
        );
        let out = node.x_stdin(
            &[
                "--json",
                "local",
                "add",
                "helper",
                "--model",
                &model,
                "--password-stdin",
            ],
            &format!("{}\n", node.password),
        );
        assert!(out.status.success(), "{out:?}");
        for q in [
            "Answer in one sentence: what is the capital of France?",
            "Write three short sentences about the sea.",
            "Now answer in Russian, in one sentence: what did I ask you first?",
        ] {
            let t0 = Instant::now();
            let out = node.x(&["--json", "local", "say", "helper", q, "--timeout", "5m"]);
            let end = last_json(&out.stdout);
            let u = &end["usage"];
            let rate = |n: &Value, ms: &Value| {
                n.as_f64().unwrap_or(0.0) * 1000.0 / ms.as_f64().unwrap_or(1.0).max(1.0)
            };
            println!(
                "FACT turn {:.1} s: prompt {} (cached {}) at {:.1} t/s, reply {} at {:.1} t/s: {}",
                t0.elapsed().as_secs_f64(),
                u["prompt_tokens"],
                u["cached_tokens"],
                rate(&u["prompt_tokens"], &u["prompt_ms"]),
                u["output_tokens"],
                rate(&u["output_tokens"], &u["output_ms"]),
                end["text"]
            );
            assert_eq!(end["outcome"], "done", "{end}");
            assert!(!end["text"].as_str().unwrap().is_empty());
        }
        let m = node.json(&["local", "models"]);
        println!("FACT {}", m["hardware"]);
    }
}
