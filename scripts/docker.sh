#!/usr/bin/env bash
# 复制到 run 后填写本次镜像、模型路径和设备；不自动探测或猜测 GPU 分组。
set -euo pipefail
export TZ=Asia/Shanghai
image=${IMAGE:-}
bench_image=${BENCH_IMAGE:-$image}
model_host=${MODEL_HOST:-}
device_args=()
# NVIDIA 示例：device_args=(--gpus '"device=0,1,2,3"')
# ROCm 示例：device_args=(--device=/dev/kfd --device=/dev/dri/renderD128)；逐卡填写。
# 设备必须在本次 allocation/获准使用范围内，不覆盖 Slurm 的可见设备变量。
cpuset_cpus=${CPUSET_CPUS:-}  # --cpuset-cpus：CPU 逻辑编号
cpuset_mems=${CPUSET_MEMS:-}  # --cpuset-mems：宿主机内存 NUMA 节点，不限制容量
# 端口和服务名供 serve 与 bench 共用；本次额外压测参数在 bench_args 中填写。
port=${PORT:-8000}
model_name=${MODEL_NAME:-model-name}
ready_timeout=${READY_TIMEOUT_S:-2400}
run_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
run_id=$(basename -- "$run_dir")
home_dir=$(dirname -- "$run_dir")
scripts_dir=$(dirname -- "$home_dir")/scripts
cache_dir=$(realpath -m -- "${CACHE_DIR:-$home_dir/.cache}")
bench_args=(
    --endpoint "${ENDPOINT:-http://127.0.0.1:$port/v1/chat/completions}"
    --model "$model_name" --tokenizer "${TOKENIZER_PATH:-/models/model}"
    --result-dir /workspace/run)

print_command() { printf '%q ' "$@"; printf '\n'; }
if [[ $# == 1 && $1 == --describe ]]; then
    printf 'IMAGE=%s\nBENCH_IMAGE=%s\nMODEL_HOST=%s\n' "${image:-<待填>}" "${bench_image:-<待填>}" "${model_host:-<待填>}"
    printf 'RUN_DIR=%s\nPORT=%s\nMODEL_NAME=%s\nREADY_TIMEOUT_S=%s\n' "$run_dir" "$port" "$model_name" "$ready_timeout"
    printf 'DEVICE_ARGS='; print_command "${device_args[@]}"
    printf 'CPUSET_CPUS=%s\nCPUSET_MEMS=%s\n' "${cpuset_cpus:-<未设置>}" "${cpuset_mems:-<未设置>}"
    printf '服务：%s/serve.sh；公共 bench：%s/bench.sh（不传 GPU）\n' "$run_dir" "$scripts_dir"
    printf '容器内 bench：'; print_command bash /workspace/scripts/bench.sh "${bench_args[@]}"
    printf '共享缓存：%s\n' "$cache_dir"
    printf '流程：服务后台启动 → /health → bench 前台执行 → 清理本次容器\n'
    exit 0
fi
[[ $# == 0 ]] || { printf '用法：bash %s [--describe]\n' "$0" >&2; exit 2; }
[[ -n $image ]] || { printf '请在本次 docker.sh 顶部或 IMAGE 中填写服务镜像。\n' >&2; exit 2; }
[[ -n $model_host && -d $model_host ]] || { printf '请填写存在的模型目录 MODEL_HOST。\n' >&2; exit 2; }
(( ${#device_args[@]} > 0 )) || { printf '请在本次 docker.sh 中填写 allocation 内的 device_args。\n' >&2; exit 2; }
[[ -n $cpuset_cpus && -n $cpuset_mems || -z $cpuset_cpus && -z $cpuset_mems ]] || {
    printf 'CPUSET_CPUS 与 CPUSET_MEMS 必须一起填写。\n' >&2; exit 2;
}
[[ $ready_timeout =~ ^[1-9][0-9]*$ ]] || { printf 'READY_TIMEOUT_S 必须为正整数。\n' >&2; exit 2; }
[[ -f $run_dir/serve.sh ]] || { printf '缺少 %s/serve.sh\n' "$run_dir" >&2; exit 2; }
for entry in bench.sh summarize-bench.py; do
    [[ -f $scripts_dir/$entry ]] || { printf '缺少公共脚本 %s/%s\n' "$scripts_dir" "$entry" >&2; exit 2; }
done
bash -n "$run_dir/serve.sh"
bash -n "$scripts_dir/bench.sh"
command -v docker >/dev/null
command -v curl >/dev/null
command -v python3 >/dev/null
model_host=$(realpath -e -- "$model_host")
if ! (set -o noclobber; printf 'run_id=%s\nstarted_at=%s\nstatus=starting\n' "$run_id" "$(date --iso-8601=seconds)" > "$run_dir/run-info.txt"); then
    printf '此 run 已有尝试记录，请新建 run：%s\n' "$run_dir" >&2; exit 2
fi

container_prefix="infer-${run_id}-${SLURM_JOB_ID:-local}-$$"
server_name="$container_prefix-server"
bench_name="$container_prefix-bench"
server_pid=''
containers_started=0
cleanup() {
    local code=$?
    trap - EXIT INT TERM
    set +e
    if [[ -n $server_pid ]]; then kill "$server_pid" 2>/dev/null; fi
    if (( containers_started )); then docker rm -f "$bench_name" "$server_name" >> "$run_dir/cleanup.log" 2>&1; fi
    if [[ -n $server_pid ]]; then wait "$server_pid" 2>/dev/null; fi
    local status=completed
    (( code == 0 )) || status=failed
    printf 'finished_at=%s\nstatus=%s\nexit_code=%s\n' "$(date --iso-8601=seconds)" "$status" "$code" >> "$run_dir/run-info.txt"
    exit "$code"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# 防止旧服务的 /health 被误认为本次服务已就绪。
python3 - "$port" <<'PY'
import socket
import sys

try:
    port = int(sys.argv[1])
    if not 1 <= port <= 65535:
        raise ValueError('端口必须在 1..65535')
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
        probe.bind(('127.0.0.1', port))
except (ValueError, OSError) as error:
    raise SystemExit(f'PORT 无效或已占用，请为本次 run 选择独立端口：{error}')
PY

# 启动时解析 ID，随后两个容器使用固定 ID；要固定排队前版本请填写 digest/ID。
image_id=$(docker image inspect "$image" --format '{{.Id}}')
bench_image_id=$(docker image inspect "$bench_image" --format '{{.Id}}')
[[ $image_id =~ ^sha256:[0-9a-f]{64}$ && $bench_image_id =~ ^sha256:[0-9a-f]{64}$ ]]
mkdir -p "$cache_dir"
# AITER 的 JIT 扩展按模块名保存；需要复用时，在本次 run 中设置兼容环境的 AITER_JIT_DIR。
common_args=(--rm --pull=never --network=host --ipc=host --workdir=/workspace/run
    -v "$run_dir:/workspace/run" -v "$model_host:/models/model:ro" -v "$cache_dir:/workspace/cache"
    -e RUN_DIR=/workspace/run -e TZ=Asia/Shanghai
    -e XDG_CACHE_HOME=/workspace/cache
    -e HF_HOME=/workspace/cache/huggingface -e TORCH_HOME=/workspace/cache/torch
    -e TRITON_CACHE_DIR=/workspace/cache/triton -e VLLM_CACHE_ROOT=/workspace/cache/vllm
    -e TORCHINDUCTOR_CACHE_DIR=/workspace/cache/torchinductor
    -e FLASHINFER_WORKSPACE_BASE=/workspace/cache -e CUDA_CACHE_PATH=/workspace/cache/cuda)
if [[ -n $cpuset_cpus ]]; then common_args+=(--cpuset-cpus "$cpuset_cpus" --cpuset-mems "$cpuset_mems"); fi
server_command=(docker run --name "$server_name" "${common_args[@]}" "${device_args[@]}"
    -e "PORT=$port" -e "MODEL_NAME=$model_name"
    --entrypoint=/bin/bash "$image_id" /workspace/run/serve.sh)
bench_command=(docker run --name "$bench_name" "${common_args[@]}"
    -v "$scripts_dir:/workspace/scripts:ro" --entrypoint=/bin/bash "$bench_image_id"
    /workspace/scripts/bench.sh "${bench_args[@]}")
{
    printf 'image_requested=%s\nimage_id=%s\nbench_image_requested=%s\nbench_image_id=%s\n' "$image" "$image_id" "$bench_image" "$bench_image_id"
    printf 'model_host=%s\nport=%s\nmodel_name=%s\n' "$model_host" "$port" "$model_name"
    printf 'scripts_dir=%s\ncache_dir=%s\n' "$scripts_dir" "$cache_dir"
    printf 'slurm_job_id=%s\nslurm_job_gpus=%s\n' "${SLURM_JOB_ID:-none}" "${SLURM_JOB_GPUS:-unset}"
    printf 'cpuset_cpus=%s\ncpuset_mems=%s\n' "$cpuset_cpus" "$cpuset_mems"
    printf 'device_args='; print_command "${device_args[@]}"
} >> "$run_dir/run-info.txt"
{ print_command "${server_command[@]}"; print_command "${bench_command[@]}"; } | tee "$run_dir/commands.log"

containers_started=1
"${server_command[@]}" > "$run_dir/serve.log" 2>&1 &
server_pid=$!
started=$SECONDS
while ! curl --fail --silent --show-error --max-time 2 "http://127.0.0.1:$port/health" >/dev/null 2>&1; do
    if ! kill -0 "$server_pid" 2>/dev/null; then
        printf '服务在健康检查前退出，见 serve.log。\n' >&2
        exit 1
    fi
    if (( SECONDS - started >= ready_timeout )); then
        printf '服务健康检查超时，见 serve.log。\n' >&2
        exit 124
    fi
    sleep 2
done
kill -0 "$server_pid" 2>/dev/null || { printf '服务已经退出，见 serve.log。\n' >&2; exit 1; }
printf 'status=benchmarking\n' >> "$run_dir/run-info.txt"
# bench 工具自行创建 bench.log，外层日志另存，避免其覆盖保护被提前触发。
"${bench_command[@]}" > "$run_dir/bench-container.log" 2>&1 &
bench_pid=$!
wait "$bench_pid"
kill -0 "$server_pid" 2>/dev/null || { printf '压测期间服务退出，见 serve.log。\n' >&2; exit 1; }
