#!/bin/sh
# 状态页 CPU 占用：4 秒区间平均算法（busybox ash 兼容）
#
# 背景：LuCI 总览页每 5 秒轮询十几个接口，采样若落在刷新风暴中间，
# "自己测自己"会显示 20~40% 的瞬时开销。
#
# 方案：与「上一次快照」做 /proc/stat 差分求平均，且仅当距上次快照
# 满 4 秒才产生新读数（保证每个显示值都是 ≥4 秒窗口的真实平均，
# 风暴被稀释成个位数）；4 秒内的重复调用返回上一个平滑值。
# 首次调用（无任何快照）退化为现场 1 秒双采样。
#
# /proc/stat 聚合行: cpu user nice system idle iowait irq softirq steal
#   total = $2..$8 求和（guest 已计入 user/nice，steal 不计）
#   busy  = total - idle - iowait

snapshot() {
	awk '/^cpu /{t=$2+$3+$4+$5+$6+$7+$8; b=t-$5-$6; print t, b; exit}' /proc/stat
}

NOW=$(date +%s)
if [ -s /tmp/.cpu_prev ]; then
	read PTS T1 B1 < /tmp/.cpu_prev
	snapshot > /tmp/.cpu_now
	read T2 B2 < /tmp/.cpu_now
	DT=$((T2 - T1)); DB=$((B2 - B1))
	if [ $((NOW - PTS)) -ge 4 ] && [ "$DT" -gt 0 ] && [ "$DB" -ge 0 ]; then
		echo "$NOW $T2 $B2" > /tmp/.cpu_prev
		echo -n "$((DB * 100 / DT))%"
		exit 0
	fi
	if [ -s /tmp/.cpu_last ]; then
		read -r LAST < /tmp/.cpu_last
		printf '%s' "$LAST"
		exit 0
	fi
fi
sleep 1
snapshot > /tmp/.cpu_now2
read T1 B1 < /tmp/.cpu_now
read T2 B2 < /tmp/.cpu_now2
DT=$((T2 - T1)); DB=$((B2 - B1))
echo "$NOW $T2 $B2" > /tmp/.cpu_prev
if [ "$DT" -gt 0 ] && [ "$DB" -ge 0 ]; then
	echo -n "$((DB * 100 / DT))%" > /tmp/.cpu_last
	cat /tmp/.cpu_last
else
	echo -n "?"
fi
