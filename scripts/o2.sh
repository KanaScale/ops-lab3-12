#!/usr/bin/env bash
# 选做 O2：同一条开放日负载，比较即时空位与等待新节点两种扩容路径。
set -euo pipefail
cd "$(dirname "$0")/.."

cpu='avg(rate(cgroup_cpu_usage_seconds_total{job="instances"}[15s])) / ${quota}'
plan=$(scripts/plan.sh 33 330)
scaler_pid=

cleanup() {
  if [ -n "$scaler_pid" ] && kill -0 "$scaler_pid" 2>/dev/null; then
    kill -INT "$scaler_pid"
    wait "$scaler_pid" || true
  fi
}
trap cleanup EXIT

for name in o2-direct o2-nodewait; do
  if [ -e "runs/$name" ]; then
    echo "runs/$name 已存在，请检查后换名；不会覆盖旧数据" >&2
    exit 1
  fi
done

curl -fsS -m 3 http://127.0.0.1:8090/config >/dev/null
curl -fsS -m 3 http://127.0.0.1:9090/-/ready >/dev/null

wait_ready() {
  for _ in $(seq 1 120); do
    if ! kill -0 "$scaler_pid" 2>/dev/null; then
      echo "scaler 已退出；查看 data/$1-scaler.log" >&2
      return 1
    fi
    count=$(curl -fsS -m 3 http://127.0.0.1:8091/instances 2>/dev/null | grep -c '"state": "ready"' || true)
    if [ "$count" -ge 2 ]; then
      return 0
    fi
    sleep 2
  done
  echo "等候两台初始实例就绪超时；查看 data/$1-scaler.log" >&2
  return 1
}

run_case() {
  local name=$1
  shift
  echo "== $name：启动 scaler"
  taskset -c 0 bin/scaler -mode reactive -min 2 -max 4 -signal "$cpu" "$@" >"data/$name-scaler.log" 2>&1 &
  scaler_pid=$!
  wait_ready "$name"
  echo "== $name：两台初始实例已就绪，开始 630 秒负载"
  scripts/run3.sh "$name" -url http://127.0.0.1:8080/api/courses/1 -plan "$plan"
  bash scripts/o2-summarize.sh "$name"
  echo "== $name：停止 scaler"
  kill -INT "$scaler_pid"
  wait "$scaler_pid"
  scaler_pid=
}

run_case o2-direct
run_case o2-nodewait -node-slots 2 -node-wait 240s
echo 'O2 两轮完成：runs/o2-direct/、runs/o2-nodewait/'
