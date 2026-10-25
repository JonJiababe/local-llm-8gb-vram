# =====================================================================
# 启动本地模型服务 (llama-server)
#   用法:  .\scripts\start.ps1
#          .\scripts\start.ps1 -Model Qwen3.5-9B-Q4_K_M.gguf
#          .\scripts\start.ps1 -Ctx 32768
#          .\scripts\start.ps1 -Force      # 端口被占时先杀掉
#
# 只监听 127.0.0.1，不出内网。
# =====================================================================
[CmdletBinding()]
param(
    [string]$Model,
    [int]$Ctx,
    [int]$GpuLayers,
    [string]$Thinking,
    [switch]$Force
)

. "$PSScriptRoot\env.ps1"

if ($Model) {
    $ModelPath  = Join-Path $LocalLlmModels $Model
    # 别名去掉量化后缀，让 API 里看到的是 qwen3.5-9b 而不是 qwen3.5-9b-q4_k_m
    $base = $Model -replace '\.gguf$', ''
    $ModelAlias = ($base -replace '[-_.]((IQ|Q)\d[\w]*|BF16|F16|UD-[\w]+)$', '').ToLower()
}
if ($Ctx)        { $LlamaCtx = $Ctx }
if ($GpuLayers -ne $null -and $PSBoundParameters.ContainsKey('GpuLayers')) { $LlamaGpuLayers = $GpuLayers }
if ($Thinking)   { $LlamaThinking = $Thinking }

if (-not (Test-Path $LlamaServerExe)) {
    Write-Host "[x] 找不到 $LlamaServerExe" -ForegroundColor Red
    Write-Host "    下载: .\scripts\download-parallel.ps1 -Url <llama.cpp release zip> -OutFile .\bin\llama.zip" -ForegroundColor DarkGray
    exit 1
}
if (-not (Test-Path $ModelPath)) {
    Write-Host "[x] 找不到模型 $ModelPath" -ForegroundColor Red
    Write-Host "    下载: .\scripts\pull-model.ps1 -Repo unsloth/Qwen3.5-4B-GGUF -File Qwen3.5-4B-Q4_K_M.gguf" -ForegroundColor DarkGray
    exit 1
}

# ---------- 端口检查 --------------------------------------------------
$inUse = Get-NetTCPConnection -LocalPort $LlamaPort -State Listen -ErrorAction SilentlyContinue
if ($inUse) {
    $procId = $inUse[0].OwningProcess
    $procName = (Get-Process -Id $procId -ErrorAction SilentlyContinue).ProcessName
    if (-not $Force) {
        Write-Host "[=] 端口 $LlamaPort 已在监听 (PID $procId, $procName) —— 服务本来就在跑" -ForegroundColor Yellow
        exit 0
    }
    Write-Host "[!] 结束占用端口的 $procName (PID $procId)" -ForegroundColor Yellow
    Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}

New-Item -ItemType Directory -Force -Path $LocalLlmLogs | Out-Null

# ---------- 组装参数 --------------------------------------------------
$srvArgs = @(
    '-m', $ModelPath
    '-a', $ModelAlias
    '--host', $LlamaHost
    '--port', "$LlamaPort"
    '-ngl', "$LlamaGpuLayers"
    '-c',   "$LlamaCtx"
    '-np',  "$LlamaParallel"
    '-t',   "$LlamaThreads"
    '-fa',  $LlamaFlashAttn
    '-ctk', $LlamaKvType
    '-ctv', $LlamaKvType
    '--jinja'
    '--reasoning-format', $LlamaReasoningFormat
    '--reasoning', $LlamaThinking
    '--reasoning-budget', "$LlamaReasoningBudget"
    '--log-file', $LlamaServerLog
)

Write-Host "[>] 启动 llama-server" -ForegroundColor Cyan
Write-Host "    模型   $(Split-Path $ModelPath -Leaf)  ($([math]::Round((Get-Item $ModelPath).Length/1GB,2)) GB)"
Write-Host "    别名   $ModelAlias"
Write-Host "    监听   $LlamaBase   层数=$LlamaGpuLayers  ctx=$LlamaCtx  kv=$LlamaKvType  fa=$LlamaFlashAttn"
Write-Host "    思考   $LlamaThinking  (预算 $LlamaReasoningBudget token)" 

$proc = Start-Process -FilePath $LlamaServerExe -ArgumentList $srvArgs `
    -RedirectStandardOutput $LlamaServerLog -RedirectStandardError $LlamaServerErr `
    -WindowStyle Hidden -PassThru

# ---------- 等待就绪 --------------------------------------------------
$deadline = (Get-Date).AddSeconds(180)
$ready = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Milliseconds 700
    if ($proc.HasExited) { break }
    try {
        $h = Invoke-RestMethod -Uri "$LlamaBase/health" -TimeoutSec 3 -ErrorAction Stop
        if ($h.status -eq 'ok') { $ready = $true; break }
    } catch { }
}

if (-not $ready) {
    Write-Host "[x] 启动失败（退出码 $($proc.ExitCode)）" -ForegroundColor Red
    Write-Host "--- $LlamaServerErr 尾部 ---" -ForegroundColor DarkGray
    Get-Content $LlamaServerErr -Tail 25 -ErrorAction SilentlyContinue
    Write-Host "--- $LlamaServerLog 尾部 ---" -ForegroundColor DarkGray
    Get-Content $LlamaServerLog -Tail 15 -ErrorAction SilentlyContinue
    if (-not $proc.HasExited) { Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue }
    exit 1
}

Write-Host "[+] 就绪  PID $($proc.Id)" -ForegroundColor Green
if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
    nvidia-smi --query-gpu=memory.used,memory.total,temperature.gpu --format=csv,noheader | ForEach-Object { "    GPU: $_" }
}
Write-Host ""
Write-Host "  .\scripts\bench.ps1              # 测吞吐 + 工具调用" -ForegroundColor Cyan
Write-Host "  .\scripts\status.ps1             # 看状态" -ForegroundColor Cyan
Write-Host "  .\scripts\stop.ps1               # 停止并释放显存" -ForegroundColor Cyan
