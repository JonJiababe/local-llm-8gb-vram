# local-llm —— 本地小模型部署

[English](README.en.md)

在 RTX 4060 Laptop 8GB、16GB 内存的笔记本上把 Qwen3.5-9B 跑起来，并接进 DSH 当副手模型。
所有东西都在 `D:\local-llm` 一个目录里，删掉这个目录就算卸载干净了。

**状态**：已跑通并实测，已接入 DSH 验证。默认 Qwen3.5-9B，64K 上下文，40 tok/s。

- 完整部署过程与踩坑实录：**[docs/deployment-story.md](docs/deployment-story.md)**（开发者向，含排障方法论）
- 实际使用记录（持续更新）：**[docs/usage-log.md](docs/usage-log.md)**
- 接入 DSH 的配置与排错：**[config/dsh-route.yaml](config/dsh-route.yaml)**

> 跑分和压测解决的是"理论上能到什么程度"，`usage-log.md` 记的是真用下来碰到的、
> 包括把之前判断推翻的那些。

---

## 目录结构

```
D:\local-llm\
├─ README.md                  ← 本文件
├─ docs\deployment-story.md   ← 全过程实录（开发者向）
├─ docs\usage-log.md          ← 实际使用记录（持续更新）
├─ README.en.md               ← 英文版
├─ bin\llama\                 ← llama.cpp 运行时（便携版，不注册任何东西）
│   ├─ llama-server.exe
│   ├─ ggml-cuda.dll          ← CUDA 后端（551MB）
│   └─ cudart64_12.dll 等     ← CUDA runtime，缺了会静默退化成 CPU
├─ models\gguf\               ← 权重
│   ├─ Qwen3.5-9B-Q4_K_M.gguf    5.29 GB  ← 默认
│   └─ Qwen3.5-4B-Q4_K_M.gguf    2.55 GB
├─ scripts\
│   ├─ env.ps1                ← 唯一需要改的配置文件
│   ├─ start.ps1              ← 启动
│   ├─ stop.ps1               ← 停止并释放显存
│   ├─ status.ps1             ← 状态
│   ├─ bench.ps1              ← 吞吐 / 工具调用实测
│   ├─ compare.ps1            ← 模型能力横向对比
│   ├─ pull-model.ps1         ← 从魔搭下 GGUF
│   └─ download-parallel.ps1  ← 多线程下载境外源（应对限速）
├─ logs\                      ← 运行日志（排障先看这里）
├─ bench\                     ← results.md + compare.md
└─ config\dsh-route.yaml      ← 接入 DSH 的配置
```

---

## 实测数据

平台：RTX 4060 Laptop 8GB（55W TGP）+ Core Ultra 9 185H + 16GB DDR5
默认配置：上下文 **65536** · KV cache 量化 q8_0 · Flash Attention on · 全层 GPU · 思考关闭

### 吞吐

| 指标 | Qwen3.5-4B (2.55 GB) | Qwen3.5-9B (5.29 GB) |
|---|---|---|
| 生成速度 | **47.9 tok/s** | **31.4 tok/s**（64K 下 40.2） |
| prefill（3848 tok） | 2708 tok/s | 1679 tok/s |
| 显存（16K 上下文） | 3189 MiB | 5453 MiB |
| 显存（**64K 上下文**） | — | **6511 MiB / 8188** |
| 工具调用延迟 | 0.8-1.5 s | 1.3-2.3 s |

### 上下文扫描（9B，只改 `-c`）

| 上下文 | 显存 | 剩余 | 结论 |
|---|---|---|---|
| 16384 | 5453 MiB | 2735 MiB | 太保守 |
| **65536** | **6511 MiB** | 1689 MiB | ✅ 甜点，默认 |
| 131072 | 7843 MiB | 345 MiB | ⚠️ 余量不足 |

64K 只比 16K 多占 1GB —— 这代模型有滑动窗口注意力，长上下文很便宜。
之所以定 64K：**DSH 的系统提示词 + 工具 schema 实测就吃掉 8385 token**（日志里 `prompt eval ... 8385 tokens`），
16K 留给干活的只剩 8K。

### 能力对比（`scripts\compare.ps1`，3 用例，temperature=0）

| 用例 | 4B | 9B |
|---|---|---|
| 恰好输出 20 个汉字 | ✘ 28 字 | ✘ 21 字 |
| 工具选择（3 个含干扰项） | ✔ | ✔ |
| 写函数：排序后**返回文件名和大小** | ✘ **只返回大小，丢了文件名** | ✔ 完整 |
| **得分** | **1 / 3** | **2 / 3** |

关键在第三题：4B 写出语法完全正确、能跑的代码，但**悄悄丢了要求的一半**。
这类"看起来对、实际缺字段"的失效在 agent 流程里最危险。所以**默认 9B**，
慢 1.5 倍换正确性。批量机械处理再切 4B。

### 思考模式（4B，同一句翻译）

| 模式 | 耗时 | token | 结果 |
|---|---|---|---|
| 思考 ON（无预算） | 32 s | 1500（撞上限） | ✘ **回复为空** |
| 思考 ON（预算 256） | 6.2 s | 269 | ✔ |
| 思考 OFF | **0.56 s** | 11 | ✔ |

小模型简单任务上会"想太多"。默认 `$LlamaThinking = 'off'`，`--reasoning-budget 256` 兜底。

---

## 常用命令

```powershell
cd D:\local-llm

.\scripts\start.ps1                          # 启动（127.0.0.1:8080，默认 9B / 64K）
.\scripts\status.ps1                         # 状态：显存、模型、目录占用
.\scripts\bench.ps1 -LongPrompt              # 吞吐 + 工具调用
.\scripts\compare.ps1                        # 能力对比
.\scripts\stop.ps1                           # 停止，释放显存

# 临时切换
.\scripts\start.ps1 -Model Qwen3.5-4B-Q4_K_M.gguf
.\scripts\start.ps1 -Ctx 32768
.\scripts\start.ps1 -Thinking on

# 下载新模型
.\scripts\pull-model.ps1 -Repo unsloth/Qwen3.5-9B-GGUF -List
.\scripts\pull-model.ps1 -Repo unsloth/Qwen3.5-9B-GGUF -File Qwen3.5-9B-Q5_K_M.gguf
```

---

## 接入 DSH（已验证）

`llm-pi-ai` 插件本来就在 web profile 里挂着，**不需要安装任何东西**。

```yaml
# ~/.dsh/settings.yaml
llm-pi-ai:
  providers:
    local-llama:
      displayName: 本地 Qwen3.5-9B (llama.cpp)
      api: openai-completions
      apiKeyEnv: LOCAL_LLAMA_API_KEY      # ⚠️ 必须，否则路由静默失效
      baseURL: http://127.0.0.1:8080/v1
      compat:
        supportsDeveloperRole: false
        maxTokensField: max_tokens
        supportsReasoningEffort: false
      timeoutMs: 900000
      streamIdleTimeoutMs: 900000
      models:
        - id: qwen3.5-9b
          name: Qwen3.5-9B (本地)
          contextWindow: 65536            # 必须 ≤ env.ps1 的 $LlamaCtx
          maxTokens: 8192
```

```yaml
# ~/.dsh/.credentials.yaml（明文）
refs:
  LOCAL_LLAMA_API_KEY: local-no-auth      # 本地服务不校验，给个非空占位
```

改完即时生效（`dsh-settings-file` 用 chokidar 监听，debounce 100ms）。

### 验证结果

| 能力 | 结果 |
|---|---|
| 纯文本对话 | ✅ |
| 流式（SSE） | ✅ `tool_calls` 在 delta 里分块下发 |
| system 角色 | ✅ |
| **工具调用** | ✅ 实测让它列目录 → 正确调用工具 → 答对"8 个 .ps1" |
| 结构化输出（简单 schema） | ✅ |
| **结构化输出 + 工具组合** | ❌ 多步工具后填复杂 schema 会失败 |
| 长上下文 | ✅ 64K 下留 50K 干活 |

### 压力测试（`scripts\stress.ps1`，详见 docs）

| 项目 | 结果 |
|---|---|
| A 多轮工具链 | ✅ 3 步闭环（`list_files → read_file → 回答`），找对关键报错 |
| B 上下文累积 | ✅ prompt 31→503 tok（16 倍），耗时只涨 34% → **KV cache 复用生效，越聊不会越慢** |
| C 指令保持 | ✅ 5/5 轮（第 1 轮约束到第 6 轮还在） |
| D 工具报错恢复 | ✅ 2 步放弃重试并解释，不卡死循环 |
| E 长文档抽取 | ✅ **22,174 tok** 输入，13.67s，四字段全对 |
| F 并发（`-np 1`） | ⚠️ 排队不并行：单 1.08s，两个并发 2.74s |
| G DSH 交叉核对 2 文件 | ✅ 9 秒，值全对 |
| H DSH 多文件统计 | ⚠️ 行数 **9/9 全对**，但**排序排错了** |

**结论**：能可靠地"取数据、按指令做事"，不可靠地"保证全局逻辑一致"。
放在链条一端（读取/抽取/翻译/改写/摘要）很稳；放中间做需要统筹全局的判断会翻车。

### ⚠️ 长会话一定会爆窗口

**本地模型只用新会话、只做短任务。**

DSH 的 web profile 默认关闭了全部上下文压缩插件（`compaction-basic` / `command-compact` /
`tool-result-pruner` 都是 `disabled: true`）——因为云端模型有 104 万 token 窗口，没必要压。
但换成 64K 的本地模型后，历史仍然无界累积：

```
400: request (254777 tokens) exceeds the available context size (65536 tokens)
```

实测在一个长会话里切到本地 9B，llama-server 日志连续出现
`283646 / 255133 / 254777 / 238592 tokens` 四次 400，而切模型前最后一次正常请求只有 `18920 tokens`。

想缓解（需改 `~/.dsh/profiles/web/cordis.patch.yml` 并重启）：

```yaml
- id: tool-result-pruner
  disabled: false
  config:
    thresholdChars: 40000     # 默认 8192 太激进，读大文件会被砍到 5KB
    headChars: 30000
    tailChars: 5000
```

详见 `docs/deployment-story.md` 第九节。**调参救不了架构错配：「开新会话」才是最有效的解法。**

**定位**：副手模型——摘要、抽取、分类、翻译、单文件改写、代码补全。
主线（agent 主脑）继续走云端旗舰模型。

---

## 踩过的坑（都已在脚本里修好）

| 坑 | 现象 | 解法 |
|---|---|---|
| **缺 apiKeyEnv** | DSH 路由静默失效，调用返回 null，**无任何报错** | 配 `apiKeyEnv` + 占位凭据。排查时先看 llama-server 日志有没有收到请求 |
| **思考吃光 token** | 开思考后 1500 token 全烧在推理里，回复为空 | `--reasoning-budget 256`；默认关思考 |
| **缺 CUDA runtime** | `--list-devices` 返回 `(none)`，静默退化成 CPU | 把 `cudart64_12.dll` 等放进 `bin\llama\` |
| **`--chat-template-kwargs` 转义** | `Start-Process` 把 JSON 参数撕成 `{e`，服务起不来 | 改用原生 `--reasoning off` |
| **`Join-Path` + `-f` 优先级** | `part{0` 被当盘符 | 先格式化再 Join-Path |
| **`$args` 是保留变量** | 脚本行为诡异 | 改名 `$srvArgs` |
| **HuggingFace 不通** | hf.co / hf-mirror 均超时 | 全部走魔搭 `modelscope.cn` |
| **境外源限速** | 单连接 650 KB/s | 多线程分段（`download-parallel.ps1`）或换魔搭 |

---

## 硬件边界

- **8GB 显存能舒服跑到 9B Q4 + 64K 上下文**（6511 MiB，剩 1.6GB 余量）。128K 也能起但余量只剩 345MB。
- **真正的瓶颈是 16GB 内存**：当前只剩 2.8GB。这机器是 8GB 板载 + 1 条 SO-DIMM，
  换根 16GB 条到 24GB（约 ¥250）能解决，比换显卡现实得多。
- **别指望它当 agent 主脑**：9B 能正确调用工具，但"多步工具 + 复杂结构化输出"顶不住，
  长链路规划和纠错也远不如云端旗舰。定位是副手。
- **纯成本上算不过 API**：qwen3.7-flash 约 2.8 元/天（500 次调用）。本地部署的价值是
  离线可用、数据不出机器、零配额，不是省钱。
