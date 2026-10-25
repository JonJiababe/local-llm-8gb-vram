# =====================================================================
# local-llm 配置文件（所有脚本 dot-source 它）
#   用法:  . "$PSScriptRoot\env.ps1"
#
# 这套部署全部关在 D:\local-llm 内：运行时、权重、日志、结果。
# 换模型 / 调上下文只要改这个文件。
# =====================================================================

# ---------- 目录 ------------------------------------------------------
$LocalLlmRoot    = 'D:\local-llm'
$LocalLlmBin     = Join-Path $LocalLlmRoot 'bin\llama'        # llama.cpp 运行时
$LocalLlmModels  = Join-Path $LocalLlmRoot 'models\gguf'      # GGUF 权重
$LocalLlmLogs    = Join-Path $LocalLlmRoot 'logs'
$LocalLlmBench   = Join-Path $LocalLlmRoot 'bench'
$LlamaServerExe  = Join-Path $LocalLlmBin 'llama-server.exe'

# ---------- 当前使用的模型 -------------------------------------------
# 换模型只改这两行（配合 .\scripts\pull-model.ps1 下载）
$ModelFile  = 'Qwen3.5-9B-Q4_K_M.gguf'
$ModelPath  = Join-Path $LocalLlmModels $ModelFile
$ModelAlias = 'qwen3.5-9b'          # API 里看到的模型名，DSH 配置要用这个

# ---------- 服务参数 --------------------------------------------------
$LlamaPort   = 8080
$LlamaHost   = '127.0.0.1'
$LlamaBase   = "http://${LlamaHost}:${LlamaPort}"

# ---------- 8GB 显存专项 ---------------------------------------------
$LlamaGpuLayers = 99                 # 99 = 全部层上 GPU
$LlamaCtx       = 65536              # 上下文；必须与 DSH 路由里的 contextWindow 一致
$LlamaKvType    = 'q8_0'             # KV cache 量化，省一半 KV 显存
$LlamaParallel  = 1                  # 单并发：8GB 卡扛不住并行槽
$LlamaThreads   = 8                  # CPU 线程（prefill 和 CPU 回退时用）
$LlamaFlashAttn = 'on'               # Ada (RTX 4060) 支持 flash attention

# 思考模式：Qwen3.5 默认会先输出推理过程。
#   实测 4B 在简单任务上会"想太多"——1500 token 全烧在推理里还没出答案，
#   所以必须给思考设预算，否则会把 max_tokens 吃光。
#   $LlamaThinking = 'off' | 'off'   （off 等于完全关掉推理）
#   $LlamaReasoningBudget = 0 关闭 / -1 不限制 / N>0 = 思考最多 N token
$LlamaThinking = 'off'
$LlamaReasoningBudget  = 256
# 思考内容怎么返回：none / deepseek(放进 reasoning_content) / deepseek-legacy
$LlamaReasoningFormat  = 'deepseek'

# ---------- 日志 ------------------------------------------------------
$LlamaServerLog = Join-Path $LocalLlmLogs 'llama-server.log'
$LlamaServerErr = Join-Path $LocalLlmLogs 'llama-server.err.log'

