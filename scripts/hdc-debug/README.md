# Acode HDC 调试方案

## 背景

设备：华为 HarmonyOS NEXT（ALN-AL10），使用 HDC 而非 ADB。  
限制：HDC `install` 仅支持 `.hap`/`.hsp`，不支持 `.apk`；无法通过 HDC 直接调试 Android 应用。

## 架构概览

```
┌─────────────────────┐        LAN (WebSocket)       ┌──────────────────┐
│   PC (开发机)         │◄──────────────────────────────│   手机 (Acode)    │
│                     │                               │                  │
│  rspack --watch     │   文件变化 → WS reload 通知    │  debug-client.js │
│  server.mjs         │◄── console.log/error ─────────│  (注入到 HTML)    │
│  (日志 + 热重载)     │                               │                  │
└─────────────────────┘                               └──────────────────┘
        │ HDC USB                                            ▲
        └── file send ──► APK 推送到 Download ──► 手动安装 ──┘
```

## 文件说明

| 文件 | 用途 |
|------|------|
| `scripts/hdc-debug/server.mjs` | Node.js 调试服务器 — 接收日志、热重载通知、静态文件服务 |
| `scripts/hdc-debug/deploy.ps1` | PowerShell 自动化脚本 — 构建、注入、推送、启动服务器 |

## 快速开始

### 前提条件

1. 电脑和手机在**同一局域网**（WiFi）
2. HDC 已安装（华为手机助手自带，位于 `C:\Program Files (x86)\HiSuite\hwtools\hdc.exe`）
3. 手机通过 USB 连接并开启开发者模式
4. 项目已完成 `npm install` 和 Cordova 平台添加

### 安装 WebSocket 依赖

```powershell
npm install ws --save-dev
```

### 方式一：完整流程（一键）

```powershell
# 构建 + 注入调试脚本 + 推送 APK + 启动调试服务器
.\scripts\hdc-debug\deploy.ps1
```

### 方式二：分步操作

```powershell
# 1. 注入调试脚本到 www/index.html
.\scripts\hdc-debug\deploy.ps1 -Action inject

# 2. 构建 APK
.\scripts\hdc-debug\deploy.ps1 -Action build

# 3. 推送到手机（需 USB 连接）
.\scripts\hdc-debug\deploy.ps1 -Action push

# 4. 在手机上点击文件管理器 → 下载 → 安装 APK

# 5. 启动调试服务器
.\scripts\hdc-debug\deploy.ps1 -Action server
```

### 方式三：开发迭代模式（推荐日常使用）

首次部署完 APK 后，后续修改前端代码可以快速迭代：

**终端 1** — rspack 监视 + 调试服务器：
```powershell
# 启动调试服务器（带文件监视）
node scripts/hdc-debug/server.mjs --port 8092 --watch
```

**终端 2** — rspack watch：
```powershell
node ./utils/config.js d paid
npx rspack --mode development --watch
```

当代码变化时：
1. rspack 自动重新构建 `www/build/`
2. server.mjs 检测到文件变化，通过 WebSocket 通知手机端
3. 手机端 Acode 自动刷新页面

> **注意**：此模式要求 Acode 加载的 `www/` 是本地文件（APK 内打包的），所以 WebView 内容刷新后仍然是旧版本。
> 要实现真正的热重载，需要让 APK 从局域网服务器加载资源（见下方"高级：网络加载模式"）。

## 日志查看

### 终端日志
启动 server.mjs 后，所有手机端的 `console.log/warn/error` 会实时显示在终端中。

### 浏览器日志面板
访问 `http://<你的IP>:8092/__logs` 查看可过滤的日志面板。

### HDC hilog（补充）
```powershell
# 查看设备全局日志（HarmonyOS 系统日志）
& "C:\Program Files (x86)\HiSuite\hwtools\hdc.exe" hilog
```

## 手动注入调试脚本

如果不使用 deploy.ps1，可以手动在 `www/index.html` 的 `<head>` 中 cordova.js 之前添加：

```html
<script src="http://192.168.x.x:8092/__debug_client.js"></script>
```

将 `192.168.x.x` 替换为你电脑的局域网 IP。

## 高级：网络加载模式

让 Cordova WebView 从局域网加载资源，实现真正的热重载（无需每次重建 APK）：

1. 修改 `config.xml` 中的 `<content>` 标签：

```xml
<!-- 开发时改为网络地址 -->
<content src="http://192.168.x.x:8092/index.html" />

<!-- 正式发布时改回 -->
<content src="index.html" />
```

2. 重新构建并安装 APK（仅需一次）
3. 之后修改代码 → rspack 重建 → 在 Acode 中刷新即可

> ⚠ 网络加载模式下 `cordova.js` 和插件 API 可能无法正常工作（因为它们依赖本地文件）。
> 建议仅在调试纯前端逻辑时使用。需要调试 Cordova 插件时请走完整 APK 构建流程。

## HDC 常用命令速查

```powershell
$hdc = "C:\Program Files (x86)\HiSuite\hwtools\hdc.exe"

# 列出设备
& $hdc list targets

# 推送文件到手机
& $hdc file send .\local-file.apk /storage/media/100/local/files/Download/app.apk

# 从手机拉取文件
& $hdc file recv /remote/path .\local-path

# 端口转发（设备端口 → PC端口）
& $hdc fport tcp:9222 tcp:9222

# 反向端口转发（PC端口 → 设备可访问）
& $hdc rport tcp:8092 tcp:8092

# 设备 shell
& $hdc shell

# 查看设备日志
& $hdc hilog
```

## 故障排查

| 问题 | 解决方案 |
|------|----------|
| 手机日志未显示 | 检查手机和电脑是否在同一 WiFi；检查防火墙是否放行端口 |
| APK 推送失败 | 确认 HDC 设备已连接（`hdc list targets`）|
| 推送后找不到 APK | 尝试在文件管理器搜索文件名，或检查 `/data/local/tmp/` |
| WebSocket 连接失败 | Windows 防火墙可能阻止了入站连接，添加 Node.js 的防火墙例外 |
| 调试脚本未加载 | 确认 `www/index.html` 中有 debug script 标签且 IP 正确 |
