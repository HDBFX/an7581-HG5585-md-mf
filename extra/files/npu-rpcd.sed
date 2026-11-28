# 补丁 3（bug 修复）：set_overclock 输入校验绕过
# 原校验 [ "$target_mhz" -lt 500 ] 对非数字输入（"abc" 等）两侧条件均为假，
# 校验被绕过 → $((target_mhz/25)) 按变量名求值得 0 → pcw=0 直写 PLL，
# 可能把 CPU 锁在极低频导致设备异常。加整数正则校验堵死。
/# Validate range (500-1600, crash likely above 1500 at stock voltage)/i\
case "$target_mhz" in ''|*[!0-9]*) echo '{"error":"frequency must be an integer (500-1600 MHz)"}'; return;; esac

# 补丁 4（加固）：调频策略与最大频率目前只写 policy0，改为遍历全部 cpufreq policy
# （多簇/多策略机型上避免只有部分核生效；单策略机型行为不变）
s|echo "$governor" > /sys/devices/system/cpu/cpufreq/policy0/scaling_governor 2>/dev/null|for pol in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor; do [ -f "$pol" ] \&\& echo "$governor" > "$pol" 2>/dev/null; done|
s|echo "$freq" > /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq 2>/dev/null|for pol in /sys/devices/system/cpu/cpufreq/policy*/scaling_max_freq; do [ -f "$pol" ] \&\& echo "$freq" > "$pol" 2>/dev/null; done|
