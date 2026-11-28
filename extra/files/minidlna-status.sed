# miniDLNA 状态页误报修复：
# wget 探测失败时 fs.exec_direct 返回空字符串（非 null），
# 原代码仅判断 null → 空串被当有效响应 → 显示"正在运行 0 条音频"。
# 补充判断：响应里没有 "Audio files" 字样即视为服务未运行。
s#if (html == null)#if (html == null || html.indexOf('Audio files') == -1)#
