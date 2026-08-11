# Vault Hunters Server Wrapper

PowerShell wrapper for a **Minecraft 1.18.2 / Forge 40.3.11 / Vault Hunters** server.

## Features

- Automatic restart after a crash
- Crash retry counter and crash-loop protection
- Daily graceful restart at a **configurable server-local time**
- 15, 5, and 1 minute player warnings
- `save-all flush` before scheduled shutdown
- Offline backups
- 7-day backup retention by default
- Discord notifications for restarts, crashes, retries, and lockout
- Normal interactive Minecraft console

## Install

Put `start.ps1` and `start.bat` beside `user_jvm_args.txt`, then launch:

```text
start.bat
```

## Backup destination

This version is configured for:

```powershell
$BackupRoot = "D:\Back-up\mcvh"
```

Each backup gets a timestamped folder, for example:

```text
D:\Back-up\mcvh\
├── 2026-08-10_04-00-05\
├── 2026-08-11_04-00-03\
└── ...
```

## Discord setup

Create a webhook for the Discord channel you want to use for server status.

In Discord go to **Server Settings → Integrations → Webhooks**, create/select a webhook, choose the channel, then copy the webhook URL.

Open `start.ps1` and set:

```powershell
$EnableDiscordNotifications = $true
$DiscordWebhookUrl          = "PASTE-YOUR-WEBHOOK-URL-HERE"
$DiscordWebhookUsername     = "Vault Hunters Server"
$DiscordServerName          = "Vault Hunters Remastered"
```

### Security

Treat the Discord webhook URL like a password.

If the GitHub repository is public, leave this in the repository copy:

```powershell
$DiscordWebhookUrl = ""
```

Only paste the real URL into the copy of `start.ps1` running on your server.

## Discord messages

Examples:

```text
:black_square_button: SERVER WRAPPER STARTED

:black_square_button: SCHEDULED RESTART STARTED at 04:00.
Saving the world and shutting down cleanly for backup.

:white_check_mark: BACKUP COMPLETE.
Starting Minecraft again.

:red_circle: SERVER CRASH
Java exit code 1 after 742.3 seconds.
Crash 1/5 inside the 300-second crash window.

:orange_circle: RESTART RETRY 1/4
Trying to start Minecraft again in 10 seconds.

:rotating_light: CRASH LOOP PROTECTION TRIGGERED
5 crashes occurred within 300 seconds.
Automatic restarting has stopped.
```

The script also reports clean manual shutdowns and wrapper-level errors.

If Discord is unavailable, the failure is written to:

```text
logs\server-wrapper.log
```

and Minecraft keeps running.


## Server ready / players can join

On this Forge 1.18.2 modpack, Minecraft's normal:

```text
[minecraft/DedicatedServer]: Done (...)! For help, type "help"
```

is **too early** to mean players can join. Forge can still reject logins with:

```text
Server is still starting! Please wait before reconnecting.
```

The wrapper now waits for this sequence:

```text
1. Minecraft: Done (...)!
2. Simple Voice Chat: Voice chat server started at port 51801
3. Wait 5 seconds
4. Discord: :green_circle: SERVER ONLINE - Players can join
```

Configure it in `start.ps1`:

```powershell
$ServerReadyLogPattern   = '\[voicechat\].*Voice chat server started at port 51801'
$ServerReadyGraceSeconds = 5
```

If the voice-chat port changes, update the pattern.

### Discord status icons

```text
:green_circle:         Server online
:white_check_mark:     Backup/success
:black_square_button:  Starting/stopping/scheduled maintenance
:red_circle:           Crash
:rotating_light:       Critical error / crash-loop lockout
:orange_circle:        Crash restart retry
```

## Daily restart

Default:

```powershell
$ScheduledRestartHour   = 4
$ScheduledRestartMinute = 0
$RestartWarningMinutes  = @(15, 5, 1)
```

The script automatically derives:

```powershell
$ScheduledRestartTimeLabel = "{0:D2}:{1:D2}" -f $ScheduledRestartHour, $ScheduledRestartMinute
```

All runtime log and Discord messages use `$ScheduledRestartTimeLabel`, so changing the hour/minute automatically changes the displayed restart time everywhere.

Flow:

```text
15 minutes before  warning
5 minutes before   warning
1 minute before    warning
scheduled time     save-all flush
                   stop
                   offline backup
                   start Minecraft
```

## Crash restart

Default:

```powershell
$RestartOnCrash      = $true
$RestartDelaySeconds = 10
$MaxCrashesInWindow  = 5
$CrashWindowSeconds  = 300
```

With those defaults, the wrapper performs up to **4 retry starts** inside a 5-minute crash window. If Minecraft crashes for the 5th time in that window, automatic restarting stops.

## Backups

Backups happen:

- before the first server start;
- after the scheduled restart stop;
- after a manual clean `stop`.

The script deliberately does **not** create a backup immediately after a crash.

Default retention:

```powershell
$MaxBackupDays = 7
```

## RAM

Keep RAM/JVM settings in:

```text
user_jvm_args.txt
```

The wrapper still uses Forge's normal argument files.
