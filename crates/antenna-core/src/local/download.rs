// SPDX-License-Identifier: AGPL-3.0-only
//! The download of a model file (`models.rs` checks and places it): `curl` in the agent sandbox, HTTPS only (also for
//! redirects), through the daemon's CONNECT proxy whose only destinations are the hub's hosts; its only writable folder
//! is the model's own download folder. It resumes with a `Range` request after a network drop or a daemon restart and
//! resolves the pinned address again each time (the CDN's redirect carries a short-lived token). A refusal by the
//! proxy or a 4xx answer is final; anything else is tried again, five times at most.

use std::{
    path::{Path, PathBuf},
    time::{Duration, Instant},
};

use antenna_proto::{
    control::code,
    models::{CatalogModel, HUB},
};

use crate::{
    error::{Error, Result},
    node::Session,
    sandbox,
};

/// The hub's hosts the download may reach through the proxy: the resolver and its CDN (`us.aws.cdn.hf.co`, the Xet
/// bridge).
const HUB_HOSTS: &[&str] = &["huggingface.co", "*.hf.co"];
/// Attempts of one download before it is left as `failed` (it resumes from the bytes it has on the next install).
const ATTEMPTS: u32 = 5;

fn file_len(p: &Path) -> u64 {
    std::fs::metadata(p).map(|m| m.len()).unwrap_or(0)
}

impl Session {
    /// Download with `curl` in the sandbox, resuming, until the `.part` file has the catalog's size or the attempts
    /// run out.
    pub(super) async fn fetch(
        &self,
        cm: &CatalogModel,
        part: &Path,
        cancel: &mut tokio::sync::watch::Receiver<bool>,
    ) -> Result<()> {
        let mut last = String::new();
        for attempt in 0..ATTEMPTS {
            if file_len(part) == cm.size {
                return Ok(());
            }
            if file_len(part) > cm.size {
                let _ = std::fs::remove_file(part);
            }
            if attempt > 0 {
                let wait = Duration::from_secs(2u64 << attempt.min(5));
                tokio::select! {
                    _ = tokio::time::sleep(wait) => {}
                    _ = cancel.changed() => return Err(Error::internal("cancelled")),
                }
            }
            match self.fetch_once(cm, part, cancel).await {
                Ok(()) if file_len(part) == cm.size => return Ok(()),
                Ok(()) => {
                    last = format!(
                        "the download ended at {} of {} bytes",
                        file_len(part),
                        cm.size
                    );
                }
                Err(e) if e.code == code::SANDBOX_UNAVAILABLE => return Err(e),
                // Not worth another try: the proxy refused the host, or the hub answered 4xx.
                Err(e) if e.code == code::DENIED => {
                    return Err(Error::new(code::FETCH_FAILED, e.message));
                }
                Err(e) => last = e.message,
            }
            if *cancel.borrow() {
                return Err(Error::internal("cancelled"));
            }
            tracing::info!(
                "local model {}: download attempt {} failed: {last}",
                cm.id,
                attempt + 1
            );
        }
        Err(Error::new(code::FETCH_FAILED, last))
    }

    async fn fetch_once(
        &self,
        cm: &CatalogModel,
        part: &Path,
        cancel: &mut tokio::sync::watch::Receiver<bool>,
    ) -> Result<()> {
        let support = self.wake_support();
        let kind = support.kind.ok_or_else(|| {
            Error::new(
                code::SANDBOX_UNAVAILABLE,
                format!(
                    "the download runs only in a sandbox, and this system has none: {}",
                    support.detail
                ),
            )
        })?;
        let curl = ["/usr/bin/curl", "/bin/curl"]
            .into_iter()
            .map(PathBuf::from)
            .find(|p| p.is_file())
            .ok_or_else(|| Error::new(code::NOT_FOUND, "curl is not installed"))?;
        let dl = self.dl_dir(&cm.id);
        let (work, home, tmp) = (dl.join("work"), dl.join("home"), dl.join("tmp"));
        let hub = self.cfg.local.hub.clone().unwrap_or_else(|| HUB.into());
        let url = cm.url(&hub);
        let mut proxy_cfg = sandbox::ProxyConfig {
            allow_hosts: HUB_HOSTS.iter().map(|h| (*h).to_string()).collect(),
            ..Default::default()
        };
        let mut ro = Vec::new();
        let mut argv: Vec<String> = vec![curl.to_string_lossy().into_owned()];
        argv.extend(
            [
                "--fail",
                "--silent",
                "--show-error",
                "--location",
                "--proto",
                "=https",
                "--proto-redir",
                "=https",
                "--speed-limit",
                "1024",
                "--speed-time",
                "60",
                "--continue-at",
                "-",
            ]
            .map(String::from),
        );
        argv.push("--max-filesize".into());
        argv.push(cm.size.to_string());
        if let (Some(_), Some(ca)) = (&self.cfg.local.hub, &self.cfg.local.hub_cacert) {
            // Tests: the hub is a loopback HTTPS server with its own CA (debug builds only, `antennad`).
            if let Some(host) = url
                .strip_prefix("https://")
                .and_then(|r| r.split('/').next())
            {
                let (h, port) = host.rsplit_once(':').unwrap_or((host, "443"));
                proxy_cfg.allow_hosts = vec![h.to_string()];
                proxy_cfg.allow_ports = vec![port.parse().unwrap_or(443)];
                proxy_cfg.allow_private = true;
            }
            argv.push("--cacert".into());
            argv.push(ca.to_string_lossy().into_owned());
            if let Some(d) = ca.parent() {
                ro.push(d.to_path_buf());
            }
        }
        argv.push("--output".into());
        argv.push(part.to_string_lossy().into_owned());
        argv.push("--".into());
        argv.push(url);
        let proxy = sandbox::start_proxy(&dl.join("proxy.sock"), proxy_cfg).await?;
        let spec = sandbox::SandboxSpec {
            argv,
            env: vec![
                ("PATH".into(), "/usr/bin:/bin".into()),
                ("LC_ALL".into(), "C".into()),
            ],
            cwd: work,
            home,
            tmp,
            rw: vec![],
            ro,
            ro_binds: vec![],
            sockets: vec![],
            proxy: Some(sandbox::ProxyBridge {
                unix: proxy.path().to_path_buf(),
                port: 0,
            }),
            limits: sandbox::Limits {
                nofile: 256,
                fsize_bytes: cm.size.saturating_add(1 << 20),
                cpu_secs: 6 * 3600,
                data_bytes: 0,
            },
            kind,
            start_gate: false,
            agent_stdin: false,
            listen: None,
            gpu: false,
        };
        let me = std::env::current_exe()?;
        let mut running = sandbox::launch(&spec, &me).await?;
        let stderr = running.stderr.take();
        let err_task = tokio::spawn(async move {
            match stderr {
                Some(s) => crate::wake::read_tail(s).await,
                None => Vec::new(),
            }
        });
        let id = cm.id.clone();
        let mut speed = SpeedMeter::new(file_len(part));
        let status = loop {
            tokio::select! {
                st = running.wait() => break st,
                _ = cancel.changed() => {
                    running.stop(Duration::from_secs(2)).await;
                    return Err(Error::internal("cancelled"));
                }
                _ = tokio::time::sleep(Duration::from_millis(500)) => {
                    let n = file_len(part);
                    let v = speed.tick(n);
                    self.set_progress(&id, |p| {
                        p.state = "downloading";
                        p.done = n;
                        p.speed = v;
                    });
                    self.publish_model(&id, false);
                }
            }
        };
        let tail = err_task.await.unwrap_or_default();
        let stats = proxy.stats();
        drop(proxy);
        let status = status.map_err(|e| Error::internal(format!("curl: {e}")))?;
        if status.success() {
            return Ok(());
        }
        let text = String::from_utf8_lossy(&tail);
        let why = text
            .lines()
            .rfind(|l| !l.trim().is_empty() && !l.starts_with(sandbox::NOTE_PREFIX))
            .unwrap_or("")
            .chars()
            .filter(|c| !c.is_control())
            .take(300)
            .collect::<String>();
        if status.code() == Some(sandbox::EXIT_SANDBOX_FAILED) {
            return Err(Error::new(code::SANDBOX_UNAVAILABLE, why));
        }
        let blocked: Vec<String> = stats
            .blocked
            .iter()
            .map(|(h, p, _)| format!("{h}:{p}"))
            .collect();
        // curl's exit 22 is an HTTP error; a 4xx will not change on the next try.
        let permanent =
            !blocked.is_empty() || (status.code() == Some(22) && why.contains("error: 4"));
        Err(Error::new(
            if permanent {
                code::DENIED
            } else {
                code::FETCH_FAILED
            },
            if blocked.is_empty() {
                format!("curl exited with {status}: {why}")
            } else {
                format!(
                    "curl exited with {status}: {why} (the proxy refused {})",
                    blocked.join(", ")
                )
            },
        ))
    }
}

/// Download speed over the last few seconds.
struct SpeedMeter {
    samples: std::collections::VecDeque<(Instant, u64)>,
}

impl SpeedMeter {
    fn new(start: u64) -> Self {
        let mut samples = std::collections::VecDeque::new();
        samples.push_back((Instant::now(), start));
        Self { samples }
    }

    fn tick(&mut self, bytes: u64) -> Option<u64> {
        let now = Instant::now();
        self.samples.push_back((now, bytes));
        while self.samples.len() > 2
            && self
                .samples
                .front()
                .is_some_and(|(t, _)| now.duration_since(*t) > Duration::from_secs(5))
        {
            self.samples.pop_front();
        }
        let (t0, b0) = *self.samples.front()?;
        let dt = now.duration_since(t0).as_secs_f64();
        (dt > 0.2).then(|| (bytes.saturating_sub(b0) as f64 / dt) as u64)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_speed_meter_measures_the_recent_rate() {
        let mut s = SpeedMeter::new(0);
        assert_eq!(s.tick(0), None);
        std::thread::sleep(Duration::from_millis(300));
        let v = s.tick(3_000_000).unwrap();
        assert!((5_000_000..=11_000_000).contains(&v), "{v}");
    }
}
