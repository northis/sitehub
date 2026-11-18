#Requires -Version 5.1
# SiteHub VPN trigger: reads the permission flag from Ubuntu and drives the
# SoftEther VPN client and the AnyDesk service on this Windows machine.
#
# Flag values (see README):
#    0  - VPN off; AnyDesk service stopped and disabled
#   -1  - VPN always on; AnyDesk service stopped and disabled
#   -2  - emergency: AnyDesk service started (enabled if it was disabled);
#         VPN state unchanged
#    N  - VPN allowed until Unix time N; AnyDesk service stopped and disabled
#
# The scheduled task runs this script as SYSTEM once a minute. When the flag
# cannot be read, the last successfully read value is used.

$ErrorActionPreference = "Stop"

$Dir = "C:\ProgramData\VpnTrigger"
$VpnConnectionName = "Ubuntu-Backup"
$VpnCmd = "C:\Program Files\SoftEther VPN Client\vpncmd_x64.exe"
$Ssh = "$env:WINDIR\System32\OpenSSH\ssh.exe"

# Managed by name; the service installation path does not matter.
$AnyDeskService = "AnyDesk"

# Last successfully read flag: a mode marker or a Unix deadline.
$StateFile = "$Dir\allowed-until.txt"
$LogFile = "$Dir\watch.log"

# SSH outage fallback: after 10 minutes without a readable flag, use -2.
$FailureSinceFile = "$Dir\ssh-failure-since.txt"
$EmergencyMarkerFile = "$Dir\ssh-emergency.active"
$EmergencyAfterSeconds = 600

# On an SSH timeout, ask AdGuard VPN (running as the logged-on user) to connect.
$AdGuardLauncher = "C:\Program Files\AdGuardVpn\AdguardVpn.Launcher.exe"
$AdGuardArgs = '/customProtocol "adguardvpn:connect_to_preferred"'
$AdGuardTaskName = "SiteHub-AdGuardVpnConnect"
$AdGuardLaunchTaskName = "SiteHub-AdGuardVpnLaunch"
$AdGuardLaunchDelaySeconds = 10
$AdGuardLastAttemptFile = "$Dir\adguard-last-attempt.txt"
$AdGuardRetrySeconds = 600

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

function Get-AnyDeskService {
    Get-Service -Name $AnyDeskService -ErrorAction SilentlyContinue
}

# Tracks consecutive failed flag reads. Returns true once the outage has
# lasted long enough to use the emergency -2 mode.
function Update-SshFailure {
    [long]$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    [long]$since = 0

    if (Test-Path $FailureSinceFile) {
        $raw = Get-Content $FailureSinceFile -Raw -ErrorAction SilentlyContinue
        if ($raw -and $raw.Trim() -match '^[0-9]{1,11}$') {
            $since = [long]$raw.Trim()
        }
    }
    if ($since -le 0 -or $since -gt $now) {
        $since = $now
        [IO.File]::WriteAllText($FailureSinceFile, [string]$since)
    }

    $elapsed = $now - $since
    if ($elapsed -lt $EmergencyAfterSeconds) {
        return [pscustomobject]@{ Active = $false; JustStarted = $false }
    }

    $justStarted = $false
    if (-not (Test-Path $EmergencyMarkerFile)) {
        [IO.File]::WriteAllText($EmergencyMarkerFile, [string]$now)
        $minutes = [math]::Floor($elapsed / 60)
        Write-Log "SSH unavailable for $minutes minutes; using emergency -2"
        $justStarted = $true
    }
    return [pscustomobject]@{ Active = $true; JustStarted = $justStarted }
}

# Called on a successful flag read. Returns true if the emergency was active,
# so the caller can log the recovery once.
function Clear-SshFailure {
    $wasEmergency = Test-Path $EmergencyMarkerFile
    Remove-Item $FailureSinceFile, $EmergencyMarkerFile -Force -ErrorAction SilentlyContinue
    return $wasEmergency
}

# Win32_ComputerSystem reports the console session only; an RDP user is
# visible through explorer.exe in their session.
function Get-InteractiveUser {
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

# Starts an AdGuard launcher task in the interactive session of User.
function Start-AdGuardTask {
    param(
        [string]$Name,
        [string]$Argument,
        [string]$User
    )

    $actionParams = @{
        Execute = $AdGuardLauncher
        WorkingDirectory = (Split-Path $AdGuardLauncher)
    }
    if (-not [string]::IsNullOrWhiteSpace($Argument)) {
        $actionParams.Argument = $Argument
    }

    $action = New-ScheduledTaskAction @actionParams
    $principal = New-ScheduledTaskPrincipal -UserId $User `
        -LogonType Interactive -RunLevel Highest
    $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
        -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew `
        -ExecutionTimeLimit ([TimeSpan]::Zero)

    Register-ScheduledTask -TaskName $Name -Action $action `
        -Principal $principal -Settings $settings -Force | Out-Null
    Start-ScheduledTask -TaskName $Name
}

# Attempts at most once per AdGuardRetrySeconds. -Force is used when the
# outage crosses into -2, so that transition also makes an attempt.
function Start-AdGuardVpnConnect {
    param([switch]$Force)

    try {
        [long]$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        [long]$last = 0

        if (Test-Path $AdGuardLastAttemptFile) {
            $raw = Get-Content $AdGuardLastAttemptFile -Raw -ErrorAction SilentlyContinue
            if ($raw -and $raw.Trim() -match '^[0-9]{1,11}$') {
                $last = [long]$raw.Trim()
            }
        }
        if (-not $Force -and $last -gt 0 -and $last -le $now -and
            ($now - $last) -lt $AdGuardRetrySeconds) {
            return
        }

        # Record the attempt before trying, so a failed attempt also waits
        # the full interval before the next one.
        [IO.File]::WriteAllText($AdGuardLastAttemptFile, [string]$now)

        if (-not (Test-Path $AdGuardLauncher)) {
            Write-Log "AdGuard VPN launcher not found: $AdGuardLauncher"
            return
        }

        $user = Get-InteractiveUser
        if ([string]::IsNullOrWhiteSpace($user)) {
            Write-Log "No interactive user is logged on; starting AdGuard VPN as SYSTEM"
            Start-Process -FilePath $AdGuardLauncher `
                -WorkingDirectory (Split-Path $AdGuardLauncher) | Out-Null
            Start-Sleep -Seconds $AdGuardLaunchDelaySeconds
            Start-Process -FilePath $AdGuardLauncher -ArgumentList $AdGuardArgs `
                -WorkingDirectory (Split-Path $AdGuardLauncher) | Out-Null
            Write-Log "AdGuard VPN connect requested as SYSTEM"
            return
        }

        Start-AdGuardTask -Name $AdGuardLaunchTaskName -Argument "" -User $user
        Write-Log "AdGuard VPN launcher started in the session of $user; connect in $AdGuardLaunchDelaySeconds s"
        Start-Sleep -Seconds $AdGuardLaunchDelaySeconds
        Start-AdGuardTask -Name $AdGuardTaskName -Argument $AdGuardArgs -User $user
        Write-Log "AdGuard VPN connect requested in the session of $user"
    }
    catch {
        Write-Log "AdGuard VPN connect failed: $($_.Exception.Message)"
    }
}

# Called on a successful flag read to drop the one-shot tasks and their timer.
function Clear-AdGuardConnect {
    $wasRequested = Test-Path $AdGuardLastAttemptFile
    Remove-Item $AdGuardLastAttemptFile -Force -ErrorAction SilentlyContinue

    foreach ($taskName in @($AdGuardLaunchTaskName, $AdGuardTaskName)) {
        if (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue) {
            Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        }
    }
    return $wasRequested
}

# -2: start the service even if it was disabled. A disabled service cannot be
# started directly, so switch it to Manual first.
function Start-AnyDeskService {
    $service = Get-AnyDeskService
    if (-not $service) {
        throw "AnyDesk service not found: $AnyDeskService"
    }

    if ($service.StartType -eq "Disabled") {
        Set-Service -Name $AnyDeskService -StartupType Manual
        $service = Get-AnyDeskService
    }

    if ($service.Status -ne "Running") {
        Start-Service -Name $AnyDeskService

        $deadline = (Get-Date).AddSeconds(10)
        while ((Get-Date) -lt $deadline) {
            $service.Refresh()
            if ($service.Status -eq "Running") {
                break
            }
            Start-Sleep -Milliseconds 500
        }
        if ($service.Status -ne "Running") {
            throw "AnyDesk service did not start (status $($service.Status))"
        }
        Write-Log "AnyDesk service started"
    }
}

# Every value except -2: stop and disable the service, wherever it is installed.
function Disable-AnyDeskService {
    $service = Get-AnyDeskService
    if (-not $service) {
        return
    }

    if ($service.Status -ne "Stopped") {
        Stop-Service -Name $AnyDeskService -Force
        Write-Log "AnyDesk service stopped"
    }

    if ($service.StartType -ne "Disabled") {
        Set-Service -Name $AnyDeskService -StartupType Disabled
        Write-Log "AnyDesk service disabled"
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
    # -1 keeps the VPN on, a cached -2 keeps the AnyDesk service running.
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
        if (Clear-SshFailure) {
            Write-Log "SSH restored; using flag $candidate"
        }
        Clear-AdGuardConnect | Out-Null
        $flag = $candidate
    }
    catch {
        $message = $_.Exception.Message
        Write-Log "Flag read failed: $message"

        $sshState = Update-SshFailure
        if ($sshState.JustStarted) {
            Start-AdGuardVpnConnect -Force
        }
        elseif ($sshState.Active -or $message -match 'timed out|timeout') {
            Start-AdGuardVpnConnect
        }
        if ($sshState.Active) {
            $flag = -2
        }
    }

    # -2 is the AnyDesk-only mode: do not touch a working VPN.
    if ($flag -eq -2) {
        Start-AnyDeskService
        exit 0
    }

    # Every other value keeps AnyDesk off, wherever the service is installed.
    Disable-AnyDeskService

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
