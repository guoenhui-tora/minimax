#!/usr/bin/env bash
# 复制到 run 后修改这里的具体引擎命令；以下参数仅为 vLLM 示例。
set -euo pipefail
export TZ=Asia/Shanghai
run_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
export RUN_DIR="$run_dir"
cd -- "$run_dir"
# 由 Docker 启动时，端口和服务名取 docker.sh 传入的连接信息。
model_path=${MODEL_PATH:-/models/model}
model_name=${MODEL_NAME:-model-name}
port=${PORT:-8000}
describe=false
if [[ ${1:-} == --describe ]]; then describe=true; shift; fi

# 普通性能对照关闭 thinking；按模型在下方命令设置。支持 enable_thinking 的模板例如：
# --default-chat-template-kwargs '{"enable_thinking": false}'
command=(vllm serve "$model_path"
    --served-model-name "$model_name"
    --host 127.0.0.1 --port "$port"
    --tensor-parallel-size 4
    "$@")
printf 'Serve command: '; printf '%q ' "${command[@]}"; printf '\n'
if "$describe"; then exit 0; fi
exec "${command[@]}"
