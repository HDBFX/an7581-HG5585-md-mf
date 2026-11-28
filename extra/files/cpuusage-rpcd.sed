# 状态页 CPU 占用虚高修复 v2：区间平均算法
#
# 旧方案（top -d1 -n2 第二帧差分 = 1 秒瞬时值）仍会被 LuCI 总览页
# 的 5 秒轮询风暴"自己测自己"（实测刷出 20~40% 假占用）。
#
# 新方案：把 popen 的采样命令整体替换为区间平均脚本
#   /usr/bin/cpuusage_avg —— 与上次调用做 /proc/stat 差分，
#   显示两次刷新之间的平均占用，覆盖完整轮询周期，回归真实值。
#   脚本本体由 prepare 脚本注入 luci-base/root/usr/bin/ 随固件打包。
s#const fd = popen('top.*#const fd = popen('/bin/sh /usr/bin/cpuusage_avg');#
