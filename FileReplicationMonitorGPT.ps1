<#  File Replication Monitor (PowerShell 5.1 / WinForms)
    - Monitors UNC subfolders (non-recursive) for Created events
    - Filters by regex
    - Polls replication across HTTPS web servers (HEAD/GET) using RunspacePool
    - GUI-only (hides console); auto-relaunch STA if needed
#>

param(
    [switch]$Relaunched
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# -----------------------------
# Helpers: Console hide + STA relaunch
# -----------------------------
Add-Type -Namespace Win32 -Name NativeMethods -MemberDefinition @"
using System;
using System.Runtime.InteropServices;
public static class NativeMethods {
  [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
}
"@

function Hide-ConsoleWindow {
    try {
        $hWnd = [Win32.NativeMethods]::GetConsoleWindow()
        if ($hWnd -ne [IntPtr]::Zero) {
            # 0 = SW_HIDE
            [void][Win32.NativeMethods]::ShowWindow($hWnd, 0)
        }
    } catch {
        # ignore
    }
}

# Relaunch in STA if needed, and keep GUI-only
if (-not $Relaunched -and [System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    try {
        $psExe = (Get-Command powershell.exe -ErrorAction Stop).Source
        $scriptPath = $MyInvocation.MyCommand.Path
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $psExe
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -Sta -File `"$scriptPath`" -Relaunched"
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        [void][System.Diagnostics.Process]::Start($psi)
    } catch {
        # if relaunch fails, continue (best effort)
    }
    exit
}

Hide-ConsoleWindow

# -----------------------------
# Load WinForms assemblies
# -----------------------------
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic
[System.Windows.Forms.Application]::EnableVisualStyles()

# -----------------------------
# Paths + config auto-create
# -----------------------------
$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$ConfigPath = Join-Path $ScriptDir 'config.json'
$LogsDir    = Join-Path $ScriptDir 'logs'

$DefaultConfig = [ordered]@{
    RootUNC               = '\\ServerShare\folder\htdocs\'
    Subfolders            = @(
        'instit\annceresult\press\preanre\2026',
        'instit\annceresult\press\preanre',
        'xml'
    )
    FilenameRegex         = '^(PendingAuctions\.(pdf|xml)|A_\d{8}_\d\.(xml|pdf)|SPL_\d{8}_\d\.pdf|BPD_SPL_\d{8}_\d\.pdf|R_\d{8}_\d\.(xml|pdf)|NCR_\d{8}_\d\.pdf|CPI_\d{8}\.(xml|pdf)|BBA_\d{14}\.(pdf|xml)|BBPA_\d{14}\.(pdf|xml)|BBR_\d{14}\.(pdf|xml)|BBSPL_\d{14}\.(pdf|xml))$'
    WebServers            = @('https://ihs-wb-p02.pktic.fiscalad.treasury.gov')
    PollIntervalMs        = 900
    TimeoutSeconds        = 180
    UseHeadVsGet          = 'HEAD' # "HEAD"|"GET"
    CertVerificationEnabled = $false
}

if (-not (Test-Path -LiteralPath $ConfigPath)) {
    $json = ($DefaultConfig | ConvertTo-Json -Depth 10)
    [System.IO.File]::WriteAllText($ConfigPath, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Load-Config {
    param([string]$Path)
    try {
        $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
        $cfg = $raw | ConvertFrom-Json

        # Minimal validation (no "auto-filling" assumptions; fail fast if invalid)
        foreach ($p in @('RootUNC','Subfolders','FilenameRegex','WebServers','PollIntervalMs','TimeoutSeconds','UseHeadVsGet','CertVerificationEnabled')) {
            if (-not ($cfg.PSObject.Properties.Name -contains $p)) {
                throw "Missing config field: $p"
            }
        }
        if (-not ($cfg.Subfolders -is [System.Array])) { throw "Config Subfolders must be an array." }
        if (-not ($cfg.WebServers -is [System.Array])) { throw "Config WebServers must be an array." }
        if ($cfg.UseHeadVsGet -notin @('HEAD','GET')) { throw 'Config UseHeadVsGet must be "HEAD" or "GET".' }

        return $cfg
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Error loading config.json:`r`n$($_.Exception.Message)`r`n`r`nFix config.json and restart.",
            "Config Error",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
        throw
    }
}

$Config = Load-Config -Path $ConfigPath

# Ensure logs dir exists
if (-not (Test-Path -LiteralPath $LogsDir)) {
    New-Item -ItemType Directory -Path $LogsDir -Force | Out-Null
}

# Log retention: keep last 5 days (cleanup at startup)
function Cleanup-OldLogs {
    param([string]$Dir)
    try {
        $cutoff = (Get-Date).Date.AddDays(-5)
        Get-ChildItem -LiteralPath $Dir -File -Filter 'app-*.log' -ErrorAction SilentlyContinue | ForEach-Object {
            $m = [regex]::Match($_.BaseName, '^app-(\d{8})$')
            if ($m.Success) {
                $dt = [datetime]::ParseExact($m.Groups[1].Value, 'yyyyMMdd', $null)
                if ($dt -lt $cutoff) {
                    Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
                }
            }
        }
    } catch {
        # ignore
    }
}
Cleanup-OldLogs -Dir $LogsDir

# -----------------------------
# Shared state (sync hash)
# -----------------------------
$sync = [hashtable]::Synchronized(@{})
$sync.ScriptDir = $ScriptDir
$sync.LogsDir   = $LogsDir
$sync.LogLock   = New-Object object
$sync.ActiveRequests = New-Object 'System.Collections.Concurrent.ConcurrentDictionary[string,System.Net.HttpWebRequest]'
$sync.ActivePipelines = New-Object System.Collections.Generic.List[object]  # store PowerShell instances (UI thread only)
$sync.Monitoring = $false
$sync.Config = $Config

# TLS: always set TLS 1.2; cert callback set on Start based on config, restored on Stop
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
$sync.PrevCertCallback = $null
$sync.CertCallbackSet = $false

function Write-LogLine {
    param(
        [ValidateSet('INFO','WARN','ERROR')]
        [string]$Level,
        [string]$Message
    )

    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
    $line = "$ts [$Level] $Message"
    $logFile = Join-Path $sync.LogsDir ("app-{0}.log" -f (Get-Date -Format 'yyyyMMdd'))

    [System.Threading.Monitor]::Enter($sync.LogLock)
    try {
        [System.IO.File]::AppendAllText($logFile, $line + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
    } finally {
        [System.Threading.Monitor]::Exit($sync.LogLock)
    }

    # UI error panel only for WARN/ERROR (marshaled)
    if ($Level -in @('WARN','ERROR') -and $sync.Form -and -not $sync.Form.IsDisposed) {
        $null = $sync.Form.BeginInvoke($sync.AppendErrorLine, @($line))
    }
}

# -----------------------------
# Build UI
# -----------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = 'File Replication Monitor'
$form.StartPosition = 'CenterScreen'
$form.Width = 1100
$form.Height = 700

$panelTop = New-Object System.Windows.Forms.Panel
$panelTop.Dock = 'Top'
$panelTop.Height = 44

$btnStart = New-Object System.Windows.Forms.Button
$btnStart.Text = 'Start'
$btnStart.Width = 90
$btnStart.Height = 28
$btnStart.Left = 10
$btnStart.Top = 8

$btnStop = New-Object System.Windows.Forms.Button
$btnStop.Text = 'Stop'
$btnStop.Width = 90
$btnStop.Height = 28
$btnStop.Left = 110
$btnStop.Top = 8
$btnStop.Enabled = $false

$btnClear = New-Object System.Windows.Forms.Button
$btnClear.Text = 'Clear'
$btnClear.Width = 90
$btnClear.Height = 28
$btnClear.Left = 210
$btnClear.Top = 8

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.AutoSize = $true
$lblStatus.Left = 320
$lblStatus.Top = 12
$lblStatus.Font = New-Object System.Drawing.Font('Segoe UI', 11, [System.Drawing.FontStyle]::Bold)
$lblStatus.Text = 'STOPPED!'
$lblStatus.ForeColor = [System.Drawing.Color]::Red

$panelTop.Controls.AddRange(@($btnStart,$btnStop,$btnClear,$lblStatus))

$grid = New-Object System.Windows.Forms.DataGridView
$grid.Dock = 'Fill'
$grid.ReadOnly = $true
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.AllowUserToOrderColumns = $false
$grid.MultiSelect = $false
$grid.RowHeadersVisible = $false
$grid.SelectionMode = 'FullRowSelect'
$grid.AutoSizeColumnsMode = 'Fill'

# Build columns: Filename + one per server (exact base URL text)
$colFile = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$colFile.HeaderText = 'Filename'
$colFile.SortMode = 'NotSortable'
$null = $grid.Columns.Add($colFile)

for ($i=0; $i -lt $Config.WebServers.Count; $i++) {
    $server = [string]$Config.WebServers[$i]
    $c = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $c.HeaderText = $server
    $c.SortMode = 'NotSortable'
    $null = $grid.Columns.Add($c)
}

$txtErrors = New-Object System.Windows.Forms.TextBox
$txtErrors.Dock = 'Bottom'
$txtErrors.Height = 140
$txtErrors.Multiline = $true
$txtErrors.ReadOnly = $true
$txtErrors.ScrollBars = 'Vertical'
$txtErrors.BackColor = [System.Drawing.SystemColors]::Window
$txtErrors.Font = New-Object System.Drawing.Font('Consolas', 9)

$form.Controls.Add($grid)
$form.Controls.Add($txtErrors)
$form.Controls.Add($panelTop)

$sync.Form = $form
$sync.Grid = $grid
$sync.ErrorBox = $txtErrors
$sync.ErrorLines = New-Object System.Collections.Generic.List[string]

# Delegates for UI-safe updates
$sync.UpdateCell = [System.Action[int,int,string]]{
    param($rowIndex,$colIndex,$value)
    try {
        if ($rowIndex -ge 0 -and $rowIndex -lt $sync.Grid.Rows.Count) {
            $sync.Grid.Rows[$rowIndex].Cells[$colIndex].Value = $value
        }
    } catch { }
}

$sync.AppendErrorLine = [System.Action[string]]{
    param($line)
    try {
        $sync.ErrorLines.Add($line) | Out-Null
        while ($sync.ErrorLines.Count -gt 500) {
            $sync.ErrorLines.RemoveAt(0)
        }
        $sync.ErrorBox.Lines = $sync.ErrorLines.ToArray()
        $sync.ErrorBox.SelectionStart = $sync.ErrorBox.TextLength
        $sync.ErrorBox.ScrollToCaret()
    } catch { }
}

$sync.SetStatus = [System.Action[bool]]{
    param($isMonitoring)
    if ($isMonitoring) {
        $lblStatus.Text = 'MONITORING'
        $lblStatus.ForeColor = [System.Drawing.Color]::Green
    } else {
        $lblStatus.Text = 'STOPPED!'
        $lblStatus.ForeColor = [System.Drawing.Color]::Red
    }
}

# -----------------------------
# Monitoring: Watchers + RunspacePool
# -----------------------------
$script:WatcherInfos = @()   # list of objects holding watcher + event source identifiers
$script:Regex = $null

function Get-AbsoluteSubfolderPath {
    param([string]$RootUNC, [string]$Subfolder)

    # RootUNC is document root; subfolder is relative under root
    return (Join-Path -Path $RootUNC -ChildPath $Subfolder)
}

function Validate-StartPrereqs {
    $root = [string]$sync.Config.RootUNC
    if (-not (Test-Path -LiteralPath $root)) {
        return "RootUNC not reachable: $root"
    }

    foreach ($sf in $sync.Config.Subfolders) {
        $p = Get-AbsoluteSubfolderPath -RootUNC $root -Subfolder ([string]$sf)
        if (-not (Test-Path -LiteralPath $p -PathType Container)) {
            return "Subfolder not reachable or not a directory: $p"
        }
    }

    if ($sync.Config.WebServers.Count -lt 1) {
        return "WebServers is empty in config.json."
    }

    foreach ($ws in $sync.Config.WebServers) {
        $s = [string]$ws
        if (-not [Uri]::IsWellFormedUriString($s, [UriKind]::Absolute)) {
            return "WebServers contains a non-absolute URL: $s"
        }
        $u = [Uri]$s
        if ($u.Scheme -ne 'https') {
            return "WebServers entry must be HTTPS (https://...): $s"
        }
    }

    # Validate regex compilation
    try {
        $script:Regex = New-Object System.Text.RegularExpressions.Regex(
            [string]$sync.Config.FilenameRegex,
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
    } catch {
        return "Invalid FilenameRegex: $($_.Exception.Message)"
    }

    return $null
}

function Build-UrlForFile {
    param(
        [string]$BaseUrl,
        [string]$RootUNC,
        [string]$FullPath
    )

    # Normalize base URL (trim trailing slash)
    $base = $BaseUrl.TrimEnd('/')

    # Ensure root ends with backslash
    $root = $RootUNC
    if (-not $root.EndsWith('\')) { $root += '\' }

    # Compute relative path under doc root
    if (-not $FullPath.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        # Should not happen if watcher paths are within root; ignore if it does.
        return $null
    }

    $rel = $FullPath.Substring($root.Length) # e.g. instit\...\foo.pdf
    $relPath = $rel -replace '\\','/' # normalize backslashes
    
    # Use System.Uri to properly handle URL construction and avoid double slashes
    try {
        $baseUri = New-Object System.Uri($base + '/')
        $mergedUri = New-Object System.Uri($baseUri, $relPath)
        return $mergedUri.AbsoluteUri
    } catch {
        # Fallback to simple concatenation if Uri parsing fails
        return ($base + '/' + $relPath)
    }
}

function Stop-Monitoring {
    if (-not $sync.Monitoring) { return }

    Write-LogLine -Level 'INFO' -Message 'Stop requested.'

    # Cancel token
    try {
        if ($sync.Cts) { $sync.Cts.Cancel() }
    } catch { }

    # Abort active requests immediately
    try {
        foreach ($kvp in $sync.ActiveRequests.GetEnumerator()) {
            try { $kvp.Value.Abort() } catch { }
        }
    } catch { }

    # Stop pipelines (best-effort)
    try {
        foreach ($p in $sync.ActivePipelines.ToArray()) {
            try { $p.Stop() } catch { }
            try { $p.Dispose() } catch { }
        }
        $sync.ActivePipelines.Clear()
    } catch { }

    # Unregister events + dispose watchers
    foreach ($wi in $script:WatcherInfos) {
        try { Unregister-Event -SourceIdentifier $wi.CreatedSid -ErrorAction SilentlyContinue } catch { }
        try { Unregister-Event -SourceIdentifier $wi.ErrorSid   -ErrorAction SilentlyContinue } catch { }
        try { $wi.Watcher.EnableRaisingEvents = $false } catch { }
        try { $wi.Watcher.Dispose() } catch { }
    }
    $script:WatcherInfos = @()

    # RunspacePool cleanup (synchronous to ensure completion before exit)
    if ($sync.Pool) {
        try { $sync.Pool.Close() } catch { }
        try { $sync.Pool.Dispose() } catch { }
        $sync.Pool = $null
    }

    # Restore cert callback if we changed it
    if ($sync.CertCallbackSet) {
        try { [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $sync.PrevCertCallback } catch { }
        $sync.CertCallbackSet = $false
    }

    $sync.ActiveRequests.Clear() | Out-Null
    $sync.Monitoring = $false
    $btnStart.Enabled = $true
    $btnStop.Enabled = $false
    $sync.SetStatus.Invoke($false)
}

function Start-Monitoring {
    if ($sync.Monitoring) { return }

    $err = Validate-StartPrereqs
    if ($err) {
        [System.Windows.Forms.MessageBox]::Show(
            $err,
            "Cannot Start",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        Write-LogLine -Level 'WARN' -Message "Start blocked: $err"
        return
    }

    # Certificate behavior for polling
    if (-not $sync.Config.CertVerificationEnabled) {
        try {
            $sync.PrevCertCallback = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
        } catch {
            $sync.PrevCertCallback = $null
        }
        try {
            [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
            $sync.CertCallbackSet = $true
        } catch {
            # ignore
        }
    }

    $sync.Cts = New-Object System.Threading.CancellationTokenSource

    # RunspacePool max concurrency: reasonable default of min(8, cpu_count)
    # Polling is I/O-bound, not CPU-bound; avoid excessive thread creation
    $cpu = [Environment]::ProcessorCount
    $max = [Math]::Min(8, [Math]::Max(2, $cpu))
    $pool = [RunspaceFactory]::CreateRunspacePool(1, $max)
    $pool.ApartmentState = 'MTA'  # background work; UI stays STA
    $pool.ThreadOptions = 'ReuseThread'
    $pool.Open()
    $sync.Pool = $pool

    # Create watchers
    $root = [string]$sync.Config.RootUNC
    foreach ($sf in $sync.Config.Subfolders) {
        $sub = [string]$sf
        $path = Get-AbsoluteSubfolderPath -RootUNC $root -Subfolder $sub

        $w = New-Object System.IO.FileSystemWatcher
        $w.Path = $path
        $w.Filter = '*.*'
        $w.IncludeSubdirectories = $false
        $w.NotifyFilter = [System.IO.NotifyFilters]::FileName
        $w.EnableRaisingEvents = $true

        $createdSid = "FSW_CREATED_$([guid]::NewGuid().ToString('N'))"
        $errorSid   = "FSW_ERROR_$([guid]::NewGuid().ToString('N'))"

        # Created event
        Register-ObjectEvent -InputObject $w -EventName Created -SourceIdentifier $createdSid -MessageData $sync -Action {
            $sync = $Event.MessageData
            try {
                $fp = $Event.SourceEventArgs.FullPath
                if ($sync.Monitoring -and $sync.Form -and -not $sync.Form.IsDisposed) {
                    try {
                        $null = $sync.Form.BeginInvoke($sync.HandleFileCreated, @($fp))
                    } catch {
                        # Form disposed between check and invoke; ignore
                    }
                }
            } catch {
                # Log file operation errors
                Write-LogLine -Level 'WARN' -Message "FileSystemWatcher event error: $($_.Exception.Message)"
            }
        } | Out-Null

        # Error event
        Register-ObjectEvent -InputObject $w -EventName Error -SourceIdentifier $errorSid -MessageData @{ Sync=$sync; Subfolder=$sub; Path=$path } -Action {
            $md = $Event.MessageData
            $sync = $md.Sync
            $sub  = $md.Subfolder
            $p    = $md.Path
            $exMsg = $null
            try { $exMsg = $Event.SourceEventArgs.GetException().Message } catch { $exMsg = 'Unknown watcher error' }

            if ($sync.Form -and -not $sync.Form.IsDisposed) {
                try {
                    $null = $sync.Form.BeginInvoke($sync.HandleWatcherError, @($sub, $p, $exMsg))
                } catch {
                    # Form disposed between check and invoke; ignore
                }
            }
        } | Out-Null

        $script:WatcherInfos += [pscustomobject]@{
            Watcher    = $w
            Subfolder  = $sub
            Path       = $path
            CreatedSid = $createdSid
            ErrorSid   = $errorSid
        }
    }

    $sync.Monitoring = $true
    $btnStart.Enabled = $false
    $btnStop.Enabled = $true
    $sync.SetStatus.Invoke($true)
    Write-LogLine -Level 'INFO' -Message "Monitoring started. Watchers: $($script:WatcherInfos.Count). RunspacePool max: $max."
}

# UI handler: file created
$sync.HandleFileCreated = [System.Action[string]]{
    param($fullPath)

    if (-not $sync.Monitoring) { return }

    try {
        $fileName = [System.IO.Path]::GetFileName($fullPath)
    } catch {
        $errMsg = $_.Exception.Message
        Write-LogLine -Level 'WARN' -Message "Error extracting filename from: $fullPath - $errMsg"
        return
    }
    
    if (-not $fileName) { return }

    # Filter by regex (case-insensitive)
    if (-not $script:Regex.IsMatch($fileName)) {
        return
    }

    # Add new row (even if same filename appears later)
    try {
        $rowIndex = $sync.Grid.Rows.Add()
    } catch {
        $errMsg = $_.Exception.Message
        Write-LogLine -Level 'ERROR' -Message "Failed to add grid row : $errMsg"
        return
    }
    
    try {
        $sync.Grid.Rows[$rowIndex].Cells[0].Value = $fileName

        # Tag includes full path + timestamp (internal distinction)
        $sync.Grid.Rows[$rowIndex].Tag = [pscustomobject]@{
            FullPath = $fullPath
            SeenAt   = (Get-Date)
        }

        # Set initial statuses
        for ($si=0; $si -lt $sync.Config.WebServers.Count; $si++) {
            $sync.Grid.Rows[$rowIndex].Cells[$si + 1].Value = 'Scanning... (0s)'
        }
    } catch {
        $errMsg = $_.Exception.Message
        Write-LogLine -Level 'ERROR' -Message "Failed to update grid row $rowIndex : $errMsg"
        return
    }

    Write-LogLine -Level 'INFO' -Message "File detected: $fullPath"

    # Start polling all servers in parallel (subject to global cap)
    $token = $sync.Cts.Token
    $method = [string]$sync.Config.UseHeadVsGet
    $intervalMs = [int]$sync.Config.PollIntervalMs
    $timeoutSec = [int]$sync.Config.TimeoutSeconds
    $root = [string]$sync.Config.RootUNC

    $pollScript = {
        param($sync, $rowIndex, $colIndex, $fileName, $url, $baseUrl, $token, $method, $intervalMs, $timeoutSec)

        function LogLocal {
            param([string]$Level, [string]$Message)

            $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss.fff')
            $line = "$ts [$Level] $Message"
            $logFile = Join-Path $sync.LogsDir ("app-{0}.log" -f (Get-Date -Format 'yyyyMMdd'))

            [System.Threading.Monitor]::Enter($sync.LogLock)
            try {
                [System.IO.File]::AppendAllText($logFile, $line + [Environment]::NewLine, (New-Object System.Text.UTF8Encoding($false)))
            } finally {
                [System.Threading.Monitor]::Exit($sync.LogLock)
            }
        }

        $start = [DateTime]::UtcNow
        $deadline = $start.AddSeconds($timeoutSec)
        $hadHttpResponse = $false
        $lastSec = -1
        $lastException = $null

        while (-not $token.IsCancellationRequested) {
            $loopStart = [DateTime]::UtcNow
            $now = [DateTime]::UtcNow
            if ($now -ge $deadline) { break }

            $elapsed = ($now - $start).TotalSeconds
            $sec = [int][Math]::Floor($elapsed)
            if ($sec -ne $lastSec) {
                $lastSec = $sec
                try { $null = $sync.Grid.BeginInvoke($sync.UpdateCell, @($rowIndex, $colIndex, ("Scanning... ({0}s)" -f $sec))) } catch { }
            }

            $reqId = [guid]::NewGuid().ToString('N')
            $req = $null
            $resp = $null

            try {
                $req = [System.Net.HttpWebRequest]::Create($url)
                $req.Method = $method
                $req.AllowAutoRedirect = $false

                if ($method -eq 'GET') {
                    try { $req.AllowReadStreamBuffering = $false } catch { }
                }

                # Track active request for abort-on-cancel (must be done BEFORE GetResponse)
                [void]$sync.ActiveRequests.TryAdd($reqId, $req)

                try {
                    $resp = $req.GetResponse()
                    $status = [int]$resp.StatusCode
                    $hadHttpResponse = $true

                    if ($method -eq 'GET') {
                        try {
                            $stream = $resp.GetResponseStream()
                            if ($stream) {
                                try { $stream.Dispose() } catch { }
                            }
                        } catch { }
                    }

                    try { $resp.Dispose() } catch { $resp.Close() }

                    if ($status -eq 200) {
                        $final = ("OK ({0}s)" -f $sec)
                        try { $null = $sync.Grid.BeginInvoke($sync.UpdateCell, @($rowIndex, $colIndex, $final)) } catch { }
                        LogLocal -Level 'INFO' -Message "Result: OK | Server=$baseUrl | File=$fileName | URL=$url | Elapsed=${sec}s"
                        return
                    }

                    # Not 200 (includes redirects) -> continue until timeout
                } catch [System.Net.WebException] {
                    $we = $_.Exception
                    $lastException = $we.Message

                    # If response exists, it's still a valid HTTP response (e.g., 404/301/500)
                    if ($we.Response -ne $null) {
                        try {
                            $r = [System.Net.HttpWebResponse]$we.Response
                            $status = [int]$r.StatusCode
                            $hadHttpResponse = $true
                            if ($method -eq 'GET') {
                                try {
                                    $stream = $r.GetResponseStream()
                                    if ($stream) {
                                        try { $stream.Dispose() } catch { }
                                    }
                                } catch { }
                            }
                            try { $r.Dispose() } catch { $r.Close() }

                            if ($status -eq 200) {
                                $final = ("OK ({0}s)" -f $sec)
                                try { $null = $sync.Grid.BeginInvoke($sync.UpdateCell, @($rowIndex, $colIndex, $final)) } catch { }
                                LogLocal -Level 'INFO' -Message "Result: OK | Server=$baseUrl | File=$fileName | URL=$url | Elapsed=${sec}s"
                                return
                            }
                        } catch {
                            # treat as exception-only
                        }
                    } else {
                        # exception without HTTP response; retry until overall timeout
                        # (no UI spam; only final outcome will show ERROR if never got any response)
                    }
                } finally {
                # Always cleanup resources
                if ($resp) {
                    try { $resp.Dispose() } catch { try { $resp.Close() } catch { } }
                    $resp = $null
                }
                if ($req) {
                    try { $req.Abort() } catch { }
                    $req = $null
                }
                [void]$sync.ActiveRequests.TryRemove($reqId, [ref]$null)
            }
        } catch {
            $lastException = $_.Exception.Message

            if ($token.IsCancellationRequested) { break }
            
            # Sleep for the remaining interval (account for request time)
            $loopElapsed = ([DateTime]::UtcNow - $loopStart).TotalMilliseconds
            $sleepMs = [Math]::Max(0, $intervalMs - $loopElapsed)
            if ($sleepMs -gt 0) { Start-Sleep -Milliseconds $sleepMs }
        }

        # Final outcome
        $finalSec = [int][Math]::Floor(([DateTime]::UtcNow - $start).TotalSeconds)
        if ($token.IsCancellationRequested) {
            # On cancel, do not overwrite final states unnecessarily; leave as-is
            return
        }

        if ($hadHttpResponse) {
            $final = ("TIMEOUT ({0}s)" -f $finalSec)
            try { $null = $sync.Grid.BeginInvoke($sync.UpdateCell, @($rowIndex, $colIndex, $final)) } catch { }
            LogLocal -Level 'INFO' -Message "Result: TIMEOUT | Server=$baseUrl | File=$fileName | URL=$url | Elapsed=${finalSec}s"
        } else {
            $final = ("ERROR ({0}s)" -f $finalSec)
            try { $null = $sync.Grid.BeginInvoke($sync.UpdateCell, @($rowIndex, $colIndex, $final)) } catch { }
            LogLocal -Level 'INFO' -Message "Result: ERROR | Server=$baseUrl | File=$fileName | URL=$url | Elapsed=${finalSec}s | LastException=$lastException"
        }
    }

    for ($si=0; $si -lt $sync.Config.WebServers.Count; $si++) {
        $baseUrl = [string]$sync.Config.WebServers[$si]
        $url = Build-UrlForFile -BaseUrl $baseUrl -RootUNC $root -FullPath $fullPath
        if (-not $url) { continue }

        $colIndex = $si + 1

        $ps = [PowerShell]::Create()
        $ps.RunspacePool = $sync.Pool
        $null = $ps.AddScript($pollScript).
            AddArgument($sync).
            AddArgument($rowIndex).
            AddArgument($colIndex).
            AddArgument($fileName).
            AddArgument($url).
            AddArgument($baseUrl).
            AddArgument($token).
            AddArgument($method).
            AddArgument($intervalMs).
            AddArgument($timeoutSec)

        # Track pipeline so Stop can attempt to stop/dispose
        $sync.ActivePipelines.Add($ps) | Out-Null

        try { [void]$ps.BeginInvoke() } catch {
            try { $ps.Dispose() } catch { }
        }
    }
}

# UI handler: watcher error -> attempt restart
$sync.HandleWatcherError = [System.Action[string,string,string]]{
    param($subfolder, $path, $exMessage)

    Write-LogLine -Level 'WARN' -Message "Watcher error on [$subfolder] ($path): $exMessage. Attempting restart."

    # Find existing watcher info
    $wi = $script:WatcherInfos | Where-Object { $_.Subfolder -eq $subfolder } | Select-Object -First 1
    if (-not $wi) { return }

    # Stop and dispose existing watcher + unregister events
    try { Unregister-Event -SourceIdentifier $wi.CreatedSid -ErrorAction SilentlyContinue } catch { }
    try { Unregister-Event -SourceIdentifier $wi.ErrorSid   -ErrorAction SilentlyContinue } catch { }
    try { $wi.Watcher.EnableRaisingEvents = $false } catch { }
    try { $wi.Watcher.Dispose() } catch { }

    # Remove from list
    $script:WatcherInfos = @($script:WatcherInfos | Where-Object { $_.Subfolder -ne $subfolder })

    # Attempt recreate
    try {
        $w = New-Object System.IO.FileSystemWatcher
        $w.Path = $path
        $w.Filter = '*.*'
        $w.IncludeSubdirectories = $false
        $w.NotifyFilter = [System.IO.NotifyFilters]::FileName
        $w.EnableRaisingEvents = $true

        $createdSid = "FSW_CREATED_$([guid]::NewGuid().ToString('N'))"
        $errorSid   = "FSW_ERROR_$([guid]::NewGuid().ToString('N'))"

        Register-ObjectEvent -InputObject $w -EventName Created -SourceIdentifier $createdSid -MessageData $sync -Action {
            $sync = $Event.MessageData
            try {
                $fp = $Event.SourceEventArgs.FullPath
                if ($sync.Monitoring -and $sync.Form -and -not $sync.Form.IsDisposed) {
                    $null = $sync.Form.BeginInvoke($sync.HandleFileCreated, @($fp))
                }
            } catch { }
        } | Out-Null

        Register-ObjectEvent -InputObject $w -EventName Error -SourceIdentifier $errorSid -MessageData @{ Sync=$sync; Subfolder=$subfolder; Path=$path } -Action {
            $md = $Event.MessageData
            $sync = $md.Sync
            $sub  = $md.Subfolder
            $p    = $md.Path
            $exMsg = $null
            try { $exMsg = $Event.SourceEventArgs.GetException().Message } catch { $exMsg = 'Unknown watcher error' }
            if ($sync.Form -and -not $sync.Form.IsDisposed) {
                $null = $sync.Form.BeginInvoke($sync.HandleWatcherError, @($sub, $p, $exMsg))
            }
        } | Out-Null

        $script:WatcherInfos += [pscustomobject]@{
            Watcher    = $w
            Subfolder  = $subfolder
            Path       = $path
            CreatedSid = $createdSid
            ErrorSid   = $errorSid
        }

        Write-LogLine -Level 'INFO' -Message "Watcher restarted successfully for [$subfolder] ($path)."
    } catch {
        $msg = "Monitoring is broken (watcher restart failed) for:`r`n$path`r`n`r`nYou must use an older script."
        [System.Windows.Forms.MessageBox]::Show(
            $msg,
            "Monitoring Broken",
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        Write-LogLine -Level 'ERROR' -Message "Watcher restart FAILED for [$subfolder] ($path): $($_.Exception.Message)"
    }
}

# -----------------------------
# Button wiring
# -----------------------------
$btnStart.Add_Click({
    try { Start-Monitoring } catch { Write-LogLine -Level 'ERROR' -Message "Start error: $($_.Exception.Message)" }
})

$btnStop.Add_Click({
    try { Stop-Monitoring } catch { Write-LogLine -Level 'ERROR' -Message "Stop error: $($_.Exception.Message)" }
})

$btnClear.Add_Click({
    try {
        Stop-Monitoring
        $grid.Rows.Clear()
        $sync.ErrorLines.Clear()
        $txtErrors.Clear()
        Write-LogLine -Level 'INFO' -Message 'Clear requested (Stop + cleared grid and error panel).'
    } catch {
        Write-LogLine -Level 'ERROR' -Message "Clear error: $($_.Exception.Message)"
    }
})

$form.Add_FormClosing({
    try { Stop-Monitoring } catch { }
})

# Initial log
Write-LogLine -Level 'INFO' -Message "App started. ScriptDir=$ScriptDir"

# Run UI
[System.Windows.Forms.Application]::Run($form)
