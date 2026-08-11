# Vault Hunters / Forge 1.18.2 server wrapper
# Forge: 1.18.2-40.3.11
#
# FEATURES
# - Uses Forge's existing user_jvm_args.txt + win_args.txt.
# - Keeps an interactive Minecraft console in this PowerShell window.
# - Restarts automatically after crashes (non-zero Java exit).
# - Daily graceful restart at the configured SERVER LOCAL TIME.
# - Warnings at 15, 5, and 1 minute before the daily restart.
# - Sends save-all flush, then stop.
# - Makes OFFLINE backups while Minecraft is stopped.
# - Crash-loop protection.
# - Wrapper events are logged to logs\server-wrapper.log.
#
# IMPORTANT
# The scheduled restart uses the Windows clock/timezone configured on the server machine.

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

# ============================================================
# CONFIGURATION
# ============================================================

$JavaExe = "java"

$JvmArgsRelative   = "user_jvm_args.txt"
$ForgeArgsRelative = "libraries\net\minecraftforge\forge\1.18.2-40.3.11\win_args.txt"

# ----- Crash restart -----
$RestartOnCrash      = $true
$RestartDelaySeconds = 10

# Stop automatic restart if the server repeatedly crashes.
$MaxCrashesInWindow = 5
$CrashWindowSeconds = 300

# ----- Daily restart -----
$EnableScheduledRestart = $true
$ScheduledRestartHour   = 4
$ScheduledRestartMinute = 0

# Automatically derived display value used in logs and Discord messages.
# Example: Hour 4 + Minute 0 = "04:00"
$ScheduledRestartTimeLabel = "{0:D2}:{1:D2}" -f $ScheduledRestartHour, $ScheduledRestartMinute

# Player warnings before the daily restart.
$RestartWarningMinutes = @(15, 5, 1)

# ----- Discord notifications -----
# Create a Discord webhook for your status channel and paste its URL below.
# Treat the URL like a password. Do not commit the real URL to a public repo.
$EnableDiscordNotifications = $true
$DiscordWebhookUrl          = ""
$DiscordWebhookUsername     = "Vault Hunters Server"
$DiscordServerName          = "Vault Hunters Remastered"

# ----- Server-ready detection -----
# Forge can print Minecraft's normal "Done (...)!" line before all
# ServerStartedEvent handlers have finished and before player logins are allowed.
#
# For this Vault Hunters pack, wait for BOTH:
#   1. Minecraft "Done (...)!"
#   2. Simple Voice Chat "Voice chat server started at port 51801"
# Then wait a small grace period before announcing SERVER ONLINE.
$ServerReadyLogPattern   = '\[voicechat\].*Voice chat server started at port 51801'
$ServerReadyGraceSeconds = 5

# ----- Backups -----
# All backups happen while Minecraft is OFFLINE.
$EnableBackupOnFirstStart       = $true
$EnableBackupOnScheduledRestart = $true
$EnableBackupOnManualStop       = $true

$BackupRoot    = "D:\Back-up\mcvh"
$MaxBackupDays = 7

# In addition to the world folder, back these up when they exist.
# Directories are supported too.
$BackupExtraPaths = @(
    "server.properties",
    "ops.json",
    "whitelist.json",
    "banned-players.json",
    "banned-ips.json",
    "user_jvm_args.txt",
    "config",
    "defaultconfigs",
    "kubejs"
)

# Pause when the wrapper finally stops.
$PauseWhenStopped = $true


# ============================================================
# INTERNAL SETUP
# ============================================================

$ServerDir     = $PSScriptRoot
$JvmArgs       = Join-Path $ServerDir $JvmArgsRelative
$ForgeArgs     = Join-Path $ServerDir $ForgeArgsRelative
$LogDir        = Join-Path $ServerDir "logs"
$WrapperLog    = Join-Path $LogDir "server-wrapper.log"
$ExtraJavaArgs = @($args)

New-Item -ItemType Directory -Path $LogDir -Force | Out-Null


function Write-WrapperLog {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [ConsoleColor]$Color = [ConsoleColor]::Gray
    )

    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Write-Host $line -ForegroundColor $Color
    Add-Content -Path $WrapperLog -Value $line -Encoding UTF8
}


function Send-DiscordNotification {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if (-not $EnableDiscordNotifications) {
        return
    }

    if ([string]::IsNullOrWhiteSpace($DiscordWebhookUrl)) {
        return
    }

    try {
        $payload = @{
            username = $DiscordWebhookUsername
            content = "**[$DiscordServerName]** $Message"
            allowed_mentions = @{
                parse = @()
            }
        } | ConvertTo-Json -Depth 5

        Invoke-RestMethod `
            -Uri $DiscordWebhookUrl `
            -Method Post `
            -ContentType "application/json" `
            -Body $payload `
            -TimeoutSec 10 | Out-Null
    }
    catch {
        # Do not include the webhook URL/token in logs.
        Write-WrapperLog "Discord notification failed: $($_.Exception.Message)" Yellow
    }
}


function Test-Requirements {
    if (-not (Test-Path $JvmArgs -PathType Leaf)) {
        throw "Missing Forge JVM argument file: $JvmArgs"
    }

    if (-not (Test-Path $ForgeArgs -PathType Leaf)) {
        throw "Missing Forge Windows argument file: $ForgeArgs"
    }

    if ($JavaExe -match '[\\/]') {
        if (-not (Test-Path $JavaExe -PathType Leaf)) {
            throw "Java executable not found: $JavaExe"
        }
    }
    elseif (-not (Get-Command $JavaExe -ErrorAction SilentlyContinue)) {
        throw "Java executable '$JavaExe' was not found in PATH."
    }
}


function Get-LevelName {
    $properties = Join-Path $ServerDir "server.properties"

    if (Test-Path $properties) {
        $line = Get-Content $properties |
            Where-Object { $_ -match '^\s*level-name=' } |
            Select-Object -First 1

        if ($line) {
            $name = ($line -split '=', 2)[1].Trim()
            if ($name) {
                return $name
            }
        }
    }

    return "world"
}


function Get-NextScheduledRestart {
    $now = Get-Date

    $candidate = Get-Date `
        -Year $now.Year `
        -Month $now.Month `
        -Day $now.Day `
        -Hour $ScheduledRestartHour `
        -Minute $ScheduledRestartMinute `
        -Second 0

    if ($candidate -le $now) {
        $candidate = $candidate.AddDays(1)
    }

    return $candidate
}


function Copy-DirectoryWithRobocopy {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Source,

        [Parameter(Mandatory = $true)]
        [string]$Destination
    )

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null

    & robocopy $Source $Destination /MIR /R:2 /W:2 /XJ /NFL /NDL /NJH /NJS /NP | Out-Host
    $copyExit = $LASTEXITCODE

    # Robocopy codes 0 through 7 are success/non-fatal differences.
    if ($copyExit -ge 8) {
        throw "Robocopy failed with exit code $copyExit while copying '$Source'."
    }
}


function Backup-Server {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Reason
    )

    $levelName = Get-LevelName
    $worldPath = Join-Path $ServerDir $levelName

    if (-not (Test-Path $worldPath -PathType Container)) {
        Write-WrapperLog "Backup skipped: world folder not found: $worldPath" Yellow
        return
    }

    New-Item -ItemType Directory -Path $BackupRoot -Force | Out-Null

    $stamp     = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
    $backupDir = Join-Path $BackupRoot $stamp

    New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

    Write-WrapperLog "Creating OFFLINE backup ($Reason): $backupDir" Cyan

    # World contains dimensions, player data, OPAC server claims/serverconfig, etc.
    $worldDest = Join-Path $backupDir $levelName
    Copy-DirectoryWithRobocopy -Source $worldPath -Destination $worldDest

    # Copy selected root-level server files and config directories.
    foreach ($relative in $BackupExtraPaths) {
        $source = Join-Path $ServerDir $relative

        if (Test-Path $source -PathType Leaf) {
            $dest       = Join-Path $backupDir $relative
            $destParent = Split-Path $dest -Parent

            if ($destParent) {
                New-Item -ItemType Directory -Path $destParent -Force | Out-Null
            }

            Copy-Item $source $dest -Force
        }
        elseif (Test-Path $source -PathType Container) {
            $dest = Join-Path $backupDir $relative
            Copy-DirectoryWithRobocopy -Source $source -Destination $dest
        }
    }

    @(
        "Vault Hunters server backup"
        "Created: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss zzz')"
        "Reason: $Reason"
        "Level name: $levelName"
        "Server directory: $ServerDir"
    ) | Set-Content (Join-Path $backupDir "BACKUP_INFO.txt") -Encoding UTF8

    Write-WrapperLog "Backup completed successfully." Green

    # Remove old timestamped backups.
    if ($MaxBackupDays -gt 0) {
        $cutoff = (Get-Date).AddDays(-$MaxBackupDays)

        Get-ChildItem $BackupRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object {
                $_.Name -match '^\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}$' -and
                $_.CreationTime -lt $cutoff
            } |
            ForEach-Object {
                Write-WrapperLog "Removing old backup: $($_.FullName)" DarkGray
                Remove-Item $_.FullName -Recurse -Force
            }
    }
}


function Send-ServerCommand {
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$Process,

        [Parameter(Mandatory = $true)]
        [string]$Command
    )

    if ($Process.HasExited) {
        return
    }

    try {
        $Process.StandardInput.WriteLine($Command)
        $Process.StandardInput.Flush()
    }
    catch {
        Write-WrapperLog "Could not send server command '$Command': $($_.Exception.Message)" Yellow
    }
}


function Send-RestartWarning {
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$Process,

        [Parameter(Mandatory = $true)]
        [int]$Minutes
    )

    $unit = if ($Minutes -eq 1) { "minute" } else { "minutes" }
    $message = "Server restart in $Minutes $unit. Please get somewhere safe."

    Send-ServerCommand `
        -Process $Process `
        -Command "tellraw @a {`"text`":`"$message`",`"color`":`"gold`"}"

    Write-WrapperLog $message Yellow
}


function Start-MinecraftProcess {
    $psi = New-Object System.Diagnostics.ProcessStartInfo

    $psi.FileName               = $JavaExe
    $psi.WorkingDirectory       = $ServerDir
    $psi.UseShellExecute        = $false
    $psi.RedirectStandardInput  = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.CreateNoWindow         = $false

    # Preserve Forge's generated Java @arg files.
    $allArgs = @(
        "@$JvmArgsRelative",
        "@$ForgeArgsRelative"
    ) + $ExtraJavaArgs

    $psi.Arguments = ($allArgs | ForEach-Object {
        if ($_ -match '\s') {
            '"' + ($_ -replace '"', '\"') + '"'
        }
        else {
            $_
        }
    }) -join ' '

    $process = New-Object System.Diagnostics.Process
    $process.StartInfo = $psi

    if (-not $process.Start()) {
        throw "Failed to start Java."
    }

    return $process
}


function Wait-ForMinecraftExit {
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$Process
    )

    $scheduledRestartPending = $false
    $nextRestart             = $null
    $warningsSent            = @{}
    $inputBuffer             = ""
    $serverReadyNotified     = $false
    $minecraftDoneSeen       = $false
    $minecraftStartupTime    = $null
    $readyMarkerSeen         = $false
    $readyMarkerSeenAt       = $null

    # Read redirected Minecraft output asynchronously while keeping this loop
    # available for scheduling and keyboard input.
    $stdoutTask = $Process.StandardOutput.ReadLineAsync()
    $stderrTask = $Process.StandardError.ReadLineAsync()

    if ($EnableScheduledRestart) {
        $nextRestart = Get-NextScheduledRestart
        Write-WrapperLog "Next scheduled restart: $($nextRestart.ToString('yyyy-MM-dd HH:mm:ss')) server local time." Cyan

        # If the wrapper starts after one of today's warning thresholds, do not
        # spam old warnings immediately.
        $now = Get-Date
        foreach ($minutes in $RestartWarningMinutes) {
            if ($now -ge $nextRestart.AddMinutes(-$minutes)) {
                $warningsSent[$minutes] = $true
            }
        }
    }

    while (-not $Process.HasExited) {
        # Drain stdout without blocking the scheduler.
        while ($null -ne $stdoutTask -and $stdoutTask.IsCompleted) {
            $line = $stdoutTask.Result

            if ($null -eq $line) {
                $stdoutTask = $null
                break
            }

            Write-Host $line

            # Stage 1: Minecraft's normal DedicatedServer "Done" marker.
            # On Forge 1.18.2 this can be too early for player logins.
            if (
                -not $minecraftDoneSeen -and
                $line -match 'Done \(([^)]+)\)! For help, type "help"'
            ) {
                $minecraftDoneSeen = $true
                $minecraftStartupTime = $Matches[1]

                Write-WrapperLog "Minecraft Done marker seen ($minecraftStartupTime), but Forge may still be starting. Waiting for late-start marker..." Cyan
            }

            # Stage 2: late startup marker for this modpack.
            if (
                -not $readyMarkerSeen -and
                $line -match $ServerReadyLogPattern
            ) {
                $readyMarkerSeen = $true
                $readyMarkerSeenAt = Get-Date

                Write-WrapperLog "Late-start marker seen. Waiting $ServerReadyGraceSeconds second(s) before declaring server online..." Cyan
            }

            $stdoutTask = $Process.StandardOutput.ReadLineAsync()
        }

        # Drain stderr without blocking the scheduler.
        while ($null -ne $stderrTask -and $stderrTask.IsCompleted) {
            $line = $stderrTask.Result

            if ($null -eq $line) {
                $stderrTask = $null
                break
            }

            Write-Host $line -ForegroundColor DarkYellow
            $stderrTask = $Process.StandardError.ReadLineAsync()
        }

        # Interactive console input.
        # Because Java stdin is redirected, this wrapper forwards complete lines
        # typed into this window to Minecraft.
        try {
            while ([Console]::KeyAvailable) {
                $key = [Console]::ReadKey($true)

                if ($key.Key -eq [ConsoleKey]::Enter) {
                    Write-Host ""
                    $command = $inputBuffer
                    $inputBuffer = ""

                    if (-not [string]::IsNullOrWhiteSpace($command)) {
                        Send-ServerCommand -Process $Process -Command $command
                    }
                }
                elseif ($key.Key -eq [ConsoleKey]::Backspace) {
                    if ($inputBuffer.Length -gt 0) {
                        $inputBuffer = $inputBuffer.Substring(0, $inputBuffer.Length - 1)

                        try {
                            Write-Host "`b `b" -NoNewline
                        }
                        catch {}
                    }
                }
                elseif (
                    $key.KeyChar -ne [char]0 -and
                    -not [char]::IsControl($key.KeyChar)
                ) {
                    $inputBuffer += $key.KeyChar
                    Write-Host $key.KeyChar -NoNewline
                }
            }
        }
        catch {
            # KeyAvailable can be unavailable in non-interactive hosts.
        }

        # Final ready announcement.
        # Only announce after Minecraft Done + the late modpack marker + grace.
        if (
            -not $serverReadyNotified -and
            $minecraftDoneSeen -and
            $readyMarkerSeen -and
            $null -ne $readyMarkerSeenAt -and
            ((Get-Date) - $readyMarkerSeenAt).TotalSeconds -ge $ServerReadyGraceSeconds
        ) {
            $serverReadyNotified = $true

            Write-WrapperLog "Minecraft is ONLINE. Players can join." Green
            Send-DiscordNotification ":green_circle: **SERVER ONLINE** - Players can join. Minecraft `Done` was seen, Simple Voice Chat finished starting, and the $ServerReadyGraceSeconds-second grace period completed."
        }

        # Scheduled daily restart.
        if ($EnableScheduledRestart) {
            $now = Get-Date

            foreach ($minutes in $RestartWarningMinutes) {
                if (-not $warningsSent.ContainsKey($minutes)) {
                    $warningAt = $nextRestart.AddMinutes(-$minutes)

                    if ($now -ge $warningAt -and $now -lt $nextRestart) {
                        Send-RestartWarning -Process $Process -Minutes $minutes
                        $warningsSent[$minutes] = $true
                    }
                }
            }

            if ($now -ge $nextRestart) {
                Write-WrapperLog "$ScheduledRestartTimeLabel scheduled restart reached. Saving world..." Cyan
                Send-DiscordNotification ":black_square_button: **SCHEDULED RESTART STARTED** at **$ScheduledRestartTimeLabel**. Saving the world and shutting down cleanly for backup."

                Send-ServerCommand `
                    -Process $Process `
                    -Command "tellraw @a {`"text`":`"Scheduled server restart now. Server will return shortly.`",`"color`":`"red`"}"

                Send-ServerCommand -Process $Process -Command "save-all flush"

                Start-Sleep -Seconds 5

                Write-WrapperLog "Stopping Minecraft cleanly for scheduled maintenance..." Cyan
                Send-ServerCommand -Process $Process -Command "stop"

                $scheduledRestartPending = $true

                # Do not schedule another event while this Java process shuts down.
                $EnableSchedulingForThisProcess = $false

                while (-not $Process.HasExited) {
                    # Continue draining output during shutdown.
                    while ($null -ne $stdoutTask -and $stdoutTask.IsCompleted) {
                        $line = $stdoutTask.Result
                        if ($null -eq $line) {
                            $stdoutTask = $null
                            break
                        }
                        Write-Host $line
                        $stdoutTask = $Process.StandardOutput.ReadLineAsync()
                    }

                    while ($null -ne $stderrTask -and $stderrTask.IsCompleted) {
                        $line = $stderrTask.Result
                        if ($null -eq $line) {
                            $stderrTask = $null
                            break
                        }
                        Write-Host $line -ForegroundColor DarkYellow
                        $stderrTask = $Process.StandardError.ReadLineAsync()
                    }

                    Start-Sleep -Milliseconds 100
                }

                break
            }
        }

        Start-Sleep -Milliseconds 100
    }

    $Process.WaitForExit()

    # Drain any final output lines left after Java exits.
    for ($i = 0; $i -lt 100; $i++) {
        $didWork = $false

        while ($null -ne $stdoutTask -and $stdoutTask.IsCompleted) {
            $line = $stdoutTask.Result
            if ($null -eq $line) {
                $stdoutTask = $null
                break
            }
            Write-Host $line
            $stdoutTask = $Process.StandardOutput.ReadLineAsync()
            $didWork = $true
        }

        while ($null -ne $stderrTask -and $stderrTask.IsCompleted) {
            $line = $stderrTask.Result
            if ($null -eq $line) {
                $stderrTask = $null
                break
            }
            Write-Host $line -ForegroundColor DarkYellow
            $stderrTask = $Process.StandardError.ReadLineAsync()
            $didWork = $true
        }

        if ($null -eq $stdoutTask -and $null -eq $stderrTask) {
            break
        }

        if (-not $didWork) {
            Start-Sleep -Milliseconds 20
        }
    }

    return @{
        ExitCode                = $Process.ExitCode
        ScheduledRestartPending = $scheduledRestartPending
    }
}


# ============================================================
# START / RESTART LOOP
# ============================================================

try {
    Set-Location $ServerDir

    try {
        $Host.UI.RawUI.WindowTitle = "Vault Hunters Server"
    }
    catch {}

    Test-Requirements

    Write-WrapperLog "Server wrapper started." Cyan
    Send-DiscordNotification ":black_square_button: **SERVER WRAPPER STARTED**"
    Write-WrapperLog "Server directory: $ServerDir" DarkGray
    Write-WrapperLog "Forge args: $ForgeArgsRelative" DarkGray

    if ($EnableScheduledRestart) {
        Write-WrapperLog "Daily restart configured for $ScheduledRestartTimeLabel server local time." DarkGray
    }

    # Safe startup backup because Minecraft is not running yet.
    if ($EnableBackupOnFirstStart) {
        Backup-Server -Reason "wrapper first start"
    }

    $CrashTimes = [System.Collections.Generic.List[datetime]]::new()

    while ($true) {
        $startedAt = Get-Date

        Write-WrapperLog "Starting Minecraft server..." Green
        $process = Start-MinecraftProcess
        Send-DiscordNotification ":black_square_button: **SERVER STARTING** - Java launched. Waiting for Minecraft `Done (...)!` and the Simple Voice Chat startup marker before marking the server online."

        $result = Wait-ForMinecraftExit -Process $process

        $exitCode = [int]$result.ExitCode
        $scheduledRestartPending = [bool]$result.ScheduledRestartPending
        $runtime = [math]::Round(((Get-Date) - $startedAt).TotalSeconds, 1)

        Write-WrapperLog "Java exited with code $exitCode after $runtime second(s)." Yellow

        # Daily scheduled-maintenance path.
        if ($scheduledRestartPending) {
            if ($EnableBackupOnScheduledRestart) {
                Backup-Server -Reason "daily $ScheduledRestartTimeLabel scheduled restart"
            }

            Write-WrapperLog "Scheduled backup complete. Starting Minecraft again..." Green
            Send-DiscordNotification ":white_check_mark: **BACKUP COMPLETE** - Scheduled restart backup finished. Starting Minecraft again."
            Start-Sleep -Seconds 3
            continue
        }

        # A clean "stop" entered manually.
        if ($exitCode -eq 0) {
            if ($EnableBackupOnManualStop) {
                Backup-Server -Reason "manual clean shutdown"
            }

            Write-WrapperLog "Clean manual shutdown detected. Wrapper will remain stopped." Green
            Send-DiscordNotification ":black_square_button: **SERVER STOPPED** - Clean manual shutdown completed. Backup finished; wrapper will remain stopped."
            break
        }

        # Crash path: do NOT back up a crashed world.
        if (-not $RestartOnCrash) {
            Write-WrapperLog "Crash restart is disabled. Wrapper is stopping." Red
            Send-DiscordNotification ":red_circle: **SERVER CRASH** - Java exit code **$exitCode** after **$runtime seconds**. Automatic crash restart is disabled."
            break
        }

        $cutoff = (Get-Date).AddSeconds(-$CrashWindowSeconds)

        for ($i = $CrashTimes.Count - 1; $i -ge 0; $i--) {
            if ($CrashTimes[$i] -lt $cutoff) {
                $CrashTimes.RemoveAt($i)
            }
        }

        $CrashTimes.Add((Get-Date))

        Write-WrapperLog "Crash detected. Recent crashes: $($CrashTimes.Count)/$MaxCrashesInWindow." Red
        Send-DiscordNotification ":red_circle: **SERVER CRASH** - Java exit code **$exitCode** after **$runtime seconds**. Crash **$($CrashTimes.Count)/$MaxCrashesInWindow** inside the $CrashWindowSeconds-second crash window."

        if ($CrashTimes.Count -ge $MaxCrashesInWindow) {
            Write-WrapperLog "Crash-loop protection triggered: $MaxCrashesInWindow crashes within $CrashWindowSeconds seconds." Red
            Write-WrapperLog "Automatic restarting stopped. Check logs\latest.log and crash-reports." Red
            Send-DiscordNotification ":rotating_light: **CRASH LOOP PROTECTION TRIGGERED** - $MaxCrashesInWindow crashes occurred within $CrashWindowSeconds seconds. Automatic restarting has stopped. Check logs/latest.log and crash-reports."
            break
        }

        $retryNumber = $CrashTimes.Count
        $maxRetriesBeforeLockout = [Math]::Max(1, $MaxCrashesInWindow - 1)

        Write-WrapperLog "Restarting after crash in $RestartDelaySeconds second(s). Retry $retryNumber/$maxRetriesBeforeLockout. Press Ctrl+C to cancel." Yellow
        Send-DiscordNotification ":orange_circle: **RESTART RETRY $retryNumber/$maxRetriesBeforeLockout** - trying to start Minecraft again in **$RestartDelaySeconds seconds**."
        Start-Sleep -Seconds $RestartDelaySeconds
    }
}
catch {
    Write-WrapperLog "WRAPPER ERROR: $($_.Exception.Message)" Red
    Send-DiscordNotification ":rotating_light: **WRAPPER ERROR** - $($_.Exception.Message)"
}
finally {
    Write-WrapperLog "Server wrapper stopped." Cyan

    if ($PauseWhenStopped) {
        try {
            Read-Host "Press Enter to close"
        }
        catch {}
    }
}
