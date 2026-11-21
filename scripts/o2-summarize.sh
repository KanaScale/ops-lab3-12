#!/usr/bin/env bash
# run3.sh 会复制 data/instances.csv 的全部历史；按本轮 scaler 的启动时刻
# 裁掉以前实验的实例，避免实例表和实例·分钟混入旧数据。
set -euo pipefail
cd "$(dirname "$0")/.."

for name in "$@"; do
  dir="runs/$name"
  [ -f "$dir/meta.txt" ] && [ -f "$dir/instances.csv" ] || {
    echo "$dir 缺少 meta.txt 或 instances.csv" >&2
    exit 1
  }
  started=$(sed -n '/^scaler \/config:/,$s/.*"started": "\([^"]*\)".*/\1/p' "$dir/meta.txt" | head -n 1)
  [ -n "$started" ] || { echo "$dir 缺少 scaler 启动时间" >&2; exit 1; }
  cutoff=$(date -d "$started" +%s%3N)
  tmp="$dir/instances.csv.tmp"
  awk -F, -v cutoff="$cutoff" 'NR == 1 || $1 >= cutoff' "$dir/instances.csv" > "$tmp"
  mv "$tmp" "$dir/instances.csv"
  bin/lab3sum -dir "$dir" > "$dir/summary.md"
  echo "已重算 $dir/summary.md（scaler 启动于 $started）"
done
