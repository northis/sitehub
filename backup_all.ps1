# Incremental backups of the projects listed in .env, then upload of every archive the
# share does not have yet: nothing new means nothing is copied.
# Runs from Task Scheduler on RDP logon/unlock, or by hand.

$ErrorActionPreference = 'Stop'
$settingsFile = Join-Path $PSScriptRoot '.env'
$log = Join-Path $PSScriptRoot 'backup_all.log'
$squash = Join-Path $PSScriptRoot 'squash_backups.py'
$reserved = 'SITEHUB_BACKUP_DEST', 'SITEHUB_BACKUP_PYTHON'


function Read-Settings([string] $path) {
    # KEY=value lines, '#' starts a comment. Ordered: projects run in the order they are
    # written down.
    $settings = [ordered]@{}
    foreach ($line in Get-Content -LiteralPath $path -Encoding utf8) {
        $line = $line.Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }
        $pair = $line -split '=', 2
        if ($pair.Count -eq 2) { $settings[$pair[0].Trim()] = $pair[1].Trim() }
    }
    return $settings
}


function Read-Projects($settings) {
    # SITEHUB_BACKUP_<share folder>=<repo dir> | <backups> | <state> | <command> [| --since]
    $projects = @()
    foreach ($key in $settings.Keys) {
        if (-not $key.StartsWith('SITEHUB_BACKUP_') -or $key -in $reserved) { continue }
        $fields = @($settings[$key] -split '\|' | ForEach-Object { $_.Trim() })
        if ($fields.Count -lt 4) { throw "$key needs at least: <dir> | <backups> | <state> | <command>" }
        $projects += @{
            Name    = $key.Substring('SITEHUB_BACKUP_'.Length)
            Dir     = $fields[0]
            Backups = $fields[1]
            State   = $fields[2]
            Run     = @($fields[3] -split '\s+')
            Since   = $fields.Count -gt 4 -and $fields[4]
        }
    }
    return $projects
}


function Invoke-BackupCommand([string[]] $command) {
    # Native tools write progress to stderr, and PowerShell 5.1 turns that into a
    # terminating error under 'Stop'. Here only the exit code matters, and the output
    # belongs in the transcript.
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $command[0] $command[1..($command.Count - 1)] | Out-Host
        return $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previous
    }
}


if ((Get-Item $log -ErrorAction SilentlyContinue).Length -gt 5MB) { Remove-Item $log -Force }
Start-Transcript -Path $log -Append -ErrorAction Continue | Out-Null

try {
    if (-not (Test-Path -LiteralPath $settingsFile)) {
        Write-Warning "$settingsFile is missing; copy .env.example and fill it in"
        return
    }
    $settings = Read-Settings $settingsFile
    $dest = $settings['SITEHUB_BACKUP_DEST']
    $python = $settings['SITEHUB_BACKUP_PYTHON']
    $projects = Read-Projects $settings

    if (-not $dest -or -not $projects) {
        Write-Warning "${settingsFile}: no SITEHUB_BACKUP_DEST or no SITEHUB_BACKUP_<folder> line"
        return
    }
    if (-not $python) { Write-Warning 'SITEHUB_BACKUP_PYTHON is not set; archives are not squashed' }

    # The whole run exists to ship new data to the share: when the receiving machine is
    # down there is nothing to do, and no local archives are created behind its back.
    if (-not (Test-Path -LiteralPath $dest)) {
        Write-Warning "$dest is not reachable; no backups taken"
        return
    }

    # Docker Desktop is usually still starting when the RDP session opens.
    $dockerUp = $false
    foreach ($attempt in 1..24) {
        try {
            docker info --format '{{.ServerVersion}}' *> $null
            $dockerUp = $LASTEXITCODE -eq 0
        } catch {
            $dockerUp = $false
        }
        if ($dockerUp) { break }
        Start-Sleep -Seconds 5
    }
    if (-not $dockerUp) { Write-Warning 'Docker Desktop is not answering; the container projects will fail' }

    foreach ($project in $projects) {
        $local = Join-Path $project.Dir $project.Backups
        $remote = Join-Path $dest $project.Name
        $run = $project.Run

        if ($project.Since -and -not (Test-Path (Join-Path $local $project.State))) {
            # First run: continue from the newest archive kept here or on the share, so
            # the first archive is not the whole library.
            $newest = Get-ChildItem $local, $remote -Filter *.zip -ErrorAction SilentlyContinue |
                Sort-Object LastWriteTime | Select-Object -Last 1
            $cutoff = if ($newest) { $newest.LastWriteTime.ToString('yyyy-MM-ddTHH:mm:ss') } else { '2000-01-01' }
            $run = $run + @('--since', $cutoff)
        }

        Write-Host "== $($project.Name)"
        Push-Location $project.Dir
        try {
            $code = Invoke-BackupCommand $run
            if ($code -ne 0) { Write-Warning "$($project.Name): backup command exited $code" }
        } catch {
            Write-Warning "$($project.Name): backup failed: $_"
        } finally {
            Pop-Location
        }

        if (-not (Test-Path $local)) { continue }

        # An archive the share already has is left alone, an older copy is replaced.
        # Robocopy creates the destination folder itself. merged-* archives are made on
        # this machine after the upload: sending them would push the same gigabytes over
        # SMB a second time, and the share folds its own chain in on a weekly task.
        robocopy $local $remote *.zip *.json /XF merged-*.zip /XO /R:1 /W:1 /NFL /NDL /NJH /NJS /NP
        if ($LASTEXITCODE -ge 8) {
            Write-Warning "$($project.Name): copy to $remote failed (robocopy $LASTEXITCODE), nothing squashed"
            continue
        }
        # Bit 1 of the robocopy exit code: files were copied, so the new data is on the
        # share and the local increments can be folded into one archive.
        if ($LASTEXITCODE -band 1 -and $python -and (Test-Path -LiteralPath $squash)) {
            Write-Host "-- squashing $($project.Name)"
            $code = Invoke-BackupCommand @($python, $squash, $local, '--delete')
            if ($code -ne 0) { Write-Warning "$($project.Name): squash exited $code" }
        }
    }
} finally {
    Stop-Transcript -ErrorAction SilentlyContinue | Out-Null
}
