#!/usr/bin/env bash
# O3：写请求经 lbd，比较 2 台常驻、4 台常驻和 B2 式按 QPS 扩到 4 台。
# 使用独立端口：业务 8082，lbd 管理 8092，scaler 管理 8093，Prometheus 9091。
# 先在真实数据盘运行 -bench-fsync，并把输出保存为 runs/o3-fsync-bench.txt。
# 用法：sudo bash scripts/o3.sh <平时 rps> <峰值 rps>
# 复测可用 O3_PREFIX=o3-m512 O3_MEMORY=512M 指定新目录和内存上限。
set -euo pipefail
cd "$(dirname "$0")/.."

die() { echo "O3：$*" >&2; exit 1; }
[ "$#" -eq 2 ] || die '用法：sudo bash scripts/o3.sh <平时 rps> <峰值 rps>'
base=$1
peak=$2
prefix=${O3_PREFIX:-o3}
memory=${O3_MEMORY:-128M}
[[ $base =~ ^[1-9][0-9]*$ && $peak =~ ^[1-9][0-9]*$ ]] || die '到达率须为正整数'
[ "$peak" -gt "$base" ] || die '峰值须高于平时到达率'
[[ $prefix =~ ^[A-Za-z0-9._-]+$ ]] || die 'O3_PREFIX 只能包含字母、数字、点、下划线和连字符'
[ "$(id -u)" -eq 0 ] || die '请用 sudo 运行（scaler 需创建 systemd 服务）'
for c in curl findmnt lsblk iostat taskset; do command -v "$c" >/dev/null || die "缺少 $c"; done
for c in enrolld loadgen lab3sum promsteps scaler; do [ -x "bin/$c" ] || die "缺少 bin/$c；请先 make build"; done
[ -s runs/o3-fsync-bench.txt ] || die '先在真实数据盘做 fsync 校准并保存 runs/o3-fsync-bench.txt'
for name in "$prefix-fixed2" "$prefix-fixed4" "$prefix-reactive"; do
  [ ! -e "runs/$name" ] || die "runs/$name 已存在，不覆盖原始数据"
done
if pgrep -x scaler >/dev/null || pgrep -x loadgen >/dev/null; then
  die '已有 scaler 或 loadgen 在运行，请先确认实验机空闲'
fi
curl -fsS -m 3 http://127.0.0.1:8092/config >/dev/null || die 'O3 lbd（8092）未启动'
curl -fsS -m 3 http://127.0.0.1:9091/-/ready >/dev/null || die 'O3 Prometheus（9091）未就绪'
curl -fsS -m 3 http://127.0.0.1:9100/metrics >/dev/null || die 'node_exporter 未启动'
[ "$(curl -fsS -m 3 http://127.0.0.1:8092/backends)" = '[]' ] || die 'O3 lbd 仍登记着旧后端，请先清理或重启'

# 每个实例有自己的 enroll.log，但它们都位于 data 所在的同一块真实磁盘。
fstype=$(findmnt -no FSTYPE -T "$PWD/data")
source=$(findmnt -no SOURCE -T "$PWD/data")
[ "$fstype" != tmpfs ] || die 'data 位于 tmpfs，fsync 实验无效'
disk=${DISK:-}
if [ -z "$disk" ] && [ -b "$source" ]; then
  if [ "$(lsblk -no TYPE "$source" | head -n 1)" = part ]; then
    disk=$(lsblk -no PKNAME "$source" | head -n 1)
  else
    disk=$(lsblk -no KNAME "$source" | head -n 1)
  fi
fi
[ -n "$disk" ] || die "无法识别 data 的整块磁盘（$source）；可设置 DISK=设备名"

# 两轮固定副本是容量对照；第三轮沿用 B2 的每 15 秒 QPS 决策和启动延迟。
# 低负载 30 秒、爬升 20 秒、峰值 150 秒、回落 20 秒、低负载 30 秒。
plan="${base}@30s,${base}~${peak}@20s,${peak}@150s,${peak}~${base}@20s,${base}@30s"
target=$(( (peak + 3) / 4 ))
qps='sum(rate(lb_requests_total{backend!="none"}[15s])) / count(up{job="instances"} == 1)'
scaler_pid=
collector_pid=
cleanup() {
  if [ -n "$collector_pid" ]; then kill "$collector_pid" 2>/dev/null || true; wait "$collector_pid" 2>/dev/null || true; collector_pid=; fi
  if [ -n "$scaler_pid" ]; then kill -INT "$scaler_pid" 2>/dev/null || true; wait "$scaler_pid" 2>/dev/null || true; scaler_pid=; fi
}
trap cleanup EXIT

wait_ready() {
  local wanted=$1 count
  for _ in $(seq 1 70); do
    kill -0 "$scaler_pid" 2>/dev/null || die "scaler 已退出；查看 data/$name-scaler.log"
    count=$(curl -fsS -m 3 http://127.0.0.1:8093/instances 2>/dev/null | grep -c '"state": "ready"' || true)
    [ "$count" -ge "$wanted" ] && return 0
    sleep 2
  done
  die "等候 $wanted 个初始实例就绪超时；查看 data/$name-scaler.log"
}

run_case() {
  local name=$1 wanted=$2
  shift 2
  echo "== $name：启动 scaler，等 $wanted 个实例就绪"
  taskset -c 0 bin/scaler -cpus 1 -quota 25 -memory "$memory" -args '-warmup 60s -sync each' \
    -lb http://127.0.0.1:8092 -prom http://127.0.0.1:9091 -admin 127.0.0.1:8093 \
    "$@" >"data/$name-scaler.log" 2>&1 &
  scaler_pid=$!
  wait_ready "$wanted"
  echo "== $name：写请求压测 250 秒"
  LC_ALL=C S_TIME_FORMAT=ISO iostat -d -x -t "$disk" 1 >"data/$name-iostat.log" 2>&1 &
  collector_pid=$!
  LB=http://127.0.0.1:8092 SCALER=http://127.0.0.1:8093 scripts/run3.sh "$name" \
    -url http://127.0.0.1:8082/api/enroll \
    -body '{"student":"s{{seq}}","course":"c1"}' -plan "$plan"
  kill "$collector_pid" 2>/dev/null || true
  wait "$collector_pid" 2>/dev/null || true
  collector_pid=
  cp "data/$name-iostat.log" "runs/$name/iostat.log"
  cp "data/$name-scaler.log" "runs/$name/scaler.log"
  {
    echo "数据盘: $source ($fstype), 整块设备 $disk"
    echo "负载: $plan"
    echo "每实例: CPUQuota=25%, MemoryMax=$memory, AllowedCPUs=1, -warmup 60s -sync each"
    echo "QPS 目标: $target 请求/秒/实例（仅 reactive 轮）"
    echo '每个实例有独立 enroll.log，所有文件位于同一块盘；无跨实例互斥锁。'
  } >"runs/$name/o3-setup.txt"
  bash scripts/o2-summarize.sh "$name"
  bin/promsteps -steps "runs/$name/steps.csv" -prom http://127.0.0.1:9091 \
    -var "disk=$disk" -queries scripts/o3-queries.txt >"runs/$name/o3-metrics.csv"
  kill -INT "$scaler_pid"
  wait "$scaler_pid"
  scaler_pid=
}

run_case "$prefix-fixed2" 2 -mode fixed -replicas 2
run_case "$prefix-fixed4" 4 -mode fixed -replicas 4
run_case "$prefix-reactive" 2 -mode reactive -min 2 -max 4 -target "$target" -signal "$qps"
echo "O3 三轮完成：runs/$prefix-fixed2/、runs/$prefix-fixed4/、runs/$prefix-reactive/"
