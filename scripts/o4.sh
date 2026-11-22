#!/usr/bin/env bash
# 单节点 K3s 上重做 B2。先运行 make build、o4-build-image.py、k3s ctr images import，
# 再 apply deploy/o4-k3s.yaml；本脚本只运行压测并保存原始证据。
set -euo pipefail

name=${1:-o4-hpa}
[[ $name =~ ^[A-Za-z0-9._-]+$ ]] || { echo "无效运行名" >&2; exit 2; }
dir="runs/$name"
[ ! -e "$dir" ] || { echo "$dir 已存在" >&2; exit 2; }
mkdir -p "$dir"
kubectl_cmd=(k3s kubectl)
"${kubectl_cmd[@]}" rollout status deploy/enrolld -n lab3-o4 --timeout=180s
curl -fsS --max-time 3 http://127.0.0.1:30080/readyz >"$dir/preflight-readyz.txt"
"${kubectl_cmd[@]}" get nodes,pods,hpa -A -o wide >"$dir/preflight-cluster.txt"
"${kubectl_cmd[@]}" describe hpa enrolld -n lab3-o4 >"$dir/hpa-before.txt"
"${kubectl_cmd[@]}" get deploy,svc,hpa,pods -n lab3-o4 -o yaml >"$dir/objects-before.yaml"

{
  echo "开始: $(date -Iseconds)"
  echo "commit: $(git rev-parse HEAD)"
  echo "plan: $(scripts/plan.sh 33 330)"
  echo "host: $(uname -srm)"
  echo "k3s: $(k3s --version | head -n 1)"
  echo "node: $("${kubectl_cmd[@]}" get node -o jsonpath='{.items[0].status.nodeInfo.kubeletVersion}')"
  echo "loadgen: taskset -c 0 bin/loadgen -url http://127.0.0.1:30080/api/courses/1 -plan '$(scripts/plan.sh 33 330)' -slo 0.2s -stop-below 0 -seed 1"
} >"$dir/meta.txt"

stopfile="$dir/watch-stop"
python3 scripts/o4-watch.py "$dir/samples.jsonl" "$stopfile" >"$dir/watch.log" 2>&1 &
watch_pid=$!
cleanup() {
  touch "$stopfile"
  wait "$watch_pid" || true
}
trap cleanup EXIT
sleep 3
date +%s.%N >"$dir/start-epoch.txt"
taskset -c 0 bin/loadgen \
  -url http://127.0.0.1:30080/api/courses/1 \
  -plan "$(scripts/plan.sh 33 330)" -seed 1 \
  -slo 0.2s -stop-below 0 \
  -out "$dir/steps.csv" -timeline "$dir/timeline.csv" \
  >"$dir/loadgen.log" 2>&1
date +%s.%N >"$dir/end-epoch.txt"
cleanup
trap - EXIT
"${kubectl_cmd[@]}" get events -n lab3-o4 --sort-by=.lastTimestamp -o yaml >"$dir/events.yaml"
"${kubectl_cmd[@]}" get deploy,svc,hpa,pods -n lab3-o4 -o yaml >"$dir/objects-after.yaml"
"${kubectl_cmd[@]}" describe hpa enrolld -n lab3-o4 >"$dir/hpa-after.txt"
"${kubectl_cmd[@]}" top pods -n lab3-o4 >"$dir/pods-top.txt" 2>&1 || true
echo "结束: $(date -Iseconds)" >>"$dir/meta.txt"
echo "完成 $dir"
