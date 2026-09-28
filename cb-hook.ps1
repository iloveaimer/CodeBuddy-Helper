# CodeBuddy Hook: 任务完成 / 待用户确认 通知（零延迟）
# 处理事件：Stop（完成 / 等待确认）、Notification（待确认，若版本支持）
$ErrorActionPreference = 'SilentlyContinue'

# ---------- 读取 stdin（UTF-8 JSON） ----------
$json = ''
try {
    $reader = New-Object System.IO.StreamReader([Console]::OpenStandardInput(), [System.Text.Encoding]::UTF8)
    $json = $reader.ReadToEnd()
    $reader.Close()
} catch {}

$temp = $env:TEMP
$logFile = Join-Path $temp 'cbh-hook.log'
$rawFile = Join-Path $temp 'cbh-hook-raw.log'
$stateFile = Join-Path $temp 'cbh-hook-state.txt'
$pendFile = Join-Path $temp 'cbh-hook-pending.txt'
$soundsDir = Join-Path $env:USERPROFILE '.codebuddy-helper\sounds'
$soundPlayer = Join-Path $PSScriptRoot 'cb-sound.ps1'

# ---------- 原始 payload 转储（排查用，保留最后 200 行） ----------
try {
    Add-Content -Path $rawFile -Value ((Get-Date -Format 'HH:mm:ss') + ' ' + $json) -Encoding UTF8
    $raw = @(Get-Content $rawFile -Encoding UTF8)
    if ($raw.Count -gt 200) { $raw[-200..-1] | Set-Content -Path $rawFile -Encoding UTF8 }
} catch {}

# ---------- 解析 payload ----------
$event = ''
$proj = 'CodeBuddy'
$safeProj = 'CodeBuddy'
$cwd = ''
$ntype = ''
$genId = ''
$prompt = ''
$stopActive = $false

try {
    if ($json) {
        $o = $json | ConvertFrom-Json
        if ($o.hook_event_name) { $event = [string]$o.hook_event_name }
        if ($o.notification_type) { $ntype = [string]$o.notification_type }
        if ($o.generation_id) { $genId = [string]$o.generation_id }
        if ($o.stop_hook_active) { $stopActive = [bool]$o.stop_hook_active }
        if ($o.prompt) { $prompt = [string]$o.prompt }
        if ($o.cwd) {
            $cwd = [string]$o.cwd
            $leaf = Split-Path $cwd -Leaf
            if ($leaf) { $proj = $leaf }
        }
        $safeProj = $proj -replace '[\\/:*?"<>|]', '_'
    }
} catch {}

# ---------- UserPromptSubmit：最轻路径，尽早返回 ----------
# 用户每次发消息都会触发，所以要避免一切非必要 IO（不用 Write-Log 以免依赖后文函数）
if ($event -eq 'UserPromptSubmit') {
    try {
        $tf = Join-Path $temp "cbh-task-$safeProj.txt"
        Set-Content -Path $tf -Value ([DateTimeOffset]::Now.ToUnixTimeMilliseconds()) -Encoding UTF8
        Add-Content -Path $logFile -Value ((Get-Date -Format 'HH:mm:ss') + " UserPromptSubmit: $proj 任务起点已记录") -Encoding UTF8
    } catch {}
    exit 0
}

# ---------- 用户配置（由扩展导出成文件；读不到就用默认值，配置读取出问题不能影响通知主流程） ----------
$cfgFile = Join-Path $temp 'cbh-config.json'
$notifyOnComplete = $true
try {
    if (Test-Path $cfgFile) {
        $c = Get-Content $cfgFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -ne $c.notifyOnComplete) { $notifyOnComplete = [bool]$c.notifyOnComplete }
    }
} catch {}

function Write-Log($s) {
    try { Add-Content -Path $logFile -Value ((Get-Date -Format 'HH:mm:ss') + ' ' + $s) -Encoding UTF8 } catch {}
}

# ---------- VS Code 是否在前台 ----------
# 扩展会维护 %TEMP%\cbh-focus-<pid>.txt（1=聚焦 / 0=失焦）。
# 只要有一个 VS Code 窗口聚焦，就认为用户正看着编辑器，不必打扰。
function Test-VSCodeFocused {
    try {
        $focusFiles = @(Get-ChildItem -Path $temp -Filter 'cbh-focus-*.txt' -ErrorAction SilentlyContinue)
        foreach ($ff in $focusFiles) {
            # 超过 5 分钟没更新的视为失效（扩展已退出）
            if (((Get-Date) - $ff.LastWriteTime).TotalMinutes -gt 5) { continue }
            $v = (Get-Content $ff.FullName -Raw -Encoding UTF8).Trim()
            if ($v -eq '1') { return $true }
        }
    } catch {}
    return $false
}

# ---------- 任务耗时（依赖 UserPromptSubmit 记录的起点） ----------
function Get-TaskDuration($projName) {
    try {
        $sp = $projName -replace '[\\/:*?"<>|]', '_'
        $tf = Join-Path $temp "cbh-task-$sp.txt"
        if (-not (Test-Path $tf)) { return '' }
        $start = [int64]((Get-Content $tf -Raw -Encoding UTF8).Trim())
        $sec = [int](([DateTimeOffset]::Now.ToUnixTimeMilliseconds() - $start) / 1000)
        if ($sec -le 0 -or $sec -gt 86400) { return '' }
        if ($sec -lt 60) { return (' · ' + $sec + 's') }
        $mm = [int]($sec / 60)
        $ss = $sec % 60
        if ($mm -lt 60) { return (' · ' + $mm + 'm' + $ss + 's') }
        $hh = [int]($mm / 60)
        $mm = $mm % 60
        return (' · ' + $hh + 'h' + $mm + 'm')
    } catch { return '' }
}

# ---------- 自定义音效目录（自动创建；说明文件只在首次写入，避免每次都做 IO） ----------
try {
    if (-not (Test-Path $soundsDir)) {
        New-Item -ItemType Directory -Path $soundsDir -Force | Out-Null
    }
    $readmePath = Join-Path $soundsDir 'README.txt'
    if (-not (Test-Path $readmePath)) {
        $readme = @"
自定义通知音效目录
==================

把音频文件放进这个目录就能替换通知音，不需要改任何配置。

【按用途区分（文件名任意，扩展名随意）】
  done.*      任务执行完成时播放
  confirm.*   有命令待你确认时播放
  default.*   上两个都没放时，作为通用音效

  例：done.wav  /  confirm.mp3  /  default.wav

【支持的格式】
  .wav（推荐，播放最稳）/ .mp3 / .m4a / .wma / .aac / .flac / .ogg

【回退规则】
  1. done.{ext} / confirm.{ext}   按用途精确匹配
  2. 目录里只有一个音频文件      直接用它
  3. default.{ext}                通用音效
  4. 都没有                       用 Windows 系统默认通知音

【现成音效素材】
  C:\Windows\Media\ 里有 70+ 个系统音效，复制喜欢的过来改名即可：
    Alarm01.wav ~ Alarm10.wav       闹钟（最明显）
    Windows Notify Calendar.wav     日历提示
    Windows Notify Email.wav        邮件提示
    Windows Notify Messaging.wav    消息提示
    chimes.wav / tada.wav           经典提示音

【建议】
  时长 1~3 秒最合适。太长听起来像卡住了。
"@
        Set-Content -Path $readmePath -Value $readme -Encoding UTF8
    }
} catch {}

# ---------- 自定义音效解析 ----------
$SOUND_EXTS = @('.wav', '.mp3', '.m4a', '.wma', '.aac', '.flac', '.ogg')

function Get-SoundFile($kind) {
    try {
        if (-not (Test-Path $soundsDir)) { return $null }
        $files = @(Get-ChildItem -Path $soundsDir -File -ErrorAction SilentlyContinue |
                   Where-Object { $SOUND_EXTS -contains $_.Extension.ToLower() })
        if ($files.Count -eq 0) { return $null }
        # 1) 按用途精确匹配 done.* / confirm.*
        $named = $files | Where-Object { $_.BaseName -ieq $kind } | Select-Object -First 1
        if ($named) { return $named.FullName }
        # 2) 目录里只有一个音频 → 直接用它
        if ($files.Count -eq 1) { return $files[0].FullName }
        # 3) 通用 default.*
        $def = $files | Where-Object { $_.BaseName -ieq 'default' } | Select-Object -First 1
        if ($def) { return $def.FullName }
        return $null
    } catch { return $null }
}

# （音效播放已内联在 Send-Toast 中：直接调 cb-sound.ps1，省一次目录扫描）

function Send-Toast($text, $title, $launch, $kind) {
    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType=WindowsRuntime] | Out-Null
        [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType=WindowsRuntime] | Out-Null
        $safeT = ($text -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;')
        $safeH = ($title -replace '&', '&amp;' -replace '<', '&lt;' -replace '>', '&gt;' -replace '"', '&quot;')
        # 点击通知 → 用 vscode:// 协议打开对应项目
        $attr = ''
        if ($launch) {
            $safeL = ($launch -replace '&', '&amp;' -replace '"', '&quot;')
            $attr = ' activationType="protocol" launch="' + $safeL + '"'
        }
        # 有自定义音效时让 Toast 静音，改由 cb-sound.ps1 播放，避免双重声音
        # 没有自定义音效就一律用 Windows 系统默认通知音（ms-winsoundevent:Notification.Default）
        $useCustom = $false
        $customFile = $null
        if ($kind) { try { $customFile = Get-SoundFile $kind; if ($customFile) { $useCustom = $true } } catch {} }
        if ($useCustom) {
            $audioTag = '<audio silent="true"/>'
            Write-Log ("  sound: 自定义[" + $kind + "] " + (Split-Path $customFile -Leaf))
        } else {
            $audioTag = '<audio src="ms-winsoundevent:Notification.Default"/>'
            Write-Log "  sound: Windows 系统默认通知音"
        }

        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        $xml.LoadXml('<toast' + $attr + '><visual><binding template="ToastGeneric"><text>' + $safeH + '</text><text>' + $safeT + '</text></binding></visual>' + $audioTag + '</toast>')
        $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier('CBH').Show($toast)

        # 通知先出现，再起独立进程放自定义音效（不阻塞 hook）
        if ($useCustom -and $customFile -and (Test-Path $soundPlayer)) {
            Start-Process -WindowStyle Hidden -FilePath 'powershell' `
                -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $soundPlayer, $customFile) | Out-Null
        }
    } catch {
        Write-Log ('  toast error: ' + $_.Exception.Message)
    }
}

# ---------- 读文件尾部（高效，不加载整个文件） ----------
function Read-Tail($path, $maxBytes) {
    try {
        $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $len = $fs.Length
        $n = [Math]::Min($maxBytes, $len)
        if ($n -le 0) { $fs.Close(); return '' }
        $fs.Seek(-$n, [System.IO.SeekOrigin]::End) | Out-Null
        $buf = New-Object byte[] $n
        $fs.Read($buf, 0, $n) | Out-Null
        $fs.Close()
        return [System.Text.Encoding]::UTF8.GetString($buf)
    } catch { return '' }
}

# ---------- 判断是否卡在"等待用户确认" ----------
# 依据 CodeBuddy 日志：
#   [beforeExecute] Permission decision: source=safety_rule_ask, allowed=true, needConfirm=true   ← 请求用户确认
#   [AcpAgent:xxx] Permission response: approved=true, ...                                        ← 用户已响应
# 若最后一条 needConfirm=true 晚于最后一条 Permission response → 仍在等待用户确认
function Test-WaitingConfirm($projName) {
    try {
        # CBH_LOG_ROOT 仅用于本地测试覆盖
        if ($env:CBH_LOG_ROOT) { $logRoot = $env:CBH_LOG_ROOT }
        else { $logRoot = Join-Path $env:LOCALAPPDATA 'CodeBuddyExtension\Logs\VSCode' }
        if (-not (Test-Path $logRoot)) { return $false }
        $dayDir = Join-Path $logRoot (Get-Date -Format 'yyyy-MM-dd')
        if (-not (Test-Path $dayDir)) { return $false }

        $files = @(Get-ChildItem -Path $dayDir -Filter '*.log' -ErrorAction SilentlyContinue)
        if ($files.Count -eq 0) { return $false }

        # 优先本项目的日志，否则取最近写入的
        $target = $files | Where-Object { $_.Name -like ($projName + '*') } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $target) {
            $target = $files | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        }
        if (-not $target) { return $false }

        $tail = Read-Tail $target.FullName 262144
        if (-not $tail) { return $false }

        # 只保留真正的日志行（以 [yyyy/M/d H:mm:ss.fff] 开头）。
        # 否则会匹配到写进日志里的脚本源码文本（自指污染），导致误判。
        $logLines = New-Object System.Collections.ArrayList
        foreach ($ln in ($tail -split "`r?`n")) {
            if ($ln -match '^\[\d{4}/\d+/\d+ \d+:\d+:\d+(\.\d+)?\]') { [void]$logLines.Add($ln) }
        }
        if ($logLines.Count -eq 0) { return $false }

        # 从尾部往前扫，遇到的第一个"标志性事件"决定结论。
        # 这样天然解决"请求/响应配对"问题，不需要比对时间戳或行号。
        for ($i = $logLines.Count - 1; $i -ge 0; $i--) {
            $ln = $logLines[$i]

            # 已确认 / 已开始执行 / 已执行完 → 说明没卡住
            if ($ln -match 'confirmed:\s*true' -or
                $ln -match 'Permission response: approved=' -or
                $ln -match 'execution_started' -or
                $ln -match '全量执行完成' -or
                $ln -match '用户拒绝' -or $ln -match '已跳过') {
                return $false
            }

            # 待用户确认的两类信号：
            #   1) 危险命令拦截 → [SafetyRule] Dangerous command detected
            #   2) 权限决策要求确认 → needConfirm=true
            if ($ln -match 'Dangerous command detected' -or $ln -match 'needConfirm=true') {
                # 新鲜度校验：必须是最近 3 分钟内的，否则视为历史遗留
                $m = [regex]::Match($ln, '^\[(\d{4}/\d+/\d+ \d+:\d+:\d+)')
                if ($m.Success) {
                    try {
                        $t = [datetime]::ParseExact($m.Groups[1].Value, 'yyyy/M/d HH:mm:ss', $null)
                        if (((Get-Date) - $t).TotalMinutes -gt 3) { return $false }
                    } catch {}
                }
                return $true
            }
        }
        return $false
    } catch { return $false }
}

# 点击通知 → 打开对应 VS Code 项目
if ($cwd) { $launchUrl = 'vscode://file/' + ($cwd -replace '\\', '/') } else { $launchUrl = '' }

# ================= Notification 事件：需要用户操作 =================
if ($event -eq 'Notification') {
    if ($ntype -eq 'permission_prompt' -or $ntype -eq 'elicitation_dialog') {
        try {
            $ts = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
            Set-Content -Path $pendFile -Value "$ts|$genId|$proj" -Encoding UTF8
        } catch {}
        Send-Toast "有命令待你确认" "【$proj】" $launchUrl "confirm"
        Write-Log "Notification: $proj type=$ntype -> 已通知待确认"
    } else {
        Write-Log "Notification: $proj type=$ntype -> 忽略"
    }
    exit 0
}

if ($event -ne 'Stop') { exit 0 }

# ================= Stop 事件 =================
# 等一小会儿，给 Notification hook 先写标记的机会
# 仅在已有 pending 标记时才稍等一下（真实环境 Notification 几乎不触发，不做无谓等待）
if (Test-Path $pendFile) { Start-Sleep -Milliseconds 150 }

# loop 重入（hook 让 agent 继续跑）不算完成
if ($stopActive) { Write-Log "Stop: $proj 跳过(loop重入)"; exit 0 }

# 8 秒内收到过 permission_prompt → 静默（Notification 已发通知）
$suppressed = $false
try {
    if (Test-Path $pendFile) {
        $line = (Get-Content $pendFile -Encoding UTF8 -First 1)
        $parts = $line -split '\|'
        if ($parts.Count -ge 2) {
            $age = [DateTimeOffset]::Now.ToUnixTimeMilliseconds() - [int64]$parts[0]
            if ($age -lt 8000) { $suppressed = $true }
        }
        Remove-Item $pendFile -Force -ErrorAction SilentlyContinue
    }
} catch {}

if ($suppressed) { Write-Log "Stop: $proj 跳过(Notification已通知)"; exit 0 }

# 读日志判断：agent 是"真干完了"还是"卡在等你确认"
$waiting = Test-WaitingConfirm $proj

# VS Code 在前台 → 用户正看着编辑器，不打扰。但仍然照常写日志，便于事后排查。
$focused = Test-VSCodeFocused
$focusTag = ''
if ($focused) { $focusTag = '(前台静默)' }

if ($waiting) {
    Write-Log "Stop: $proj | cwd=$cwd -> 等待用户确认$focusTag"
    if (-not $focused) { Send-Toast "有命令待你确认，已暂停" "【$proj】" $launchUrl "confirm" }
    exit 0
}

# 真·任务完成
# 节流：同项目 5 秒内不重复弹（多轮对话连续结束时避免轰炸）
$allowToast = $true
try {
    $throttleFile = Join-Path $temp "cbh-thr-$safeProj.txt"
    if (Test-Path $throttleFile) {
        $lastTs = [int64]((Get-Content $throttleFile -Raw -Encoding UTF8).Trim())
        if ([DateTimeOffset]::Now.ToUnixTimeMilliseconds() - $lastTs -lt 5000) { $allowToast = $false }
    }
} catch { $throttleFile = $null }

$dur = Get-TaskDuration $proj
$skipTag = ''
if (-not $allowToast) { $skipTag = '(节流跳过)' }
if (-not $notifyOnComplete) { $skipTag = $skipTag + '(配置关闭)' }
Write-Log "Stop: $proj | cwd=$cwd -> 完成$dur$skipTag$focusTag"

if ($allowToast -and -not $focused -and $notifyOnComplete) {
    # 只有真的弹了通知才消耗节流窗口
    if ($throttleFile) { try { Set-Content -Path $throttleFile -Value ([DateTimeOffset]::Now.ToUnixTimeMilliseconds()) -Encoding UTF8 } catch {} }
    Send-Toast "任务执行完成$dur" "【$proj】" $launchUrl "done"
}

# 状态文件，供扩展去重
try {
    $ts = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
    Add-Content -Path $stateFile -Value "$ts|$proj" -Encoding UTF8
    $all = @(Get-Content $stateFile -Encoding UTF8)
    if ($all.Count -gt 20) { $all[-20..-1] | Set-Content -Path $stateFile -Encoding UTF8 }
} catch {}

exit 0
