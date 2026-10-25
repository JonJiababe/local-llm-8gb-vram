# =====================================================================
# 实测：prefill / 生成速度 / 显存 / 工具调用 / 多轮工具状态
#   用法:  .\scripts\bench.ps1
#          .\scripts\bench.ps1 -NumPredict 512 -LongPrompt
# 结果打印并追加到 .\bench\results.md
# =====================================================================
[CmdletBinding()]
param(
    [int]$NumPredict = 256,
    [switch]$LongPrompt,
    [switch]$SkipTool
)

. "$PSScriptRoot\env.ps1"

if (-not (Get-NetTCPConnection -LocalPort $LlamaPort -State Listen -ErrorAction SilentlyContinue)) {
    Write-Host "[x] 服务没起，先跑 .\scripts\start.ps1" -ForegroundColor Red; exit 1
}

function PostJson($path, $obj, [int]$to = 900) {
    Invoke-RestMethod -Uri "$LlamaBase$path" -Method Post `
        -Body ($obj | ConvertTo-Json -Depth 20 -Compress) `
        -ContentType 'application/json' -TimeoutSec $to
}

$stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$props = try { Invoke-RestMethod -Uri "$LlamaBase/props" -TimeoutSec 5 } catch { $null }
$nCtx  = if ($props) { $props.default_generation_settings.n_ctx } else { $LlamaCtx }
# 以服务实际加载的模型为准，而不是 env.ps1 里写的默认值
$runningModel = if ($props -and $props.model_alias) { $props.model_alias } else { $ModelAlias }

Write-Host "===== bench $runningModel @ $stamp =====" -ForegroundColor Cyan
Write-Host "ctx=$nCtx  thinking=$LlamaThinking  kv=$LlamaKvType" -ForegroundColor DarkGray

# ---------- 1) 纯生成速度 --------------------------------------------
Write-Host "`n[1/4] 生成速度（raw completion）…" -ForegroundColor Yellow
$c = PostJson '/completion' @{
    prompt      = 'Write a short paragraph about local language models running on consumer GPUs.'
    n_predict   = $NumPredict
    temperature = 0.3
    stream      = $false
}
$genTps  = $c.timings.predicted_per_second
$preTps  = $c.timings.prompt_per_second
Write-Host ("    prefill  {0,7:N1} tok/s" -f $preTps)
Write-Host ("    生成      {0,7:N1} tok/s   ({1} tok / {2:N2} s)" -f $genTps, $c.timings.predicted_n, ($c.timings.predicted_ms/1000)) -ForegroundColor Green

# ---------- 2) 长提示 prefill -----------------------------------------
$longPreTps = $null
if ($LongPrompt) {
    Write-Host "`n[2/4] 长上下文 prefill…" -ForegroundColor Yellow
    $filler = ('本地模型部署需要考虑显存带宽、量化精度和上下文长度之间的平衡。' * 240)
    $lc = PostJson '/completion' @{
        prompt = $filler + "`n请用一句话总结上面这段话的主题。"
        n_predict = 32; temperature = 0.2; stream = $false
    }
    $longPreTps = $lc.timings.prompt_per_second
    Write-Host ("    {0} tok 输入 -> prefill {1:N1} tok/s，耗时 {2:N1} s" -f $lc.timings.prompt_n, $longPreTps, ($lc.timings.prompt_ms/1000)) -ForegroundColor Green
}

# ---------- 3) 显存 ---------------------------------------------------
Write-Host "`n[3/4] 显存…" -ForegroundColor Yellow
if (Get-Command nvidia-smi -ErrorAction SilentlyContinue) {
    nvidia-smi --query-gpu=memory.used,memory.total,temperature.gpu,power.draw --format=csv,noheader | ForEach-Object { "    $_" }
}
$memUsed = (nvidia-smi --query-gpu=memory.used --format=csv,noheader 2>$null)

# ---------- 4) 工具调用 -----------------------------------------------
$toolOk = $false; $toolDetail = '跳过'; $multiOk = $false
if (-not $SkipTool) {
    Write-Host "`n[4/4] 工具调用…" -ForegroundColor Yellow
    $tools = @(
        @{ type='function'; function=@{ name='read_file'; description='读取指定路径的文件内容'; parameters=@{ type='object'; properties=@{ path=@{type='string';description='文件绝对路径'}; limit=@{type='integer';description='最多读取行数'} }; required=@('path') } } },
        @{ type='function'; function=@{ name='run_shell'; description='执行一条 PowerShell 命令'; parameters=@{ type='object'; properties=@{ command=@{type='string';description='要执行的命令'} }; required=@('command') } } }
    )
    $msgs = @(@{ role='user'; content='帮我看看 D:\dsh_workplace\README.md 里写了什么，只看前 50 行。' })
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r1 = PostJson '/v1/chat/completions' @{ messages=$msgs; tools=$tools; tool_choice='auto'; max_tokens=400; temperature=0; stream=$false }
    $sw.Stop()
    $m1 = $r1.choices[0].message
    if ($m1.tool_calls) {
        $toolOk = $true
        foreach ($t in $m1.tool_calls) {
            Write-Host ("    ✔ {0}({1})   [{2:N1}s]" -f $t.function.name, $t.function.arguments, $sw.Elapsed.TotalSeconds) -ForegroundColor Green
            $toolDetail = "$($t.function.name)($($t.function.arguments))"
        }
        # 多轮：塞回工具结果，看它能不能收敛
        $msgs += @{ role='assistant'; content=$null; tool_calls=$m1.tool_calls }
        $msgs += @{ role='tool'; tool_call_id=$m1.tool_calls[0].id; content="# dsh_workplace`n这是工作区根目录，包含若干子项目。" }
        $r2 = PostJson '/v1/chat/completions' @{ messages=$msgs; tools=$tools; max_tokens=300; temperature=0; stream=$false }
        $m2 = $r2.choices[0].message
        if ($m2.content -and -not $m2.tool_calls) {
            $multiOk = $true
            $ans = ($m2.content -replace "`n",' ')
            Write-Host ("    ✔ 多轮收敛：{0}" -f $ans.Substring(0,[Math]::Min(90,$ans.Length))) -ForegroundColor Green
        } else {
            Write-Host "    ⚠ 第二轮没有收敛成文本回复（可能又发起工具调用）" -ForegroundColor Yellow
        }
    } else {
        $toolDetail = '未返回 tool_calls'
        Write-Host "    ✘ 没走工具调用，直接文本：" -ForegroundColor Red
        $txt = ($m1.content -replace "`n",' ')
        Write-Host ("      " + $txt.Substring(0,[Math]::Min(160,$txt.Length)))
    }
}

# ---------- 记录 ------------------------------------------------------
$md = @"

## $stamp — $runningModel
| 指标 | 值 |
|---|---|
| 模型 | $runningModel |`n| 上下文 | $nCtx |
| 思考模式 | $LlamaThinking |
| 生成速度 | **$([math]::Round($genTps,1)) tok/s** |
| 短提示 prefill | $([math]::Round($preTps,1)) tok/s |
| 长提示 prefill | $(if ($longPreTps) { "$([math]::Round($longPreTps,1)) tok/s" } else { '未测' }) |
| GPU 显存 | $memUsed |
| 工具调用 | $(if ($toolOk) { "通过 — $toolDetail" } else { $toolDetail }) |
| 多轮工具 | $(if ($multiOk) { '收敛正常' } elseif ($toolOk) { '未收敛' } else { '未测' }) |

"@
New-Item -ItemType Directory -Force -Path $LocalLlmBench | Out-Null
$rf = Join-Path $LocalLlmBench 'results.md'
if (-not (Test-Path $rf)) { Set-Content -Path $rf -Value "# 本地模型实测记录`n" -Encoding utf8 }
Add-Content -Path $rf -Value $md -Encoding utf8
Write-Host "`n[+] 已记录到 $rf" -ForegroundColor Cyan
