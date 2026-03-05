# History Scan vs. Start Monitoring - Key Differences

## Overview

| Feature | History Scan | Start Monitoring |
|---------|-------------|-----------------|
| **Trigger** | Button click (manual, one-time) | Button click (continuous, ongoing) |
| **Window** | Separate modal dialog | Main form grid (Dashboard tab) |
| **Scope** | Past files (by date) | Real-time file creation events |
| **Duration** | Runs once, then stops | Continuous until Stop clicked |
| **Polling Method** | Synchronous (blocking) | Asynchronous (non-blocking via RunspacePool) |

---

## History Scan (`$btnHistory_Click`)

### Purpose
Retrospectively scan and check files from a **specific past date** to verify their replication status.

### Workflow
```
1. Open separate "History / File Scanner" form dialog
   ↓
2. User selects date using DateTimePicker (defaults to today)
   ↓
3. Click "Scan Files" button
   ↓
4. Scan monitored folders for files matching:
   - regex pattern
   - AND LastWriteTime within selected date (00:00 - 23:59)
   ↓
5. For each matching file, poll each web server sequentially
   ↓
6. Display results in dialog grid: FOUND (green) or MISSING (red)
   ↓
7. Show "Scan Complete" message
```

### Key Characteristics

**File Source:** Filesystem scan
```powershell
$file.LastWriteTime -ge $targetDate -and $file.LastWriteTime -lt $nextDay
```

**Polling:** Synchronous & Blocking
```powershell
$req = [System.Net.WebRequest]::Create($fullUrl)
$resp = $req.GetResponse()
$grid.Rows[$rowIndex].Cells[$colIndex].Value = "FOUND ($($resp.StatusCode))"
```

**Timeout:** 2 seconds (short, per single request)
```powershell
$req.Timeout = 2000
```

**Concurrency:** Sequential per-server within each file
- File A → Server 1 → Server 2 → Server 3
- File B → Server 1 → Server 2 → Server 3

**UI Responsiveness:** Kept responsive with `DoEvents()` but still blocks dialog
```powershell
[System.Windows.Forms.Application]::DoEvents()
```

**Error Handling:** Catches exceptions and displays error message
```powershell
$msg = $_.Exception.Message
$grid.Rows[$rowIndex].Cells[$colIndex].Value = "MISSING ($msg)"
```

**Resource Cleanup:** Manual (no background tasks to clean up)

---

## Start Monitoring (`$btnStart_Click`)

### Purpose
**Real-time continuous monitoring** of designated folders for newly created files and immediate replication checking.

### Workflow
```
1. Click "Start" button on main form
   ↓
2. Initialize RunspacePool (1-8 threads based on CPU)
   ↓
3. Create FileSystemWatcher for each monitored subfolder
   - Watches for "Created" events only
   - Non-recursive
   ↓
4. [CONTINUOUS] When file is created:
   - Check if matches regex pattern
   - Add row to main grid
   - Dispatch N async polling tasks (one per server) to RunspacePool
   ↓
5. Each polling task runs in background:
   - 500ms retry interval
   - 180-second total timeout
   - Updates grid cell every time status changes
   - Respects MonitoringActive.IsRunning flag
   ↓
6. Shows "Scanning... (5 s)" → "FOUND (200)" [green] or "TIMEOUT (180 s)" [red]
   ↓
7. Click "Stop" to:
   - Disable watchers
   - Cancel all running polls
   - Clean up runspaces
```

### Key Characteristics

**File Source:** FileSystemWatcher (real-time events)
```powershell
$newWatcher.add_Created($action)
$newWatcher.EnableRaisingEvents = $true
```

**Polling:** Asynchronous & Non-blocking
```powershell
$ps = [powershell]::Create()
$ps.RunspacePool = $script:RunspacePool
$handle = $ps.BeginInvoke()  # Returns immediately
```

**Timeout:** 180 seconds (per file, global)
```powershell
if ($statusCode -eq 200) { $success = $true; break }
while ($MonitoringActive.IsRunning -and $stopwatch.Elapsed.TotalSeconds -lt 180)
```

**Concurrency:** Parallel per-server (up to 8 concurrent runspaces)
- File A → Async poll Server 1, 2, 3 (concurrent)
- File B → Async poll Server 1, 2, 3 (concurrent)

**UI Responsiveness:** Instant (non-blocking dispatch)
- FileSystemWatcher event returns immediately
- Main thread never blocks on HTTP requests
- Grid updates via `Form.Invoke()` from background runspaces

**Status Display:** Live elapsed time
```
"Scanning... (0 s)"
"Scanning... (1 s)"
"Scanning... (2 s)"
→ "FOUND (200)" or "TIMEOUT (180 s)"
```

**Error Handling:** Silently retries on HTTP errors; timeout is final state

**Resource Cleanup:** Proper cleanup on Stop
```powershell
$script:MonitoringActive.IsRunning = $false
foreach ($job in $script:ActiveRunspaces) {
    $job.PowerShell.EndInvoke($job.Handle)
    $job.PowerShell.Dispose()
}
$script:RunspacePool.Close()
$script:RunspacePool.Dispose()
```

---

## Side-by-Side Comparison

| Aspect | History Scan | Start Monitoring |
|--------|-------------|-----------------|
| **Trigger** | Manual button (one-time) | Manual button (continuous) |
| **File Detection** | Scans disk for date match | Taps FileSystemWatcher |
| **Polling Approach** | Synchronous (direct HTTP) | Async (RunspacePool) |
| **Default Timeout** | 2 seconds | 180 seconds |
| **Retry Logic** | One shot per server per file | 500ms intervals × 360 (to 180s) |
| **Concurrency** | Sequential | Up to 8 concurrent |
| **UI Thread** | Blocks dialog (DoEvents helps) | Never blocks (async dispatch) |
| **Status Updates** | Final only (FOUND/MISSING) | Live (Scanning... → elapsed time) |
| **Cancellation** | None (must wait for scan) | Stop button (immediate) |
| **Grid Display** | Separate dialog window | Main form DataGridView |
| **Cleanup** | None (dialog closes) | Proper runspace/watcher cleanup |
| **Real-time?** | No (retrospective) | Yes (live file detection) |
| **Use Case** | Audit past replication | Verify active replication |

---

## Example Scenarios

### Scenario 1: Verify Yesterday's Files
**Use History Scan:**
1. Open main form, click "History Scan"
2. Change DateTimePicker to yesterday's date
3. Click "Scan Files"
4. Review results in dialog (FOUND = replicated, MISSING = issue)
5. Close dialog

### Scenario 2: Monitor Real-Time File Creation
**Use Start Monitoring:**
1. Click "Start" on main form
2. Application monitors all subfolders
3. Each new file detected → row added automatically
4. Polling starts immediately (parallel across servers)
5. Watch grid update in real-time
6. Click "Stop" when done

---

## Common Issues & Solutions

| Issue | History Scan | Start Monitoring |
|-------|-------------|-----------------|
| Dialog freezes during scan | DoEvents tries to help, but blocking is inherent | Never freezes (async) |
| Can't cancel scan | No cancel button; must wait | Click Stop button (immediate) |
| Slow results on many files | Sequential polling is slow | Fast (parallel via RunspacePool) |
| Missing error detail | Catches exception message | Silent retry; final state only |
| Old files never matched | Only scans configured subfolders | Only watches configured subfolders |

---

## Technical Depth

### History Scan: Synchronous Per-Server Loop
```powershell
foreach ($srv in $webServers) {
    $colIndex = $grid.Columns[$srv].Index
    $fullUrl = "https://$srv/$subPath/$($file.Name)"
    
    try {
        $req = [System.Net.WebRequest]::Create($fullUrl)
        $req.Timeout = 2000  # 2-second per-request timeout
        $resp = $req.GetResponse()
        $grid.Rows[$rowIndex].Cells[$colIndex].Value = "FOUND ($($resp.StatusCode))"
        $grid.Rows[$rowIndex].Cells[$colIndex].Style.BackColor = [System.Drawing.Color]::LightGreen
        $resp.Close()
    } catch {
        $grid.Rows[$rowIndex].Cells[$colIndex].Value = "MISSING ($msg)"
        $grid.Rows[$rowIndex].Cells[$colIndex].Style.BackColor = [System.Drawing.Color]::LightCoral
    }
}
```

### Start Monitoring: Async Runspace Dispatch
```powershell
$ps = [powershell]::Create()
$ps.RunspacePool = $script:RunspacePool
$null = $ps.AddScript($PollingScript)  # Contains 180s retry loop
$null = $ps.AddArgument($DataGridView1)
$null = $ps.AddArgument($rowIndex)
$null = $ps.AddArgument($webServer)
$null = $ps.AddArgument($colIndex)
$null = $ps.AddArgument($fullUrl)
$null = $ps.AddArgument($Form1)
$null = $ps.AddArgument($script:MonitoringActive)

$handle = $ps.BeginInvoke()  # Non-blocking
$script:ActiveRunspaces += @{ PowerShell = $ps; Handle = $handle }
```

---

## Recommendations

| Need | Choose |
|------|--------|
| Audit past replication for a specific date | **History Scan** |
| Real-time monitoring of active file creation | **Start Monitoring** |
| Quick spot-check of recent files | **History Scan** (with today's date) |
| Verify ongoing replication process | **Start Monitoring** |
| Check hundreds of old files at once | **History Scan** (but expect delays) |
| Monitor for replication failures in production | **Start Monitoring** |
