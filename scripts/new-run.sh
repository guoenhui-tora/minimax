#!/usr/bin/env bash
# 准备输入，不启动模型、不提交任务。
set -euo pipefail
if [[ ${1:-} == --help ]]; then
    printf '用法：bash scripts/new-run.sh [label]\n'
    exit 0
fi
[[ $# -le 1 ]] || { printf '用法：bash scripts/new-run.sh [label]\n' >&2; exit 2; }
label=${1:-experiment}
[[ $label =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,47}$ ]] || {
    printf '名称使用 1–48 个英文字母、数字、点、下划线或连字符。\n' >&2
    exit 2
}
scripts_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
project_dir=$(dirname -- "$scripts_dir")
for file in serve.sh docker.sh slurm.sh bench.sh summarize-bench.py; do
    [[ -f $scripts_dir/$file ]] || { printf '缺少模板：%s/%s\n' "$scripts_dir" "$file" >&2; exit 1; }
done
[[ -f $project_dir/protocols/benchmark.md ]] || { printf '缺少压测协议。\n' >&2; exit 1; }
stamp=$(TZ=Asia/Shanghai date +%Y%m%d-%H%M%S)
mkdir -p "$project_dir/home"
run_dir=$(mktemp -d "$project_dir/home/run-$stamp-$label-XXXXXX")
cp "$scripts_dir/serve.sh" "$scripts_dir/docker.sh" "$scripts_dir/slurm.sh" "$run_dir/"
cp "$project_dir/protocols/benchmark.md" "$run_dir/protocol.md"
cat > "$run_dir/README.md" <<'README'
# 本次实验

- 状态：准备中，未运行。
- 目的：待填写。
- 对照或父 run：待填写。
- 本次改动：待填写。
- 下一步：待填写。

## 结果

- 结论：待填写。
- 结果文件：待填写。
- 异常或限制：待填写。
README
printf '%s\n' "$run_dir"
