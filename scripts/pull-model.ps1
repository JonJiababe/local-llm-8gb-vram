# =====================================================================
# 从魔搭（ModelScope）拉 GGUF 权重到 .\models\gguf\
#   用法:  .\scripts\pull-model.ps1 -Repo unsloth/Qwen3.5-4B-GGUF -File Qwen3.5-4B-Q4_K_M.gguf
#          .\scripts\pull-model.ps1 -List -Repo unsloth/Qwen3.5-4B-GGUF
#          .\scripts\pull-model.ps1 -Repo unsloth/Qwen3.5-9B-GGUF -File Qwen3.5-9B-Q4_K_M.gguf -ThenUse
#
# 为什么用魔搭：HuggingFace 在本机不通；魔搭实测 ~3.8 MB/s，
# 而走代理访问境外源只有 ~0.65 MB/s。
# =====================================================================
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Repo,
    [string]$File,
    [switch]$List,
    [switch]$ThenUse
)

. "$PSScriptRoot\env.ps1"
$ErrorActionPreference = 'Stop'

$apiUrl = "https://modelscope.cn/api/v1/models/$Repo/repo/files?Revision=master"
Write-Host "[i] 查询 $Repo" -ForegroundColor DarkGray
$meta = Invoke-RestMethod -Uri $apiUrl -TimeoutSec 30 -Headers @{'User-Agent' = 'Mozilla/5.0'}
$files = $meta.Data.Files | Where-Object { $_.Name -match '\.gguf$' }

if (-not $files) { Write-Host "[x] 该仓库没有 .gguf 文件" -ForegroundColor Red; exit 1 }

if ($List -or -not $File) {
    Write-Host "`n可用 GGUF：" -ForegroundColor Cyan
    $files | Sort-Object Size | ForEach-Object {
        "  {0,-44} {1,7:N0} MB" -f $_.Name, ($_.Size / 1MB)
    }
    Write-Host "`n挑一个，用 -File 指定。例：" -ForegroundColor DarkGray
    Write-Host "  .\scripts\pull-model.ps1 -Repo $Repo -File <文件名>" -ForegroundColor DarkGray
    return
}

$entry = $files | Where-Object { $_.Name -eq $File } | Select-Object -First 1
if (-not $entry) {
    Write-Host "[x] 仓库里没有 $File。加 -List 看可用文件。" -ForegroundColor Red
    exit 1
}

New-Item -ItemType Directory -Force -Path $LocalLlmModels | Out-Null
$out = Join-Path $LocalLlmModels $File
$expected = [int64]$entry.Size

if ((Test-Path $out) -and ((Get-Item $out).Length -eq $expected)) {
    Write-Host "[=] 已存在且大小一致 ($([math]::Round($expected/1GB,2)) GB)，跳过" -ForegroundColor Yellow
} else {
    $url = "https://modelscope.cn/api/v1/models/$Repo/repo?Revision=master&FilePath=$File"
    Write-Host ("[>] 下载 {0}  ({1:N0} MB) -> {2}" -f $File, ($expected/1MB), $out) -ForegroundColor Cyan
    curl.exe -L --retry 5 --retry-delay 3 --retry-all-errors -C - -o $out $url
    $actual = (Get-Item $out).Length
    if ($actual -ne $expected) {
        Write-Host ("[x] 大小不符: {0} vs {1} —— 重跑本命令会自动续传" -f $actual, $expected) -ForegroundColor Red
        exit 1
    }
    Write-Host ("[+] 完成 {0:N2} GB" -f ($actual/1GB)) -ForegroundColor Green
}

# 校验 GGUF magic
$fs = [System.IO.File]::OpenRead($out)
$buf = New-Object byte[] 4
$fs.Read($buf, 0, 4) | Out-Null
$fs.Dispose()
$magic = [System.Text.Encoding]::ASCII.GetString($buf)
if ($magic -ne 'GGUF') {
    Write-Host "[x] 文件头不是 GGUF（得到 '$magic'），文件可能损坏" -ForegroundColor Red
    exit 1
}
Write-Host "[+] GGUF 文件头校验通过" -ForegroundColor Green

if ($ThenUse) {
    Write-Host "`n[i] 已切换建议模型为 $File" -ForegroundColor Cyan
    Write-Host "    把 scripts\env.ps1 里的 `$ModelFile 改成 $File ，或启动时用：" -ForegroundColor DarkGray
    Write-Host "    .\scripts\start.ps1 -Model $File" -ForegroundColor DarkGray
}
