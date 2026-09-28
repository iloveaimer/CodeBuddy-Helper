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
Head '[1/7] 编码：.ps1 的 BOM 与 .bat 的纯 ASCII'
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
Head '[2/7] PowerShell 语法'
Get-ChildItem $src -Filter *.ps1 -File | Sort-Object Name | ForEach-Object {
    $err = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$err)
    if (@($err).Count -gt 0) { Bad ($_.Name + ': ' + @($err)[0].Message) }
    else { Good ($_.Name + ': 解析通过') }
}

# ---------------------------------------------------------------
Head '[3/7] package.json'
$pkgPath = Join-Path $src 'package.json'
$pkg = $null
try {
    $pkg = Get-Content $pkgPath -Raw -Encoding UTF8 | ConvertFrom-Json
    Good '合法的 JSON'
    Good ('版本 ' + $pkg.version)
} catch { Bad ('解析失败: ' + $_.Exception.Message) }

# install.ps1 / uninstall.ps1 里各硬编码了一份扩展 ID。改了 publisher 忘改它们的话，
# 装完 `code --list-extensions` 永远校验不到（脚本只会提示"重启后再确认一次"）。
# 1.2.10 把 publisher 从 local 改成 iloveaimer 时就是这么暴露出来的。
if ($pkg) {
    $wantId = [string]$pkg.publisher + '.' + [string]$pkg.name
    $instText = Get-Content (Join-Path $src 'install.ps1') -Raw -Encoding UTF8
    $uninText = Get-Content (Join-Path $src 'uninstall.ps1') -Raw -Encoding UTF8
    if ($instText.Contains($wantId) -and $uninText.Contains($wantId)) {
        Good ('install/uninstall 里的扩展 ID 与 package.json 一致（' + $wantId + '）')
    } else {
        Bad ('install/uninstall 里的扩展 ID 与 package.json 不一致，应为 ' + $wantId + '：装了也校验不到')
    }
}

# ---------------------------------------------------------------
Head '[4/7] 打包并核对 VSIX 内容'
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
                            'extension\cb-sound.ps1', 'extension\README.md', 'extension\LICENSE',
                            'extension\icon.png', 'extension.vsixmanifest', '[Content_Types].xml')) {
            if (Test-Path -LiteralPath (Join-Path $tmp $need)) { Good ('包内含 ' + $need) }
            else { Bad ('包里缺 ' + $need) }
        }

        # 图标三件事都得对：package.json 里声明了 icon、文件在包里、而且是 128×128 的 PNG。
        # 尺寸不合规时 VS Code 直接不显示图标，什么错都不报，只会看到一个默认灰块。
        $icoSrc = Join-Path $src 'icon.png'
        if (-not $pkg -or -not $pkg.icon) { Bad 'package.json 没声明 icon，扩展列表里会显示成默认灰块' }
        elseif (-not (Test-Path -LiteralPath $icoSrc)) { Bad ('package.json 声明了 icon = ' + $pkg.icon + '，但文件不存在') }
        else {
            Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue
            try {
                $img = [System.Drawing.Image]::FromFile($icoSrc)
                if ($img.Width -eq 128 -and $img.Height -eq 128) { Good 'icon.png 是 128×128 的 PNG' }
                else { Bad ('icon.png 尺寸应为 128×128，实际 ' + $img.Width + 'x' + $img.Height) }
                $img.Dispose()
            } catch { Bad ('icon.png 不是可读的图片: ' + $_.Exception.Message) }
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
Head '[5/7] 源码里不该出现的个人痕迹'
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

# hook 的原始 payload 转储是让人贴进 issue 的：prompt 原文（可能含源码、路径、密钥）
# 不能入盘，否则等于要求用户把整段对话内容公开出去
$rawHook = [System.IO.File]::ReadAllText((Join-Path $src 'cb-hook.ps1'), [System.Text.Encoding]::UTF8)
if ($rawHook -match 'prompt.{0,12}已省略') { Good 'cb-hook.ps1 转储 payload 时会隐去 prompt 原文' }
else { Bad 'cb-hook.ps1 把 prompt 原文写进了 %TEMP%\cbh-hook-raw.log，而该文件会被贴进 issue' }

# ---------------------------------------------------------------
Head '[6/7] 私有工作记忆有没有被 git 跟踪'
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
Head '[7/7] 通知链路：不重复、不指错、能弹能点'
# 点击跳转靠 Toast 的 launch 属性。缺了它，通知照样弹得出来，但被点击时没有任何反应、
# 也不报任何错，只能靠检查提前拦住。两条通知路径各拼各的 XML，都要查。
$hookText = [System.IO.File]::ReadAllText((Join-Path $src 'cb-hook.ps1'), [System.Text.Encoding]::UTF8)
$jsText = [System.IO.File]::ReadAllText((Join-Path $src 'extension.js'), [System.Text.Encoding]::UTF8)

# hook 侧：把函数原样抠出来执行，用带中文和空格的路径验编码与结尾斜杠。
# 用 AST 定位函数体，不用正则：正则一遇到重排格式（比如在闭括号那行末尾加个注释）
# 就匹配不到，会报"找不到 Get-LaunchUrl"这种假失败。
$fnAst = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $src 'cb-hook.ps1'), [ref]$null, [ref]$null).FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-LaunchUrl' }, $true) | Select-Object -First 1
if ($fnAst) {
    try {
        Invoke-Expression $fnAst.Extent.Text
        $u = Get-LaunchUrl 'd:/测试 目录/项目'
        $why = @()
        if ($u -notmatch '^vscode://file/d:/') { $why += '前缀不对' }
        if (-not $u.EndsWith('/')) { $why += '结尾缺 /，VS Code 会按文件打开' }
        if ($u -match '[^\x00-\x7F]') { $why += '还有没编码的非 ASCII 字符' }
        if ($u -match ' ') { $why += '还有没编码的空格' }
        if ($why.Count -gt 0) { Bad ('cb-hook.ps1 的项目地址有问题: ' + ($why -join '; ') + '  ->  ' + $u) }
        else { Good 'cb-hook.ps1 的项目地址格式正确' }
    } catch { Bad ('cb-hook.ps1 项目地址执行失败: ' + $_.Exception.Message) }
} else { Bad 'cb-hook.ps1 里找不到 Get-LaunchUrl' }

# 扩展侧是另一条独立的 Toast 拼装路径，最容易漏掉 launch —— 漏了就点了没反应
if ($jsText -match 'activationType="protocol"') { Good 'extension.js 的通知带跳转属性' }
else { Bad 'extension.js 的通知没有 launch，被点击时不会有任何反应' }
if ($jsText -match 'function projectUrl') { Good 'extension.js 有项目地址解析' }
else { Bad 'extension.js 缺 projectUrl，通知指不到对应项目' }

# 「测试通知」走的是真实 hook 链路，会被"前台静默"吃掉——可点这个命令的人当然正看着 VS Code。
# 结果是照 README 验证安装的人什么也看不到，以为装失败了。所以测试会话必须被认得。
if ($hookText -match "'cbh-test'" -and $hookText -match '\$isTest') {
    Good 'cb-hook.ps1 认得测试会话（测试通知不会被前台静默吃掉）'
} else {
    Bad 'cb-hook.ps1 不认得测试会话，测试通知会被前台静默吃掉'
}

# 前台静默若按「任意一个窗口前台」判定，多窗口并行时（本机实测 6 个窗口、7 个焦点文件）
# 用户在 B 窗口干活、A 窗口的项目跑完就会被静默掉，完成通知再也收不到。必须按任务所在项目判定。
if ($hookText -match 'function Test-ProjectFocused' -and $hookText -match 'Test-ProjectFocused \$cwd') {
    Good 'cb-hook.ps1 按任务所在项目判定前台静默（多窗口不会误静默）'
} else {
    Bad 'cb-hook.ps1 的前台判定退回按任意窗口了，多窗口下完成通知会被误静默'
}
if ($jsText -match 'wsPaths') {
    Good 'extension.js 上报焦点时带上了本窗口的工作区路径'
} else {
    Bad 'extension.js 没上报工作区路径，hook 无法判断任务是否就在前台那个窗口'
}

# 前台静默会把"人正盯着那个窗口"时的完成通知吃掉，用户只会当成插件没反应。
# 默认改成盯着也弹，由 notifyWhenFocused 开关决定；静默是在 hook 里判的，
# 所以配置必须两端都接上（扩展写进 cbh-config.json，hook 读出来）。
if ($hookText -match 'notifyWhenFocused' -and $jsText -match 'notifyWhenFocused') {
    Good '前台「盯着也弹」开关两端都接上了'
} else {
    Bad 'notifyWhenFocused 只实现了一侧，前台静默仍会吃掉完成通知'
}

# 提示音要在插件里能改：设置里有两个字符串项，「选择提示音」命令负责挑文件并写设置。
# 扩展把值导进 cbh-config.json、hook 读出来播放 —— 只接一头的话，用户在设置里改完毫无反应，
# 而且不会报任何错，最难查的那种。
if ($jsText -match 'soundFor' -and $jsText -match 'codebuddyHelper\.pickSound' -and
    $hookText -match 'soundDone' -and $hookText -match 'soundConfirm') {
    Good '提示音能在设置/命令里改，且扩展与 hook 两端都接了'
} else {
    Bad '提示音的配置没接全：在设置里改了不会生效'
}

# 横幅可能被 Windows「专注助手 / 勿扰」直接收走，任务栏闪烁是那种情况下唯一还能被察觉的提示。
# 两条通知路径都要有：只做 hook 那条的话，「429 重试进度」这类扩展发的通知在勿扰下就完全看不见了。
if ($hookText -match 'Flash-Taskbar' -and $jsText -match 'FlashWindowEx') {
    Good '任务栏闪烁两条通知路径都有（专注助手拦掉横幅时的兜底）'
} else {
    Bad '任务栏闪烁只做了一条通知路径，另一条在勿扰下会完全看不见'
}

# 还有一类限流把码写在尖括号里（`<429> InternalError.Algo: ... [Rate limit reached]`）：
# 行里既没有 HTTP 也没有 statusCode，实测 13 次，只认前两条规则会整条漏掉。
if ($jsText -match 'angleM' -and $jsText.Contains('<429')) {
    Good 'extension.js 认得尖括号形式的错误码（<429> InternalError…）'
} else {
    Bad 'extension.js 漏掉尖括号形式的限流错误（<429> InternalError…）'
}

# 日志目录是当天所有项目共用的（实测同时有 5 个项目的日志）。不按本窗口项目筛的话：
# ① A 窗口会把 B 项目的错误重试进 A 的会话；② 每个窗口各弹一次同样的通知。
if ($jsText -match 'function localProjects' -and $jsText -match 'mine\.includes') {
    Good 'extension.js 只处理本窗口打开的项目'
} else {
    Bad 'extension.js 会处理其它项目的日志：重试会发错会话，通知会重复'
}

# 内容审核拦截（InternalError.Algo.DataInspectionFailed）整行没有 HTTP 字样，
# 只认 HTTP (429|5xx) 的话这类错误永远不会被重试——而 CodeBuddy 自己只内部重试 1 次，
# 失败就弹「处理过程出现异常」干等用户点。errLabel 保证它显示成「内容审核拦截」
# 而不是把内部代号 inspect 当 HTTP 码露给用户。
if ($jsText -match 'DataInspectionFailed') {
    if ($jsText -match 'errLabel') {
        Good 'extension.js 认得内容审核拦截并自动续跑（不露内部错误代号）'
    } else {
        Bad 'extension.js 认得内容审核拦截但没做文案转换，通知里会显示内部代号'
    }
} else {
    Bad 'extension.js 不认得内容审核拦截，这类错误只会弹「处理过程出现异常」而不自动重试'
}

# 「服务出现异常，请重试」（错误码 500）在日志里是「后端服务响应状态码异常」，整行同样没有 HTTP
# 字样，码在相邻行的 statusCode: 500 / errorCode=500 / "code":500 里。只认 HTTP 的话这一类
# 全部漏掉（实测 2026-09-20 08:55、08:56 同一个项目连撞两次 500，扩展和没装一样）。
# srv 是"一条码都取不到"时的兜底代号，由 errLabel 显示成「服务端异常」，不外露内部代号。
if ($jsText -match '后端服务响应状态码异常' -and $jsText -match 'statusCode' -and $jsText -match 'srv') {
    Good 'extension.js 认得「后端服务响应状态码异常」并自动续跑'
} else {
    Bad 'extension.js 不认得「后端服务响应状态码异常」：500 类弹框不会自动重试'
}

# 日志文件名是 <项目名>__<32位hex>.log。按 ($projName + '*') 匹配会让 App 命中 AppServer，
# 把别的项目的 needConfirm 当成这个项目卡在等确认
if ($hookText.Contains("__*")) { Good 'cb-hook.ps1 按 __ 边界匹配本项目日志' }
else { Bad 'cb-hook.ps1 的项目日志匹配没有 __ 边界，项目名互为前缀时会认错项目' }

# 撞上服务端错误（429 / 5xx / 内容审核拦截）时，CodeBuddy 只内部重试 1 次就收尾，
# 日志里留下 onStepError，界面上是「处理过程出现异常，请重试」。这时 Stop 照样触发，
# 再弹一条「任务执行完成」就和那个弹框互相矛盾，用户会把失败当成跑完
# （实测 08:57:58 报错、08:58:33 弹"完成 · 4m46s"）。
# 跑完写 notifyAllStepsEnd、出错写 onStepError；run end 两种都写，拿它当信号必然误判。
if ($hookText -match 'function Test-FailedEnd' -and $hookText -match 'onStepError' -and $hookText -match 'notifyAllStepsEnd') {
    Good 'cb-hook.ps1 区分「跑完」与「出错中断」，中断时不会误弹完成'
} else {
    Bad 'cb-hook.ps1 不区分完成与中断：服务端报错后仍会弹「任务执行完成」'
}
if ($hookText -match '任务中断，未正常完成') {
    Good 'cb-hook.ps1 中断时的通知文案与完成分开'
} else {
    Bad 'cb-hook.ps1 中断时没换文案，用户分不清是跑完还是失败'
}

# 「等待确认」的三条提醒路径各自只响一次：hook 的 Notification 弹确认框时一次、hook 的 Stop
# 任务暂停时一次（Stop 不是心跳，同一项目停下后不会再触发第二次）、扩展兜底一次。
# 而 CodeBuddy 自身没有确认超时（日志里查不到任何 permission 超时或自动拒绝机制），
# 任务会无限期停在 waiting_user_input、agent 原地闲着。所以必须有一条补提醒兜底。
if ($jsText -match 'CONFIRM_REMIND' -and $jsText -match '仍在等你确认') {
    Good 'extension.js 漏看「待确认」后会补一次提醒'
} else {
    Bad 'extension.js 的待确认提醒只有一次，用户漏看后任务会一直挂着'
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