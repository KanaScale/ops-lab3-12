#!/usr/bin/env bash
# 实验 3 答辩复测命令清单：按小节、按终端复制命令，不要整体运行本文件。
# 参数采用第 12 组 LAB3.md 与 runs/ 中的实际配置；复测结果统一写入 runs/def-*，保留原始 runs/。
# 若某个 runs/def-* 已存在，run.sh/run3.sh 会拒绝覆盖；再次复测时只改结果目录名。
# 终端 A=Prometheus，B=lbd，C=scaler，D=压测和查看结果，E=定时注入或发布。
# 各终端先执行：ssh s1；cd /root/ops-lab3-12。
# 本文件是便于复制的文本。直接执行或 source 时，下面的实验命令均不会运行。
if [[ -n ${BASH_SOURCE[0]:-} ]]; then
  echo '请打开 RETEST.sh，按小节复制命令；不要整体运行。' >&2
  return 0 2>/dev/null || exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# 任务 0：环境（新会话先做；已经运行的服务不要重复启动）
# ─────────────────────────────────────────────────────────────────────────────
# 本地终端：
ssh s1
# 云服务器各终端：
cd /root/ops-lab3-12
export PATH=/usr/local/go/bin:$PATH
make build test
test -x tools/prometheus && test -x tools/node_exporter
stat -fc %T /sys/fs/cgroup
cat /sys/fs/cgroup/cgroup.controllers
systemctl --version | head -n 1
lscpu
free -m
swapon --show
uname -r
cat /etc/os-release
mkdir -p data
# 终端 A：先确认 9090、9100 未被旧进程占用；node_exporter 后台、Prometheus 前台。
ss -ltnp | grep -E ':9090|:9100' || true
taskset -c 0 tools/node_exporter --web.listen-address=127.0.0.1:9100 > data/node_exporter.log 2>&1 &
taskset -c 0 tools/prometheus --config.file=deploy/prometheus.yml --storage.tsdb.path=/dev/shm/lab3-prom --web.listen-address=127.0.0.1:9090
# 终端 D：确认 Prometheus 可用。
curl -fsS http://127.0.0.1:9090/-/ready
curl -s http://127.0.0.1:9090/api/v1/targets

# ─────────────────────────────────────────────────────────────────────────────
# 任务 A1：0.5 核配额算术（终端 D；两个 scope 各运行 10 秒）
# ─────────────────────────────────────────────────────────────────────────────
for n in 1 2; do sudo systemd-run --quiet --scope -p CPUQuota=50% bin/enrolld -burn "$n" -for 10s; done

# ─────────────────────────────────────────────────────────────────────────────
# 任务 A2：100%、50%、60% 配额和 GOMAXPROCS=1
# 实际到达率 R=90 请求/秒；每个阶段 20 秒；服务端口 8081。
# ─────────────────────────────────────────────────────────────────────────────
# 终端 D：先确认没有仍在运行的 lab3-a；不存在时 reset-failed 报错可忽略。
sudo systemctl stop lab3-a 2>/dev/null || true
sudo systemctl reset-failed lab3-a 2>/dev/null || true
sudo systemd-run --unit=lab3-a -p CPUQuota=100% -p MemoryMax=256M "$PWD/bin/enrolld" -addr 127.0.0.1:8081 -data "$PWD/data/a" -work 2000000
curl -s http://127.0.0.1:8081/config | grep -E 'gomaxprocs|cgroup'
# 基线及同为 90 请求/秒的 100% 对照。
scripts/run.sh def-a2-base -url http://127.0.0.1:8081/api/courses/1 -rates 30,60 -step 20s
scripts/run.sh def-a2-q100 -url http://127.0.0.1:8081/api/courses/1 -rates 90,90 -step 20s
# 50% 配额：不重启进程，直接改 cgroup 配额。
sudo systemctl set-property --runtime lab3-a CPUQuota=50%
scripts/run.sh def-a2-q50 -url http://127.0.0.1:8081/api/courses/1 -rates 90,90 -step 20s
# 改法一：本组按平均用核约 0.400/0.7 取 CPUQuota=60%。
sudo systemctl set-property --runtime lab3-a CPUQuota=60%
scripts/run.sh def-a2-q60 -url http://127.0.0.1:8081/api/courses/1 -rates 90,90 -step 20s
# 改法二：配额回到 50%，新进程的 GOMAXPROCS 固定为 1。
sudo systemctl stop lab3-a
sudo systemctl reset-failed lab3-a 2>/dev/null || true
sudo systemd-run --unit=lab3-a -p CPUQuota=50% -p MemoryMax=256M --setenv=GOMAXPROCS=1 "$PWD/bin/enrolld" -addr 127.0.0.1:8081 -data "$PWD/data/a" -work 2000000
scripts/run.sh def-a2-gmp1 -url http://127.0.0.1:8081/api/courses/1 -rates 90,90 -step 20s
# 对照 p99、配额、节流比例；四次各查一遍。
scripts/table.sh runs/def-a2-q100 ok_rps p50_ms p99_ms gomaxprocs cg_limit_cores throttle_ratio
scripts/table.sh runs/def-a2-q50 ok_rps p50_ms p99_ms gomaxprocs cg_limit_cores throttle_ratio
scripts/table.sh runs/def-a2-q60 ok_rps p50_ms p99_ms gomaxprocs cg_limit_cores throttle_ratio
scripts/table.sh runs/def-a2-gmp1 ok_rps p50_ms p99_ms gomaxprocs cg_limit_cores throttle_ratio

# ─────────────────────────────────────────────────────────────────────────────
# 任务 A3：内存上限、OOM、提高上限、限制并发
# 报表请求每个占 8 MiB、保持 500 ms；三档 10/20/30 请求/秒。
# ─────────────────────────────────────────────────────────────────────────────
# 终端 D：先停止 A2 服务，再复现 200M 内存上限下的 OOM。
sudo systemctl stop lab3-a
sudo systemctl reset-failed lab3-a 2>/dev/null || true
sudo systemd-run --unit=lab3-a -p MemoryMax=200M -p MemorySwapMax=0 "$PWD/bin/enrolld" -addr 127.0.0.1:8081 -data "$PWD/data/a"
scripts/run.sh def-a3-oom -url 'http://127.0.0.1:8081/api/report?mb=8&ms=500' -rates 10,20,30 -step 20s
systemctl show -p ActiveState,Result,ExecMainStatus lab3-a
journalctl -u lab3-a --no-pager | tail -n 8
sudo dmesg | grep -i oom-kill | tail -n 2
# 校准：先提高到 512M，只测 10、20 请求/秒，观察峰值并发与 RSS。
sudo systemctl stop lab3-a 2>/dev/null || true
sudo systemctl reset-failed lab3-a 2>/dev/null || true
sudo systemd-run --unit=lab3-a -p MemoryMax=512M -p MemorySwapMax=0 "$PWD/bin/enrolld" -addr 127.0.0.1:8081 -data "$PWD/data/a"
scripts/run.sh def-a3-calib20 -url 'http://127.0.0.1:8081/api/report?mb=8&ms=500' -rates 10,20 -step 20s
scripts/table.sh runs/def-a3-calib20 report_inflight_max rss_max_mb mem_current_max_mb
# 改法一：实测峰值并发 19，(13 + 19×8×2)×1.1≈348.7 MiB，取 360M。
sudo systemctl stop lab3-a
sudo systemctl reset-failed lab3-a 2>/dev/null || true
sudo systemd-run --unit=lab3-a -p MemoryMax=360M -p MemorySwapMax=0 "$PWD/bin/enrolld" -addr 127.0.0.1:8081 -data "$PWD/data/a"
scripts/run.sh def-a3-m360 -url 'http://127.0.0.1:8081/api/report?mb=8&ms=500' -rates 10,20,30 -step 20s
systemctl show -p ActiveState,Result,ExecMainStatus lab3-a
# 改法二：保留 200M，最多并行处理 10 个报表；其余立即返回 503。
sudo systemctl stop lab3-a 2>/dev/null || true
sudo systemctl reset-failed lab3-a 2>/dev/null || true
sudo systemd-run --unit=lab3-a -p MemoryMax=200M -p MemorySwapMax=0 "$PWD/bin/enrolld" -addr 127.0.0.1:8081 -data "$PWD/data/a" -report-max 10
scripts/run.sh def-a3-cap10 -url 'http://127.0.0.1:8081/api/report?mb=8&ms=500' -rates 10,20,30 -step 20s
systemctl show -p ActiveState,Result,ExecMainStatus lab3-a
scripts/table.sh runs/def-a3-oom ok_rps error_rate report_inflight_max rss_max_mb mem_current_max_mb
scripts/table.sh runs/def-a3-m360 ok_rps error_rate report_inflight_max rss_max_mb mem_current_max_mb
scripts/table.sh runs/def-a3-cap10 ok_rps error_rate report_inflight_max rss_max_mb mem_current_max_mb
sudo systemctl stop lab3-a

# ─────────────────────────────────────────────────────────────────────────────
# 任务 B：伸缩控制环。终端 B 运行 lbd，终端 C 运行 scaler，终端 D 压测。
# 每换一组 scaler：在终端 C 按 Ctrl-C，等它停完实例，再复制下一组命令。
# 开放日曲线实际为 33@120s,33~330@30s,330@300s,330~33@60s,33@120s。
# ─────────────────────────────────────────────────────────────────────────────
# 终端 B（前台；若已启动先查端口，不要重复启动）：
taskset -c 0 bin/lbd
# B0：终端 C 只启 1 台；待实例就绪后，终端 D 压测 20～160 请求/秒。
# [C] 前台运行，保持此终端；[D] 在另一个终端复制下一行。
sudo taskset -c 0 bin/scaler -mode fixed -replicas 1
# [D]
scripts/run3.sh def-b0-one -url http://127.0.0.1:8080/api/courses/1 -rates 20,40,60,80,100,120,140,160 -step 20s
# B1：终端 C 改为常驻 4 台；等 4 台就绪后，终端 D 运行开放日曲线。
# [C] 先 Ctrl-C 停止 B0 scaler。
sudo taskset -c 0 bin/scaler -mode fixed -replicas 4
# [D]
scripts/run3.sh def-b1-fixed -url http://127.0.0.1:8080/api/courses/1 -plan '33@120s,33~330@30s,330@300s,330~33@60s,33@120s'
# B2 CPU：终端 C 起步 2 台、最多 4 台；${quota} 必须保留原样，由 scaler 替换。
# [C] 先 Ctrl-C 停止 B1 scaler。
sudo taskset -c 0 bin/scaler -mode reactive -min 2 -max 4 -signal 'avg(rate(cgroup_cpu_usage_seconds_total{job="instances"}[15s])) / ${quota}'
# [D]
scripts/run3.sh def-b2-cpu -url http://127.0.0.1:8080/api/courses/1 -plan '33@120s,33~330@30s,330@300s,330~33@60s,33@120s'
# B2 请求率：本组单实例容量线 C=84 请求/秒。
# [C] 先 Ctrl-C 停止 B2 CPU scaler。
sudo taskset -c 0 bin/scaler -mode reactive -min 2 -max 4 -target 84 -signal 'sum(rate(lb_requests_total{backend!="none"}[15s])) / count(up{job="instances"} == 1)'
# [D]
scripts/run3.sh def-b2-qps -url http://127.0.0.1:8080/api/courses/1 -plan '33@120s,33~330@30s,330@300s,330~33@60s,33@120s'
# B3：本组定时表在负载开始后 20 秒预热到 4 台，490 秒调回最少 2 台。
# [C] 先 Ctrl-C 停止 B2 请求率 scaler。
sudo taskset -c 0 bin/scaler -mode reactive -min 2 -max 4 -schedule '+20s=4,+490s=2' -signal 'avg(rate(cgroup_cpu_usage_seconds_total{job="instances"}[15s])) / ${quota}'
# [D]
scripts/run3.sh def-b3-sched -url http://127.0.0.1:8080/api/courses/1 -plan '33@120s,33~330@30s,330@300s,330~33@60s,33@120s'
# 终端 D：查看各轮摘要与负载下的错误类型。
cat runs/def-b2-cpu/summary.md
cat runs/def-b2-qps/summary.md
cat runs/def-b3-sched/summary.md

# ─────────────────────────────────────────────────────────────────────────────
# 任务 C：固定 3 台，每台 25% CPU、负载 168 请求/秒。
# 终端 C 先按 Ctrl-C 停止 B3 scaler，再启下列固定 3 台的 scaler。
# 终端 E 的注入命令要在 D 的压测开始后按注释时刻单独复制。
# ─────────────────────────────────────────────────────────────────────────────
sudo taskset -c 0 bin/scaler -mode fixed -replicas 3
# C1：终端 D 运行 240 秒；E 约第 60 秒 kill 8102，第 160 秒暂停 8103 共 20 秒。
# [D] 先运行压测。
scripts/run3.sh def-c1-stop -url http://127.0.0.1:8080/api/courses/1 -plan '168@240s'
# [E] 开始后约第 60 秒复制：
sudo scripts/inject.sh kill 8102
# [E] 开始后约第 160 秒复制：
sudo scripts/inject.sh pause 8103 20
# [D] 负载结束后：
cat runs/def-c1-stop/summary.md
# C2 默认探测：终端 B 使用默认 lbd（间隔 1s、超时 500ms、fall=3、rise=2）。
# 终端 D 运行 120 秒；E 约第 40 秒暂停全部实例 2 秒。
# [D] 先运行压测。
scripts/run3.sh def-c2-default -url http://127.0.0.1:8080/api/courses/1 -plan '168@120s'
# [E] 开始后约第 40 秒复制：
sudo scripts/inject.sh pause all 2
# C2 灵敏探测：终端 B 按 Ctrl-C 停止旧 lbd，复制下一行；等三台重新健康再压测。
# [B]
taskset -c 0 bin/lbd -check-interval 500ms -check-timeout 200ms -fall 1
# [D] 等后端重新健康，再运行负载。
curl -s http://127.0.0.1:8090/backends
scripts/run3.sh def-c2-sensitive -url http://127.0.0.1:8080/api/courses/1 -plan '168@120s'
# [E] 开始后约第 40 秒复制：
sudo scripts/inject.sh pause all 2
cat runs/def-c2-default/summary.md
cat runs/def-c2-sensitive/summary.md
# C3 不摘除：终端 B 按 Ctrl-C 后改回默认 lbd；三台恢复健康再开始。
# [B]
taskset -c 0 bin/lbd
# [D]
curl -s http://127.0.0.1:8090/backends
# 终端 D 运行 240 秒；E 约第 60 秒将 8102 的配额 25%→14%，约第 180 秒恢复 25%。
# [D] 先运行压测。
scripts/run3.sh def-c3-slow -url http://127.0.0.1:8080/api/courses/1 -plan '168@240s'
# [E] 开始后约第 60 秒复制：
sudo scripts/inject.sh slow 8102 14
# [E] 开始后约第 180 秒复制：
sudo scripts/inject.sh restore 8102 25
# C3 离群摘除：终端 B 按 Ctrl-C，再用 -outlier 启动；其余条件不变。
# [B]
taskset -c 0 bin/lbd -outlier
# [D] 等后端重新健康，再运行负载。
curl -s http://127.0.0.1:8090/backends
scripts/run3.sh def-c3-outlier -url http://127.0.0.1:8080/api/courses/1 -plan '168@240s'
# [E] 开始后约第 60 秒复制：
sudo scripts/inject.sh slow 8102 14
# [E] 开始后约第 180 秒复制：
sudo scripts/inject.sh restore 8102 25
cat runs/def-c3-slow/summary.md
cat runs/def-c3-outlier/summary.md

# ─────────────────────────────────────────────────────────────────────────────
# 任务 D1：发布。终端 B 从 -outlier 改回默认 lbd；终端 C 继续保留固定 3 台。
# 第一轮完成后不要重启 scaler：naive 把 v1 换成 v2，graceful 再换成 v3。
# ─────────────────────────────────────────────────────────────────────────────
# [B] 先 Ctrl-C 停止带 -outlier 的 lbd，再启动默认 lbd。
taskset -c 0 bin/lbd
# [D]
curl -s http://127.0.0.1:8090/backends
# 终端 D：168 请求/秒持续 180 秒；E 在开始后约第 30 秒触发直接替换。
# [D]
scripts/run3.sh def-d1-naive -url http://127.0.0.1:8080/api/courses/1 -plan '168@180s'
# [E] 开始后约第 30 秒复制：
curl -X POST 'http://127.0.0.1:8091/rollout?version=v2&mode=naive'
# 终端 D：168 请求/秒持续 420 秒；E 在开始后约第 30 秒触发排空加就绪。
# [D]
scripts/run3.sh def-d1-graceful -url http://127.0.0.1:8080/api/courses/1 -plan '168@420s'
# [E] 开始后约第 30 秒复制：
curl -X POST 'http://127.0.0.1:8091/rollout?version=v3&mode=graceful'
cat runs/def-d1-naive/summary.md
cat runs/def-d1-graceful/summary.md

# ─────────────────────────────────────────────────────────────────────────────
# 任务 D2：自愈。终端 C 先按 Ctrl-C 停掉 D1 scaler，再启固定 3 台。
# 与任务 C/D1 不同：D2 实际负载是 100 请求/秒，480 秒；内存 64M、每请求泄漏 16 KiB。
# ─────────────────────────────────────────────────────────────────────────────
sudo taskset -c 0 bin/scaler -mode fixed -replicas 3 -restart on-failure -memory 64M -args '-warmup 10s -work 1000000 -leak-kb 16'
# 终端 D：三台就绪后压测并查看重启、OOM、缺口。
scripts/run3.sh def-d2-heal -url http://127.0.0.1:8080/api/courses/1 -plan '100@480s'
cat runs/def-d2-heal/summary.md
systemctl show -p NRestarts lab3-inst-8101 lab3-inst-8102 lab3-inst-8103
sudo journalctl -u lab3-inst-8101 --no-pager | tail -n 20
curl -sG http://127.0.0.1:9090/api/v1/query --data-urlencode 'query=sum(changes(process_start_time_seconds{job="instances"}[10m]))'

# ─────────────────────────────────────────────────────────────────────────────
# 任务 E：数据核查与分析（无额外压测）。查看本轮原始结果，再按 LAB3.md 第 6 节作答。
# ─────────────────────────────────────────────────────────────────────────────
scripts/table.sh runs/def-a2-q50 ok_rps p99_ms throttle_ratio
scripts/table.sh runs/def-a3-cap10 ok_rps error_rate report_inflight_max rss_max_mb
cat runs/def-b2-cpu/summary.md
cat runs/def-c1-stop/summary.md
cat runs/def-c3-outlier/summary.md
cat runs/def-d2-heal/summary.md

# ─────────────────────────────────────────────────────────────────────────────
# 已完成的选做 O1：GOMEMLIMIT（A3 相同负载；终端 C 先 Ctrl-C 停掉 D2 scaler）。
# 原实验脚本 o1.sh 使用固定 runs/o1-* 名称；这里手动改用 def-o1-*，不覆盖原记录。
# ─────────────────────────────────────────────────────────────────────────────
sudo systemctl stop lab3-a 2>/dev/null || true
sudo systemctl reset-failed lab3-a 2>/dev/null || true
sudo systemd-run --unit=lab3-a -p MemoryMax=200M -p MemorySwapMax=0 --setenv=GOMEMLIMIT=off --setenv=GOGC=100 "$PWD/bin/enrolld" -addr 127.0.0.1:8081 -data "$PWD/data/a"
scripts/run.sh def-o1-control -url 'http://127.0.0.1:8081/api/report?mb=8&ms=500' -rates 10,20,30 -step 20s
systemctl show -p ActiveState,Result,ExecMainStatus lab3-a
sudo systemctl stop lab3-a 2>/dev/null || true
sudo systemctl reset-failed lab3-a 2>/dev/null || true
sudo systemd-run --unit=lab3-a -p MemoryMax=200M -p MemorySwapMax=0 --setenv=GOMEMLIMIT=170MiB --setenv=GOGC=100 "$PWD/bin/enrolld" -addr 127.0.0.1:8081 -data "$PWD/data/a"
scripts/run.sh def-o1-memlimit -url 'http://127.0.0.1:8081/api/report?mb=8&ms=500' -rates 10,20,30 -step 20s
systemctl show -p ActiveState,Result,ExecMainStatus lab3-a
bin/promsteps -steps runs/def-o1-control/steps.csv -prom http://127.0.0.1:9090 -queries runs/o1-control/gc-queries.txt > runs/def-o1-control/gc.csv
bin/promsteps -steps runs/def-o1-memlimit/steps.csv -prom http://127.0.0.1:9090 -queries runs/o1-memlimit/gc-queries.txt > runs/def-o1-memlimit/gc.csv
sudo systemctl stop lab3-a 2>/dev/null || true

# ─────────────────────────────────────────────────────────────────────────────
# 已完成的选做 O2：两层伸缩。终端 B 确保 lbd 为默认参数。
# 同 B2 的 33→330 曲线，比较即时空位与多等 240 秒才有新节点。
# ─────────────────────────────────────────────────────────────────────────────
# 终端 C：对照组；两台初始实例就绪后，终端 D 压测。
sudo taskset -c 0 bin/scaler -mode reactive -min 2 -max 4 -signal 'avg(rate(cgroup_cpu_usage_seconds_total{job="instances"}[15s])) / ${quota}'
scripts/run3.sh def-o2-direct -url http://127.0.0.1:8080/api/courses/1 -plan '33@120s,33~330@30s,330@300s,330~33@60s,33@120s'
bash scripts/o2-summarize.sh def-o2-direct
# 终端 C 按 Ctrl-C 停掉上组 scaler，再启模拟节点等待组；D 等两台初始实例就绪后压测。
sudo taskset -c 0 bin/scaler -mode reactive -min 2 -max 4 -node-slots 2 -node-wait 240s -signal 'avg(rate(cgroup_cpu_usage_seconds_total{job="instances"}[15s])) / ${quota}'
scripts/run3.sh def-o2-nodewait -url http://127.0.0.1:8080/api/courses/1 -plan '33@120s,33~330@30s,330@300s,330~33@60s,33@120s'
bash scripts/o2-summarize.sh def-o2-nodewait
cat runs/def-o2-direct/summary.md
cat runs/def-o2-nodewait/summary.md

# 全部结束：终端 C/B/A 各按 Ctrl-C 停前台进程；仅在确认没有组员复测时清理 lab3 单元。
# sudo scripts/cleanup.sh
