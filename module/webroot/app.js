/*
 * app.js —— DHCPv6 客户端 WebUI 逻辑
 *
 * 三件事：
 *   1. 把目标接口上的 IPv4 / IPv6 地址读出来，标出哪一个是我们通过
 *      DHCPv6 拿到的；
 *   2. 把状态浓缩成顶部那张卡（一句话 + 一个图标）；
 *   3. 皮肤与明暗的读写（设置面板）。
 *
 * 数据来源是一条命令，用 ##ADDR / ##PROP 两个分隔符切成三段：
 *   <模块>/lib/dhcp6c-ctl.sh status   -> key=value 的运行状态
 *   ip -o addr show                   -> 每行一个地址
 *   cat <模块>/module.prop            -> 版本号之类
 * 合并成一次 exec 是为了少一次往返 —— KernelSU 的桥每次调用都要
 * 往返一次 WebView 与 native，能省则省。
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
const PROP = MODDIR + '/module.prop';

const KEY_SKIN = 'd6.skin';
const KEY_THEME = 'd6.theme';

const el = {
	settings: document.getElementById('btnSettings'),
	sheet: document.getElementById('sheet'),
	scrim: document.getElementById('scrim'),
	statusCard: document.getElementById('statusCard'),
	statusTitle: document.getElementById('statusTitle'),
	statusSub: document.getElementById('statusSub'),
	statusIcon: document.getElementById('statusIcon'),
	card6: document.getElementById('card6'),
	card4: document.getElementById('card4'),
	footnote: document.getElementById('footnote'),
	banner: document.getElementById('banner'),
	refresh: document.getElementById('btnRefresh'),
	restart: document.getElementById('btnRestart'),
	sIfname: document.getElementById('sIfname'),
	sWatchdog: document.getElementById('sWatchdog'),
	sVersion: document.getElementById('sVersion'),
};

/* ── 偏好存取 ────────────────────────────────────────────────────
 *
 * localStorage 在 file:// 源上不一定可用（取决于 WebView 有没有开
 * DOM storage）。所以内存里**总是**先存一份，localStorage 只是尽力而为 ——
 * 它抛异常时设置就只活这一次会话，而不是整个页面崩掉。 */
const mem = Object.create(null);

function prefGet(key, dflt) {
	try {
		const v = localStorage.getItem(key);
		if (v !== null) return v;
	} catch (e) { /* 落到内存份 */ }
	return key in mem ? mem[key] : dflt;
}

function prefSet(key, value) {
	mem[key] = value;
	try { localStorage.setItem(key, value); } catch (e) { /* 只影响持久化 */ }
}

/* ── 皮肤与主题 ────────────────────────────────────────────────── */

let mq = null;
try { mq = window.matchMedia('(prefers-color-scheme: dark)'); } catch (e) { mq = null; }

function applySkin(skin) {
	document.documentElement.dataset.skin = skin;
	for (const b of el.sheet.querySelectorAll('[data-skin]')) {
		b.setAttribute('aria-pressed', String(b.dataset.skin === skin));
	}
}

function applyTheme(pref) {
	/* 「跟随系统」在这里就被解析掉了，style.css 只认 light / dark ——
	   这样深色 token 只有一份，不会在两处之间跑偏。 */
	const dark = pref === 'dark' || (pref === 'system' && !!mq && mq.matches);
	document.documentElement.dataset.theme = dark ? 'dark' : 'light';
	for (const b of el.sheet.querySelectorAll('[data-theme-opt]')) {
		b.setAttribute('aria-pressed', String(b.dataset.themeOpt === pref));
	}
}

const getSkin = () => prefGet(KEY_SKIN, 'miuix');
const getTheme = () => prefGet(KEY_THEME, 'system');

function initPrefs() {
	applySkin(getSkin());
	applyTheme(getTheme());

	el.sheet.querySelectorAll('[data-skin]').forEach(b => {
		b.addEventListener('click', () => {
			prefSet(KEY_SKIN, b.dataset.skin);
			applySkin(b.dataset.skin);
		});
	});

	el.sheet.querySelectorAll('[data-theme-opt]').forEach(b => {
		b.addEventListener('click', () => {
			prefSet(KEY_THEME, b.dataset.themeOpt);
			applyTheme(b.dataset.themeOpt);
		});
	});

	/* 选了「跟随系统」时，系统在页面开着的时候换深浅也要跟上 */
	if (mq) {
		const onSystemChange = () => {
			if (getTheme() === 'system') applyTheme('system');
		};
		if (mq.addEventListener) mq.addEventListener('change', onSystemChange);
		else if (mq.addListener) mq.addListener(onSystemChange);
	}
}

/* ── 设置面板 ──────────────────────────────────────────────────── */

let sheetTimer = null;

function openSheet() {
	clearTimeout(sheetTimer);
	el.sheet.hidden = false;
	el.scrim.hidden = false;
	requestAnimationFrame(() => {
		el.sheet.classList.add('is-open');
		el.scrim.classList.add('is-open');
	});
}

function closeSheet() {
	el.sheet.classList.remove('is-open');
	el.scrim.classList.remove('is-open');
	/* 动画结束后再真正隐藏，否则位移过渡看不见 */
	sheetTimer = setTimeout(() => {
		el.sheet.hidden = true;
		el.scrim.hidden = true;
	}, 240);
}

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

/* ── 状态卡 ────────────────────────────────────────────────────── */

/* 图标统一用 currentColor 之外的 CSS 变量取色，这样深浅色跟着 token 走。
   绿色只出现在这里 —— 状态卡的文字一律用前景色，不染绿。 */
const ICON_OK = '<svg width="34" height="34" viewBox="0 0 34 34" fill="none">'
	+ '<circle cx="17" cy="17" r="12.5" stroke="var(--ok)" stroke-width="3.2" '
	+ 'stroke-linecap="round" stroke-dasharray="58 21" stroke-dashoffset="12"/>'
	+ '<path d="M11.6 17.4l3.9 3.9 7-7.9" stroke="var(--ok)" stroke-width="3.2" '
	+ 'stroke-linecap="round" stroke-linejoin="round"/></svg>';

/* 灰用 --text-2 而不是 --text-3：--text-3 在深色下是 #636366，压在
   --surface-2 (#2c2c2e) 上几乎看不见，"未取得地址"时会像图标漏画了。 */
const ICON_WARN = '<svg width="34" height="34" viewBox="0 0 34 34" fill="none">'
	+ '<circle cx="17" cy="17" r="12.5" stroke="var(--text-2)" stroke-width="3" '
	+ 'stroke-dasharray="2.5 5.5" stroke-linecap="round"/></svg>';

const ICON_OFF = '<svg width="34" height="34" viewBox="0 0 34 34" fill="none">'
	+ '<circle cx="17" cy="17" r="9.5" stroke="var(--text-2)" stroke-width="3"/></svg>';

/* 判定顺序刻意与 lib/common.sh 的 d6_status_short() 保持一致：
   先排除「本来就不该工作」的原因，最后才说工作结果。
   两处不一致的话，模块卡片上的简介和这个页面会各说各话。 */
function renderStatus(st, addrs) {
	const ifname = st.IFNAME || '';
	const iaHex = (st.IA_ADDR_HEX || '').toLowerCase();
	const mine = addrs.filter(a => a.ifname === ifname && a.v6);
	const hasOwn = !!iaHex && mine.some(a => hex32(a.addr) === iaHex);

	const running = st.RUNNING === '1';
	const paused = st.PAUSED === '1';
	const off = st.MODULE_OFF === '1';
	const up = st.IFACE_UP === '1';

	let kind, title, sub;
	if (off) {
		kind = 'off'; title = '已停用'; sub = '模块被停用或等待卸载';
	} else if (paused) {
		kind = 'warn'; title = '已暂停'; sub = '用户手动停止，看门狗不会拉起';
	} else if (!up) {
		kind = 'warn'; title = '未连接 Wi-Fi'; sub = (ifname || '无线接口') + ' 未就绪';
	} else if (hasOwn) {
		kind = 'ok'; title = '已获取 IPv6 地址'; sub = ifname + ' · 运行中';
	} else if (running) {
		kind = 'warn'; title = '正在获取 IPv6 地址'; sub = ifname + ' · 等待服务器应答';
	} else {
		kind = 'off'; title = '客户端未运行'; sub = '点下面的「重启客户端」';
	}

	el.statusCard.className = 'status-card is-' + kind;
	el.statusTitle.textContent = title;
	el.statusSub.textContent = sub;
	el.statusIcon.innerHTML = kind === 'ok' ? ICON_OK : kind === 'warn' ? ICON_WARN : ICON_OFF;

	return { ifname, running, paused, hasOwn, v6: mine };
}

/* ── 渲染地址列表 ─────────────────────────────────────────────── */

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
		out = await exec(
			CTL + " status; echo '##ADDR'; ip -o addr show"
			+ "; echo '##PROP'; cat " + PROP
		);
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
	const rest = splitOn(parts[1], '##PROP');
	const all = parseAddrs(rest[0]);
	const prop = parseKV(rest[1]);

	const view = renderStatus(st, all);
	const ifname = view.ifname;

	renderList(el.card6, all.filter(a => a.ifname === ifname && a.v6), (st.IA_ADDR_HEX || '').toLowerCase());
	renderList(el.card4, all.filter(a => a.ifname === ifname && !a.v6), '');

	if (view.running && !view.hasOwn) {
		el.footnote.textContent =
			'还没有拿到全局 IPv6 地址。可能是网络不提供 DHCPv6 有状态地址分配（IA_NA），'
			+ '也可能客户端还没完成握手。';
	} else {
		el.footnote.textContent = '';
	}

	/* 设置面板里的只读信息 */
	el.sIfname.textContent = ifname || '—';
	el.sWatchdog.textContent = view.paused ? '已暂停'
		: st.WATCHDOG === '1' ? '运行中' : '未运行';
	if (prop.version) el.sVersion.textContent = prop.version;
}

async function restart() {
	setBusy(true);
	try {
		const r = await exec(CTL + ' restart');
		if (r.errno === 0) {
			toast('已重启客户端');
			/* 握手的实测耗时在亚秒级，给一点余量再读一次 */
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

initPrefs();

el.settings.addEventListener('click', openSheet);
el.scrim.addEventListener('click', closeSheet);
document.addEventListener('keydown', e => {
	if (e.key === 'Escape') closeSheet();
});

el.refresh.addEventListener('click', load);
el.restart.addEventListener('click', restart);

if (!hasBridge()) {
	showError('未检测到 KernelSU 的 WebUI 环境。请在 KernelSU 管理器里打开本页面，'
		+ '而不是用浏览器直接访问。');
	el.refresh.disabled = true;
	el.restart.disabled = true;
} else {
	load();
	/* 低频自动刷新；页面不可见时不做，省电 */
	setInterval(() => {
		if (document.visibilityState === 'visible') load();
	}, 10000);
}
