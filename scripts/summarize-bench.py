#!/usr/bin/env python3
"""检查 vLLM 逐轮结果，汇总正式轮次，不修改原始 JSON。"""
import argparse
import csv
import json
from pathlib import Path
import sys


def load(path):
    data = json.loads(path.read_text())
    if not isinstance(data, dict):
        raise ValueError('结果 JSON 顶层必须是对象')
    return data


def validate(data, expected, output_len):
    completed = data.get('completed')
    if type(completed) is not int or completed != expected:
        raise ValueError(f'完成数 {completed!r}，预期 {expected}')
    for field in ('failed', 'failed_requests'):
        if data.get(field, 0) != 0:
            raise ValueError(f'{field}={data[field]!r}')
    if any(data.get('errors', [])):
        raise ValueError('存在失败请求：' + repr([e for e in data['errors'] if e])[:500])
    lengths = data.get('output_lens')
    if not isinstance(lengths, list) or len(lengths) != expected:
        raise ValueError(f'缺少 {expected} 条逐请求 output_lens')
    if any(type(n) is not int or n != output_len for n in lengths):
        raise ValueError(f'部分请求的输出长度与 {output_len} 不符')


def summary(root):
    config = load(root / 'protocol.json')
    fields = ['protocol', 'concurrency_index', 'max_concurrency', 'round', 'seed',
              'expected_requests', 'completed', 'failed_requests', 'input_len', 'output_len',
              'duration_s', 'request_throughput', 'output_throughput', 'total_token_throughput',
              'mean_ttft_ms', 'median_ttft_ms', 'p99_ttft_ms',
              'mean_tpot_ms', 'median_tpot_ms', 'p90_tpot_ms', 'p99_tpot_ms',
              'mean_e2el_ms', 'p99_e2el_ms', 'validation', 'error', 'json_file']
    rows = []
    # 按测量计划读取正式轮次；失败或中断时只汇总已有文件。
    for plan in config['plans']:
        concurrency = plan['concurrency']
        expected = plan['measured_requests_per_round']
        for round_number in range(1, 4):
            path = root / f'round-{round_number:02d}-c{concurrency}.json'
            if not path.exists():
                continue
            row = dict(protocol=config['protocol'], concurrency_index=plan['concurrency_index'],
                       max_concurrency=concurrency, round=round_number,
                       seed=plan['seed_start'] + round_number, expected_requests=expected,
                       input_len=config['input_len'], output_len=config['output_len'], json_file=path.name)
            try:
                data = load(path)
                metrics = fields[fields.index('completed'):fields.index('validation')]
                row.update({k: data[k] for k in metrics if k in data and k not in ('input_len', 'output_len')})
                row['duration_s'] = data.get('duration', '')
                row['failed_requests'] = data.get('failed_requests', data.get('failed',
                    expected - data['completed'] if type(data.get('completed')) is int else ''))
                validate(data, expected, config['output_len'])
                row['validation'] = 'passed'
            except (OSError, ValueError, TypeError, KeyError) as error:
                row.update(validation='failed', error=str(error))
            rows.append(row)
    writer = csv.DictWriter(sys.stdout, fieldnames=fields)
    writer.writeheader()
    writer.writerows(rows)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    check = commands.add_parser('check', help='检查单轮结果')
    check.add_argument('json_file', type=Path)
    check.add_argument('--expected-requests', type=int, required=True)
    check.add_argument('--output-len', type=int, required=True)
    collect = commands.add_parser('summary', help='输出正式轮次 CSV 到 stdout')
    collect.add_argument('--result-dir', type=Path, required=True)
    args = parser.parse_args()
    try:
        if args.command == 'check':
            validate(load(args.json_file), args.expected_requests, args.output_len)
            print(f'Validated: {args.json_file.name}')
        else:
            summary(args.result_dir)
    except (OSError, ValueError, TypeError, KeyError) as error:
        parser.exit(1, f'summarize-bench: {error}\n')


if __name__ == '__main__':
    main()
