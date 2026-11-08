#Requires -Version 5.1
# SiteHub VPN trigger: reads the permission flag from Ubuntu and drives the
# SoftEther VPN client and the portable AnyDesk on this Windows machine.
#
# Flag values (see README):
#    0  - VPN off, AnyDesk stopped
#   -1  - VPN always on
#   -2  - emergency: portable AnyDesk started, VPN state unchanged
#    N  - VPN allowed until Unix time N, AnyDesk stopped
#
# The scheduled task runs this script as SYSTEM once a minute. When the flag
# cannot be read, the last successfully read value is used.

$ErrorActionPreference = "Stop"

$Dir = "C:\ProgramData\VpnTrigger"
$VpnConnectionName = "Ubuntu-Backup"
$VpnCmd = "C:\Program Files\SoftEther VPN Client\vpncmd_x64.exe"
$Ssh = "$env:WINDIR\System32\OpenSSH\ssh.exe"
$AnyDeskExe = "$Dir\AnyDesk.exe"
$AnyDeskTaskName = "SiteHub-AnyDeskEmergency"
# Optional: pin the account that owns the interactive session. Empty means
# detect the console user, then an RDP user through explorer.exe.
$AnyDeskUser = ""

# Last successfully read flag: a mode marker or a Unix deadline.
$StateFile = "$Dir\allowed-until.txt"
$LogFile = "$Dir\watch.log"

function Write-Log {
    param([string]$Message)

    if ((Test-Path $LogFile) -and
        (Get-Item $LogFile).Length -gt 1MB) {
        Move-Item $LogFile "$LogFile.1" -Force
    }

    Add-Content -Path $LogFile -Encoding UTF8 -Value (
        "{0} {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    )
}

function Invoke-Tool {
    param(
        [string]$File,
        [string]$Arguments,
        [int]$TimeoutSeconds = 15
    )

    $info = New-Object System.Diagnostics.ProcessStartInfo
    $info.FileName = $File
    $info.Arguments = $Arguments
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $info

    try {
        [void]$process.Start()
        $process.StandardInput.Close()

        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()

        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $process.Kill()
            $process.WaitForExit()
            throw "Timeout: $File"
        }

        $process.WaitForExit()

        return [pscustomobject]@{
            Code = $process.ExitCode
            Out  = $stdout.Result.Trim()
            Err  = $stderr.Result.Trim()
        }
    }
    finally {
        $process.Dispose()
    }
}

function Get-AnyDeskProcess {
    $processName = [IO.Path]::GetFileNameWithoutExtension($AnyDeskExe)

    @(
        Get-Process -Name $processName -ErrorAction SilentlyContinue |
            Where-Object {
                try { $_.Path -eq $AnyDeskExe }
                catch { $false }
            }
    )
}

# Win32_ComputerSystem reports the console session only, so an RDP login is
# invisible there. The shell process of the session does expose its owner.
function Get-InteractiveUser {
    if (-not [string]::IsNullOrWhiteSpace($AnyDeskUser)) {
        return $AnyDeskUser
    }

    $consoleUser = (Get-CimInstance Win32_ComputerSystem -ErrorAction SilentlyContinue).UserName
    if (-not [string]::IsNullOrWhiteSpace($consoleUser)) {
        return $consoleUser
    }

    $shell = Get-Process explorer -IncludeUserName -ErrorAction SilentlyContinue |
        Where-Object {
            $_.SessionId -ne 0 -and
            -not [string]::IsNullOrWhiteSpace($_.UserName)
        } |
        Sort-Object SessionId -Descending |
        Select-Object -First 1

    if ($shell) {
        return $shell.UserName
    }

    return $null
}

# A portable AnyDesk is an interactive GUI app: started by a SYSTEM task it
# lands in session 0 and exits at once. Register a one-shot task for the
# logged-on user and start that; the process then belongs to their session.
function Start-AnyDesk {
    if ((Get-AnyDeskProcess).Count -gt 0) {
        return
    }
    if (-not (Test-Path $AnyDeskExe)) {
        throw "AnyDesk not found: $AnyDeskExe"
    }

    # A task prepared in advance already knows its user; then no detection is
    # needed at all, which is the reliable path for an RDP-only session.
    $task = Get-ScheduledTask -TaskName $AnyDeskTaskName -ErrorAction SilentlyContinue

    if (-not $task) {
        $user = Get-InteractiveUser
        if ([string]::IsNullOrWhiteSpace($user)) {
            throw "No interactive user is logged on; set `$AnyDeskUser or create the ${AnyDeskTaskName} task in advance"
        }

        $action = New-ScheduledTaskAction -Execute $AnyDeskExe -WorkingDirectory $Dir
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Highest
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
            -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew `
            -ExecutionTimeLimit ([TimeSpan]::Zero)

        Register-ScheduledTask -TaskName $AnyDeskTaskName -Action $action `
            -Principal $principal -Settings $settings -Force | Out-Null
    }
    else {
        $user = $task.Principal.UserId
    }

    Start-ScheduledTask -TaskName $AnyDeskTaskName

    # Give AnyDesk time to initialize and catch a launcher that exits at once.
    Start-Sleep -Seconds 2
    $deadline = (Get-Date).AddSeconds(10)
    while ((Get-Date) -lt $deadline) {
        if ((Get-AnyDeskProcess).Count -gt 0) {
            Write-Log "AnyDesk started in the interactive session of ${user}"
            return
        }
        Start-Sleep -Milliseconds 500
    }

    $info = Get-ScheduledTaskInfo -TaskName $AnyDeskTaskName -ErrorAction SilentlyContinue
    $result = if ($info) { $info.LastTaskResult } else { "unknown" }
    throw "AnyDesk did not start (task result ${result}); check that a user is logged on"
}

function Stop-AnyDesk {
    $running = @(Get-AnyDeskProcess)
    if ($running.Count -gt 0) {
        $running | Stop-Process -Force
        Write-Log "AnyDesk stopped: flag is no longer -2"
    }

    # The one-shot task is recreated on the next -2, so do not leave it behind.
    if (Get-ScheduledTask -TaskName $AnyDeskTaskName -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask -TaskName $AnyDeskTaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $AnyDeskTaskName -Confirm:$false -ErrorAction SilentlyContinue
    }
}

try {
    if ([string]::IsNullOrWhiteSpace($VpnConnectionName)) {
        throw "VPN connection name is empty."
    }

    if ($VpnConnectionName -match '["\r\n]') {
        throw "Invalid VPN connection name."
    }

    # Last successfully read flag.
    [long]$flag = 0

    if (Test-Path $StateFile) {
        $saved = (Get-Content $StateFile -Raw).Trim()

        if ($saved -match '^-?[0-9]{1,11}$') {
            $flag = [long]$saved
        }
    }

    # Read the flag. If SSH fails, keep the previously saved value: a cached
    # -1 keeps the VPN on, a cached -2 keeps AnyDesk running.
    try {
        $reply = Invoke-Tool -File $Ssh -Arguments (
            '-F "{0}\ssh_config" vpn-trigger read-flag' -f $Dir
        )

        if ($reply.Code -ne 0) {
            throw "SSH exit=$($reply.Code): $($reply.Err)"
        }

        if ($reply.Out -notmatch '^-?[0-9]{1,11}$') {
            throw "Invalid flag response"
        }

        [long]$candidate = [long]$reply.Out
        [long]$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

        # A positive deadline can be at most four hours ahead. An extra
        # minute allows for a small clock difference.
        if ($candidate -gt ($now + 14460)) {
            throw "Deadline too far in future; check system clocks"
        }

        [IO.File]::WriteAllText("$StateFile.tmp", [string]$candidate)
        Move-Item "$StateFile.tmp" $StateFile -Force
        $flag = $candidate
    }
    catch {
        Write-Log "Flag read failed: $($_.Exception.Message)"
    }

    # -2 is an AnyDesk-only mode: do not touch a working VPN.
    if ($flag -eq -2) {
        Start-AnyDesk
        exit 0
    }

    Stop-AnyDesk

    if (-not (Test-Path $VpnCmd)) {
        throw "vpncmd.exe not found: $VpnCmd"
    }

    [long]$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $vpnOn = ($flag -eq -1) -or (($flag -gt 0) -and ($flag -gt $now))

    if ($vpnOn) {
        $command = "AccountConnect"
        $alreadyInDesiredState = 35
    }
    else {
        $command = "AccountDisconnect"
        $alreadyInDesiredState = 37
    }

    $vpnArguments = 'localhost /CLIENT /PROGRAMMING /CMD {0} "{1}"' -f `
        $command, $VpnConnectionName

    $result = Invoke-Tool -File $VpnCmd -Arguments $vpnArguments

    if ($result.Code -eq 0) {
        if ($command -eq "AccountConnect") {
            if ($flag -eq -1) {
                Write-Log "VPN connect requested; always on"
            }
            else {
                $deadline = [DateTimeOffset]::FromUnixTimeSeconds($flag).ToLocalTime().ToString(
                    "yyyy-MM-dd HH:mm:ss zzz"
                )
                Write-Log "VPN connect requested; allowed until $deadline"
            }
        }
        else {
            Write-Log "VPN disconnected: permission disabled or expired"
        }
    }
    elseif ($result.Code -eq $alreadyInDesiredState) {
        # No state change: do not write to the log.
    }
    else {
        $details = (
            "$($result.Out) $($result.Err)" -replace '\s+', ' '
        ).Trim()

        throw "$command failed: exit=$($result.Code); $details"
    }

    exit 0
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    exit 1
}
