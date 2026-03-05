# File Replication Monitor

A PowerShell-based WinForms application that monitors designated folders on a file server for new files, detects them in real-time, and polls multiple web servers to verify that the files have been replicated/processed.

## Files

- **Claude.ps1** — Main production application (single script, ~800 lines, self-contained)
- **config.json** — Auto-created configuration file (RootUNC, Subfolders, FilenameRegex, WebServers, polling settings)
- **logs/** — Auto-created folder for daily rolling logs (5-day retention)
- **config.json.template** — Reference template showing all available config options
- **RUN_INSTRUCTIONS.txt** — Complete deployment & troubleshooting guide

## Quick Start

1. Copy **Claude.ps1** to your computer or network location
2. Right-click → "Run with PowerShell" 
3. The app auto-creates **config.json** with defaults
4. Edit **config.json** to set your RootUNC, Subfolders, WebServers, and regex
5. Restart the app
6. Click **[Start]** in the GUI to begin monitoring

## Key Features

✅ **Real-time Monitoring** — FileSystemWatcher detects new files immediately  
✅ **Multi-Server Polling** — Concurrently checks multiple HTTPS endpoints in parallel  
✅ **WinForms GUI** — Simple Start/Stop interface with live status grid  
✅ **Automatic Logging** — Daily rolling logs with 5-day retention  
✅ **Self-Healing** — Restarts watchers automatically if they fail  
✅ **Robust Threading** — Proper runspace pooling with cancellation tokens  
✅ **Auto-Config** — Creates default config.json if missing  
✅ **Self-Relaunching** — Ensures Single-Threaded Apartment (STA) mode for UI stability  

## Architecture

- **Monitoring** — System.IO.FileSystemWatcher per subfolder (Created events only)
- **HTTP Polling** — System.Net.HttpWebRequest (HEAD or GET, configurable)
- **Concurrency** — RunspacePool with depth = min(8, CPU count)
- **Cancellation** — CancellationToken for immediate polling shutdown
- **State** — Synchronized hashtable for thread-safe shared data
- **Logging** — Thread-safe Write-AppLog with daily file rotation
- **UI Threading** — Proper marshaling (Invoke/BeginInvoke) to avoid deadlocks

## Configuration Example

```json
{
  "RootUNC": "\\\\server\\share\\htdocs",
  "Subfolders": [
    "instit\\annceresult\\press\\preanre\\2026",
    "xml"
  ],
  "FilenameRegex": "^(PendingAuctions\\.pdf|Report.*\\.xlsx)?$",
  "WebServers": [
    "https://ihs-wb-p02.example.gov",
    "https://backup-server.example.com"
  ],
  "PollIntervalMs": 900,
  "TimeoutSeconds": 180,
  "UseHeadVsGet": "HEAD",
  "CertVerificationEnabled": false
}
```

## Status Indicators (GUI Grid)

| Cell Status | Meaning |
|---|---|
| `Scanning... (X s)` | Still polling this server |
| `OK (X s)` | File found on server (200 OK) |
| `TIMEOUT (X s)` | Polling timed out without success |
| `ERROR (X s)` | Exception during polling |

## Logs

Logs are stored in `logs/app-YYYYMMDD.log` with timestamps. Entries include:
- Monitor start/stop events
- Files detected and their matched subfolders
- Polling results (success, timeout, error)
- Warnings and exceptions
- Watcher restart attempts

Old logs are deleted automatically; only the last 5 days are kept.

## Troubleshooting

See **RUN_INSTRUCTIONS.txt** for detailed troubleshooting steps.

**Quick fixes:**
- Set execution policy: `Set-ExecutionPolicy -ExecutionPolicy ByPass -Scope Process`
- Check **logs/app-YYYYMMDD.log** for error messages
- Verify **config.json** is valid JSON
- Ensure RootUNC path is reachable (UNC format: `\\server\share\path`)
- For HTTPS errors, set `CertVerificationEnabled: false` in config

## Technical Notes

- **Platform**: Windows PowerShell 5.1
- **Frameworks**: .NET 4.5+, System.Windows.Forms, System.Net
- **Console**: Hidden on startup (STA relaunch)
- **Threading**: MTA background polling + STA UI thread
- **Resilience**: Automatic watcher restart, graceful polling timeouts, comprehensive logging

---

For complete deployment instructions, see **RUN_INSTRUCTIONS.txt**.
