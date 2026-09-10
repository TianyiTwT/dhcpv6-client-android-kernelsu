/*
 * app.js —— DHCPv6 客户端 WebUI 逻辑
 *
 * 只做一件事：把目标接口上的 IPv4 / IPv6 地址读出来显示，并标出哪一个
 * 是本模块通过 DHCPv6 拿到的。
 *
 * 数据来源是两条命令，合并成一次 exec 调用（少一次往返，也免得并发调用桥）：
 *   <模块>/lib/dhcp6c-ctl.sh status    -> key=value 的运行状态
 *   ip -o addr show                    -> 每行一个地址
 * 用一个 ##ADDR 分隔符把两段输出切开。
 */

import { exec, toast, hasBridge } from './kernelsu.js';

/* 模块自身路径从 URL 反推，不写死 —— 免得改了模块 id 这里就失效。
   file:///data/adb/modules/<id>/webroot/index.html */
const MODDIR = (() => {
	const p = decodeURIComponent(location.pathname || '');
	const m = p.match(/^(.*)\/webroot\/index\.html$/);
	return m ? m[1] : '/data/adb/modules/dhcp6c-android';
})();
const CTL = MODDIR + '/lib/dhcp6c-ctl.sh';

const el = {
	subtitle: document.getElementById('subtitle'),
	dot: document.getElementById('dot'),
	banner: document.getElementById('banner'),
	card6: document.getElementById('card6'),
	card4: document.getElementById('card4'),
	footnote: document.getElementById('footnote'),
	refresh: document.getElementById('btnRefresh'),
	restart: document.getElementById('btnRestart'),
};

/* ── 解析 ─────────────────────────────────────────────────────── */

function splitOn(text, sep) {
	const i = String(text).indexOf(sep);
	return i < 0 ? [String(text), ''] : [text.slice(0, i), text.slice(i + sep.length)];
}

function parseKV(text) {
	const out = {};
	for (const line of String(text).split('\n')) {
		const i = line.indexOf('=');
		if (i <= 0) continue;
		out[line.slice(0, i).trim()] = line.slice(i + 1).trim();
	}
	return out;
}

/* 冒号写法（含 :: 压缩）-> 32 位小写十六进制。
   watchdog 的比对和回调的落盘都基于这个形式，
   这里必须用同一套归一化，否则「哪个是本模块拿到的地址」会认错。 */
function hex32(ip) {
	const s = String(ip).trim().replace(/%.*$/, '');
	if (s.indexOf('::') >= 0) {
		const parts = s.split('::');
		const L = parts[0] ? parts[0].split(':') : [];
		const R = parts[1] ? parts[1].split(':') : [];
		const mid = new Array(Math.max(0, 8 - L.length - R.length)).fill('0');
		return L.concat(mid, R).map(g => g.padStart(4, '0')).join('').toLowerCase();
	}
	return s.split(':').map(g => g.padStart(4, '0')).join('').toLowerCase();
}

/* ip -o addr show 的一行形如：
   17: wlan0    inet 10.39.153.4/15 brd 10.39.255.255 scope global wlan0\
   17: wlan0    inet6 fe80::8b8c:cd17:ed8d:f898/64 scope link stable-privacy \
   注意 -o 模式会把换行转义成反斜杠加空格，所以只能按行正则抓。

   尾部用 (.*?)\s*$ 而不是 (.*)$：JS 正则里 \r 属于行终止符，而 `.` 不匹配
   行终止符。一旦输入带 CRLF（比如经 adb 从 Windows 抓的样本），
   (.*)$ 就会因为 `.` 跨不过 \r 而整个匹配失败 —— 表现为「一行都解析不出来」。
   \s* 正好可以吃掉那个 \r。这个坑排查起来很费时间，别再改回去。 */
const ADDR_RE = /^\s*\d+:\s+(\S+)\s+(inet6?)\s+([0-9a-fA-F:.]+)\/(\d+)\s+(.*?)\s*$/;

function parseAddrs(text) {
	const list = [];
	for (const raw of String(text).split(/\r?\n/)) {
		const m = raw.match(ADDR_RE);
		if (!m) continue;
		const rest = m[5];
		list.push({
			ifname: m[1],
			v6: m[2] === 'inet6',
			addr: m[3],
			plen: Number(m[4]),
			scope: (rest.match(/scope\s+(\S+)/) || [, ''])[1],
			temporary: /\btemporary\b/.test(rest),
			deprecated: /\bdeprecated\b/.test(rest),
		});
	}
	return list;
}

/* ── 渲染 ─────────────────────────────────────────────────────── */

function tag(text, own) {
	const s = document.createElement('span');
	s.className = own ? 'tag tag-own' : 'tag';
	s.textContent = text;
	return s;
}

const SCOPE_LABEL = { global: '全局', link: '链路本地', host: '本机', nowhere: '未指定' };
const scopeRank = s => (s === 'global' ? 0 : s === 'link' ? 1 : s === 'host' ? 2 : 3);

function renderList(container, items, iaHex) {
	container.textContent = '';

	if (!items.length) {
		const d = document.createElement('div');
		d.className = 'placeholder';
		d.textContent = '接口上暂无此类地址';
		container.appendChild(d);
		return;
	}

	items.sort((a, b) => scopeRank(a.scope) - scopeRank(b.scope) || a.addr.localeCompare(b.addr));

	for (const it of items) {
		const own = it.v6 && iaHex && hex32(it.addr) === iaHex;

		const row = document.createElement('div');
		row.className = own ? 'row row-own' : 'row';

		const addr = document.createElement('div');
		addr.className = 'row-addr';
		addr.textContent = it.addr;
		row.appendChild(addr);

		const meta = document.createElement('div');
		meta.className = 'row-meta';
		meta.appendChild(tag('/' + it.plen));
		meta.appendChild(tag(SCOPE_LABEL[it.scope] || it.scope));
		if (it.temporary) meta.appendChild(tag('临时'));
		if (it.deprecated) meta.appendChild(tag('已废弃'));
		if (own) meta.appendChild(tag('DHCPv6', true));
		row.appendChild(meta);

		container.appendChild(row);
	}
}

function setBusy(busy) {
	el.refresh.disabled = busy;
	el.restart.disabled = busy;
	el.restart.textContent = busy ? '处理中…' : '重启客户端';
}

function showError(message) {
	el.banner.hidden = false;
	el.banner.className = 'banner banner-error';
	el.banner.textContent = message;
}

/* ── 主流程 ───────────────────────────────────────────────────── */

async function load() {
	let out;
	try {
		out = await exec(CTL + " status; echo '##ADDR'; ip -o addr show");
	} catch (e) {
		showError('读取状态失败：' + (e && e.message ? e.message : e));
		return;
	}

	if (out.errno !== 0 && !out.stdout) {
		showError('读取状态失败（退出码 ' + out.errno + '）' + (out.stderr ? '：' + out.stderr : ''));
		return;
	}
	el.banner.hidden = true;

	const parts = splitOn(out.stdout, '##ADDR');
	const st = parseKV(parts[0]);
	const all = parseAddrs(parts[1]);
	const ifname = st.IFNAME || '';
	const mine = all.filter(a => a.ifname === ifname);

	const v6 = mine.filter(a => a.v6);
	const v4 = mine.filter(a => !a.v6);

	const running = st.RUNNING === '1';
	const paused = st.PAUSED === '1';

	el.dot.className = 'dot ' + (running ? 'dot-on' : paused ? 'dot-idle' : 'dot-off');

	let sub = ifname || '未知接口';
	sub += running ? ' · 已连接' : ' · 未运行';
	if (paused) sub += '（已手动停止）';
	el.subtitle.textContent = sub;

	renderList(el.card6, v6, (st.IA_ADDR_HEX || '').toLowerCase());
	renderList(el.card4, v4, '');

	if (running && !v6.some(a => a.scope === 'global')) {
		el.footnote.textContent =
			'接口上还没有全局 IPv6 地址。可能是网络不提供 DHCPv6 有状态地址分配（IA_NA），'
			+ '也可能客户端还没完成握手。';
	} else {
		el.footnote.textContent = '';
	}
}

async function restart() {
	setBusy(true);
	try {
		const r = await exec(CTL + ' restart');
		if (r.errno === 0) {
			toast('已重启客户端');
			// 握手的实测耗时在亚秒级，给一点余量再读一次
			await new Promise(res => setTimeout(res, 1200));
			await load();
		} else {
			toast('重启失败');
			showError('重启失败（退出码 ' + r.errno + '）' + (r.stderr ? '：' + r.stderr : ''));
		}
	} catch (e) {
		showError('重启失败：' + (e && e.message ? e.message : e));
	} finally {
		setBusy(false);
	}
}

/* ── 启动 ─────────────────────────────────────────────────────── */

el.refresh.addEventListener('click', load);
el.restart.addEventListener('click', restart);

if (!hasBridge()) {
	showError('未检测到 KernelSU 的 WebUI 环境。请在 KernelSU 管理器里打开本页面，'
		+ '而不是用浏览器直接访问。');
	el.refresh.disabled = true;
	el.restart.disabled = true;
} else {
	load();
	// 低频自动刷新；页面不可见时不做，省电
	setInterval(() => {
		if (document.visibilityState === 'visible') load();
	}, 10000);
}
