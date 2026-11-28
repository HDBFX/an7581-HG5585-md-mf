# 补丁 3（bug 修复）：set_overclock 输入校验绕过
# 原校验 [ "$target_mhz" -lt MIN ] 对非数字输入两侧条件均为假，校验被绕过
# → $((target_mhz/25)) 得 0 → pcw=0 直写 PLL，可能把 CPU 锁死。加整数校验堵死。
# 锚点兼容新旧两版（新版注释不同，直接锚在校验行本身）
/if \[ "\$target_mhz" -lt "\$AIROHA_OC_MIN_MHZ" \]/i\
case "$target_mhz" in ''|*[!0-9]*) printf '{"error":"frequency must be an integer MHz"}'; return;; esac
/# Validate range/i\
case "$target_mhz" in ''|*[!0-9]*) echo '{"error":"frequency must be an integer (500-1600 MHz)"}'; return;; esac

# 补丁 4（加固）：调频策略与最大频率只写 policy0 → 遍历全部 cpufreq policy
s|echo "$governor" > /sys/devices/system/cpu/cpufreq/policy0/scaling_governor 2>/dev/null|for pol in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor; do [ -f "$pol" ] \&\& echo "$governor" > "$pol" 2>/dev/null; done|
s|echo "$freq" > /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq 2>/dev/null|for pol in /sys/devices/system/cpu/cpufreq/policy*/scaling_max_freq; do [ -f "$pol" ] \&\& echo "$freq" > "$pol" 2>/dev/null; done|
