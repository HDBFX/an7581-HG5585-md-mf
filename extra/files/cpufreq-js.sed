# luci-app-cpufreq 调频策略下拉框选项中文化：
# governor 值由 o.value(gov) 直接显示，不经 _() 翻译函数，po 无效；
# 仿 NPU 页同款方案：注入 GOV_LABELS 映射作为显示标签（value 不变，配置兼容）。
s#o\.value(gov);#o.value(gov, GOV_LABELS[gov] || gov);#
/^'require form';/a\
var GOV_LABELS = { conservative:'保守模式', ondemand:'按需调频', userspace:'用户指定频率', powersave:'省电模式', performance:'高性能模式', schedutil:'调度器自适应', interactive:'交互模式' };
