# CodeBuddy Helper 音效播放器
# 用法: powershell -File cb-sound.ps1 "<音频文件路径>"
# 独立子进程运行，避免阻塞 hook
param([string]$Path)

$ErrorActionPreference = 'SilentlyContinue'

if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { exit 1 }

$ext = [System.IO.Path]::GetExtension($Path).ToLower()

# WAV：SoundPlayer 最轻量可靠（同步播放，进程退出前播完）
if ($ext -eq '.wav') {
    try {
        $p = New-Object System.Media.SoundPlayer $Path
        $p.PlaySync()
        exit 0
    } catch {}
}

# 其他格式（mp3/m4a/wma/aac/flac/ogg）：WPF MediaPlayer
try {
    Add-Type -AssemblyName PresentationCore
    $m = New-Object System.Windows.Media.MediaPlayer
    $m.Open([uri]$Path)
    $m.Play()
    # 等时长元数据就绪（最多 3 秒）
    $waited = 0
    while ($waited -lt 3000 -and -not $m.NaturalDuration.HasTimeSpan) {
        Start-Sleep -Milliseconds 100
        $waited += 100
    }
    $ms = 3000
    if ($m.NaturalDuration.HasTimeSpan) {
        $ms = [Math]::Min([int]$m.NaturalDuration.TimeSpan.TotalMilliseconds, 20000)
    }
    Start-Sleep -Milliseconds $ms
    $m.Close()
} catch {}

exit 0
