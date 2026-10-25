# 8GB 显存的游戏本上跑本地大模型，并接进 AI Agent 框架：一次完整的踩坑实录

> 硬件：RTX 4060 Laptop 8GB / Intel Core Ultra 9 185H / 16GB DDR5（一台 2024 年的轻薄性能本）
> 系统：Windows 11 build 26200
> 目标：在自己笔记本上部署一个能用的本地 LLM，接进 DSH（DeepSeek Harness）当"副手模型"
> 时间：2026-10
> 结果：**跑通了，9B 模型 40 tok/s，64K 上下文，显存占 6.5GB**

---

## 一、先说结论

| 项目 | 结果 |
|---|---|
| 运行时 | llama.cpp b11871（CUDA 12.4 便携版） |
| 模型 | Qwen3.5-9B-Q4_K_M（5.29 GB）+ Qwen3.5-4B-Q4_K_M（2.55 GB） |
| 生成速度 | **40.2 tok/s**（9B）/ 47.9 tok/s（4B） |
| prefill 速度 | 1679-2708 tok/s |
| 上下文 | **65536**，显存 6511 MiB / 8188 |
| 磁盘占用 | 8.97 GB（运行时 633MB + 模型 7.84GB） |
| 接入 DSH | ✅ 文本、工具调用、流式全部跑通 |
| 长会话 | ❌ **必须开新会话**（框架不压缩，25 万 token 直接 400） |
| 压力测试 | ✅ 3 步工具链闭环 / ✅ 22K token 长文档抽取 / ⚠️ 排序会出错 |
| 部署耗时 | 约 30 分钟（其中 25 分钟在下东西） |

**三个反直觉的结论**，后面逐一展开：

1. **最大的敌人不是显存，是网络。** 境外源全部被卡在 ~650 KB/s，方案选型被这件事彻底改变。
2. **4B 不是 9B 的"小一号"，是"会悄悄漏需求的另一个东西"。** 对比测试里 4B 写出了语法完全正确的代码，但把题目要求的一半丢了。
3. **名字里带 Flash/Air/Mini 的模型，绝大多数根本塞不进 8GB。** GLM-4.7-Flash 是 19GB，GLM-5.3-Flash 是 320B。

还有一个结论只有压测才能看出来，先放这里：**它能可靠地"取数据、按指令做事"，不可靠地"保证全局逻辑一致"。**
压力测试里它读 9 个文件数行数，9 个数字全对，但把列表排序排错了——数据没错，一致性错了。这决定了它该放在流程的哪一环。

---

## 二、先做诊断，别急着下载

在动手之前，先把两件事测清楚：**硬件能跑多大的模型**，和**网络能多快下到东西**。这两件事决定了后面所有选择。

### 2.1 硬件实测

用 `nvidia-smi` 和注册表拿到实际参数（`Get-CimInstance` 在这台机器上被拒绝访问，所以换了路子）：

| 项目 | 实测 | 对部署的意义 |
|---|---|---|
| CPU | Intel Core Ultra 9 185H，16 核 22 线程 | CPU 回退推理能用，约 9 tok/s |
| 内存 | 15.4 GB 可用，当前空闲 **2.8 GB** | ⚠️ 真正的瓶颈 |
| 内存规格 | 板载 8GB DDR5 + 8GB SO-DIMM 单条 | 可升级，见第八节 |
| 显卡 | RTX 4060 Laptop，8188 MiB，驱动 566.07 / CUDA 12.7 | 8GB 是硬上限 |
| 显卡功耗 | **TGP 上限 55W**（同芯片里偏低配） | 比台式 4060 慢不少 |
| 显存带宽 | 128-bit GDDR6 约 256 GB/s | 决定 tok/s 上限 |
| 磁盘 | C: 剩 139 GB，D: 剩 563 GB | 模型放 D 盘 |

**估算方法**：解码速度 ≈ 显存带宽 ÷ 模型权重体积。
- 4B Q4（2.55GB）：理论 100 tok/s，实测 48 tok/s（效率 ~48%）
- 9B Q4（5.29GB）：理论 48 tok/s，实测 40 tok/s（效率 ~83%，因为上下文里有 SWA 省了带宽）

这个公式很好用：**先算权重体积，再看剩多少给 KV cache**。

### 2.2 网络实测（这一步救了我一整天）

本来打算用 Ollama，一条命令搞定。先测了速度：

| 源 | 实测速度 | 说明 |
|---|---|---|
| github.com（直连） | **31 KB/s** | 1.5GB 要 14 小时 |
| github.com（挂代理后） | 654 KB/s | 21 倍提升，但还是要 40 分钟 |
| ollama.com CDN（zip） | 144 KB/s | |
| ollama.com CDN（Setup.exe） | 658 KB/s | |
| **registry.ollama.ai（模型仓库）** | **614 KB/s** | 关键：模型也得从这走 |
| gh-proxy.com（单线程） | 14 KB/s | |
| **gh-proxy.com（8 线程分段）** | **1522 KB/s** | 多线程有效 |
| hf-mirror.com | 超时 | 不通 |
| huggingface.co | 超时 | 不通 |
| **modelscope.cn（魔搭）** | **3837 KB/s → 峰值 24 MB/s** | ⭐ 国内源，快得离谱 |

**结论**：Ollama 方案要下 1.5GB 安装包 + 3.6GB 权重全走境外 ≈ **2.3 小时**。这条路直接否掉。

改成：**llama.cpp 运行时（633MB，多线程镜像 1.1 MB/s）+ 权重从魔搭下（24 MB/s）**，总共 30 分钟。

> 💡 换任何方案前，先花 5 分钟测速。这一步省下的时间比后面所有优化加起来都多。

---

## 三、方案选型

| 方案 | 运行时体积 | 权重来源 | 总下载量 | 判断 |
|---|---|---|---|---|
| Ollama | 1513 MB | registry.ollama.ai（614 KB/s） | ~5.1 GB 全境外 | ❌ 2.3 小时 |
| LM Studio | ~1 GB | HF（不通） | 不可行 | ❌ |
| **llama.cpp** | **633 MB**（260 主包 + 373 CUDA runtime） | **魔搭 24 MB/s** | ~8.5 GB 但快 | ✅ **选它** |
| vLLM | — | — | Windows 支持差 | ❌ |

llama.cpp 还有个附带好处：参数完全可控（上下文、KV 量化、思考预算、工具模板全在命令行上），比 Ollama 的"黑盒 modelfile"更适合排查问题。

---

## 四、部署步骤

### 4.1 建目录（把一切关在一个文件夹里）

```powershell
$root = 'D:\local-llm'
foreach ($d in 'bin','models\gguf','logs','scripts','config','bench','docs') {
  New-Item -ItemType Directory -Force -Path (Join-Path $root $d) | Out-Null
}
```

不写注册表、不装系统服务、模型不落 `C:\Users\*`。这套目录本身就能直接打包分享（权重加 `.gitignore` 就行）。

### 4.2 下载运行时（多线程分段）

llama.cpp 的 release 页有个坑：`latest` 这个 release 只有个 `nightly-tag.txt`，真正的二进制挂在 **build 号** 的 release 上。用 API 翻最近 15 个 release 才找到带 `win-cuda` 资产的：

```powershell
$r = Invoke-RestMethod 'https://api.github.com/repos/ggml-org/llama.cpp/releases?per_page=15'
# 找到 b11871（2026-10-25）
```

需要的两个包：
- `llama-b11871-bin-win-cuda-12.4-x64.zip` — 260 MB（主程序 + ggml-cuda.dll 551MB）
- `cudart-llama-bin-win-cuda-12.4-x64.zip` — 373 MB（CUDA runtime，**必须**）

> ⚠️ **别选 CUDA 13.x 的包**。你的驱动是 566.07（CUDA 12.7），CUDA 13 运行时需要 580+ 驱动。

**注意版本匹配**：驱动 566.07 → CUDA 12.7 → 用 cuda-12.4 的构建（12.x 向后兼容）。

8 线程分段下载脚本（D:\local-llm\scripts\download-parallel.ps1 的核心）：

```powershell
$total = Get-RemoteSize $Url          # 从 content-length 拿
$chunk = 6MB
$ranges = 按 $chunk 切成 N 段
# 每次并发 8 个 curl -r start-end，各自写 .partN
# 全部完成后按序拼接
```

实测从 654 KB/s 提到 1522 KB/s。断点续传靠 `.partN` 文件是否完整来判断，重跑即续。

### 4.3 解压并验证 CUDA

```powershell
Expand-Archive .\bin\llama-cuda-12.4.zip -DestinationPath .\bin\llama -Force
& .\bin\llama\llama-server.exe --list-devices
```

**第一次跑，输出是 `(none)`。** 明明放了 `ggml-cuda.dll`，却识别不到显卡。

原因：缺 CUDA runtime。解压 cudart 包后：

```
Available devices:
  CUDA0: NVIDIA GeForce RTX 4060 Laptop GPU (8187 MiB, 7099 MiB free)
```

> 💡 这个坑最阴险：没有报错，只是静默退化成 CPU 推理。不检查 `--list-devices` 就会以为"我的显卡怎么这么慢"。

### 4.4 从魔搭下权重

HuggingFace 不通，但魔搭全有（unsloth 的 GGUF 仓库都同步了）。API 很简单：

```powershell
# 列文件
$meta = Invoke-RestMethod "https://modelscope.cn/api/v1/models/unsloth/Qwen3.5-9B-GGUF/repo/files?Revision=master"
$meta.Data.Files | Where-Object { $_.Name -match '\.gguf$' } | Select Name, Size

# 下载
curl.exe -L -C - -o 目标.gguf "https://modelscope.cn/api/v1/models/unsloth/Qwen3.5-9B-GGUF/repo?Revision=master&FilePath=Qwen3.5-9B-Q4_K_M.gguf"
```

5.29 GB 用了 3 分 41 秒（平均 24 MB/s）。

下完校验文件头（4 字节 magic 必须是 `GGUF`）：

```powershell
$fs=[System.IO.File]::OpenRead($path); $buf=New-Object byte[] 4; $fs.Read($buf,0,4)|Out-Null; $fs.Dispose()
[System.Text.Encoding]::ASCII.GetString($buf)   # GGUF
```

### 4.5 启动

```powershell
.\bin\llama\llama-server.exe `
  -m .\models\gguf\Qwen3.5-9B-Q4_K_M.gguf `
  -a qwen3.5-9b `
  --host 127.0.0.1 --port 8080 `
  -ngl 99 -c 65536 -np 1 -t 8 `
  -fa on -ctk q8_0 -ctv q8_0 `
  --jinja `
  --reasoning off --reasoning-format deepseek --reasoning-budget 256
```

关键参数逐个解释：

| 参数 | 作用 | 为什么这么设 |
|---|---|---|
| `-ngl 99` | 全部层放显存 | 少了会有一半跑 CPU，速度腰斩 |
| `-c 65536` | 上下文 64K | 见第六节扫描结果 |
| `-fa on` | Flash Attention | Ada(sm_89) 支持，省显存提速 |
| `-ctk/-ctv q8_0` | KV cache 量化 | 省一半 KV 显存，几乎无损 |
| `-np 1` | 单并发 | 8GB 卡开不了第二个槽 |
| `--jinja` | 用模型原生聊天模板 | **工具调用的前提**，不开就是纯文本 |
| `--reasoning off` | 关思考 | 见第五节，4B 开思考会想太多 |
| `--reasoning-budget 256` | 思考预算兜底 | 万一开思考也不会失控 |
| `--reasoning-format deepseek` | 思考放进 `reasoning_content` | 和 OpenAI 兼容端点的惯例一致 |

---

## 五、踩坑合集

### 坑 1：思考模式把 token 全吃光，回复是空的

Qwen3.5 是思考模型。一句"把这句话翻译成英文"，实测：

| 模式 | 耗时 | 生成 token | 结果 |
|---|---|---|---|
| 思考 ON（`max_tokens=400`） | 9.2 s | 400（撞上限） | ❌ **回复为空**，`finish_reason=length` |
| 思考 ON（`max_tokens=1500`） | 32 s | 1500（又撞上限） | ❌ **还是空**，推理写了 5810 字符没结束 |
| 思考 ON（`--reasoning-budget 256`） | 6.2 s | 269 | ✅ 正确 |
| **思考 OFF** | **0.56 s** | 11 | ✅ **正确，快 11 倍** |

小模型在简单任务上"过度思考"是通病。**8GB 卡上跑 agent，默认关思考**，需要强推理时再开，并且一定要加预算。

### 坑 2：`llama-server --list-devices` 返回 `(none)`

见 4.3，缺 `cudart64_12.dll`。静默退化，不报错。

### 坑 3：`--chat-template-kwargs` 传 JSON 参数，服务直接起不来

想用 `--chat-template-kwargs '{"enable_thinking":false}'` 关思考，PowerShell 的 `Start-Process -ArgumentList` 会把花括号和引号撕碎：

```
error while handling argument "--chat-template-kwargs":
  parse error at line 1, column 2: invalid literal; last read: '{e'; expected string literal
```

`{e` —— 它只收到了"花括号 + 一个字母"。

**解法**：用原生开关 `--reasoning off`，完全绕开 JSON 参数转义问题。

### 坑 4：`Join-Path` 和 `-f` 的优先级

```powershell
Join-Path $dir "part{0:D4}" -f $i     # ❌
```
报错：`找不到驱动器。名为"part{0"的驱动器不存在`

原因：`-f` 在命令参数位置被当成了 `Join-Path` 的开关，字符串字面量 `"part{0:D4}"` 原样传进去，PowerShell 看到冒号就以为是盘符 `part{0:`。

**解法**：先格式化，再 Join：

```powershell
$partName = 'part{0:D4}' -f $i
Join-Path $dir $partName              # ✅
```

### 坑 5：`$args` 是 PowerShell 保留变量

脚本里写 `$args = @('-m', ...)` 会有莫名其妙的解析问题。**改名**，`$srvArgs` 就好。

### 坑 6：接 DSH 时，不配 `apiKeyEnv` 路由静默失效

这个最花时间。按文档把路由写进 `settings.yaml`：

```yaml
llm-pi-ai:
  providers:
    local-llama:
      api: openai-completions
      baseURL: http://127.0.0.1:8080/v1
      models:
        - id: qwen3.5-9b
```

文档说"`apiKeyEnv` 省略则路由不认证"——符合本地服务的需求。**但路由就是不出现。** 没有任何报错，调用方只拿到 `null`。

**定位方法**：去看 llama-server 的日志。如果 DSH 真的发请求过来了，日志里会有 `slot print_timing`。日志一动不动 → 请求根本没发出 → 问题在 DSH 侧，不在模型侧。

**解法**：给一个占位凭据。

```yaml
# settings.yaml
local-llama:
  apiKeyEnv: LOCAL_LLAMA_API_KEY
```

```yaml
# ~/.dsh/.credentials.yaml（明文）
refs:
  LOCAL_LLAMA_API_KEY: local-no-auth
```

改完立刻生效（`dsh-settings-file` 用 chokidar 监听，debounce 100ms）。

> 💡 排查"接不通"类问题，第一步永远看**对端日志有没有收到请求**。这一条把"DSH 配置问题"和"模型服务问题"一刀切开。

### 坑 7：DSH 的系统提示词就吃掉 8.4K

从 llama-server 日志看得很清楚：

```
prompt eval time = 5443.28 ms / 8385 tokens
```

**8385 token 是 agent 框架的系统提示词 + 工具 schema。** 如果按原计划给 16384 上下文，留给真正干活的空间只剩 8K，多轮对话一上来就爆。

这一条直接导致了第六节的上下文扫描。

---

## 六、上下文到底能给多大？（扫描实测）

KV cache 是变量。同一个 9B Q4 模型，只改 `-c`：

| 上下文 | 显存占用 | 剩余 | 结论 |
|---|---|---|---|
| 16384 | 5453 MiB | 2735 MiB | 太保守 |
| 65536 | **6511 MiB** | 1689 MiB | ✅ **甜点** |
| 131072 | 7843 MiB | **345 MiB** | ⚠️ 余量不足，一个峰值就 OOM |

**64K 只比 16K 多占 1GB** —— 说明这代模型用了滑动窗口注意力（SWA），长上下文的 KV 增长被压住了。128K 也能跑起来，但只剩 345MB 余量，不值得为它冒风险。

最终定在 **65536**：够放下 8.4K 系统提示词 + 50K 的实际工作内容，还有 1.6GB 显存余量。

---

## 七、4B vs 9B：别只看速度

200 块钱的差距（其实只是多下 2.7GB），但性质完全不同。

### 吞吐对比（16K 上下文）

| 指标 | Qwen3.5-4B | Qwen3.5-9B |
|---|---|---|
| 权重 | 2.55 GB | 5.29 GB |
| 生成速度 | 47.9 tok/s | 31.4 tok/s（64K 下 40.2） |
| prefill（3848 tok） | 2708 tok/s | 1679 tok/s |
| 显存 | 3189 MiB | 5453 MiB |
| 工具调用延迟 | 0.8-1.5 s | 1.3-2.3 s |

4B 快 1.5 倍，显存只占 39%。看起来 4B 更划算。

### 能力对比（3 个用例，temperature=0）

| 用例 | 4B | 9B |
|---|---|---|
| 恰好输出 20 个汉字 | ❌ 输出了 28 字 | ❌ 输出了 21 字 |
| 从 3 个工具里选对（含 1 个危险工具做干扰） | ✅ | ✅ |
| 写 PowerShell 函数：按大小排序**返回文件名和大小** | ❌ **只返回了大小，丢了文件名** | ✅ 完整 |
| **得分** | **1 / 3** | **2 / 3** |

**第三题是重点。** 4B 的输出：

```powershell
function Get-TopFiles {
    param([string]$Path, [int]$Count)
    $files = Get-ChildItem -Path $Path -File | Sort-Object Length -Descending | Select-Object -First $Count
    foreach ($file in $files) {
        [math]::Round($file.Length / 1MB, 2)     # 只有大小，文件名没了
    }
}
```

语法完全正确，能跑，**但把题目要求的一半悄悄丢了**。9B 会老老实实返回 `[PSCustomObject]@{ Name=...; SizeMB=... }`。

这种"看起来对、实际缺字段"的失效，在 agent 流程里最危险——你不会立刻发现，直到下游拿不到数据。

> **结论：默认用 9B。** 慢 1.5 倍，换需求不被悄悄丢掉，这笔买卖划算。
> 大批量机械处理（分类、抽取、打标签）再切 4B。

---

## 八、压力测试：它在真实 agent 场景下到底行不行

吞吐数字好看不等于能用。真正的考验是**多轮工具调用**：模型能不能记住上一步的结果，能不能在工具报错后改策略，能不能在上下文变长后不崩。

下面六项跑的是直连 llama-server 的脚本化测试（`scripts\stress.ps1`，可复现），外加两项跑在 DSH 里的真实 agent 任务。

### A. 多轮工具链：能不能闭环

任务："先列出目录，再读出其中日志文件的前几行，最后告诉我日志里有没有报错。"

| 项 | 结果 |
|---|---|
| 是否闭环 | ✅ 3 步内收敛为文本 |
| 工具调用链 | `list_files → read_file → 文本回答` |
| 是否找对关键信息（日志里的 `connection refused`） | ✅ |

三层嵌套的意图（列目录 → 挑出日志 → 判断有无报错）它一次走完，顺序没乱。

### B. 上下文累积：8 轮连续对话

| 轮 | prompt tok | 生成 tok | 耗时 s |
|---|---|---|---|
| 1 | 31 | 36 | 1.17 |
| 2 | 86 | 64 | 1.89 |
| 3 | 167 | 50 | 1.48 |
| 4 | 232 | 49 | 1.44 |
| 5 | 297 | 52 | 1.51 |
| 6 | 365 | 44 | 1.30 |
| 7 | 429 | 53 | 1.54 |
| 8 | 503 | 54 | 1.57 |

**看点**：prompt 从 31 token 涨到 503 token（16 倍），耗时只从 1.17s 涨到 1.57s（1.34 倍）。

这说明 **KV cache 复用是生效的**——每轮只 prefill 新增的那几十个 token，历史部分直接复用。否则按 1679 tok/s 的冷启动 prefill 速度，第 8 轮光 prefill 就要 0.3s 以上，而且会随轮数线性变差。

对 agent 场景来说这是关键指标：**长对话不会越聊越慢。**

### C. 指令保持：第 1 轮下的约束能撑几轮

第 1 轮要求"之后每次回答开头都必须加 `[LOCAL]` 标记"，然后连问 5 个无关问题。

| 结果 | 5 / 5 轮全部保持 |
|---|---|

这一项本来是预期会翻车的（小模型典型失效模式），结果 9B 稳住了。5 轮不算长，但至少说明几轮内的约束不会丢。

### D. 工具报错恢复：会不会卡在死循环

故意让 `read_file` 一直返回 `ERROR: file not found (ENOENT)`：

| 项 | 结果 |
|---|---|
| 调用序列 | `read_file → 文本回答` |
| 最终正确报告"找不到该文件" | ✅ **2 步就放弃重试** |
| 是否无脑重复同一调用 | ✅ 否 |

模型没有在"调工具 → 报错 → 再调工具"里打转，而是立刻转成对用户的解释。这一点比很多大模型好——不少模型会盲目重试 3 次才认输。

### E. 长文档抽取：压到 64K 上下文

喂 600 条工单记录（约 7000 字），其中唯一一条涉及"证书过期"，要求抽出工单号、影响时长、处理日期、涉及省份。

| 项 | 结果 |
|---|---|
| 输入 prompt | **22,174 tok** |
| 端到端耗时 | **13.67 s** |
| 抽取正确 | ✅ 487 号 / 47 分钟 / 2026-10-20 / 三个省份，四项全对 |

22K token 的 prefill 用 13.67 秒（约 1620 tok/s），四个字段零错误。

**这是 64K 上下文真正的用处**：不是拿来聊天，是拿来一次性塞进整份日志/文档做抽取。这个输入长度已经超过了多数 8GB 显卡方案的上限（16K 上下文根本装不下）。

### F. 并发：两个请求同时来会怎样

服务是 `-np 1`（单槽位）。

| 场景 | 总耗时 |
|---|---|
| 单个请求 | 1.08 s |
| 两个并发（各自 1.15s / 1.96s） | **2.74 s** |

单槽位下并发是**排队**而不是并行：总耗时约等于两次串行之和。**不会崩，也不会变快。**

想要真并行得加 `-np 2`，但 8GB 卡装不下第二份 KV cache——这是硬约束，不是配置问题。

### G. DSH 里跑真实 agent 任务（一）：配置一致性核对

在 DSH 里让它读 `env.ps1` 和 `README.md` 两个文件，交叉核对配置值是否一致。

| 项 | 结果 |
|---|---|
| 耗时 | **9 秒** |
| 是否实际读了文件 | ✅ 引用了具体行号 |
| 提取的三个值 | ✅ `$LlamaCtx = 65536`、`$LlamaPort = 8080`、`$LlamaKvType = 'q8_0'` |
| 结论 | ✅ 正确判断"一致" |

### H. DSH 里跑真实 agent 任务（二）：多文件统计 + 排序

让它统计 9 个 `.ps1` 文件的行数并排序，报出最多和最少的两个。

| 项 | 结果 |
|---|---|
| 耗时 | **32 秒** |
| 行数准确性 | ✅ **9 / 9 全部正确** |
| 排序正确性 | ❌ **排错了** |
| 最终结论 | ✅ 最多 `stress.ps1`(280)、最少 `stop.ps1`(31) 都对 |

真实行数（核对过）：

```
stress.ps1  280    download-parallel.ps1  100    env.ps1    49
bench.ps1   127    compare.ps1             96    status.ps1 49
start.ps1   117    pull-model.ps1          78    stop.ps1   31
```

它报出的每个数字都对，但列表里把 `download-parallel.ps1`(100) 排到了 `compare.ps1`(96) 后面，自相矛盾。

**这个失败很典型**：小模型能把"读文件、数行数"这类事实性工作做对，但**在需要保持全局一致性的排序/汇总环节掉链子**。它不会算错，只是没把"排序"这件事真正做对就急着下结论。

> 实际使用中的对策：**别让它一步做完"统计 + 排序 + 判断"**。拆成两步——先要数据表，再单独让它判断——准确率会高很多。或者干脆用脚本算出结果，让模型只负责解释。

### 压力测试总结

| 能力 | 结果 |
|---|---|
| 多轮工具链闭环 | ✅ 3 步 |
| 长对话不衰减（KV 复用） | ✅ prompt 涨 16 倍，耗时只涨 34% |
| 指令保持 | ✅ 5/5 轮 |
| 工具报错恢复 | ✅ 2 步放弃，不死循环 |
| 长文档抽取（22K tok） | ✅ 13.67s，四字段全对 |
| 并发 | ⚠️ 排队，不崩不快 |
| 事实性提取（读文件数行数） | ✅ 9/9 准确 |
| **需要全局一致性的运算（排序）** | ❌ 会出错 |
| 多步工具 + 复杂结构化输出 | ❌ 顶不住 |

**一句话定位**：它能可靠地"取数据、按指令做事"，不可靠地"保证全局逻辑一致"。

所以最佳用法是把它放在**链条的一端**——读取、抽取、翻译、改写、摘要；而不是放在**中间**去做需要统筹全局的判断。

---

## 九、接进 DSH

DSH 的 `llm-pi-ai` 插件本来就挂在 web profile 里，**不需要装任何东西**，只要加一条路由。

### 最终配置

```yaml
# ~/.dsh/settings.yaml
llm-pi-ai:
  providers:
    local-llama:
      displayName: 本地 Qwen3.5-9B (llama.cpp)
      api: openai-completions
      apiKeyEnv: LOCAL_LLAMA_API_KEY      # ⚠️ 必须！见坑 6
      baseURL: http://127.0.0.1:8080/v1
      compat:
        supportsDeveloperRole: false      # llama-server 不认 developer 角色
        maxTokensField: max_tokens        # 不吃 max_completion_tokens
        supportsReasoningEffort: false    # 别发 reasoning_effort
      timeoutMs: 900000                   # 本地模型首字慢，给足 15 分钟
      streamIdleTimeoutMs: 900000
      models:
        - id: qwen3.5-9b
          name: Qwen3.5-9B (本地)
          contextWindow: 65536            # 必须 ≤ llama-server 的 -c
          maxTokens: 8192
```

`compat` 那三项是关键：llama-server 是个"长得像 OpenAI、细节不太像"的端点。不声明这几项差异，请求会被 400 拒掉。

### 验证结果

| 能力 | 结果 | 说明 |
|---|---|---|
| 纯文本对话 | ✅ | |
| **流式（SSE）** | ✅ | `tool_calls` 在 delta 里分块下发，`finish_reason=tool_calls` |
| system 角色 | ✅ | |
| **工具调用** | ✅ | 实测让它列目录，正确调用了工具，答出"8 个 .ps1 文件"（正确） |
| 结构化输出（简单 schema） | ✅ | 单字段 schema 正常返回 |
| **结构化输出 + 工具组合** | ❌ | 多步工具调用后填复杂 schema 会失败 |
| 长上下文 | ✅ | 64K 下系统提示词 8.4K，剩 50K 可用 |

**能力边界很清楚**：当成"会调用工具的助手"用没问题；要求它一边多步调工具一边吐符合复杂 schema 的结构化结果，9B 顶不住。

所以定位是：**副手模型**——读文件做摘要、批量抽取、翻译、单文件改写、代码补全。主线（agent 主脑）继续走云端旗舰模型。

### ⚠️ 最重要的一条限制：长会话一定会爆窗口

跑通之后，我在一个已经攒了几十万 token 的会话里把模型切成本地 9B，立刻收到：

```
400: request (254777 tokens) exceeds the available context size (65536 tokens)
n_prompt_tokens: 254777, n_ctx: 65536
```

llama-server 日志里是连续四次失败：

```
18,920 tokens      ← 切模型前最后一次正常请求
283,646 tokens  ✘  exceeds 65536
255,133 tokens  ✘
254,777 tokens  ✘
238,592 tokens  ✘
```

前一秒还是 1.9 万 token，下一秒直接跳到 25 万——中间没有任何压缩动作。

**根因不在模型，在框架。** DSH 的 web profile 默认把三个上下文压缩插件全部关掉了：

```yaml
- id: compaction-basic      disabled: true
- id: command-compact       disabled: true
- id: tool-result-pruner    disabled: true
```

对云端模型这是合理设计：deepseek-flash 有 1,048,576 token 窗口，历史随便攒。**但换成 64K 的本地模型后，历史仍然无界累积**，第一次请求就带着整段对话冲上去。

| | deepseek-flash（云端） | 本地 Qwen3.5-9B |
|---|---|---|
| 上下文窗口 | 1,048,576 | 65,536 |
| 系统提示词占用 | 可忽略 | **8,385**（占 13%） |
| 累积到 25 万 token 的长会话 | 无压力 | **直接 400** |

> **结论：本地模型只用新会话、只做短任务。**
> 这一条比任何参数调优都重要——调参救不了架构层面的容量错配。

如果想在长会话里也能用，有三个方向（前两个需要改 profile 的 patch 层并重启）：

**1. 开工具结果裁剪**（最安全，只改工具输出不改对话语义）

```yaml
# ~/.dsh/profiles/web/cordis.patch.yml
- id: tool-result-pruner
  disabled: false
  config:
    thresholdChars: 40000     # 默认 8192 对编程场景太激进，读个大文件就被砍
    headChars: 30000
    tailChars: 5000
```

> 验证 patch 是否生效：`dsh --profile web --patch <你的patch.yml> --dump-config | grep -A6 tool-result-pruner`

**2. 开历史摘要压缩**（`compaction-basic`）。注意压缩本身要调用 LLM——如果当前配的就是本地模型，压缩会又慢又不可靠，建议压缩走云端、干活走本地。

**3. 提高上下文到 131072**（实测 7843 MiB / 8188）。但显存余量只剩 345MB，而且 25 万 token 依然会爆——治标不治本。


---

## 十、排障方法论：三次定位过程

上面那些坑，"现象 → 结论"看着很干净，但真实排查过程不是这样的。这里把三次最难的定位过程原样记下来——**我觉得这部分比结论更值得抄**。

### 案例一：显卡没被用上，但一切看起来正常

**现象**：模型能跑，回答也对，就是慢得出奇。

**错误的第一反应**：以为 55W 的笔记本 GPU 就是这个水平，去调量化、调线程数。调了半天没变化。

**转折点**：想到去看显存占用——`nvidia-smi` 显示 **0 MiB**。模型在跑，显存一点没用。

**定位**：

```
llama-server.exe --list-devices
→ Available devices: (none)
```

放了 `ggml-cuda.dll` 在那儿，程序却一个设备都看不见。补上 `cudart64_12.dll` / `cublas64_12.dll` 之后立刻变成：

```
CUDA0: NVIDIA GeForce RTX 4060 Laptop GPU (8187 MiB, 7099 MiB free)
```

**这一课**：**"报错"和"静默降级"是两种完全不同的故障。** 后者不产生任何错误信息，只是安静地不好好干活。对付它不能看错误输出，只能看**能力断言**——`--list-devices` 有没有列出 CUDA0、`nvidia-smi` 显存有没有涨、某个功能是不是真的启用了。每装一个带硬件加速的东西，第一件事是验证它真的认到了硬件。

### 案例二：路由静默失效，调用方只拿到 null

**现象**：配置文件按文档写好了，调用返回 `null`。**没有任何报错。**

**错误的第一反应**：怀疑 YAML 缩进、怀疑模型名写错、怀疑服务没起。反复重写配置，无效。

**转折点**：去看对端日志。

```
Get-Content D:\local-llm\logs\llama-server.log | Select-String 'print_timing'
```

日志里最后一次请求停在几分钟前我手动测试的那一刻，中间**一动不动**。

这说明：**框架根本没往外发请求。** 问题在配置侧，不在模型侧。一刀切开，范围缩小一半。

**定位**：既然不发请求，就逐项排除"配置为什么没被接受"：

1. 设置文件是否热加载？—— 查代码确认 `dsh-settings-file` 用 chokidar 监听，debounce 100ms，所以会
2. 字段是否合法？—— 对照插件 schema 逐个核对，都对
3. 那还有什么会让路由压根不出现？—— 试了一个最不像的：补上 `apiKeyEnv`

立刻通了。

**这一课**：**先确认"对端有没有收到请求"，这是最高性价比的一刀。** 它把"我的服务坏了"和"调用方没叫我"彻底分开，而这两类问题的排查方向完全相反。另外——**省略一个"可选"字段导致功能静默失效**，这种事文档不会写，只能靠试。

### 案例三：25 万 token 撞上 6.5 万窗口

**现象**：

```
400: request (254777 tokens) exceeds the available context size (65536 tokens)
```

**错误的第一反应**：以为模型服务配错了，去查 `-c` 参数。`-c 65536` 明明是对的。

**转折点**：数字对不上——**25 万比 6.5 万大近 4 倍，一个正常的工作流程怎么会攒出 25 万？**

**定位**：

第一步，看服务端日志的错误行，发现不是一次，是连续四次：

```
283,646 tokens  ✘
255,133 tokens  ✘
254,777 tokens  ✘
238,592 tokens  ✘
```

第二步，往前翻成功的请求：切模型前最后一次正常请求只有 **18,920 tokens**。

18,920 → 283,646。**单步跳变 15 倍。** 这说明不是慢慢攒起来的，而是一次性灌进去的。

第三步，量出这个会话的真实体量。会话文件是 `session.jsonl.zstd`，2.55 MB。直接解压只出来 255 字节——它是**多帧 zstd**，`zstdDecompressSync` 只解第一帧。按 zstd 魔数 `28 b5 2f fd` 切帧后逐帧解压，得到 5.96 MB、8643 条记录、17.8 万中文字符。

和 25 万 token 对上了。

第四步，去看框架为什么没压缩历史。翻 `dsh --profile web --dump-config`：

```yaml
- id: compaction-basic      disabled: true
- id: command-compact       disabled: true
- id: tool-result-pruner    disabled: true
```

**三个压缩插件全关着。** 对云端 104 万窗口的模型这是合理设计，对 64K 的本地模型就是灾难。

**这一课**：**数字异常时，先量出真值，再去找谁在放大。** 如果一开始就接受"是不是 -c 配小了"这个假设，会一直在参数里打转。是"25 万 vs 6.5 万差 4 倍"这个不合理，把我推到了"谁在往里灌数据"这个正确问题上。

### 四条能复用的原则

1. **先看对端日志有没有收到请求。** 这一刀把问题切成"我没发"和"你没收/你处理错了"两半，方向完全不同。
2. **区分"报错失败"和"静默降级"。** 后者更常见也更危险——没有错误信息。要看能力断言（设备列表、资源占用、功能是否真的启用），不能只看错误输出。
3. **数字异常先量真值。** 拿"这个数是不是合理"去反推，比顺着第一反应查参数有效得多。
4. **一次只改一个变量，并且用最小的命令隔离层级。** 比如怀疑框架问题时，先用 `curl` 直连模型服务，确认模型侧没问题，再回到框架侧。

> 这四条里，第 1 条救了我最多时间。它适用于任何"两边对接不上"的场景：客户端不报错、服务端不报错、就是不work——**先确定请求到底有没有出门**。


---

## 十一、值得写下来的几个事实

### 9.1 "Flash / Air / Mini" 不等于小

想找国产厂商的小模型时会踩这个坑：

| 模型 | 名字感觉 | 实际规模 | Q4 体积 | 8GB 能跑？ |
|---|---|---|---|---|
| GLM-4.7-Flash | 轻量 | ~30B | **19 GB** | ❌ |
| GLM-5.3-Flash | 轻量 | **320B（18B 激活）** | ~180 GB | ❌ |
| Qwen3.8-27B | 中等 | 27B | 18 GB | ❌ |
| Qwen3.5-35B-A3B | 中等 | 35B MoE | 22 GB | ❌ |
| **Qwen3.5-9B** | — | 9B dense | **5.5 GB** | ✅ |
| **Qwen3.5-4B** | — | 4B dense | **3.3 GB** | ✅ |

**智谱的开源策略是"大而强"，不做端侧**；端侧路线是 Qwen 和面壁智能（MiniCPM）在走。

### 9.2 本地部署在纯成本上算不过 API

按一天 500 次调用、每次 2 万输入 + 2 千输出算：

| 方案 | 日成本 |
|---|---|
| qwen3.7-flash（API） | ≈ 2.8 元（算上缓存命中可能 1 元内） |
| GLM-5.3-Flash（API） | ≈ 10.8 元 |
| **本地 9B** | 电费 ≈ 0.5 元，但要占 6.5GB 显存 + 一台常开的机器 |

**本地部署唯一不可替代的价值是：断网可用、数据不出机器、零配额限制、以及折腾本身。** 如果只是为了省钱，直接调 API。

### 9.3 真正的瓶颈是内存，不是显存

16GB 里当前只剩 2.8GB（微信 + 浏览器 + Office 就吃掉 8-9GB）。模型加载有峰值，一不小心就开始换页。

这台机器是 **8GB 板载 + 1 条 DDR5 SO-DIMM**（同代轻薄本常见配置，可自行查阅对应机型规格）。把那根 8GB 换成 16GB（约 ¥250）到 24GB，这个瓶颈就没了——**比换显卡现实得多**。

---

## 十二、复现清单

```powershell
# 1. 建目录
New-Item -ItemType Directory -Force D:\local-llm\{bin,models\gguf,logs,scripts,config,bench,docs}

# 2. 下载运行时（多线程，绕开境外限速）
.\scripts\download-parallel.ps1 `
  -Url 'https://gh-proxy.com/https://github.com/ggml-org/llama.cpp/releases/download/b11871/llama-b11871-bin-win-cuda-12.4-x64.zip' `
  -OutFile .\bin\llama-cuda-12.4.zip -Threads 8
.\scripts\download-parallel.ps1 `
  -Url 'https://gh-proxy.com/https://github.com/ggml-org/llama.cpp/releases/download/b11871/cudart-llama-bin-win-cuda-12.4-x64.zip' `
  -OutFile .\bin\cudart-cuda-12.4.zip -Threads 8

# 3. 解压 + 验证 CUDA（必须看到 CUDA0，不能是 none）
Expand-Archive .\bin\llama-cuda-12.4.zip -Dest .\bin\llama -Force
Expand-Archive .\bin\cudart-cuda-12.4.zip -Dest .\bin\llama -Force
.\bin\llama\llama-server.exe --list-devices

# 4. 从魔搭下模型
.\scripts\pull-model.ps1 -Repo unsloth/Qwen3.5-9B-GGUF -File Qwen3.5-9B-Q4_K_M.gguf

# 5. 启动
.\scripts\start.ps1

# 6. 实测
.\scripts\bench.ps1 -LongPrompt
.\scripts\compare.ps1

# 7. 接 DSH：settings.yaml 加 llm-pi-ai 路由 + .credentials.yaml 加占位 key
```

### 检查项 checklist

- [ ] `--list-devices` 输出 `CUDA0: ... RTX 4060 ...`，**不是 `(none)`**
- [ ] `nvidia-smi` 显示显存占用 ≈ 权重体积 + 1-1.5GB
- [ ] 生成速度 ≥ 30 tok/s（明显低于此说明有层跑在 CPU 上）
- [ ] GGUF 文件头是 `GGUF`
- [ ] 思考模式默认关闭（否则小模型会想太多）
- [ ] `contextWindow` ≤ llama-server 的 `-c`
- [ ] DSH 路由配了 `apiKeyEnv`

---

## 十三、最终成果

| 项 | 值 |
|---|---|
| 目录 | `D:\local-llm`（8.97 GB，含 2 个模型） |
| 服务 | `http://127.0.0.1:8080`，模型名 `qwen3.5-9b` |
| 上下文 | 65536（显存 6511 / 8188 MiB） |
| 生成速度 | 40.2 tok/s |
| 模型 | Qwen3.5-9B-Q4_K_M（默认）/ Qwen3.5-4B-Q4_K_M |
| 接入状态 | DSH 已验证：文本 ✅ 工具 ✅ 流式 ✅ 结构化+工具 ❌ |
| 压测状态 | 工具链 ✅ 长文档 ✅ 指令保持 ✅ 报错恢复 ✅ 排序 ❌ 并发 ⚠️ |

配套脚本都在 `scripts\` 里，`README.md` 有完整命令，`bench\` 下有历次实测记录：

| 文件 | 内容 |
|---|---|
| `scripts\start.ps1` `stop.ps1` `status.ps1` | 启停与状态 |
| `scripts\bench.ps1` | 吞吐 / prefill / 显存 / 工具调用基线 |
| `scripts\compare.ps1` | 换模型后的能力横向对比 |
| `scripts\stress.ps1` | 六项压力测试（A-F），可直接复现本文第八节 |
| `scripts\pull-model.ps1` | 从魔搭下 GGUF |
| `scripts\download-parallel.ps1` | 多线程分段下载境外源 |
| `bench\results.md` `compare.md` `stress.md` | 历史实测原始记录 |

整个目录不依赖注册表和服务，拷走就能用（权重和运行时在 `.gitignore` 里，需按第四节重新拉取）。
