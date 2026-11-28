# 调频策略下拉框显示内核原文名（performance 等）→ 中文标签
# 仅改显示文本，option 的 value 仍为内核原名，提交不受影响。
# 兼容新旧两版结尾（})); 与 ;}));）；弹窗中文化不再走 JS 补丁：
# 新版（v1.0.1）弹窗已改用 _() 翻译函数，由 po/zh_Hans 覆盖。
/function renderGovSelect(avail, active) {/i\
var govLabels={performance:'性能模式',schedutil:'动态调频',ondemand:'按需调频',powersave:'省电模式',conservative:'保守调频',interactive:'交互调频',userspace:'用户态指定'};
s|}}, gs.map(function(g){return E('option',{'value':g,'selected':g===active?'':null},g);}));|}}, gs.map(function(g){return E('option',{'value':g,'selected':g===active?'':null},(govLabels[g]\|\|g));}));|
s|}}, gs.map(function(g){return E('option',{'value':g,'selected':g===active?'':null},g);}))|}}, gs.map(function(g){return E('option',{'value':g,'selected':g===active?'':null},(govLabels[g]\|\|g));}))|
