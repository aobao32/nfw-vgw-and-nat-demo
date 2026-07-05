#!/usr/bin/env bash
# 查询指定时间窗口内被 NFW idle timeout 静默切断的 TCP 长连接
# 只关心 state=established 的记录 (TCP 两端都以为连接还活着, 但 NFW 已回收 flow)
#
# 用法示例:
#   ./nfw-idle-report.sh                                # 默认: 过去 24h
#   NFW_WINDOW_HOURS=72 ./nfw-idle-report.sh            # 过去 3 天
#   NFW_TOP_N=50 ./nfw-idle-report.sh                   # 展示前 50 条
#   NFW_LOG_GROUP=/aws/network-firewall/xxx/flow ./nfw-idle-report.sh

set -euo pipefail

# ============ 参数区 =============
REGION="${NFW_REGION:-ap-northeast-1}"
LOG_GROUP="${NFW_LOG_GROUP:-/aws/network-firewall/nfw-test-os-keepalive/flow}"
WINDOW_HOURS="${NFW_WINDOW_HOURS:-24}"
TOP_N="${NFW_TOP_N:-20}"
# ================================

FILTER='{ $.event.netflow.reason = "timeout" && $.event.proto = "TCP" && $.event.netflow.state = "established" }'

WINDOW_SEC=$(( WINDOW_HOURS * 3600 ))
START_MS=$(( ( $(date -u +%s) - WINDOW_SEC ) * 1000 ))

echo "region:        $REGION"
echo "log-group:     $LOG_GROUP"
echo "window:        past ${WINDOW_HOURS}h"
echo "top-N:         $TOP_N"
echo

AWS_PAGER="" aws logs filter-log-events \
  --region "$REGION" \
  --log-group-name "$LOG_GROUP" \
  --start-time "$START_MS" \
  --filter-pattern "$FILTER" \
  --output json \
| TOP_N="$TOP_N" python3 -c "$(cat <<'PY'
import json, sys, os
from datetime import datetime

TOP_N = int(os.environ.get('TOP_N', 20))


def parse_ts(s):
    return datetime.strptime(s, '%Y-%m-%dT%H:%M:%S.%f%z') if s else None


def dur(a, b):
    return (b - a).total_seconds() if a and b else None


d = json.load(sys.stdin)
events = d.get('events', [])
print(f'被 NFW idle timeout 静默切断的 TCP 长连接: {len(events)} 条')
if not events:
    print('(无匹配记录)')
    sys.exit(0)

rows = []
for e in events:
    m = json.loads(e['message'])
    ev = m.get('event', {})
    nf = ev.get('netflow', {})
    t_s = parse_ts(nf.get('start'))
    t_e = parse_ts(nf.get('end'))
    t_v = parse_ts(ev.get('timestamp'))
    rows.append({
        'src': f"{ev.get('src_ip')}:{ev.get('src_port')}",
        'dst': f"{ev.get('dest_ip')}:{ev.get('dest_port')}",
        'app': ev.get('app_proto', '-'),
        'active_age': nf.get('age', 0),
        'idle_duration': dur(t_e, t_v),
        'total_life': dur(t_s, t_v),
        'pkts': nf.get('pkts', 0),
        'bytes': nf.get('bytes', 0),
        'start_short': (nf.get('start') or '')[:19],
        'evt_short':   (ev.get('timestamp') or '')[:19],
    })

print()
print('=' * 148)
print(f'Top {TOP_N} 明细，按 total_life 排序 (连接从建立到被 NFW 闲置切断的持续时长):')
print('=' * 148)
print(f"{'total_life':>10} {'active_age':>10} {'idle_duration':>13} {'pkts':>6} {'bytes':>8}  {'app':>6}  "
      f"{'src':<22} -> {'dst':<22} {'start':<19} {'evt_ts':<19}")
for r in sorted(rows, key=lambda x: x['total_life'] or 0, reverse=True)[:TOP_N]:
    tl   = f"{r['total_life']:.1f}s"    if r['total_life']    is not None else '-'
    aa   = f"{r['active_age']:.1f}s"
    idle = f"{r['idle_duration']:.1f}s" if r['idle_duration'] is not None else '-'
    print(f"{tl:>10} {aa:>10} {idle:>13} {r['pkts']:>6} {r['bytes']:>8}  {r['app']:>6}  "
          f"{r['src']:<22} -> {r['dst']:<22} "
          f"{r['start_short']:<19} {r['evt_short']:<19}")

print()
print('字段说明:')
print('  total_life    = 连接总持续时长 (从 flow 建立、到处于活跃、到闲置下来被 NFW 切断, 即 active_age + idle_duration)')
print('  active_age    = 闲置下来之前，本 flow 的活跃期 (进入闲置前最后一个包的时间 - 第一个包的时间)')
print('  idle_duration = 最后一个包 到 NFW 切断的闲置时长 (≈ NFW 配置的 idle_duration 设置 + NFW 采样延迟)')
PY
)"
