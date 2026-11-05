<!-- SPDX-License-Identifier: Apache-2.0 -->
# Built-in local assistant and local models (design, experimental)

**Status:** proposal, 2026-10-05; phase 1 (the doctor) built in preview.6 (D-101, D-UI-26); **the first slice of
phase 2 built on 2026-10-06** (the runtime in its sandbox, the catalog, verified downloads, local agents with a
conversation; D-104, D-UI-31; what was built and measured: [§14](#14-as-built-the-first-slice-of-phase-2-2026-10-06)).
Decision entry: D-96 (proposed). Every part of our own design here ships on the experimental track (D-94,
`docs/STACK.md` "Principle: proven technology first").

**The idea** (2026-10-05). Inside Antenna the user downloads a local open-weight model (no account, no API
key), and it appears as one more agent with its own chat. It helps people who are not technical to set up Antenna and
troubleshoot it: it sees the node's status and logs, explains what is wrong in plain words, proposes fixes and helps
connect AI apps and contacts; it can be switched between a chat view and a terminal view. It must not weaken security:
isolated, and every action goes through the owner. Refinements of the same day: the model offered follows the power of
the computer; a curated model catalog plus "add another model"; several models can be installed, each its own agent;
local models can also work for other agents (a stronger agent delegates subtasks to them, on this computer or on
another of the user's devices); such agents carry a truthful "Local" badge; and local models run at full power by
default, with throughput scheduling instead of energy throttling.

**Contents.** [1. Summary](#1-summary) · [2. Research](#2-research) · [3. Architecture](#3-architecture) ·
[4. The doctor](#4-the-doctor-phase-1-no-model) · [5. The assistant's tools](#5-the-assistants-tools) ·
[6. Prompt injection and residual risks](#6-prompt-injection-and-residual-risks) · [7. User interface](#7-user-interface) ·
[8. Local models as workers](#8-local-models-as-workers-for-other-agents) · [9. Scheduling and power](#9-scheduling-and-power) ·
[10. Costs](#10-costs-disk-memory-battery) · [11. Phases](#11-phases) · [12. Open questions](#12-open-questions-for-the-maintainer) ·
[13. Sources](#13-sources) · [14. As built](#14-as-built-the-first-slice-of-phase-2-2026-10-06)

---

## 1. Summary

- **Phase 1 needs no model: a doctor.** Seven deterministic checks (the daemon is down, the keys are locked, the relay
  is unreachable, an AI app's CLI is missing or not on PATH, an app needs a restart, a token is bound elsewhere), each
  with one fix button whose exact action is shown in a consent dialog: the vendor's official installer in a visible
  terminal tab, one PATH line, an app restart, the existing unlock. It helps everyone, on every machine.
- **Runtime: llama.cpp's `llama-server`** (MIT), built by us from a pinned tag without its HTTPS client, shipped inside
  the app, listening on a unix socket, in **its own sandbox** with no network, no daemon socket, no token and one
  model file. Rejected as the base: Ollama (a background service with a registry and cloud features, no unix socket),
  MLX (a Python stack, Apple-only, "not recommended for production"), LM Studio (proprietary), llamafile (needs the
  Xcode tools for Metal).
- **Models: Qwen3.5 in three sizes, chosen by the machine** (Apache-2.0, ungated, the best measured Russian and tool
  use up to 10B): the 9B (5.68 GB) by default on Apple silicon M2 or newer with 16 GB or more, the 4B (2.74 GB) on M1
  and on x86 laptops without a GPU build, the **2B (1.28 GB) as the small fallback** for 8 GB machines; the doctor only
  below that. A curated catalog travels in the signed release manifest; files come from Hugging Face by commit, are
  verified by the manifest's SHA-256 before first use, resume after interruptions, and can be removed. Advanced owners
  can add other models by commit and hash.
- **Connection: an ordinary agent through MCP.** A small loop of ours runs in a second sandbox without network, connects
  through `antenna mcp` with its own token like every agent, and reuses the resident-session machinery (D-93) for
  turns, streaming and interrupts. Each model is its own agent with its own conversation, in a chat view and a terminal
  view of the same session.
- **No authority.** The assistant reads diagnostics (status, findings, filtered log lines, agents, apps, pairing,
  network facts) and can only highlight a fix the doctor itself offers at that moment; the owner clicks, the doctor's
  consent dialog runs it. It has no links, no network, no owner commands. Prompt injection through logs can change
  what it says, not what happens; the residual risks are named in §6.3.
- **Workers (phase 4):** a stronger agent delegates subtasks to local models over links, addressed by name, only from
  contacts the owner names; on one computer through a new, experimental delegation tool. A "Local" badge appears only
  when our daemon launched the runtime itself.
  *Measured 2026-10-06* (Apple M1 Pro, 16 GB, macOS 27): Qwen3.5-9B (MLX 4-bit) under an open coding-agent CLI,
  led step by step on a small iOS game, built and ran an app skeleton but could not implement or debug a 40-line board
  algorithm even with compiler and test output fed back and the algorithm described; a 20B model (gpt-oss-20b, 12 GB)
  would not load next to Xcode. So workers that write code are offered only from the 20–30B class up (≥32 GB unified
  memory, or a 24 GB GPU), with small tasks and machine feedback (compiler, tests) in the loop; smaller models stay
  with the assistant's diagnostics and chat.
- **Full power by default.** The scheduler serves throughput (batch requests to one model, load a second model only if
  both fit, never swap); a Power setting exists but is the owner's choice and never switches by itself.
- **Effort:** about 11–13 weeks for all four phases; phase 1 (about 2 weeks) is useful on its own.

---

## 2. Research

Facts were checked on 2026-10-05 against primary sources (project repositories, release pages, model cards, license
texts, vendor documentation); every row names its source in [§13](#13-sources). **Unverified** marks what we could not
confirm from a primary source. Speeds are estimates from public measurements on other people's machines until our own
runs replace them (CONTRIBUTING principle 6: numbers in docs come from a run).

### 2.1 Runtimes

Release data from the GitHub API, PyPI and crates.io on 2026-10-05; the llama.cpp and Ollama archives were downloaded
and their dependencies, signatures and minimum OS versions read from the binaries. Sizes marked "archive" are
compressed.

| Runtime | License | Latest release | macOS arm64 | Linux x86_64 | API | Unix socket | Tool calling | Fit for a sandbox without network |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| **llama.cpp `llama-server`** | MIT (ggml MIT) | b11405, 2026-10-05 (several builds a day) | 12.0 MB archive; the server and its libraries ≈ 29 MB, Metal shaders built in; only ad-hoc signed | CPU 17.7 MB archive (≈ 42 MB unpacked, 14 CPU variants chosen at run time); Vulkan 31.6 MB; CUDA 13.4: 153 MB + 440 MB runtime | OpenAI `/v1/chat/completions`, Anthropic-style `/v1/messages`, native `/completion` | **yes**: `--host <path>.sock` | yes: the model's Jinja template (`--jinja`, now the default), per-family parsers and an auto-parser, lazy GBNF grammar, `json_schema` | **best:** one process, no telemetry found, `--offline`; built with `LLAMA_OPENSSL=OFF` it has no HTTPS client at all |
| MLX / mlx-lm (`mlx_lm.server`) | MIT | mlx 0.32.3 (2026-09-29), mlx-lm 0.32.0 (2026-10-01, after a 5-month gap) | no binary: Python ≥ 3.11 + `mlx-metal` wheel (42–68 MB) + transformers | CUDA/CPU wheels exist; the server is Mac-oriented | OpenAI-style; its own docs: "not recommended for production" | no (TCP only) | yes, per-family parsers; no constrained decoding in the server | possible on a Mac with the GPU rules, but a whole Python stack to ship and review |
| Ollama | MIT | v0.35.1 (2026-09-29; v0.40.0-rc3 out) | 159.6 MB (universal; bundles `llama-server` and MLX) | 1.44 GB (with CUDA; no CPU-only asset) | native `/api`, OpenAI, Anthropic | no (issues #739, #8072 open) | yes (`tools`) | **poor:** a background service, a model registry and cloud features to switch off, runners over loopback TCP; since v0.30.0 it runs upstream `llama-server` itself |
| llamafile | Apache-2.0 | 0.10.6 (2026-09-15) | one 43.9 MB file (368 MB "full") | same file | OpenAI | unverified | as llama.cpp b10441 | Metal compiles a module at run time and needs the Xcode command-line tools: poor |
| mistral.rs | MIT | v0.9.4 (2026-09-24; crate still 0.8.1) | 48.3 MB archive | CPU 35.9 MB archive | OpenAI, Anthropic | none found (unverified) | yes, grammar-enforced | plausible; a built-in agent (web search, shell) to keep off; essentially one maintainer |
| Apple Foundation Models | part of macOS 26 | macOS 26.0+ | 0 MB (in the OS) | — | Swift API only | — | yes (`Tool` protocol, guided generation) | on-device, but needs Apple Intelligence switched on, an 8,192-token context, and **Russian is not among its languages** |

Briefly, the rest: **LM Studio** is proprietary and its terms forbid redistribution (it stays an AI app the owner can
connect, D-85); **candle** (MIT OR Apache-2.0) is a tensor library without a server, chat templates or tool parsing;
the Rust bindings **`llama-cpp-2`** (0.1.158, "does not follow semver") expose llama.cpp's legacy template engine and,
as far as we could find, not llama-server's Jinja templates and tool-call parsers, which we would have to rebuild
(unverified); **vLLM** is a 315 MB wheel plus torch and CUDA, built for datacenter GPUs; **ONNX Runtime GenAI** has no
Metal path on a Mac and needs ONNX exports of each model.

**Choice: bundle `llama-server`, built by us from a pinned build tag.** It is the only candidate with a documented unix
socket, MIT (compatible with the app's AGPL-3.0-only), the smallest footprint, no telemetry, the strongest tool-calling
and grammar support, and one engine for macOS and Linux; Ollama itself now runs it. We build it in our release
pipeline (macOS arm64 with Metal and the shaders built in; macOS x86_64 CPU only; Linux x86_64 CPU with the run-time
variants; Vulkan and CUDA later and optional), with `LLAMA_OPENSSL=OFF` so the child cannot download anything even if
its sandbox failed, and sign it with the app. Never passed: `--tools` (llama-server now has built-in tools, including
a shell command), its MCP options, `-hf`/`-dr` (its own downloads), `--ui-mcp-proxy`.

Settings that matter to us (server README): `-c` (context), `-ngl` and `--fit` (GPU layers; `--fit` sizes to device
memory and is on by default), `-ctk`/`-ctv` (KV cache type; the docs warn that extreme KV quantization such as `q4_0`
"can substantially degrade the model's tool calling performance", so `q8_0` at most), `--load-mode
auto|mmap|mlock|…` (replaced `--mlock`/`--no-mmap`), `-t`/`-tb` (threads), `-np` (parallel slots), `--cache-ram`.

**Risks of the choice.** Fast churn: flags get renamed (`--mlock` → `--load-mode`) and tool-call parsers change per
model family, so the build is pinned per release and an integration test runs on every upgrade. Ownership: the ggml
team joined Hugging Face on 2026-02-20 ("the project will continue to be 100% open-source and community driven"), and
NVIDIA announced on 2026-09-03 that it will acquire Hugging Face; MIT means a fork stays possible, and our weights are
pinned by hash, not by host (§2.3). Intel Macs have no GPU path. macOS has no hard memory cap (the daemon's watchdog,
D-P-12). **Later options:** an MLX path through `mlx-swift-lm` only if our own measurements show a real gain on Apple
silicon; Apple Foundation Models as a zero-download option for languages it supports; "bring your own Ollama or LM
Studio" stays the existing AI-apps route (outside our sandbox, and labelled so).

### 2.2 Models

Facts from the Hugging Face API and the model cards on 2026-10-05; file sizes are the exact sizes from the repository
`tree` API. Tool-use scores of 2026 small models are **self-reported by their makers**: the Berkeley Function Calling
Leaderboard was last updated 2026-04-12 and lists none of them. Russian is measured independently by MERA 2.0 (overall
score) and its GorillaHard task (tool use in Russian); whether the Qwen3.5 runs there used thinking mode is unverified.

| Model | Released | Parameters | License | Q4_K_M GGUF | Tool use | Russian (MERA 2.0 / GorillaHard) | Notes |
| --- | --- | --- | --- | --- | --- | --- | --- |
| **Qwen3.5-9B** | 2026-03-02 | 9B dense (Gated DeltaNet + attention) | Apache-2.0, not gated | 5.68 GB (`unsloth/Qwen3.5-9B-GGUF`) | native; BFCL-V4 66.1, TAU2 79.1 (self-reported, thinking) | **0.186 / 0.258**, the best measured up to 10B | 201 languages; 262k context; thinks by default, switchable |
| **Qwen3.5-4B** | 2026-03-02 | 4B | Apache-2.0, not gated | 2.74 GB | BFCL-V4 50.3, TAU2 79.9 | 0.093 / 0.136 | thinks by default, switchable |
| **Qwen3.5-2B** | 2026-03-02 | 2.27B | Apache-2.0, not gated | 1.28 GB | BFCL-V4 43.6, TAU2 48.8 | MMMLU 56.9 | non-thinking by default |
| Gemma 4 E4B-it | 2026-04-02 | 4.5B effective (8B with per-layer embeddings) | Apache-2.0, not gated | 4.98 GB (QAT Q4_0 5.15 GB, official) | native; Tau2 42.2 % | 0.170 / 0.209 (non-reasoning) | 140+ languages in pre-training; open llama.cpp issues with its tool calls (#29655, #21547) |
| Gemma 4 E2B-it | 2026-04-02 | 2.3B effective | Apache-2.0 | 3.11 GB | Tau2 24.5 % | 0.099 / 0.052 | larger file than Qwen3.5-4B |
| GigaChat 3.1 Lightning | 2026-03-21 | 10B MoE, 1.8B active | MIT, not gated, official GGUF | 6.47 GB | its own `function_call` format; no public tool benchmark; llama.cpp parsing unverified | Russian-first; MMLU-RU 0.68 (self-reported) | fast for its size (1.8B active) |
| LFM2.5-2.6B | 2026-08-04 | 2.69B | **LFM Open License 1.0**: not OSI; commercial use only below $10M annual revenue | 1.67 GB, official | BFCLv4 56.88 (self-reported) | 0.120 / 0.124 | always thinks |
| Granite 4.2 8B / 3B | 2026-08-25 | 8B / 3B | Apache-2.0, official GGUF | 5.35 / 2.24 GB | BFCL v4 52.4 | **Russian not among its 12 languages** | three reasoning modes |
| Ministral 3 8B / 3B | 2025-12-02 | 8.4B / 3B | Apache-2.0, official GGUF | 5.20 / 2.15 GB | native; no BFCL in the card | Russian not listed | — |
| gpt-oss-20b | 2025-08 | 21B MoE, 3.6B active | Apache-2.0 | MXFP4 only, 12.11 GB | strong; reasoning can only be lowered | — | too big for 16 GB next to the OS and apps |

Excluded: **Llama 3.2 3B** (the repository is gated: an anonymous download gets HTTP 401 `GatedRepo`, which breaks "no
account"; no newer small Llama exists); **tiny-aya** (CC-BY-NC, gated); **Nemotron-3-Nano-4B** (English only); **Phi**
(no Phi-5; Phi-4-mini is from 2025-02); **newer Qwen** (no small Qwen3.6 or 3.8; Qwen3.8 moved to the Qwen Community
License 1.0 with conditions above 100M monthly users, so the Apache-2.0 Qwen3.5 files are the ones to pin).

**Recommendation: one family, three sizes, chosen by the machine.** Qwen3.5 in three sizes gives one tool-call format,
one prompt, one evaluation and one license (Apache-2.0, ungated, so "no account" holds and mirroring is allowed).

| The machine | Recommended | In memory at 8k context (est.) | Why |
| --- | --- | --- | --- |
| Apple silicon M2 or newer, 16 GB or more | **Qwen3.5-9B** Q4_K_M (5.68 GB) | ≈ 6.3–6.6 GB | the default "capable multilingual mid-size" model: the best measured Russian and tool use up to 10B; ≈ 14–21 tokens/s (est.) |
| M1 with 16 GB or more; x86-64 with AVX2 and 16 GB or more (CPU, no GPU build yet) | **Qwen3.5-4B** Q4_K_M (2.74 GB) | ≈ 3.3–3.6 GB | there the 9B misses both speed thresholds (M1 ≈ 9.5 tokens/s and 90 for a prompt; a Zen 4 CPU ≈ 8.6 and 66), so every turn with logs would take half a minute |
| 8 GB machines; Intel Macs | **Qwen3.5-2B** Q4_K_M (1.28 GB): the small fallback | ≈ 1.7–1.9 GB | fits beside the OS, the browser and Antenna; same format and prompts; non-thinking by default. Step up to 4B when about 4.5 GB is free |
| Less than 8 GB, or x86-64 without AVX2 | the doctor only | — | a model would make the computer swap, or run too slowly to help |

Runners-up for our own evaluation in phase 3: **Gemma 4 E4B** (Apache-2.0, strong multilingual; held back by its file
size, weaker Tau2 and open llama.cpp tool-call issues) and **GigaChat 3.1 Lightning** (MIT, Russian-first, fast; its
custom function-call format must first be shown to parse in llama.cpp). Not in the catalog: LFM2.5 (license threshold,
always thinks), Granite 4.2 (no Russian), gpt-oss-20b (a candidate for machines with 32 GB or more later).

**How we run Qwen3.5:** text only (no vision projector file); `-c 8192` always (its default context of 262,144 tokens
would reserve about 8 GiB of KV cache); KV cache `q8_0` at most; **thinking off for tool turns**
(`chat_template_kwargs: {"enable_thinking": false}`), because with thinking on the 9B can put its tool call inside the
thinking block (llama.cpp issue #20837, open); tool arguments constrained by the tools' JSON schema (llama.cpp's lazy
grammar). There is no official Qwen GGUF for these sizes, only community quantizations (unsloth, bartowski,
lmstudio-community): the catalog pins one file by hash, and the runtime is started with **the official chat template
from Qwen's own repository** (`--chat-template-file`, shipped with the release and pinned by hash) instead of the one
embedded by the quantizer, so the quantizer's metadata cannot change how prompts and tools are formatted.

### 2.3 Distribution and verification

Checked live on 2026-10-05:

- **Immutable addresses.** `https://huggingface.co/<repo>/resolve/<commit>/<file>` serves exactly that commit's file
  (the reply carries `X-Repo-Commit`). The catalog stores the commit, never a branch: today `unsloth/Qwen3.5-9B-GGUF` @
  `3885219b6810b007914f3a7950a8d1b469d598a5`, `unsloth/Qwen3.5-4B-GGUF` @ `e87f176479d0855a907a41277aca2f8ee7a09523`,
  `unsloth/Qwen3.5-2B-GGUF` @ `f6d5376be1edb4d416d56da11e5397a961aca8ae`.
- **The hash is published and checkable.** `GET /api/models/<repo>/tree/<commit>` lists each file's `lfs.oid`, which
  is its SHA-256; a `HEAD` on the file gives the same value in `X-Linked-Etag` and the size in `X-Linked-Size`. A
  downloaded file matched its `lfs.oid`. Example: `Qwen3.5-4B-Q4_K_M.gguf` is 2,740,937,888 bytes, SHA-256
  `00fe7986ff5f6b463e62455821146049db6f9313603938a70800d1fb69ef11a4`. **We never trust a hash fetched at run time:**
  the expected SHA-256 and size come from our signed release.
- **Xet storage still serves plain HTTPS with ranges.** These files are on Hugging Face's Xet backend; `resolve` answers
  `302` to a CDN address (`us.aws.cdn.hf.co/xet-bridge-us/…`, CloudFront, `accept-ranges: bytes`), and a `Range`
  request returned `206` with the right `Content-Range`. The redirect carries a token-like parameter of unknown
  lifetime (unverified), so a resumed download resolves the address again first.
- **Limits.** Anonymous clients get 3,000 resolver requests per IP per 5 minutes; a download needs one or two. Gated
  repositories refuse anonymous downloads (401), so the catalog takes only ungated ones.

**The catalog in the signed release.** One file, `packaging/models.json`, lists each model: ID, name, maker, license
(SPDX and the license URL), languages, roles it may take (Assistant, Worker), repository, commit, file name, size,
SHA-256, quantization, default context, KV bytes per token, memory needed at the default context, the chat template
file and its SHA-256, the tool-use rating from our evaluation, and the smallest hardware tier. It is compiled into the
daemon and copied into the release manifest as a new optional field `models[]` (UPDATES §2: readers ignore fields they
do not know, so older versions are unaffected; the manifest stays under its 64 KiB limit). The release tool checks that
both copies are equal. A catalog change rides on a release, tested together with the prompts and tools.

**Download.** The daemon downloads, so closing the window does not stop it. It runs `curl` (as `antenna update` does:
HTTPS only, also for redirects, `--max-filesize` = the catalog size) **inside the agent sandbox** (D-71, D-P-13), with
the hub's hosts (`huggingface.co`, `*.hf.co`) as the CONNECT proxy's allow list and the model folder as the only
writable path. Before it starts: free space ≥ size + 10 % + 1 GB, otherwise "Not enough disk space: free X GB". It
writes `<data>/local/models/<id>.gguf.part`, resumes with a `Range` request (`curl -C -`) after a pause, a network
drop, a window close or a reboot, and re-resolves the address each time. **Verification:** after the last byte the
daemon computes SHA-256 over the file and compares it and the size with the catalog; only then is the file renamed to
`<id>.gguf`, made read-only and allowed to load. A mismatch deletes the file and says so. The verified state is kept
with the file's device, inode, size and modification time; any change means verifying again before the next load.
**Removal** deletes the file and the agent. **From a file:** the same verification applies to a file the owner
provides.

**Owner-added models** ("Add another model", §7.4): only from huggingface.co, only by commit; the expected SHA-256 is
either given by the owner or pinned at the end of the first download (labelled so); the license is the owner's
confirmation.

**Mirroring.** Apache-2.0 and MIT allow redistribution with the license and notices (the Gemma 4 repositories carry no
`LICENSE` file, so a mirror would add the Apache text). Since the hash is pinned, any mirror is safe to read from; a
public mirror is a publication and needs the maintainer's decision (Q-LM6).

### 2.4 Hardware assessment and expected speed

**Reading the hardware without permissions.** The assessment uses only what any unprivileged process may read; it never
prompts, needs no root, reads no other app's data, starts no shell for detection and downloads nothing executable, so
there is nothing for the OS or an antivirus to object to.

| What | macOS | Linux | What the person sees |
| --- | --- | --- | --- |
| Memory | `sysctl hw.memsize`; available memory and pressure from `vm_stat` / `sysctl kern.memorystatus_level` | `/proc/meminfo` (`MemTotal`, `MemAvailable`, `SwapTotal`); a cgroup limit from `/proc/self/cgroup` → `memory.max` (containers, systemd slices) | nothing |
| CPU | `machdep.cpu.brand_string` ("Apple M2 Pro"), `hw.ncpu`, `hw.perflevel0.physicalcpu` (performance cores), `hw.optional.arm64`, `sysctl.proc_translated` (running under Rosetta) | `/proc/cpuinfo` (model, `flags`: `avx2`, `avx512f`, `fma`, `f16c`; physical cores from `core id`), `sched_getaffinity` (CPUs this process may use) | nothing |
| GPU | the Metal device name and its recommended working set (`MTLDevice.recommendedMaxWorkingSetSize`, a public API without an entitlement or prompt), read by running the bundled runtime's `--list-devices` **inside its own sandbox**, which doubles as the probe that Metal works under our profile | `/sys/class/drm/card*/device/vendor` (NVIDIA, AMD, Intel) and, for AMD, `mem_info_vram_total`; informational until a GPU build exists (phase 2 is CPU-only on Linux) | nothing |
| Disk | `statvfs` on the data directory | the same | nothing |
| Power | `pmset -g batt` (on battery or AC) | `/sys/class/power_supply/*/{type,online,status}` | nothing |

Not used: `system_profiler` (slow), `powermetrics` (root), `ioreg` walks, `lspci`, `nvidia-smi`, `dmidecode` (root),
anything that lists other users' processes. A unix socket for the runtime also means no firewall dialog about
incoming connections.

**Recommendation.** The budget for a model is the smaller of half the total memory and the memory available at that
moment minus 1 GB (room for the OS, a browser and Antenna). A catalog model is **recommended** when its memory need at
the default context (weights, KV cache and compute buffers, from the catalog) fits the budget and its expected speed on
this machine (the estimates below, later our measurements) is at least about 10 tokens/s generating and 100 tokens/s
reading a prompt; **slower** when it fits but misses a speed threshold; **not recommended** when it does not fit (the
row says how much it needs). The mark goes to the largest recommended model; the default follows it (§2.2). The
constants are starting points for our own measurements in phase 2.

**Expected speed.** Generation is bounded by memory bandwidth: tokens per second ≤ bandwidth ÷ the model file's size.
Bandwidths (Apple's and the CPU makers' pages): M1 ≈ 68 GB/s, M2 100, M3 100, M3 Pro 150, M4 120, M4 Pro 273, M5 153,
M6 170; a laptop with two channels of DDR5-4800…5600 77–90 GB/s, LPDDR5x-7500 120 GB/s (theoretical peaks).

Measured anchors from public llama.cpp benchmarks (LLaMA-2-7B Q4_0, a 3.83 GB file; other people's machines, not ours):

| Machine | Prompt (tokens/s) | Generation (tokens/s) | Source |
| --- | --- | --- | --- |
| M1 (8 GPU cores) | 118 | 14.2 | llama.cpp discussion #4167 |
| M2 (10 GPU cores) | 180 | 21.9 | #4167 |
| M3 (10 GPU cores) | 187 | 21.3 | #4167 |
| M4 | 221 | 24.1 | #4167 |
| M5 | 723 | 31.9 | #4167 |
| Ryzen 7040 iGPU (780M), Vulkan | 282 | 19.9 | #10879 |
| Ryzen 9 7940HS, CPU only (Mistral-7B Q4_K_M) | 83 | 11.2 | llamafile discussion #450 |

So generation reaches about 80 % of peak bandwidth on Apple silicon and about 55 % on laptop CPUs. Estimates for our
models (est., scaled from these anchors; no measured llama.cpp numbers were found for Intel 12th/13th-generation
laptops, whose column assumes about 42 GB/s effective):

| Generation, tokens/s (est.) | M1 | M2 / M3 | M4 | M5 | Zen 4 CPU | 780M Vulkan | Intel 12/13 CPU |
| --- | --- | --- | --- | --- | --- | --- | --- |
| Qwen3.5-2B (1.28 GB) | 42 | 65 | 72 | 95 | 38 | 59 | 33 |
| Qwen3.5-4B (2.74 GB) | 20 | 30 | 34 | 45 | 18 | 28 | 15 |
| Qwen3.5-9B (5.68 GB) | 9.5 | 14.5 | 16 | 21 | 8.6 | 13 | 7.4 |

| Reading the prompt, tokens/s (est.) | M1 | M2 | M4 | M5 | Zen 4 CPU |
| --- | --- | --- | --- | --- | --- |
| Qwen3.5-4B | ≈ 190 | ≈ 290 | ≈ 355 | ≈ 1,150 | ≈ 150 |
| Qwen3.5-9B | ≈ 90 | ≈ 135 | ≈ 165 | ≈ 540 | ≈ 66 |

**Reading the prompt dominates this use.** A first turn of about 3,000 tokens (instructions, tool definitions, log
lines) on the 9B takes about 33 s on an M1 and 5 s on an M5 (est.). Hence: instructions and tools short (about 1,500
tokens) and kept as a cached prefix by the runtime (only the first turn of a session pays for them), tool results
compact (50 log lines at `WARN` and above, each capped), and the doctor's findings given as codes and facts rather than
raw text. Claims of "90 tokens/s for a 4B model on an M2 MacBook Air" are above the physical ceiling (100 GB/s ÷ 2.74
GB ≈ 37) and are disregarded.

---

## 3. Architecture

### 3.1 Processes and boundaries

```
 Window (owner process)                         antennad (keys, policy, the only authority)
 ├─ chat view ──────── local_say ─────────────▶ │ local sessions: the resident machinery of D-93,
 ├─ terminal view (same session, as text)       │   keyed by (agent, counterpart) instead of by link
 ├─ doctor: window-side checks ─ doctor_report ▶ │ diagnostics: daemon-side checks, findings, fix catalog IDs
 └─ fix buttons → consent → owner action        │ model store: catalog, downloads, verification
                                                 │
                       starts both, holds their lifelines, limits, stops them
                    ┌────────────────────────────┴─────────────────────────────┐
                    ▼                                                          ▼
   Sandbox A: the agent loop                                    Sandbox B: the model runtime
   `antenna local-agent` (our code, Rust)                       `llama-server` (llama.cpp, bundled, pinned)
   ├─ stdin/stdout: turns in, stream-json out (D-93)            ├─ reads: one model file, its own binary
   ├─ child `antenna mcp` → daemon socket                       ├─ listens: a unix socket in its run folder
   │    (agent token, AgentRequest only, D-28 binding)          ├─ no network, no daemon socket, no HOME
   └─ HTTP (OpenAI-compatible) over that unix socket ─────────▶ └─ GPU: Metal on macOS; CPU on Linux (phase 2)
```

- **The daemon stays the only authority** (SPEC §9). It creates the model's agent in the owner flow, starts both
  sandboxed processes, holds their lifelines (D-71: EOF on the supervisor's stdin kills the tree), decides every tool
  call, and keeps the conversation in its encrypted database.
- **Sandbox B (the runtime) has nothing worth stealing and no way out.** It reads one model file and writes nothing but
  its socket. It cannot reach the daemon socket, the network, the owner's files or the agent token. This matters
  because the runtime parses untrusted input in C++: llama.cpp has had memory-safety bugs reachable both from crafted
  model files and from crafted text (§6.3).
- **Sandbox A (the loop) is an ordinary agent.** It holds a token for its own agent and connects through `antenna mcp`,
  so the daemon binds the token to the loop's process tree (D-28) and parses its requests as `AgentRequest`: owner
  commands do not exist for it (CONTRIBUTING "Security rules"). It has no network either (no CONNECT-proxy bridge, unlike a
  wake agent): its only sockets are the daemon's and the runtime's.
- **The window renders, the owner acts.** Fixes are executed by the window (or by `antenna doctor` in a terminal) as
  owner actions with consent, never by the daemon on a model's request (§4.3, §5.3).

### 3.2 Why the loop connects through MCP, not an internal adapter

Three ways to connect a model were considered:

| Way | What it means | Verdict |
| --- | --- | --- |
| **MCP** (chosen) | The loop is an MCP host like Claude Code: it starts `antenna mcp` with its token and turns the server's tools into the runtime's `tools` | One tool surface for every agent: the same wrappers ("external data" notices), the same MCP `instructions` (D-88), the same "no owner API for agents" tests. The binding and policy are the existing ones. The tool list is tailored per agent role by `antenna mcp`, as `instructions` already are, so a small model sees only the few tools it needs |
| Internal adapter, in a separate process | The loop sends `AgentRequest` lines itself | Same boundary, but a second tool surface whose descriptions and data wrappers would drift from MCP's; no gain beyond one process and a JSON-RPC hop that costs milliseconds next to seconds of generation |
| Internal adapter, inside the daemon | The daemon calls the runtime and runs the tool loop itself | Rejected: model-facing parsing would live in the process that holds the keys, and tool calls would not pass the agent boundary (`AgentRequest` parsing), which is our strongest check ("no such command" is stronger than "forbidden") |

The security boundary is the same for the first two (both end in `AgentRequest` under a token bound to the loop's
process tree); MCP wins on having one path. The MCP client is `rmcp`, already in the stack (`docs/STACK.md`).

### 3.3 Why our own loop, and what exactly is new

D-94 asks every decision to say what is new and why nothing existing fits.

- **Reused unchanged:** the runtime (llama.cpp), the weights (published GGUF files), the MCP server and client
  (`antenna mcp`, `rmcp`), the agent token and its binding (D-28, D-86), the sandboxes (D-71 bwrap + Landlock +
  seccomp, D-P-13 Seatbelt), the lifeline and supervisor, the resident session machinery (D-93: turns on stdin,
  stream-json out, interrupt, counters), the signed release manifest (D-82), `curl` for downloads (as `antenna
  update`), the approvals and owner commands for every fix.
- **New, ours, experimental:** (1) the agent loop `antenna local-agent`, about the size of a small module: it reads
  turns, calls the runtime's chat API with the tools, runs the model's tool calls through MCP, and writes Claude Code's
  stream-json subset that `resident.rs` already parses (`system/init`, `assistant` blocks, `result`); (2) the doctor's
  checks and its fix catalog; (3) the diagnostics capability and its read-only agent commands; (4) local sessions
  without a link (keyed by agent and counterpart); (5) the runtime's sandbox profiles (on macOS with GPU access); (6)
  the model catalog, download and hardware assessment; (7) delegation between agents of one node (phase 4).
- **Why not an existing agent CLI.** Claude Code, Codex and goose can drive local models, but they are general coding
  agents: a fixed prompt and tool set of tens of thousands of tokens (about 32,000 for Claude Code, D-93 limit 7), which
  a small model on a laptop CPU reads at tens to a few hundred tokens per second (§2.4), so every turn would start
  with minutes of prompt processing; and they bring shell and file tools we would have to switch off and then prove
  switched off. Our loop needs six to eight read-only tools and a prompt of about 1,500 tokens.

### 3.4 Sandbox B: the runtime

Common to both systems: started by the daemon through the existing supervisor (`antennad --antenna-wake-exec` style:
lifeline on stdin, start gate, a probe from inside before the runtime is `exec`ed); `--clearenv`-style environment
(only what the runtime needs); rlimits (core 0, file size, open files); no access to the daemon socket, the data
directory, HOME, the link folders, the keychain or the clipboard; the model file read-only; the run folder
`<data>/local/run/<agent>/` writable for the socket only. llama-server is started with the flags that close its own
side doors: `--host <run folder>/llm.sock`, `--offline`, `--no-slots` (the slots endpoint, on by default, shows what
each slot is processing), no `--slot-save-path` (no prompt dumps to disk), `--no-webui`, and a random API key per
start passed in the environment (`LLAMA_API_KEY`, never on the command line, where `ps` would show it) and handed to
the loop the same way, so another process that finds the socket gets `401`; plus `--jinja` with
`--chat-template-file` (the official template, §2.2), `--parallel` from the scheduler (§9), `--ctx-size` and
`--threads` from the hardware assessment.

| | Linux (bwrap, the D-71 main mode) | Linux (Landlock fallback) | macOS (Seatbelt, the D-P-13 model) |
| --- | --- | --- | --- |
| Network | empty netns (only `lo`); seccomp denies `connect` altogether (the runtime only listens) | Landlock: no TCP connect or bind; seccomp: no UDP and no `connect` at all, which also closes the same-user unix sockets Landlock leaves open before ABI 9 (D-71 limits), the daemon socket among them | `(deny network*)` except listening on the one socket path |
| Files | tmpfs root, system libraries, the runtime binary and the model file read-only, the run folder rw | Landlock: the same lists | `(deny default)`, the same lists; plus what dyld needs (D-P-15) |
| GPU | none in phase 2 (CPU build); Vulkan or CUDA later needs `/dev/dri` or `/dev/nvidia*` bound in, a separate review | none | **Metal needs IOKit user clients for the GPU and Metal's compiler service**; the exact `iokit-open` and `mach-lookup` rules are found on a real Mac and kept as narrow as dyld's (unverified until then) |
| Memory | `RLIMIT_DATA` (on Linux it counts private writable mappings, so the KV cache and buffers, not the read-only mapped model file) | same | the daemon's footprint watchdog (D-P-12); whether Metal buffers count in `phys_footprint` is to be measured |
| CPU | `--threads`; `nice` per power setting (§9); no cgroups yet (D-71 limit) | same | `--threads`; QoS per power setting |
| Probe before start | listing `/` fails, `connect()` to a public address fails, the daemon socket is absent | same | as D-P-13, plus: Metal device opens (otherwise CPU fallback, reported) |

If the probe or the profile fails, the runtime does not start (`sandbox_unavailable`), as for every other sandbox
(CONTRIBUTING principle 4). A "Run without GPU" setting removes the GPU rules on macOS for owners who prefer the smaller
kernel surface at the cost of speed (§6.3 R4).

### 3.5 Sandbox A: the loop

The wake agent's sandbox (D-71, D-P-13) with three differences: **no CONNECT-proxy bridge** (no network at all; the
loop talks only to the daemon socket and the runtime socket); **no HOME files** of the owner (no agent CLI login to
read); **no transcript on disk**: the conversation is kept by the daemon in the encrypted database and replayed into
the loop's context when it restarts, which closes for local agents the plain-text transcript limit of resident agents
(D-93 limit 1). Its run folder holds nothing but scratch.

### 3.6 Lifecycle

- **Start:** on the first turn (as D-93), the daemon starts sandbox B, waits for the runtime's health endpoint, then
  sandbox A. Loading a model takes seconds when its file is in the page cache, longer from disk; the chat shows
  "Loading the model…".
- **Idle:** the runtime stays loaded while it is used. It is unloaded after an idle period that depends on memory, not
  energy (§9: 30 minutes by default; "keep loaded" for dedicated machines; immediately when another model needs the
  memory). The next turn loads it again.
- **Stop:** `lock` stops both (the daemon's state is sealed; a loop must not outlive it); the window closing does not
  stop them when the daemon outlives the window (macOS LaunchAgent, systemd service).
- **Crash:** as D-93: three crashes within 10 minutes and the session waits for the next turn; the chat shows the
  reason from the runtime's last stderr lines (filtered, §6.2).

---

## 4. The doctor (phase 1, no model)

A deterministic doctor comes first and works without any model (maintainer decision 2026-10-05, "fix-it buttons
instead of support"). When Antenna finds a known problem, it says what is wrong and offers one button that fixes it,
with consent. The assistant (phase 3) only explains on top of it and highlights the doctor's own fixes.

### 4.1 Checks

| Code | What is wrong | Who checks, how | Facts shown |
| --- | --- | --- | --- |
| `daemon_down` | The background service is not running | Window: the control socket does not answer and the daemon process is gone (`DaemonHost`) | Exit status, the last lines of `antennad.log` (macOS `~/Library/Logs/Antenna/antennad.log`, Linux `$XDG_STATE_HOME/antenna/antennad.log` or the user journal), filtered |
| `keys_locked` | The node is locked (after a reboot or `lock`) | Daemon `status.state == "locked"` | Since when, if known |
| `relay_unreachable` | Links of levels 1–2 (relay only, Q-1) cannot connect | Daemon: the link endpoints' relay connection state (iroh's home relay and net report), plus a DNS lookup and a TCP connect to the relay host from the daemon | Which links are affected; which step failed (name lookup, connection, TLS); whether LAN could serve level 3+ contacts |
| `ai_cli_missing` | An AI app's command-line program is not installed (seen live: `claude: command not found` on a clean Mac) | Window: the app's binaries are in neither PATH nor the usual folders (`ai_apps.dart`, `agentSearchDirs`) when the owner chose that app (Connect, Code mode, Start agent) | The app, the folders searched |
| `ai_cli_not_on_path` | The program is installed but the terminal does not find it | Window: the binary is in a known folder (`~/.local/bin`, npm's global `bin`, `/opt/homebrew/bin`…) that the login shell's PATH lacks (the `-ilc` PATH probe of `cli_install.dart`) | The folder, the shell and its profile file |
| `app_restart_needed` | Connect wrote an app's MCP file after the running app had started, so the app has not read it | Window: the app's process started before the file's modification time, and its agent is "Waiting for the app" (D-89) | The app, when it started, when the file changed |
| `token_bound_elsewhere` | The app's agent token is bound to another live process, so the app is refused (`token_bound`, D-28) | Daemon `agent_list`: `bound_alive`, `bound_comm`, `bound_pid`; window: which app expected it (ChatGPT and Codex share one file, D-85 limit) | The process that holds it, since when |
| `screen_recording_missing` | macOS has not given this build of the window Screen Recording, so a screenshot for an agent would show only the desktop (after an update the switch in System Settings may belong to the previous build, D-UI-41) | Window, macOS only: `CGPreflightScreenCaptureAccess()` through the Runner; a problem once a screenshot met it, worth knowing before | The steps (remove with −, add with +, restart) and the button that opens the pane |

Later candidates, once the first seven work: `sandbox_unavailable` (no bwrap, or AppArmor blocks user namespaces on
Ubuntu 24.04: a guide only, since the fix is system-level), `version_mismatch` (window and daemon from different
releases after an interrupted update: restart the daemon), `quarantined_app` (macOS quarantine attribute left on the
app after a manual copy, USER-GUIDE "Install"), `disk_low`.

### 4.2 Fixes

Every fix is fixed text in the app, reviewed with the release; nothing in a fix comes from a model, a log line or a
contact. The consent dialog shows exactly what will happen before the click.

| Finding | Fix | How it runs | Authentication |
| --- | --- | --- | --- |
| `daemon_down` | **Start Antenna's background service** | `DaemonHost.start()`: macOS LaunchAgent, Linux the user service or the window's child | none (starting is safe); a second failure shows the log and a "Copy a diagnostic report" button (facts only, no secrets) |
| `keys_locked` | **Unlock** | the existing unlock / sign-in prompt (`unlock`, `login {hold}`) | the owner password |
| `relay_unreachable` | **Try again now**; **Use the local network** when level 3+ contacts are on this network | `diagnose {retry: true}` (the daemon reconnects its links at once); `lan_set` (D-77) | none (a retry only does sooner what the daemon does anyway) / the owner password for LAN, as today |
| `ai_cli_missing` | **Install <app> with its official installer** | a Code-mode terminal tab runs the vendor's documented command, visibly: Claude Code `curl -fsSL https://claude.ai/install.sh \| bash`; Codex `curl -fsSL https://chatgpt.com/codex/install.sh \| sh`; Gemini CLI `npm install -g @google/gemini-cli` when `npm` exists, otherwise the guide (§13) | consent: the dialog shows the command, the vendor's domain and the vendor's page; no sudo, ever |
| `ai_cli_not_on_path` | **Add <folder> to PATH** | one line appended to the shell profile, after a backup, exactly as "Install the antenna command" does today (D-58, `cli_install.dart`) | consent: the line and the file are shown |
| `app_restart_needed` | **Restart <app>** | macOS: quit by bundle ID through Apple Events, then open it again (`open -b`); Linux and CLI apps: the guide ("close and reopen", "open a new terminal") | consent: "unsaved work in <app> may be lost"; never a forced kill |
| `token_bound_elsewhere` | **Quit <process>**, or **Give <app> its own agent** | quit as above (macOS app) or SIGTERM after re-checking the process identity (`p_uniqueid` / start time, as the daemon's binding does); a separate agent through Connect | consent / the owner password (it creates an agent) |

The doctor re-runs a finding's check right before its fix runs; if the problem is gone, nothing runs. After a fix it
runs the check again and says whether it worked.

### 4.3 Where it shows

- **In place, where the person looks** (the lesson of D-UI-15): Connect and Start agent show the finding and its
  button inside their own dialog; the sign-in screen shows `daemon_down` and `keys_locked`; a conversation with a
  level 1–2 contact shows `relay_unreachable`.
- **Settings → Troubleshoot:** every current finding with its button, "Check again", and "Copy a diagnostic report".
- **A dot on the navigation** while a finding stands that the owner has not seen.
- **CLI:** `antenna doctor` prints the daemon's findings and the CLI's own (`daemon_down`, the `antenna` command's
  PATH); `antenna doctor --fix <code>` runs the daemon-side fixes after a `y/N` prompt (owner only: an agent's token
  gets `unknown_command`, like every owner command). App fixes stay in the window, which knows the apps.

### 4.4 Interfaces (proposed, `x-control/7`, only additions)

*Built in preview.6 (D-101, D-UI-26):* phase 1 needs no new command. The daemon adds two read-only facts to replies the
owner already reads (`contacts[].transport.relay`, the refused MCP host in `agent_list`), `antenna doctor` composes its
findings from `status`, `contacts` and `agent_list`, and the window's Check panel runs the app checks itself. The
commands below stay for phase 3, when the assistant needs the findings.

- `diagnose {retry?}` → `diagnosis {findings: [{id, code, severity, facts, fixes: [fix_code]}], checked_ms}`: the
  daemon-side checks. Owner: no password, as `status`; `retry: true` (owner only) also reconnects the links now.
  Agents: only with the `diagnostics` capability (§5.1), and without `retry`.
- `doctor_report {findings}` (owner only): the window posts its own findings (app checks), which the daemon keeps in
  memory, so the assistant and `antenna doctor` see one list. Findings carry codes, app IDs and paths, never file
  contents.
- Fix execution is not a new daemon command: daemon-side fixes are the existing owner commands (`unlock`, `lan_set`,
  `agent_add`…) and the owner's `retry`; window-side fixes are window actions.

### 4.5 Phase 1 tests (in §11 too)

Unit tests per check on a fake file system, a fake PATH probe, a fake process list and fake daemon replies; widget
tests of every finding's banner and consent dialog (the exact command and file shown); live tests: daemon stopped →
started; locked → unlocked; a token bound to another MCP host → "Quit" frees it; relay stopped (the local test relay,
D-36) → `relay_unreachable` → relay back → cleared; the shell profile edit with a backup, byte for byte, idempotent;
negative tests: a path with quotes or a newline in a finding is refused, not quoted into a command; an agent token
gets `unknown_command` for the fix path; on a real Mac: the Claude Code installer in a terminal tab, the PATH line on
zsh, restarting Claude Desktop by bundle ID.

---

## 5. The assistant's tools

### 5.1 The `diagnostics` capability

A new per-agent setting, owner only (`agent_set {diagnostics: true}` with the password, or set at model install):
the agent may call the read-only diagnostics commands below. **The daemon refuses it for an agent with links in scope,
and refuses links for an agent that has it** (`denied`). Diagnostics show facts about every link (labels, states,
network facts); an agent that could also send to a contact would turn them into a cross-link leak (D-29). With no
links, a diagnostics agent can send nothing to anyone: `send`, `share_file` and the rest have no contact to name.

### 5.2 Read-only tools

MCP tools that `antenna mcp` lists for a diagnostics agent (and only these, with short descriptions written for small
models), each backed by an `AgentRequest` the daemon answers from its own state:

| Tool | Returns | Filtering |
| --- | --- | --- |
| `node_status` | `status` + versions of the window and daemon, lock state, owner session present, sandbox kind (`wake_list.sandbox`) | — |
| `doctor_findings` | the merged findings (§4.4) with their codes and fix codes | — |
| `recent_log` | the daemon's last log lines, by default 50 at `WARN` and above (up to 200) | each line at most 300 characters, control characters removed, contact-supplied fields quoted and marked (§6.2) |
| `agents_status` | agents with status chips' facts (D-89: bound process name, alive, last seen, token file present, `everyone`, tasks), never tokens | — |
| `ai_apps` | the window's last app scan: installed, found where, connected, which config file (path only) | from `doctor_report` |
| `pairing_state` | open invites and pairings: stage, age, error code; never invite links or codes | — |
| `network_facts` | relay reachability per step, LAN on/off, how many links connected directly or through the relay | no IP addresses: they are not needed to explain, and the owner sees them in the card |
| `help` | a section of the bundled user guide by topic, so explanations quote our own text instead of guessing | static text shipped with the release |
| `propose_fix` | `{finding_id, fix_code, note}` → `proposed` or `no_such_finding` | see §5.3 |

### 5.3 `propose_fix`: the assistant's buttons are a subset of the doctor's

The assistant cannot run anything. `propose_fix` only asks the window to show one of the doctor's own buttons in the
chat. The daemon accepts a proposal only when `finding_id` is a current finding and `fix_code` is one of that
finding's fixes; it sends the owner an event `{kind: "fix_proposal", agent, finding_id, fix_code, note}`. The window
draws the card from its own catalog (the doctor's title and description), shows the model's `note` below it as a quote
labelled "the assistant's note", and on click opens **the doctor's** consent dialog after re-running the check. So
at click time an assistant button can do exactly what the doctor's own button would do at that moment, and nothing
else. Free-text commands in the assistant's replies are shown as text without a copy or run button (§7.2).

### 5.4 What the assistant never gets

Owner commands (absent from `AgentRequest`, the MCP server and the agent CLI, as for every agent); links, contacts,
inbox, history, files; the network; tokens, invite links, codes, passwords; file contents of other apps' configs; the
ability to start, stop or configure other agents. New owner commands added for this feature (`local_say`,
`local_session`, `model_install`, `model_remove`, `doctor_report`, the `diagnostics` setting) get a test in each of the
"no owner API for agents" checks (CLI, protocol, MCP).

---

## 6. Prompt injection and residual risks

### 6.1 Stance

Everything a tool returns is data, never instructions; the assistant has no authority, so a successful injection can
change what the assistant **says**, not what **happens**. The daemon decides every call; the window shows only the
doctor's fixes; the owner clicks.

### 6.2 Where hostile text can come from

| Source | Example | Handling |
| --- | --- | --- |
| Contact-supplied strings in the daemon log | the `reason` of a peer's rejection is logged as received (`link …: peer rejected a message: {reason}`, `node.rs`) | `recent_log` quotes and marks such fields as "from the contact", caps length; the log line format changes to put contact text in a quoted field |
| Agent names announced by contacts | validated `[A-Za-z0-9._-]{1,64}` (D-75) | short and constrained; still data |
| Third-party program output | an agent CLI's stderr tail in the wake journal, a vendor installer's output | the same caps and stripping; installer output is shown to the owner in the terminal, not given to the model unless the owner asks |
| Text the owner pastes | an error copied from a website | the owner's own turn; the same lack of authority applies |
| The weights | a backdoored or "sleeper" model, especially an owner-added one (§7.4) | no authority; owner-added models are labelled; the runtime is sandboxed |
| Other apps' configuration files | a crafted `mcp.json` | the doctor reports facts about them (present, parsed, has an `antenna` entry), never contents |

The window and the loop strip C0 and C1 control characters (except line breaks and tabs) from every tool result and
every model reply before display.

### 6.3 Residual risks, exactly

- **R1 · Misleading prose.** Injected or simply wrong text can tell the owner something false ("your contact's keys
  changed, remove the link", "install this other program"). The assistant cannot act, but the owner can. Mitigation:
  fixes only through the doctor's buttons, no copy button on model-written commands, the chat's standing line "The
  assistant can be wrong. Antenna never asks you to paste commands from a chat.", the first-run explanation. **Not
  closed:** social engineering of the owner through the assistant's words.
- **R2 · Steering among legitimate fixes.** Injected text can make the assistant highlight a real but unneeded fix
  (restart an app and lose unsaved work; issue a new token and disconnect an app). Bounded to what the doctor offers
  at that moment, each with its own consent text. **Not closed:** nuisance to the owner's own setup; no escalation.
- **R3 · Exploiting the runtime.** llama.cpp has had memory-safety bugs reachable from crafted model files (GGUF
  parser, CVE-2025-53630 and its bypass GHSA-3p4r-fq3f-q74v) and from crafted **text** (tokenizer heap overflow,
  GHSA-7rxv-5jhh-j6xx), so a hostile log line could in principle reach code execution in the runtime. Contained by
  sandbox B (no network, no daemon socket, no token, no files). **Not closed:** a compromised runtime can feed the loop
  false completions (R1, R2) and burn CPU; in the Landlock-only fallback the D-71 limits apply (unix sockets of the
  same user, signals). Mitigation over time: the runtime is pinned per release and updated with releases; owner-added
  models are flagged.
- **R4 · GPU drivers as attack surface (macOS).** Metal needs IOKit user clients for the GPU in sandbox B's profile, a
  large kernel surface. Reachable only after R3. **Not closed;** "Run without GPU" removes it for those who prefer.
- **R5 · Same-user processes.** A process of the same user that finds the runtime socket gets `401` without the
  per-start API key; but the key lives in the environments of the runtime and the loop, which the same user can read
  on Linux (`/proc/<pid>/environ`), so this is a speed bump, not a wall: such a process could use the model (CPU time).
  With `--no-slots` and no slot save path it cannot read other conversations. Everything in the assistant's context is
  something the same user can already read (logs, `status`) or the owner's own data. Same boundary as CONTROL §11.
- **R6 · Poisoned memory.** An injected instruction stays in the session until the context ends. Mitigation: "New
  conversation" (a reset; taint as D-93 item 8), short contexts. **Not closed** within a session.
- **R7 · Downloads.** A compromised mirror or CDN serves other bytes: the SHA-256 from the signed manifest refuses them
  and the partial file is deleted (fail closed). **Not closed:** denial of service; and for an owner-added model
  without a hash, the first download is trusted as is (labelled "pinned on first download").
- **R8 · Exfiltration.** Closed by construction: no network in either sandbox, no links, a renderer that never fetches
  a URL (no remote images, no link previews), proposals made of closed codes. What remains is the owner copying text
  out.
- **R9 · Terminal control sequences.** Model text could drive a terminal (clipboard writes by OSC 52, hyperlinks by OSC
  8, the window's own private exit-code sequence of Code mode, CM.5). Closed by stripping control characters before
  the terminal view writes anything.
- **R10 · Worker mode (phase 4).** Tasks from other agents are data; output goes back as a send through the same
  policy and scanner. **Not closed:** a worker can be made to give a delegator wrong answers, like any model.

---

## 7. User interface

### 7.1 Where local models appear

- **Agents → Local models** (tagged Experimental): the installed models, each with its "Local" badge, state (not
  loaded, loading, ready, working, N waiting), memory in use, file size, license, and its role (Assistant, Worker,
  Chat only); "Add a model" opens the catalog.
- **Chats:** each local model agent has its own conversation, pinned in a section "On this computer" above the
  contacts. The first installed model is named **Assistant** by default and has the diagnostics capability; the owner
  can rename it.
- **Code mode:** each local model can have a tab in the agents' dock showing its terminal view (§7.2).

### 7.2 Chat view and terminal view

One session, two renderings; switching keeps the context because the session lives in the daemon.

- **Chat view:** the owner's bubbles and the model's; activity lines ("Read the last 50 warnings of the daemon log",
  "Checked the AI apps"); fix cards from `propose_fix` (§5.3); "What it read" expands the raw tool results; the
  conversation language follows the window's. Rendering is minimal Markdown: emphasis, lists, inline code and code
  blocks; links are plain text unless they point to our own guide; no images, no HTML. Code blocks written by the model
  have no copy or run button and say "Written by the assistant; Antenna has not checked it."
- **Terminal view:** the same session drawn by the window's terminal widget (`xterm`, D-UI-16) as plain text: tool
  calls and their raw results, replies, and fixes as numbered lines (`[1] Restart Claude Desktop`, press 1 or click),
  which open the same consent dialog. All text is stripped of control characters first (R9). For a headless node,
  `antenna local chat <agent>` gives the same view in a real terminal (phase 3), with daemon-side fixes through
  `antenna doctor --fix`.

### 7.3 The download flow

1. Agents → Local models → **Set up the assistant** (or **Add a model**).
2. **This computer:** "Apple M2 · 16 GB memory · 210 GB free" and what that means (§2.4).
3. **The catalog** (§7.4) with "Recommended for your computer" on one row; each row: name and maker, download size,
   memory needed, languages, license, tool-use rating from our evaluation, expected speed here ("about 10 words a
   second").
4. **Confirm:** "Download 5.7 GB from Hugging Face (huggingface.co). After the download the model runs only on this
   computer, without internet access. License: Apache-2.0 (read)." The owner password once: it creates the agent.
5. **Progress:** size, speed, time left; Pause, Resume, Cancel. The daemon downloads, so closing the window does not
   stop it and a restart resumes it.
6. **Verify:** "Checking the file…" then "Verified" or "The file does not match what this version of Antenna expects.
   It was deleted." (nothing half-verified is ever loaded).
7. **Ready:** the conversation opens with three suggestions: "Check my setup", "Connect an AI app", "Why don't my
   messages arrive?".

**Remove:** a model's menu → Remove: the file is deleted and its agent removed (the password, as `agent_remove`).
**From a file:** "Install a model from a file…" verifies a file the owner already has (a USB stick, or one received
over Antenna and accepted from quarantine) against the same catalog hash: the signature decides, not the channel
(the update lesson of D-82).

### 7.4 The catalog and "Add another model"

The catalog is curated per release (§2.3): name, maker, license, file size per quantization, memory needed, languages,
tool-use rating (our evaluation, §11 phase 3), and the "Recommended for your computer" mark from the hardware
assessment (§2.4). Rows that will not fit say why ("needs 12 GB of memory, this Mac has 8").

**Add another model** (advanced, behind a disclosure): a Hugging Face repository, a revision (a commit; a branch name is
resolved to its commit and shown), a GGUF file, and either the expected SHA-256 or the box "Pin the file I download now"
(trust on first download), plus a box confirming the owner has read the model's license. Such a model is labelled
"Added by you · not reviewed by Antenna" everywhere; it gets the same sandbox; whether it may have the diagnostics
capability is the owner's choice (it is off by default for added models).

Several models can be installed; each is its own agent with its own conversation. Only what fits in memory is loaded
at once (§9).

### 7.5 The "Local" badge

- **What it says:** "Local · runs on this Mac" (Linux: "on this computer"), with the tooltip: "Antenna runs this model
  on this computer, with no internet access. Its replies go only where its conversation goes."
- **When it shows:** only when **this daemon** launched the runtime itself: the agent was created by the model flow
  (`model_install`), which records `runtime: "local"` and the catalog ID with the agent, and the daemon starts the
  runtime in sandbox B. Never from a name, an app scan or a contact's word: the same rule as vendor marks for a
  contact's agent (D-UI-18).
- **Where:** the agent's row, its conversation header, the thread chip and the author line of its messages.
- **Another of the owner's devices** (phase 4, needs "My devices"): "Local · runs on <device>", only over a link the
  owner has marked as their own device, from a field in that node's signed agent announcement (PROTOCOL §21). A
  contact's agents never get the badge.
- **Wording.** The proposed "data does not leave your devices" is true of the model's own processing, but a local
  model's reply can go into a conversation with a cloud agent; the tooltip above says what is always true. Open
  question Q-LM4.

---

## 8. Local models as workers for other agents

### 8.1 What it is

A stronger agent (Claude Code on this computer or on the owner's server) hands a subtask to a local model on one of the
owner's machines: summarize these files, classify these messages, draft a reply, extract fields. The work stays on the
owner's hardware and costs no tokens.

### 8.2 Across devices: composed from what exists

On the machine with the model, a local model agent in the **Worker** role is a resident agent (D-93) whose program is
our loop with that model:

- **Addressing (D-90, D-91):** the delegating agent addresses the worker by name over the link (`to: {agent:
  "qwen3.5-9b"}`); the worker's `everyone` is off, so it reads only what is addressed to it.
- **Task authority (D-88):** the worker takes tasks only from contacts the owner names; **default nobody** for workers
  (unlike the level-5 default of D-88), because the owner's machine pays for the work. Typically the owner names their
  own server or other device.
- **Turns (D-93):** a task is a turn; the loop itself (not the model) reads the referenced messages through
  `read_inbox` and puts them into the model's context as the tool result they are, marked task or data, so a small
  model does not have to make that call. The reply streams back (D-63…D-66) through the same policy and scanner as any
  send. The session key is the thread (agent, link, counterpart agent), as D-93 already foresaw.
- **"My devices":** the badge "runs on <device>" (§7.5) and listing remote workers in one place wait for own-device
  links (a planned direction: the owner's nodes linked as the same owner). Delegation itself works over any link
  without it.

### 8.3 On the same computer: a new, experimental path

Agents of one node have no link between them. Proposed: an MCP tool `ask_local_model {model, prompt, max_tokens?}`
for agents the owner allows (`agent_set {delegates_to: […]}`, the password, since it widens what the agent can do).
The daemon turns the call into a turn of the worker's session **keyed by the delegating agent**, waits, and returns
the text as the tool result, marked as the output of local model X. Flow rules: that session holds only this
delegator's data and carries its taint (D-29); it has no links; its output returns only to that delegator. Nothing
crosses between delegators because their sessions are separate. This is a new local channel between agents, so it
gets its own threat analysis, negative tests (a delegator that is not allowed; reading another delegator's session;
an agent with diagnostics as a worker, refused) and the Experimental label.

*Built since* (2026-10-06, D-132, CONTROL §32, experimental): a general local route between two agents of one computer
that the owner connects on the agent map. A message over it carries its writer's taint and local data label into the
reader; a write down, a secret and a chain longer than 8 messages are refused. Local-model agents are not ends of such a
route yet (the daemon decides whom they answer); `ask_local_model` stays the proposal for them.

### 8.4 Roles do not mix

A local model agent is an **Assistant** (diagnostics, no links), a **Worker** (links or delegators, no diagnostics) or
**Chat only**. The daemon enforces it (§5.1). One model file can back several agents; each has its own sessions.

---

## 9. Scheduling and power

**Maintainer decision (2026-10-05): no throttling by default.** People who install a local model want it at full
power, and professionals will run Antenna on Mac minis and servers for this. The scheduler exists for throughput, not
for energy.

### 9.1 Why concurrency is limited by memory, with numbers

Generating a token reads every weight of the model once, so generation speed is bounded by memory bandwidth:
tokens per second ≤ bandwidth ÷ bytes read per token (about the model file's size at 4-bit quantization).

Examples (est.: ceilings are bandwidth ÷ file size, expected values about 80 % of them on Apple silicon, §2.4):

| Situation | What happens |
| --- | --- |
| One request, Qwen3.5-9B on an M2 (100 GB/s) | ceiling 100 ÷ 5.68 ≈ 17.6 tokens/s, about 14.5 expected |
| Two **different** models at once on that M2 (the 9B and the 4B) | they share the 100 GB/s: roughly 7 and 15 tokens/s instead of 14.5 and 30. The total is the same; every answer takes about twice as long |
| **One** model, four requests batched (`--parallel 4`) | the 9B's weights are read once per step for all four, so together they approach four times one request's rate while each slows a little (compute grows, bandwidth use does not); to be measured with `llama-batched-bench` in phase 2. The price is a KV cache per request: for Qwen3.5 32 KiB per token, so 256 MiB per 8k slot and +1 GiB for four; for a model like Granite 4.2 8B (160 KiB per token) the same four slots would cost +5 GiB |
| Model and caches exceed free memory | the 5.68 GB file is re-read from the SSD at 3–7 GB/s for every token: 0.5–1.2 tokens/s, 15–30 times slower, and every other app stalls with it |
| A Mac mini with M4 Pro and 64 GB (273 GB/s) | the 9B's ceiling is about 48 tokens/s; there is room for it with eight slots and a second model loaded beside it |

So the scheduler keeps to three rules:

1. **One copy of a model, several requests batched.** Requests to the same model run as parallel slots of one runtime
   (`--parallel N`, continuous batching): the weights are read once per step for all of them, so the total grows with
   N while each request slows only a little. The cost is a KV cache per slot, so N is what fits in the memory budget
   (§10).
2. **Different models only if both fit.** Two different models generating at once split the bandwidth: each runs at
   about half speed, the total is unchanged, and the latency of both doubles. A second model is loaded only when both
   fit in memory with headroom; otherwise its requests wait in the queue.
3. **Never swap.** When model and caches exceed free memory, weights are read back from the disk at a few GB/s instead
   of the memory's 100–800 GB/s, and generation falls to a crawl (tens of times slower) while the whole computer
   stutters. The scheduler queues instead.

The queue: per runtime, first in first out, with the owner's own chat ahead of delegated work (a person waiting comes
first), round-robin between delegators, a cap per delegator (8 waiting tasks) and per task (`max_tokens`, a time
limit), counters in the agent's card (as D-93: turns, tokens, time).

### 9.2 The optional power setting

Settings → Local models → **Power:** **Maximum** (default) · Balanced · Battery saver. Chosen by the owner, never
switched by Antenna.

| Setting | Threads | Priority | Delegated work | Unload after idle |
| --- | --- | --- | --- | --- |
| Maximum (default) | all performance cores | normal | runs whenever it fits | 30 minutes (or "keep loaded") |
| Balanced | half of the performance cores | lower (`nice` 10; macOS utility QoS) | runs | 10 minutes |
| Battery saver | 2 | background (macOS background QoS, efficiency cores) | waits while on battery | 2 minutes |

On battery with Maximum, the Local models card may show one line ("On battery: local models run at full power; you can
choose Balanced in Settings"). It changes nothing by itself.

---

## 10. Costs: disk, memory, battery

| Cost | Amount |
| --- | --- |
| The runtime inside the app | about +12 MB compressed on macOS (≈ 29 MB installed), +18 MB on Linux (≈ 42 MB installed), from the upstream build of the same tag; our own build will be measured |
| Model files (Q4_K_M; Q8_0 in brackets) | Qwen3.5-2B 1.28 GB (2.01), 4B 2.74 GB (4.48), 9B 5.68 GB (9.53) |
| Disk during a download | the `.part` file becomes the model file (no second copy) plus the 1 GB headroom we require |
| Memory while a model is loaded, 8k context (est.) | 2B ≈ 1.7–1.9 GB, 4B ≈ 3.3–3.6 GB, 9B ≈ 6.3–6.6 GB; each further 8k slot +256 MiB (Qwen3.5) |
| Memory when unloaded | none: the processes are stopped; the file may stay in the OS page cache, which the OS reclaims at will |
| The doctor | nothing measurable: a few file reads and `status` calls when it runs |
| CPU and GPU | full while reading a prompt and generating; nothing while idle (processes blocked on their input, as D-93 measured for resident agents) |
| Battery | to be measured in phase 2 on a real Mac (energy per typical answer); no throttling by default (§9) |

**8 GB machines.** macOS and a browser take most of 8 GB. The 2B model (≈ 1.8 GB in use) fits beside them; the 4B is
offered only when about 4.5 GB is free when the owner installs it; the 9B is shown as "needs 16 GB". With less than 8 GB
or a CPU without AVX2 no model is recommended; the doctor works on every machine, with or without a model. When memory
runs low during use (macOS memory pressure, Linux `/proc/pressure/memory`), the conversation shows one line, "Memory is
low: answers will be slow. Close other apps or choose a smaller model.", and changes nothing by itself.

---

## 11. Phases

Rough effort is for one developer who knows the codebase, excluding waiting for a real Mac. Every phase ends with its
TROUBLESHOOTING entries and an independent security review before it leaves the experimental label.

### Phase 1 · The doctor and its fix buttons (no model)

- **Scope:** `diagnose` and `doctor_report` (§4.4), the relay reachability facts in the daemon; the window's doctor
  (`lib/state/doctor.dart`, checks in `lib/host`), the seven checks and their fixes (§4.1–§4.2), the in-place banners,
  Settings → Troubleshoot, the diagnostic report; `antenna doctor [--fix]`.
- **Tests:** §4.5; plus the "no owner API for agents" tests for `doctor_report`; golden frames for each banner (light,
  dark, Russian).
- **Security review:** running vendor installers (the command is ours, the script is the vendor's: consent and
  visibility), shell profile edits (quoting, backup, idempotence), quitting or signalling processes (identity re-check,
  no forced kill), Apple Events quoting, that the diagnostic report carries no secrets.
- **Effort:** about 2 weeks (daemon 3 days, window 6 days, CLI 1 day, real-Mac pass 2 days).

### Phase 2 · Runtime, catalog, download, chat (experimental)

- **Scope:** llama-server built from a pinned tag in our release pipeline (macOS arm64 with Metal, Linux x86_64 CPU
  with runtime CPU-feature variants) and shipped inside the app; `packaging/models.json` compiled in and carried in
  the signed manifest (§2.3); hardware assessment (§2.4); the download manager; sandboxes A and B (§3.4–§3.5); local
  sessions keyed by agent (D-93 machinery); the loop `antenna local-agent` with the `help` tool only; the window's
  Local models card, catalog, download flow, chat view, terminal view, the Local badge; Power setting and scheduler
  (§9).
- **Tests:** catalog and manifest signature (a changed hash fails); download resumed after a kill and after a restart;
  a wrong byte → refused and deleted; disk full; the sandbox probes (sandbox B cannot read `~/.ssh`, cannot connect
  anywhere, cannot see the daemon socket; sandbox A cannot connect anywhere); the lifeline kills both; idle unload;
  interrupt; memory limit; two models that do not fit → the second waits; golden frames. **Measurements** recorded in
  this document: load time, prompt processing and generation speed, memory, on the build server CPU and on real Macs
  (8 GB and 16 GB).
- **Security review:** the new Seatbelt rules for Metal; the runtime's build provenance (pinned tag, our build, signed
  with the app); the download path and its host allowlist; GGUF parsing exposure; the loop's parsing of runtime
  output.
- **Effort:** about 4 weeks.

### Phase 3 · The assistant uses the doctor (experimental)

- **Scope:** the `diagnostics` capability and its exclusivity with links (§5.1); the read-only commands and MCP tools
  (§5.2); `propose_fix` and fix cards (§5.3); rendering rules (§7.2); loop limits (at most 8 tool calls per turn, an
  output cap, a time limit); `antenna local chat`.
- **Tests:** an evaluation set of about 40 scripted troubleshooting cases on fake daemon states, in English and
  Russian, scored per catalog model (the right finding explained, the right fix proposed, no invented facts): a model
  enters the catalog with the diagnostics role only above a threshold set from these runs; an adversarial corpus
  (instructions in a peer's rejection reason, in an agent name, in installer output; terminal escape sequences;
  Markdown image and link exfiltration attempts; very long lines), each with a negative control; the diagnostics
  agent cannot send, read links or call owner commands (CLI, protocol, MCP).
- **Security review:** prompt injection (§6), tool authority, rendering, an exfiltration analysis.
- **Effort:** about 2–3 weeks.

### Phase 4 · Local models as workers (experimental)

- **Scope:** the Worker role over links (§8.2: default nobody, addressing, resident turns keyed by thread); same-node
  delegation (§8.3); the queue across delegators (§9.1); the remote Local badge once own-device links exist.
- **Tests:** delegation between two daemons with a fake model and with a real small model; refusals (not allowed, a
  diagnostics agent as a worker, a delegator reading another's session); the queue's fairness and the owner's
  priority; nothing loaded beyond the memory budget.
- **Security review:** the new local channel between agents (§8.3), cross-delegator isolation, the badge's truth.
- **Effort:** about 3–4 weeks, plus "My devices" for the remote badge.

**Total:** about 11–13 weeks of focused work for all four phases; phase 1 is useful on its own and comes first.

---

## 12. Open questions for the maintainer

- **Q-LM1 · The name.** The user guide already calls every AI agent an "assistant". Keep **Assistant** for the first
  local model (with the Local badge), or call it **Helper** to tell it apart?
- **Q-LM2 · Running vendor installers.** The `ai_cli_missing` fix runs the vendor's own `curl … | sh` installer in a
  visible terminal tab after consent (§4.2). Acceptable, or only open the vendor's page?
- **Q-LM3 · The default model.** One button "Set up the assistant" that downloads the model recommended for this
  computer (size and license shown), with the catalog one click away; or always the catalog first? On 8 GB machines:
  offer the small model, or the doctor only, by default?
- **Q-LM4 · The badge's words.** "Local · runs on this Mac" with the tooltip of §7.5, or the proposed "data does
  not leave your devices", which is not true once a local model replies into a conversation with a cloud agent?
- **Q-LM5 · Bundle the runtime** in every release (about +12 MB on macOS, +18 MB on Linux, compressed) so executable
  code arrives only through signed releases, or download it on demand with the first model?
- **Q-LM6 · Mirroring weights.** Rely on Hugging Face plus "install from a file", or also mirror the catalog's files
  where licenses allow (GitHub release files are limited to 2 GiB each), given that Hugging Face is changing owner?
- **Q-LM7 · Diagnostics for other agents.** Only local models may get the `diagnostics` capability, or may the owner
  give it to a cloud agent too (its provider would then see the node's logs)?
- **Q-LM8 · Workers' default.** A worker takes tasks from nobody until the owner names contacts (§8.2), unlike D-88's
  level-5 default. Confirm.
- **Q-LM9 · Same-computer delegation** (§8.3, a new channel between agents): wanted in phase 4, or only delegation over
  links?
- **Q-LM10 · Keeping a model loaded.** 30 minutes after the last use by default (memory, not energy), or keep it loaded
  as long as the daemon runs?
- **Q-LM11 · Platforms in phase 2.** Linux CPU only first (Vulkan and CUDA later), and Intel Macs CPU only with the
  small model: acceptable?

---

## 13. Sources

Checked 2026-10-05.

**Runtimes.** llama.cpp: https://github.com/ggml-org/llama.cpp (release b11405:
https://github.com/ggml-org/llama.cpp/releases/tag/b11405), server options and the unix socket:
https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md and `tools/server/server-http.cpp`, function
calling: https://github.com/ggml-org/llama.cpp/blob/master/docs/function-calling.md, the auto-parser:
https://github.com/ggml-org/llama.cpp/blob/master/docs/autoparser.md, building:
https://github.com/ggml-org/llama.cpp/blob/master/docs/build.md; ggml joins Hugging Face:
https://huggingface.co/blog/ggml-joins-hf; NVIDIA to acquire Hugging Face:
https://blogs.nvidia.com/blog/nvidia-to-acquire-hugging-face/. MLX: https://github.com/ml-explore/mlx,
https://github.com/ml-explore/mlx-lm (server: `mlx_lm/SERVER.md`), https://pypi.org/project/mlx-lm/,
https://github.com/ml-explore/mlx-swift-lm. Ollama: https://github.com/ollama/ollama (v0.35.1, v0.30.0 "upstream
llama-server", `llm/server.go`, `envconfig/config.go`, issues #739 and #8072, `docs/faq.mdx`). llamafile:
https://github.com/mozilla-ai/llamafile/releases/tag/0.10.6. LM Studio terms: https://lmstudio.ai/app-terms. mistral.rs:
https://github.com/EricLBuehler/mistral.rs/releases/tag/v0.9.4. candle: https://crates.io/crates/candle-core.
`llama-cpp-2`: https://crates.io/crates/llama-cpp-2. vLLM: https://pypi.org/project/vllm/. ONNX Runtime GenAI:
https://github.com/microsoft/onnxruntime-genai/releases/tag/v0.17.0. Apple Foundation Models: availability
https://developer.apple.com/documentation/foundationmodels/systemlanguagemodel/availability-swift.enum/unavailablereason,
languages https://support.apple.com/en-us/121115.

**Sandboxes.** Seatbelt and Metal (the `AGXDeviceUserClient` and `com.apple.MTLCompilerService` rules, third-party,
to be verified): https://github.com/todesking/cc-sandbox-gpu-mac, https://github.com/openai/codex/issues/17644,
https://github.com/anthropics/sandbox-runtime/issues/560; bubblewrap's private loopback:
https://github.com/containers/bubblewrap/blob/main/network.c; CUDA in bwrap: https://github.com/openai/codex/issues/19676;
Landlock ABI levels: https://docs.kernel.org/userspace-api/landlock.html.

**Security advisories (llama.cpp).** Tokenizer heap overflow from crafted text:
https://github.com/ggml-org/llama.cpp/security/advisories/GHSA-7rxv-5jhh-j6xx; GGUF parser integer overflow
(CVE-2025-53630): https://github.com/ggml-org/llama.cpp/security/advisories/GHSA-vgg9-87g3-85w8 and its bypass
https://github.com/ggml-org/llama.cpp/security/advisories/GHSA-3p4r-fq3f-q74v; GGUF tensor parsing:
https://github.com/ggml-org/llama.cpp/security/advisories/GHSA-96jg-mvhq-q7q7.

**Vendor installers (the doctor's fixes).** Claude Code: https://code.claude.com/docs/en/setup (native installer,
launcher `~/.local/bin/claude`, signed release manifest); Codex: https://learn.chatgpt.com/docs/codex/cli; Gemini CLI:
https://github.com/google-gemini/gemini-cli (npm, Homebrew).

**Models.** Qwen3.5: https://huggingface.co/Qwen/Qwen3.5-9B, https://huggingface.co/Qwen/Qwen3.5-4B,
https://huggingface.co/Qwen/Qwen3.5-2B (chat template:
https://huggingface.co/Qwen/Qwen3.5-4B/blob/main/chat_template.jinja), GGUF files
https://huggingface.co/unsloth/Qwen3.5-9B-GGUF, https://huggingface.co/unsloth/Qwen3.5-4B-GGUF,
https://huggingface.co/unsloth/Qwen3.5-2B-GGUF; release report
https://www.marktechpost.com/2026/03/02/alibaba-just-released-qwen-3-5-small-models-a-family-of-0-8b-to-9b-parameters-built-for-on-device-applications/.
Gemma 4: https://blog.google/innovation-and-ai/technology/developers-tools/gemma-4/,
https://ai.google.dev/gemma/docs/gemma_4_license, https://huggingface.co/google/gemma-4-E4B-it,
https://huggingface.co/unsloth/gemma-4-E4B-it-GGUF, https://huggingface.co/google/gemma-4-E4B-it-qat-q4_0-gguf.
GigaChat 3.1: https://huggingface.co/ai-sage/GigaChat3.1-10B-A1.8B,
https://huggingface.co/ai-sage/GigaChat3.1-10B-A1.8B-GGUF. LFM2.5: https://www.liquid.ai/blog/lfm2-5-2-6b,
https://huggingface.co/LiquidAI/LFM2.5-2.6B/blob/main/LICENSE, https://huggingface.co/LiquidAI/LFM2.5-8B-A1B. Granite 4.2:
https://huggingface.co/blog/ibm-granite/granite-4-2, https://huggingface.co/ibm-granite/granite-4.2-8b,
https://huggingface.co/ibm-granite/granite-4.2-8b-GGUF. Ministral 3: https://mistral.ai/news/mistral-3/. gpt-oss-20b:
https://huggingface.co/ggml-org/gpt-oss-20b-GGUF. Nemotron-3-Nano-4B:
https://huggingface.co/nvidia/NVIDIA-Nemotron-3-Nano-4B-BF16. Qwen Community License (Qwen3.8):
https://huggingface.co/Qwen/Qwen3.8-Flash-Next/blob/main/LICENSE. Berkeley Function Calling Leaderboard:
https://gorilla.cs.berkeley.edu/leaderboard.html. MERA 2.0: https://mera.a-ai.ru/en/text/leaderboard, GorillaHard:
https://huggingface.co/datasets/MERA-evaluation/GorillaHard. llama.cpp tool-call issues:
https://github.com/ggml-org/llama.cpp/issues/20837, https://github.com/ggml-org/llama.cpp/issues/29655,
https://github.com/ggml-org/llama.cpp/issues/21547.

**Distribution.** Hugging Face Xet and its HTTPS bridge: https://huggingface.co/docs/hub/xet/legacy-git-lfs; rate limits:
https://huggingface.co/docs/hub/rate-limits; the `tree` API and `resolve` headers were checked directly.

**Speed and bandwidth.** llama.cpp on Apple silicon: https://github.com/ggml-org/llama.cpp/discussions/4167; Vulkan:
https://github.com/ggml-org/llama.cpp/discussions/10879; CPU: https://github.com/mozilla-ai/llamafile/discussions/450,
https://community.frame.work/t/llm-benchmark-amd-7840u/49351. Apple bandwidths:
https://www.apple.com/newsroom/2022/06/apple-unveils-m2-with-breakthrough-performance-and-capabilities/,
https://support.apple.com/en-us/117735, https://support.apple.com/en-us/117736,
https://www.apple.com/newsroom/2024/10/apple-introduces-m4-pro-and-m4-max/,
https://www.apple.com/newsroom/2025/10/apple-unleashes-m5-the-next-big-leap-in-ai-performance-for-apple-silicon/,
https://www.apple.com/newsroom/2026/08/apple-introduces-m6-and-m5-ultra-for-a-big-leap-in-performance-and-ai-compute/.
Laptop memory: https://www.intel.com/content/www/us/en/products/sku/226254/intel-core-i71260p-processor-18m-cache-up-to-4-70-ghz/specifications.html,
https://www.amd.com/en/products/processors/laptop/ryzen/7000-series/amd-ryzen-7-7840u.html (via a search snippet; the
page timed out).

---

## 14. As built: the first slice of phase 2 (2026-10-06)

Decision entry: D-104 (and D-UI-31 for the window). What phase 2 (§11) asked for and what this slice does:

| Phase 2 item | In this slice |
| --- | --- |
| llama-server from a pinned tag, without its HTTPS client, in our pipeline | ✓ `packaging/llama/build.sh`: v0.6.0 (`d812350`), source archive pinned by SHA-256; `LLAMA_OPENSSL=OFF`, `LLAMA_SUBPROCESS=OFF` (no tools, MCP servers or router), no web UI; Linux x86_64 CPU variants, macOS arm64 Metal; shipped as `llama/` next to `antennad` |
| Sandbox B (the runtime) | ✓ the agent sandbox in listen-only mode (§3.4 as designed, Linux checked in bwrap and Landlock modes); macOS: run on a real Mac (M1 Pro, macOS 27, 2026-10-06), Metal used under Seatbelt, nothing blocked (see the Mac table below) |
| Sandbox A (the loop) | ✓ `antenna local-agent` in the agent sandbox with no network, only the runtime's run folder; bound to its agent (D-28) |
| The catalog in the signed manifest | ✓ compiled in (`packaging/models.json`, `antenna_proto::models`) and copied into the manifest's optional `models[]` by `antenna-release manifest --models`; `verify --models` checks the two are equal (`packaging/release-linux.sh` does both) |
| Hardware assessment | ✓ (§2.4 rules; Linux and macOS readers; no GPU facts yet) |
| Download manager | ✓ resumable, sandboxed `curl`, host allowlist, disk check, SHA-256 before first use, re-check after a change, removal, from a file; no Pause/Resume buttons (an interrupted download resumes by itself; Cancel removes) |
| Local sessions keyed by agent | ✓ keyed by (agent, counterpart); the owner is the only counterpart now |
| The loop with the `help` tool only | the loop without any tool: chat only. `help` comes with phase 3's tools, through `antenna mcp` |
| Local models card, catalog, download flow, chat view, Local badge | ✓ (D-UI-31); the terminal view and "Install from a file…" in the window are not built (the CLI and the protocol have `from_file`) |
| Power setting and scheduler | the scheduler's rules of §9 (one copy with slots, a second model only if both fit, never swap, idle unload); no Power setting |

**Deviations from the design, and why.**
1. **Models and agents are separate** (decision of 2026-10-06: several local agents at once, each an
   ordinary agent). Several agents may run on one model, each with its own conversation; removing a model keeps its
   agents. The design's §7.3 "removal deletes the file and the agent" assumed one agent per model.
2. **No tools in the loop yet.** The loop does not start `antenna mcp` in this slice, so it holds no usable token;
   the boundary is already the final one (an agent's process tree, bound), and tools are added inside it.
3. **`model_install` needs an owner session, not the password** (§7.3 step 4 asked for the password "because it
   creates the agent"): here the agent is created separately, with the password (`local_agent_add`).
4. **Memory figures.** The CPU build repacks the weights for AVX2, so a model in use takes about 1.6 times its file
   (measured below); the catalog keeps a measured CPU figure and an estimated Metal figure per model.

**How the daemon and the loop talk** (our own protocol on the loop's stdin and stdout, the subset of Claude Code's
stream-json that `resident.rs`/`wake.rs` already parse): in, an optional `{"type":"antenna_context","system":…,
"messages":[…]}` (the conversation from the database), then `{"type":"user","message":{"role":"user","content":…}}`
per turn and `{"type":"control_request","request":{"subtype":"interrupt"}}`; out, `system/init`, `stream_event` text
deltas, the whole `assistant` message and a `result` (`success`, `interrupted`, `error`) with the runtime's numbers in
`antenna_usage`. The loop keeps what fits the context (instructions first, then the latest messages) and leaves room
for a 1,024-token reply.

**Measurements** (Linux build server: AMD EPYC-Rome, 16 vCPUs without SMT, 32 GB, shared with other work; llama.cpp
v0.6.0 CPU build with `-c 8192 -np 1`; prompts of about 800 tokens; the server's own `timings`):

| What | Qwen3.5-2B (1.28 GB) | Qwen3.5-4B (2.74 GB) | Qwen3.5-9B (5.68 GB) |
| --- | --- | --- | --- |
| Download from Hugging Face (one `curl`, this server) | 11.4 s | 23.7 s | 46.9 s |
| SHA-256 of the file matches the hub's `lfs.oid` | yes | yes | yes |
| Load from the page cache | 2.3 s | 3.2 s | 8.7 s |
| Memory in use (RSS) after load / after two turns | 1.98 / 2.10 GB | 4.43 / 4.62 GB | 8.65 / 8.88 GB |
| Reading the prompt, 8 threads, unsandboxed | 163 tokens/s | 69 tokens/s | 38 tokens/s |
| Generating, 8 threads, unsandboxed | 32–33 tokens/s | 16 tokens/s | 9.5 tokens/s |

On a real Mac (Apple M1 Pro, 16 GB, macOS 27.0.1, Metal, the runtime and the loop in their Seatbelt sandboxes,
2026-10-06):

| What | Qwen3.5-4B | Qwen3.5-9B |
| --- | --- | --- |
| Download (`curl`, home connection) | 130 s | 289 s |
| Load in the sandbox | 5.8 s | 6.7 s |
| Generating | 36–42 tokens/s | 22–24 tokens/s |
| Reading the prompt | 46–179 tokens/s | 38–111 tokens/s |
| The system's free memory while loaded (an upper bound: it includes the page cache of the model file, which macOS can reclaim) | 82 % → 53 % (≈ 4.6 GB) | 75 % → 35 % (≈ 6.4 GB) |

The process's own footprint stays under 0.9 GB: Metal maps the weights outside it, so placement uses an estimate of the
Metal allocation (`memory_metal` in `packaging/models.json`: 3.6 GB for the 4B, 6.6 GB for the 9B); the free-memory drop
above is an upper bound for it, not the value itself (the 4B must still fit an 8 GB Mac's 4 GB budget). Seatbelt blocked nothing the runtime needs, but it denies the
Metal shader cache (`…/C/com.apple.metal/…`), so the shaders are compiled again on every load (part of the load
time); a narrow read rule for that cache is a follow-up. Answers in Russian were correct with both models.
| **In the sandbox, through the daemon and the loop** (8 threads, `real_llama_server_answers_in_its_sandbox`) | prompt 90–138 tokens/s, reply 26–31 tokens/s | — | — |
| Each further 8k slot | +0.12 GB (4 slots: 2.34 GB) | — | — |

The sandbox costs nothing measurable: the same numbers inside and outside, at the same load. Threads matter on a shared
machine: with 16 threads at a load average of 11 the 2B generated 4.5 tokens/s (sandboxed) and 10–18 (unsandboxed),
against about 30 with 8; hence half the threads on a machine without SMT (D-104 item 5). The second turn of a
conversation reads only its new tokens (the runtime's prompt cache: 810 of 814 tokens cached). The install from a file
(copy and SHA-256 of 1.28 GB) takes 3.5 s; the first turn after an install, with the model loading, 3.5–9.6 s
depending on the load. A Russian question was answered in Russian by the 2B. Not measured yet: a Mac (Metal, the
Seatbelt profile with the GPU rules, an 8 GB and a 16 GB machine), the 4B and 9B through the daemon, battery use.
