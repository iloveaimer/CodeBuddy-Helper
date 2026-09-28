# CodeBuddy Helper 安装脚本（Windows / PowerShell 5.1+）
# 用法: 双击 install.bat，或 powershell -NoProfile -ExecutionPolicy Bypass -File install.ps1
$ErrorActionPreference = 'Stop'
$src = Split-Path -Parent $MyInvocation.MyCommand.Path
# 扩展 ID 必须与 package.json 的 publisher + name 一致，否则装完校验不到（verify.ps1 第 3 节查这一条）
$extId = 'iloveaimer.codebuddy-helper'
# 1.2.10 之前的安装用的是 local.codebuddy-helper。两个 ID 并存时会出现两个实例各自轮询日志、
# 各自弹通知 —— 用起来就是"每条通知弹两遍"，所以装新版前要先把旧 ID 卸掉
$oldId = 'local.codebuddy-helper'
$cbId = 'tencent-cloud.coding-copilot'

function Say-Cyan($s) { Write-Host $s -ForegroundColor Cyan }
function Say-Ok($s)   { Write-Host ('  ' + $s) -ForegroundColor Green }
function Say-Warn($s) { Write-Host ('  ' + $s) -ForegroundColor Yellow }
function Say-Err($s)  { Write-Host ('  ' + $s) -ForegroundColor Red }

# 列出所有可能的 VS Code 命令行入口。
# PATH 上的 code 最省事，但全新机器上通常没有，所以常见安装位置都得兜住。
function Get-CodeClis {
    $list = New-Object System.Collections.ArrayList
    $onPath = Get-Command code -ErrorAction SilentlyContinue
    if ($onPath) { [void]$list.Add($onPath.Source) }
    # 必须先判空再 Join-Path：${env:ProgramFiles(x86)} 在 32 位系统上是空字符串，
    # 而 Join-Path 的 -Path 不接受空值会抛终止性错误 —— 第 3 行设了
    # $ErrorActionPreference = 'Stop'，脚本会直接死在这一行，连提示都没有。
    # 四个变体都要列：正式版 / Insiders × ProgramFiles / ProgramFiles(x86)。
    $cands = @()
    foreach ($pf in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if (-not $pf) { continue }
        $cands += (Join-Path $pf 'Microsoft VS Code\bin\code.cmd')
        $cands += (Join-Path $pf 'Microsoft VS Code Insiders\bin\code-insiders.cmd')
    }
    if ($env:LOCALAPPDATA) {
        $cands += (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code\bin\code.cmd')
        $cands += (Join-Path $env:LOCALAPPDATA 'Programs\Microsoft VS Code Insiders\bin\code-insiders.cmd')
    }
    foreach ($p in $cands) {
        if ($p -and (Test-Path $p) -and -not $list.Contains($p)) { [void]$list.Add($p) }
    }
    return $list
}

# VS Code 可以同时装好几个变体（正式版 / Insiders），各有独立的扩展目录。
# 装到 CodeBuddy 不在的那个变体上等于没装，所以先挑真正装了 CodeBuddy 的那个。
function Select-CodeCli($clis) {
    foreach ($c in $clis) {
        try {
            $exts = @(& $c --list-extensions 2>$null)
            if ($exts -contains $cbId) { return @{ cli = $c; hasCb = $true } }
        } catch {}
    }
    if ($clis.Count -gt 0) { return @{ cli = $clis[0]; hasCb = $false } }
    return $null
}

Write-Host ''
Say-Cyan '  CodeBuddy Helper 安装'
Say-Cyan '  ====================='
Write-Host '  给 CodeBuddy 的任务通知加速：完成即刻弹 Windows 通知，429 / 5xx 自动重试。'
Write-Host '  注意：CodeBuddy 本身必须先装好，本插件是配合它的。'

Write-Host ''
Say-Cyan '[1/4] 查找 VS Code'
$clis = Get-CodeClis
if ($clis.Count -eq 0) {
    Say-Err '没找到 VS Code 的命令行工具 code。'
    Write-Host ''
    Write-Host '  改用这个办法（不需要命令行）：'
    Write-Host '    1. 打开 VS Code'
    Write-Host '    2. 扩展面板 → 右上角 "..." → 从 VSIX 安装...'
    Write-Host '    3. 选择 dist\CodeBuddy-Helper.vsix'
    exit 1
}
foreach ($c in $clis) { Write-Host ('  - ' + $c) }
$pick = Select-CodeCli $clis
$cli = $pick.cli
Write-Host ('  使用: ' + $cli)
if ($pick.hasCb) {
    Say-Ok '这个 VS Code 里装了 CodeBuddy'
} else {
    Say-Warn ('没在任何 VS Code 里找到 CodeBuddy（' + $cbId + '）')
    Say-Warn '请先装好 CodeBuddy，否则本插件弹不出通知'
}

Write-Host ''
Say-Cyan '[2/4] 打包'
$vsix = Join-Path $src 'dist\CodeBuddy-Helper.vsix'
$pkgScript = Join-Path $src 'package-vsix.ps1'
if (Test-Path $pkgScript) {
    & $pkgScript
    if (-not (Test-Path $vsix)) { Say-Err '打包没有产出 vsix'; exit 1 }
} elseif (Test-Path $vsix) {
    Say-Ok '没有源码，直接用现成的 vsix'
} else {
    Say-Err ('既没有 package-vsix.ps1，也没有 ' + $vsix)
    exit 1
}

Write-Host ''
Say-Cyan '[3/4] 安装扩展'
# 先把旧 ID 卸掉：两个 ID 并存时会有两个实例各自轮询日志、各自弹通知 —— 每条通知弹两遍
$before = @(& $cli --list-extensions 2>$null)
if ($before -contains $oldId) {
    & $cli --uninstall-extension $oldId 2>$null | Out-Null
    Say-Ok ('已卸载旧 ID 版本：' + $oldId)
}
& $cli --install-extension $vsix --force
if ($LASTEXITCODE -ne 0) { Say-Err '安装失败，见上面的输出'; exit 1 }

Write-Host ''
Say-Cyan '[4/4] 校验'
$exts = @(& $cli --list-extensions 2>$null)
if ($exts -contains $extId) { Say-Ok ($extId + ' 已安装') }
else { Say-Warn ('已装列表里没有 ' + $extId + '，重启 VS Code 后再确认一次') }

Write-Host ''
Write-Host '  安装完成。接下来只做一次：' -ForegroundColor Green
Write-Host '    1. 完全退出并重启 VS Code（Reload Window 不够）'
Write-Host '    2. 插件激活时会自动把通知 hook 写进 %USERPROFILE%\.codebuddy\settings.json'
Write-Host '       写之前先备份成 settings.json.bak；你原有的插件开关和 hook 都不会被动'
Write-Host '    3. 重开一个 CodeBuddy 会话（hook 是会话开始时读取的）'
Write-Host ''
Write-Host '  验证: 命令面板 Ctrl+Shift+P → "CodeBuddy Helper: 测试通知"'
Write-Host '  排错: 命令面板 → "CodeBuddy Helper: 显示运行日志"'
Write-Host ''