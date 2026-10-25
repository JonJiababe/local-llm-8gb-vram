
## 2026-10-25 16:04 — qwen3.5-9b-q4_k_m

| 用例 | 结果 | 耗时 |
|---|---|---|
| 恰好20字摘要 | 失败（实际 21 字） | 2.12s |
| 工具选择 | 通过 | 1.3s |
| 写代码 | 通过 | 5.89s / 166 tok |

**得分：2 / 3**

<details><summary>原始输出</summary>

```
[1] 量化技术降低精度压缩权重，让小显存运行大模型。
[3] function Get-TopFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [int]$Count
    )

    try {
        $files = Get-ChildItem -Path $Path -File -ErrorAction Stop |
            Sort-Object Length -Descending |
            Select-Object -First $Count

        foreach ($file in $files) {
            [PSCustomObject]@{
                Name = $file.Name
                SizeMB = [math]::Round($file.Length / 1MB, 2)
            }
        }
    }
    catch {
        throw $_
    }
}
```
</details>


## 2026-10-25 16:05 — qwen3.5-4b-q4_k_m

| 用例 | 结果 | 耗时 |
|---|---|---|
| 恰好20字摘要 | 失败（实际 28 字） | 0.61s |
| 工具选择 | 通过 | 1s |
| 写代码 | 通过 | 2.47s / 108 tok |

**得分：2 / 3**

<details><summary>原始输出</summary>

```
[1] 本地大模型部署核心矛盾是显存容量与模型参数规模之间的取舍。
[3] function Get-TopFiles {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path,
        [Parameter(Mandatory=$true)]
        [int]$Count
    )

    $files = Get-ChildItem -Path $Path -File | Sort-Object Length -Descending | Select-Object -First $Count
    foreach ($file in $files) {
        [math]::Round($file.Length / 1MB, 2)
    }
}
```
</details>


## 2026-10-25 16:05 — qwen3.5-4b-q4_k_m

| 用例 | 结果 | 耗时 |
|---|---|---|
| 恰好20字摘要 | 失败（实际 28 字） | 0.98s |
| 工具选择 | 通过 | 0.8s |
| 写代码 | 失败 | 2.45s / 108 tok |

**得分：1 / 3**

<details><summary>原始输出</summary>

```
[1] 本地大模型部署核心矛盾是显存容量与模型参数规模之间的取舍。
[3] function Get-TopFiles {
    param(
        [Parameter(Mandatory=$true)]
        [string]$Path,
        [Parameter(Mandatory=$true)]
        [int]$Count
    )

    $files = Get-ChildItem -Path $Path -File | Sort-Object Length -Descending | Select-Object -First $Count
    foreach ($file in $files) {
        [math]::Round($file.Length / 1MB, 2)
    }
}
```
</details>


## 2026-10-25 16:06 — qwen3.5-9b-q4_k_m

| 用例 | 结果 | 耗时 |
|---|---|---|
| 恰好20字摘要 | 失败（实际 21 字） | 1.34s |
| 工具选择 | 通过 | 1.6s |
| 写代码 | 通过 | 5.84s / 166 tok |

**得分：2 / 3**

<details><summary>原始输出</summary>

```
[1] 量化技术降低精度压缩权重，让小显存运行大模型。
[3] function Get-TopFiles {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [int]$Count
    )

    try {
        $files = Get-ChildItem -Path $Path -File -ErrorAction Stop |
            Sort-Object Length -Descending |
            Select-Object -First $Count

        foreach ($file in $files) {
            [PSCustomObject]@{
                Name = $file.Name
                SizeMB = [math]::Round($file.Length / 1MB, 2)
            }
        }
    }
    catch {
        throw $_
    }
}
```
</details>

