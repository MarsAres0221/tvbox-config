# TVBox Android 端逐线路验证脚本（完整版）
# 功能：启动 MuMu → 下载配置 → 逐条验证线路 → 生成报告 → 推送微信 → 关闭 MuMu

param(
    [string]$OnlyLineIndexes = "",
    [switch]$SkipNotification,
    [switch]$KeepMuMuOpen,
    [switch]$UseLocalConfig,
    [string]$ReportLabel = "TVBox Android 线路验证报告",
    [string]$NotificationSuffix = ""
)

$ErrorActionPreference = "Stop"

# ============================================================
# 配置区
# ============================================================
$mumuPath = "C:\Program Files\Netease\MuMuPlayer-12.0"
$mumuExe = Join-Path $mumuPath "shell\MuMuPlayer.exe"
$mumuAdb = Join-Path $mumuPath "shell\adb.exe"
$screenshotDir = "C:\projects\tvbox-config\screenshots"
$reportPath = "C:\projects\tvbox-config\android-validation-report.md"
$queueDir = "C:\claude workspace\.video-queue"
$notifyDir = Join-Path $queueDir "notifications"
$configPath = Join-Path $queueDir "config.json"
$pythonExe = "C:\Program Files\Python312\python.exe"
$multiRepoHelper = "C:\projects\tvbox-config\android_multi_repo_helper.py"
$configInputHelper = "C:\projects\tvbox-config\android_config_input_helper.py"
$multiRepoMaxSubLines = 3
$selectedLineIndexes = @()
if ($OnlyLineIndexes.Trim()) {
    $selectedLineIndexes = $OnlyLineIndexes -split "," | ForEach-Object { [int]$_.Trim() }
}

# CDN 配置地址
$cdnUrls = @{
    "DC.json" = "https://cdn.jsdelivr.net/gh/MarsAres0221/tvbox-config@master/DC.json"
    "singles.json" = "https://cdn.jsdelivr.net/gh/MarsAres0221/tvbox-config@master/singles.json"
}

# 影视仓 UI 坐标（MuMu 1600x900 landscape，uiautomator 提取）
$btnSettings = @{ x = 1485; y = 207 }
$btnConfigAddr = @{ x = 537; y = 68 }
$btnName = @{ x = 545; y = 690 }
$btnUrl = @{ x = 973; y = 690 }
$btnConfirm = @{ x = 1221; y = 680 }

# ============================================================
# 工具函数
# ============================================================
function Write-Log {
    param([string]$msg)
    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] $msg"
}

# 通过 cmd /c 调用 adb，stderr 彻底丢弃（避免 PowerShell 把 adb 的 Warning 输出当成 NativeCommandError）
function Invoke-Adb {
    param([string]$command)
    cmd /c "`"$mumuAdb`" $command 2>nul"
}
function Invoke-AdbQuiet {
    param([string]$command)
    cmd /c "`"$mumuAdb`" $command 2>nul" | Out-Null
}

function Invoke-AndroidTap {
    param([int]$x, [int]$y, [string]$label = "")
    Invoke-AdbQuiet "shell `"input tap $x $y`""
    if ($label) { Write-Log "  Tap: $label ($x, $y)" }
}

function Invoke-AndroidKey {
    param([int]$keycode)
    Invoke-AdbQuiet "shell `"input keyevent $keycode`""
}

function Clear-InputField {
    for ($i = 0; $i -lt 100; $i++) { Invoke-AndroidKey -keycode 67 }
}

function Take-Screenshot {
    param([string]$filename)
    $remotePath = "/sdcard/screen.png"
    $localPath = Join-Path $screenshotDir $filename
    Invoke-AdbQuiet "shell `"/system/bin/screencap -p $remotePath`""
    Invoke-AdbQuiet "pull $remotePath `"$localPath`""
    Write-Log "  Screenshot: $localPath"
    return $localPath
}

function Test-NavBarPixels {
    param([string]$screenshotPath)
    Add-Type -AssemblyName System.Drawing
    $bmp = [System.Drawing.Bitmap]::new($screenshotPath)
    $rect = [System.Drawing.Rectangle]::new(0, 70, 1600, 70)
    $bits = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
        [System.Drawing.Imaging.PixelFormat]::Format24bppRgb)
    $byteCount = [Math]::Abs($bits.Stride) * $bits.Height
    $bytes = [byte[]]::new($byteCount)
    [System.Runtime.InteropServices.Marshal]::Copy($bits.Scan0, $bytes, 0, $byteCount)
    $bmp.UnlockBits($bits)
    $bmp.Dispose()

    $bright = 0
    for ($i = 0; $i -lt $byteCount; $i += 3) {
        $max = [Math]::Max($bytes[$i], [Math]::Max($bytes[$i+1], $bytes[$i+2]))
        if ($max -gt 100) { $bright++ }
    }
    return $bright
}

function Test-UiState {
    param([string]$screenshotPath)
    $dumpRemote = "/sdcard/ui_dump.xml"
    $dumpLocal = Join-Path $screenshotDir "ui_dump.xml"
    Invoke-AdbQuiet "shell `"uiautomator dump $dumpRemote`""
    Invoke-AdbQuiet "pull $dumpRemote `"$dumpLocal`""

    if (!(Test-Path $dumpLocal)) {
        return @{ Status = "Fail"; Reason = "uiautomator dump 失败" ; LabelCount = 0 }
    }

    $xmlText = [System.IO.File]::ReadAllText($dumpLocal, [System.Text.Encoding]::UTF8)
    $xml = [xml]$xmlText

    $nodes = $xml.SelectNodes("//*[@text]")
    $texts = @()
    foreach ($n in $nodes) {
        if ($n.text -and $n.text.Trim()) {
            $texts += $n.text.Trim()
        }
    }

    # 1. 对话框检测：出现"配置地址"说明对话框未关闭
    if ($texts -contains "配置地址") {
        return @{ Status = "Fail"; Reason = "配置对话框未关闭" ; LabelCount = 0 }
    }

    # 2. 导航标签像素分析：截图导航带 bright 像素数 ≥ 10000 → 有效
    $brightPixels = Test-NavBarPixels -screenshotPath $screenshotPath
    if ($brightPixels -ge 10000) {
        return @{ Status = "Pass"; Reason = "导航标签正常 ($brightPixels px)" ; LabelCount = $brightPixels }
    }

    return @{ Status = "Fail"; Reason = "主页分类栏未加载 ($brightPixels px)" ; LabelCount = 0 }
}

function Test-TabBarText {
    $dumpRemote = "/sdcard/ui_dump.xml"
    $dumpLocal = Join-Path $screenshotDir "ui_dump.xml"
    Invoke-AdbQuiet "shell `"uiautomator dump $dumpRemote`""
    Invoke-AdbQuiet "pull $dumpRemote `"$dumpLocal`""

    if (!(Test-Path $dumpLocal)) {
        return @{ Status = "Fail"; Reason = "uiautomator dump 失败" ; LabelCount = 0 }
    }

    $xmlText = [System.IO.File]::ReadAllText($dumpLocal, [System.Text.Encoding]::UTF8)
    $tabKeywords = @("热门电影", "热播剧集", "热门动漫", "热播综艺", "电影筛选", "电视筛选")
    foreach ($keyword in $tabKeywords) {
        if ($xmlText.Contains($keyword)) {
            return @{ Status = "Pass"; Reason = "标签文本正常 ($keyword)" ; LabelCount = 1 }
        }
    }

    return @{ Status = "Fail"; Reason = "标签文本未加载" ; LabelCount = 0 }
}

function Test-IsMultiRepoLine {
    param([string]$lineName, [string]$lineUrl)
    if ($lineName -like "*多仓*") { return $true }
    if ($lineUrl -match "gitlab\.com/.+tvboxmuti|Tomorrow/master/lmw\.json") { return $true }
    return $false
}

function Get-UiDumpText {
    $dumpRemote = "/sdcard/ui_dump.xml"
    $dumpLocal = Join-Path $screenshotDir "ui_dump.xml"
    Invoke-AdbQuiet "shell `"uiautomator dump $dumpRemote`""
    Invoke-AdbQuiet "pull $dumpRemote `"$dumpLocal`""
    if (!(Test-Path $dumpLocal)) { return "" }
    return [System.IO.File]::ReadAllText($dumpLocal, [System.Text.Encoding]::UTF8)
}

function Test-IsHomePage {
    $xmlText = Get-UiDumpText
    if (!$xmlText) { return $false }
    if ($xmlText.Contains("配置地址")) { return $false }
    return $xmlText.Contains("历史") -and $xmlText.Contains("直播") -and $xmlText.Contains("搜索")
}

function Dismiss-StartupDialog {
    $xmlText = Get-UiDumpText
    if ($xmlText.Contains("拉取配置失败") -or $xmlText.Contains("failed to connect")) {
        Invoke-AndroidTap -x 760 -y 490 -label "Dismiss startup dialog"
        Start-Sleep -Seconds 2
    }
}

function Ensure-YingshiHome {
    param([string]$reason = "")

    if (Test-IsHomePage) { return }

    Write-Log "  Recovering home state $reason"
    for ($i = 0; $i -lt 2; $i++) {
        Invoke-AndroidKey -keycode 4
        Start-Sleep -Seconds 2
        if (Test-IsHomePage) { return }
    }

    $yingshiPkg = "com.huawei.himovceie"
    $yingshiActivity = "com.github.tvbox.osc.ui.activity.HomeActivity"
    Invoke-AdbQuiet "shell `"am force-stop $yingshiPkg`""
    Start-Sleep -Seconds 2
    Invoke-AdbQuiet "shell `"am start -n ${yingshiPkg}/${yingshiActivity}`""
    Start-Sleep -Seconds 10
    Dismiss-StartupDialog

    for ($i = 0; $i -lt 5; $i++) {
        if (Test-IsHomePage) { return }
        Start-Sleep -Seconds 2
    }
}

function Return-HomeAfterConfigSubmit {
    for ($i = 0; $i -lt 4; $i++) {
        if (Test-IsHomePage) { return $true }

        $xmlText = Get-UiDumpText
        $inSettings = $xmlText.Contains("配置地址") -or
            $xmlText.Contains("播放器") -or
            $xmlText.Contains("操作偏好") -or
            $xmlText.Contains("换张壁纸")

        if ($inSettings) {
            Invoke-AndroidKey -keycode 4
            Start-Sleep -Seconds 2
            continue
        }

        # Loading pages may have no nav buttons yet. Do not press back out of them.
        return $false
    }

    return (Test-IsHomePage)
}

function Test-MultiRepoLineConfig {
    param(
        [int]$lineIndex,
        [string]$lineName,
        [string]$lineUrl,
        [string]$screenshotName,
        [string]$displayName
    )

    if (!(Test-Path $pythonExe)) { throw "Python not found: $pythonExe" }
    if (!(Test-Path $multiRepoHelper)) { throw "Multi repo helper not found: $multiRepoHelper" }

    $screenshotPath = Join-Path $screenshotDir $screenshotName
    Write-Log "  Multi-repo flow via uiautomator2"
    $env:PYTHONIOENCODING = "utf-8"
    $helperOutput = & $pythonExe $multiRepoHelper `
        --name $displayName `
        --url $lineUrl `
        --screenshot $screenshotPath `
        --max-sub-lines $multiRepoMaxSubLines 2>&1

    if ($LASTEXITCODE -ne 0) {
        throw "Multi repo helper failed: $($helperOutput -join "`n")"
    }

    $helperResult = $helperOutput | Select-Object -Last 1 | ConvertFrom-Json

    return [PSCustomObject]@{
        LineIndex = $lineIndex
        LineName = $lineName
        LineUrl = $lineUrl
        ScreenshotPath = $screenshotPath
        ScreenshotName = $screenshotName
        Status = $helperResult.status
        Reason = $helperResult.reason
        LabelCount = $helperResult.labelCount
    }
}

function Invoke-ConfigInput {
    param([string]$displayName, [string]$lineUrl)

    if (!(Test-Path $pythonExe)) { throw "Python not found: $pythonExe" }
    if (!(Test-Path $configInputHelper)) { throw "Config input helper not found: $configInputHelper" }

    $env:PYTHONIOENCODING = "utf-8"
    $helperOutput = & $pythonExe $configInputHelper `
        --name $displayName `
        --url $lineUrl 2>&1

    if ($LASTEXITCODE -ne 0) {
        throw "Config input helper failed: $($helperOutput -join "`n")"
    }

    $inputResult = $helperOutput | Select-Object -Last 1 | ConvertFrom-Json
    if (-not $inputResult.ok) {
        throw $inputResult.reason
    }

    Write-Log "  $($inputResult.reason)"
}

function Wait-ConfigLoaded {
    param([int]$maxWait = 45)

    $interval = 5
    $elapsed = 0
    $dumpRemote = "/sdcard/ui_dump.xml"
    $dumpLocal = Join-Path $screenshotDir "ui_dump.xml"
    $prevContentCount = -1
    $stableCount = 0

    while ($elapsed -lt $maxWait) {
        Invoke-AdbQuiet "shell `"uiautomator dump $dumpRemote`""
        Invoke-AdbQuiet "pull $dumpRemote `"$dumpLocal`""

        if (Test-Path $dumpLocal) {
            $xmlText = [System.IO.File]::ReadAllText($dumpLocal, [System.Text.Encoding]::UTF8)
            $xml = [xml]$xmlText
            $nodes = $xml.SelectNodes("//*[@text]")

            $texts = @()
            foreach ($n in $nodes) {
                if ($n.text -and $n.text.Trim()) { $texts += $n.text.Trim() }
            }

            # 对话框还在 → 继续等
            if ($texts -contains "配置地址") {
                Write-Log "  Config dialog still open, waiting... (${elapsed}s)"
                Start-Sleep -Seconds $interval
                $elapsed += $interval
                continue
            }

            # 内容区节点计数
            $contentCount = 0
            foreach ($n in $nodes) {
                $bounds = $n.bounds
                if ($bounds -match '\[(\d+),(\d+)\]\[(\d+),(\d+)\]') {
                    $y1 = [int]$matches[2]
                    if ($y1 -gt 260 -and $n.text -and $n.text.Trim()) { $contentCount++ }
                }
            }

            # UI 稳定检测：连续 2 次（10s）节点数不变 → 加载完成
            if ($contentCount -eq $prevContentCount -and $contentCount -ge 10) {
                $stableCount++
                if ($stableCount -ge 2) {
                    Write-Log "  Config stable (${contentCount} nodes, ${elapsed}s)"
                    return
                }
            } else {
                $stableCount = 0
            }
            $prevContentCount = $contentCount
        }

        Start-Sleep -Seconds $interval
        $elapsed += $interval
    }
    Write-Log "  Config load timeout (${maxWait}s), proceeding anyway"
}

function Start-MuMu {
    Write-Log "Starting MuMu Player..."
    if (!(Test-Path $mumuExe)) {
        throw "MuMu not found: $mumuExe"
    }

    # Kill stale adb server before starting MuMu to prevent boot timeout
    Write-Log "  Killing stale adb server (if any)..."
    # Try graceful shutdown first
    Invoke-AdbQuiet "kill-server"
    Start-Sleep -Seconds 2
    # Force kill any remaining adb processes (including zombie processes)
    $adbProcs = Get-Process adb -ErrorAction SilentlyContinue
    if ($adbProcs) {
        Write-Log "  Force killing $($adbProcs.Count) stale adb process(es)..."
        $adbProcs | Stop-Process -Force -ErrorAction SilentlyContinue
    }
    # Give MuMu time to start fresh adb server
    Start-Sleep -Seconds 3

    # Check if MuMu is already running and responsive
    $existingProc = Get-Process -Name "MuMuPlayer" -ErrorAction SilentlyContinue
    if ($existingProc) {
        Write-Log "  MuMuPlayer process already running (PID $($existingProc.Id)), checking adb..."
        Invoke-AdbQuiet "connect `"127.0.0.1:16384`""
        Start-Sleep -Seconds 3
        $existingBoot = (Invoke-Adb "shell getprop sys.boot_completed" -ErrorAction SilentlyContinue) | Select-Object -First 1
        if ($existingBoot -eq "1") {
            Write-Log "MuMu ready (already running)"
            return
        }
        Write-Log "  MuMu running but not booted yet, waiting up to 60s..."
        for ($j = 0; $j -lt 20; $j++) {
            Start-Sleep -Seconds 3
            $b = (Invoke-Adb "shell getprop sys.boot_completed" -ErrorAction SilentlyContinue) | Select-Object -First 1
            if ($b -eq "1") {
                Write-Log "MuMu ready (already running, waited $(( $j + 1) * 3)s)"
                return
            }
        }
        Write-Log "  Existing MuMu unresponsive, killing and restarting..."
        @("MuMuPlayer", "MuMuPlayerService", "MuMuVMMHeadless", "MuMuVMMSVC") | ForEach-Object {
            Get-Process -Name $_ -ErrorAction SilentlyContinue | Stop-Process -Force
        }
        Start-Sleep -Seconds 5
    }

    Start-Process -FilePath $mumuExe -WorkingDirectory (Join-Path $mumuPath "shell")
    Start-Sleep -Seconds 20
    Invoke-AdbQuiet "connect `"127.0.0.1:16384`""
    Start-Sleep -Seconds 5
    $maxRetries = 30
    for ($i = 0; $i -lt $maxRetries; $i++) {
        $boot = (Invoke-Adb "shell getprop sys.boot_completed") | Select-Object -First 1
        if ($boot -eq "1") {
            Write-Log "MuMu ready"
            return
        }
        Start-Sleep -Seconds 3
    }
    # Clean up on failure to prevent zombie process blocking next run
    Write-Log "  Boot timeout, killing MuMu processes before throwing..."
    @("MuMuPlayer", "MuMuPlayerService", "MuMuVMMHeadless", "MuMuVMMSVC", "adb") | ForEach-Object {
        Get-Process -Name $_ -ErrorAction SilentlyContinue | Stop-Process -Force
    }
    throw "MuMu boot timeout"
}

function Start-YingshiCang {
    Write-Log "Launching YingshiCang..."
    # 影视仓伪装为华为包名，versionName=5.0.44.1
    $yingshiPkg = "com.huawei.himovceie"
    $yingshiActivity = "com.github.tvbox.osc.ui.activity.HomeActivity"

    $pkg = Invoke-Adb "shell `"pm list packages $yingshiPkg`""
    if ($pkg -match $yingshiPkg) {
        Write-Log "Found package: $yingshiPkg"
        Invoke-AdbQuiet "shell `"am start -n ${yingshiPkg}/${yingshiActivity}`""
        Start-Sleep -Seconds 8
        Write-Log "YingshiCang launched"
    } else {
        Write-Log "YingshiCang not found, trying to install..."
        $apkPath = "C:\projects\tvbox-config\apks\影视仓_5.0.44.1-通用版.apk"
        if (Test-Path $apkPath) {
            Invoke-AdbQuiet "install `"$apkPath`""
            Start-Sleep -Seconds 3
            $pkg2 = Invoke-Adb "shell `"pm list packages $yingshiPkg`""
            if ($pkg2 -match $yingshiPkg) {
                Write-Log "APK installed, launching..."
                Invoke-AdbQuiet "shell `"am start -n ${yingshiPkg}/${yingshiActivity}`""
                Start-Sleep -Seconds 8
                Write-Log "YingshiCang launched"
            } else {
                Write-Log "APK install failed silently"
            }
        } else {
            Write-Log "APK not found at: $apkPath"
        }
    }
}

function Stop-MuMu {
    Write-Log "Stopping MuMu Player..."
    # 优先用官方命令优雅关闭
    $mumuMgr = Join-Path $mumuPath "shell\MuMuManager.exe"
    if (Test-Path $mumuMgr) {
        & $mumuMgr control --vmindex all shutdown 2>&1 | Out-Null
        Start-Sleep -Seconds 2
    }
    # 强制清理残留进程（MuMuPlayerService 官方 shutdown 不会关）
    @("MuMuPlayer", "MuMuPlayerService", "MuMuVMMHeadless", "MuMuVMMSVC", "adb") | ForEach-Object {
        Get-Process -Name $_ -ErrorAction SilentlyContinue | Stop-Process -Force
    }
    Start-Sleep -Seconds 3
    Write-Log "MuMu stopped"
}

function Test-LineConfig {
    param(
        [int]$lineIndex,
        [string]$lineName,
        [string]$lineUrl,
        [string]$screenshotName,
        [string]$displayName
    )

    Write-Log "===== Line $lineIndex : $displayName ====="

    if (Test-IsMultiRepoLine -lineName $lineName -lineUrl $lineUrl) {
        return Test-MultiRepoLineConfig `
            -lineIndex $lineIndex `
            -lineName $lineName `
            -lineUrl $lineUrl `
            -screenshotName $screenshotName `
            -displayName $displayName
    }

    Ensure-YingshiHome -reason "before single line $lineIndex"

    Invoke-AndroidTap -x $btnSettings.x -y $btnSettings.y -label "Settings"
    Start-Sleep -Seconds 2

    Invoke-AndroidTap -x $btnConfigAddr.x -y $btnConfigAddr.y -label "ConfigAddr"
    Start-Sleep -Seconds 2

    Invoke-ConfigInput -displayName $displayName -lineUrl $lineUrl

    Return-HomeAfterConfigSubmit | Out-Null

    Wait-ConfigLoaded -maxWait 120

    # 额外等待：分类标签可能在内容卡片之后才渲染
    Start-Sleep -Seconds 15

    $screenshotPath = Take-Screenshot -filename $screenshotName
    $uiState = Test-UiState -screenshotPath $screenshotPath

    return [PSCustomObject]@{
        LineIndex = $lineIndex
        LineName = $lineName
        LineUrl = $lineUrl
        ScreenshotPath = $screenshotPath
        ScreenshotName = $screenshotName
        Status = $uiState.Status
        Reason = $uiState.Reason
        LabelCount = $uiState.LabelCount
    }
}

function Send-Notification {
    param([string]$id, [string]$message)

    $queueConfig = @{}
    if (Test-Path $configPath) {
        $queueConfig = Get-Content -Raw -Encoding UTF8 $configPath | ConvertFrom-Json
    }

    $createdAt = [DateTime]::UtcNow
    $utc8 = $createdAt.AddHours(8)
    $ts = $utc8.ToString("yyyy-MM-dd HH:mm")

    $notification = [PSCustomObject]@{
        id = $id
        project = if ($queueConfig.project) { $queueConfig.project } else { "my-weixin-project" }
        session_key = if ($queueConfig.session_key) { $queueConfig.session_key } else { "" }
        message = "$message`nEnqueue: $ts"
        created_at = $createdAt.ToUniversalTime().ToString("o")
        token_mtime_at_failure = 0
    }

    if (!(Test-Path $notifyDir)) { New-Item -ItemType Directory -Path $notifyDir -Force | Out-Null }
    $outPath = Join-Path $notifyDir "$id.json"
    $notification | ConvertTo-Json -Depth 3 | Set-Content -Path $outPath -Encoding UTF8
    Write-Log "Notification queued: $outPath"
}

# ============================================================
# Main Flow
# ============================================================
Write-Log "===== TVBox Android Line Validation Start ====="

# Step 1: Start MuMu
try {
    Start-MuMu
    Start-YingshiCang
} catch {
    Write-Log "MuMu start failed: $_"
    # Ensure cleanup even on startup failure to prevent zombie processes locking log file
    Write-Log "Cleaning up MuMu processes after startup failure..."
    @("MuMuPlayer", "MuMuPlayerService", "MuMuVMMHeadless", "MuMuVMMSVC", "adb") | ForEach-Object {
        Get-Process -Name $_ -ErrorAction SilentlyContinue | Stop-Process -Force
    }
    if (!$SkipNotification) {
        $utc8 = [DateTime]::UtcNow.AddHours(8)
        $dateStr = $utc8.ToString("yyyy-MM-dd")
        $timeStr = $utc8.ToString("yyyy-MM-dd HH:mm")
        $failId = "tvbox_android${NotificationSuffix}_${dateStr}_failed"
        $reason = "$_".Trim()
        $failMsg = "⚠️ TVBox 每日验证未启动`n`n原因：MuMu 启动失败`n错误：$reason`n时间：$timeStr"
        try {
            Send-Notification -id $failId -message $failMsg
        } catch {
            Write-Log "Failed to queue failure notification: $_"
        }
    }
    exit 1
}

try {

# Step 2: Create and clear screenshot dir
if (!(Test-Path $screenshotDir)) { New-Item -ItemType Directory -Path $screenshotDir -Force | Out-Null }
Get-ChildItem -Path $screenshotDir -Filter "*.png" | Remove-Item -Force
Write-Log "Screenshot dir cleared"

# Step 3: Load config (local files or CDN)
$allLines = @()

if ($UseLocalConfig) {
    Write-Log "Loading local config files..."
    $localSources = @("DC.json", "singles.json")
    foreach ($source in $localSources) {
        $localPath = Join-Path "C:\projects\tvbox-config" $source
        Write-Log "  Load $source : $localPath"
        try {
            $content = Get-Content -Raw -Encoding UTF8 $localPath
            $config = $content | ConvertFrom-Json
            foreach ($line in $config.urls) {
                $allLines += [PSCustomObject]@{
                    Source = $source
                    Name = $line.name
                    Url = $line.url
                }
            }
            Write-Log "  $source contains $($config.urls.Count) lines"
        } catch {
            Write-Log "  Load $source failed: $_"
        }
    }
} else {
    Write-Log "Downloading config files from CDN..."
    foreach ($source in $cdnUrls.Keys) {
        $url = $cdnUrls[$source]
        Write-Log "  Download $source : $url"
        try {
            $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 30
            $config = $response.Content | ConvertFrom-Json
            foreach ($line in $config.urls) {
                $allLines += [PSCustomObject]@{
                    Source = $source
                    Name = $line.name
                    Url = $line.url
                }
            }
            Write-Log "  $source contains $($config.urls.Count) lines"
        } catch {
            Write-Log "  Download $source failed: $_"
        }
    }
}

Write-Log "Total $($allLines.Count) lines to test"

# Step 4: Test each line
$results = @()
$sourceLineIndex = 0
foreach ($line in $allLines) {
    $sourceLineIndex++
    if ($selectedLineIndexes.Count -gt 0 -and $sourceLineIndex -notin $selectedLineIndexes) {
        continue
    }

    $lineIndex = $sourceLineIndex
    $cleanName = $line.Name -replace '[^a-zA-Z0-9]', ''
    $screenshotName = "{0:D2}-{1}.png" -f $lineIndex, $cleanName
    # adb input text 不支持中文/emoji，用 ASCII slug 作为 name
    $displayName = "L{0:D2}-{1}" -f $lineIndex, ($line.Source -replace '\.json','')

    try {
        $result = Test-LineConfig `
            -lineIndex $lineIndex `
            -lineName $line.Name `
            -lineUrl $line.Url `
            -screenshotName $screenshotName `
            -displayName $displayName
        $results += $result
    } catch {
        Write-Log "  Line test failed: $_"
        $results += [PSCustomObject]@{
            LineIndex = $lineIndex
            LineName = $line.Name
            LineUrl = $line.Url
            ScreenshotName = $screenshotName
            Status = "Fail"
            Reason = "脚本异常: $_"
            LabelCount = 0
        }
    }
}

# Step 5: Generate report
Write-Log "===== Generating Report ====="

$passedCount = @($results | Where-Object { $_.Status -eq "Pass" }).Count
$failedCount = $results.Count - $passedCount
$passRate = if ($results.Count -gt 0) { [math]::Round($passedCount / $results.Count * 100, 1) } else { 0 }

$reportLines = @()
$reportLines += "# TVBox Android 线路验证报告"
$reportLines += ""
$reportLines += "- **日期**: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
$reportLines += "- **设备**: MuMu Player 12.0 (Android 12, API 32)"
$reportLines += "- **APK**: 影视仓 5.0.44.1"
$configSource = if ($UseLocalConfig) { "本地文件" } else { "CDN" }
$reportLines += "- **配置**: $configSource ($($allLines.Count) 条线路)"
$reportLines += "- **判定标准**: 对话框关闭 + 内容区加载完成"
$reportLines += ""
$reportLines += "---"
$reportLines += ""
$reportLines += "## 验证结果"
$reportLines += ""
$reportLines += "| # | 来源 | 名称 | 截图 | 状态 | 原因 |"
$reportLines += "|---|------|------|------|------|------|"

foreach ($result in $results) {
    $icon = if ($result.Status -eq "Pass") { "PASS" } else { "FAIL" }
    $reason = if ($result.Reason) { $result.Reason } else { "-" }
    $reportLines += "| $($icon) $($result.LineIndex) | $($result.LineName) | $($result.ScreenshotName) | $($result.Status) | $reason |"
}

$reportLines += ""
$reportLines += "---"
$reportLines += ""
$reportLines += "## 统计"
$reportLines += ""
$reportLines += "- 总计：$($results.Count)"
$reportLines += "- 通过：$passedCount"
$reportLines += "- 失败：$failedCount"
$reportLines += "- 通过率：$passRate%"
$reportLines += ""
$reportLines += "### 分类统计"
$reportLines += ""

$dcPass = @($results | Where-Object { $_.Status -eq "Pass" -and $_.LineName -notlike "*单仓*" }).Count
$dcFail = @($results | Where-Object { $_.Status -eq "Fail" -and $_.LineName -notlike "*单仓*" }).Count
$spPass = @($results | Where-Object { $_.Status -eq "Pass" -and $_.LineName -like "*单仓*" }).Count
$spFail = @($results | Where-Object { $_.Status -eq "Fail" -and $_.LineName -like "*单仓*" }).Count
$reportLines += "- DC.json（多仓）：$dcPass 通过, $dcFail 失败"
$reportLines += "- singles.json（单仓）：$spPass 通过, $spFail 失败"
$reportLines += ""
$reportLines += "---"
$reportLines += ""
$reportLines += "## 截图"
$reportLines += ""
$reportLines += "保存位置：$screenshotDir"
$reportLines += ""

$reportText = $reportLines -join "`n"
Set-Content -Path $reportPath -Value $reportText -Encoding UTF8
Write-Log "Report saved: $reportPath"

# Step 6: Send WeChat notification
if ($SkipNotification) {
    Write-Log "===== Skipping WeChat Notification ====="
} else {
    Write-Log "===== Sending WeChat Notification ====="

    $now = [DateTime]::UtcNow
    $utc8 = $now.AddHours(8)
    $dateStr = $utc8.ToString("yyyy-MM-dd")
    $dayOfWeek = @("Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat")[$utc8.DayOfWeek]

    $msgLines = @()
    $msgLines += $ReportLabel
    $msgLines += "日期：$dateStr ($dayOfWeek)"
    $msgLines += ""
    $msgLines += "测试信息："
    $msgLines += "- 设备：MuMu Player 12.0"
    $msgLines += "- APK：影视仓 5.0.44.1"
    $msgLines += "- 总计：$($results.Count)"
    $msgLines += "- 通过：$passedCount"
    $msgLines += "- 失败：$failedCount"
    $msgLines += "- 通过率：$passRate%"
    $msgLines += ""
    $msgLines += "验证结果："

    foreach ($result in $results) {
        $icon = if ($result.Status -eq "Pass") { "✅" } else { "❌" }
        $msgLines += "$icon $($result.LineIndex). $($result.LineName) — $($result.Status) $($result.Reason)"
    }

    $msgLines += ""
    $msgLines += "完整报告：android-validation-report.md"
    $msgLines += "截图目录：screenshots/"

    $message = $msgLines -join "`n"
    $notificationId = "tvbox_android${NotificationSuffix}_$dateStr"
    Send-Notification -id $notificationId -message $message
}

# Step 7: Stop MuMu
if ($KeepMuMuOpen) {
    Write-Log "Keeping MuMu running"
} else {
    Stop-MuMu
}

Write-Log "===== Validation Complete ====="

} catch {
    Write-Log "Validation aborted: $_"
    if (!$SkipNotification) {
        $utc8 = [DateTime]::UtcNow.AddHours(8)
        $dateStr = $utc8.ToString("yyyy-MM-dd")
        $timeStr = $utc8.ToString("yyyy-MM-dd HH:mm")
        $failId = "tvbox_android${NotificationSuffix}_${dateStr}_failed"
        $reason = "$_".Trim()
        $failMsg = "⚠️ TVBox 每日验证异常中止`n`n阶段：主流程`n错误：$reason`n时间：$timeStr"
        try {
            Send-Notification -id $failId -message $failMsg
        } catch {
            Write-Log "Failed to queue failure notification: $_"
        }
    }
} finally {
    # Always ensure MuMu is cleaned up, even if any step throws
    if (!$KeepMuMuOpen) {
        Write-Log "Finally: ensuring MuMu cleanup..."
        @("MuMuPlayer", "MuMuPlayerService", "MuMuVMMHeadless", "MuMuVMMSVC", "adb") | ForEach-Object {
            Get-Process -Name $_ -ErrorAction SilentlyContinue | Stop-Process -Force
        }
    }
}
