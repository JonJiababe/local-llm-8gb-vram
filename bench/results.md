# 本地模型实测记录


## 2026-10-25 15:57:48 — qwen3.5-4b
| 指标 | 值 |
|---|---|
| 上下文 | 16384 |
| 思考模式 | on |
| 生成速度 | **49.8 tok/s** |
| 短提示 prefill | 18.6 tok/s |
| 长提示 prefill | 2791.4 tok/s |
| GPU 显存 | 3189 MiB |
| 工具调用 | 通过 — read_file({"path":"D:\\dsh_workplace\\README.md","limit":50}) |
| 多轮工具 | 收敛正常 |


## 2026-10-25 16:00:23 — qwen3.5-4b
| 指标 | 值 |
|---|---|
| 上下文 | 16384 |
| 思考模式 | off |
| 生成速度 | **47.9 tok/s** |
| 短提示 prefill | 32.4 tok/s |
| 长提示 prefill | 2707.8 tok/s |
| GPU 显存 | 3189 MiB |
| 工具调用 | 通过 — read_file({"path":"D:\\dsh_workplace\\README.md","limit":50}) |
| 多轮工具 | 收敛正常 |


## 2026-10-25 16:04:11 — qwen3.5-4b
| 指标 | 值 |
|---|---|
| 上下文 | 16384 |
| 思考模式 | off |
| 生成速度 | **31.4 tok/s** |
| 短提示 prefill | 13.5 tok/s |
| 长提示 prefill | 1679.3 tok/s |
| GPU 显存 | 5453 MiB |
| 工具调用 | 通过 — read_file({"path":"D:\\dsh_workplace\\README.md","limit":50}) |
| 多轮工具 | 收敛正常 |


## 2026-10-25 16:21:29 — qwen3.5-9b
| 指标 | 值 |
|---|---|
| 模型 | qwen3.5-9b |
| 上下文 | 65536 |
| 思考模式 | off |
| 生成速度 | **40.2 tok/s** |
| 短提示 prefill | 30.3 tok/s |
| 长提示 prefill | 未测 |
| GPU 显存 | 6511 MiB |
| 工具调用 | 通过 — read_file({"path":"D:\\dsh_workplace\\README.md","limit":50}) |
| 多轮工具 | 收敛正常 |

