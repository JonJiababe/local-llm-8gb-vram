# =====================================================================
# 停止本地模型服务，释放显存
#   用法:  .\scripts\stop.ps1
# =====================================================================
. "$PSScriptRoot\env.ps1"

$conns = Get-NetTCPConnection -LocalPort $LlamaPort -State Listen -ErrorAction SilentlyContinue
if (-not $conns) {
    # 端口没监听，也扫一下有没有残留进程
    $leftover = Get-Process llama-server -ErrorAction SilentlyContinue
    if ($leftover) {
        $leftover | ForEach-Object { Write-Host "[>] 结束残留 llama-server PID $($_.Id)" -ForegroundColor Cyan; Stop-Process -Id $_.Id -Force }
        Write-Host "[+] 已清理" -ForegroundColor Green
    } else {
        Write-Host "[=] 服务本来就没在跑" -ForegroundColor Yellow
    }
    exit 0
}

foreach ($c in $conns) {
    Write-Host "[>] 结束 PID $($c.OwningProcess)（端口 $LlamaPort）" -ForegroundColor Cyan
    Stop-Process -Id $c.OwningProcess -Force -ErrorAction SilentlyContinue
}
Start-Sleep -Seconds 1

if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
    $used = (nvidia-smi --query-gpu=memory.used --format=csv,noheader)
    Write-Host "[+] 已停止，当前显存占用 $used" -ForegroundColor Green
} else {
    Write-Host "[+] 已停止" -ForegroundColor Green
}
