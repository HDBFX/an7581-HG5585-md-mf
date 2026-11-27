#!/usr/bin/env bash
# 个人光猫专版（xg-040g-md / xg-040g-mf）云端构建准备：
# 全新克隆 pbs05/ponwrt；只保留 PON/ONU 核心 + NPU 加速/超频 + 网络加速。
# 不含 QModem、短信转发、USB 4G/5G 模组驱动、OpenClash、SSR-Plus、NAS、
# 脚本环境与额外主题（使用 LuCI 默认 bootstrap 主题 + 简体中文）。
# 由 .github/workflows/build-pon.yml 调用，运行在 GitHub-hosted runner 上。
set -euo pipefail

MODEL="${1:?缺少机型名}"
PROFILE="${2:?缺少 target profile}"
SUBTARGET="${3:?缺少 subtarget (an7581/an7583)}"

REPO="${GITHUB_WORKSPACE:?缺少 GITHUB_WORKSPACE}"
SRC="$REPO/ponwrt"
SEED="$REPO/extra/seed-pon.config"

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

# 编译缓存：dl 与 ccache 放到源码树之外，由 Actions cache 跨构建复用
mkdir -p "$REPO/cache/dl" "$REPO/cache/ccache"
[ -e "$SRC/dl" ] || ln -s "$REPO/cache/dl" "$SRC/dl"
[ -e "$SRC/.ccache" ] || ln -s "$REPO/cache/ccache" "$SRC/.ccache"
endg

# ---------------------------------------------------------------
# 2) feeds：官方 + PON/ONU/AIROHA 专用 feed。
#    光猫专版不需要 qmodem feed（无 4G/5G 模组管理），
#    也不需要 helloworld feed（无 SSR-Plus）。
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
src-git airoha https://github.com/naoki66/luci-app-airoha.git;main
FEEDS
cat feeds.conf
./scripts/feeds update -a
./scripts/feeds install -a
endg

# ---------------------------------------------------------------
# 2.5) luci-app-airoha-npu（rchen14b 版 v1.0.1）
#      NPU 监控 + CPU 频率控制 + PLL 超频（500-1600MHz 直写寄存器）
#      支持 AN7581/AN7583 双 SoC 检测，拷入 package/ 覆盖 feed 同名包
#      —— 光猫专版的"加速"核心，必须保留并校验超频实现。
# ---------------------------------------------------------------
group "引入 luci-app-airoha-npu (NPU 监控 / CPU 超频)"
NPU_DIR="$SRC/package/luci-app-airoha-npu"
if [ ! -f "$NPU_DIR/Makefile" ]; then
  rm -rf /tmp/airoha-npu-src
  git clone --depth 1 https://github.com/rchen14b/luci-app-airoha-npu.git /tmp/airoha-npu-src
  mkdir -p "$NPU_DIR"
  cp -a /tmp/airoha-npu-src/. "$NPU_DIR/"
  rm -rf /tmp/airoha-npu-src
fi
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
endg

# ---------------------------------------------------------------
# 3) 机型定制（OpenWrt files/ overlay，直接编进 rootfs）
#    保留：概览页读数脚本 / root 密码 / LAN IP / 简体中文
#    + 网络加速（RPS 多核分发 / TCP 调优 / dnsmasq 缓存，体积近零）。
#    2.5G 口 lan1 桥接修复为机型基础功能，保留。
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


# 3.1 概览页频率/温度显示：数据源脚本 /sbin/cpuinfo、/sbin/tempinfo 由 autocore 包
#     与本仓库 overlay 双保险提供（overlay 优先），rpcd ACL 也由 autocore 提供，
#     缺它概览页温度/频率/架构会显示 ?
mkdir -p "$OVL/sbin"
install -m 0755 "$REPO/config/overlay/sbin/cpuinfo"  "$OVL/sbin/cpuinfo"
install -m 0755 "$REPO/config/overlay/sbin/tempinfo" "$OVL/sbin/tempinfo"

# 3.1b 概览页增强：CPU 温度 / CPU 频率 / 固件编译时间三行（与个人版同款修复版）
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
		    freqk3      = parseInt(data[11], 10);

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

		/* CPU 频率：优先 cpufreq sysfs（kHz），airoha 布局非标准时从 cpuinfo
		   输出解析（格式 "…x 2 (1050MHz, 58.4°C)"，rpcd getCPUInfo 产物，必有） */
		var freqk = freqk1 || freqk2 || freqk3 || 0,
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

# 3.25 网络加速三件（体积近零纯配置）：BBR 由 kmod-tcp-bbr 包自带
#      sysctl 落地；这里补 RPS 多核分发 + TCP/conntrack 调优 + DNS 缓存。
mkdir -p "$OVL/etc/sysctl.d" "$OVL/etc/hotplug.d/net"
cat > "$OVL/etc/sysctl.d/90-rps.conf" <<'SYSCTL'
# RFS：全局 socket 流哈希表项数（每流 4096 由热插拔脚本分配）
net.core.rps_sock_flow_entries = 32768
SYSCTL

cat > "$OVL/etc/hotplug.d/net/20-rps" <<'RPS'
#!/bin/sh
# 网卡上线时把 RX 软中断分散到 CPU1-3（4 核取掩码 e，CPU0 留给硬中断）
[ "$ACTION" = "add" ] || exit 0
[ -n "$INTERFACE" ] || exit 0
[ -d "/sys/class/net/$INTERFACE/queues" ] || exit 0
case "$INTERFACE" in
  lo|sit*|ip6tnl*|tun*|tap*|wg*|br-*|docker*|veth*) exit 0 ;;
esac
for q in /sys/class/net/"$INTERFACE"/queues/rx-*/rps_cpus; do
  [ -w "$q" ] && echo e > "$q" 2>/dev/null
done
for q in /sys/class/net/"$INTERFACE"/queues/rx-*/rps_flow_cnt; do
  [ -w "$q" ] && echo 4096 > "$q" 2>/dev/null
done
exit 0
RPS
chmod +x "$OVL/etc/hotplug.d/net/20-rps"

cat > "$OVL/etc/sysctl.d/91-net-tuning.conf" <<'NETTUNE'
# TCP/UDP 缓冲上限 16MB：tcp_rmem/wmem 第三列是内核自动调优上限
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 131072 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
# conntrack：大流量 NAT/转发场景
net.netfilter.nf_conntrack_max = 131072
NETTUNE

# 3.2b 小包转发调优（硬件依据：4 核 Cortex-A53 / 512MB RAM / 10G PON + 2.5G LAN）
#      netdev_budget/Usecs/backlog：软中断预算与积压队列加大，高 pps 不丢包不抖动
#      fq + BBR 官方推荐搭配；min_free_kbytes 提高内存最低保留水位防分配失败丢包
#      FastOpen/ECN/MTU 探测/长连接 —— 桥接转发与 NAT 稳定性
cat > "$OVL/etc/sysctl.d/92-packet-tuning.conf" <<'PKTTUNE'
net.core.netdev_budget = 1024
net.core.netdev_budget_usecs = 8000
net.core.netdev_max_backlog = 8192
net.core.somaxconn = 4096
net.core.netdev_tstamp_prequeue = 0
net.core.rps_sock_flow_entries = 32768
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
PKTTUNE

# 3.2c CPU governor 默认 performance（4 核 A53 常开转发场景，LuCI cpufreq 可改）
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

# 3.3 登录 IP 192.168.2.1
cat > "$OVL/etc/uci-defaults/99-lan-ip" <<'LANIP'
#!/bin/sh
uci -q batch <<'UCIBATCH'
set network.lan.ipaddr='192.168.2.1'
set network.lan.netmask='255.255.255.0'
commit network
UCIBATCH
exit 0
LANIP

# 2.5G 口并入 LAN 桥：md/mf 的 2.5G RJ45 是独立 GMAC（gdm4），netdev 名 lan1
# （EN8811H 2500base-x）。上游兜底配置只桥 eth0，lan1 不在任何接口 → 不通。
# 仅当系统存在 lan1（即 md/mf）时追加；hg5585f 无 lan1 自动跳过。
cat > "$OVL/etc/uci-defaults/97-lan25g-bridge" <<'LAN25G'
#!/bin/sh
[ -e /sys/class/net/lan1 ] || exit 0
for d in $(uci -q show network | sed -n 's/^network\.\([^.=]*\)=device$/\1/p'); do
  [ "$(uci -q get network.$d.name)" = "br-lan" ] || continue
  case " $(uci -q get network.$d.ports 2>/dev/null) " in
    *" lan1 "*) ;;
    *) uci add_list network.$d.ports='lan1' ;;
  esac
done
uci commit network
exit 0
LAN25G

# 3.4 默认简体中文（使用 LuCI 默认 bootstrap 主题，光猫专版不带额外主题）
cat > "$OVL/etc/uci-defaults/99-lang" <<'LANG'
#!/bin/sh
uci -q set luci.main.lang='zh_cn'
uci -q commit luci
exit 0
LANG

# 98-pw-dns-selfheal：PassWall DNS 自愈兜底（正式版不带 PassWall，用户后期自装时生效）
#   背景（2026-11-26 设备实测）：PassWall 默认 remote_dns=1.1.1.1 → chinadns-ng
#   trust-dns tcp://1.1.1.1；部分机房对 CF 1.1.1.0/24 anycast 路由黑洞
#   （1.1.1.1/1.0.0.1:443 超时，8.8.4.4:443 正常）→ 境外域名解析挂起 =「没网」。
#   正式版首启时 /etc/config/passwall 尚不存在（用户后期经 iStore/opkg 自装），
#   uci-defaults 直接改不了 → 改为把自愈块写进 /etc/rc.local：
#   每次开机 90 秒后检测一次，装了 PassWall 且远程 DNS 仍为默认值（空/1.1.1.1/
#   带前缀默认）则改为 8.8.8.8 并重启 PassWall；用户自定义 DNS 永不覆盖。
#   注意 remote_dns 必须存裸 IP（PassWall 生成 chinadns-ng 配置时自动拼
#   tcp:// 前缀，存 'tcp://8.8.8.8' 会二次拼接成 tcp://tcp://8.8.8.8 乱码）。
#   rc.local 是同步执行的，sleep 必须放进后台子壳，否则阻塞开机。
cat > "$OVL/etc/uci-defaults/98-pw-dns-selfheal" <<'PWHEAL'
#!/bin/sh
[ -f /etc/rc.local ] || exit 0
grep -q "PW_DNS_SELFHEAL" /etc/rc.local && exit 0
sed -i '/^[[:space:]]*exit 0$/d' /etc/rc.local
cat >> /etc/rc.local <<'RCAPPEND'

# PW_DNS_SELFHEAL: PassWall 默认远程 DNS 1.1.1.1 在部分机房为路由黑洞，自动改 8.8.8.8
(
  sleep 90
  if [ -f /etc/config/passwall ]; then
    cur=$(uci -q get passwall.@global[0].remote_dns)
    case "$cur" in
      ""|"1.1.1.1"|"tcp://1.1.1.1"|"udp://1.1.1.1")
        uci set passwall.@global[0].remote_dns='8.8.8.8'
        uci commit passwall
        /etc/init.d/passwall restart >/dev/null 2>&1
        logger -t pw-dns-selfheal "remote_dns 默认值 → 8.8.8.8（规避 1.1.1.1 anycast 路由黑洞）"
        ;;
    esac
  fi
) &
exit 0
RCAPPEND
exit 0
PWHEAL
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
# 6) 严格校验：光猫专版正反向双向校验
# ---------------------------------------------------------------
group "校验个人光猫专版包集合"
# 正向：必须全部入选（PON/ONU 核心 + NPU/超频 + 中文 + BBR）
for p in luci-app-onu luci-app-pon-status airoha-ponctl airoha-pond airoha-pon-debug zoneinfo-core zoneinfo-asia \
         luci-app-airoha-npu \
         luci-i18n-base-zh-cn kmod-tcp-bbr autocore irqbalance; do
  if ! grep -q "^CONFIG_PACKAGE_${p}=y$" .config; then
    echo "::error::个人光猫专版缺少 ${p}"
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
# 反向：确认"其他插件都不要"确实不在固件里
for p in qmodem qfirehose \
         luci-app-qmodem luci-app-qmodem-next luci-app-qmodem-monitor \
         luci-app-qmodem-ttl luci-app-qmodem-ttlfw4 luci-app-qmodem-sms \
         luci-app-qmodem-mwan sms-forwarder sms-forwarder-next \
         luci-app-openclash luci-app-ssr-plus xray-core \
         luci-app-samba4 luci-app-minidlna luci-app-diskman filebrowser \
         bash python3 jq htop \
         usb-modeswitch kmod-usb-net-qmi-wwan kmod-mtk-t7xx \
         luci-theme-argon luci-theme-aurora luci-app-aurora-config \
         luci-theme-vantage luci-app-vantage luci-app-passwall \
         kmod-crypto-hw-eip93 kmod-cryptodev luci-app-cpufreq ; do
  if grep -q "^CONFIG_PACKAGE_${p}=y$" .config; then
    echo "::error::个人光猫专版不应包含 ${p}"
    exit 1
  fi
done
echo "个人光猫专版包校验通过（PON/ONU 核心 + NPU/超频 + 网络加速，其余插件全部排除）"
