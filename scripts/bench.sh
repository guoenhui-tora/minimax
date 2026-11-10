#!/usr/bin/env bash
# 只连接已有服务；部署方式由 serve 脚本决定。
set -euo pipefail

usage() {
    cat <<'HELP'
用法：bench.sh --endpoint URL --model ALIAS --tokenizer PATH_OR_ID --result-dir DIR [选项]

必需参数：
  --endpoint URL          完整 HTTP(S) chat 地址，例如 http://127.0.0.1:8000/v1/chat/completions
  --model ALIAS           请求中的服务模型别名
  --tokenizer PATH_OR_ID  客户端实际 tokenizer 路径或标识
  --result-dir DIR        本次运行目录；已有压测结果拒绝覆盖
选项：
  --concurrencies C ...   正整数并发列表，默认 16 32 64，不允许重复
  --input-len N          random 输入目标长度，默认 8192；服务端另加 chat template
  --output-len N         输出长度，默认 1024
  --seed N               起始 seed，默认 0，按并发顺序每轮加 1
  --temperature X        默认 0
  --tokenizer-mode MODE  原样传给 vLLM，可省略
  --describe             预览计划与命令
  --help                 显示帮助
HELP
}

die() { printf 'bench: %s\n' "$*" >&2; exit 2; }
need_value() { (( $# >= 2 )) && [[ $2 != --* ]] || die "$1 缺少参数"; }

original_args=("$@")
endpoint= model= tokenizer= result_dir= tokenizer_mode=
input_len=8192 output_len=1024 seed=0 temperature=0 describe=0
concurrencies=(16 32 64)
while (( $# )); do
    case $1 in
        --endpoint) need_value "$@"; endpoint=$2; shift 2 ;;
        --model) need_value "$@"; model=$2; shift 2 ;;
        --tokenizer) need_value "$@"; tokenizer=$2; shift 2 ;;
        --result-dir) need_value "$@"; result_dir=$2; shift 2 ;;
        --input-len) need_value "$@"; input_len=$2; shift 2 ;;
        --output-len) need_value "$@"; output_len=$2; shift 2 ;;
        --seed) need_value "$@"; seed=$2; shift 2 ;;
        --temperature) need_value "$@"; temperature=$2; shift 2 ;;
        --tokenizer-mode) need_value "$@"; tokenizer_mode=$2; shift 2 ;;
        --concurrencies)
            shift; concurrencies=()
            while (( $# )) && [[ $1 != --* ]]; do concurrencies+=("$1"); shift; done
            (( ${#concurrencies[@]} )) || die '--concurrencies 至少需要一个整数'
            ;;
        --describe) describe=1; shift ;;
        --help|-h) usage; exit 0 ;;
        *) die "未知参数：$1" ;;
    esac
done
[[ -n $endpoint && -n $model && -n $tokenizer && -n $result_dir ]] || die '必须提供 --endpoint、--model、--tokenizer 和 --result-dir'

# Python 仅校验参数和计算计划，避免 shell 整数溢出或含糊的 URL 拆分。
protocol_json=$(python3 - "$endpoint" "$model" "$tokenizer" "$result_dir" \
    "$input_len" "$output_len" "$seed" "$temperature" "$tokenizer_mode" "${concurrencies[@]}" <<'PY'
import json
import math
from pathlib import Path
import re
import sys
from urllib.parse import urlsplit

endpoint, model, tokenizer, result_dir, ilen, olen, seed, temperature, mode, *cs = sys.argv[1:]
def integer(value, name, minimum):
    if not re.fullmatch(r'[0-9]+', value) or int(value) < minimum:
        raise SystemExit(f'{name} 必须是 >= {minimum} 的整数：{value}')
    return int(value)
ilen, olen = integer(ilen, 'input-len', 1), integer(olen, 'output-len', 1)
seed = integer(seed, 'seed', 0)
cs = [integer(c, 'concurrency', 1) for c in cs]
if len(set(cs)) != len(cs):
    raise SystemExit('并发列表不允许重复')
try:
    temperature = float(temperature)
except ValueError:
    raise SystemExit('temperature 必须是非负有限数')
if not math.isfinite(temperature) or temperature < 0:
    raise SystemExit('temperature 必须是非负有限数')
try:
    url = urlsplit(endpoint)
    url.port
except ValueError as error:
    raise SystemExit(f'endpoint 无效：{error}')
if url.scheme not in ('http', 'https') or not url.hostname or url.fragment:
    raise SystemExit('endpoint 必须是完整 HTTP(S) URL，且不能含 fragment')
if not url.path.endswith('/chat/completions'):
    raise SystemExit('本模板使用 chat 接口；endpoint 路径须以 /chat/completions 结尾')
if url.query:
    raise SystemExit('endpoint 请使用不带 query 的 chat URL')
plans = []
for i, c in enumerate(cs):
    warmup = max(16, 2 * min(c, 256))
    measured = max(32, 4 * min(c, 256))
    plans.append(dict(concurrency=c, concurrency_index=i+1,
        warmup_requests=warmup, measured_requests_per_round=measured,
        seed_start=seed+4*i, total_requests=warmup+3*measured))
print(json.dumps(dict(protocol='native-random-2c-4c-v2', endpoint=endpoint,
    base_url=f'{url.scheme}://{url.netloc}', endpoint_path=url.path,
    model=model, tokenizer=tokenizer, tokenizer_mode=mode or None,
    result_dir=str(Path(result_dir).resolve()), concurrencies=cs,
    input_len=ilen, output_len=olen, seed=seed, temperature=temperature,
    backend='openai-chat', dataset='random', random_range_ratio=0.0, random_prefix_len=0,
    request_rate='inf', ignore_eos=True, num_warmups=0, ready_check_timeout_sec=0,
    request_count_concurrency_cap=256, warmup_min_requests=16, measured_min_requests=32,
    warmup_rounds=1, measured_rounds=3, plans=plans,
    total_requests=sum(p['total_requests'] for p in plans)), indent=2, ensure_ascii=False))
PY
) || exit 2
mapfile -t http_parts < <(python3 -c 'import json,sys; p=json.load(sys.stdin); print(p["base_url"]); print(p["endpoint_path"]); print(p["result_dir"])' <<< "$protocol_json")
base_url=${http_parts[0]} endpoint_path=${http_parts[1]} result_dir=${http_parts[2]}
phase_plan=$(python3 -c '
import json,sys
p=json.load(sys.stdin)
for plan in p["plans"]:
    c=plan["concurrency"]
    for r in range(4):
        phase="warmup" if r == 0 else "measured"
        n=plan["warmup_requests"] if r == 0 else plan["measured_requests_per_round"]
        filename=f"warmup-c{c}.json" if r == 0 else f"round-{r:02d}-c{c}.json"
        print(c,plan["concurrency_index"],phase,r,n,plan["seed_start"]+r,filename,sep="\t")
' <<< "$protocol_json")

make_command() {
    command=(vllm bench serve
        --backend openai-chat --base-url "$base_url" --endpoint "$endpoint_path"
        --model "$model" --tokenizer "$tokenizer"
        --dataset-name random --random-input-len "$input_len" --random-output-len "$output_len"
        --random-range-ratio 0.0 --random-prefix-len 0
        --request-rate inf --ignore-eos --temperature "$temperature"
        --num-warmups 0 --ready-check-timeout-sec 0
        --percentile-metrics ttft,tpot,itl,e2el --metric-percentiles 50,90,99
        --save-result --save-detailed
        --num-prompts "$num_requests" --max-concurrency "$concurrency"
        --seed "$round_seed" --result-dir "$result_dir" --result-filename "$filename"
        --metadata 'protocol=native-random-2c-4c-v2' "concurrency_index=$concurrency_index"
        "phase=$phase" "round=$round" "seed=$round_seed"
        "input_len=$input_len" "output_len=$output_len" "num_requests=$num_requests")
    if [[ -n $tokenizer_mode ]]; then command+=(--tokenizer-mode "$tokenizer_mode"); fi
}
print_command() { printf 'Command: '; printf '%q ' "${command[@]}"; printf '\n'; }

if (( describe )); then
    printf '%s\n' "$protocol_json"
    while IFS=$'\t' read -r concurrency concurrency_index phase round num_requests round_seed filename; do
        make_command; print_command
    done <<< "$phase_plan"
    exit 0
fi

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
helper=$script_dir/summarize-bench.py
[[ -f $helper ]] || die "缺少同目录 helper：$helper"
command -v vllm >/dev/null || die '当前环境找不到 vllm'
mkdir -p -- "$result_dir"
shopt -s nullglob
existing=("$result_dir"/warmup-c*.json "$result_dir"/round-*-c*.json)
(( ${#existing[@]} == 0 )) || die "目录已有压测 JSON，拒绝覆盖：$result_dir"
for file in bench.log protocol.json summary.csv; do
    [[ ! -e $result_dir/$file ]] || die "目录已有 $file，拒绝覆盖：$result_dir"
done
# 目录标记防止两个客户端同时写同一个 run；失败后也保留它。
mkdir -- "$result_dir/.bench-started" || die "本目录已尝试压测，请新建 run：$result_dir"
finish() {
    local status=$?
    trap - EXIT
    if python3 "$helper" summary --result-dir "$result_dir" > "$result_dir/.summary.csv.tmp"; then
        mv -- "$result_dir/.summary.csv.tmp" "$result_dir/summary.csv"
    else
        printf 'bench: 无法生成 summary.csv\n' >&2
        if (( status == 0 )); then status=1; fi
    fi
    printf 'Benchmark exit status: %s\n' "$status"
    exit "$status"
}
trap finish EXIT
exec > >(tee "$result_dir/bench.log") 2>&1
printf 'Invocation: '; printf '%q ' "$0" "${original_args[@]}"; printf '\n'
printf '%s\n' "$protocol_json" | tee "$result_dir/protocol.json"
while IFS=$'\t' read -r concurrency concurrency_index phase round num_requests round_seed filename; do
    make_command
    printf 'Phase: C=%s %s round=%s requests=%s seed=%s\n' "$concurrency" "$phase" "$round" "$num_requests" "$round_seed"
    print_command
    "${command[@]}"
    python3 "$helper" check "$result_dir/$filename" --expected-requests "$num_requests" --output-len "$output_len"
done <<< "$phase_plan"
