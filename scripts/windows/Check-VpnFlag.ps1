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
        $flag = $candidate
    }
    catch {
        Write-Log "Flag read failed: $($_.Exception.Message)"
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
