/**
 * HDC 调试服务器
 *
 * 功能：
 * 1. 接收来自手机端 Acode 的 console 日志（WebSocket）
 * 2. 监视 www/build/ 目录变化，通知手机端热重载
 * 3. 在浏览器提供日志查看面板（可选）
 *
 * 用法：node scripts/hdc-debug/server.mjs [--port 8092] [--watch]
 */

import { createServer } from "node:http";
import { WebSocketServer } from "ws";
import { watch, readFileSync, existsSync } from "node:fs";
import { resolve, join, extname } from "node:path";
import { networkInterfaces } from "node:os";
import { parseArgs } from "node:util";
import { execSync } from "node:child_process";

const ROOT = resolve(import.meta.dirname, "../..");
const WWW = join(ROOT, "www");

const { values: args } = parseArgs({
	options: {
		port: { type: "string", short: "p", default: "8092" },
		watch: { type: "boolean", short: "w", default: false },
	},
});

const PORT = Number.parseInt(args.port, 10);

// ─── 自动释放被占用的端口 ────────────────────────────────────────────
function killPortProcess(port) {
	try {
		if (process.platform === "win32") {
			const result = execSync(
				`(Get-NetTCPConnection -LocalPort ${port} -ErrorAction SilentlyContinue).OwningProcess`,
				{ encoding: "utf-8", shell: "powershell.exe", timeout: 5000 },
			).trim();
			const pids = [...new Set(result.split(/\r?\n/).map(s => s.trim()).filter(s => s && s !== "0"))];
			for (const pid of pids) {
				if (String(pid) !== String(process.pid)) {
					try {
						execSync(`Stop-Process -Id ${pid} -Force`, { shell: "powershell.exe", timeout: 3000 });
						console.log(`${C.yellow}[端口]${C.reset} 已终止占用端口 ${port} 的进程 (PID: ${pid})`);
					} catch {}
				}
			}
		} else {
			execSync(`lsof -ti:${port} | xargs -r kill -9`, { timeout: 3000 });
		}
	} catch {
		// 端口未被占用，忽略
	}
}

killPortProcess(PORT);

// ─── MIME types ──────────────────────────────────────────────────────
const MIME = {
	".html": "text/html",
	".js": "application/javascript",
	".mjs": "application/javascript",
	".css": "text/css",
	".json": "application/json",
	".svg": "image/svg+xml",
	".png": "image/png",
	".jpg": "image/jpeg",
	".woff": "font/woff",
	".woff2": "font/woff2",
	".ttf": "font/ttf",
	".ico": "image/x-icon",
};

// ─── Terminal colors ─────────────────────────────────────────────────
const C = {
	reset: "\x1b[0m",
	dim: "\x1b[2m",
	red: "\x1b[31m",
	yellow: "\x1b[33m",
	blue: "\x1b[34m",
	cyan: "\x1b[36m",
	green: "\x1b[32m",
	magenta: "\x1b[35m",
	white: "\x1b[37m",
};

const LEVEL_COLOR = {
	log: C.white,
	info: C.cyan,
	warn: C.yellow,
	error: C.red,
	debug: C.magenta,
};

// ─── HTTP Server (serves www/ + debug client) ────────────────────────
const httpServer = createServer((req, res) => {
	const url = new URL(req.url, `http://localhost:${PORT}`);
	let pathname = decodeURIComponent(url.pathname);

	// Debug client script (injected into app)
	if (pathname === "/__debug_client.js") {
		res.writeHead(200, { "Content-Type": "application/javascript", "Access-Control-Allow-Origin": "*" });
		res.end(generateDebugClientJS());
		return;
	}

	// Log viewer web page
	if (pathname === "/__logs") {
		res.writeHead(200, { "Content-Type": "text/html" });
		res.end(generateLogViewerHTML());
		return;
	}

	// Static file serving from www/
	if (pathname === "/") pathname = "/index.html";
	const filePath = join(WWW, pathname);

	// Prevent path traversal
	if (!filePath.startsWith(WWW)) {
		res.writeHead(403);
		res.end("Forbidden");
		return;
	}

	if (!existsSync(filePath)) {
		res.writeHead(404);
		res.end("Not Found");
		return;
	}

	const ext = extname(filePath);
	const mime = MIME[ext] || "application/octet-stream";
	const body = readFileSync(filePath);
	res.writeHead(200, {
		"Content-Type": mime,
		"Access-Control-Allow-Origin": "*",
		"Cache-Control": "no-cache",
	});
	res.end(body);
});

// ─── WebSocket Server ────────────────────────────────────────────────
const wss = new WebSocketServer({ server: httpServer });
const clients = new Set();

wss.on("connection", (ws, req) => {
	const from = req.headers["x-forwarded-for"] || req.socket.remoteAddress;
	console.log(`${C.green}[连接]${C.reset} 客户端已连接 ${C.dim}${from}${C.reset}`);
	clients.add(ws);

	ws.on("message", (raw) => {
		try {
			const msg = JSON.parse(raw.toString());
			handleMessage(msg);
		} catch {
			console.log(`${C.dim}[原始消息]${C.reset}`, raw.toString());
		}
	});

	ws.on("close", () => {
		clients.delete(ws);
		console.log(`${C.yellow}[断开]${C.reset} 客户端已断开 ${C.dim}${from}${C.reset}`);
	});
});

function broadcast(data) {
	const payload = JSON.stringify(data);
	for (const ws of clients) {
		if (ws.readyState === 1) ws.send(payload);
	}
}

function handleMessage(msg) {
	switch (msg.type) {
		case "console": {
			const color = LEVEL_COLOR[msg.level] || C.white;
			const ts = new Date(msg.timestamp).toLocaleTimeString("zh-CN");
			const prefix = `${C.dim}${ts}${C.reset} ${color}[${msg.level.toUpperCase()}]${C.reset}`;
			const args = (msg.args || [])
				.map((a) => (typeof a === "string" ? a : JSON.stringify(a, null, 2)))
				.join(" ");
			console.log(`${prefix} ${args}`);
			break;
		}
		case "error": {
			const ts = new Date(msg.timestamp).toLocaleTimeString("zh-CN");
			console.log(
				`${C.dim}${ts}${C.reset} ${C.red}[未捕获错误]${C.reset} ${msg.message}`,
			);
			if (msg.stack) console.log(`${C.dim}${msg.stack}${C.reset}`);
			break;
		}
		case "ping":
			// keep alive
			break;
		default:
			console.log(`${C.dim}[未知消息]${C.reset}`, JSON.stringify(msg));
	}
}

// ─── File Watcher ────────────────────────────────────────────────────
if (args.watch) {
	const buildDir = join(WWW, "build");
	let debounceTimer = null;

	console.log(`${C.blue}[监视]${C.reset} 正在监视 www/build/ 的变化...`);

	if (existsSync(buildDir)) {
		watch(buildDir, { recursive: true }, (_event, filename) => {
			if (debounceTimer) clearTimeout(debounceTimer);
			debounceTimer = setTimeout(() => {
				console.log(
					`${C.blue}[热重载]${C.reset} 检测到变化: ${C.dim}${filename}${C.reset}，通知客户端刷新...`,
				);
				broadcast({ type: "reload", file: filename });
			}, 500);
		});
	} else {
		console.log(`${C.yellow}[警告]${C.reset} www/build/ 不存在，跳过监视`);
	}
}

// ─── Start ───────────────────────────────────────────────────────────
httpServer.listen(PORT, "0.0.0.0", () => {
	const lanIP = getLanIP();
	console.log("");
	console.log(`${C.green}╔══════════════════════════════════════════════╗${C.reset}`);
	console.log(`${C.green}║${C.reset}     HDC 远程调试服务器已启动                ${C.green}║${C.reset}`);
	console.log(`${C.green}╠══════════════════════════════════════════════╣${C.reset}`);
	console.log(`${C.green}║${C.reset} 局域网地址: ${C.cyan}http://${lanIP}:${PORT}${C.reset}          ${C.green}║${C.reset}`);
	console.log(`${C.green}║${C.reset} 日志面板:   ${C.cyan}http://${lanIP}:${PORT}/__logs${C.reset}   ${C.green}║${C.reset}`);
	console.log(`${C.green}║${C.reset} 监视模式:   ${args.watch ? `${C.green}已开启` : `${C.dim}未开启`}${C.reset}                        ${C.green}║${C.reset}`);
	console.log(`${C.green}╚══════════════════════════════════════════════╝${C.reset}`);
	console.log("");
	console.log(`${C.dim}提示: 确保手机和电脑在同一局域网${C.reset}`);
	console.log(`${C.dim}在 www/index.html 的 <head> 中加入:${C.reset}`);
	console.log(`${C.cyan}<script src="http://${lanIP}:${PORT}/__debug_client.js"><\/script>${C.reset}`);
	console.log("");
});

// ─── Helpers ─────────────────────────────────────────────────────────
function getLanIP() {
	const nets = networkInterfaces();
	for (const name of Object.keys(nets)) {
		for (const net of nets[name]) {
			if (net.family === "IPv4" && !net.internal) {
				return net.address;
			}
		}
	}
	return "127.0.0.1";
}

function generateDebugClientJS() {
	const lanIP = getLanIP();
	return `
// ── Acode HDC Remote Debug Client ──
(function() {
  if (window.__HDC_DEBUG_ACTIVE) return;
  window.__HDC_DEBUG_ACTIVE = true;

  var WS_URL = "ws://${lanIP}:${PORT}";
  var ws = null;
  var queue = [];
  var reconnectTimer = null;

  function connect() {
    try {
      ws = new WebSocket(WS_URL);
    } catch(e) { return; }

    ws.onopen = function() {
      while (queue.length) ws.send(queue.shift());
    };
    ws.onclose = function() {
      ws = null;
      if (!reconnectTimer) reconnectTimer = setTimeout(function() {
        reconnectTimer = null;
        connect();
      }, 3000);
    };
    ws.onerror = function() {};

    ws.onmessage = function(evt) {
      try {
        var msg = JSON.parse(evt.data);
        if (msg.type === "reload") {
          location.reload();
        } else if (msg.type === "eval") {
          try { eval(msg.code); } catch(e) { send({ type: "error", message: e.message, stack: e.stack }); }
        }
      } catch(e) {}
    };
  }

  function send(obj) {
    var data = JSON.stringify(obj);
    if (ws && ws.readyState === 1) {
      ws.send(data);
    } else {
      if (queue.length < 200) queue.push(data);
    }
  }

  // 劫持 console 方法
  var _console = {};
  ["log", "info", "warn", "error", "debug"].forEach(function(level) {
    _console[level] = console[level];
    console[level] = function() {
      _console[level].apply(console, arguments);
      var args = [];
      for (var i = 0; i < arguments.length; i++) {
        try {
          var v = arguments[i];
          if (v instanceof Error) {
            args.push({ message: v.message, stack: v.stack });
          } else if (typeof v === "object") {
            args.push(JSON.parse(JSON.stringify(v, function(k, val) {
              if (typeof val === "function") return "[Function]";
              if (val instanceof HTMLElement) return val.outerHTML.substring(0, 200);
              return val;
            })));
          } else {
            args.push(v);
          }
        } catch(e) {
          args.push("[无法序列化]");
        }
      }
      send({ type: "console", level: level, args: args, timestamp: Date.now() });
    };
  });

  // 捕获未处理错误
  window.addEventListener("error", function(e) {
    send({ type: "error", message: e.message, filename: e.filename, lineno: e.lineno, colno: e.colno, timestamp: Date.now() });
  });

  window.addEventListener("unhandledrejection", function(e) {
    send({ type: "error", message: "UnhandledRejection: " + (e.reason && e.reason.message || e.reason), stack: e.reason && e.reason.stack, timestamp: Date.now() });
  });

  // 心跳
  setInterval(function() { send({ type: "ping" }); }, 30000);

  connect();
})();
`;
}

function generateLogViewerHTML() {
	const lanIP = getLanIP();
	return `<!DOCTYPE html>
<html><head>
<meta charset="utf-8"><title>HDC Debug Logs</title>
<style>
  * { margin:0; padding:0; box-sizing:border-box; }
  body { font-family: 'Cascadia Code', 'Consolas', monospace; font-size: 13px; background:#1e1e2e; color:#cdd6f4; }
  #toolbar { position:fixed; top:0; left:0; right:0; height:40px; background:#181825; display:flex; align-items:center; padding:0 12px; gap:8px; z-index:10; border-bottom:1px solid #313244; }
  #toolbar button { background:#313244; color:#cdd6f4; border:none; padding:4px 12px; border-radius:4px; cursor:pointer; font-size:12px; }
  #toolbar button:hover { background:#45475a; }
  #filter { background:#313244; color:#cdd6f4; border:1px solid #45475a; padding:4px 8px; border-radius:4px; flex:1; max-width:300px; font-size:12px; }
  #logs { padding:48px 12px 12px; }
  .entry { padding:3px 0; border-bottom:1px solid #21212e; white-space:pre-wrap; word-break:break-all; }
  .entry .time { color:#6c7086; margin-right:8px; }
  .entry.log .level { color:#a6adc8; }
  .entry.info .level { color:#89b4fa; }
  .entry.warn .level { color:#f9e2af; } .entry.warn { background:#f9e2af08; }
  .entry.error .level { color:#f38ba8; } .entry.error { background:#f38ba808; }
  .entry.debug .level { color:#cba6f7; }
  .count { background:#45475a; color:#cdd6f4; border-radius:8px; padding:0 6px; font-size:11px; margin-left:4px; }
</style></head><body>
<div id="toolbar">
  <strong style="color:#89b4fa">HDC Debug</strong>
  <input id="filter" placeholder="过滤日志...">
  <button onclick="document.getElementById('logs').innerHTML=''">清空</button>
  <span id="status" style="color:#a6e3a1">●</span>
  <span class="count" id="cnt">0</span>
</div>
<div id="logs"></div>
<script>
var logs=document.getElementById('logs'), cnt=document.getElementById('cnt'), status=document.getElementById('status'), filter=document.getElementById('filter');
var n=0;
var ws=new WebSocket("ws://"+location.host);
ws.onopen=function(){status.style.color='#a6e3a1';};
ws.onclose=function(){status.style.color='#f38ba8';setTimeout(function(){location.reload();},3000);};
ws.onmessage=function(e){
  try{
    var m=JSON.parse(e.data); if(m.type==='console'||m.type==='error'){
      var level=m.level||'error';
      var text=(m.args||[m.message]).map(function(a){return typeof a==='string'?a:JSON.stringify(a,null,2)}).join(' ');
      if(m.stack) text+='\\n'+m.stack;
      var f=filter.value;
      var div=document.createElement('div');
      div.className='entry '+level;
      div.innerHTML='<span class="time">'+(new Date(m.timestamp)).toLocaleTimeString()+'</span><span class="level">['+level.toUpperCase()+']</span> '+escapeHtml(text);
      if(f&&text.toLowerCase().indexOf(f.toLowerCase())===-1) div.style.display='none';
      logs.appendChild(div);
      n++;cnt.textContent=n;
      if(n>2000){logs.removeChild(logs.firstChild);n--;}
      logs.scrollTop=logs.scrollHeight;
    }
  }catch(ex){}
};
filter.oninput=function(){
  var f=filter.value.toLowerCase();
  var entries=logs.getElementsByClassName('entry');
  for(var i=0;i<entries.length;i++){entries[i].style.display=(!f||entries[i].textContent.toLowerCase().indexOf(f)!==-1)?'':'none';}
};
function escapeHtml(t){var d=document.createElement('div');d.textContent=t;return d.innerHTML;}
</script></body></html>`;
}
