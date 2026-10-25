# Running a local 9B LLM on an 8GB laptop GPU — and wiring it into an AI agent harness

[中文版](README.md) · [Full write-up (Chinese)](docs/deployment-story.md)

A working setup for serving **Qwen3.5-9B** on a laptop with a single
**RTX 4060 Laptop 8GB** GPU, then plugging it into **DSH** (a DeepSeek-Harness-based
agent framework) as a secondary model.

Everything lives in one folder. Delete `D:\local-llm` and it's gone — nothing is
installed elsewhere on the system.

> **TL;DR** — 40 tok/s generation, 64K context, 6.5 GB VRAM, ~30 min to set up.
> Reliable at extraction and instruction-following; unreliable at anything requiring
> global consistency. Use it as a sidekick, not as the main agent.

---

## Results

| Metric | Value |
|---|---|
| Runtime | llama.cpp b11871 (portable CUDA 12.4 build) |
| Models | Qwen3.5-9B-Q4_K_M (5.29 GB) + Qwen3.5-4B-Q4_K_M (2.55 GB) |
| Generation | **40.2 tok/s** (9B) / 47.9 tok/s (4B) |
| Prefill | 1679–2708 tok/s |
| Context | **65,536** tokens → 6511 MiB / 8188 MiB VRAM |
| Disk | 8.97 GB total (633 MB runtime + 7.84 GB weights) |
| Setup time | ~30 min, of which ~25 min is downloading |

Tested on: RTX 4060 Laptop 8GB (55 W TGP) · Intel Core Ultra 9 185H · 16 GB DDR5 · Windows 11.

### Context-window scan (9B, only `-c` changed)

| Context | VRAM | Headroom | Verdict |
|---|---|---|---|
| 16,384 | 5453 MiB | 2735 MiB | too conservative |
| **65,536** | **6511 MiB** | 1689 MiB | ✅ sweet spot |
| 131,072 | 7843 MiB | 345 MiB | too tight |

64K costs only ~1 GB more than 16K — this generation of models uses sliding-window
attention, so long context is cheap.

---

## Why llama.cpp and not Ollama

Measured from the target machine (China, no proxy for domestic sources):

| Source | Speed | Note |
|---|---|---|
| github.com (direct) | 31 KB/s | 1.5 GB → 14 hours |
| github.com (via proxy) | 654 KB/s | still 40 min |
| ollama.com CDN | 144–658 KB/s | |
| registry.ollama.ai | 614 KB/s | model blobs come from here too |
| **modelscope.cn (ModelScope)** | **3.8 → 24 MB/s** | domestic, fast |

The Ollama route needs ~5.1 GB from overseas sources ≈ 2.3 hours.
The llama.cpp route is 633 MB (multi-threaded mirror download) + weights from
ModelScope ≈ 30 minutes. That single measurement decided the architecture.

**Measure your network before choosing a stack.** It saved more time than every
optimization that followed.

---

## Quick start

```powershell
# 1. Lay out the directory
New-Item -ItemType Directory -Force D:\local-llm\{bin,models\gguf,logs,scripts,config,bench,docs}

# 2. Runtime — multi-threaded download from a GitHub mirror
.\scripts\download-parallel.ps1 `
  -Url 'https://gh-proxy.com/https://github.com/ggml-org/llama.cpp/releases/download/b11871/llama-b11871-bin-win-cuda-12.4-x64.zip' `
  -OutFile .\bin\llama-cuda-12.4.zip -Threads 8
.\scripts\download-parallel.ps1 `
  -Url 'https://gh-proxy.com/https://github.com/ggml-org/llama.cpp/releases/download/b11871/cudart-llama-bin-win-cuda-12.4-x64.zip' `
  -OutFile .\bin\cudart-cuda-12.4.zip -Threads 8

# 3. Extract both (cudart is NOT optional) and verify CUDA is visible
Expand-Archive .\bin\llama-cuda-12.4.zip -Dest .\bin\llama -Force
Expand-Archive .\bin\cudart-cuda-12.4.zip -Dest .\bin\llama -Force
.\bin\llama\llama-server.exe --list-devices     # must print CUDA0, not (none)

# 4. Weights from ModelScope
.\scripts\pull-model.ps1 -Repo unsloth/Qwen3.5-9B-GGUF -File Qwen3.5-9B-Q4_K_M.gguf

# 5. Serve
.\scripts\start.ps1          # 127.0.0.1:8080, model id "qwen3.5-9b", 64K context

# 6. Measure
.\scripts\bench.ps1 -LongPrompt
.\scripts\stress.ps1
```

### The one launch command that matters

```
llama-server.exe -m Qwen3.5-9B-Q4_K_M.gguf -a qwen3.5-9b `
  --host 127.0.0.1 --port 8080 `
  -ngl 99 -c 65536 -np 1 -t 8 `
  -fa on -ctk q8_0 -ctv q8_0 `
  --jinja --reasoning off --reasoning-format deepseek --reasoning-budget 256
```

`--jinja` is mandatory for tool calling. `--reasoning off` matters because small
thinking models will otherwise burn the whole token budget reasoning and return an
empty answer.

---

## Stress test results (agent-oriented)

| Test | Result |
|---|---|
| **Multi-step tool chain** | ✅ closed the loop in 3 steps (`list_files → read_file → answer`), found the key error in tool output |
| **Context accumulation (8 turns)** | ✅ prompt grew 31 → 503 tok (16×), latency only 1.17 → 1.57 s → **KV cache reuse works, long chats don't get slower** |
| **Instruction retention** | ✅ 5/5 turns (a constraint set in turn 1 survived to turn 6) |
| **Tool error recovery** | ✅ gave up retrying after 2 steps and explained, no infinite loop |
| **Long-document extraction** | ✅ **22,174 tok** input, 13.67 s, all four fields correct |
| **Concurrency (`-np 1`)** | ⚠️ queues, doesn't parallelize: single 1.08 s, two concurrent 2.74 s |
| **Factual extraction (9 files)** | ✅ 9/9 numbers correct |
| **Global-consistency task (sorting)** | ❌ got every number right, then **sorted them wrong** |
| **Multi-step tools + complex schema** | ❌ fails |

> The sorting failure is the most instructive one: it read 9 files, counted lines
> perfectly (9/9), then produced a list ordered incorrectly — `download-parallel.ps1`
> (100 lines) listed *after* `compare.ps1` (96 lines). Data right, conclusion wrong.

**Positioning**: reliable at "fetch data, follow instructions"; unreliable at
"maintain global consistency". Put it at the **end** of a pipeline (read / extract /
translate / rewrite / summarize), not in the middle making coordination decisions.

---

## Wiring into DSH

The `llm-pi-ai` plugin is already mounted in the web profile — nothing to install.

```yaml
# ~/.dsh/settings.yaml
llm-pi-ai:
  providers:
    local-llama:
      displayName: Local Qwen3.5-9B (llama.cpp)
      api: openai-completions
      apiKeyEnv: LOCAL_LLAMA_API_KEY      # ⚠️ required — omitting it silently disables the route
      baseURL: http://127.0.0.1:8080/v1
      compat:
        supportsDeveloperRole: false
        maxTokensField: max_tokens
        supportsReasoningEffort: false
      timeoutMs: 900000
      streamIdleTimeoutMs: 900000
      models:
        - id: qwen3.5-9b
          contextWindow: 65536            # must be <= llama-server's -c
          maxTokens: 8192
```

```yaml
# ~/.dsh/.credentials.yaml  (plaintext, dummy value is fine)
refs:
  LOCAL_LLAMA_API_KEY: local-no-auth
```

Verified: plain chat ✅ · streaming SSE ✅ · `system` role ✅ · tool calls ✅ ·
simple structured output ✅ · **tools + complex schema ❌**.

---

## ⚠️ The most important limitation: long sessions will overflow

**Use the local model in fresh, short sessions only.**

DSH's web profile ships with all three context-compaction plugins disabled, because a
1M-token cloud model doesn't need them. Switch to a 64K local model mid-session and
the history keeps growing unbounded:

```
400: request (254777 tokens) exceeds the available context size (65536 tokens)
```

The server log showed four consecutive failures — `283646 / 255133 / 254777 / 238592`
tokens — while the last successful request *before* the model switch was only
**18,920 tokens**. A 15× jump in one step, with no compaction anywhere in between.

Options if you need it to work in long sessions (all require editing
`~/.dsh/profiles/web/cordis.patch.yml` and restarting):

```yaml
- id: tool-result-pruner
  disabled: false
  config:
    thresholdChars: 40000     # the default 8192 is far too aggressive for coding
    headChars: 30000
    tailChars: 5000
```

Tuning parameters won't fix an architectural mismatch. **"Open a new session" is the
most effective answer.**

---

## Pitfalls (all fixed in these scripts)

| Pitfall | Symptom | Fix |
|---|---|---|
| Missing CUDA runtime | `--list-devices` prints `(none)`; silently falls back to CPU | copy `cudart64_12.dll` etc. into `bin\llama\` |
| Missing `apiKeyEnv` | route silently never registers; caller gets `null`, **no error at all** | add `apiKeyEnv` + a dummy credential ref |
| Thinking eats the budget | 1500 tokens of reasoning, `finish_reason=length`, empty answer | `--reasoning-budget 256`, or `--reasoning off` |
| `--chat-template-kwargs` quoting | JSON arg mangled into `{e`, server won't start | use the native `--reasoning off` flag |
| `Join-Path` + `-f` precedence | `part{0` treated as a drive letter | format the string first, then `Join-Path` |
| `$args` is reserved in PowerShell | weird script behavior | rename to `$srvArgs` |
| HuggingFace unreachable | hf.co / hf-mirror time out | use ModelScope (`modelscope.cn`) |
| Overseas rate limiting | ~650 KB/s on any single connection | multi-threaded ranged download, or ModelScope |

---

## Hardware notes

- **8 GB VRAM comfortably runs 9B at Q4 with 64K context** (6511 MiB, 1.6 GB headroom).
- **The real bottleneck is 16 GB of system RAM**, not VRAM — the model load spike plus a
  browser and Office will start paging. This class of laptop usually has 8 GB soldered
  plus one DDR5 SO-DIMM slot; a ~$35 stick to reach 24 GB removes the bottleneck.
- **Cost-wise, an API beats local.** A domestic flash-tier API costs roughly
  $0.4 per day for 500 calls. Local deployment buys you offline availability,
  data locality, zero quota — not savings.
- **Don't use it as the main agent.** Multi-step planning, error correction and
  long-horizon consistency are far below a cloud flagship.

---

## Repository layout

```
├─ README.md / README.en.md
├─ docs/deployment-story.md   full write-up: measurements, pitfalls, debugging methodology
├─ docs/usage-log.md          real-world usage log, updated as I keep using it
├─ scripts/
│  ├─ env.ps1                 the only file you normally edit
│  ├─ start.ps1 stop.ps1 status.ps1
│  ├─ bench.ps1               throughput / prefill / VRAM baseline
│  ├─ compare.ps1             capability comparison when switching models
│  ├─ stress.ps1              six agent-oriented stress tests
│  ├─ pull-model.ps1          GGUF from ModelScope
│  └─ download-parallel.ps1   multi-threaded ranged download
├─ config/dsh-route.yaml      DSH integration + troubleshooting guide
└─ bench/                     raw measurement records
```

Weights and runtime binaries are `.gitignore`d — re-fetch them with the scripts above.

## License

MIT
