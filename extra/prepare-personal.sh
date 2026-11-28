#!/usr/bin/env bash
# 个人精简版（xg-040g-md / xg-040g-mf）云端构建准备：
# 全新克隆 pbs05/ponwrt；只装 OpenClash(不带内核)
# + PassWall(Xray 核心+nftables 透明代理) + PON 基础栈
# + 调优三件套；不含其他主题与 Passwall。
# 由 .github/workflows/build-personal.yml 调用，运行在 GitHub-hosted runner 上。
set -euo pipefail

MODEL="${1:?缺少机型名}"
PROFILE="${2:?缺少 target profile}"
SUBTARGET="${3:?缺少 subtarget (an7581/an7583)}"

REPO="${GITHUB_WORKSPACE:?缺少 GITHUB_WORKSPACE}"
SRC="$REPO/ponwrt"
SEED="$REPO/extra/seed-personal.config"

case "$SUBTARGET" in
  an7581|an7583) ;;
  *) echo "::error::不支持的 subtarget: ${SUBTARGET}"; exit 1 ;;
esac

group(){ echo "::group::$*"; }
endg(){ echo "::endgroup::"; }

# ---------------------------------------------------------------
# 1) 主源码（pbs05/ponwrt 的 master 分支同时含 an7581 与 an7583 子目标）
# ---------------------------------------------------------------
group "克隆 pbs05/ponwrt (master)"
git clone --depth 1 https://github.com/pbs05/ponwrt.git "$SRC"
cd "$SRC"

# 出厂默认 LAN IP 写进配置生成器（不使用 uci-defaults）：
#   config_generate 生成固件自带的 /etc/config/network 默认值，新装/重置后
#   LAN 直接就是 192.168.2.1；保留配置升级时 sysupgrade 回写用户的
#   /etc/config/network，config_generate 不参与生成——用户已改的 LAN IP
#   （如 192.168.88.1）不会被覆盖回默认（修复「升级后网关被重置」）。
CG="$SRC/package/base-files/files/bin/config_generate"
[ -f "$CG" ] || { echo "::error::config_generate 不存在"; exit 1; }
sed -i 's|ipaddr:-"192.168.1.1"|ipaddr:-"192.168.2.1"|' "$CG"
grep -q 'ipaddr:-"192.168.2.1"' "$CG" || {
  echo "::error::config_generate 默认 LAN IP patch 失败"; exit 1; }
echo "config_generate 出厂 LAN IP → 192.168.2.1"

# 编译缓存：dl 与 ccache 放到源码树之外，由 Actions cache 跨构建复用
mkdir -p "$REPO/cache/dl" "$REPO/cache/ccache"
[ -e "$SRC/dl" ] || ln -s "$REPO/cache/dl" "$SRC/dl"
[ -e "$SRC/.ccache" ] || ln -s "$REPO/cache/ccache" "$SRC/.ccache"
endg

# ---------------------------------------------------------------
# 2) feeds：官方 + PON/ONU/AIROHA/PassWall 专用 feed
# ---------------------------------------------------------------
group "写入 feeds.conf"
cat > feeds.conf <<'FEEDS'
src-git packages https://github.com/immortalwrt/packages.git
src-git luci https://github.com/immortalwrt/luci.git
src-git routing https://github.com/openwrt/routing.git
src-git telephony https://github.com/openwrt/telephony.git
src-git video https://github.com/openwrt/video.git
src-git pon_drivers https://github.com/pbs05/openwrt-pon-drivers.git
src-git onu https://github.com/naoki66/OpenWrt_ONU_CONFIG.git;main
# PassWall：依赖包仓库在前，luci 应用仓库在后（依赖含 xray-core/tcping/geoview 等）
src-git passwall_packages https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git
src-git passwall https://github.com/Openwrt-Passwall/openwrt-passwall.git
FEEDS
cat feeds.conf
./scripts/feeds update -a
./scripts/feeds install -a
endg

# ---------------------------------------------------------------
# 2.4a) luci-app-librespeed 中文翻译注入
#       上游（immortalwrt/luci feed）po 目录只有 templates，无 zh_Hans；
#       这里按 view 源码 _() 字符串逐条注入简体中文 po，构建系统据此生成
#       luci-i18n-librespeed-zh-cn 包（seed 显式 =y）。msgid 与上游 master
#       test.js / history.js / settings.js 及 menu.d 逐字一致。
# ---------------------------------------------------------------
group "注入 luci-app-librespeed 简体中文翻译"
LS_PO="$SRC/feeds/luci/applications/luci-app-librespeed/po/zh_Hans"
[ -d "$SRC/feeds/luci/applications/luci-app-librespeed" ] || {
  echo "::error::feeds/luci 中未找到 luci-app-librespeed"; exit 1; }
mkdir -p "$LS_PO"
cp "$REPO/extra/files/librespeed-zh.po" "$LS_PO/luci-app-librespeed.po"
grep -q 'msgstr "开始测速"' "$LS_PO/luci-app-librespeed.po" || {
  echo "::error::librespeed 中文 po 注入失败"; exit 1; }
echo "luci-app-librespeed 简体中文翻译已注入（$(grep -c '^msgstr' "$LS_PO/luci-app-librespeed.po") 条）"
endg

# ---------------------------------------------------------------
# 2.4) PassWall 内核开关确认（用户指定：固件内置 Xray 核心）
#      PassWall（v1）的内核是 INCLUDE_* 开关（非 choice），aarch64 上
#      SingBox/SS-Rust/Haproxy 等默认全开；内核裁剪由 seed-personal.config
#      的 INCLUDE 开关完成（只留 Xray），这里仅确认 feed install 生效。
# ---------------------------------------------------------------
group "PassWall feed 就绪确认"
PW_MK="$SRC/feeds/passwall/luci-app-passwall/Makefile"
[ -f "$PW_MK" ] || { echo "::error::未找到 passwall Makefile（feeds install 未生效？）"; exit 1; }
grep -q "INCLUDE_Xray" "$PW_MK" || { echo "::error::passwall Makefile 无 INCLUDE_Xray 选项，上游结构已变"; exit 1; }
grep -q "INCLUDE_SingBox" "$PW_MK" || { echo "::error::passwall Makefile 无 INCLUDE_SingBox 选项，上游结构已变"; exit 1; }
echo "PassWall feed 就绪（INCLUDE 开关模式，内核裁剪由 seed-personal.config 完成）"
endg

# ---------------------------------------------------------------
# 2.4b) ddnsto 内网穿透（koolcenter 官方闭源 ipk，中文界面）
#       替换原 Tailscale：国内服务直连、微信扫码绑定、无需公网 IP。
#       集成方式：构建时下载 ipk 并解包进 files/ overlay 直接编进 rootfs
#       （固件为 APK 包管理无 opkg，运行时安装 ipk 不可行）。
# ---------------------------------------------------------------
group "下载并解包 ddnsto 离线包"
DDNSTO_BASE="http://fw.koolcenter.com/binary/ddnsto/openwrt"
# 本固件基于 APK 包管理（USE_APK default y，固件内无 opkg），不能像旧版那样
# 在首次开机用 opkg 装 ipk（会静默失败 → ddnsto 永远装不上、ipk 白占 /root）。
# 改为构建期直接解包 ipk（ar 归档内 data.tar.gz/xz）落进 files/ overlay，
# 与普通包一致直接编进 rootfs，运行时零依赖。
mkdir -p "$SRC/files" /tmp/ddnsto-x
for f in standard/4.2.8/ddnsto_aarch64.ipk luci-app-ddnsto.ipk luci-i18n-ddnsto-zh-cn.ipk; do
  fn="$(basename "$f")"
  curl -fsSLk "$DDNSTO_BASE/$f" -o "/tmp/ddnsto-x/$fn" || { echo "::error::ddnsto 下载失败: $fn"; exit 1; }
  [ -s "/tmp/ddnsto-x/$fn" ] || { echo "::error::ddnsto 包为空: $fn"; exit 1; }
  # ipk 实测为 tar.gz 归档（内含 ./data.tar.gz），非 ar 格式；ar 仅作兼容回退
  if tar -xzf "/tmp/ddnsto-x/$fn" -C /tmp/ddnsto-x 2>/dev/null && [ -f /tmp/ddnsto-x/data.tar.gz ]; then
    tar -xzf /tmp/ddnsto-x/data.tar.gz -C "$SRC/files" || { echo "::error::ddnsto 解包失败: $fn"; exit 1; }
  elif ar p "/tmp/ddnsto-x/$fn" data.tar.gz > /tmp/ddnsto-x/data.tgz 2>/dev/null; then
    tar -xzf /tmp/ddnsto-x/data.tgz -C "$SRC/files" || { echo "::error::ddnsto 解包失败: $fn"; exit 1; }
  elif ar p "/tmp/ddnsto-x/$fn" data.tar.xz > /tmp/ddnsto-x/data.txz 2>/dev/null; then
    tar -xJf /tmp/ddnsto-x/data.txz -C "$SRC/files" || { echo "::error::ddnsto 解包失败: $fn"; exit 1; }
  else
    echo "::error::ddnsto ipk 结构异常（无 data.tar.gz/xz）: $fn"; exit 1
  fi
  rm -rf /tmp/ddnsto-x; mkdir -p /tmp/ddnsto-x
done
rm -rf /tmp/ddnsto-x
# 落地自检：真实守护进程 ddnstod（常规文件）+ ddnsto 启动符号链接（-f 会解引用
# 链接目标在构建机上不存在而误报，须用 -L 判定）+ init 脚本
[ -f "$SRC/files/usr/sbin/ddnstod" ] || { echo "::error::ddnstod 守护进程未落入 files/"; exit 1; }
[ -L "$SRC/files/usr/sbin/ddnsto" ] || { echo "::error::ddnsto 符号链接未落入 files/"; exit 1; }
[ -f "$SRC/files/etc/init.d/ddnsto" ] || { echo "::error::ddnsto init 脚本未落入 files/"; exit 1; }
echo "ddnsto 已解包进 rootfs overlay:"
find "$SRC/files" -path '*ddnsto*' -o -name 'ddnsto' | head -20
endg

# ---------------------------------------------------------------
# 2.4c) luci-app-accesscontrol（上网时段管控，afala2020 版）
#       单包仓库且 immortalwrt/luci 未收录，clone 拷入 package/（与 NPU 包同模式）。
#       原版 Makefile 用相对路径 include ../../luci.mk（仅 feed 子目录层级有效），
#       拷入 package/ 顶层后解析失败导致包被构建系统静默跳过，须改为 $(TOPDIR) 绝对路径。
#       wechatpush（微信推送）已由 immortalwrt/luci feed 直接收录，无需拷入。
# ---------------------------------------------------------------
group "引入 luci-app-accesscontrol (afala2020)"
AC_DIR="$SRC/package/luci-app-accesscontrol"
if [ ! -f "$AC_DIR/Makefile" ]; then
  rm -rf /tmp/accesscontrol-src
  git clone --depth 1 https://github.com/afala2020/luci-app-accesscontrol.git /tmp/accesscontrol-src
  mkdir -p "$AC_DIR"
  cp -a /tmp/accesscontrol-src/. "$AC_DIR/"
  rm -rf /tmp/accesscontrol-src
fi
sed -i 's|include ../../luci.mk|include $(TOPDIR)/feeds/luci/luci.mk|' "$AC_DIR/Makefile"
# po 目录名对齐官方规范：旧式 zh-cn → zh_Hans（官方语言代码，i18n 包名仍为 -zh-cn，
# 且受已有的 CONFIG_LUCI_LANG_zh_Hans=y 语言开关控制；否则开关名非法导致包不被选中）
mv "$AC_DIR/po/zh-cn" "$AC_DIR/po/zh_Hans" 2>/dev/null || true
test -d "$AC_DIR/po/zh_Hans" || { echo "::error::accesscontrol po 目录改名失败"; exit 1; }
grep -q 'feeds/luci/luci.mk' "$AC_DIR/Makefile" || { echo "::error::accesscontrol Makefile include 修复失败"; exit 1; }
grep -q 'LUCI_TITLE' "$AC_DIR/Makefile" || { echo "::error::luci-app-accesscontrol 源码不完整"; exit 1; }
echo "luci-app-accesscontrol 就绪"
endg

# ---------------------------------------------------------------
# 2.4d) iStore 应用商店（linkease 官方，ipk/apk 双包管理前端）
#       linkease/istore 单仓库多包：luci-app-store + taskd 三件套
#       clone 后拷入 package/。Makefile 已用 $(TOPDIR)/feeds/luci/luci.mk
#       绝对路径，无需 include 修复；前端 dist 由 Makefile 构建时下载，
#       界面自带中文。在线装包走 iStore 官方源（用户态包可用）。
# ---------------------------------------------------------------
group "引入 iStore 应用商店 (linkease)"
IS_DIR="$SRC/package/istore"
if [ ! -f "$IS_DIR/luci-app-store/Makefile" ]; then
  rm -rf /tmp/istore-src
  git clone --depth 1 https://github.com/linkease/istore.git /tmp/istore-src || { echo "::error::istore 克隆失败"; exit 1; }
  mkdir -p "$IS_DIR"
  for pkg in luci-app-store luci-lib-taskd luci-lib-xterm taskd; do
    cp -a "/tmp/istore-src/luci/$pkg" "$IS_DIR/" || { echo "::error::istore 拷入 $pkg 失败"; exit 1; }
  done
  rm -rf /tmp/istore-src
  echo "--- iStore 包目录 ---"
  ls "$IS_DIR"
fi
endg

# ---------------------------------------------------------------
# 2.4e) 主题策略（2026-11-26 调整）：mac 主题整体移除，默认主题改为
#       Argon（jerrykuku 官方 v3.1.4，immortalwrt/luci feed 同步维护，OP 最火主题）。
#       feed argon 自带的 30- 抢默认脚本仍由 files 覆盖废掉（见 3.4a），
#       默认统一由 99-lang-theme 指定，避免并行 commit race。
group "主题策略：默认 Argon（mac 已移除）"
grep -q "CONFIG_PACKAGE_luci-theme-argon=y" "$SEED" || {
  echo "::error::seed 缺少 luci-theme-argon（默认主题包）"; exit 1; }
PW_THEME_MK="$SRC/feeds/luci/themes/luci-theme-argon/Makefile"
grep -q "PKG_VERSION:=3" "$PW_THEME_MK" 2>/dev/null || \
  grep -q "LUCI_TITLE" "$PW_THEME_MK" 2>/dev/null || {
  echo "::warning::feed argon Makefile 结构异常，仅告警不阻塞"; }
echo "默认主题：Argon（feed 版）"
endg

# （2.4g OpenAppFilter 已移除：OAF DPI 识别与 NPU/PPE 流卸载天然互斥，
#   实测关闭流卸载后识别仍不可靠，2026-11-28 经用户确认放弃）

# 2.4c) autocore 重新引入：fork 主页温度/频率/架构 rpcd 读数的 ACL（luci-mod-status-autocore.json）
#       与 /sbin/cpuinfo、/sbin/tempinfo 都由该包提供，个人版此前误删导致概览页三项显示 ?；
#       包本身是纯脚本（含与 overlay 同名文件，overlay files/ 优先级更高，无冲突）
group "引入 autocore（概览页温度/频率读数 + rpcd ACL）"
grep -Fq "CONFIG_PACKAGE_autocore=y" "$SRC/.config" 2>/dev/null || true
echo "autocore 由 seed-personal.config 提供（CONFIG_PACKAGE_autocore=y）"
endg

# ---------------------------------------------------------------
# 2.5) luci-app-airoha-npu（rchen14b 版 v1.0.1）
#      NPU 监控 + CPU 频率控制 + PLL 超频（500-1600MHz 直写寄存器）
#      支持 AN7581/AN7583 双 SoC 检测，拷入 package/ 覆盖 feed 同名包
# ---------------------------------------------------------------
group "引入 luci-app-airoha-npu (NPU 监控 / CPU 超频)"
NPU_DIR="$SRC/package/luci-app-airoha-npu"
# 无条件覆盖：naoki66/luci-app-airoha feed 的同名包（61408B 后端）不带 PLL
# 超频实现，曾因同名冲突压过 package/ 的 rchen14b 版（19581B）——feed 行
# 已删除，此处保留 rm -rf 强制覆盖作为双保险。
rm -rf /tmp/airoha-npu-src "$NPU_DIR"
git clone --depth 1 https://github.com/rchen14b/luci-app-airoha-npu.git /tmp/airoha-npu-src || {
  echo "::error::rchen14b/luci-app-airoha-npu 克隆失败"; exit 1; }
mkdir -p "$NPU_DIR"
cp -a /tmp/airoha-npu-src/. "$NPU_DIR/"
rm -rf /tmp/airoha-npu-src
grep -q 'LUCI_TITLE:=LuCI Airoha SoC Status' "$NPU_DIR/Makefile" || {
  echo "::error::luci-app-airoha-npu 源码不完整"
  exit 1
}
# 确认后端带超频实现（AIROHA_OC_MAX_MHZ 上限配置 + devmem PLL 写入）
grep -q 'AIROHA_OC_MAX_MHZ' "$NPU_DIR/root/usr/libexec/rpcd/luci.airoha_npu" || {
  echo "::error::该版本不含 CPU 超频实现（AIROHA_OC_MAX_MHZ），请检查仓库"
  exit 1
}
grep -q 'devmem' "$NPU_DIR/root/usr/libexec/rpcd/luci.airoha_npu" || {
  echo "::error::该版本后端缺 devmem 超频路径，请检查仓库"
  exit 1
}
echo "luci-app-airoha-npu rchen14b 版就绪（含超频）"
# 注入中文翻译（rchen14b 上游只有西语 po）：po/zh_Hans 使构建系统生成
# luci-i18n-airoha-npu-zh-cn 包（seed 显式 =y，与 wol/smartdns 同模式）。
# msgid 与 view JS _() 内字符串逐字节一致（含后端返回状态词 Active/Idle 等）。
mkdir -p "$NPU_DIR/po/zh_Hans" "$NPU_DIR/luci-app-airoha-npu/po/zh_Hans"
cp "$REPO/extra/files/npu-zh.po" "$NPU_DIR/po/zh_Hans/luci-app-airoha-npu.po"
cp "$REPO/extra/files/npu-zh.po" "$NPU_DIR/luci-app-airoha-npu/po/zh_Hans/luci-app-airoha-npu.po"
grep -q 'msgstr "CPU 频率"' "$NPU_DIR/po/zh_Hans/luci-app-airoha-npu.po" || {
  echo "::error::npu 中文 po 注入失败"; exit 1; }
echo "luci-app-airoha-npu 中文翻译已注入"

# 2.5b) NPU 插件本地化补丁 + bug 修复（sed 补丁见 extra/files/npu-*.sed）：
#   JS：超频确认弹窗硬编码英文 → 中文（未走 _()，po 无效）；
#       调频策略下拉框内核原文名（performance 等）→ 中文标签（value 不变）
#   rpcd：set_overclock 非数字输入绕过校验 → pcw=0 直写 PLL 的 bug 堵死；
#         governor/最大频率只写 policy0 → 遍历全部 cpufreq policy（多簇机型全核生效）
for JSF in "$NPU_DIR/htdocs/luci-static/resources/view/airoha_npu/status.js" \
           "$NPU_DIR/luci-app-airoha-npu/htdocs/luci-static/resources/view/airoha_npu/status.js"; do
  [ -f "$JSF" ] || continue
  sed -i -f "$REPO/extra/files/npu-status-js.sed" "$JSF"
  grep -q 'govLabels\[g\]' "$JSF" || { echo "::error::NPU JS 调频策略中文补丁未生效（上游源码结构可能已变）: $JSF"; exit 1; }
done
# 弹窗中文化（新版 v1.0.1 弹窗走 _() 翻译函数）由 po 覆盖，校验 po 关键条目
grep -q '^msgid "%d MHz is above' "$NPU_DIR/po/zh_Hans/luci-app-airoha-npu.po" 2>/dev/null || {
  echo "::error::NPU po 缺超频弹窗翻译"; exit 1; }
for RPCF in "$NPU_DIR/root/usr/libexec/rpcd/luci.airoha_npu" \
            "$NPU_DIR/luci-app-airoha-npu/root/usr/libexec/rpcd/luci.airoha_npu"; do
  [ -f "$RPCF" ] || { echo "::error::未找到 rpcd 后端: $RPCF"; exit 1; }
  sed -i -f "$REPO/extra/files/npu-rpcd.sed" "$RPCF"
  grep -q 'must be an integer' "$RPCF" || { echo "::error::NPU rpcd 整数校验补丁未生效: $RPCF"; exit 1; }
  grep -q 'for pol in' "$RPCF" || { echo "::error::NPU rpcd 多 policy 补丁未生效: $RPCF"; exit 1; }
  sh -n "$RPCF" || { echo "::error::NPU rpcd 补丁后语法错误: $RPCF"; exit 1; }
done
echo "NPU 插件补丁就绪（JS 中文化 ×2 + rpcd 校验/多policy ×2）"
endg

# ---------------------------------------------------------------
# 3) 机型定制（OpenWrt files/ overlay，直接编进 rootfs）
#    个人精简版保留：概览页读数脚本 / root 密码 / LAN IP / 简体中文
#    + 调优三件套（RPS 多核分发 / 代理调优 sysctl / dnsmasq 缓存，
#      体积近零、无常驻进程，OpenClash 场景直接受益）。
# ---------------------------------------------------------------
group "注入机型定制 ($MODEL)"
OVL="$SRC/files"
mkdir -p "$OVL/etc/uci-defaults"

# ---------------------------------------------------------------
# 3.0 默认时区：中国标准时间（Asia/Shanghai UTC+8）+ 国内 NTP
#     LuCI 时区下拉依赖 zoneinfo 数据包（seed 提供 core+asia）；
#     时间准确是 VMess/TLS 代理握手的前提。
# ---------------------------------------------------------------
cat > "$OVL/etc/uci-defaults/99-timezone" <<'TZ'
#!/bin/sh
uci -q set system.@system[0].timezone='CST-8'
uci -q set system.@system[0].zonename='Asia/Shanghai'
uci -q delete system.ntp
uci -q set system.ntp=timeserver
uci -q set system.ntp.enabled='1'
uci -q add_list system.ntp.server='ntp.aliyun.com'
uci -q add_list system.ntp.server='ntp.tencent.com'
uci -q add_list system.ntp.server='cn.pool.ntp.org'
uci -q commit system
exit 0
TZ


# 3.1 概览页频率/温度显示：LuCI 状态页通过 /sbin/cpuinfo、/sbin/tempinfo 读数。
#     autocore 只在 ipq*/mediatek*/qualcommax* 安装这两个脚本，airoha 不在其列，
#     因此直接从本仓库 overlay 注入，不引入 autocore 包、不改 .config。
mkdir -p "$OVL/sbin"
install -m 0755 "$REPO/config/overlay/sbin/cpuinfo"      "$OVL/sbin/cpuinfo"
install -m 0755 "$REPO/config/overlay/sbin/tempinfo"     "$OVL/sbin/tempinfo"
install -m 0755 "$REPO/config/overlay/sbin/cpufreq_real" "$OVL/sbin/cpufreq_real"

# 3.1b 概览页增强：CPU 温度 / CPU 频率 / 固件编译时间三行（覆盖 luci-mod-status 主页 include）
#     fork 前端靠 autocore 提供的 rpcd 扩展（luci.getTempInfo/getCPUInfo）读数，
#     个人版不装 autocore，rpcd 方法缺失导致温度/频率行不显示。
#     此处覆盖 10_system.js：温度/频率改用 fs.exec/fs.read 直读内核 /sys 节点
#     注意：本 fork 的 LuCI fs.js 没有 listdir() 方法，必须用 fs.exec 走 rpcd
#     执行 shell 读取 thermal zone（fs.read/fs.exec 各版本 LuCI 均有）
#     （CONFIG_AIROHA_THERMAL 与 CPUFREQ 内核侧均已开启，数据源现成），
#     保留 fork 原有 rpcd 逻辑作为优先数据源，另新增固件编译时间行（编译时注入）。
BUILD_TIME="$(TZ='Asia/Shanghai' date '+%Y-%m-%d %H:%M')"
mkdir -p "$OVL/www/luci-static/resources/view/status/include"
cat > "$OVL/www/luci-static/resources/view/status/include/10_system.js" <<'JSEOF'
'use strict';
'require baseclass';
'require fs';
'require rpc';
'require uci';

var callGetUnixtime = rpc.declare({
	object: 'luci',
	method: 'getUnixtime',
	expect: { result: 0 }
});

var callLuciVersion = rpc.declare({
	object: 'luci',
	method: 'getVersion'
});

var callSystemBoard = rpc.declare({
	object: 'system',
	method: 'board'
});

var callSystemInfo = rpc.declare({
	object: 'system',
	method: 'info'
});

var callCPUBench = rpc.declare({
	object: 'luci',
	method: 'getCPUBench'
});

var callCPUInfo = rpc.declare({
	object: 'luci',
	method: 'getCPUInfo'
});

var callCPUUsage = rpc.declare({
	object: 'luci',
	method: 'getCPUUsage'
});

var callTempInfo = rpc.declare({
	object: 'luci',
	method: 'getTempInfo'
});

var FW_BUILD_TIME = '__BUILD_TIME__';

return baseclass.extend({
	title: _('System'),

	load: function() {
		return Promise.all([
			L.resolveDefault(callSystemBoard(), {}),
			L.resolveDefault(callSystemInfo(), {}),
			L.resolveDefault(callCPUBench(), {}),
			L.resolveDefault(callCPUInfo(), {}),
			L.resolveDefault(callCPUUsage(), {}),
			L.resolveDefault(callTempInfo(), {}),
			L.resolveDefault(callLuciVersion(), { revision: _('unknown version'), branch: 'LuCI' }),
			L.resolveDefault(callGetUnixtime(), 0),
			L.resolveDefault(fs.exec('/bin/sh', ['-c',
				'cat /sys/class/thermal/thermal_zone*/temp 2>/dev/null | sort -n | tail -n 1'
			]), {}),
			L.resolveDefault(fs.read('/sys/devices/system/cpu/cpufreq/policy0/cpuinfo_cur_freq'), ''),
			L.resolveDefault(fs.read('/sys/devices/system/cpu/cpufreq/policy0/scaling_cur_freq'), ''),
			L.resolveDefault(fs.read('/sys/devices/system/cpu/cpufreq/cpu0/cpuinfo_cur_freq'), ''),
			L.resolveDefault(fs.exec('/bin/sh', ['-c', '/sbin/cpufreq_real 2>/dev/null']), {}),
			uci.load('system')
		]);
	},

	render: function(data) {
		var boardinfo   = data[0],
		    systeminfo  = data[1],
		    cpubench    = data[2],
		    cpuinfo     = data[3],
		    cpuusage    = data[4],
		    tempinfo    = data[5],
		    luciversion = data[6],
		    unixtime    = data[7],
		    zoneTemp    = (L.isObject(data[8]) && typeof data[8].stdout == 'string') ? parseInt(data[8].stdout, 10) / 1000.0 : 0,
		    freqk1      = parseInt(data[9], 10),
		    freqk2      = parseInt(data[10], 10),
		    freqk3      = parseInt(data[11], 10),
		    freqk0      = (L.isObject(data[12]) && typeof data[12].stdout == 'string') ? parseInt(data[12].stdout, 10) : 0;

		luciversion = luciversion.branch + ' ' + luciversion.revision;

		var datestr = null;

		if (unixtime) {
			var date = new Date(unixtime * 1000),
				zn = uci.get('system', '@system[0]', 'zonename')?.replaceAll(' ', '_') || 'UTC',
				ts = uci.get('system', '@system[0]', 'clock_timestyle') || 0,
				hc = uci.get('system', '@system[0]', 'clock_hourcycle') || 0;

			datestr = new Intl.DateTimeFormat(undefined, {
				dateStyle: 'medium',
				timeStyle: (ts == 0) ? 'long' : 'full',
				hourCycle: (hc == 0) ? undefined : hc,
				timeZone: zn
			}).format(date);
		}

		/* CPU 温度：优先 rpcd(tempinfo)，兜底 shell 直读 thermal zone 最大值 */
		var tempstr = tempinfo.tempinfo || null;

		if (!tempstr && zoneTemp > 0 && zoneTemp < 150)
			tempstr = '%.1f ℃'.format(zoneTemp);

		/* CPU 频率：优先 /sbin/cpufreq_real（PLL 寄存器直读，真值——含 npu APP
		   的 PLL 直写超频，cpufreq sysfs 感知不到），cpufreq sysfs 兜底，再兜
		   底 cpuinfo 输出解析（格式 "…x 2 (1050MHz, 58.4°C)"，rpcd 产物，必有） */
		var freqk = freqk0 || freqk1 || freqk2 || freqk3 || 0,
		    freqstr = null;

		if (freqk > 0) {
			freqstr = (freqk >= 1000000) ? '%.2f GHz'.format(freqk / 1000000) : '%d MHz'.format(Math.round(freqk / 1000));
		} else {
			var mf = (typeof cpuinfo.cpuinfo == 'string' ? cpuinfo.cpuinfo : '').match(/\((\d+)\s*MHz/);

			if (mf && parseInt(mf[1], 10) > 0)
				freqstr = (parseInt(mf[1], 10) >= 1000) ? '%.2f GHz'.format(parseInt(mf[1], 10) / 1000) : '%d MHz'.format(mf[1]);
		}

		/* 固件编译时间：编译时注入（占位符用 indexOf 检测，避免 sed 误伤本行导致永远显示 ?） */
		var buildstr = (FW_BUILD_TIME && FW_BUILD_TIME.indexOf('BUILD') < 0) ? FW_BUILD_TIME : null;

		var fields = [
			_('Hostname'),         boardinfo.hostname,
			_('Model'),            boardinfo.model + cpubench.cpubench,
			_('Architecture'),     cpuinfo.cpuinfo || boardinfo.system,
			_('Target Platform'),  (L.isObject(boardinfo.release) ? boardinfo.release.target : ''),
			_('Firmware Version'), (L.isObject(boardinfo.release) ? boardinfo.release.description + ' / ' : '') + (luciversion || ''),
			_('固件编译时间'),      buildstr,
			_('Kernel Version'),   boardinfo.kernel,
			_('CPU 温度'),         tempstr,
			_('CPU 频率'),         freqstr,
			_('Local Time'),       datestr,
			_('Uptime'),           systeminfo.uptime ? '%t'.format(systeminfo.uptime) : null,
			_('Load Average'),     Array.isArray(systeminfo.load) ? '%.2f, %.2f, %.2f'.format(
				systeminfo.load[0] / 65535.0,
				systeminfo.load[1] / 65535.0,
				systeminfo.load[2] / 65535.0
			) : null,
			_('CPU usage (%)'),    cpuusage.cpuusage
		];

		var table = E('table', { 'class': 'table' });

		for (var i = 0; i < fields.length; i += 2) {
			table.appendChild(E('tr', { 'class': 'tr' }, [
				E('td', { 'class': 'td left', 'width': '33%' }, [ fields[i] ]),
				E('td', { 'class': 'td left' }, [ (fields[i + 1] != null) ? fields[i + 1] : '?' ])
			]));
		}

		return table;
	}
});
JSEOF
# 只替换定义行（^var FW_BUILD_TIME），避免误伤其他引用占位符的逻辑行
sed -i "/^var FW_BUILD_TIME = /s|__BUILD_TIME__|$BUILD_TIME|" "$OVL/www/luci-static/resources/view/status/include/10_system.js"
# 自检：构建日志打印注入结果，未替换或仍含占位符则报错
INJECTED="$(grep -o "FW_BUILD_TIME = '[^']*'" "$OVL/www/luci-static/resources/view/status/include/10_system.js" | head -1)"
echo "BUILD_TIME 注入结果: $INJECTED"
echo "$INJECTED" | grep -q "FW_BUILD_TIME = '20" || { echo "::error::固件编译时间注入失败"; exit 1; }

# 3.1c 远程访问：Tailscale 默认开机自启（首次需在 LuCI → 服务 → Tailscale 登录账号）
cat > "$OVL/etc/uci-defaults/99-ddnsto" <<'TS'
#!/bin/sh
# ddnsto 已在构建期解包进 rootfs（固件为 APK 包管理，无 opkg），
# 这里只负责注册开机自启（幂等）。
[ -x /etc/init.d/ddnsto ] && /etc/init.d/ddnsto enable
exit 0
TS

# 3.2 登录密码 root
ROOT_HASH="$(openssl passwd -1 -salt airoha root 2>/dev/null || true)"
[ -n "$ROOT_HASH" ] || ROOT_HASH='$1$airoha$lzq0xSV6pJiFfzc/JwIoc0'
cat > "$OVL/etc/shadow" <<SHADOW
root:${ROOT_HASH}:0:0:99999:7:::
daemon:*:0:0:99999:7:::
ftp:*:0:0:99999:7:::
network:*:0:0:99999:7:::
nobody:*:0:0:99999:7:::
ntp:*:0:0:99999:7:::
SHADOW

# 3.25 调优三件套（与正式版同款，体积近零）：BBR 由 kmod-tcp-bbr 包自带
#     sysctl 落地；这里补 RPS 多核分发 + TCP/conntrack 代理调优 + DNS 缓存。
mkdir -p "$OVL/etc/sysctl.d" "$OVL/etc/hotplug.d/net"
cat > "$OVL/etc/sysctl.d/90-rps.conf" <<'SYSCTL'
# RFS：全局 socket 流哈希表项数（每流 4096 由热插拔脚本分配）
net.core.rps_sock_flow_entries = 32768
SYSCTL

cat > "$OVL/etc/hotplug.d/net/20-rps" <<'RPS'
#!/bin/sh
# 网卡上线时把 RX 软中断分到 CPU0 以外的所有核（按实际核数自适应：
# MD/AN7581=4 核 → 掩码 e；MF/AN7583=2 核 → 掩码 2；CPU0 留给硬中断）
[ "$ACTION" = "add" ] || exit 0
[ -n "$INTERFACE" ] || exit 0
[ -d "/sys/class/net/$INTERFACE/queues" ] || exit 0
case "$INTERFACE" in
  lo|sit*|ip6tnl*|tun*|tap*|wg*|br-*|docker*|veth*) exit 0 ;;
esac
# 按实际核数自适应：MD(AN7581)=4核 → 掩码 e；MF(AN7583)=2核 → 掩码 2
# 排除 CPU0（留作硬中断），其余 CPU 全部参与 RPS 软中断分发
ncpu=$(grep -c '^processor' /proc/cpuinfo 2>/dev/null)
[ "$ncpu" -ge 1 ] 2>/dev/null || ncpu=4
rps_mask=$(printf '%x' $(( (1 << ncpu) - 2 )))
for q in /sys/class/net/"$INTERFACE"/queues/rx-*/rps_cpus; do
  [ -w "$q" ] && echo "$rps_mask" > "$q" 2>/dev/null
done
# 硬中断固定 CPU0（airoha_eth.* 为 QDMA 收包中断；掩码 1 = 仅 CPU0），
# 与 RPS 掩码互补：硬中断 CPU0 / 软中断分发到其余核 / NPU 卸载流量不进 CPU
awk -F: '/airoha_eth\./ {gsub(/ +/, "", $1); print $1}' /proc/interrupts 2>/dev/null | while read irq; do
  [ -f "/proc/irq/$irq/smp_affinity" ] && echo 1 > "/proc/irq/$irq/smp_affinity" 2>/dev/null
done
for q in /sys/class/net/"$INTERFACE"/queues/rx-*/rps_flow_cnt; do
  [ -w "$q" ] && echo 4096 > "$q" 2>/dev/null
done
exit 0
RPS
chmod +x "$OVL/etc/hotplug.d/net/20-rps"

cat > "$OVL/etc/sysctl.d/91-proxy-tuning.conf" <<'PROXYTUNE'
# TCP/UDP 缓冲上限 16MB：tcp_rmem/wmem 第三列是内核自动调优上限
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 131072 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
# conntrack：代理 UDP/QUIC 海量短连接
net.netfilter.nf_conntrack_max = 131072
PROXYTUNE

# 3.x 小包转发调优（92 号段，晚于 91 号通用/代理调优加载）
#     硬件依据：MD=AN7581 4 核 / MF=AN7583 2 核 / 512MB RAM / 10G PON + EN8811H 2.5G LAN
#     netdev_budget/Usecs/backlog：软中断每轮处理预算与积压队列加大，
#     高 pps（游戏/语音/IPTV 小包）下不丢包不抖动 —— 小包卡顿头号参数
#     fq 队列 + BBR：BBR 官方推荐搭配，降延迟提吞吐（SQM 开 cake 时按口覆盖）
#     min_free_kbytes：512MB 内存下提高最低保留水位，压力期网络栈不因分配失败丢包
#     其余：FastOpen/ECN/MTU 探测/长连接/半开队列 —— 代理与 NAT 场景稳定性
mkdir -p "$OVL/etc/sysctl.d"
cat > "$OVL/etc/sysctl.d/92-packet-tuning.conf" <<'PKTTUNE'
net.core.netdev_budget = 1024
net.core.netdev_budget_usecs = 8000
net.core.netdev_max_backlog = 8192
net.core.somaxconn = 4096
net.core.netdev_tstamp_prequeue = 0
net.ipv4.tcp_fastopen = 3
net.ipv4.tcp_ecn = 1
net.ipv4.tcp_mtu_probing = 1
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 600
net.ipv4.tcp_max_syn_backlog = 4096
net.core.default_qdisc = fq
vm.min_free_kbytes = 32768
net.netfilter.nf_conntrack_tcp_timeout_established = 3600
net.netfilter.nf_conntrack_tcp_timeout_time_wait = 30
net.netfilter.nf_conntrack_tcp_timeout_close_wait = 30
# ---- USB 存储写入调优：脏页回写平滑（SMB/qB/aria2 写盘不再长卡顿） ----
# 默认 dirty_ratio=20%（512MB 内存约 100MB）：攒满 100MB 脏页后内核集中回写，
# USB 盘带宽有限 → SMB 拷贝/下载周期性整段停顿。改为字节限：
# 超过 16MB 起后台持续回写、64MB 强制同步回写，写速曲线平直、无阶梯卡顿
vm.dirty_background_bytes = 16777216
vm.dirty_bytes = 67108864
vm.dirty_writeback_centisecs = 500
vm.dirty_expire_centisecs = 3000
PKTTUNE

# 3.x CPU governor 默认 performance：A53 常开高吞吐/转发场景（MD 4 核/MF 2 核），
#     免去空闲降频带来的首包延迟与软中断处理波动（LuCI cpufreq 界面可改回）
cat > "$OVL/etc/uci-defaults/91-cpu-governor" <<'CPUGOV'
#!/bin/sh
for gov in /sys/devices/system/cpu/cpufreq/policy*/scaling_governor; do
  [ -f "$gov" ] && [ -w "$gov" ] && echo performance > "$gov" 2>/dev/null
done
exit 0
CPUGOV

cat > "$OVL/etc/uci-defaults/98-dns-cache" <<'DNSCACHE'
uci -q set dhcp.@dnsmasq[0].cachesize='2000'
uci -q commit dhcp
DNSCACHE

# 3.x FileBrowser 网页文件管理：开机启用，根目录指向 USB 挂载点 /mnt/
# 访问 http://192.168.2.1:8989，首次账号 admin/admin（登录后请改密）
cat > "$OVL/etc/uci-defaults/99-filebrowser" <<'FILEBROWSER'
#!/bin/sh
uci -q set filebrowser.config.enabled='1'
uci -q set filebrowser.config.root_path='/mnt/'
uci -q commit filebrowser
exit 0
FILEBROWSER

# 3.2a 下载工具开箱即用：qBittorrent（BT/磁力，WebUI :8080，账号 admin/adminadmin）
cat > "$OVL/etc/uci-defaults/98-downloader" <<'DOWNLOADER'
#!/bin/sh
# qBittorrent：默认不自动启动（2026-11-28 用户要求改默认关闭）。
# 下载目录仍预配置好 /mnt/Downloads（95-nas-autolink 热插拔后自动指到盘上），
# 需要时在 LuCI「服务 → qBittorrent」勾选启用即可，无需再填目录。
uci -q set qbittorrent.config.enabled='0'
uci -q set qbittorrent.config.download_dir='/mnt/Downloads'
uci -q commit qbittorrent
# aria2：默认不自动启动（2026-11-28 用户要求，与 qBittorrent 保持一致）。
# 下载目录与运行用户仍预配置好；目录开机先建好（init 硬校验），
# 需要时在 LuCI「服务 → aria2」勾选启用即可。
mkdir -p /mnt/Downloads 2>/dev/null
uci -q set aria2.main.enabled='0'
uci -q set aria2.main.user='root'
uci -q set aria2.main.dir='/mnt/Downloads'
uci -q commit aria2
# ---- 硬盘保护 #2：定时 sync 落盘保险 ----
# 虽然脏页 5 秒即开始回写，但突然断电/拔盘仍可能丢失最后几秒数据；
# 每 5 分钟强制 sync 一次，把暴露窗口压到最小（代价为零——脏页
# 早就被回写掉了，sync 基本是空转）。
cat > "$OVL/etc/uci-defaults/94-data-sync" <<'DATASYNC'
#!/bin/sh
CRONTAB=/etc/crontabs/root
mkdir -p /etc/crontabs
touch "$CRONTAB"
grep -q '^\*/5 \* \* \* \* sync$' "$CRONTAB" || echo '*/5 * * * * sync' >> "$CRONTAB"
/etc/init.d/cron restart 2>/dev/null
exit 0
DATASYNC
# NAS 一条龙热插拔：块设备分区被 blockd 自动挂载后——
#   1) 盘上建 Downloads 目录；2) /mnt/Downloads 符号链接指向最新挂载的盘；
#   3) 同名目录在 tmpfs 的残留（qb/aria2 开机 mkdir 所建）被替换为链接，
#      保证 SMB(nas 共享)、FileBrowser(/mnt)、qBittorrent、aria2 全部即插即用。
# USB 盘性能预调（在挂载前先对整盘设置，分区事件不重复设）：
#   预读 2MB（默认 128KB：顺序读/SMB 列目录/播放视频吞吐提升明显）；
#   IO 调度器 mq-deadline（HDD 顺序化写、flash 延迟折中，优于默认 none）。
cat > "$OVL/etc/hotplug.d/block/93-usb-disk-tune" <<'USBDISK'
#!/bin/sh
[ "$ACTION" = add ] || exit 0
# 只对整盘设备生效（sda/nvme0n1/mmcblk0），分区（sda1）事件跳过
case "$DEVNAME" in
  sd[a-z]|nvme*[0-9]n[0-9]|mmcblk[0-9]) ;;
  *) exit 0 ;;
esac
Q="/sys/block/$DEVNAME/queue"
# 预读 2MB（blockdev 单位 512B 扇区）
blockdev --setra 4096 "/dev/$DEVNAME" 2>/dev/null
# 调度器：内核可选列表含 mq-deadline 才切换（不支持则保留默认，不报错）
[ -w "$Q/scheduler" ] && grep -qw 'mq-deadline' "$Q/scheduler" 2>/dev/null \
  && echo mq-deadline > "$Q/scheduler" 2>/dev/null
# ---- 硬盘保护：把新盘纳入 hd-idle 休眠管理 ----
# 机械盘 10 分钟无访问自动停转：降热、减磨损、省电（U 盘/SSD 收到停转
# 指令只是无操作，不受影响）。动态为每个新盘建 hd-idle 段并重启服务，
# 免去在 LuCI 手动配置；冷插拔（开机已插着的盘）同样会触发本脚本。
if command -v hd-idle >/dev/null 2>&1; then
  case "$DEVNAME" in
    sd*) ;;
    *) DEVNAME="" ;;  # hd-idle 只认 sdX 命名
  esac
  if [ -n "$DEVNAME" ] && ! uci -q show hd-idle | grep -q "disk='$DEVNAME'"; then
    uci -q add hd-idle hd-idle >/dev/null
    uci -q set "hd-idle.@hd-idle[-1].disk=$DEVNAME"
    uci -q set "hd-idle.@hd-idle[-1].enabled=1"
    uci -q set "hd-idle.@hd-idle[-1].idle_time_interval=10"
    uci -q set "hd-idle.@hd-idle[-1].idle_time_unit=minutes"
    uci -q commit hd-idle
    /etc/init.d/hd-idle restart 2>/dev/null
  fi
fi
exit 0
USBDISK
cat > "$OVL/etc/hotplug.d/block/95-nas-autolink" <<'NASLINK'
#!/bin/sh
[ "$ACTION" = add ] || exit 0
case "$DEVNAME" in
  # 分区（sda1）+ 整盘无分区格式化（sda / nvme0n1 / mmcblk0）都认，
  # 覆盖 U 盘/UFS 盒子/移动 SSD 常见的 superfloppy 整盘格式
  sd[a-z][0-9]*|sd[a-z]|nvme*[0-9]n[0-9]*|mmcblk[0-9]*) ;;
  *) exit 0 ;;
esac
MNT="/mnt/$DEVNAME"
# 等待 blockd 完成挂载（最多 10 秒）
i=0
while [ ! -d "$MNT" ] && [ $i -lt 10 ]; do sleep 1; i=$((i+1)); done
[ -d "$MNT" ] || exit 0
mkdir -p "$MNT/Downloads" 2>/dev/null
# 若 /mnt/Downloads 是开机时 qb/aria2 在 tmpfs 建的普通目录，先移除再建链接
[ -L /mnt/Downloads ] || rm -rf /mnt/Downloads
ln -sfn "$MNT/Downloads" /mnt/Downloads
logger -t nas-autolink "USB 分区 $DEVNAME 已挂载于 $MNT，/mnt/Downloads -> $MNT/Downloads"
NASLINK
chmod +x "$OVL/etc/hotplug.d/block/95-nas-autolink"
exit 0
DOWNLOADER

# 3.2b SMB 开箱即用（ksmbd 内核态共享）：默认共享 /mnt 匿名读写，
#     硬盘挂到 /mnt 下后 Windows/手机"网上邻居"直接可见可写，无需建用户。
#     UCI 文件 /etc/config/ksmbd（globals + share 结构，见 ksmbd.init）。
cat > "$OVL/etc/uci-defaults/98-ksmbd-share" <<'KSMBDSHARE'
#!/bin/sh
[ -f /etc/config/ksmbd ] || exit 0
# 幂等保护：已有名为 nas 的共享则跳过。
# 保留设置升级时 uci-defaults 会重新执行，无保护会每升一级多攒一个重复共享。
if uci -q show ksmbd | grep -q "\.name='nas'"; then
  exit 0
fi
# 监听 lan 口
uci -q set ksmbd.@globals[0].interface='lan'
# 匿名读写共享：force_root 免权限坑，guest_ok 免建用户
uci -q add ksmbd share >/dev/null
uci -q set ksmbd.@share[-1].name='nas'
uci -q set ksmbd.@share[-1].path='/mnt'
uci -q set ksmbd.@share[-1].read_only='no'
uci -q set ksmbd.@share[-1].guest_ok='yes'
uci -q set ksmbd.@share[-1].force_root='1'
uci -q set ksmbd.@share[-1].create_mask='0666'
uci -q set ksmbd.@share[-1].dir_mask='0777'
uci -q commit ksmbd
exit 0
KSMBDSHARE

# 3.3 登录 IP 192.168.2.1 —— 已移入 config_generate（clone 段 patch）：
#     出厂默认直接生成在固件 /etc/config/network 里，不再用 uci-defaults；
#     保留配置升级时用户改过的 LAN IP（如 192.168.88.1）不会被覆盖回默认。

# 2.5G 口并入 LAN 桥：md/mf 的 2.5G RJ45 是独立 GMAC（gdm4），netdev 名 lan1
# （EN8811H 2500base-x）。上游兜底配置只桥 eth0，lan1 不在任何接口 → 不通。
# 注意：airoha 以太网驱动 probe 晚，首启 uci-defaults 执行时 lan1 往往还没枚举完
# （与 98-zte-wan 对 eth1 的实测结论一致，存在性检测会误杀 → 2.5G 口不通）。
# 改为后台子壳等待 lan1 出现（最多 60 秒）再配置，不阻塞首启；
# hg5585f 无 lan1，等待超时自动跳过。
cat > "$OVL/etc/uci-defaults/97-lan25g-bridge" <<'LAN25G'
#!/bin/sh
(
  i=0
  while [ ! -e /sys/class/net/lan1 ] && [ $i -lt 60 ]; do sleep 1; i=$((i+1)); done
  [ -e /sys/class/net/lan1 ] || exit 0
  for d in $(uci -q show network | sed -n 's/^network\.\([^.=]*\)=device$/\1/p'); do
    [ "$(uci -q get network.$d.name)" = "br-lan" ] || continue
    case " $(uci -q get network.$d.ports 2>/dev/null) " in
      *" lan1 "*) ;;
      *) uci add_list network.$d.ports='lan1' ;;
    esac
  done
  uci commit network
) &
exit 0
LAN25G

# 2.4b) zte WAN 口：eth1 独立 WAN（DHCP 协议），防火墙加入 wan 区
#   设备布局（md/mf）：eth0/eth1 = 1G GMAC，lan1 = 2.5G GMAC。
#   上游兜底只桥 eth0，lan1 由 97-lan25g-bridge 并入 br-lan，
#   eth1 默认空闲 → 配为独立 DHCP WAN（接上级光猫/路由）。
#   幂等保护：无 eth1 的机型自动跳过；eth1 若已被桥收编先移除；
#   firewall wan 区按 name 动态定位，不依赖 zone 索引。
cat > "$OVL/etc/uci-defaults/98-zte-wan" <<'ZTEWAN'
#!/bin/sh
# 注：不做 /sys/class/net/eth1 存在性检测——uci 配置是声明式的，
# netifd 会在内核枚举出 eth1 后自动挂载接口；首启 uci-defaults 执行时
# eth1 往往还没枚举完（airoha 以太网驱动 probe 晚），存在性检测会误杀。
# 本固件仅面向 md/mf 两机型，eth1 硬件固定存在。
for d in $(uci -q show network | sed -n 's/^network\.\([^.=]*\)=device$/\1/p'); do
  [ "$(uci -q get network.$d.name)" = "br-lan" ] || continue
  case " $(uci -q get network.$d.ports 2>/dev/null) " in
    *" eth1 "*) uci del_list network.$d.ports='eth1' ;;
  esac
done
uci -q batch <<UCIB
set network.zte=interface
set network.zte.proto='dhcp'
set network.zte.device='eth1'
set network.zte.force_link='0'
UCIB
WIDX=$(uci show firewall 2>/dev/null | sed -n "s/^firewall\.@zone\[\([0-9]*\)\]\.name='wan'.*/\1/p" | head -1)
if [ -n "$WIDX" ]; then
  case " $(uci -q get firewall.@zone[$WIDX].network) " in
    *" zte "*) ;;
    *) uci add_list firewall.@zone[$WIDX].network='zte' ;;
  esac
fi
uci commit network
uci commit firewall
exit 0
ZTEWAN

# 98c) 随身wifi 预置 WAN：usb0 DHCP 接口（RNDIS/ECM 模式插上即出网），
#     声明式配置——netifd 在设备枚举后自动上线，未插时接口待机不报错；
#     QMI 模式设备可在 LuCI 里把协议改为 QMI 蜂窝（luci-proto-qmi）。
cat > "$OVL/etc/uci-defaults/98c-usb-wwan" <<'USBWWAN'
#!/bin/sh
case " $(uci -q show network | sed -n 's/^network\.[^.]*=interface$/&/p') " in
  *usbmodem*) exit 0 ;;
esac
uci -q batch <<UCIB
set network.usbmodem=interface
set network.usbmodem.proto='dhcp'
set network.usbmodem.device='usb0'
set network.usbmodem.force_link='0'
UCIB
WIDX=$(uci show firewall 2>/dev/null | sed -n "s/^firewall\.@zone\[\([0-9]*\)\]\.name='wan'.*/\1/p" | head -1)
if [ -n "$WIDX" ]; then
  case " $(uci -q get firewall.@zone[$WIDX].network) " in
    *" usbmodem "*) ;;
    *) uci add_list firewall.@zone[$WIDX].network='usbmodem' ;;
  esac
fi
uci commit network
uci commit firewall
exit 0
USBWWAN

# 95-npu-offload：NPU 硬件流卸载默认开启（Airoha PPE + NPU 硬件转发）
#   flowtable 内核支持由 kmod-nft-offload 提供（上游 airoha generic config
#   NF_FLOW_TABLE 未编入，必须装包；NET_AIROHA_NPU=y 驱动已内置）。
#   开启后 forward 链直连流量经 PPE/NPU 硬件转发；PassWall 代理流量在
#   mangle/nat prerouting 即被 REDIRECT/TPROXY 到本机终结，不进 forward
#   链，不受卸载影响。uci-defaults 仅刷机后首次开机执行，用户之后手动
#   关闭不会被回写。
cat > "$OVL/etc/uci-defaults/95-npu-offload" <<'NPUOFF'
#!/bin/sh
uci -q set firewall.@defaults[0].flow_offloading='1'
uci -q set firewall.@defaults[0].flow_offloading_hw='1'
uci -q commit firewall
exit 0
NPUOFF

# 96-passwall-dns：PassWall 远程 DNS 预置为 8.8.8.8（规避 1.1.1.1 anycast 路由黑洞）
#   根因（2026-11-26 设备实测）：PassWall 默认 remote_dns=1.1.1.1，生成 chinadns-ng
#   trust-dns tcp://1.1.1.1，所有境外域名解析都依赖该可信 DNS。而本节点机房侧对
#   Cloudflare 1.1.1.0/24 anycast 段路由黑洞（1.1.1.1 / 1.0.0.1 :443 全超时，
#   同机房 8.8.4.4:443 正常 302）→ 可信 DNS 永远无响应 → 境外域名解析挂起，
#   表现为「节点配置正确但没网」（国内直连不受影响）。
#   修复：预置 8.8.8.8（实测可达）。注意 remote_dns 必须存裸 IP —— PassWall
#   生成 chinadns-ng 配置时自动拼 tcp:// 前缀，存 'tcp://8.8.8.8' 会被二次
#   拼接成乱码 tcp://tcp://8.8.8.8（本次踩坑实录）。
#   仅当值为默认 1.1.1.1 / 空 / 带前缀默认值时覆盖，用户自定义 DNS 不动；
#   uci-defaults 仅刷机后首次开机执行，之后用户手动改的值不会被回写。
cat > "$OVL/etc/uci-defaults/96-passwall-dns" <<'PWDNS'
#!/bin/sh
[ -f /etc/config/passwall ] || exit 0
cur=$(uci -q get passwall.@global[0].remote_dns)
case "$cur" in
  ""|"1.1.1.1"|"tcp://1.1.1.1"|"udp://1.1.1.1")
    uci set passwall.@global[0].remote_dns='8.8.8.8'
    uci -q commit passwall
    ;;
esac
exit 0
PWDNS

# 3.4 默认简体中文 + 默认主题 Argon（jerrykuku 官方 v3.1.4 / OP 最火主题）
#     mac 主题已整体移除；feed argon 自带的 30- 抢默认脚本被 30_luci-theme-argon
#     覆盖为「只注册」，默认统一由本脚本指定，杜绝并行 commit race。
cat > "$OVL/etc/uci-defaults/99-lang-theme" <<'LANGTHEME'
#!/bin/sh
uci -q set luci.main.lang='zh_cn'
uci -q set luci.main.mediaurlbase='/luci-static/argon'
uci -q commit luci
exit 0
LANGTHEME
# 3.4b 废掉 Argon 自带 uci-defaults 的「抢默认」行为（保留主题注册）
#     根因：首启 uci-defaults 为并行后台执行（( . file ) & + wait），
#     Argon 的迁移脚本 commit 慢、后到——它 commit 时用自己的 config
#     快照重写 /etc/config/luci，会把其他主题注册与默认值抹掉，
#     表现为：首启默认主题随机、主题切换下拉缺项。
#     处理：用 files 覆盖（prepare_rootfs 在包安装后执行）把
#     30_luci-theme-argon 替换为只注册、不设默认的空操作版本。
cat > "$OVL/etc/uci-defaults/30_luci-theme-argon" <<'ARGONFIX'
#!/bin/sh
# 只注册 Argon，不设默认（默认由 99-lang-theme 统一指定）
uci -q set luci.themes.Argon='/luci-static/argon'
exit 0
ARGONFIX
chmod +x "$OVL/etc/uci-defaults/"*
endg

# ---------------------------------------------------------------
# 4) 预置源码包：an7583 的 DEFAULT_PACKAGES 同样含 uboot-envtools
# ---------------------------------------------------------------
group "预置 u-boot / openssl 源码"
mkdir -p dl
UB="dl/u-boot-2026.10.tar.bz2"
if ! curl -fL --connect-timeout 15 --max-time 180 --retry 1 \
      "https://git.u-boot-project.org/u-boot/u-boot/-/releases/v2026.10/downloads/u-boot-2026.10.tar.bz2" \
      -o "$UB"; then
  TMP="$(mktemp -d)"
  curl -fL --retry 3 -o "$TMP/src.tar.gz" \
    "https://github.com/u-boot/u-boot/archive/refs/tags/v2026.10.tar.gz"
  TOP="$(tar -tzf "$TMP/src.tar.gz" | head -1 | cut -d/ -f1)"
  tar -xzf "$TMP/src.tar.gz" -C "$TMP"
  tar -cjf "$UB" -C "$TMP" "$TOP"
  rm -rf "$TMP"
fi
UB_HASH="$(sha256sum "$UB" | cut -d' ' -f1)"
sed -i -E "s/^PKG_HASH:=.*/PKG_HASH:=${UB_HASH}/" \
  tools/mkimage/Makefile package/boot/uboot-tools/Makefile
echo "u-boot hash: ${UB_HASH}"

if [ ! -f dl/openssl-3.5.9.tar.gz ]; then
  curl -fL --retry 3 -o dl/openssl-3.5.9.tar.gz \
    https://github.com/openssl/openssl/releases/download/openssl-3.5.9/openssl-3.5.9.tar.gz
fi
echo "openssl hash: $(sha256sum dl/openssl-3.5.9.tar.gz | cut -d' ' -f1)"
endg

# ---------------------------------------------------------------
# 5) .config：平台按 subtarget 动态写入
#    设备符号 CONFIG_TARGET_airoha_<subtarget>_DEVICE_<profile>=y
# ---------------------------------------------------------------
group "生成 .config (${SUBTARGET} / ${PROFILE})"
# ccache 选项默认带可见性条件（bool "Use ccache" if DEVEL），DEVEL 未开时
# kconfig 视为不可见符号，defconfig 会把它重置回默认值 n，种子里写 y 也无效。
# 这里去掉该条件，让 CONFIG_CCACHE=y 真正生效；不影响其他开发选项。
sed -i 's/^\([[:space:]]*\)bool "Use ccache" if DEVEL$/\1bool "Use ccache"/' config/Config-devel.in
grep -q 'bool "Use ccache"$' config/Config-devel.in || {
  echo "::error::改写 ccache 可见性失败，config/Config-devel.in 结构可能已变"
  exit 1
}
{
  echo "CONFIG_TARGET_airoha=y"
  echo "CONFIG_TARGET_airoha_${SUBTARGET}=y"
  echo 'CONFIG_TARGET_BOARD="airoha"'
  echo "CONFIG_TARGET_SUBTARGET=\"${SUBTARGET}\""
  echo "CONFIG_TARGET_ROOTFS_SQUASHFS=y"
  cat "$SEED"
  echo "CONFIG_TARGET_airoha_${SUBTARGET}_DEVICE_${PROFILE}=y"
} > .config

make defconfig

# ccache 是构建加速项，未生效不阻塞出固件，但要显式告警
if grep -q "^CONFIG_CCACHE=y$" .config; then
  echo "ccache: 已启用"
else
  echo "::warning::CONFIG_CCACHE 未生效，本次构建不会写编译缓存"
fi

if ! grep -q "^CONFIG_TARGET_airoha_${SUBTARGET}_DEVICE_${PROFILE}=y$" .config; then
  echo "::error::机型设备未选中: ${SUBTARGET} / ${PROFILE}"
  echo "--- .config 中实际选中的设备符号 ---"
  grep -E "^CONFIG_TARGET_.*_DEVICE_.*=y$" .config | head -20 || true
  echo "--- 含 ${PROFILE} 的所有行 ---"
  grep -n "$PROFILE" .config | head -20 || true
  exit 1
fi
echo "已选设备: $(grep -E '^CONFIG_TARGET_.*_DEVICE_.*=y$' .config | tr '\n' ' ')"
grep -E "^CONFIG_TARGET_(BOARD|SUBTARGET|PROFILE)=" .config || true

# 关闭设备独立 bootloader / ATF / 外部交叉工具链包
KEYS="$(grep -E '^CONFIG_PACKAGE_(u-boot-|trusted-firmware-a-|arm-gnu-toolchain)[^=]*=y$' .config | sed 's/=y$//' || true)"
for k in $KEYS; do
  sed -i "s|^${k}=y|# ${k} is not set|" .config
done

# ---------------------------------------------------------------
# an7583 专属修复：XG-040G-MF(UBI) 设备除 sysupgrade.itb 外还定义了
#   ARTIFACTS := bl31-uboot.fip preloader.bin
# 这两个 ARTIFACT 是「首次烧录用」的独立 bootloader，生成时要调用 host
# 工具 fiptool（由 arm-trusted-firmware-tools/host 提供），其输入
# bl2.bin / bl31.lzma / u-boot.lzma 又由上面刚禁用的 ATF / u-boot 包产出。
# 于是云端上一轮报 `fiptool: No such file or directory` → target/linux
# 构建失败（Error 127）。它们不属于 sysupgrade 固件，直接移除 ARTIFACT
# 定义，只保留 IMAGES := sysupgrade.itb，与 an7581 三机型处理一致。
# ---------------------------------------------------------------
if [ "$SUBTARGET" = "an7583" ]; then
  group "移除 an7583 独立 bootloader ARTIFACT 规则（修复 fiptool 缺失）"
  MK="target/linux/airoha/image/an7583.mk"
  sed -i -E '/^[[:space:]]*ARTIFACT/d' "$MK"
  echo "剩余 ARTIFACT 定义行数: $(grep -cE '^[[:space:]]*ARTIFACT' "$MK" || true)"
  echo "--- mf-ubi 设备块（确认只产 sysupgrade.itb）---"
  sed -n '/define Device\/nokia_xg-040g-mf-ubi/,/^endef/p' "$MK"
  endg
fi

# ---------------------------------------------------------------
# sysupgrade 元数据兼容修复：补全 image SUPPORTED_DEVICES
# ---------------------------------------------------------------
group "补全 image supported_devices（恢复系统内保留配置升级）"
# fwtool_check_image（an7581/an7583 subtarget 均 REQUIRE_IMAGE_METADATA=1）
# 用板子 DTS compatible（/tmp/sysinfo/board_name）比对镜像 metadata 的
# supported_devices。上游定义与之错位：
#   - fiberhome/nokia 各变体交叉写了对方的名字（不含自身 compatible）
#   - h3c_hm2004-du 与 an7583 的 mf/mf-ubi 完全未定义 SUPPORTED_DEVICES
#     （append-metadata 因条件为假不写 metadata）
# 结果：系统内（LuCI/sysupgrade）升级一律报
#   「Device not supported by this image」/「Image metadata not present」
# 被拒，只能走 U-Boot/recovery 引导刷写。补全后系统内保留配置升级恢复。
MK1="target/linux/airoha/image/an7581.mk"
MK2="target/linux/airoha/image/an7583.mk"
[ -f "$MK1" ] && [ -f "$MK2" ] || { echo "::error::缺少 airoha image 定义文件"; exit 1; }
sed -i \
  -e 's|^  SUPPORTED_DEVICES += fiberhome,hg5585f-ct-usb-sfp$|&\n  SUPPORTED_DEVICES += fiberhome,hg5585f-ct|' \
  -e 's|^  SUPPORTED_DEVICES += fiberhome,hg5585f-ct$|&\n  SUPPORTED_DEVICES += fiberhome,hg5585f-ct-usb-sfp|' \
  -e 's|^  SUPPORTED_DEVICES += fiberhome,hg5585f-cu-usb-sfp$|&\n  SUPPORTED_DEVICES += fiberhome,hg5585f-cu|' \
  -e 's|^  SUPPORTED_DEVICES += fiberhome,hg5585f-cu$|&\n  SUPPORTED_DEVICES += fiberhome,hg5585f-cu-usb-sfp|' \
  -e 's|^  SUPPORTED_DEVICES += nokia,xg-040g-md-ubi-usb-sfp$|&\n  SUPPORTED_DEVICES += nokia,xg-040g-md-ubi|' \
  -e 's|^  SUPPORTED_DEVICES += nokia,xg-040g-md-ubi$|&\n  SUPPORTED_DEVICES += nokia,xg-040g-md-ubi-usb-sfp|' \
  -e 's|^  DEVICE_DTS := an7581-h3c-hm2004-du$|&\n  SUPPORTED_DEVICES += h3c,hm2004-du|' \
  "$MK1"
sed -i \
  -e 's|^  DEVICE_DTS := an7583-nokia_xg-040g-mf-ubi$|&\n  SUPPORTED_DEVICES += nokia,xg-040g-mf-ubi|' \
  -e 's|^  DEVICE_DTS := an7583-nokia_xg-040g-mf$|&\n  SUPPORTED_DEVICES += nokia,xg-040g-mf|' \
  "$MK2"
for dev in fiberhome,hg5585f-ct fiberhome,hg5585f-ct-usb-sfp \
           fiberhome,hg5585f-cu fiberhome,hg5585f-cu-usb-sfp \
           nokia,xg-040g-md-ubi nokia,xg-040g-md-ubi-usb-sfp \
           h3c,hm2004-du; do
  grep -q "^  SUPPORTED_DEVICES += ${dev}\$" "$MK1" || {
    echo "::error::AN7581 supported_devices 补全失败: ${dev}"; exit 1
  }
done
for dev in nokia,xg-040g-mf nokia,xg-040g-mf-ubi; do
  grep -q "^  SUPPORTED_DEVICES += ${dev}\$" "$MK2" || {
    echo "::error::AN7583 supported_devices 补全失败: ${dev}"; exit 1
  }
done
echo "supported_devices 补全完成（AN7581 +7 / AN7583 +2）"
endg

# ---------------------------------------------------------------
# 6) 严格校验：个人精简版正反向双向校验
# ---------------------------------------------------------------
group "校验个人精简版包集合"
# 正向：必须全部入选（OpenClash + PassWall + PON 基础 + 中文
#       + NPU/超频界面 + 插件全家桶）
for p in luci-app-onu luci-i18n-onu-zh-cn luci-app-pon-status airoha-ponctl airoha-pond airoha-pon-debug \
         luci-app-airoha-npu luci-i18n-airoha-npu-zh-cn \
         luci-app-openclash luci-i18n-openclash-zh-cn \
         luci-app-passwall luci-i18n-passwall-zh-cn \
         luci-i18n-base-zh-cn luci-theme-argon \
         xray-core kmod-nft-offload kmod-nft-tproxy kmod-nft-socket \
         kmod-usb-net kmod-usb-net-rndis kmod-usb-net-cdc-ether kmod-usb-net-qmi-wwan \
         uqmi usb-modeswitch luci-proto-qmi \
         zoneinfo-core zoneinfo-asia \
         luci-app-librespeed luci-i18n-librespeed-zh-cn librespeed-go \
         zerotier luci-app-zerotier luci-i18n-zerotier-zh-cn \
         p910nd luci-app-p910nd luci-i18n-p910nd-zh-cn kmod-usb-printer \
         nfs-kernel-server luci-app-nfs luci-i18n-nfs-zh-cn \
         luci-app-store \
         kmod-tcp-bbr \
         filebrowser autocore \
         luci-app-cpufreq luci-i18n-cpufreq-zh-cn kmod-crypto-hw-eip93 kmod-cryptodev \
         openssl-util libopenssl-devcrypto \
         luci-app-wol luci-i18n-wol-zh-cn \
         smartdns luci-app-smartdns luci-i18n-smartdns-zh-cn \
         luci-app-hd-idle luci-i18n-hd-idle-zh-cn \
         luci-app-upnp luci-i18n-upnp-zh-cn \
         luci-app-nlbwmon luci-i18n-nlbwmon-zh-cn \
         sqm-scripts luci-app-sqm luci-i18n-sqm-zh-cn \
         luci-compat luci-app-accesscontrol luci-i18n-accesscontrol-zh-cn \
         luci-app-wechatpush luci-i18n-wechatpush-zh-cn \
         luci-i18n-ksmbd-zh-cn luci-i18n-minidlna-zh-cn luci-i18n-diskman-zh-cn \
         luci-i18n-qbittorrent-zh-cn luci-i18n-aria2-zh-cn \
         jq bash iputils-arping; do
  if ! grep -q "^CONFIG_PACKAGE_${p}=y$" .config; then
    echo "::error::个人精简版缺少 ${p}"
    exit 1
  fi
done
# 超频依赖：busybox CUSTOM 开关 + devmem applet + 内核 /dev/mem 全部必须开启
for c in CONFIG_BUSYBOX_CUSTOM CONFIG_BUSYBOX_CONFIG_DEVMEM CONFIG_KERNEL_DEVMEM; do
  if ! grep -q "^${c}=y$" .config; then
    echo "::error::缺少 ${c}，CPU 超频功能不可用"
    exit 1
  fi
done
# 反向：确认精简目标确实不在固件里
# （EIP93/cryptodev/cpufreq 已按用户要求重新引入；Tailscale 已按用户要求移除，换 ddnsto；
#   PassWall 内核按用户要求只内置 Xray，SingBox 必须不在）
for p in luci-theme-mac luci-theme-aurora luci-app-aurora-config luci-theme-vantage \
         luci-app-vantage luci-app-passwall2 luci-app-ssr-plus \
         tailscale luci-app-tailscale \
         luci-app-qmodem luci-app-qmodem-sms luci-app-qmodem-mwan \
         luci-app-qmodem-ttl sms-forwarder sing-box; do
  if grep -q "^CONFIG_PACKAGE_${p}=y$" .config; then
    echo "::error::个人精简版不应包含 ${p}"
    exit 1
  fi
done
# 语言开关是 HIDDEN 中文包能否被选中的前提，必须存在
if ! grep -q "^CONFIG_LUCI_LANG_zh_Hans=y$" .config; then
  echo "::error::缺少 CONFIG_LUCI_LANG_zh_Hans，中文翻译包不会生效"
  exit 1
fi
echo "个人精简版包校验通过（OpenClash 无内核 + PassWall 内置 Xray 内核 + ddnsto + PON 基础 + NPU/超频 + 插件全家桶）"
endg
