# =====================================================================
# 查看本地模型服务状态
#   用法:  .\scripts\status.ps1
# =====================================================================
. "$PSScriptRoot\env.ps1"

function Section($t) { Write-Host ""; Write-Host "── $t " -ForegroundColor Cyan }

Section '服务'
$conns = Get-NetTCPConnection -LocalPort $LlamaPort -State Listen -ErrorAction SilentlyContinue
if ($conns) {
    try {
        $h = Invoke-RestMethod -Uri "$LlamaBase/health" -TimeoutSec 3
        Write-Host ("  运行中  {0}  PID={1}  health={2}" -f $LlamaBase, $conns[0].OwningProcess, $h.status) -ForegroundColor Green
        try {
            $props = Invoke-RestMethod -Uri "$LlamaBase/props" -TimeoutSec 3
            Write-Host ("  模型      {0}" -f $props.model_alias)
            Write-Host ("  上下文    {0} tok" -f $props.default_generation_settings.n_ctx)
            Write-Host ("  槽位      {0}" -f $props.total_slots)
            $tl = $props.build_info
        } catch { }
    } catch {
        Write-Host "  端口在监听但 /health 无响应" -ForegroundColor Yellow
    }
} else {
    Write-Host "  未运行 —— .\scripts\start.ps1" -ForegroundColor Yellow
}

Section '显存'
if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
    nvidia-smi --query-gpu=memory.used,memory.total,utilization.gpu,temperature.gpu,power.draw --format=csv,noheader | ForEach-Object { "  $_" }
} else { Write-Host "  无 nvidia-smi" -ForegroundColor DarkGray }

Section '已下载的模型'
if (Test-Path $LocalLlmModels) {
    $ggufs = Get-ChildItem $LocalLlmModels -Filter *.gguf -File -ErrorAction SilentlyContinue
    if ($ggufs) {
        $ggufs | Sort-Object Name | ForEach-Object {
            $mark = if ($_.Name -eq $ModelFile) { ' <- 当前' } else { '' }
            "  {0,-40} {1,6:N2} GB{2}" -f $_.Name, ($_.Length/1GB), $mark
        }
    } else { Write-Host "  （空）" -ForegroundColor DarkGray }
}

Section '目录占用'
$sz = (Get-ChildItem $LocalLlmRoot -Recurse -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
Write-Host ("  {0}  合计 {1:N2} GB" -f $LocalLlmRoot, ($sz/1GB))
$d = Get-PSDrive D -ErrorAction SilentlyContinue
if ($d) { Write-Host ("  D: 剩余 {0:N0} GB" -f ($d.Free/1GB)) }
