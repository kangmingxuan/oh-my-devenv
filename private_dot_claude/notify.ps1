param(
    [string]$Message = "任务结束"
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

$notification = New-Object System.Windows.Forms.NotifyIcon
try {
    $notification.Icon = [System.Drawing.SystemIcons]::Information
    $notification.Visible = $true
    $notification.BalloonTipIcon = [System.Windows.Forms.ToolTipIcon]::Info
    $notification.BalloonTipTitle = "Claude Code"
    $notification.BalloonTipText = $Message
    $notification.ShowBalloonTip(5000)
    Start-Sleep -Seconds 6
}
finally {
    $notification.Dispose()
}
