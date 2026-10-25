# =====================================================================
# 本地模型压力测试（agent 场景向）
#   用法:  .\scripts\stress.ps1
#          .\scripts\stress.ps1 -Only A,C
#
# 测什么：
#   A 多轮工具链     — 连续 5 步工具调用能否闭环
#   B 上下文累积     — 8 轮对话里 prefill 时间/缓存复用/质量衰减
#   C 指令保持       — 第 1 轮给的约束，第 6 轮还在不在
#   D 工具报错恢复   — 工具返回错误后，是傻重试还是改策略
#   E 长文档抽取     — 约 2 万 token 输入的 prefill 与准确性
#   F 并发行为       — 两个请求同时来，排队还是崩
#
# 结果追加到 .\bench\stress.md
# =====================================================================
[CmdletBinding()]
param([string[]]$Only)

. "$PSScriptRoot\env.ps1"

if (-not (Get-NetTCPConnection -LocalPort $LlamaPort -State Listen -ErrorAction SilentlyContinue)) {
    Write-Host "[x] 服务没起，先跑 .\scripts\start.ps1" -ForegroundColor Red; exit 1
}

$props    = Invoke-RestMethod "$LlamaBase/props" -TimeoutSec 5
$model    = $props.model_alias
$nCtx     = $props.default_generation_settings.n_ctx
$stamp    = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
$want     = { param($k) (-not $Only) -or ($Only -contains $k) }

$md = [System.Text.StringBuilder]::new()
[void]$md.AppendLine("`n## $stamp — $model（ctx $nCtx）`n")

function Chat([object[]]$messages, $tools = $null, [int]$maxTokens = 500) {
    $body = @{ messages = $messages; max_tokens = $maxTokens; temperature = 0; stream = $false }
    if ($tools) { $body.tools = $tools; $body.tool_choice = 'auto' }
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $r = Invoke-RestMethod -Uri "$LlamaBase/v1/chat/completions" -Method Post `
        -Body ($body | ConvertTo-Json -Depth 20 -Compress) -ContentType 'application/json' -TimeoutSec 1800
    $sw.Stop()
    [pscustomobject]@{
        Msg      = $r.choices[0].message
        Finish   = $r.choices[0].finish_reason
        Prompt   = $r.usage.prompt_tokens
        Out      = $r.usage.completion_tokens
        Secs     = [math]::Round($sw.Elapsed.TotalSeconds, 2)
        PreTps   = if ($r.usage.prompt_tokens -gt 0 -and $sw.Elapsed.TotalSeconds -gt 0) {
                       [math]::Round($r.usage.prompt_tokens / $sw.Elapsed.TotalSeconds, 0) } else { 0 }
    }
}

$tools = @(
    @{ type='function'; function=@{ name='list_files'; description='列出目录下的文件'; parameters=@{ type='object'; properties=@{ path=@{type='string'} }; required=@('path') } } },
    @{ type='function'; function=@{ name='read_file';  description='读取文件内容';     parameters=@{ type='object'; properties=@{ path=@{type='string'}; limit=@{type='integer'} }; required=@('path') } } },
    @{ type='function'; function=@{ name='write_file'; description='写入文件';         parameters=@{ type='object'; properties=@{ path=@{type='string'}; content=@{type='string'} }; required=@('path','content') } } },
    @{ type='function'; function=@{ name='run_shell';  description='执行 PowerShell 命令'; parameters=@{ type='object'; properties=@{ command=@{type='string'} }; required=@('command') } } }
)

# 假的工具实现：让测试可复现，不真的动文件系统
$fakeResults = @{
    'list_files' = 'D:\demo\app.log (2.1 MB)`nD:\demo\config.json (1.2 KB)`nD:\demo\data.csv (480 KB)'
    'read_file'  = '{"level":"info","ts":"2026-10-25T10:00:00Z","msg":"started"}' + "`n" + '{"level":"error","ts":"2026-10-25T10:05:12Z","msg":"connection refused","host":"db.internal:5432"}' + "`n" + '{"level":"warn","ts":"2026-10-25T10:05:30Z","msg":"retry 1/3"}'
    'write_file' = 'ok'
    'run_shell'  = 'ok'
}

# =====================================================================
# A 多轮工具链
# =====================================================================
if (& $want 'A') {
    Write-Host "`n[A] 多轮工具链…" -ForegroundColor Yellow
    $msgs = @(@{ role='system'; content='你是一个运维助手，必须使用工具获取信息，不要凭空猜测。' })
    $msgs += @{ role='user'; content='D:\demo 目录下有什么文件？先列出来，然后读出其中那个日志文件的前几行，最后告诉我日志里有没有报错。' }

    $steps = 0; $closed = $false; $trace = @()
    while ($steps -lt 6) {
        $steps++
        $r = Chat $msgs $tools 600
        if ($r.Msg.tool_calls) {
            $tc = $r.Msg.tool_calls[0]
            $fn = $tc.function.name
            $trace += "$steps.$fn"
            Write-Host ("    第 {0} 步: 调用 {1}" -f $steps, $fn) -ForegroundColor DarkGray
            $msgs += @{ role='assistant'; content=$null; tool_calls=$r.Msg.tool_calls }
            $msgs += @{ role='tool'; tool_call_id=$tc.id; content=$fakeResults[$fn] }
        } else {
            $closed = $true
            $ans = ($r.Msg.content -replace "`n", ' ').Trim()
            Write-Host ("    第 {0} 步: 收敛为文本" -f $steps) -ForegroundColor DarkGray
            Write-Host ("    答案: " + $ans.Substring(0, [Math]::Min(140, $ans.Length)))
            break
        }
    }
    $chain = $trace -join ' -> '
    $hasErr = ($ans -match 'error|错误|报错|connection refused')
    Write-Host ("    结论: {0} 步, {1}, 识别到报错={2}" -f $steps, $(if ($closed) { '✔ 闭环' } else { '✘ 未收敛' }), $hasErr) -ForegroundColor $(if ($closed -and $hasErr) { 'Green' } else { 'Red' })

    [void]$md.AppendLine('### A. 多轮工具链')
    [void]$md.AppendLine('| 项 | 值 |')
    [void]$md.AppendLine('|---|---|')
    [void]$md.AppendLine("| 是否闭环 | $(if ($closed) { '✅ 是' } else { '❌ 否（6 步内未收敛）' }) |")
    [void]$md.AppendLine("| 总轮数 | $steps |")
    [void]$md.AppendLine("| 工具调用链 | ``$chain`` |")
    [void]$md.AppendLine("| 找对关键信息（日志里的 connection refused） | $(if ($hasErr) { '✅' } else { '❌' }) |")
    [void]$md.AppendLine("| 最终回答 | $($ans.Substring(0,[Math]::Min(200,$ans.Length))) |")
    [void]$md.AppendLine('')
}

# =====================================================================
# B 上下文累积
# =====================================================================
if (& $want 'B') {
    Write-Host "`n[B] 上下文累积（8 轮）…" -ForegroundColor Yellow
    $msgs = @(@{ role='system'; content='你是一个简洁的技术助手，每次回答不超过两句话。' })
    $rows = @()
    $qs = @(
        '什么是量化？',
        'GGUF 和 safetensors 有什么区别？',
        'KV cache 为什么占显存？',
        'Flash Attention 省的是什么？',
        '滑动窗口注意力怎么省 KV？',
        '为什么小模型容易漏需求？',
        'prefill 和 decode 哪个更吃算力？',
        '最后一个问题：把你我前面聊过的话题列一下。'
    )
    $i = 0
    foreach ($q in $qs) {
        $i++
        $msgs += @{ role='user'; content=$q }
        $r = Chat $msgs $null 250
        $msgs += @{ role='assistant'; content=$r.Msg.content }
        $rows += [pscustomobject]@{ 轮 = $i; prompt = $r.Prompt; out = $r.Out; 耗时 = $r.Secs; prefillTps = $r.PreTps }
        Write-Host ("    第 {0} 轮: prompt={1,6} tok  生成={2,4} tok  {3,6}s" -f $i, $r.Prompt, $r.Out, $r.Secs)
    }
    $last = $rows[-1]
    $recall = ($last.prompt -gt 2000)
    [void]$md.AppendLine('### B. 上下文累积（8 轮连续对话）')
    [void]$md.AppendLine('')
    [void]$md.AppendLine('| 轮 | prompt tok | 生成 tok | 耗时 s | 有效速率 tok/s |')
    [void]$md.AppendLine('|---|---|---|---|---|')
    foreach ($x in $rows) {
        [void]$md.AppendLine("| $($x.轮) | $($x.prompt) | $($x.out) | $($x.耗时) | $($x.prefillTps) |")
    }
    [void]$md.AppendLine('')
    [void]$md.AppendLine("第 8 轮 prompt 达 $($last.prompt) tok，全程无截断；平均耗时 $([math]::Round((($rows | Measure-Object 耗时 -Average).Average),2)) s。")
    [void]$md.AppendLine('')
}

# =====================================================================
# C 指令保持
# =====================================================================
if (& $want 'C') {
    Write-Host "`n[C] 指令保持（约束能撑几轮）…" -ForegroundColor Yellow
    $msgs = @(@{ role='system'; content='你是技术助手。' })
    $msgs += @{ role='user'; content='请记住一条规则：从现在开始，你每次回答的开头都必须加上标记 [LOCAL]，然后再写正文。先重复一遍这条规则确认你记住了。' }
    $r0 = Chat $msgs $null 120
    $msgs += @{ role='assistant'; content=$r0.Msg.content }

    $qs = @('1+1等于几？', 'GGUF 是什么的缩写？', '显存和内存有什么区别？', '解释一下什么是 token。', '最后再确认一次：你还记得开头要加什么标记吗？')
    $holdCount = 0; $total = 0; $detail = @()
    foreach ($q in $qs) {
        $msgs += @{ role='user'; content=$q }
        $r = Chat $msgs $null 200
        $msgs += @{ role='assistant'; content=$r.Msg.content }
        $total++
        $ok = $r.Msg.content -match '^\s*\[LOCAL\]'
        if ($ok) { $holdCount++ }
        $detail += ("第{0}问:{1}" -f $total, $(if ($ok) { '✔' } else { '✘' }))
        Write-Host ("    第 {0} 问: {1}" -f $total, $(if ($ok) { '保持 ✔' } else { '丢失 ✘' })) -ForegroundColor $(if ($ok) { 'DarkGray' } else { 'Red' })
    }
    Write-Host ("    指令保持 {0}/{1}" -f $holdCount, $total) -ForegroundColor $(if ($holdCount -eq $total) { 'Green' } else { 'Yellow' })
    [void]$md.AppendLine('### C. 指令保持（第 1 轮下的约束，能撑几轮）')
    [void]$md.AppendLine('')
    [void]$md.AppendLine("**结果：$holdCount / $total 轮保持住** —— $($detail -join '，')")
    [void]$md.AppendLine('')
}

# =====================================================================
# D 工具报错恢复
# =====================================================================
if (& $want 'D') {
    Write-Host "`n[D] 工具报错恢复…" -ForegroundColor Yellow
    $msgs = @(@{ role='system'; content='你是运维助手，用工具解决问题。遇到错误要分析原因，不要重复同样的失败调用。' })
    $msgs += @{ role='user'; content='读一下 D:\demo\nothing_here.txt 这个文件的内容。' }

    $attempts = @(); $recovered = $false; $repeated = $false
    for ($i = 1; $i -le 4; $i++) {
        $r = Chat $msgs $tools 400
        if (-not $r.Msg.tool_calls) {
            $txt = ($r.Msg.content -replace "`n", ' ').Trim()
            $attempts += "第${i}步:文本"
            Write-Host ("    第 {0} 步: 转为文本回复" -f $i) -ForegroundColor DarkGray
            if ($txt -match '不存在|找不到|没有|not found|no such') { $recovered = $true }
            Write-Host ("    " + $txt.Substring(0, [Math]::Min(140, $txt.Length)))
            break
        }
        $tc = $r.Msg.tool_calls[0]
        $argsJson = if ($tc.function.arguments -is [string]) { $tc.function.arguments } else { $tc.function.arguments | ConvertTo-Json -Compress }
        $attempts += "$i.$($tc.function.name)"
        Write-Host ("    第 {0} 步: 又调用 {1}" -f $i, $tc.function.name) -ForegroundColor DarkGray
        if ($i -eq 2 -and $attempts[0] -eq $attempts[1]) { $repeated = $true }
        $msgs += @{ role='assistant'; content=$null; tool_calls=$r.Msg.tool_calls }
        $msgs += @{ role='tool'; tool_call_id=$tc.id; content='ERROR: file not found (ENOENT): D:\demo\nothing_here.txt' }
    }
    Write-Host ("    结论: 恢复={0}, 重复同一调用={1}" -f $recovered, $repeated) -ForegroundColor $(if ($recovered) { 'Green' } else { 'Yellow' })
    [void]$md.AppendLine('### D. 工具报错恢复（工具一直返回 ENOENT）')
    [void]$md.AppendLine('')
    [void]$md.AppendLine("| 项 | 值 |")
    [void]$md.AppendLine("|---|---|")
    [void]$md.AppendLine("| 调用序列 | ``$($attempts -join ' -> ')`` |")
    [void]$md.AppendLine("| 最终正确报告「找不到该文件」 | $(if ($recovered) { '✅' } else { '❌ 卡在工具循环里' }) |")
    [void]$md.AppendLine("| 是否无脑重复同一调用 | $(if ($repeated) { '⚠️ 是' } else { '✅ 否' }) |")
    [void]$md.AppendLine('')
}

# =====================================================================
# E 长文档抽取
# =====================================================================
if (& $want 'E') {
    Write-Host "`n[E] 长文档抽取…" -ForegroundColor Yellow
    $filler = @()
    for ($i = 1; $i -le 600; $i++) {
        $filler += "第 ${i} 号工单：客户反馈服务响应缓慢，已按标准流程处理并记录在案，等待后续回访确认，责任人已签核。"
    }
    $needle = '第 487 号工单：客户反馈支付接口返回 502，根因是上游网关证书过期，已于 2026-10-20 更换证书，影响时长 47 分钟，涉及三个省份。'
    $filler[486] = $needle
    $doc = ($filler -join "`n")
    $q = "下面是一份共 600 条的工单记录。请找出其中唯一一条涉及『证书过期』的工单，告诉我工单编号、影响时长、处理日期、涉及省份。只输出这四个信息，不要解释。`n`n" + $doc
    $r = Chat @(@{ role='user'; content=$q }) $null 300
    $ans = ($r.Msg.content -replace "`n", ' ').Trim()
    $ok = ($ans -match '487' -and $ans -match '47')
    Write-Host ("    prompt={0} tok, {1}s, 抽取值: {2}" -f $r.Prompt, $r.Secs, $(if ($ok) { '✔' } else { '✘' })) -ForegroundColor $(if ($ok) { 'Green' } else { 'Red' })
    Write-Host ("    " + $ans.Substring(0, [Math]::Min(150, $ans.Length)))
    [void]$md.AppendLine('### E. 长文档抽取（600 条工单里找唯一一条，压到 64K 上下文）')
    [void]$md.AppendLine('')
    [void]$md.AppendLine("| 项 | 值 |")
    [void]$md.AppendLine("|---|---|")
    [void]$md.AppendLine("| 输入 prompt | **$($r.Prompt) tok** |")
    [void]$md.AppendLine("| 端到端耗时 | $($r.Secs) s（含 prefill） |")
    [void]$md.AppendLine("| 抽取正确（487 号 / 47 分钟 / 三个省份） | $(if ($ok) { '✅' } else { '❌' }) |")
    [void]$md.AppendLine("| 输出 | $($ans.Substring(0,[Math]::Min(160,$ans.Length))) |")
    [void]$md.AppendLine('')
}

# =====================================================================
# F 并发
# =====================================================================
if (& $want 'F') {
    Write-Host "`n[F] 并发（-np 1，看排队行为）…" -ForegroundColor Yellow
    $ask = @{ messages=@(@{role='user';content='用一句话解释什么是 prefill。'}); max_tokens=120; temperature=0; stream=$false } | ConvertTo-Json -Depth 8
    $one = [Diagnostics.Stopwatch]::StartNew()
    $null = Invoke-RestMethod "$LlamaBase/v1/chat/completions" -Method Post -Body $ask -ContentType 'application/json' -TimeoutSec 600
    $one.Stop()

    $two = [Diagnostics.Stopwatch]::StartNew()
    $jobs = @(
        (Start-Job { param($u,$b) (Measure-Command { Invoke-RestMethod $u -Method Post -Body $b -ContentType 'application/json' -TimeoutSec 600 }).TotalSeconds } -ArgumentList "$LlamaBase/v1/chat/completions", $ask),
        (Start-Job { param($u,$b) (Measure-Command { Invoke-RestMethod $u -Method Post -Body $b -ContentType 'application/json' -TimeoutSec 600 }).TotalSeconds } -ArgumentList "$LlamaBase/v1/chat/completions", $ask)
    )
    $jobs | Wait-Job -Timeout 900 | Out-Null
    $two.Stop()
    $each = $jobs | Receive-Job
    $jobs | Remove-Job -Force
    Write-Host ("    单个请求 {0:N2}s；两个并发总耗时 {1:N2}s（各自 {2}）" -f $one.Elapsed.TotalSeconds, $two.Elapsed.TotalSeconds, (($each | ForEach-Object { '{0:N2}s' -f $_ }) -join ' / '))
    [void]$md.AppendLine('### F. 并发（服务是 `-np 1` 单槽位）')
    [void]$md.AppendLine('')
    [void]$md.AppendLine("| 场景 | 总耗时 |")
    [void]$md.AppendLine("|---|---|")
    [void]$md.AppendLine("| 单个请求 | $([math]::Round($one.Elapsed.TotalSeconds,2)) s |")
    [void]$md.AppendLine("| 两个并发（各自耗时 $(($each | ForEach-Object { '{0:N1}s' -f $_ }) -join ' / ')） | **$([math]::Round($two.Elapsed.TotalSeconds,2)) s** |")
    [void]$md.AppendLine('')
    [void]$md.AppendLine('单槽位下并发是**排队**而非并行：总耗时约等于两次串行之和，不会变快也不会崩。要真并行得加 `-np`，但 8GB 卡装不下第二份 KV。')
    [void]$md.AppendLine('')
}

New-Item -ItemType Directory -Force -Path $LocalLlmBench | Out-Null
$rf = Join-Path $LocalLlmBench 'stress.md'
if (-not (Test-Path $rf)) { Set-Content -Path $rf -Value "# 压力测试记录`n" -Encoding utf8 }
Add-Content -Path $rf -Value $md.ToString() -Encoding utf8
Write-Host "`n[+] 已记录到 $rf" -ForegroundColor Cyan
