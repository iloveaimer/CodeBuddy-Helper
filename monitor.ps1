$ErrorActionPreference = 'Continue'
$logDir = "$env:LOCALAPPDATA\CodeBuddyExtension\Logs\VSCode"
$last = @{}
$cd = 0

$appId = 'CBH'
$rk = "HKCU:\Software\Classes\AppUserModelId\$appId"
if (-not (Test-Path $rk)) {
    New-Item $rk -Force | Out-Null
    Set-ItemProperty $rk -Name DisplayName -Value 'CBH' -Force
}
$lk = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\CBH.lnk"
if (-not (Test-Path $lk)) {
    $ws = New-Object -ComObject WScript.Shell
    $sc = $ws.CreateShortcut($lk)
    $sc.TargetPath = 'powershell.exe'
    $sc.Save()
}

[Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] > $null
[Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom, ContentType = WindowsRuntime] > $null

function Toast($t, $m) {
    try {
        $x = New-Object Windows.Data.Xml.Dom.XmlDocument
        $x.LoadXml("$t$m")
        $n = [Windows.UI.Notifications.ToastNotification]::new($x)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($n)
    } catch {}
}

$today = Join-Path $logDir (Get-Date -Format 'yyyy-MM-dd')
if (Test-Path $today) {
    Get-ChildItem "$today\*.log" | ForEach-Object { $last[$_.FullName] = $_.Length }
}

Toast '<toast><visual><binding template="ToastGeneric"><text>' '【Monitor】Started</text></binding></visual></toast>'

while ($true) {
    try {
        $today = Join-Path $logDir (Get-Date -Format 'yyyy-MM-dd')
        if (Test-Path $today) {
            Get-ChildItem "$today\*.log" -ErrorAction SilentlyContinue | ForEach-Object {
                $fp = $_.FullName
                $sz = $_.Length
                $prev = if ($last[$fp]) { $last[$fp] } else { 0 }
                if ($sz -gt $prev) {
                    $tail = Get-Content $fp -Tail 100 -Encoding UTF8 -ErrorAction SilentlyContinue
                    $c = [string]::Join("`n", $tail)
                    $last[$fp] = $sz
                    $p = ($_.BaseName -split '__')[0]
                    if ($c -match 'notifyAllStepsEnd') {
                        Write-Host "$(Get-Date -Format HH:mm:ss) [$p] Done"
                        Toast '<toast><visual><binding template="ToastGeneric"><text>' ('【' + $p + '】Task done</text></binding></visual></toast>')
                    }
                    if ($c -match 'HTTP 429') {
                        $n = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
                        if ($n -ge $cd) {
                            $cd = $n + 30000
                            Write-Host "$(Get-Date -Format HH:mm:ss) [$p] 429"
                            Toast '<toast><visual><binding template="ToastGeneric"><text>' ('【' + $p + '】Rate limit</text></binding></visual></toast>')
                        }
                    }
                }
            }
        }
    } catch {}
    Start-Sleep -Seconds 1
}