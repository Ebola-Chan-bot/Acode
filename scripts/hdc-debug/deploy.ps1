<#
.SYNOPSIS
  HDC 调试部署脚本 - 构建、推送、启动调试服务器

.DESCRIPTION
  自动化 Acode 的 HDC 调试流程：
  1. 构建 debug APK
  2. 通过 HDC 推送到手机 Download 目录
  3. 启动远程调试服务器
  4. 注入调试脚本到 www/index.html 和平台 index.html

.PARAMETER Action
    执行的动作: build | push | bp | inject | server | logs | rport | full (默认 full)
    bp = 同步前端 + 注入 + Gradle 构建 APK + 推送（跳过 rspack，适合只改了 Java/原生代码）
    rport = 仅设置 HDC 反向端口转发

.PARAMETER Port
  调试服务器端口 (默认 8092)

.PARAMETER DebugHost
    调试脚本注入使用的主机 IP（可选，不填则自动选择局域网 IP）

.PARAMETER NoInject
  不注入调试脚本 (仅推送)

.PARAMETER UseRport
  使用 HDC 反向端口转发（USB 隧道模式），适用于局域网不通的场景（如卓易通）
  此模式下注入 127.0.0.1 替代局域网 IP，通过 USB 建立端口隧道

.EXAMPLE
  .\deploy.ps1                            # 完整流程（局域网模式）
  .\deploy.ps1 -UseRport                  # 完整流程（USB 隧道模式）
  .\deploy.ps1 -Action build              # 仅构建
  .\deploy.ps1 -Action push               # 仅推送已构建的 APK
  .\deploy.ps1 -Action bp                 # 同步 + 注入 + Gradle 构建 + 推送
  .\deploy.ps1 -Action bp -UseRport       # 同上，但使用 USB 隧道
  .\deploy.ps1 -Action inject             # 仅注入调试脚本并重新构建前端
  .\deploy.ps1 -Action server -UseRport   # 启动调试服务器（带 rport）
  .\deploy.ps1 -Action rport              # 仅设置 HDC 反向端口转发
  .\deploy.ps1 -Action logs               # 抓取设备 hilog 日志
#>

param(
    [ValidateSet("build", "push", "bp", "inject", "server", "logs", "rport", "full")]
    [string]$Action = "full",

    [int]$Port = 8092,

    [string]$DebugHost = "",

    [switch]$NoInject,

    [switch]$UseRport
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
$PlatformAssetsDir = Join-Path $ProjectRoot "platforms/android/app/src/main/assets/www"
$PlatformIndexHtml = Join-Path $PlatformAssetsDir "index.html"
$PlatformConfigXml = Join-Path $ProjectRoot "platforms/android/app/src/main/res/xml/config.xml"
$DebugSchemeTag = '<!-- HDC_SCHEME -->'

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
            "C:\Program Files (x86)\Android\android-sdk",
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
    if ($UseRport) {
        Write-Ok "使用 HDC rport 隧道模式: 127.0.0.1"
        return "127.0.0.1"
    }

    if (-not [string]::IsNullOrWhiteSpace($DebugHost)) {
        Write-Ok "使用指定调试地址: $DebugHost"
        return $DebugHost
    }

    $candidates = Get-NetIPAddress -AddressFamily IPv4 | Where-Object {
        $_.PrefixOrigin -ne "WellKnown" -and
        $_.IPAddress -notmatch '^169\.254\.' -and
        $_.InterfaceAlias -notmatch 'Loopback|vEthernet|Hyper-V|WSL|VirtualBox|VMware|isatap|Teredo|Bluetooth'
    }

    $private = $candidates | Where-Object {
        $_.IPAddress -match '^192\.168\.' -or
        $_.IPAddress -match '^10\.' -or
        $_.IPAddress -match '^172\.(1[6-9]|2[0-9]|3[0-1])\.'
    }

    $best = $private | Select-Object -First 1
    if (-not $best) {
        $best = $candidates | Select-Object -First 1
    }

    if ($best) {
        Write-Ok "自动选择调试地址: $($best.IPAddress) ($($best.InterfaceAlias))"
        return $best.IPAddress
    }

    Write-Warn "未找到可用局域网地址，回退到 127.0.0.1"
    return "127.0.0.1"
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
function Get-InlineDebugScript {
    param([string]$LanIP)

    # 生成内联调试脚本，尝试多个地址连接
    $addresses = @()
    if ($UseRport) {
        $addresses += "127.0.0.1"
    }
    if ($LanIP -ne "127.0.0.1") {
        $addresses += $LanIP
    }
    if ($addresses.Count -eq 0) {
        $addresses += "127.0.0.1"
    }

    $wsUrls = ($addresses | ForEach-Object { """ws://$($_):${Port}""" }) -join ","
    $httpUrls = ($addresses | ForEach-Object { """http://$($_):${Port}/__debug_client.js""" }) -join ","

    $inlineJS = @"
(function(){
  if(window.__HDC_DEBUG_ACTIVE)return;
  window.__HDC_DEBUG_ACTIVE=true;
  window.__debugHost='$($LanIP):${Port}';

  /* ── 诊断浮层 ── */
  var D=document.createElement('div');
  D.id='__hdc_diag';
  D.style.cssText='position:fixed;top:0;left:0;right:0;z-index:999999;background:rgba(0,0,0,0.85);color:#0f0;font:11px/1.4 monospace;padding:6px 8px;max-height:35vh;overflow-y:auto;pointer-events:none;white-space:pre-wrap';
  var diagLines=[];
  function diag(msg){
    var t=new Date();
    var ts=('0'+t.getHours()).slice(-2)+':'+('0'+t.getMinutes()).slice(-2)+':'+('0'+t.getSeconds()).slice(-2)+'.'+('00'+t.getMilliseconds()).slice(-3);
    diagLines.push(ts+' '+msg);
    if(diagLines.length>30)diagLines.shift();
    D.textContent=diagLines.join('\n');
    if(!D.parentNode){try{document.body.appendChild(D)}catch(e){}}
  }
  /* 5秒后自动隐藏诊断浮层（如果WS连上了） */
  var diagHideTimer=setTimeout(function(){D.style.display='none'},15000);

  diag('HDC Debug init, URLs: $wsUrls');
  diag('UA: '+navigator.userAgent.substring(0,80));

  /* ── HTTP 探测 ── */
  var httpUrls=[$httpUrls];
  httpUrls.forEach(function(url){
    diag('HTTP probe: '+url);
    var xhr=new XMLHttpRequest();
    xhr.timeout=5000;
    xhr.open('GET',url,true);
    xhr.onload=function(){diag('HTTP OK: '+url+' status='+xhr.status+' len='+xhr.responseText.length)};
    xhr.onerror=function(){diag('HTTP FAIL: '+url)};
    xhr.ontimeout=function(){diag('HTTP TIMEOUT: '+url)};
    try{xhr.send()}catch(e){diag('HTTP EXCEPTION: '+url+' '+e.message)}
  });

  /* ── WebSocket 多地址连接 ── */
  var URLS=[$wsUrls];
  var ws=null,queue=[],urlIdx=0,retryCount=0,maxRetry=50;
  function connect(){
    if(retryCount>=maxRetry){diag('WS: max retries reached, giving up');return}
    var url=URLS[urlIdx%URLS.length];
    diag('WS try #'+retryCount+': '+url);
    try{ws=new WebSocket(url)}catch(e){diag('WS constructor error: '+e.message);tryNext();return}
    ws.onopen=function(){
      diag('WS CONNECTED: '+url);
      retryCount=0;
      clearTimeout(diagHideTimer);
      diagHideTimer=setTimeout(function(){D.style.display='none'},3000);
      while(queue.length&&ws.readyState===1)ws.send(queue.shift());
    };
    ws.onclose=function(ev){diag('WS closed: code='+ev.code+' reason='+ev.reason);var info='WS closed: code='+ev.code+' reason='+ev.reason+' wasClean='+ev.wasClean;ws=null;tryNext();setTimeout(function(){if(_c&&_c.warn)_c.warn('[HDC]',info)},0)};
    ws.onerror=function(){diag('WS error on '+url)};
    ws.onmessage=function(evt){try{var m=JSON.parse(evt.data);if(m.type==="reload")location.reload();if(m.type==="eval")try{eval(m.code)}catch(e){send({type:"error",message:e.message,stack:e.stack})}}catch(e){}};
  }
  function tryNext(){urlIdx++;retryCount++;setTimeout(connect,2000)}
  function send(obj){var d=JSON.stringify(obj);if(ws&&ws.readyState===1)ws.send(d);else if(queue.length<200)queue.push(d)}

  /* ── 前台恢复时立即重连 ── */
  document.addEventListener('visibilitychange',function(){
    if(!document.hidden&&(!ws||ws.readyState!==1)){
      diag('Visibility restored, reconnecting...');
      retryCount=0;urlIdx=0;connect();
    }
  });
  document.addEventListener('resume',function(){
    if(!ws||ws.readyState!==1){
      diag('App resumed, reconnecting...');
      retryCount=0;urlIdx=0;connect();
    }
  });

  /* ── Console 劫持 ── */
  var _c={};
  ["log","info","warn","error","debug"].forEach(function(l){
    _c[l]=console[l];
    console[l]=function(){
      _c[l].apply(console,arguments);
      var a=[];for(var i=0;i<arguments.length;i++){try{var v=arguments[i];if(v instanceof Error)a.push({message:v.message,stack:v.stack});else if(typeof v==="object")a.push(JSON.parse(JSON.stringify(v,function(k,val){if(typeof val==="function")return"[Function]";if(val instanceof HTMLElement)return val.outerHTML.substring(0,200);return val})));else a.push(v)}catch(e){a.push("[unserializable]")}}
      if(l==="error"&&a.length===1&&typeof a[0]==="number")a.push(new Error().stack);
      send({type:"console",level:l,args:a,timestamp:Date.now()});
    };
  });

  /* ── 错误捕获 ── */
  window.addEventListener("error",function(e){
    diag('JS ERROR: '+e.message+' @'+e.filename+':'+e.lineno);
    send({type:"error",message:e.message,filename:e.filename,lineno:e.lineno,colno:e.colno,timestamp:Date.now()});
  });
  window.addEventListener("unhandledrejection",function(e){
    diag('UNHANDLED: '+(e.reason&&e.reason.message||e.reason));
    send({type:"error",message:"UnhandledRejection: "+(e.reason&&e.reason.message||e.reason),stack:e.reason&&e.reason.stack,timestamp:Date.now()});
  });

  setInterval(function(){send({type:"ping"})},10000);
  connect();
})();
"@

    return "${DebugTag}<script>$inlineJS</script>"
}

function Invoke-InjectFile([string]$FilePath, [string]$DebugScript) {
    if (-not (Test-Path $FilePath)) {
        Write-Warn "文件不存在，跳过注入: $FilePath"
        return
    }
    $html = Get-Content $FilePath -Raw -Encoding UTF8

    # 移除旧的注入（外部脚本和内联脚本两种格式都清除）
    $html = $html -replace "(?ms)^\s*$([regex]::Escape($DebugTag)).*?</script>\s*$\r?\n?", ""

    # 在 <script src="cordova.js"> 之前注入
    if ($html -match '(\s*<script src="cordova\.js"></script>)') {
        $indent = "    "
        $html = $html -replace '(\s*<script src="cordova\.js"></script>)', "`n${indent}${DebugScript}`n`$1"
        Set-Content $FilePath -Value $html -Encoding UTF8 -NoNewline
        Write-Ok "已注入到: $FilePath"
    } else {
        Write-Warn "未找到 cordova.js 引用: $FilePath"
    }
}

function Invoke-Inject {
    Write-Step "注入远程调试脚本（内联模式）"

    # 获取真实 LAN IP（不受 UseRport 影响，用于多地址回退）
    $realLanIP = if (-not [string]::IsNullOrWhiteSpace($DebugHost)) { $DebugHost } else {
        $cands = Get-NetIPAddress -AddressFamily IPv4 | Where-Object {
            $_.PrefixOrigin -ne "WellKnown" -and
            $_.IPAddress -notmatch '^169\.254\.' -and
            $_.InterfaceAlias -notmatch 'Loopback|vEthernet|Hyper-V|WSL|VirtualBox|VMware|isatap|Teredo|Bluetooth'
        }
        $priv = $cands | Where-Object { $_.IPAddress -match '^192\.168\.|^10\.|^172\.(1[6-9]|2[0-9]|3[0-1])\.' }
        $best = ($priv | Select-Object -First 1)
        if ($best) { $best.IPAddress } else { "127.0.0.1" }
    }

    Write-Ok "LAN IP: $realLanIP | UseRport: $UseRport"
    $debugScript = Get-InlineDebugScript -LanIP $realLanIP

    # 注入到源 index.html
    Invoke-InjectFile -FilePath $IndexHtml -DebugScript $debugScript

    # 同时注入到平台 index.html（如果存在）
    Invoke-InjectFile -FilePath $PlatformIndexHtml -DebugScript $debugScript

    # 临时将 Cordova scheme 改为 http（解决 https secure context 阻止 ws:// 的问题）
    Invoke-SetHttpScheme
}

function Invoke-SetHttpScheme {
    if (-not (Test-Path $PlatformConfigXml)) {
        Write-Warn "平台 config.xml 不存在，跳过 scheme 修改"
        return
    }
    $xml = Get-Content $PlatformConfigXml -Raw -Encoding UTF8
    # 移除旧的 scheme 注入
    $xml = $xml -replace '(?m)^\s*<preference name="Scheme" value="http" />\s*\r?\n?', ''
    # 在 </widget> 前加入
    if ($xml -match '</widget>') {
        $xml = $xml -replace '</widget>', "    <preference name=`"Scheme`" value=`"http`" />`n</widget>"
        Set-Content $PlatformConfigXml -Value $xml -Encoding UTF8 -NoNewline
        Write-Ok "已设置 Cordova Scheme=http（允许 ws:// 连接）"
    }
}

function Invoke-RestoreHttpsScheme {
    if (-not (Test-Path $PlatformConfigXml)) { return }
    $xml = Get-Content $PlatformConfigXml -Raw -Encoding UTF8
    if ($xml -match '<preference name="Scheme" value="http"') {
        $xml = $xml -replace '(?m)^\s*<preference name="Scheme" value="http" />\s*\r?\n?', ''
        Set-Content $PlatformConfigXml -Value $xml -Encoding UTF8 -NoNewline
        Write-Ok "已恢复 Cordova Scheme=https"
    }
}

# ─── 移除调试脚本 ─────────────────────────────────────────────────────
function Invoke-RemoveInjectFile([string]$FilePath) {
    if (Test-Path $FilePath) {
        $html = Get-Content $FilePath -Raw -Encoding UTF8
        if ($html -match [regex]::Escape($DebugTag)) {
            # 移除外部脚本和内联脚本两种格式
            $html = $html -replace "(?ms)^\s*$([regex]::Escape($DebugTag)).*?</script>\s*$\r?\n?", ""
            Set-Content $FilePath -Value $html -Encoding UTF8 -NoNewline
            Write-Ok "已移除调试脚本: $FilePath"
        }
    }
}

function Invoke-RemoveInject {
    Invoke-RemoveInjectFile -FilePath $IndexHtml
    Invoke-RemoveInjectFile -FilePath $PlatformIndexHtml
    Invoke-RestoreHttpsScheme
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
        $prevEAP = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        & $GradlewBat assembleDebug 2>&1 | ForEach-Object {
            if ($_ -match 'BUILD (SUCCESSFUL|FAILED)') {
                Write-Host "  $_" -ForegroundColor $(if ($_ -match 'SUCCESSFUL') { 'Green' } else { 'Red' })
            }
        }
        $ErrorActionPreference = $prevEAP
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

    # 同步 www/build 到平台目录
    Invoke-SyncWwwBuild

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

# ─── 同步插件脚本/资源到平台目录 ──────────────────────────────────────
function Invoke-SyncPluginAssets {
    $PlatformAssets = Join-Path $ProjectRoot "platforms/android/app/src/main/assets"
    $PlatformJavaRoot = Join-Path $ProjectRoot "platforms/android/app/src/main/java"

    if (-not (Test-Path $PlatformAssets)) {
        Write-Warn "平台 assets 目录不存在，跳过插件同步"
        return
    }

    Write-Step "同步插件资源到平台目录"

    # ── 1. Shell 脚本 → assets 根目录 ──
    $shellScripts = @(
        @{ Src = "src/plugins/terminal/scripts/init-alpine.sh";   Dst = "init-alpine.sh" },
        @{ Src = "src/plugins/terminal/scripts/init-sandbox.sh";  Dst = "init-sandbox.sh" },
        @{ Src = "src/plugins/terminal/scripts/rm-wrapper.sh";    Dst = "rm-wrapper.sh" }
    )

    foreach ($item in $shellScripts) {
        $src = Join-Path $ProjectRoot $item.Src
        $dst = Join-Path $PlatformAssets $item.Dst
        if (Test-Path $src) {
            Copy-Item $src $dst -Force
            Write-Ok "$($item.Src) → assets/$($item.Dst)"
        } else {
            Write-Warn "源文件不存在: $($item.Src)"
        }
    }

    # ── 2. 二进制 assets──
    $binaryAssets = @(
        @{ Src = "../acodex_server/target/aarch64-linux-android/release/axs"; Dst = "axs" }
    )
    foreach ($item in $binaryAssets) {
        $src = Join-Path $ProjectRoot $item.Src
        $dst = Join-Path $PlatformAssets $item.Dst
        if (Test-Path $src) {
            Copy-Item $src $dst -Force
            Write-Ok "$($item.Src) → assets/$($item.Dst)"
        } else {
            Write-Warn "源文件不存在: $($item.Src)"
        }
    }

    # ── 3. JS 插件（自动读取 cordova_plugins.js 的 moduleId，cordova.define 包装）──
    $cordovaPluginsJs = Join-Path $PlatformAssets "www/cordova_plugins.js"
    $moduleIdMap = @{}  # "plugins/xxx/www/file.js" → moduleId
    if (Test-Path $cordovaPluginsJs) {
        $cpContent = Get-Content $cordovaPluginsJs -Raw -Encoding UTF8
        $idMatches = [regex]::Matches($cpContent, '"id":\s*"([^"]+)"[^}]*?"file":\s*"([^"]+)"')
        foreach ($m in $idMatches) {
            $moduleIdMap[$m.Groups[2].Value] = $m.Groups[1].Value
        }
    }

    # src/plugins 目录名 → 平台 cordova pluginId
    $pluginDirToId = @{
        "terminal"                 = "com.foxdebug.acode.rk.exec.terminal"
        "system"                   = "cordova-plugin-system"
        "custom-tabs"              = "com.foxdebug.acode.rk.customtabs"
        "pluginContext"            = "com.foxdebug.acode.rk.plugin.plugincontext"
        "cordova-plugin-buildinfo" = "cordova-plugin-buildinfo"
        "ftp"                      = "cordova-plugin-ftp"
        "iap"                      = "cordova-plugin-iap"
        "sdcard"                   = "cordova-plugin-sdcard"
        "server"                   = "cordova-plugin-server"
        "sftp"                     = "cordova-plugin-sftp"
        "websocket"                = "cordova-plugin-websocket"
    }

    $jsCount = 0
    foreach ($dir in $pluginDirToId.Keys) {
        $pluginId = $pluginDirToId[$dir]
        $srcWww = Join-Path $ProjectRoot "src/plugins/$dir/www"
        if (-not (Test-Path $srcWww)) { continue }

        Get-ChildItem $srcWww -Filter "*.js" | ForEach-Object {
            $jsFile = $_
            $platformRelPath = "plugins/$pluginId/www/$($jsFile.Name)"
            $dst = Join-Path $PlatformAssets "www/$platformRelPath"

            $moduleId = $moduleIdMap[$platformRelPath]
            if (-not $moduleId) {
                Write-Warn "找不到 moduleId: $platformRelPath (可能未在 cordova_plugins.js 注册)，跳过"
                return
            }

            $dstDir = Split-Path $dst
            if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Path $dstDir -Force | Out-Null }

            $jsContent = Get-Content $jsFile.FullName -Raw -Encoding UTF8
            $wrapped = "cordova.define(""$moduleId"", function(require, exports, module) {`n${jsContent}`n});`n"
            Set-Content $dst -Value $wrapped -Encoding UTF8 -NoNewline
            $jsCount++
            Write-Ok "src/plugins/$dir/www/$($jsFile.Name) → [$moduleId]"
        }
    }
    Write-Ok "JS 插件已同步 ($jsCount 个，含 cordova.define 包装)"

    # ── 4. Java 源文件（自动读取 package 声明确定目标路径）──
    $javaCount = 0
    $pluginSrcBase = Join-Path $ProjectRoot "src/plugins"
    Get-ChildItem $pluginSrcBase -Directory | ForEach-Object {
        $javaFiles = Get-ChildItem $_.FullName -Filter "*.java" -Recurse
        foreach ($jf in $javaFiles) {
            $firstLines = Get-Content $jf.FullName -TotalCount 10 -Encoding UTF8
            $pkgMatch = $firstLines | Select-String -Pattern '^\s*package\s+([^;]+);' | Select-Object -First 1
            if ($pkgMatch) {
                $pkgPath = $pkgMatch.Matches[0].Groups[1].Value.Replace('.', '/')
                $dstDir = Join-Path $PlatformJavaRoot $pkgPath
                if (Test-Path $dstDir) {
                    Copy-Item $jf.FullName (Join-Path $dstDir $jf.Name) -Force
                    $javaCount++
                }
            }
        }
    }
    Write-Ok "Java 源文件已同步 ($javaCount 个)"
}

# ─── 同步 www/build 到平台目录 ────────────────────────────────────────
function Invoke-SyncWwwBuild {
    $srcBuild = Join-Path $WwwDir "build"
    $dstBuild = Join-Path $PlatformAssetsDir "build"

    if (-not (Test-Path $srcBuild)) {
        Write-Warn "www/build 不存在，跳过同步"
        return
    }
    if (-not (Test-Path $PlatformAssetsDir)) {
        Write-Warn "平台 assets/www 目录不存在，跳过同步"
        return
    }

    Write-Step "同步 www/build → 平台 assets/www/build"
    Copy-Item -Path "$srcBuild\*" -Destination $dstBuild -Recurse -Force
    $fileCount = (Get-ChildItem $srcBuild -Recurse -File).Count
    Write-Ok "已同步 $fileCount 个文件"
}

# ─── HDC 反向端口转发 ─────────────────────────────────────────────────
function Invoke-Rport {
    Test-Hdc

    Write-Step "设置 HDC 反向端口转发 (设备:${Port} → 主机:${Port})"

    # 先清除已有的同端口转发
    $existing = & $HdcExe fport ls 2>&1
    if ($existing -match "tcp:${Port}") {
        Write-Warn "清除已有端口转发..."
        & $HdcExe fport rm "tcp:${Port}" 2>&1 | Out-Null
    }

    # 设置反向端口转发: 设备上的 127.0.0.1:PORT → 主机的 PORT
    $result = & $HdcExe rport tcp:${Port} tcp:${Port} 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Ok "反向端口转发已建立: 设备 127.0.0.1:${Port} → 主机 :${Port}"
        Write-Ok "设备上的应用可通过 http://127.0.0.1:${Port} 连接调试服务器"
    } else {
        Write-Warn "端口转发可能失败: $result"
        Write-Warn "尝试备选命令..."
        # 有些 HDC 版本语法不同
        $result2 = & $HdcExe fport tcp:${Port} tcp:${Port} 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Ok "正向端口转发已建立 (fport): 主机:${Port} → 设备:${Port}"
        } else {
            Write-Err "端口转发失败，请手动执行: hdc rport tcp:${Port} tcp:${Port}"
        }
    }

    # 显示当前端口转发列表
    $list = & $HdcExe fport ls 2>&1
    Write-Host "  当前端口转发:" -ForegroundColor DarkGray
    $list | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray }
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
        $serverArgs = @($serverScript, "--port", $Port, "--watch")
        if ($UseRport) { $serverArgs += "--localhost" }
        node @serverArgs
    } finally {
        Pop-Location
    }
}

function Invoke-Logs {
    Test-Hdc
    $logDir = Join-Path $ProjectRoot "scripts/hdc-debug/logs"
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null

    $ts = Get-Date -Format "yyyyMMdd-HHmmss"
    $logFile = Join-Path $logDir "hilog-$ts.log"
    $filteredLogFile = Join-Path $logDir "hilog-filtered-$ts.log"

    Write-Step "抓取设备日志（一次性导出，不阻塞）"
    $query = "hilog -x -z 1500"
    $output = & $HdcExe shell $query 2>&1
    $output | Out-File -FilePath $logFile -Encoding UTF8

    Write-Ok "日志已保存: $logFile"

    $pattern = 'foxdebug|acode|Terminal|ProcessManager|TerminalService|Executor|proot|axs|WebSocket|Connection lost|Failed to start AXS'
    $filtered = $output | Select-String -Pattern $pattern
    $filtered | ForEach-Object { $_.Line } | Out-File -FilePath $filteredLogFile -Encoding UTF8
    Write-Ok "过滤日志已保存: $filteredLogFile"

    Write-Step "最近匹配行预览"
    $preview = $filtered | Select-Object -Last 40
    if ($preview) {
        $preview | ForEach-Object { Write-Host "  $($_.Line)" }
    } else {
        Write-Warn "未捕获到匹配日志，可先复现后立即执行: .\deploy.ps1 -Action logs"
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
        # 同步插件脚本和 www/build 以确保平台资源是最新的
        Invoke-SyncPluginAssets
        Invoke-SyncWwwBuild
        # 注入到平台目录（不需要 rspack，直接注入平台副本）
        if (-not $NoInject) { Invoke-Inject }
        $apk = Invoke-GradleBuild
        Invoke-Push -ApkPath $apk
    }
    "inject" {
        Invoke-Inject
        Write-Step "重新构建前端资源"
        Push-Location $ProjectRoot
        npx rspack --mode development
        Pop-Location
        Invoke-SyncWwwBuild
        Write-Ok "注入完成，需要重新构建 APK 并推送"
    }
    "server" {
        if ($UseRport) { Invoke-Rport }
        Invoke-Server
    }
    "logs" {
        Invoke-Logs
    }
    "rport" {
        Invoke-Rport
    }
    "full" {
        Invoke-SyncPluginAssets
        if (-not $NoInject) { Invoke-Inject }
        Invoke-Build
        Invoke-Push
        if ($UseRport) { Invoke-Rport }
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
