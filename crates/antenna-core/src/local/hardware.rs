// SPDX-License-Identifier: AGPL-3.0-only
//! The hardware assessment (`docs/LOCAL-ASSISTANT.md` §2.4): what this computer can run, read without any permission.
//! Linux: `/proc/meminfo`, `/proc/cpuinfo`, the cgroup's `memory.max`, `sched_getaffinity`, `statvfs`. macOS: `sysctl`
//! (`hw.memsize`, `hw.ncpu`, `hw.perflevel0.physicalcpu`, `machdep.cpu.brand_string`, `kern.memorystatus_level`),
//! `statvfs`. Nothing prompts, needs root, reads another app's data or starts a shell.
//!
//! The recommendation ([`assess`]) is a pure function of the facts, so it is tested here on made-up machines: the
//! machine's tier picks the largest model its class can run at a useful speed (the table of §2.2), and the memory
//! local models may use at this moment can only lower that.

use antenna_proto::{
    control::{HardwareInfo, LocalModelInfo},
    models::CatalogModel,
};

const GIB: u64 = 1 << 30;
/// Machines below this memory run no local model (an "8 GB" machine reports 7.6–8 GiB).
const MIN_MEMORY: u64 = 7 * GIB;
/// The "16 GB or more" class (a 16 GB machine reports 15.3–16 GiB).
const MEMORY_16: u64 = 15 * GIB;
/// Room left for the OS, a browser and Antenna.
const HEADROOM: u64 = GIB;
/// Below this generation speed (tokens per second) a model is too slow to chat with (§2.4).
const MIN_SPEED: u32 = 10;

/// What the daemon read.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Machine {
    /// `linux`, `macos`.
    pub os: String,
    /// `x86_64`, `aarch64`.
    pub arch: String,
    /// CPU name.
    pub cpu: String,
    /// Physical cores (performance cores on Apple silicon).
    pub cores: u32,
    /// Hardware threads this process may use.
    pub threads: u32,
    /// AVX2 (x86-64).
    pub avx2: bool,
    /// Total memory or the cgroup's limit, bytes.
    pub memory: u64,
    /// Available now, bytes.
    pub available: u64,
    /// Free space where the models are kept, bytes.
    pub disk_free: u64,
}

impl Machine {
    /// Apple silicon: the runtime computes on the GPU with Metal.
    pub fn metal(&self) -> bool {
        self.os == "macos" && self.arch == "aarch64"
    }

    /// The Apple silicon generation from the CPU name (`Apple M2 Pro` → 2); `None` elsewhere.
    pub fn apple_generation(&self) -> Option<u32> {
        let rest = self.cpu.strip_prefix("Apple M")?;
        let digits: String = rest.chars().take_while(char::is_ascii_digit).collect();
        digits.parse().ok()
    }

    /// The memory bandwidth the runtime can use, GB/s (about 80 % of Apple's figure, 55 % of a laptop CPU's), for
    /// the speed estimate (§2.4); `None` when unknown.
    fn effective_bandwidth(&self) -> Option<f64> {
        if self.metal() {
            let name = self.cpu.to_ascii_lowercase();
            let tier = |base: f64, pro: f64, max: f64| {
                if name.contains("max") || name.contains("ultra") {
                    max
                } else if name.contains("pro") {
                    pro
                } else {
                    base
                }
            };
            let peak = match self.apple_generation()? {
                1 => tier(68.0, 200.0, 400.0),
                2 => tier(100.0, 200.0, 400.0),
                3 => tier(100.0, 150.0, 300.0),
                4 => tier(120.0, 273.0, 410.0),
                5 => tier(153.0, 273.0, 410.0),
                _ => tier(170.0, 273.0, 410.0),
            };
            Some(peak * 0.8)
        } else if self.arch == "x86_64" && self.avx2 {
            // Two channels of DDR5 at about 55 % (the Zen 4 and Intel laptops of §2.4); measured here on a shared
            // server CPU: 38 GB/s for the 2B model (`docs/LOCAL-ASSISTANT.md` §10).
            Some(40.0)
        } else {
            None
        }
    }

    /// Expected generation speed of a model file of `size` bytes, tokens per second.
    pub fn est_tokens_per_s(&self, size: u64) -> Option<u32> {
        let bw = self.effective_bandwidth()?;
        let gb = size as f64 / 1e9;
        (gb > 0.0).then(|| (bw / gb).floor() as u32)
    }

    /// What local models may use now, before subtracting loaded models: the smaller of half the total memory and the
    /// available memory minus the headroom.
    pub fn budget(&self) -> u64 {
        (self.memory / 2).min(self.available.saturating_sub(HEADROOM))
    }

    /// The model this machine's class runs at a useful speed (`docs/LOCAL-ASSISTANT.md` §2.2): Apple silicon M2 or
    /// newer with 16 GB → 9B; M1 with 16 GB, or an x86-64 CPU with AVX2 and 16 GB → 4B; 8 GB machines and Intel Macs
    /// → 2B; below 8 GB, or x86-64 without AVX2 → none. Returned as the index of the size class (0 small, 1 medium,
    /// 2 large) or the reason there is none.
    pub fn tier(&self) -> Result<usize, String> {
        if self.memory < MIN_MEMORY {
            return Err(format!(
                "{} of memory: local models need 8 GB or more",
                gb(self.memory)
            ));
        }
        if self.arch == "x86_64" && !self.avx2 {
            return Err("the CPU has no AVX2: a local model would run too slowly".into());
        }
        let big = self.memory >= MEMORY_16;
        Ok(if self.metal() {
            match (big, self.apple_generation().unwrap_or(1)) {
                (true, g) if g >= 2 => 2,
                (true, _) => 1,
                (false, _) => 0,
            }
        } else if self.os == "macos" {
            // An Intel Mac: CPU only, the small model.
            0
        } else if big {
            1
        } else {
            0
        })
    }

    /// The facts for the window.
    pub fn info(&self, loaded: u64) -> HardwareInfo {
        HardwareInfo {
            os: self.os.clone(),
            arch: self.arch.clone(),
            cpu: self.cpu.clone(),
            cores: self.cores,
            threads: self.threads,
            avx2: self.avx2,
            accel: if self.metal() { "metal" } else { "cpu" }.into(),
            memory_bytes: self.memory,
            available_bytes: self.available,
            budget_bytes: self.budget().saturating_sub(loaded),
            disk_free_bytes: self.disk_free,
        }
    }
}

/// `12.4 GB` (decimal, as the window shows sizes).
pub fn gb(bytes: u64) -> String {
    format!("{:.1} GB", bytes as f64 / 1e9)
}

/// Fit and recommendation of each catalog model on this machine (in catalog order, smallest first): `recommended` for
/// at most one model (the machine's tier, or the largest smaller one that fits the memory free now), `fits`, `slow`
/// (it fits, but it is above this machine's class and expected below 10 tokens per second), `too_big`,
/// `unsupported`.
pub fn assess(
    m: &Machine,
    models: &[&CatalogModel],
    loaded_elsewhere: u64,
) -> Vec<(String, String, Option<u32>)> {
    let budget = m.budget().saturating_sub(loaded_elsewhere);
    let tier = m.tier();
    // Models of one family come in size classes, smallest first; their position is their class.
    let mut out: Vec<(String, String, Option<u32>)> = Vec::new();
    let mut recommended: Option<usize> = None;
    if let Ok(t) = &tier {
        for (i, cm) in models.iter().enumerate() {
            if i <= *t && cm.memory_for(1, m.metal()) <= budget {
                recommended = Some(i);
            }
        }
    }
    for (i, cm) in models.iter().enumerate() {
        let need = cm.memory_for(1, m.metal());
        let est = m.est_tokens_per_s(cm.size);
        let (fit, detail) = match &tier {
            Err(why) => ("unsupported", why.clone()),
            Ok(_) if need > budget => (
                "too_big",
                format!(
                    "needs {} of memory; local models may use {} now",
                    gb(need),
                    gb(budget)
                ),
            ),
            Ok(_) if Some(i) == recommended => (
                "recommended",
                format!("fits in {} with room to spare", gb(budget)),
            ),
            // Above this machine's class: slow unless the bandwidth says otherwise (an M1 Pro reads memory three times
            // as fast as an M1).
            Ok(t) if i > *t && est.is_none_or(|e| e < MIN_SPEED) => (
                "slow",
                "fits in memory, but answers slowly on this computer".to_string(),
            ),
            Ok(_) => ("fits", format!("needs {} of memory", gb(need))),
        };
        out.push((fit.to_string(), detail, est));
    }
    out
}

/// Fills the fit fields of the window's model rows.
pub fn apply(rows: &mut [LocalModelInfo], fits: Vec<(String, String, Option<u32>)>) {
    for (r, (fit, detail, est)) in rows.iter_mut().zip(fits) {
        r.fit = fit;
        r.fit_detail = detail;
        r.est_tokens_per_s = est;
    }
}

/// Reads this machine. `models_dir` is where the files go (for the free space).
pub fn read(models_dir: &std::path::Path) -> Machine {
    let disk_free = disk_free(models_dir);
    #[cfg(target_os = "linux")]
    {
        linux::read(disk_free)
    }
    #[cfg(target_os = "macos")]
    {
        macos::read(disk_free)
    }
    #[cfg(not(any(target_os = "linux", target_os = "macos")))]
    {
        Machine {
            os: std::env::consts::OS.into(),
            arch: std::env::consts::ARCH.into(),
            cpu: String::new(),
            cores: 1,
            threads: 1,
            avx2: false,
            memory: 0,
            available: 0,
            disk_free,
        }
    }
}

/// Free space for an unprivileged user on the file system of `dir` (or its nearest existing parent).
#[cfg(unix)]
pub fn disk_free(dir: &std::path::Path) -> u64 {
    let mut p = dir.to_path_buf();
    loop {
        if p.exists() {
            break;
        }
        if !p.pop() {
            return 0;
        }
    }
    match rustix::fs::statvfs(&p) {
        Ok(s) => s.f_bavail.saturating_mul(s.f_frsize),
        Err(_) => 0,
    }
}

/// Windows: not read yet (`GetDiskFreeSpaceExW` comes with the built-in runtime there, D-134, WP-27): 0, so nothing is
/// downloaded on a guess.
#[cfg(windows)]
pub fn disk_free(_dir: &std::path::Path) -> u64 {
    0
}

#[cfg(target_os = "linux")]
mod linux {
    use super::Machine;

    /// `MemTotal` and `MemAvailable` of a `/proc/meminfo` text, bytes.
    pub(super) fn meminfo(text: &str) -> (u64, u64) {
        let field = |name: &str| {
            text.lines()
                .find_map(|l| l.strip_prefix(name))
                .and_then(|r| r.trim().trim_end_matches("kB").trim().parse::<u64>().ok())
                .map_or(0, |kb| kb.saturating_mul(1024))
        };
        (field("MemTotal:"), field("MemAvailable:"))
    }

    /// The CPU's name, whether it has AVX2, and its physical cores, from a `/proc/cpuinfo` text.
    pub(super) fn cpuinfo(text: &str) -> (String, bool, u32) {
        let mut name = String::new();
        let mut avx2 = false;
        let mut cores = std::collections::BTreeSet::new();
        let mut phys = String::new();
        for l in text.lines() {
            let Some((k, v)) = l.split_once(':') else {
                continue;
            };
            let (k, v) = (k.trim(), v.trim());
            match k {
                "model name" if name.is_empty() => name = v.to_string(),
                "flags" => avx2 |= v.split_whitespace().any(|f| f == "avx2"),
                "physical id" => phys = v.to_string(),
                "core id" => {
                    cores.insert((phys.clone(), v.to_string()));
                }
                _ => {}
            }
        }
        (name, avx2, cores.len() as u32)
    }

    /// The memory limit of this process's cgroup (v2), if it has one.
    fn cgroup_limit() -> Option<u64> {
        let cg = std::fs::read_to_string("/proc/self/cgroup").ok()?;
        let path = cg.lines().find_map(|l| l.strip_prefix("0::"))?;
        let v = std::fs::read_to_string(format!("/sys/fs/cgroup{path}/memory.max")).ok()?;
        v.trim().parse().ok()
    }

    pub(super) fn read(disk_free: u64) -> Machine {
        let (mut total, mut avail) =
            meminfo(&std::fs::read_to_string("/proc/meminfo").unwrap_or_default());
        if let Some(limit) = cgroup_limit()
            && limit < total
        {
            avail = avail.min(limit);
            total = limit;
        }
        let (cpu, avx2, cores) =
            cpuinfo(&std::fs::read_to_string("/proc/cpuinfo").unwrap_or_default());
        let threads = std::thread::available_parallelism()
            .map(|n| n.get() as u32)
            .unwrap_or(1);
        Machine {
            os: "linux".into(),
            arch: std::env::consts::ARCH.into(),
            cpu,
            cores: if cores == 0 {
                threads
            } else {
                cores.min(threads)
            },
            threads,
            avx2,
            memory: total,
            available: avail,
            disk_free,
        }
    }

    #[cfg(test)]
    mod tests {
        use super::*;

        #[test]
        fn proc_files_are_read() {
            let (t, a) = meminfo(
                "MemTotal:       32768000 kB\nMemFree: 1 kB\nMemAvailable:   16384000 kB\n",
            );
            assert_eq!((t, a), (32_768_000 * 1024, 16_384_000 * 1024));
            let cpu = "processor\t: 0\nmodel name\t: AMD EPYC-Rome Processor\nphysical id\t: 0\ncore id\t\t: 0\nflags\t\t: fpu sse avx avx2 fma\n\
                       processor\t: 1\nmodel name\t: AMD EPYC-Rome Processor\nphysical id\t: 0\ncore id\t\t: 0\nflags\t\t: fpu avx2\n\
                       processor\t: 2\nmodel name\t: AMD EPYC-Rome Processor\nphysical id\t: 0\ncore id\t\t: 1\nflags\t\t: fpu avx2\n";
            assert_eq!(cpuinfo(cpu), ("AMD EPYC-Rome Processor".into(), true, 2));
            assert!(!cpuinfo("flags : sse sse2 avx\n").1);
            // This machine reads as something.
            let m = read(0);
            assert!(m.memory > 0 && m.threads > 0, "{m:?}");
        }
    }
}

#[cfg(target_os = "macos")]
mod macos {
    use super::Machine;

    pub(super) fn read(disk_free: u64) -> Machine {
        use antenna_sys::darwin::{sysctl_string, sysctl_u64};
        let memory = sysctl_u64("hw.memsize").unwrap_or(0);
        // The share of memory the kernel considers available (0–100), the figure memory pressure is judged by.
        let level = sysctl_u64("kern.memorystatus_level").unwrap_or(50).min(100);
        let threads = sysctl_u64("hw.ncpu").unwrap_or(1) as u32;
        let cores = sysctl_u64("hw.perflevel0.physicalcpu")
            .or_else(|_| sysctl_u64("hw.physicalcpu"))
            .unwrap_or(u64::from(threads)) as u32;
        let cpu = sysctl_string("machdep.cpu.brand_string").unwrap_or_default();
        let arch = if sysctl_u64("hw.optional.arm64").unwrap_or(0) == 1 {
            "aarch64"
        } else {
            "x86_64"
        };
        let avx2 = arch == "x86_64" && sysctl_u64("hw.optional.avx2_0").unwrap_or(0) == 1;
        Machine {
            os: "macos".into(),
            arch: arch.into(),
            cpu,
            cores,
            threads,
            avx2,
            memory,
            available: memory / 100 * level,
            disk_free,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use antenna_proto::models::Catalog;

    fn machine(os: &str, arch: &str, cpu: &str, gib: u64, avail_gib: u64, avx2: bool) -> Machine {
        Machine {
            os: os.into(),
            arch: arch.into(),
            cpu: cpu.into(),
            cores: 8,
            threads: 8,
            avx2,
            memory: gib * GIB,
            available: avail_gib * GIB,
            disk_free: 100 * GIB,
        }
    }

    fn fits(m: &Machine) -> Vec<String> {
        let c = Catalog::builtin().unwrap();
        let ms: Vec<&CatalogModel> = c.models.iter().collect();
        assess(m, &ms, 0).into_iter().map(|(f, _, _)| f).collect()
    }

    /// The table of `docs/LOCAL-ASSISTANT.md` §2.2, on made-up machines with plenty of free memory.
    #[test]
    fn the_recommendation_follows_the_machine_class() {
        let cases = [
            // Apple silicon M2 or newer, 16 GB: the 9B.
            (
                machine("macos", "aarch64", "Apple M2", 16, 15, false),
                ["fits", "fits", "recommended"],
            ),
            (
                machine("macos", "aarch64", "Apple M4 Pro", 24, 20, false),
                ["fits", "fits", "recommended"],
            ),
            // M1 with 16 GB: the 4B; the 9B is slow on an M1 (68 GB/s) but fits an M1 Pro (200 GB/s).
            (
                machine("macos", "aarch64", "Apple M1", 16, 15, false),
                ["fits", "recommended", "slow"],
            ),
            (
                machine("macos", "aarch64", "Apple M1 Pro", 16, 15, false),
                ["fits", "recommended", "fits"],
            ),
            // 8 GB Macs: the 2B; the 4B fits half of 8 GB only at Metal's size, and the 9B does not.
            (
                machine("macos", "aarch64", "Apple M3", 8, 7, false),
                ["recommended", "fits", "too_big"],
            ),
            // An Intel Mac: the 2B (CPU only).
            (
                machine(
                    "macos",
                    "x86_64",
                    "Intel(R) Core(TM) i7-8569U",
                    16,
                    15,
                    true,
                ),
                ["recommended", "fits", "too_big"],
            ),
            // x86-64 with AVX2 and 32 GB (this build server): the 4B.
            (
                machine("linux", "x86_64", "AMD EPYC-Rome Processor", 32, 24, true),
                ["fits", "recommended", "slow"],
            ),
            // x86-64 with 16 GB: the 4B fits the 8 GB budget at the CPU's size; the 9B does not.
            (
                machine("linux", "x86_64", "AMD Ryzen 7 7840U", 16, 14, true),
                ["fits", "recommended", "too_big"],
            ),
        ];
        for (m, want) in cases {
            assert_eq!(fits(&m), want, "{m:?}");
        }
    }

    #[test]
    fn small_or_old_machines_run_no_model() {
        let m = machine("linux", "x86_64", "Old CPU", 16, 15, false);
        assert_eq!(fits(&m), ["unsupported"; 3]);
        let m = machine("linux", "x86_64", "Small", 4, 3, true);
        assert_eq!(fits(&m), ["unsupported"; 3]);
        assert!(m.tier().unwrap_err().contains("8 GB"));
    }

    #[test]
    fn free_memory_now_can_only_lower_the_recommendation() {
        // An M2 with 16 GB, but only 5 GB available: the budget is 4 GB, so the 4B instead of the 9B.
        let m = machine("macos", "aarch64", "Apple M2", 16, 5, false);
        assert_eq!(fits(&m), ["fits", "recommended", "too_big"]);
        // Models already loaded count against the budget.
        let m = machine("linux", "x86_64", "AMD EPYC-Rome Processor", 32, 24, true);
        let c = Catalog::builtin().unwrap();
        let ms: Vec<&CatalogModel> = c.models.iter().collect();
        let f: Vec<String> = assess(&m, &ms, 12 * GIB)
            .into_iter()
            .map(|(f, _, _)| f)
            .collect();
        assert_eq!(f, ["recommended", "too_big", "too_big"]);
    }

    #[test]
    fn speed_estimates_follow_the_bandwidth() {
        let m1 = machine("macos", "aarch64", "Apple M1", 16, 15, false);
        let m5 = machine("macos", "aarch64", "Apple M5", 16, 15, false);
        // §2.4: about 42 and 95 tokens/s for the 2B (1.28 GB).
        assert_eq!(m1.est_tokens_per_s(1_280_835_840), Some(42));
        assert_eq!(m5.est_tokens_per_s(1_280_835_840), Some(95));
        assert_eq!(m1.apple_generation(), Some(1));
        let arm_linux = machine("linux", "aarch64", "", 16, 15, false);
        assert_eq!(arm_linux.est_tokens_per_s(1_000_000_000), None);
    }
}
