<#
.SYNOPSIS
  HDC 调试部署脚本 - 构建、推送、启动调试服务器

.DESCRIPTION
  自动化 Acode 的 HDC 调试流程：
  1. 构建 debug APK
  2. 通过 HDC 推送到手机 Download 目录
  3. 启动远程调试服务器
  4. 注入调试脚本到 www/index.html

.PARAMETER Action
  执行的动作: build | push | bp | inject | server | full (默认 full)
    bp = 仅 Gradle 构建 APK + 推送（跳过前端构建，适合只改了 Java/原生代码）

.PARAMETER Port
  调试服务器端口 (默认 8092)

.PARAMETER NoInject
  不注入调试脚本 (仅推送)

.EXAMPLE
  .\deploy.ps1                    # 完整流程
  .\deploy.ps1 -Action build      # 仅构建
  .\deploy.ps1 -Action push       # 仅推送已构建的 APK
  .\deploy.ps1 -Action bp         # Gradle 构建 + 推送（快速）
  .\deploy.ps1 -Action inject     # 仅注入调试脚本并重新构建前端
  .\deploy.ps1 -Action server     # 仅启动调试服务器
#>

param(
    [ValidateSet("build", "push", "bp", "inject", "server", "full")]
    [string]$Action = "full",

    [int]$Port = 8092,

    [switch]$NoInject
)

$ErrorActionPreference = "Stop"

# ─── 配置 ─────────────────────────────────────────────────────────────
$ProjectRoot = Resolve-Path (Join-Path $PSScriptRoot "../..")
$HdcExe = "C:\Program Files (x86)\HiSuite\hwtools\hdc.exe"
$WwwDir = Join-Path $ProjectRoot "www"
$IndexHtml = Join-Path $WwwDir "index.html"
$ApkDir = Join-Path $ProjectRoot "platforms/android/app/build/outputs/apk/debug"
$ApkPattern = Join-Path $ApkDir "*.apk"
$GradlewBat = Join-Path $ProjectRoot "platforms/android/gradlew.bat"
$ConfigXml = Join-Path $ProjectRoot "config.xml"
$DebugTag = "<!-- HDC_DEBUG -->"
$RemoteDir = "/storage/media/100/local/files/Docs/Download"

# ─── 工具函数 ─────────────────────────────────────────────────────────
function Write-Step($msg) { Write-Host "`n▶ $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "  ✓ $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "  ⚠ $msg" -ForegroundColor Yellow }
function Write-Err($msg)  { Write-Host "  ✗ $msg" -ForegroundColor Red }

# ─── 从 config.xml 读取应用名和版本号 ─────────────────────────────────
function Get-AppInfo {
    if (-not (Test-Path $ConfigXml)) {
        Write-Warn "找不到 config.xml，使用默认名称"
        return @{ Name = "app-debug"; Version = "0.0.0" }
    }
    [xml]$xml = Get-Content $ConfigXml -Encoding UTF8
    $name = $xml.widget.name
    $version = $xml.widget.version
    if ([string]::IsNullOrWhiteSpace($name)) { $name = "app-debug" }
    if ([string]::IsNullOrWhiteSpace($version)) { $version = "0.0.0" }
    return @{ Name = $name; Version = $version }
}

# ─── 自动检测并设置 JAVA_HOME / ANDROID_HOME ─────────────────────────
function Initialize-BuildEnv {
    # JAVA_HOME
    if (-not $env:JAVA_HOME -or -not (Test-Path (Join-Path $env:JAVA_HOME 'bin/javac.exe'))) {
        $jdkDirs = @(
            'C:\Program Files\Android\openjdk',
            'C:\Program Files\Java',
            'C:\Program Files\Eclipse Adoptium',
            'C:\Program Files\Microsoft\jdk*',
            "$env:USERPROFILE\.gradle\jdks"
        )
        $javac = Get-ChildItem -Path $jdkDirs -Filter javac.exe -Recurse -Depth 4 -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($javac) {
            # javac 在 bin/ 下，JAVA_HOME 是其上两级
            $env:JAVA_HOME = (Split-Path (Split-Path $javac.FullName))
            Write-Ok "自动检测 JAVA_HOME: $env:JAVA_HOME"
        } else {
            Write-Err "找不到 JDK，请安装 JDK 或设置 JAVA_HOME 环境变量"
            exit 1
        }
    } else {
        Write-Ok "JAVA_HOME: $env:JAVA_HOME"
    }

    # ANDROID_HOME
    if (-not $env:ANDROID_HOME) {
        $sdkCandidates = @(
            "$env:LOCALAPPDATA\Android\Sdk",
            'C:\Android\Sdk',
            "$env:USERPROFILE\Android\Sdk"
        )
        foreach ($sdk in $sdkCandidates) {
            if (Test-Path $sdk) {
                $env:ANDROID_HOME = $sdk
                Write-Ok "自动检测 ANDROID_HOME: $env:ANDROID_HOME"
                break
            }
        }
        if (-not $env:ANDROID_HOME) {
            Write-Err "找不到 Android SDK，请设置 ANDROID_HOME 环境变量"
            exit 1
        }
    } else {
        Write-Ok "ANDROID_HOME: $env:ANDROID_HOME"
    }
}

# ─── 重命名 APK 为 应用名-版本号.apk ─────────────────────────────────
function Rename-ApkWithVersion {
    $info = Get-AppInfo
    $targetName = "$($info.Name)-$($info.Version).apk"
    $sourceApk = Join-Path $ApkDir "app-debug.apk"
    $targetApk = Join-Path $ApkDir $targetName

    if (-not (Test-Path $sourceApk)) {
        Write-Warn "app-debug.apk 不存在，跳过重命名"
        return $null
    }

    Copy-Item $sourceApk $targetApk -Force
    $sizeMB = [math]::Round((Get-Item $targetApk).Length / 1MB, 1)
    Write-Ok "$targetName ($sizeMB MB)"
    return $targetApk
}

function Get-LanIP {
    $ip = (Get-NetIPAddress -AddressFamily IPv4 |
           Where-Object { $_.InterfaceAlias -notmatch "Loopback" -and $_.PrefixOrigin -ne "WellKnown" } |
           Select-Object -First 1).IPAddress
    if (-not $ip) { $ip = "127.0.0.1" }
    return $ip
}

function Test-Hdc {
    if (-not (Test-Path $HdcExe)) {
        # 尝试从 PATH 查找
        $found = Get-Command hdc -ErrorAction SilentlyContinue
        if ($found) {
            $script:HdcExe = $found.Source
        } else {
            Write-Err "找不到 hdc.exe，请确认华为手机助手已安装"
            Write-Err "预期路径: $HdcExe"
            exit 1
        }
    }
    $targets = & $HdcExe list targets 2>&1
    if ($targets -match "^\[Empty\]$" -or [string]::IsNullOrWhiteSpace($targets)) {
        Write-Err "未检测到 HDC 设备，请确认 USB 连接并开启开发者模式"
        exit 1
    }
    Write-Ok "HDC 设备: $($targets.Trim())"
}

# ─── 注入调试脚本 ─────────────────────────────────────────────────────
function Invoke-Inject {
    Write-Step "注入远程调试脚本到 index.html"

    $lanIP = Get-LanIP
    $debugScript = "$DebugTag<script src=`"http://${lanIP}:${Port}/__debug_client.js`"></script>"

    $html = Get-Content $IndexHtml -Raw -Encoding UTF8

    # 先移除旧的注入
    $html = $html -replace "(?m)^\s*$([regex]::Escape($DebugTag)).*$\r?\n?", ""

    # 在 <script src="cordova.js"> 之前注入
    if ($html -match '(\s*<script src="cordova\.js"></script>)') {
        $indent = "    "
        $html = $html -replace '(\s*<script src="cordova\.js"></script>)', "`n${indent}${debugScript}`n`$1"
        Set-Content $IndexHtml -Value $html -Encoding UTF8 -NoNewline
        Write-Ok "已注入: http://${lanIP}:${Port}/__debug_client.js"
    } else {
        Write-Warn "未找到 cordova.js 引用，请手动添加调试脚本"
        Write-Host "  $debugScript" -ForegroundColor DarkGray
    }
}

# ─── 移除调试脚本 ─────────────────────────────────────────────────────
function Invoke-RemoveInject {
    if (Test-Path $IndexHtml) {
        $html = Get-Content $IndexHtml -Raw -Encoding UTF8
        if ($html -match [regex]::Escape($DebugTag)) {
            $html = $html -replace "(?m)^\s*$([regex]::Escape($DebugTag)).*$\r?\n?", ""
            Set-Content $IndexHtml -Value $html -Encoding UTF8 -NoNewline
            Write-Ok "已移除调试脚本注入"
        }
    }
}

# ─── Gradle 构建 APK ──────────────────────────────────────────────────
function Invoke-GradleBuild {
    Write-Step "检测构建环境"
    Initialize-BuildEnv

    if (-not (Test-Path $GradlewBat)) {
        Write-Err "找不到 gradlew.bat: $GradlewBat"
        Write-Err "请先运行 cordova platform add android"
        exit 1
    }

    Write-Step "Gradle 构建 debug APK"
    Push-Location (Split-Path $GradlewBat)
    try {
        & $GradlewBat assembleDebug 2>&1 | ForEach-Object {
            if ($_ -match 'BUILD (SUCCESSFUL|FAILED)') {
                Write-Host "  $_" -ForegroundColor $(if ($_ -match 'SUCCESSFUL') { 'Green' } else { 'Red' })
            }
        }
        if ($LASTEXITCODE -ne 0) {
            Write-Err "Gradle 构建失败 (exit code: $LASTEXITCODE)"
            exit 1
        }
    } finally {
        Pop-Location
    }

    Write-Step "重命名 APK"
    $apk = Rename-ApkWithVersion
    if (-not $apk) {
        Write-Err "构建产物不存在"
        exit 1
    }
    return $apk
}

# ─── 完整构建（前端 + APK）────────────────────────────────────────────
function Invoke-Build {
    Write-Step "构建前端资源 (rspack)"

    Push-Location $ProjectRoot
    try {
        # 配置 (dev mode, paid)
        node ./utils/config.js d paid
        Write-Ok "配置完成"

        # rspack 构建
        npx rspack --mode development
        Write-Ok "前端构建完成"
    } finally {
        Pop-Location
    }

    # Gradle 构建 APK
    Invoke-GradleBuild
}

# ─── 推送 APK ─────────────────────────────────────────────────────────
function Invoke-Push {
    param([string]$ApkPath)

    Write-Step "通过 HDC 推送 APK 到手机"
    Test-Hdc

    # 如果未指定 APK 路径，自动查找最新的带版本号的 APK
    if (-not $ApkPath -or -not (Test-Path $ApkPath)) {
        $info = Get-AppInfo
        $versionedApk = Join-Path $ApkDir "$($info.Name)-$($info.Version).apk"
        if (Test-Path $versionedApk) {
            $ApkPath = $versionedApk
        } else {
            # 回退：取最新的 APK
            $latest = Get-ChildItem $ApkPattern -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
            if (-not $latest) {
                Write-Err "未找到 APK 文件，请先执行构建"
                exit 1
            }
            $ApkPath = $latest.FullName
        }
    }

    $apkItem = Get-Item $ApkPath
    $sizeMB = [math]::Round($apkItem.Length / 1MB, 1)
    Write-Host "  APK: $($apkItem.Name) ($sizeMB MB)" -ForegroundColor DarkGray

    $remotePath = "$RemoteDir/$($apkItem.Name)"
    Write-Host "  推送到: $remotePath" -ForegroundColor DarkGray
    & $HdcExe file send $apkItem.FullName $remotePath 2>&1 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }

    if ($LASTEXITCODE -eq 0) {
        Write-Ok "推送成功！请在手机文件管理器 → 下载 中点击安装"
    } else {
        Write-Warn "推送可能失败，尝试备选路径..."
        $altPath = "/data/local/tmp/$($apkItem.Name)"
        & $HdcExe file send $apkItem.FullName $altPath 2>&1 | ForEach-Object { Write-Host "  $_" -ForegroundColor DarkGray }
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "已推送到 $altPath"
            Write-Warn "可能需要手动复制到 Download 目录安装"
        } else {
            Write-Err "推送失败，请检查 HDC 连接和设备权限"
        }
    }
}

# ─── 启动调试服务器 ───────────────────────────────────────────────────
function Invoke-Server {
    Write-Step "启动 HDC 远程调试服务器"

    $serverScript = Join-Path $PSScriptRoot "server.mjs"
    if (-not (Test-Path $serverScript)) {
        Write-Err "找不到 server.mjs"
        exit 1
    }

    # 检查 ws 模块
    $wsPath = Join-Path $ProjectRoot "node_modules/ws"
    if (-not (Test-Path $wsPath)) {
        Write-Warn "安装 ws 依赖..."
        Push-Location $ProjectRoot
        npm install ws --save-dev
        Pop-Location
    }

    Push-Location $ProjectRoot
    try {
        node $serverScript --port $Port --watch
    } finally {
        Pop-Location
    }
}

# ─── rspack watch 模式 ───────────────────────────────────────────────
function Invoke-Watch {
    Write-Step "启动 rspack watch（配合调试服务器热重载）"

    Push-Location $ProjectRoot
    try {
        node ./utils/config.js d paid
        npx rspack --mode development --watch
    } finally {
        Pop-Location
    }
}

# ─── 主流程 ───────────────────────────────────────────────────────────
Write-Host ""
Write-Host "╔══════════════════════════════════════╗" -ForegroundColor Magenta
Write-Host "║   Acode HDC 调试部署工具             ║" -ForegroundColor Magenta
Write-Host "╚══════════════════════════════════════╝" -ForegroundColor Magenta

switch ($Action) {
    "build" {
        if (-not $NoInject) { Invoke-Inject }
        Invoke-Build
    }
    "push" {
        Test-Hdc
        Invoke-Push
    }
    "bp" {
        $apk = Invoke-GradleBuild
        Invoke-Push -ApkPath $apk
    }
    "inject" {
        Invoke-Inject
        Write-Step "重新构建前端资源"
        Push-Location $ProjectRoot
        npx rspack --mode development
        Pop-Location
        Write-Ok "注入完成，需要重新构建 APK 并推送"
    }
    "server" {
        Invoke-Server
    }
    "full" {
        if (-not $NoInject) { Invoke-Inject }
        Invoke-Build
        Invoke-Push
        # 构建完成后启动服务器
        Write-Host "`n" -NoNewline
        Write-Host "═══════════════════════════════════════" -ForegroundColor DarkGray
        Write-Host "  APK 已推送，请在手机上安装后继续" -ForegroundColor Yellow
        Write-Host "  按 Enter 启动调试服务器..." -ForegroundColor Yellow
        Write-Host "═══════════════════════════════════════" -ForegroundColor DarkGray
        Read-Host
        Invoke-Server
    }
}

# 注册退出时清理注入
$null = Register-EngineEvent PowerShell.Exiting -Action {
    Invoke-RemoveInject
}
