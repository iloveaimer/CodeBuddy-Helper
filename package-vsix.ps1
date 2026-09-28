$ErrorActionPreference = "Stop"
$src = Split-Path -Parent $MyInvocation.MyCommand.Path
$tmpDir = Join-Path $env:TEMP "cb-vsix"
# 产物落在项目内的 dist\，不写桌面：桌面路径可能被 OneDrive 重定向，
# 而且"发给人"的场景下没人愿意去桌面翻文件
$dist = Join-Path $src "dist"

Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path "$tmpDir\extension" -Force | Out-Null

# 版本/名称一律取自 package.json，不在这里另写一份，否则两边迟早对不上
$pkg = Get-Content "$src\package.json" -Raw -Encoding UTF8 | ConvertFrom-Json

# 引擎下限也从 package.json 推（^1.80.0 → 1.80.0）：上面那句"不另写一份"这里同样适用
$minVer = '1.80.0'
if ($pkg.engines -and $pkg.engines.vscode) {
    $mv = [regex]::Match([string]$pkg.engines.vscode, '\d+(\.\d+){1,3}')
    if ($mv.Success) { $minVer = $mv.Value }
}

Copy-Item "$src\package.json" "$tmpDir\extension\" -Force
Copy-Item "$src\extension.js" "$tmpDir\extension\" -Force
# hook 脚本必须跟着进包：扩展本身只做轮询与注册，通知全靠这两个脚本
Copy-Item "$src\cb-hook.ps1" "$tmpDir\extension\" -Force
Copy-Item "$src\cb-sound.ps1" "$tmpDir\extension\" -Force
# README 与 LICENSE 也要进包：VS Code 的扩展详情页读的就是扩展目录里的 README.md，
# 不带的话那一页是空的；LICENSE 是 MIT 要求随附的副本。
# 它们不进下面的 Assets —— 那里只列 manifest 和入口文件，多出来的文件 VS Code 会直接忽略。
Copy-Item "$src\README.md" "$tmpDir\extension\" -Force
Copy-Item "$src\README.en.md" "$tmpDir\extension\" -Force
Copy-Item "$src\LICENSE" "$tmpDir\extension\" -Force
# 图标同样要进包：扩展列表和详情页读的是扩展目录里的 icon.png（package.json 的 icon 字段）
Copy-Item "$src\icon.png" "$tmpDir\extension\" -Force

@"
<?xml version="1.0" encoding="utf-8"?>
<PackageManifest Version="2.0.0" xmlns="http://schemas.microsoft.com/developer/vsx-schema/2011">
  <Metadata>
    <Identity Id="$($pkg.name)" Version="$($pkg.version)" Publisher="$($pkg.publisher)" />
    <DisplayName>$($pkg.displayName)</DisplayName>
    <Description>$($pkg.description)</Description>
  </Metadata>
  <Installation>
    <InstallationTarget Id="Microsoft.VisualStudio.Code" Version="[$minVer,)" />
  </Installation>
  <Dependencies/>
  <Assets>
    <Asset Type="Microsoft.VisualStudio.Code.Manifest" Path="extension/package.json" />
    <Asset Type="Microsoft.VisualStudio.Code.Extension" Path="extension/extension.js" />
    <Asset Type="Microsoft.VisualStudio.Code.Extension" Path="extension/cb-hook.ps1" />
    <Asset Type="Microsoft.VisualStudio.Code.Extension" Path="extension/cb-sound.ps1" />
  </Assets>
</PackageManifest>
"@ | Set-Content "$tmpDir\extension.vsixmanifest" -Encoding UTF8

Set-Content -Path "$tmpDir\c" -Value @"
<?xml version="1.0" encoding="utf-8"?>
<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
  <Default Extension="vsixmanifest" ContentType="text/xml" />
  <Default Extension="json" ContentType="application/json" />
  <Default Extension="js" ContentType="application/javascript" />
  <Default Extension="ps1" ContentType="application/octet-stream" />
  <Default Extension="md" ContentType="text/markdown" />
  <Default Extension="png" ContentType="image/png" />
  <Override PartName="/extension/LICENSE" ContentType="text/plain" />
</Types>
"@ -Encoding UTF8
Rename-Item "$tmpDir\c" "[Content_Types].xml"

New-Item -ItemType Directory -Path $dist -Force | Out-Null
$zipPath = Join-Path $env:TEMP "cb-helper.zip"
$vsixPath = Join-Path $dist "CodeBuddy-Helper.vsix"
Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
Remove-Item $vsixPath -Force -ErrorAction SilentlyContinue
Compress-Archive -Path "$tmpDir\*" -DestinationPath $zipPath -Force
Move-Item $zipPath $vsixPath -Force
Remove-Item $tmpDir -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host ("打包完成: " + $vsixPath)
Write-Host ("版本:     " + $pkg.version)
Write-Host ("大小:     " + [math]::Round((Get-Item $vsixPath).Length / 1KB, 1) + " KB")
Write-Host ""
Write-Host "装自己机器: 运行 install.bat"
Write-Host "发给别人  : 把上面这个 vsix 发过去，对方双击即可安装"