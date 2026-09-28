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
$pendFile = Join-Path $temp 'cbh-hook-pending.txt'
$soundsDir = Join-Path $env:USERPROFILE '.codebuddy-helper\sounds'
$soundPlayer = Join-Path $PSScriptRoot 'cb-sound.ps1'

# 项目名要当文件名用，统一在这里清洗。扩展侧必须有同一套规则，
# 否则扩展按 cbh-path-<项目名>.txt 取项目路径会找不到文件。
function Get-SafeName($n) { return ($n -replace '[\\/:*?"<>|]', '_') }

# ---------- 解析 payload ----------
$event = ''
$proj = 'CodeBuddy'
$safeProj = 'CodeBuddy'
$cwd = ''
$ntype = ''
$genId = ''
$stopActive = $false
$isTest = $false

try {
    if ($json) {
        $o = $json | ConvertFrom-Json
        if ($o.hook_event_name) { $event = [string]$o.hook_event_name }
        # 扩展的"测试通知"命令用这个 session_id 进来
        if ($o.session_id -eq 'cbh-test') { $isTest = $true }
        if ($o.notification_type) { $ntype = [string]$o.notification_type }
        if ($o.generation_id) { $genId = [string]$o.generation_id }
        if ($o.stop_hook_active) { $stopActive = [bool]$o.stop_hook_active }
        if ($o.cwd) {
            $cwd = [string]$o.cwd
            $leaf = Split-Path $cwd -Leaf
            if ($leaf) { $proj = $leaf }
        }
        $safeProj = Get-SafeName $proj
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

# ---------- 原始 payload 转储（排查用，保留最后 200 行） ----------
# 放在 UserPromptSubmit 提前返回之后：那条路径用户每发一条消息都触发，
# 不该为它做一次全量读 + 全量重写。
function Write-RawDump($text) {
    try {
        # prompt 原文不入盘：它可能含源码、路径、密钥，而这个文件是要贴进 issue 的
        $line = $text -replace '"prompt"\s*:\s*"(?:[^"\\]|\\.)*"', '"prompt":"<已省略>"'
        if ($line.Length -gt 500) { $line = $line.Substring(0, 500) + '…(已截断)' }
        Add-Content -Path $rawFile -Value ((Get-Date -Format 'HH:mm:ss') + ' ' + $line) -Encoding UTF8
        $raw = @(Get-Content $rawFile -Encoding UTF8)
        if ($raw.Count -gt 200) { $raw[-200..-1] | Set-Content -Path $rawFile -Encoding UTF8 }
    } catch {}
}
Write-RawDump $json

# ---------- 用户配置（由扩展导出成文件；读不到就用默认值，配置读取出问题不能影响通知主流程） ----------
$cfgFile = Join-Path $temp 'cbh-config.json'
$notifyOnComplete = $true
# 通知来源标识。改它要连带改扩展侧的注册表/快捷方式，所以由扩展写进配置，这里不另写一份
$aumid = 'CBH'
try {
    if (Test-Path $cfgFile) {
        $c = Get-Content $cfgFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($null -ne $c.notifyOnComplete) { $notifyOnComplete = [bool]$c.notifyOnComplete }
        if ($c.aumid) { $aumid = [string]$c.aumid }
    }
} catch {}

function Write-Log($s) {
    try { Add-Content -Path $logFile -Value ((Get-Date -Format 'HH:mm:ss') + ' ' + $s) -Encoding UTF8 } catch {}
}

# ---------- 当前任务所在项目是否正被用户看着 ----------
# 扩展维护 %TEMP%\cbh-focus-<pid>.txt，格式：<1|0>|<工作区路径>[;<路径>...]（1=该窗口在前台）。
# 只有"前台的那个窗口装的正是任务所在项目"时才静默：多窗口并行时用户在别的窗口干活，
# 任务照样跑完，这时必须弹通知，否则完成通知会被静默光。
# 旧格式（裸 1，扩展还没重载）一律忽略：宁可多弹一条，也不能漏掉完成通知。
function Test-ProjectFocused($projectPath) {
    if (-not $projectPath) { return $false }
    $cur = ($projectPath -replace '\\', '/').TrimEnd('/')
    try {
        $focusFiles = @(Get-ChildItem -Path $temp -Filter 'cbh-focus-*.txt' -ErrorAction SilentlyContinue)
        foreach ($ff in $focusFiles) {
            # 超过 5 分钟没更新的视为失效（扩展已退出）
            if (((Get-Date) - $ff.LastWriteTime).TotalMinutes -gt 5) { continue }
            $line = (Get-Content $ff.FullName -Raw -Encoding UTF8).Trim()
            $bar = $line.IndexOf('|')
            if ($bar -lt 1) { continue }
            if ($line.Substring(0, $bar) -ne '1') { continue }
            foreach ($ws in $line.Substring($bar + 1).Split(';')) {
                $w = $ws.Trim().TrimEnd('/')
                if (-not $w) { continue }
                # 任务可能跑在工作区的子目录里，所以路径相等或在其之下都算
                if ($cur -eq $w) { return $true }
                if ($cur.StartsWith($w + '/', [StringComparison]::OrdinalIgnoreCase)) { return $true }
            }
        }
    } catch {}
    return $false
}

# ---------- 任务耗时（依赖 UserPromptSubmit 记录的起点） ----------
function Get-TaskDuration($projName) {
    try {
        $sp = Get-SafeName $projName
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
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($aumid).Show($toast)

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

# ---------- 定位本项目当天的日志，返回其中的日志行 ----------
# 判"卡在等确认"和判"出错中断"共用这一份定位逻辑。
# 日志文件名是 <项目名>__<32位hex>.log，必须按 __ 边界匹配：
# 只写 ($projName + '*') 的话，App 会连 AppServer 的日志一起匹配 ——
# 那就会把别的项目的 needConfirm 当成这个项目卡在等确认。
# 找不到本项目的日志就返回空：宁可漏报，也不能张冠李戴。
function Get-ProjectLogLines($projName) {
    $lines = New-Object System.Collections.ArrayList
    try {
        # CBH_LOG_ROOT 仅用于本地测试覆盖
        if ($env:CBH_LOG_ROOT) { $logRoot = $env:CBH_LOG_ROOT }
        else { $logRoot = Join-Path $env:LOCALAPPDATA 'CodeBuddyExtension\Logs\VSCode' }
        if (-not (Test-Path $logRoot)) { return $lines }
        $dayDir = Join-Path $logRoot (Get-Date -Format 'yyyy-MM-dd')
        if (-not (Test-Path $dayDir)) { return $lines }

        $files = @(Get-ChildItem -Path $dayDir -Filter '*.log' -ErrorAction SilentlyContinue)
        if ($files.Count -eq 0) { return $lines }

        $target = $files | Where-Object { $_.Name -like ($projName + '__*') } | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $target) { return $lines }

        $tail = Read-Tail $target.FullName 262144
        if (-not $tail) { return $lines }

        # 只保留真正的日志行（以 [yyyy/M/d H:mm:ss.fff] 开头）。
        # 否则会匹配到写进日志里的脚本源码文本（自指污染），导致误判。
        foreach ($ln in ($tail -split "`r?`n")) {
            if ($ln -match '^\[\d{4}/\d+/\d+ \d+:\d+:\d+(\.\d+)?\]') { [void]$lines.Add($ln) }
        }
    } catch {}
    return $lines
}

# ---------- 判断是否卡在"等待用户确认" ----------
# 依据 CodeBuddy 日志：
#   [beforeExecute] Permission decision: source=safety_rule_ask, allowed=true, needConfirm=true   ← 请求用户确认
#   [AcpAgent:xxx] Permission response: approved=true, ...                                        ← 用户已响应
# 若最后一条 needConfirm=true 晚于最后一条 Permission response → 仍在等待用户确认
function Test-WaitingConfirm($projName) {
    try {
        $logLines = @(Get-ProjectLogLines $projName)
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

# ---------- 判断这次 Stop 是"真干完了"还是"出错中断" ----------
# 撞上服务端错误（429 / 5xx / 内容审核拦截）时，CodeBuddy 自己只内部重试 1 次就收尾，
# 日志里留下 onStepError，界面上是个"处理过程出现异常，请重试"的弹框。
# 这种 Stop 不算完成：再弹一条"任务执行完成"会和那个弹框互相矛盾，
# 用户会把失败当成跑完了（实测 08:57:58 报错、08:58:33 弹"完成 · 4m46s"）。
# 从尾部往前扫，遇到的第一个"结局信号"决定结论。
# run end 两种结局都写，所以不能拿它当信号。
function Test-FailedEnd($projName) {
    try {
        $logLines = @(Get-ProjectLogLines $projName)
        if ($logLines.Count -eq 0) { return $false }

        for ($i = $logLines.Count - 1; $i -ge 0; $i--) {
            $ln = $logLines[$i]

            # 正常收尾。扩展自动补的重试跑通后尾部会补上这条，
            # 那次 Stop 就该按完成算
            if ($ln -match 'notifyAllStepsEnd' -or $ln -match 'onAllStepsEnd') { return $false }

            # 出错收尾
            if ($ln -match 'onStepError' -or $ln -match 'fullStream error part detected') {
                # 新鲜度校验：太久远的是历史遗留，不能拿它给这次 Stop 定案。
                # 宁可偶尔把失败说成完成，也不能因为扫到一条旧错误就不弹完成通知。
                $m = [regex]::Match($ln, '^\[(\d{4}/\d+/\d+ \d+:\d+:\d+)')
                if ($m.Success) {
                    try {
                        $t = [datetime]::ParseExact($m.Groups[1].Value, 'yyyy/M/d HH:mm:ss', $null)
                        if (((Get-Date) - $t).TotalMinutes -gt 5) { return $false }
                    } catch {}
                }
                return $true
            }
        }
        return $false
    } catch { return $false }
}

# 点击通知 → 打开对应 VS Code 项目。
# 两个都会让点击"看着没反应"的坑：
#   1) 文件夹 URL 必须带结尾 /，官方格式是 vscode://file/{full path to project}/
#   2) 路径必须 percent-encode：含 # 会被当成片段截断，含 % 会被当成转义
function Get-LaunchUrl($p) {
    if (-not $p) { return '' }
    $s = ($p -replace '\\', '/')
    # EscapeDataString 会把分隔符和盘符冒号一并编码，再还原回来
    $e = [System.Uri]::EscapeDataString($s) -replace '%2F', '/' -replace '%3A', ':'
    if (-not $e.EndsWith('/')) { $e = $e + '/' }
    return 'vscode://file/' + $e
}

$launchUrl = Get-LaunchUrl $cwd

# 项目根目录落盘给扩展用。扩展按日志文件名认项目，文件名里只有项目名、没有全路径，
# 拿不到路径就没法让通知点开对应项目。
if ($cwd -and $safeProj) {
    # 必须 BOM-less UTF-8：路径可能含中文，扩展按 UTF-8 读，
    # 而 Set-Content -Encoding UTF8 在 PowerShell 5.1 下会带 BOM
    try {
        [System.IO.File]::WriteAllText((Join-Path $temp "cbh-path-$safeProj.txt"), $cwd, (New-Object System.Text.UTF8Encoding($false)))
    } catch {}
}

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

# 正看着任务所在的那个 VS Code 窗口 → 不打扰。但仍然照常写日志，便于事后排查。
$focused = Test-ProjectFocused $cwd
# 测试通知不受前台静默影响。要测的人当然正看着 VS Code，静默掉的话，
# 用户点了"测试通知"什么也看不到，只会以为装失败了
if ($isTest) { $focused = $false }
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
    # 测试通知同样不受节流限制
    if (-not $isTest -and (Test-Path $throttleFile)) {
        $lastTs = [int64]((Get-Content $throttleFile -Raw -Encoding UTF8).Trim())
        if ([DateTimeOffset]::Now.ToUnixTimeMilliseconds() - $lastTs -lt 5000) { $allowToast = $false }
    }
} catch { $throttleFile = $null }

$dur = Get-TaskDuration $proj
$willToast = $allowToast -and -not $focused -and $notifyOnComplete

# 只在真要弹的时候才读日志：Stop 每次都触发，为它多读 256KB 不值得，
# 而"节流跳过 / 前台静默 / 配置关闭"这三种情况下弹不弹已经定了，读了也没处用。
$failed = $false
if ($willToast) { $failed = Test-FailedEnd $proj }

$skipTag = ''
if (-not $allowToast) { $skipTag = '(节流跳过)' }
if (-not $notifyOnComplete) { $skipTag = $skipTag + '(配置关闭)' }
if ($failed) {
    Write-Log "Stop: $proj | cwd=$cwd -> 中断(服务端错误，退出的那步没跑完)$dur$skipTag$focusTag"
} else {
    Write-Log "Stop: $proj | cwd=$cwd -> 完成$dur$skipTag$focusTag"
}

if ($willToast) {
    # 只有真的弹了通知才消耗节流窗口。测试通知不算，否则紧接着来的真实通知会被它挤掉
    if ($throttleFile -and -not $isTest) { try { Set-Content -Path $throttleFile -Value ([DateTimeOffset]::Now.ToUnixTimeMilliseconds()) -Encoding UTF8 } catch {} }
    if ($failed) {
        # 用 confirm 音：任务没跑完，需要人看一眼，不是完成音
        Send-Toast "任务中断，未正常完成$dur" "【$proj】" $launchUrl "confirm"
    } else {
        Send-Toast "任务执行完成$dur" "【$proj】" $launchUrl "done"
    }
}

exit 0
