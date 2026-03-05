<#
.SYNOPSIS
  通过 HDC 获取华为手机屏幕截图

.DESCRIPTION
  使用 HDC shell 命令在手机端执行截图，然后拉取到本地。
  默认保存到桌面，文件名包含时间戳。

.PARAMETER OutputDir
  截图保存目录 (默认: 桌面)

.PARAMETER FileName
  自定义文件名 (不含扩展名)。省略则自动生成带时间戳的名称。

.PARAMETER Open
  截图完成后自动打开图片

.EXAMPLE
  .\screenshot.ps1                          # 截图保存到桌面
  .\screenshot.ps1 -OutputDir "D:\pics"     # 截图保存到指定目录
  .\screenshot.ps1 -FileName "bug-repro"    # 自定义文件名
  .\screenshot.ps1 -Open                    # 截图后自动打开
#>

param(
    [string]$OutputDir = [Environment]::GetFolderPath("Desktop"),
    [string]$FileName,
    [switch]$Open
)

$ErrorActionPreference = "Stop"

# ─── 配置 ─────────────────────────────────────────────────────────────
$HdcExe = "C:\Program Files (x86)\HiSuite\hwtools\hdc.exe"

# ─── 工具函数 ─────────────────────────────────────────────────────────
function Write-Step($msg) { Write-Host "`n▶ $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "  ✓ $msg" -ForegroundColor Green }
function Write-Err($msg)  { Write-Host "  ✗ $msg" -ForegroundColor Red }

# ─── 检查 HDC ─────────────────────────────────────────────────────────
if (-not (Test-Path $HdcExe)) {
    Write-Err "找不到 hdc.exe: $HdcExe"
    Write-Host "  请确认已安装华为手机助手 (HiSuite)" -ForegroundColor Yellow
    exit 1
}

# ─── 检查设备连接 ─────────────────────────────────────────────────────
Write-Step "检查设备连接"
$targets = & $HdcExe list targets 2>&1
if ($LASTEXITCODE -ne 0 -or $targets -match "Empty" -or [string]::IsNullOrWhiteSpace($targets)) {
    Write-Err "未检测到已连接的设备"
    Write-Host "  请确认手机已通过 USB 连接并开启 HDC 调试" -ForegroundColor Yellow
    exit 1
}
Write-Ok "已连接设备: $($targets.Trim())"

# ─── 截图 ─────────────────────────────────────────────────────────────
Write-Step "在手机上执行截图"
$output = & $HdcExe shell snapshot_display 2>&1 | Out-String
if ($output -match "write to\s+(\S+)") {
    $RemotePath = $Matches[1]
} else {
    Write-Err "截图失败，无法解析输出:`n$output"
    exit 1
}

# 从远程文件名推断扩展名 (jpeg/png)
$remoteExt = [System.IO.Path]::GetExtension($RemotePath)  # e.g. ".jpeg"
if ([string]::IsNullOrWhiteSpace($remoteExt)) { $remoteExt = ".jpeg" }

Write-Ok "手机端截图: $RemotePath"

# ─── 拉取到本地 ───────────────────────────────────────────────────────
Write-Step "拉取截图到本地"

if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

if ([string]::IsNullOrWhiteSpace($FileName)) {
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $FileName = "screenshot_$timestamp"
}

$localFile = Join-Path $OutputDir "$FileName$remoteExt"

& $HdcExe file recv $RemotePath $localFile 2>&1 | Out-Null
if (-not (Test-Path $localFile)) {
    Write-Err "拉取文件失败，本地文件不存在: $localFile"
    exit 1
}
Write-Ok "已保存到: $localFile"

# ─── 清理手机临时文件 ─────────────────────────────────────────────────
& $HdcExe shell rm -f $RemotePath 2>$null | Out-Null

# ─── 显示文件信息 ─────────────────────────────────────────────────────
$fileInfo = Get-Item $localFile
$sizeKB = [math]::Round($fileInfo.Length / 1KB, 1)
Write-Host "`n  📱 截图完成!" -ForegroundColor Green
Write-Host "  文件: $localFile"
Write-Host "  大小: ${sizeKB} KB"

# ─── 复制到剪贴板 ─────────────────────────────────────────────────────
Write-Step "复制到剪贴板"
Add-Type -AssemblyName System.Windows.Forms
$img = [System.Drawing.Image]::FromFile($localFile)
[System.Windows.Forms.Clipboard]::SetImage($img)
$img.Dispose()
Write-Ok "已复制到剪贴板"

# ─── 自动打开 ─────────────────────────────────────────────────────────
if ($Open) {
    Write-Step "打开截图"
    Start-Process $localFile
}
