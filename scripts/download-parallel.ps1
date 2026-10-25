# =====================================================================
# 多线程分段下载（应对境外源限速）
#   用法:  .\scripts\download-parallel.ps1 -Url <url> -OutFile <path> [-Threads 8]
#
# 为什么要它：本机到境外的单连接只有 ~650 KB/s，多连接分段能提到 1.5-2 MB/s。
# 断点续传：已完成的 .partN 会跳过，重跑即可继续。
# =====================================================================
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Url,
    [Parameter(Mandatory = $true)][string]$OutFile,
    [int]$Threads = 8,
    [int]$ChunkMB = 6
)

$ErrorActionPreference = 'Stop'

function Get-RemoteSize([string]$u) {
    $h = curl.exe -sIL --max-time 30 $u 2>$null
    $lens = [regex]::Matches(($h -join "`n"), '(?im)^content-length:\s*(\d+)\s*$') | ForEach-Object { [int64]$_.Groups[1].Value }
    if ($lens.Count -eq 0) { return 0 }
    return ($lens | Measure-Object -Maximum).Maximum
}

$total = Get-RemoteSize $Url
if ($total -le 0) { throw "拿不到远端文件大小: $Url" }
Write-Host ("[i] 远端大小 {0:N1} MB" -f ($total / 1MB)) -ForegroundColor DarkGray

if ((Test-Path $OutFile) -and ((Get-Item $OutFile).Length -eq $total)) {
    Write-Host "[=] 已存在且大小一致，跳过" -ForegroundColor Yellow
    return
}

$partDir = "$OutFile.parts"
New-Item -ItemType Directory -Force -Path $partDir | Out-Null

$chunk = [int64]$ChunkMB * 1MB
$ranges = @()
for ($s = [int64]0; $s -lt $total; $s += $chunk) {
    $e = [Math]::Min($s + $chunk - 1, $total - 1)
    $idx = [int]($s / $chunk)
    $partName = 'part{0:D4}' -f $idx
    $ranges += [pscustomobject]@{ Start = $s; End = $e; Part = (Join-Path $partDir $partName) }
}
Write-Host ("[i] 切成 {0} 段 x {1} MB，并发 {2}" -f $ranges.Count, $ChunkMB, $Threads) -ForegroundColor DarkGray

$sw = [Diagnostics.Stopwatch]::StartNew()
$queue = [System.Collections.Queue]::new()
$ranges | ForEach-Object { $queue.Enqueue($_) }
$running = @()

while ($queue.Count -gt 0 -or $running.Count -gt 0) {
    while ($running.Count -lt $Threads -and $queue.Count -gt 0) {
        $r = $queue.Dequeue()
        if ((Test-Path $r.Part) -and ((Get-Item $r.Part).Length -eq ($r.End - $r.Start + 1))) { continue }
        $p = Start-Process -FilePath 'curl.exe' `
            -ArgumentList @('-sS', '-L', '--retry', '5', '--retry-all-errors', '--max-time', '300',
                            '-r', "$($r.Start)-$($r.End)", '-o', $r.Part, $Url) `
            -PassThru -WindowStyle Hidden
        $running += $p
    }
    if ($running.Count -eq 0) { continue }
    $running = @($running | Where-Object { -not $_.HasExited })
    Start-Sleep -Milliseconds 300

    $done = (Get-ChildItem $partDir -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    $pct = if ($total -gt 0) { $done / $total * 100 } else { 0 }
    $rate = ($done / 1KB) / [Math]::Max($sw.Elapsed.TotalSeconds, 0.1)
    Write-Progress -Activity "下载 $([IO.Path]::GetFileName($OutFile))" `
        -Status ("{0:N1} / {1:N1} MB  ({2:N0}%)  {3:N0} KB/s" -f ($done/1MB), ($total/1MB), $pct, $rate) `
        -PercentComplete ([Math]::Min(100, $pct))
}
$sw.Stop()

# --- 拼接 --------------------------------------------------------------
$missing = $ranges | Where-Object { -not (Test-Path $_.Part) -or (Get-Item $_.Part).Length -ne ($_.End - $_.Start + 1) }
if ($missing) {
    Write-Host ("[x] {0} 段不完整，重跑本命令即可续传" -f $missing.Count) -ForegroundColor Red
    $missing | Select-Object -First 5 | ForEach-Object { "    " + $_.Part }
    exit 1
}

Write-Host "[>] 拼接…" -ForegroundColor Cyan
$out = [System.IO.File]::Create($OutFile)
try {
    foreach ($r in ($ranges | Sort-Object Start)) {
        $in = [System.IO.File]::OpenRead($r.Part)
        try { $in.CopyTo($out) } finally { $in.Dispose() }
    }
} finally { $out.Dispose() }

Remove-Item $partDir -Recurse -Force -ErrorAction SilentlyContinue

$final = (Get-Item $OutFile).Length
if ($final -ne $total) {
    Write-Host ("[x] 大小不符: 实际 {0} vs 期望 {1}" -f $final, $total) -ForegroundColor Red
    exit 1
}
Write-Host ("[+] 完成 {0}  {1:N1} MB  用时 {2:N1} 分钟  平均 {3:N0} KB/s" -f `
    $OutFile, ($final/1MB), ($sw.Elapsed.TotalMinutes), (($final/1KB)/[Math]::Max($sw.Elapsed.TotalSeconds,0.1))) -ForegroundColor Green
