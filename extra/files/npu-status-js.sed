# 补丁 1：超频确认弹窗硬编码英文 → 中文（该串未走 _()，po 翻译无效）
s|'Frequencies above 1400 MHz may be unstable. Continue?'|'1400 MHz 以上为超频档，可能不稳定，确定继续？'|

# 补丁 2：调频策略下拉框显示内核原文名（performance 等）→ 中文标签
# 仅改显示文本，option 的 value 仍为内核原名，提交不受影响
/function renderGovSelect(avail, active) {/i\
var govLabels={performance:'性能模式',schedutil:'动态调频',ondemand:'按需调频',powersave:'省电模式',conservative:'保守调频',interactive:'交互调频',userspace:'用户态指定'};
s|}}, gs.map(function(g){return E('option',{'value':g,'selected':g===active?'':null},g);}))|}}, gs.map(function(g){return E('option',{'value':g,'selected':g===active?'':null},(govLabels[g]\|\|g));}))|
