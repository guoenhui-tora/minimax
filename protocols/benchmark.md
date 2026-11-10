# 压测协议

每个并发 C，先预热一轮，再正式测量三轮。

| 阶段 | 请求数 |
| --- | --- |
| 预热 | `max(16, 2 × min(C, 256))` |
| 正式每轮 | `max(32, 4 × min(C, 256))` |

C 超过 256 时，按 256 计算请求数；并发仍用实际 C。

统一使用 `/v1/chat/completions`，发送一条 user 消息，由服务端应用模型的 chat template。

默认 random 输入目标 8192、输出 1024 tokens，temperature=0，ignore EOS，thinking off。服务端加上 chat template 后，实际输入会更长。各轮 seed 依次递增。

每轮保存一个 JSON；`summary.csv` 只汇总三轮正式结果，每轮一行。
