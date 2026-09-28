# CodeBuddy Helper 发布前自检
# 用法: powershell -NoProfile -ExecutionPolicy Bypass -File verify.ps1
#
# 这里检查的每一条，都是实际踩过的坑。改完代码跑一遍，比翻 git log 找教训划算。
$ErrorActionPreference = 'Stop'
$src = Split-Path -Parent $MyInvocation.MyCommand.Path

$script:pass = 0
$script:fail = 0
function Good($m) { $script:pass++; Write-Host ('  [OK]   ' + $m) -ForegroundColor Green }
function Bad($m)  { $script:fail++; Write-Host ('  [FAIL] ' + $m) -ForegroundColor Red }
function Head($m) { Write-Host ''; Write-Host $m -ForegroundColor Cyan }

# 读取文件的编码特征。注意 BOM 本身是 U+FEFF，算非 ASCII 字符，
# 判断"内容里有没有非 ASCII"时必须先把它剥掉，否则纯 ASCII 文件加了 BOM 会被误判。
function Get-Info($path) {
    $bytes = [System.IO.File]::ReadAllBytes($path)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $text = [System.Text.Encoding]::UTF8.GetString($bytes)
    if ($hasBom) { $text = $text.Substring(1) }
    return @{
        HasBom   = $hasBom
        NonAscii = ($text -match '[^\x00-\x7F]')
    }
}

Write-Host ''
Write-Host '  CodeBuddy Helper 发布前自检' -ForegroundColor Cyan
Write-Host '  ============================' -ForegroundColor Cyan

# ---------------------------------------------------------------
Head '[1/6] 编码：.ps1 的 BOM 与 .bat 的纯 ASCII'
# PowerShell 5.1 读没有 BOM 的 .ps1 时按系统 ANSI 码页解码。中文变乱码，
# 更糟的是 CJK 标点被拆开的字节会吞掉紧跟其后的 ASCII 引号，字符串永不闭合，
# 整个脚本语法报错。.bat 反过来：cmd 按 OEM 码页读，BOM 会被当成命令的一部分。
Get-ChildItem $src -Filter *.ps1 -File | Sort-Object Name | ForEach-Object {
    $i = Get-Info $_.FullName
    if ($i.NonAscii -and -not $i.HasBom) { Bad ($_.Name + ': 含非 ASCII 却没有 BOM，PowerShell 5.1 会按 ANSI 码页解码') }
    else { Good ($_.Name + ': 编码正确') }
}
Get-ChildItem $src -Filter *.bat -File | Sort-Object Name | ForEach-Object {
    $i = Get-Info $_.FullName
    if ($i.HasBom) { Bad ($_.Name + ': .bat 不能有 BOM，cmd 会把 BOM 当成命令的一部分') }
    elseif ($i.NonAscii) { Bad ($_.Name + ': .bat 必须纯 ASCII，cmd 按 OEM 码页读会乱') }
    else { Good ($_.Name + ': 编码正确') }
}

# ---------------------------------------------------------------
Head '[2/6] PowerShell 语法'
Get-ChildItem $src -Filter *.ps1 -File | Sort-Object Name | ForEach-Object {
    $err = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$err)
    if (@($err).Count -gt 0) { Bad ($_.Name + ': ' + @($err)[0].Message) }
    else { Good ($_.Name + ': 解析通过') }
}

# ---------------------------------------------------------------
Head '[3/6] package.json'
$pkgPath = Join-Path $src 'package.json'
$pkg = $null
try {
    $pkg = Get-Content $pkgPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Good '合法的 JSON'
    Good ('版本 ' + $pkg.version)
} catch { Bad ('解析失败: ' + $_.Exception.Message) }

# ---------------------------------------------------------------
Head '[4/6] 打包并核对 VSIX 内容'
# hook 脚本漏进包是真实发生过的：扩展只负责轮询和注册，通知全靠 cb-hook.ps1，
# 它不在包里的话，换台机器通知会完全失效。
$vsix = Join-Path $src 'dist\CodeBuddy-Helper.vsix'
try {
    & (Join-Path $src 'package-vsix.ps1') *>&1 | Out-Null
    if (Test-Path -LiteralPath $vsix) { Good '打包产出 vsix' } else { Bad '打包没有产出 vsix' }
} catch { Bad ('打包失败: ' + $_.Exception.Message) }

if (Test-Path -LiteralPath $vsix) {
    $tmp = Join-Path $env:TEMP ('cbh-verify-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    $zip = $tmp + '.zip'
    try {
        Copy-Item -LiteralPath $vsix -Destination $zip -Force
        New-Item -ItemType Directory -Path $tmp -Force | Out-Null
        Expand-Archive -LiteralPath $zip -DestinationPath $tmp -Force

        # 必须用 -LiteralPath：[] 在 PowerShell 路径里是通配符，[Content_Types].xml 会匹配不到
        foreach ($need in @('extension\extension.js', 'extension\package.json', 'extension\cb-hook.ps1',
                            'extension\cb-sound.ps1', 'extension.vsixmanifest', '[Content_Types].xml')) {
            if (Test-Path -LiteralPath (Join-Path $tmp $need)) { Good ('包内含 ' + $need) }
            else { Bad ('包里缺 ' + $need) }
        }

        # 包里的脚本必须和源文件逐字节一致，否则等于装了个旧版本
        foreach ($f in @('extension.js', 'cb-hook.ps1', 'cb-sound.ps1')) {
            $inZip = Join-Path $tmp ('extension\' + $f)
            if (-not (Test-Path -LiteralPath $inZip)) { continue }
            $h1 = (Get-FileHash -LiteralPath $inZip -Algorithm MD5).Hash
            $h2 = (Get-FileHash -LiteralPath (Join-Path $src $f) -Algorithm MD5).Hash
            if ($h1 -eq $h2) { Good ($f + ': 与源文件一致') } else { Bad ($f + ': 与源文件不一致') }
        }

        # manifest 的版本必须跟 package.json 一致，否则升级安装会被当成不同版本
        $mf = Join-Path $tmp 'extension.vsixmanifest'
        if ((Test-Path -LiteralPath $mf) -and $pkg) {
            $x = Get-Content -LiteralPath $mf -Raw -Encoding UTF8
            if ($x -match ('Version="' + [regex]::Escape($pkg.version) + '"')) { Good 'manifest 版本与 package.json 一致' }
            else { Bad 'manifest 版本与 package.json 对不上' }
            if ($x -match ('Publisher="' + [regex]::Escape($pkg.publisher) + '"')) { Good 'manifest 发布者一致' }
            else { Bad 'manifest 发布者与 package.json 对不上' }
        }
    } catch { Bad ('核对 VSIX 内容失败: ' + $_.Exception.Message) }
    finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    }
}

# ---------------------------------------------------------------
Head '[5/6] 源码里不该出现的个人痕迹'
# 本机用户名、个人目录会随着 C:\Users\<名字> 这类路径泄进公开仓库
$scanExt = @('.md', '.js', '.json', '.ps1', '.bat', '.yml', '.yaml', '.txt')
$skipDir = @('.git', '.codebuddy', 'dist', 'node_modules')
$hits = @()
Get-ChildItem $src -Recurse -File | Where-Object {
    $scanExt -contains $_.Extension.ToLower() -and
    -not ($_.FullName.Substring($src.Length).Split('\') | Where-Object { $skipDir -contains $_ })
} | ForEach-Object {
    # 跳过本脚本：下面那两个模式本身就写在它里面
    if ($_.Name -eq 'verify.ps1') { return }
    $t = [System.IO.File]::ReadAllText($_.FullName, [System.Text.Encoding]::UTF8)
    # 只匹配真正的路径形态。光出现 OneDrive 这个词是正常的 —— 文档里就在解释
    # "桌面被 OneDrive 重定向" 这回事，按词匹配会把说明文字一起误报。
    if ($t -match 'C:\\Users\\[^\\/\s]+' -or $t -match '[A-Za-z]:[\\/][^\s]*OneDrive') {
        $hits += $_.FullName.Substring($src.Length).TrimStart('\')
    }
}
if ($hits.Count -eq 0) { Good '没有发现本机用户目录或个人路径' }
else { $hits | ForEach-Object { Bad ('含个人路径: ' + $_) } }

# ---------------------------------------------------------------
Head '[6/6] 私有工作记忆有没有被 git 跟踪'
# .codebuddy/ 里是本机各项目的工作记忆，含用户名、个人路径、其它私有项目名。
# 它被 .gitignore 忽略还不够——如果历史上已经被 add 过，ignore 是拦不住的。
if (Get-Command git -ErrorAction SilentlyContinue) {
    $tracked = @(& git -C $src ls-files)
    $bad = @($tracked | Where-Object { $_ -like '.codebuddy/*' })
    if ($bad.Count -gt 0) {
        Bad ('.codebuddy 仍被 git 跟踪，共 ' + $bad.Count + ' 个文件')
        Write-Host '         执行: git rm -r --cached .codebuddy' -ForegroundColor Yellow
    } else { Good '.codebuddy 未被跟踪' }

    $build = @($tracked | Where-Object { $_ -like 'dist/*' -or $_ -like '*.vsix' })
    if ($build.Count -gt 0) { Bad ('构建产物被跟踪: ' + ($build -join ', ')) }
    else { Good '构建产物未被跟踪' }
} else {
    Write-Host '  [跳过] 环境里没有 git' -ForegroundColor Yellow
}

# ---------------------------------------------------------------
Write-Host ''
if ($script:fail -eq 0) {
    Write-Host ('  通过 ' + $script:pass + ' 项，没有问题。') -ForegroundColor Green
} else {
    Write-Host ('  通过 ' + $script:pass + ' 项，失败 ' + $script:fail + ' 项。') -ForegroundColor Red
}
Write-Host ''
if ($script:fail -gt 0) { exit 1 } else { exit 0 }