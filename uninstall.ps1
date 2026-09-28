# CodeBuddy Helper 卸载脚本（Windows / PowerShell 5.1+）
# 用法: 双击 uninstall.bat，或 powershell -NoProfile -ExecutionPolicy Bypass -File uninstall.ps1
#
# 顺序不能反：先清 hook，再卸扩展。反过来的话 settings.json 里会留一条指向已删脚本的
# hook，CodeBuddy 之后每次 Stop 都会去跑一个不存在的文件。
$ErrorActionPreference = 'Continue'
$extId = 'local.codebuddy-helper'
$settings = Join-Path $env:USERPROFILE '.codebuddy\settings.json'

function Say-Ok($s)   { Write-Host ('  ' + $s) -ForegroundColor Green }
function Say-Warn($s) { Write-Host ('  ' + $s) -ForegroundColor Yellow }
function Say-Cyan($s) { Write-Host $s -ForegroundColor Cyan }

Write-Host ''
Say-Cyan '  CodeBuddy Helper 卸载'
Say-Cyan '  ====================='

# ---------- 1. 清 hook ----------
Write-Host ''
Say-Cyan '[1/4] 清理 settings.json 里的 hook'
$removed = 0
if (Test-Path $settings) {
    $sc = $null
    try { $sc = Get-Content $settings -Raw -Encoding UTF8 | ConvertFrom-Json }
    catch { Say-Warn ('settings.json 解析失败，跳过清理: ' + $_.Exception.Message) }

    if ($sc -and $sc.hooks) {
        $newHooks = [ordered]@{}
        foreach ($ev in @($sc.hooks.PSObject.Properties)) {
            $groups = @()
            foreach ($g in @($ev.Value)) {
                $kept = @()
                foreach ($h in @($g.hooks)) {
                    if ([string]$h.command -like '*cb-hook.ps1*') { $removed++ }
                    else { $kept += $h }
                }
                if ($kept.Count -gt 0) { $g.hooks = $kept; $groups += $g }
            }
            if ($groups.Count -gt 0) { $newHooks[$ev.Name] = $groups }
        }
        if ($removed -gt 0) {
            Copy-Item $settings ($settings + '.bak') -Force
            if ($newHooks.Count -gt 0) { $sc.hooks = [pscustomobject]$newHooks }
            else { $sc.PSObject.Properties.Remove('hooks') }   # 一条不剩就把整个键去掉，别留个空壳
            # 必须写成无 BOM 的 UTF-8：JSON.parse 不认开头的 BOM，
            # 而 Set-Content -Encoding UTF8 在 PowerShell 5.1 下会加上 BOM
            $json = $sc | ConvertTo-Json -Depth 32
            [System.IO.File]::WriteAllText($settings, $json, (New-Object System.Text.UTF8Encoding($false)))
        }
    }
}
if ($removed -eq 0) { Say-Ok '没有需要清理的 hook' }
else { Say-Ok ('已移除 ' + $removed + ' 条 hook，原文件备份为 settings.json.bak') }

# ---------- 2. 卸扩展 ----------
Write-Host ''
Say-Cyan '[2/4] 卸载扩展'
# 与 install.ps1 里的查找逻辑故意重复：两个脚本都要能单独执行，不互相依赖
$cli = $null
$onPath = Get-Command code -ErrorAction SilentlyContinue
if ($onPath) { $cli = $onPath.Source }
else {
    # 与 install.ps1 同样的判空：${env:ProgramFiles(x86)} 可能为空，Join-Path 会抛。
    # 变体也列全，否则装在 Insiders 里的人卸不掉。
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
    foreach ($p in $cands) { if (Test-Path $p) { $cli = $p; break } }
}

if ($cli) {
    & $cli --uninstall-extension $extId 2>$null
    if ($LASTEXITCODE -eq 0) { Say-Ok ('已通过 ' + $cli + ' 卸载') }
    else { Say-Warn '卸载命令返回非零，可能本来就没装，继续清理残留目录' }
} else {
    Say-Warn '没找到 VS Code 的命令行工具，改为直接删扩展目录'
}

# ---------- 3. 清通知来源注册 ----------
# 这两项都是本插件自己建的（扩展激活时注册，不注册的话 Toast 会显示成"未知程序"）。
# 不清的话，开始菜单里会留一个指向 powershell.exe 的 CBH 快捷方式 —— 点了会开一个
# PowerShell 窗口，没人知道那是什么。
Write-Host ''
Say-Cyan '[3/4] 清理通知来源注册'
$regGone = 0
$lnk = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\CBH.lnk'
if (Test-Path $lnk) {
    Remove-Item $lnk -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path $lnk)) { Say-Ok '已删除开始菜单里的 CBH 快捷方式'; $regGone++ }
}
$regKey = 'HKCU:\Software\Classes\AppUserModelId\CBH'
if (Test-Path $regKey) {
    Remove-Item $regKey -Recurse -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path $regKey)) { Say-Ok '已删除通知来源注册表项'; $regGone++ }
}
if ($regGone -eq 0) { Say-Ok '没有需要清理的通知来源注册' }

# ---------- 4. 清残留目录 ----------
Write-Host ''
Say-Cyan '[4/4] 清理残留目录'
$n = 0
foreach ($r in @(
    (Join-Path $env:USERPROFILE '.vscode\extensions'),
    (Join-Path $env:USERPROFILE '.vscode-insiders\extensions')
)) {
    if (-not (Test-Path $r)) { continue }
    foreach ($d in @(Get-ChildItem $r -Directory -Filter 'local.codebuddy-helper*' -ErrorAction SilentlyContinue)) {
        Remove-Item $d.FullName -Recurse -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path $d.FullName)) { Say-Ok ('已删除 ' + $d.Name); $n++ }
    }
}
if ($n -eq 0) { Say-Ok '没有残留目录' }

Write-Host ''
Write-Host '  卸载完成。重启 VS Code 生效。' -ForegroundColor Green
Write-Host ''
Write-Host '  下面这些东西属于你的数据，没有删除：'
Write-Host '    %USERPROFILE%\.codebuddy-helper\sounds    自定义通知音效'
Write-Host '    %TEMP%\cbh-*                              运行期临时文件，系统会自行清理'
Write-Host ''