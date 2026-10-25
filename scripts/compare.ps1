# =====================================================================
# 4B / 9B 能力横向对比
#   用法:  .\scripts\compare.ps1            # 测当前正在跑的模型
# 每次重启换模型后跑一遍，结果追加到 .\bench\compare.md
# =====================================================================
[CmdletBinding()]
param([int]$MaxTokens = 700)

. "$PSScriptRoot\env.ps1"

$props = try { Invoke-RestMethod -Uri "$LlamaBase/props" -TimeoutSec 5 } catch { $null }
$model = if ($props) { $props.model_alias } else { 'unknown' }

function Ask($q, $mt = $MaxTokens) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-RestMethod -Uri "$LlamaBase/v1/chat/completions" -Method Post -ContentType 'application/json' -TimeoutSec 600 `
        -Body (@{ messages = @(@{ role = 'user'; content = $q }); max_tokens = $mt; temperature = 0; stream = $false } | ConvertTo-Json -Depth 8)
    $sw.Stop()
    [pscustomobject]@{
        Text  = ($r.choices[0].message.content -replace "`r", '').Trim()
        Secs  = [math]::Round($sw.Elapsed.TotalSeconds, 2)
        Toks  = $r.usage.completion_tokens
        Finish = $r.choices[0].finish_reason
    }
}

New-Item -ItemType Directory -Force -Path $LocalLlmBench | Out-Null
$rf = Join-Path $LocalLlmBench 'compare.md'
$sb = [System.Text.StringBuilder]::new()
[void]$sb.AppendLine("`n## $(Get-Date -Format 'yyyy-MM-dd HH:mm') — $model`n")

Write-Host "===== 对比测试：$model =====" -ForegroundColor Cyan

# --- 用例 1：字数硬约束 ------------------------------------------------
$q1 = '用恰好 20 个汉字总结下面这段话，只输出摘要本身，不要任何解释或标点补充：本地大模型部署的核心矛盾是显存容量与模型参数规模之间的取舍，量化技术通过降低数值精度来压缩权重体积，从而让小显存显卡也能运行较大的模型。'
$r1 = Ask $q1
$len = ($r1.Text -replace '[\s，。、；：！？""''（）()]', '').Length
$ok1 = ($len -eq 20)
Write-Host "`n[1] 字数约束（要求恰好20字）" -ForegroundColor Yellow
Write-Host "    $($r1.Text)"
Write-Host ("    实际 {0} 字 -> {1}  [{2}s]" -f $len, $(if ($ok1) { '✔ 通过' } else { '✘ 不符' }), $r1.Secs) -ForegroundColor $(if ($ok1) { 'Green' } else { 'Red' })

# --- 用例 2：工具选择 + 干扰项 -----------------------------------------
$tools = @(
    @{ type='function'; function=@{ name='list_files'; description='列出目录下的文件'; parameters=@{ type='object'; properties=@{ path=@{type='string'} }; required=@('path') } } },
    @{ type='function'; function=@{ name='read_file'; description='读取单个文件内容'; parameters=@{ type='object'; properties=@{ path=@{type='string'}; limit=@{type='integer'} }; required=@('path') } } },
    @{ type='function'; function=@{ name='delete_file'; description='删除文件（危险操作）'; parameters=@{ type='object'; properties=@{ path=@{type='string'} }; required=@('path') } } }
)
$q2 = 'D:\dsh_workplace 这个目录下都有哪些文件？'
$sw = [Diagnostics.Stopwatch]::StartNew()
$r2 = Invoke-RestMethod -Uri "$LlamaBase/v1/chat/completions" -Method Post -ContentType 'application/json' -TimeoutSec 600 `
    -Body (@{ messages=@(@{role='user';content=$q2}); tools=$tools; tool_choice='auto'; max_tokens=300; temperature=0; stream=$false } | ConvertTo-Json -Depth 12)
$sw.Stop()
$tc = $r2.choices[0].message.tool_calls
$ok2 = ($tc -and $tc[0].function.name -eq 'list_files')
Write-Host "`n[2] 工具选择（应选 list_files，不该选 delete_file）" -ForegroundColor Yellow
if ($tc) {
    Write-Host ("    选中 {0}({1}) -> {2}  [{3:N1}s]" -f $tc[0].function.name, $tc[0].function.arguments, $(if ($ok2) { '✔ 通过' } else { '✘ 选错' }), $sw.Elapsed.TotalSeconds) -ForegroundColor $(if ($ok2) { 'Green' } else { 'Red' })
} else {
    Write-Host "    ✘ 没发起工具调用，直接文本回复" -ForegroundColor Red
    $ok2 = $false
}

# --- 用例 3：写代码 ----------------------------------------------------
$q3 = '写一个 PowerShell 函数 Get-TopFiles，接收目录路径和数量两个参数，按文件大小降序返回前 N 个文件的名称和大小（MB）。只输出代码，不要解释。'
$r3 = Ask $q3 900
$hasParam = ($r3.Text -match 'param\s*\(' -or $r3.Text -match '\$Path' -or $r3.Text -match 'function')
$hasSort  = ($r3.Text -match 'Sort-Object' -and $r3.Text -match 'Length')
# 题目要求"返回名称和大小"，两个都得有：只有大小不算过
$hasName  = ($r3.Text -match '(?i)\bName\b|文件名|名称')
$hasSize  = ($r3.Text -match '(?i)SizeMB|Length\s*/|/ 1MB|大小')
$ok3 = ($hasParam -and $hasSort -and $hasName -and $hasSize)
Write-Host "`n[3] 写代码（Get-TopFiles，必须同时返回名称和大小）" -ForegroundColor Yellow
Write-Host ("    函数={0} 排序={1} 名称={2} 大小={3}  -> {4}  [{5}s, {6} tok]" -f $hasParam, $hasSort, $hasName, $hasSize, $(if ($ok3) { '✔ 通过' } else { '✘ 不完整' }), $r3.Secs, $r3.Toks) -ForegroundColor $(if ($ok3) { 'Green' } else { 'Red' })

$score = @($ok1, $ok2, $ok3) | Where-Object { $_ } | Measure-Object | Select-Object -ExpandProperty Count

[void]$sb.AppendLine('| 用例 | 结果 | 耗时 |')
[void]$sb.AppendLine('|---|---|---|')
[void]$sb.AppendLine("| 恰好20字摘要 | $(if ($ok1) { '通过' } else { '失败' })（实际 $len 字） | $($r1.Secs)s |")
[void]$sb.AppendLine("| 工具选择 | $(if ($ok2) { '通过' } else { '失败' }) | $([math]::Round($sw.Elapsed.TotalSeconds,1))s |")
[void]$sb.AppendLine("| 写代码 | $(if ($ok3) { '通过' } else { '失败' }) | $($r3.Secs)s / $($r3.Toks) tok |")
[void]$sb.AppendLine("")
[void]$sb.AppendLine("**得分：$score / 3**")
[void]$sb.AppendLine("")
[void]$sb.AppendLine('<details><summary>原始输出</summary>')
[void]$sb.AppendLine("")
[void]$sb.AppendLine('```')
[void]$sb.AppendLine("[1] $($r1.Text)")
[void]$sb.AppendLine("[3] $($r3.Text)")
[void]$sb.AppendLine('```')
[void]$sb.AppendLine('</details>')
Add-Content -Path $rf -Value $sb.ToString() -Encoding utf8

Write-Host "`n===== 得分 $score / 3  =====" -ForegroundColor Cyan
Write-Host "[+] 已记录到 $rf" -ForegroundColor Cyan
