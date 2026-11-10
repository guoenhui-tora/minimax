#!/usr/bin/env bash
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --gres=gpu:4
#SBATCH --time=02:00:00
#SBATCH --signal=B:TERM@60

# GPU 数和时限为示例；分区、CPU、内存及设备分组按当前站点显式申请。
set -euo pipefail
export TZ=Asia/Shanghai
usage() {
    printf '用法：sbatch --chdir="$run_dir" --output="$run_dir/slurm.log" "$run_dir/slurm.sh" "$run_dir"\n'
    printf '作业内：srun --ntasks=1 --kill-on-bad-exit=1 bash "$run_dir/docker.sh"\n'
}
if [[ ${1:-} == --describe ]]; then usage; exit 0; fi
[[ $# -le 1 ]] || { usage >&2; exit 2; }
[[ -n ${SLURM_JOB_ID:-} ]] || { usage >&2; exit 2; }
# sbatch 会 spool 本脚本，不能从 BASH_SOURCE 推导原始 run 路径。
run_dir=$(realpath -e -- "${1:-$PWD}")
[[ -f $run_dir/docker.sh ]] || { printf '缺少 %s/docker.sh\n' "$run_dir" >&2; exit 2; }
exec srun --ntasks=1 --kill-on-bad-exit=1 bash "$run_dir/docker.sh"
