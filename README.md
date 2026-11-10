# 推理实验模板

复制到新项目后使用。启动脚本按实验改，所有部署共用 `scripts/bench.sh`。

实验进度、关键结果和下一步保存在项目文件中，不依赖对话历史；新会话从索引和 run 记录接着做。

## 目录

```text
.
├── README.md              模板说明与使用方法
├── AGENTS.md              Codex 的阅读、修改和执行约定
├── docs/                  研究说明、文档索引与分析
├── protocols/benchmark.md 公共压测协议
├── scripts/
│   ├── serve.sh           服务启动模板
│   ├── docker.sh          容器与运行编排模板
│   ├── slurm.sh           资源申请模板
│   ├── bench.sh           公共压测入口
│   ├── summarize-bench.py 压测结果汇总
│   └── new-run.sh         创建 run，复制启动脚本和协议
└── home/
    ├── README.md          实验总索引
    ├── .cache/            跨 run 共享缓存，运行时创建
    ├── run-时间戳-baseline-后缀/
    └── run-时间戳-decode-only-后缀/
```

[压测协议](protocols/benchmark.md) · [研究文档](docs/README.md) · [实验索引](home/README.md)

## 脚本关系

```
宿主机
  sbatch -> slurm.sh -> srun --> +-----------+
                                 | docker.sh |
  bash ------------------------> +-----+-----+
                                       |
                     +-----------------+-----------------+
                     |                                   | 服务就绪后
                     v                                   v
               服务容器 (GPU)                       压测容器 (CPU)
                 serve.sh                            bench.sh
                     |                                   |
                vllm serve <------- HTTP ------- vllm bench serve
```

两种入口二选一，共用同一个 `docker.sh`：

- 使用 Slurm：`sbatch` 提交 `slurm.sh`，分配资源后在计算节点通过 `srun` 调用 `docker.sh`。
- 不使用 Slurm：在已有可用资源的宿主机直接执行 `bash docker.sh`。

`docker.sh` 负责启动容器、等待服务就绪、执行压测和清理。`serve.sh`、`bench.sh` 在各自容器中直接调用原生 vLLM 命令，只负责模型服务和 HTTP 压测。

## 运行实验

### 创建 run

在项目根目录执行：

```bash
exp_name=baseline  # 本次实验名
run_dir=$(bash scripts/new-run.sh "$exp_name")
```

每个 run 自带 README，保存当次实验记录。

### serve.sh

在此修改模型路径、TP、引擎参数和补丁，按模型关闭 thinking。

Decode-only 模拟（[vLLM 官方方法](https://docs.vllm.ai/en/latest/serving/expert_parallel_deployment/#benchmarking_1)）：

```bash
# serve.sh：追加到 vllm serve，用合成 KV 测量 decode
--kv-transfer-config '{"kv_connector":"DecodeBenchConnector","kv_role":"kv_both","kv_connector_extra_config":{"startup_fill":true}}'
```

### docker.sh

填写镜像、设备、挂载和 CPU/内存绑定。端口和服务名供 serve 与 bench 共用。

`home/.cache/` 通过 Docker 挂载到容器内的 `/workspace/cache/`，复用编译缓存，缩短 vLLM 启动时间。参考[缓存设计](https://docs.vllm.ai/en/latest/design/torch_compile/#compilation-cache)。

在 `bench_args` 中修改压测参数。对应的命令示例：

```bash
bash scripts/bench.sh --help   # 查看参数（项目根目录）

# 容器内调用示例；--describe 预览计划与命令
bash /workspace/scripts/bench.sh \
  --endpoint http://127.0.0.1:8000/v1/chat/completions \
  --model model-name \
  --tokenizer /models/model \
  --result-dir /workspace/run \
  --describe
```

Prefill-only 模拟：

```bash
# 使用常规服务；在 bench_args 定义后追加（仍含首 token 生成）
bench_args+=(--output-len 1)
```

PD 等部署在 run 内增加 P、D 和代理的启动脚本，由 `docker.sh` 按实际拓扑编排。

### slurm.sh

使用 Slurm 时填写节点、GPU、CPU/内存和时限。

### 执行

先查看配置，再选择一种方式运行：

```bash
bash "$run_dir/docker.sh" --describe

# 已有可用资源时直接执行。
bash "$run_dir/docker.sh"

# 或使用 Slurm 分配资源。
sbatch --chdir="$run_dir" --output="$run_dir/slurm.log" \
  "$run_dir/slurm.sh" "$run_dir"
```

结果保存在 run 内：`summary.csv` 为汇总，逐轮 JSON 为原始结果。日志分别为 `serve.log`、`bench.log` 和 `bench-container.log`。

