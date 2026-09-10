/*
 * kernelsu.js —— KernelSU WebUI 桥的极薄封装
 *
 * 官方把同样的东西发布成了 npm 包 kernelsu，但模块里不该为此引入一套
 * 前端打包工具链，所以这里只保留真正用得到的几个函数。
 *
 * 底层桥的签名（这个猜不得，写错了整个页面就是死的）：
 *
 *     ksu.exec(command, optionsJson, callbackName)
 *         -> 执行结束后调用 window[callbackName](errno, stdout, stderr)
 *
 * 也就是说：命令的返回值不是通过 return 或事件回来的，而是 KernelSU
 * 反过来调用一个挂在 window 上的全局函数。回调名必须唯一，用完要删掉，
 * 否则多次调用会互相覆盖。
 *
 * 这与官方实现语义一致，只是去掉了 spawn / listPackages 等本项目用不到的接口。
 */

let seq = 0;

export function hasBridge() {
	return typeof window.ksu !== 'undefined' && window.ksu !== null;
}

export function exec(command, options) {
	return new Promise((resolve, reject) => {
		if (!hasBridge()) {
			reject(new Error('未检测到 KernelSU 的 WebUI 环境'));
			return;
		}

		const cb = `__ksu_exec_${Date.now()}_${seq++}`;

		window[cb] = (errno, stdout, stderr) => {
			delete window[cb];
			resolve({ errno, stdout, stderr });
		};

		try {
			window.ksu.exec(command, JSON.stringify(options || {}), cb);
		} catch (e) {
			delete window[cb];
			reject(e);
		}
	});
}

export function toast(message) {
	if (hasBridge() && typeof window.ksu.toast === 'function') {
		window.ksu.toast(String(message));
	}
}
