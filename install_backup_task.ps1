# Registers the backup task with Task Scheduler. Needs administrator rights,
# so it asks for them itself (UAC): run it once from a normal PowerShell.
#   powershell -ExecutionPolicy Bypass -File "C:\0github\sitehub\install_backup_task.ps1"

$task = 'SiteHub backups'
$script = Join-Path $PSScriptRoot 'backup_all.ps1'

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`""
    )
    return
}

# The task runs as the logged-on user: the share credentials and the Docker
# Desktop session belong to that account.
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument "-NoProfile -ExecutionPolicy Bypass -File `"$script`""
$triggers = @(New-ScheduledTaskTrigger -AtLogOn)
$unlock = New-CimInstance -CimClass (Get-CimClass -Namespace root/Microsoft/Windows/TaskScheduler `
    -ClassName MSFT_TaskSessionStateChangeTrigger) -ClientOnly
$unlock.StateChange = 8   # session unlock, i.e. an RDP reconnect to an open session
$triggers += $unlock
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" -LogonType Interactive
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 6)

Register-ScheduledTask $task -Action $action -Trigger $triggers -Principal $principal `
    -Settings $settings -Force | Out-Null
Get-ScheduledTask $task | Select-Object TaskName, State
Read-Host 'Task registered. Press Enter to close this window'
