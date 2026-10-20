#!/bin/sh
# luci-app-region-select 1.0.0 (2026-10-20)
# 在 网络 → DNS 里增加"区域选择"选项卡：按省份+运营商选择代表性 DNS 网段，
# 作为 EDNS Client Subnet（dnsmasq add-subnet）向上游提交。
#
# 用法：
#   sh luci-app-region-select.sh            安装
#   sh luci-app-region-select.sh status     查看状态
#   sh luci-app-region-select.sh uninstall  卸载（还原 dns.js、删除新增文件）
#
# 安装内容：
#   新增  /www/luci-static/resources/region-select-data.js
#   新增  /usr/share/rpcd/acl.d/luci-app-region-select.json
#   修改  /www/luci-static/resources/view/network/dns.js   （按补丁插入 require 与选项卡代码块）
#   修改  /etc/sysupgrade.conf                             （登记上述文件，升级时保留）
#   备份  /usr/share/luci-app-region-select/dns.js.orig    （卸载时据此字节级还原）

set -e
VERSION="1.0.0"

DNSJS=/www/luci-static/resources/view/network/dns.js
DATAJS=/www/luci-static/resources/region-select-data.js
ACLJS=/usr/share/rpcd/acl.d/luci-app-region-select.json
SUFCONF=/etc/sysupgrade.conf
BKPDIR=/usr/share/luci-app-region-select
BKP=$BKPDIR/dns.js.orig

BEGIN_RE='>>> luci-app-region-select begin >>>'
END_RE='<<< luci-app-region-select end <<<'

msg() { printf '%s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = "0" ] || die "请用 root 运行"
[ -f "$DNSJS" ] || die "找不到 $DNSJS，请确认这是 OpenWrt + LuCI"

TMP=""
cleanup() { if [ -n "$TMP" ] && [ -d "$TMP" ]; then rm -rf "$TMP"; fi; return 0; }
trap cleanup EXIT INT TERM

extract_payload() {
	TMP=$(mktemp -d /tmp/luci-rs.XXXXXX) || die "无法创建临时目录"
	mkdir -p "$TMP/files"
	write_payload
	[ -s "$TMP/files/region-select-data.js" ] || die "载荷写入失败"
}

do_install() {
	extract_payload

	# ---- 1. 先校验 dns.js 结构：不匹配就完全不改动系统 ----
	need_patch=1
	if grep -q "$BEGIN_RE" "$DNSJS" && grep -q "require region-select-data as rs" "$DNSJS"; then
		need_patch=0
	fi
	if [ "$need_patch" = "1" ]; then
		n1=$(grep -c "'require uci';" "$DNSJS" || true)
		n2=$(grep -c "return m.render();}});" "$DNSJS" || true)
		[ "$n1" = "1" ] || die "dns.js 结构与预期不符：require 锚点出现 $n1 次，本机 LuCI 版本可能不兼容（未做任何修改）"
		[ "$n2" = "1" ] || die "dns.js 结构与预期不符：尾部锚点出现 $n2 次，本机 LuCI 版本可能不兼容（未做任何修改）"
	fi

	# ---- 2. 首次安装备份系统自带的 dns.js（只在真正要打补丁时备份）----
	if [ "$need_patch" = "1" ] && [ ! -f "$BKP" ]; then
		mkdir -p "$BKPDIR"
		cp -p "$DNSJS" "$BKP"
		msg "  已备份原始 dns.js"
	fi

	# ---- 3. 新增文件 ----
	cp "$TMP/files/region-select-data.js" "$DATAJS"
	chmod 644 "$DATAJS"
	cp "$TMP/files/luci-app-region-select.json" "$ACLJS"
	chmod 644 "$ACLJS"
	msg "  已安装数据模块与 ACL"

	# ---- 4. 给 dns.js 打补丁 ----
	if [ "$need_patch" = "0" ]; then
		msg "  dns.js 已打过补丁，跳过"
	else
		if grep -q "require region-select-data as rs" "$DNSJS"; then
			msg "  dns.js 依赖已存在，跳过"
		else
			sed -i "s|'require uci';|'require uci';'require region-select-data as rs';|" "$DNSJS"
			msg "  dns.js 已加入模块依赖"
		fi

		if grep -q "$BEGIN_RE" "$DNSJS"; then
			msg "  dns.js 选项卡代码块已存在，跳过"
		else
			awk -v bf="$TMP/files/dns-inject.js" -v anchor="return m.render();}});" '
				!done && index($0, anchor) > 0 {
					p = index($0, anchor)
					printf "%s", substr($0, 1, p - 1)
					while ((getline l < bf) > 0) print l
					close(bf)
					printf "%s\n", substr($0, p)
					done = 1
					next
				}
				{ print }
			' "$DNSJS" > "$DNSJS.new" && mv "$DNSJS.new" "$DNSJS"
			chmod 644 "$DNSJS"
			msg "  dns.js 已插入选项卡代码块"
		fi
	fi

	# ---- 5. sysupgrade.conf 登记 ----
	for f in "$DNSJS" "$DATAJS" "$ACLJS"; do
		if ! grep -qxF "$f" "$SUFCONF" 2>/dev/null; then
			printf '%s\n' "$f" >> "$SUFCONF"
		fi
	done
	msg "  /etc/sysupgrade.conf 已登记"

	# ---- 6. 生效 ----
	rm -f /tmp/luci-indexcache* 2>/dev/null || true
	/etc/init.d/rpcd restart >/dev/null 2>&1 || true
	msg ""
	msg "安装完成（v$VERSION）。"
	msg "  rpcd 已重启，Web 会话会掉线，请重新登录 LuCI。"
	msg "  打开 网络 → DNS，最后一个标签页就是“区域选择”。"
	msg "  总开关默认关闭：勾选、选好省份/运营商，再点 Save & Apply 生效。"
}

do_uninstall() {
	# ---- 1. 还原 dns.js ----
	if [ -f "$BKP" ]; then
		cp -p "$BKP" "$DNSJS"
		msg "  dns.js 已从备份还原"
	else
		if grep -q "$BEGIN_RE" "$DNSJS"; then
			awk -v b="$BEGIN_RE" -v e="$END_RE" '
				index($0, b) > 0 { skip = 1; next }
				index($0, e) > 0 { skip = 0; next }
				!skip { print }
			' "$DNSJS" > "$DNSJS.new" && mv "$DNSJS.new" "$DNSJS"
			chmod 644 "$DNSJS"
			msg "  dns.js 已移除选项卡代码块（无备份，按标记移除）"
		fi
		if grep -q "require region-select-data as rs" "$DNSJS"; then
			sed -i "s|'require region-select-data as rs';||" "$DNSJS"
			msg "  dns.js 已移除模块依赖"
		fi
	fi

	# ---- 2. 删除新增文件与备份 ----
	rm -f "$DATAJS" "$ACLJS"
	rm -rf "$BKPDIR"

	# ---- 3. sysupgrade.conf 去掉登记 ----
	for f in "$DNSJS" "$DATAJS" "$ACLJS"; do
		if grep -qxF "$f" "$SUFCONF" 2>/dev/null; then
			awk -v x="$f" '$0 != x' "$SUFCONF" > "$SUFCONF.new" && mv "$SUFCONF.new" "$SUFCONF"
		fi
	done

	rm -f /tmp/luci-indexcache* 2>/dev/null || true
	/etc/init.d/rpcd restart >/dev/null 2>&1 || true
	msg "已卸载，dns.js 已还原为系统原文件。"
	msg "注意：dnsmasq 的 add-subnet（/etc/config/dhcp 的 extraconftext）不会被改动。"
}

do_status() {
	msg "luci-app-region-select 状态"
	if [ -f "$DATAJS" ]; then msg "  数据模块    : 已安装"; else msg "  数据模块    : 未安装"; fi
	if [ -f "$ACLJS" ]; then msg "  ACL         : 已安装"; else msg "  ACL         : 未安装"; fi
	if grep -q "$BEGIN_RE" "$DNSJS" 2>/dev/null; then msg "  dns.js      : 已打补丁"; else msg "  dns.js      : 未打补丁"; fi
	if grep -q "require region-select-data as rs" "$DNSJS" 2>/dev/null; then msg "  dns.js 依赖 : 已加入"; else msg "  dns.js 依赖 : 未加入"; fi
	if [ -f "$BKP" ]; then msg "  原始备份    : 有"; else msg "  原始备份    : 无"; fi
	n=0
	for f in "$DNSJS" "$DATAJS" "$ACLJS"; do
		if grep -qxF "$f" "$SUFCONF" 2>/dev/null; then n=$((n + 1)); fi
	done
	msg "  sysupgrade  : 已登记 $n/3"
	v=$(uci -q get 'dhcp.@dnsmasq[0].extraconftext' || true)
	msg "  当前 ECS    : ${v:-（未配置）}"
}

# ---- 载荷：把三个文本文件写到 $TMP/files/（here-doc，不依赖 base64）----
write_payload() {
	cat > "$TMP/files/region-select-data.js" <<'RS_EOF_DATA'
'use strict';
'require baseclass';
'require uci';
'require fs';

/*
 * luci-app-region-select —— 区域/运营商 ECS 伪装数据模块
 * 被 view/network/dns.js（DNS 页"区域选择"选项卡）引用。
 * 数据：31 省 × 4 运营商 → 代表性 DNS 网段/24（EDNS Client Subnet 伪装）。
 * 内部编码：
 *   省份：BJ TJ HE SX NM LN JL HL SH JS ZJ AH FJ JX SD HA HB HN GD GX HI CQ SC GZ YN XZ SN GS QH NX XJ
 *   运营商：Unicom Mobile Telecom Broadnet
 * 注：部分省份广电无公开 DNS 记录，用同省移动网段兜底（广电5G与移动共建共享）。
 */

var PROVINCES = [
	['BJ', '京', '北京'],
	['TJ', '津', '天津'],
	['HE', '冀', '河北'],
	['SX', '晋', '山西'],
	['NM', '蒙', '内蒙古'],
	['LN', '辽', '辽宁'],
	['JL', '吉', '吉林'],
	['HL', '黑', '黑龙江'],
	['SH', '沪', '上海'],
	['JS', '苏', '江苏'],
	['ZJ', '浙', '浙江'],
	['AH', '皖', '安徽'],
	['FJ', '闽', '福建'],
	['JX', '赣', '江西'],
	['SD', '鲁', '山东'],
	['HA', '豫', '河南'],
	['HB', '鄂', '湖北'],
	['HN', '湘', '湖南'],
	['GD', '粤', '广东'],
	['GX', '桂', '广西'],
	['HI', '琼', '海南'],
	['CQ', '渝', '重庆'],
	['SC', '川', '四川'],
	['GZ', '贵', '贵州'],
	['YN', '云', '云南'],
	['XZ', '藏', '西藏'],
	['SN', '陕', '陕西'],
	['GS', '甘', '甘肃'],
	['QH', '青', '青海'],
	['NX', '宁', '宁夏'],
	['XJ', '新', '新疆']
];

var CARRIERS = [
	['Unicom',   '联', '联通'],
	['Mobile',   '移', '移动'],
	['Telecom',  '电', '电信'],
	['Broadnet', '广', '广电']
];

var MAP = {
	'Unicom': {
		'BJ': '202.106.0.20/24',
		'TJ': '202.99.104.68/24',
		'HE': '202.99.160.68/24',
		'SX': '202.99.192.66/24',
		'NM': '202.99.224.68/24',
		'LN': '202.96.64.68/24',
		'JL': '202.98.0.68/24',
		'HL': '202.97.224.69/24',
		'SH': '210.22.70.3/24',
		'JS': '221.6.4.66/24',
		'ZJ': '101.71.70.0/24', // 保留用户原始配置(杭州联通)
		'AH': '218.104.78.2/24',
		'FJ': '58.22.96.66/24',
		'JX': '220.248.192.12/24',
		'SD': '202.102.128.68/24',
		'HA': '202.102.224.68/24',
		'HB': '218.104.111.114/24',
		'HN': '58.20.127.170/24',
		'GD': '210.21.196.6/24',
		'GX': '221.7.128.68/24',
		'HI': '221.11.132.2/24',
		'CQ': '221.5.203.98/24',
		'SC': '119.6.6.6/24',
		'GZ': '221.13.28.234/24',
		'YN': '221.3.131.11/24',
		'XZ': '221.13.65.34/24',
		'SN': '221.11.1.67/24',
		'GS': '221.7.34.10/24',
		'QH': '221.207.58.58/24',
		'NX': '221.199.12.157/24',
		'XJ': '221.7.1.20/24',
	},
	'Mobile': {
		'BJ': '211.136.17.107/24',
		'TJ': '211.137.160.5/24',
		'HE': '211.143.60.56/24',
		'SX': '211.138.106.19/24',
		'NM': '211.138.91.1/24',
		'LN': '211.137.32.178/24',
		'JL': '211.141.16.99/24',
		'HL': '211.137.241.34/24',
		'SH': '211.136.112.50/24',
		'JS': '221.131.143.69/24',
		'ZJ': '211.140.13.188/24',
		'AH': '211.138.180.2/24',
		'FJ': '211.138.156.66/24',
		'JX': '211.141.90.68/24',
		'SD': '218.201.96.130/24',
		'HA': '211.138.30.66/24',
		'HB': '211.137.64.163/24',
		'HN': '211.142.210.100/24',
		'GD': '211.136.192.6/24',
		'GX': '211.138.240.100/24',
		'HI': '211.138.164.6/24',
		'CQ': '218.201.17.2/24',
		'SC': '211.137.96.205/24',
		'GZ': '211.139.5.29/24',
		'YN': '211.139.29.150/24',
		'XZ': '211.139.73.34/24',
		'SN': '211.137.130.2/24',
		'GS': '218.203.160.195/24',
		'QH': '211.138.75.123/24',
		'NX': '218.203.123.116/24',
		'XJ': '218.202.152.130/24',
	},
	'Telecom': {
		'BJ': '219.141.136.10/24',
		'TJ': '219.150.32.132/24',
		'HE': '222.222.202.202/24',
		'SX': '211.138.106.19/24', // 山西电信无可靠公开DNS, 同省移动兜底
		'NM': '222.74.39.50/24',
		'LN': '219.148.204.66/24',
		'JL': '219.149.194.55/24',
		'HL': '219.147.198.230/24',
		'SH': '202.96.209.133/24',
		'JS': '218.2.2.2/24',
		'ZJ': '202.101.172.35/24',
		'AH': '61.132.163.68/24',
		'FJ': '218.85.152.99/24',
		'JX': '202.101.224.69/24',
		'SD': '219.146.1.66/24',
		'HA': '222.88.88.88/24',
		'HB': '202.103.24.68/24',
		'HN': '222.246.129.80/24',
		'GD': '202.96.128.86/24',
		'GX': '202.103.225.68/24',
		'HI': '59.50.100.68/24',
		'CQ': '61.128.192.68/24',
		'SC': '61.139.2.69/24',
		'GZ': '202.98.192.67/24',
		'YN': '222.172.200.68/24',
		'XZ': '202.98.224.68/24', // 依真实用户数据(拉萨电信), IP库geo有偏差
		'SN': '61.134.1.4/24',
		'GS': '61.178.0.93/24',
		'QH': '202.100.128.68/24',
		'NX': '202.100.96.68/24',
		'XJ': '61.128.114.167/24',
	},
	'Broadnet': {
		// 有公开记录的省份；其余省份在下方由同省移动兜底
		'TJ': '211.148.160.209/24',
		'JS': '211.167.132.29/24',
		'FJ': '203.190.96.2/24',
		'SD': '210.77.192.88/24',
		'SC': '60.255.80.19/24',
		'SN': '210.87.141.250/24',
	}
};

// 广电多数省份无公开 DNS 记录 → 同省移动网段兜底（广电5G与移动共建共享）
PROVINCES.forEach(function(p) {
	if (!MAP.Broadnet[p[0]])
		MAP.Broadnet[p[0]] = MAP.Mobile[p[0]];
});

function provName(code) {
	for (var i = 0; i < PROVINCES.length; i++)
		if (PROVINCES[i][0] == code)
			return PROVINCES[i][2];
	return code;
}

function carrName(code) {
	for (var i = 0; i < CARRIERS.length; i++)
		if (CARRIERS[i][0] == code)
			return CARRIERS[i][2];
	return code;
}

/* 由 dnsmasq 段的 extraconftext 反查当前生效的省份/运营商 */
function current(sid) {
	var v = (uci.get('dhcp', sid, 'extraconftext') || '').trim();
	var m = v.match(/add-subnet=([0-9.\/]+)/);
	if (!m)
		return null;
	for (var c in MAP)
		for (var p in MAP[c])
			if (MAP[c][p] == m[1])
				return { prov: p, carr: c, cidr: m[1] };
	return null;
}

/* 待落盘的目标值（null 表示无需处理）；applyECS/clearECS 负责写入 */
var _pending = null;

/* 总开关状态：config dnsmasq 是否存在（非空）extraconftext */
function isEnabled(sid) {
	return (uci.get('dhcp', sid, 'extraconftext') || '').trim() != '';
}

/* 关闭总开关：整条删除 extraconftext */
function clearECS(sid) {
	if (uci.get('dhcp', sid, 'extraconftext') == null)
		return false;
	uci.unset('dhcp', sid, 'extraconftext');
	_pending = '';
	return true;
}

function applyECS(sid, prov, carr) {
	var cidr = (carr && prov && MAP[carr] && MAP[carr][prov]) || null;
	if (!cidr)
		return false;
	uci.set('dhcp', sid, 'extraconftext', 'add-subnet=' + cidr);
	_pending = 'add-subnet=' + cidr;
	return true;
}

/* 取出并清除待落盘的目标值；null 表示本次没有改动 */
function takePending() {
	var p = _pending;
	_pending = null;
	return p;
}

/* 读磁盘上真正生效的 extraconftext（uci 命令行读文件，不受 rpcd 暂存影响） */
function readConfigText(sid) {
	return fs.exec('/bin/sh', [ '-c', 'uci -q get dhcp.' + String(sid) + '.extraconftext 2>/dev/null' ])
		.then(function(r) { return (r && r.stdout ? r.stdout : '').trim(); },
			function() { return null; });
}

/* dnsmasq 的 reload 只发 SIGHUP，收到 SIGHUP 不会重读配置文件，所以必须 restart；
   而 LuCI 的 uci.save() 只是暂存，真正写盘要等 uci apply（点 Save & Apply 后的那次），
   因此这里先轮询磁盘上的值，确认写入后再重启，最多等约 10 秒。
   init 脚本又只在 extraconftext 非空时才写 <confdir>/extraconfig.conf、从不清空它，
   所以重启前先删掉该文件，让 init 脚本按当前配置重新生成。 */
function restartDnsmasq(sid) {
	var s = String(sid || '');
	var script = 'D=$(uci -q get dhcp.' + s + '.confdir); ' +
		'D=${D:-/tmp/dnsmasq.' + s + '.d}; ' +
		'rm -f "$D/extraconfig.conf"; ' +
		'/etc/init.d/dnsmasq restart';
	return fs.exec('/bin/sh', [ '-c', script ]);
}

function restartWhenCommitted(sid, want) {
	var tries = 34;

	function poll() {
		return readConfigText(sid).then(function(cur) {
			if (cur === want)
				return restartDnsmasq(sid);
			if (--tries <= 0)
				return false; /* 一直没落盘（比如只点了 Save），不重启 */
			return new Promise(function(res) { setTimeout(res, 300); }).then(poll);
		});
	}

	return poll();
}

/* LuCI 的模块工厂必须返回 baseclass 子类，由加载器实例化一次后缓用。
   数据数组挂在原型上，调用方按 rs.PROVINCES / rs.current(sid) 使用。 */
return baseclass.extend({
	PROVINCES: PROVINCES,
	CARRIERS: CARRIERS,
	MAP: MAP,
	provName: provName,
	carrName: carrName,
	current: current,
	isEnabled: isEnabled,
	clearECS: clearECS,
	applyECS: applyECS,
	takePending: takePending,
	readConfigText: readConfigText,
	restartDnsmasq: restartDnsmasq,
	restartWhenCommitted: restartWhenCommitted
});
RS_EOF_DATA
	cat > "$TMP/files/luci-app-region-select.json" <<'RS_EOF_ACL'
{
	"luci-app-region-select": {
		"description": "区域选择选项卡：允许重启 dnsmasq 使 add-subnet 生效",
		"read": {
			"ubus": {
				"file": [ "exec" ]
			},
			"file": {
				"/etc/init.d/dnsmasq": [ "exec" ],
				"/etc/init.d/dnsmasq restart": [ "exec" ],
				"/bin/sh": [ "exec" ]
			}
		}
	}
}
RS_EOF_ACL
	cat > "$TMP/files/dns-inject.js" <<'RS_EOF_INJECT'
/* >>> luci-app-region-select begin >>> */
/* 说明：DNS 页的选项卡属于 dnsmasq 这个 TypedSection（s.tab('general') 等），
   所以新选项卡必须挂在同一个 section 上，才会出现在同一个标签栏里。 */
try{
var _rsSec=(s&&s.tabs&&s.tabs['general'])?s:null;
if(!_rsSec)
for(var _rsi=0;_rsi<m.children.length;_rsi++){
	var _rsc=m.children[_rsi];
	if(_rsc&&_rsc.tabs&&_rsc.tabs['general']){_rsSec=_rsc;break;}
}
if(_rsSec){
var _rsEnableOpt=null,_rsProvOpt=null,_rsCarrOpt=null;
/* 按两个下拉的当前值写入 extraconftext；总开关关闭时什么都不做 */
var _rsCommit=function(sid){
	if(_rsEnableOpt&&_rsEnableOpt.formvalue(sid)!='1')return false;
	var p=_rsProvOpt?_rsProvOpt.formvalue(sid):'',c=_rsCarrOpt?_rsCarrOpt.formvalue(sid):'';
	var cur=rs.current(sid);
	if(!p&&!c){ /* 两个都没选 */
		if((uci.get('dhcp',sid,'extraconftext')||'').trim()!='')return false; /* 已有自定义值，不擅自覆盖 */
		p='BJ';c='Unicom';
	}
	if(!p&&cur)p=cur.prov;
	if(!c&&cur)c=cur.carr;
	if(!p||!c)return false;
	if(cur&&cur.prov==p&&cur.carr==c)return false; /* 值没变，不写也不重启 */
	return rs.applyECS(sid,p,c);
};
_rsSec.tab('regionselect',_('区域选择'),_('开启总开关后，会用所选运营商在当地的代表性 DNS 网段作为 EDNS Client Subnet（dnsmasq add-subnet）向上游提交，让上游 DNS 认为查询来自该地区。'));
var _rsEnable=_rsSec.taboption('regionselect',form.Flag,'__region_enable__',_('总开关'),_('开启：在 config dnsmasq 写入 extraconftext；关闭：删除整条 extraconftext，不再提交 EDNS Client Subnet。开启时若未选择省份/运营商，默认使用 北京·联通。'));
_rsEnable.load=function(sid){return rs.isEnabled(sid)?'1':'0';};
_rsEnable.write=function(sid,val){
	if(val==this.enabled)_rsCommit(sid);
	else rs.clearECS(sid);
};
_rsEnableOpt=_rsEnable;
var _rsStatus=_rsSec.taboption('regionselect',form.DummyValue,'__region_status__',_('当前生效'));
_rsStatus.load=function(sid){
	if(!rs.isEnabled(sid))return _('已关闭：未设置 extraconftext，DNS 不提交 EDNS Client Subnet');
	var c=rs.current(sid);
	if(c)return rs.provName(c.prov)+' · '+rs.carrName(c.carr)+'（add-subnet='+c.cidr+'）';
	var v=(uci.get('dhcp',sid,'extraconftext')||'').trim();
	if(v)return _('自定义值 %s，不在预设列表中，可重新选择覆盖').format(v);
	return _('尚未配置，请选择省份与运营商后保存');
};
_rsStatus.write=function(){};
_rsStatus.remove=function(){return false;};
var _rsProv=_rsSec.taboption('regionselect',form.ListValue,'__region_prov__',_('省份'));
for(var _rsp=0;_rsp<rs.PROVINCES.length;_rsp++)
	_rsProv.value(rs.PROVINCES[_rsp][0],rs.PROVINCES[_rsp][2]);
_rsProv.load=function(sid){var c=rs.current(sid);return c?c.prov:'';};
_rsProv.remove=function(){return false;};
_rsProv.write=function(sid){_rsCommit(sid);};
_rsProvOpt=_rsProv;
var _rsCarr=_rsSec.taboption('regionselect',form.ListValue,'__region_carr__',_('运营商'));
for(var _rscn=0;_rscn<rs.CARRIERS.length;_rscn++)
	_rsCarr.value(rs.CARRIERS[_rscn][0],rs.CARRIERS[_rscn][2]);
_rsCarr.load=function(sid){var c=rs.current(sid);return c?c.carr:'';};
_rsCarr.remove=function(){return false;};
_rsCarr.write=function(sid){_rsCommit(sid);};
_rsCarrOpt=_rsCarr;
/* 保存前统一按"总开关"处理 extraconftext。
   LuCI 的 Flag 在 parse 阶段的写入门槛依赖 isEqual() 的类型比较（字符串与布尔混用时行为不直观），
   所以在 map.save 里直接读复选框和两个下拉的当前值，逻辑最确定、只跑一次。 */
var _rsApplyState=function(){
	var sid=_rsSec.cfgsections()[0];
	if(!sid)return null;
	if(_rsEnableOpt&&_rsEnableOpt.formvalue(sid)=='1')
		_rsCommit(sid);
	else
		rs.clearECS(sid);
	return sid;
};
var _rsNotifyError=function(msg){
	L.require('ui').then(function(ui){ui.addNotification(null,msg,'error');});
};
var _rsSave=m.save.bind(m);
m.save=function(cb,silent){
	var sid=_rsApplyState();
	return _rsSave(cb,silent).then(function(r){
		var want=sid?rs.takePending():null;
		if(want!==null){
			/* 不能在这里等待：uci.apply（写盘）是在本 promise 之后才被框架调用的，
			   阻塞会让写盘永远等不到。后台轮询到配置真正落盘后再重启 dnsmasq。 */
			rs.restartWhenCommitted(sid,want).then(null,function(e){
				_rsNotifyError(_('dnsmasq 重启失败，add-subnet 可能未生效：%s').format((e&&e.message)||e));
			});
		}
		return r;
	});
};
}
}catch(e){}
/* <<< luci-app-region-select end <<< */
RS_EOF_INJECT
}

case "${1:-install}" in
	install)   do_install ;;
	uninstall) do_uninstall ;;
	status)    do_status ;;
	*)         msg "用法: sh $0 [install|uninstall|status]"; exit 1 ;;
esac
exit 0
