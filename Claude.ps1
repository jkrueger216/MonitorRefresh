<#
  File Replication Monitor (PowerShell 5.1 / WinForms)
  - Monitors UNC subfolders (non-recursive) for Created events
  - Filters by regex (case-insensitive)
  - Polls replication across HTTPS web servers using RunspacePool
  - GUI-only (auto-hide console, auto-relaunch in STA if needed)
#>

param(
    [switch]$Relaunched
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ============================================================================
# SECTION 1: STA RELAUNCH + CONSOLE HIDING
# ============================================================================

# Console hiding via Windows API
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
            [void][Win32.NativeMethods]::ShowWindow($hWnd, 0)  # SW_HIDE = 0
        }
    } catch {}
}

# Relaunch in STA if needed (prevent infinite loop with $Relaunched parameter)
if (-not $Relaunched -and [System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    try {
        $psExe = (Get-Command powershell.exe -ErrorAction Stop).Source
        $scriptPath = $MyInvocation.MyCommand.Path
        if (-not $scriptPath) { $scriptPath = $PSCommandPath }
        
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $psExe
        $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -Sta -File `"$scriptPath`" -Relaunched"
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        
        [void][System.Diagnostics.Process]::Start($psi)
    } catch {}
    exit
}

Hide-ConsoleWindow

# ============================================================================
# SECTION 2: LOAD ASSEMBLIES
# ============================================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

# ============================================================================
# SECTION 3: PATHS + CONFIG
# ============================================================================

$ScriptDir = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$ConfigPath = Join-Path $ScriptDir 'config.json'
$LogsDir    = Join-Path $ScriptDir 'logs'

$DefaultConfig = @{
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
    UseHeadVsGet          = 'HEAD'  # 'HEAD' or 'GET'
    CertVerificationEnabled = $false
}

# Auto-create config if missing
if (-not (Test-Path -LiteralPath $ConfigPath)) {
    $DefaultConfig | ConvertTo-Json -Depth 10 | Set-Content $ConfigPath
}

# Load config
function Load-Config {
    param([string]$Path)
    try {
        $cfg = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
        # Minimal validation
        foreach ($field in @('RootUNC','Subfolders','FilenameRegex','WebServers','PollIntervalMs','TimeoutSeconds','UseHeadVsGet','CertVerificationEnabled')) {
            if (-not ($cfg.PSObject.Properties.Name -contains $field)) {
                throw "Missing config field: $field"
            }
        }
        return $cfg
    } catch {
        [System.Windows.Forms.MessageBox]::Show(
            "Error loading config.json:`r`n$($_.Exception.Message)",
            'Config Error',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Error
        ) | Out-Null
        exit 1
    }
}

$Config = Load-Config -Path $ConfigPath

# Ensure logs dir exists
if (-not (Test-Path -LiteralPath $LogsDir)) {
    New-Item -ItemType Directory -Path $LogsDir -Force | Out-Null
}

# Log cleanup (retain last 5 days)
function Cleanup-OldLogs {
    param([string]$Dir)
    try {
        $cutoff = (Get-Date).Date.AddDays(-5)
        Get-ChildItem -LiteralPath $Dir -File -Filter 'app-*.log' -ErrorAction SilentlyContinue | ForEach-Object {
            if ($_.BaseName -match '^app-(\d{8})$') {
                $dt = [datetime]::ParseExact($Matches[1], 'yyyyMMdd', $null)
                if ($dt -lt $cutoff) {
                    Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
                }
            }
        }
    } catch {}
}
Cleanup-OldLogs -Dir $LogsDir

# ============================================================================
# SECTION 4: SHARED STATE
# ============================================================================

$sync = [hashtable]::Synchronized(@{})
$sync.ScriptDir     = $ScriptDir
$sync.LogsDir       = $LogsDir
$sync.LogLock       = New-Object object
$sync.Config        = $Config
$sync.Monitoring    = $false
$sync.CtsToken      = $null
$sync.Pool          = $null
$sync.WatcherInfos  = @()

# TLS
[System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
$sync.CertCallbackPrev = $null

# ============================================================================
# SECTION 5: LOGGING
# ============================================================================

function Write-AppLog {
    param(
        [ValidateSet('INFO','WARN','ERROR')]
        [string]$Level,
        [string]$Message
    )
    
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    $line = "[$ts] [$Level] $Message"
    $logFile = Join-Path $sync.LogsDir ("app-{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
    
    [System.Threading.Monitor]::Enter($sync.LogLock)
    try {
        Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue
    } finally {
        [System.Threading.Monitor]::Exit($sync.LogLock)
    }
}

# ============================================================================
# SECTION 6: UI BUILD
# ============================================================================

$form = New-Object System.Windows.Forms.Form
$form.Text = 'File Replication Monitor'
$form.Size = New-Object System.Drawing.Size(1200, 700)
$form.StartPosition = 'CenterScreen'

# Top panel: buttons + status
$panelTop = New-Object System.Windows.Forms.Panel
$panelTop.Dock = 'Top'
$panelTop.Height = 45

$btnStart = New-Object System.Windows.Forms.Button
$btnStart.Text = 'Start'
$btnStart.Width = 80
$btnStart.Height = 28
$btnStart.Left = 10
$btnStart.Top = 8

$btnStop = New-Object System.Windows.Forms.Button
$btnStop.Text = 'Stop'
$btnStop.Width = 80
$btnStop.Height = 28
$btnStop.Left = 100
$btnStop.Top = 8
$btnStop.Enabled = $false

$btnClear = New-Object System.Windows.Forms.Button
$btnClear.Text = 'Clear'
$btnClear.Width = 80
$btnClear.Height = 28
$btnClear.Left = 190
$btnClear.Top = 8

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = 'STOPPED!'
$lblStatus.ForeColor = [System.Drawing.Color]::Red
$lblStatus.Font = New-Object System.Drawing.Font('Arial', 11, [System.Drawing.FontStyle]::Bold)
$lblStatus.AutoSize = $true
$lblStatus.Left = 290
$lblStatus.Top = 12

$panelTop.Controls.Add($btnStart)
$panelTop.Controls.Add($btnStop)
$panelTop.Controls.Add($btnClear)
$panelTop.Controls.Add($lblStatus)

# Grid for files
$grid = New-Object System.Windows.Forms.DataGridView
$grid.Dock = 'Fill'
$grid.ReadOnly = $true
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.AllowUserToOrderColumns = $false
$grid.RowHeadersVisible = $false
$grid.SelectionMode = 'FullRowSelect'
$grid.AutoSizeColumnsMode = 'Fill'

# Columns: Filename + servers
$col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$col.HeaderText = 'Filename'
$NULL = $grid.Columns.Add($col)

foreach ($srv in $Config.WebServers) {
    $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $col.HeaderText = [string]$srv
    $NULL = $grid.Columns.Add($col)
}

# Error panel at bottom
$errorBox = New-Object System.Windows.Forms.RichTextBox
$errorBox.Dock = 'Bottom'
$errorBox.Height = 150
$errorBox.ReadOnly = $true
$errorBox.BackColor = [System.Drawing.SystemColors]::Window
$errorBox.Font = New-Object System.Drawing.Font('Consolas', 9)

$form.Controls.Add($grid)
$form.Controls.Add($errorBox)
$form.Controls.Add($panelTop)

$sync.Form = $form
$sync.Grid = $grid
$sync.ErrorBox = $errorBox
$sync.ErrorLines = [System.Collections.Generic.List[string]]::new()

# ============================================================================
# SECTION 7: UI HELPERS
# ============================================================================

# Thread-safe grid update
function Update-GridCell {
    param($RowIdx, $ColIdx, $Value)
    try {
        if ($RowIdx -ge 0 -and $RowIdx -lt $sync.Grid.Rows.Count -and $ColIdx -ge 0 -and $ColIdx -lt $sync.Grid.Columns.Count) {
            $sync.Grid.Rows[$RowIdx].Cells[$ColIdx].Value = $Value
        }
    } catch {}
}

# Thread-safe error panel append
function Add-ErrorLine {
    param([string]$Line)
    try {
        $sync.ErrorLines.Add($Line) | Out-Null
        while ($sync.ErrorLines.Count -gt 500) {
            $sync.ErrorLines.RemoveAt(0)
        }
        $sync.ErrorBox.Lines = $sync.ErrorLines.ToArray()
        $sync.ErrorBox.SelectionStart = $sync.ErrorBox.TextLength
        $sync.ErrorBox.ScrollToCaret()
    } catch {}
}

function Set-StatusLabel {
    param([bool]$IsMonitoring)
    if ($IsMonitoring) {
        $lblStatus.Text = 'MONITORING'
        $lblStatus.ForeColor = [System.Drawing.Color]::Green
    } else {
        $lblStatus.Text = 'STOPPED!'
        $lblStatus.ForeColor = [System.Drawing.Color]::Red
    }
}

# ============================================================================
# SECTION 8: VALIDATION
# ============================================================================

function Validate-Prerequisites {
    $root = [string]$sync.Config.RootUNC
    
    # Check root
    if (-not (Test-Path -LiteralPath $root -PathType Container)) {
        return "RootUNC not reachable: $root"
    }
    
    # Check subfolders
    foreach ($sub in $sync.Config.Subfolders) {
        $path = Join-Path -Path $root -ChildPath ([string]$sub)
        if (-not (Test-Path -LiteralPath $path -PathType Container)) {
            return "Subfolder not reachable: $path"
        }
    }
    
    # Validate regex
    try {
        $NULL = New-Object System.Text.RegularExpressions.Regex(
            [string]$sync.Config.FilenameRegex,
            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
        )
    } catch {
        return "Invalid FilenameRegex: $($_.Exception.Message)"
    }
    
    # Check WebServers
    foreach ($ws in $sync.Config.WebServers) {
        $u = [string]$ws
        if (-not [Uri]::IsWellFormedUriString($u, [UriKind]::Absolute)) {
            return "WebServers contains invalid URL: $u"
        }
    }
    
    return $null  # OK
}

# ============================================================================
# SECTION 9: BUILD URL FROM PATH
# ============================================================================

function Build-UrlForFile {
    param([string]$BaseUrl, [string]$RootUNC, [string]$FullPath)
    
    $root = $RootUNC
    if (-not $root.EndsWith('\')) { $root += '\' }
    
    if (-not $FullPath.StartsWith($root, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $null
    }
    
    $rel = $FullPath.Substring($root.Length)
    $relUrl = '/' + ($rel -replace '\\', '/')
    
    $base = $BaseUrl.TrimEnd('/')
    return ($base + $relUrl)
}

# ============================================================================
# SECTION 10: START MONITORING
# ============================================================================

function Start-Monitoring {
    if ($sync.Monitoring) { return }
    
    $err = Validate-Prerequisites
    if ($err) {
        [System.Windows.Forms.MessageBox]::Show(
            $err,
            'Cannot Start',
            [System.Windows.Forms.MessageBoxButtons]::OK,
            [System.Windows.Forms.MessageBoxIcon]::Warning
        ) | Out-Null
        Write-AppLog -Level WARN -Message "Start blocked: $err"
        return
    }
    
    # Setup cert callback if needed
    if (-not $sync.Config.CertVerificationEnabled) {
        try {
            $sync.CertCallbackPrev = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
        } catch {
            $sync.CertCallbackPrev = $null
        }
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
    }
    
    # Create cancellation token
    $sync.CtsToken = (New-Object System.Threading.CancellationTokenSource).Token
    
    # Create RunspacePool
    $poolSize = [Math]::Min(8, [Math]::Max(2, [Environment]::ProcessorCount))
    $sync.Pool = [RunspaceFactory]::CreateRunspacePool(1, $poolSize)
    $sync.Pool.ApartmentState = 'MTA'
    $sync.Pool.ThreadOptions = 'ReuseThread'
    $sync.Pool.Open()
    
    # Create FileSystemWatchers
    $root = [string]$sync.Config.RootUNC
    $sync.WatcherInfos = @()
    
    foreach ($sf in $sync.Config.Subfolders) {
        $sub = [string]$sf
        $path = Join-Path -Path $root -ChildPath $sub
        
        $w = New-Object System.IO.FileSystemWatcher
        $w.Path = $path
        $w.Filter = '*.*'
        $w.IncludeSubdirectories = $false
        $w.NotifyFilter = [System.IO.NotifyFilters]::FileName
        
        $createdSid = "FSW_Created_$([guid]::NewGuid().ToString('N'))"
        $errorSid = "FSW_Error_$([guid]::NewGuid().ToString('N'))"
        
        Register-ObjectEvent -InputObject $w -EventName Created -SourceIdentifier $createdSid -Action {
            param($Sender, $E)
            $sync = $global:SyncRef
            if ($sync.Monitoring) {
                $fp = $E.FullPath
                $fileName = [System.IO.Path]::GetFileName($fp)
                
                # Regex filter
                if ($fileName -match $sync.Config.FilenameRegex) {
                    $sync.Form.Invoke([Action[]]{
                        Handle-FileCreated -FullPath $fp -FileName $fileName
                    }.Invoke())
                }
            }
        } | Out-Null
        
        Register-ObjectEvent -InputObject $w -EventName Error -SourceIdentifier $errorSid -Action {
            param($Sender, $E)
            $msg = "Watcher error on [$sub]: $($E.GetException().Message)"
            Write-AppLog -Level ERROR -Message $msg
            $global:SyncRef.Form.Invoke([Action]{
                Add-ErrorLine "$((Get-Date).ToString('HH:mm:ss')) $msg"
            })
        } | Out-Null
        
        $w.EnableRaisingEvents = $true
        $sync.WatcherInfos += @{ Watcher = $w; Sub = $sub; Path = $path; CreatedSid = $createdSid; ErrorSid = $errorSid }
    }
    
    # Store sync ref globally for event handlers
    $global:SyncRef = $sync
    
    $sync.Monitoring = $true
    $btnStart.Enabled = $false
    $btnStop.Enabled = $true
    Set-StatusLabel $true
    Write-AppLog -Level INFO -Message "Monitoring started"
}

# ============================================================================
# SECTION 11: HANDLE FILE CREATED
# ============================================================================

function Handle-FileCreated {
    param([string]$FullPath, [string]$FileName)
    
    if (-not $sync.Monitoring) { return }
    
    # Add row
    $rowIdx = $sync.Grid.Rows.Add()
    $sync.Grid.Rows[$rowIdx].Cells[0].Value = $FileName
    $sync.Grid.Rows[$rowIdx].Tag = @{ FullPath = $FullPath; CreatedAt = (Get-Date) }
    
    # Init cells for servers
    for ($si = 0; $si -lt $sync.Config.WebServers.Count; $si++) {
        $sync.Grid.Rows[$rowIdx].Cells[$si + 1].Value = 'Scanning... (0s)'
    }
    
    Write-AppLog -Level INFO -Message "File detected: $FullPath"
    
    # Launch polling for all servers
    $root = [string]$sync.Config.RootUNC
    $timeout = [int]$sync.Config.TimeoutSeconds
    $interval = [int]$sync.Config.PollIntervalMs
    $method = [string]$sync.Config.UseHeadVsGet
    $token = $sync.CtsToken
    
    for ($si = 0; $si -lt $sync.Config.WebServers.Count; $si++) {
        $baseUrl = [string]$sync.Config.WebServers[$si]
        $url = Build-UrlForFile -BaseUrl $baseUrl -RootUNC $root -FullPath $FullPath
        if (-not $url) { continue }
        
        $colIdx = $si + 1
        
        $ps = [PowerShell]::Create()
        $ps.RunspacePool = $sync.Pool
        
        $pollScript = {
            param($syncRef, $rowIdx, $colIdx, $fileName, $url, $baseUrl, $token, $method, $timeout, $interval)
            
            $start = [DateTime]::UtcNow
            $deadline = $start.AddSeconds($timeout)
            $lastSec = -1
            $ok = $false
            
            while (-not $token.IsCancellationRequested) {
                $now = [DateTime]::UtcNow
                if ($now -ge $deadline) { break }
                
                $elapsed = ($now - $start).TotalSeconds
                $sec = [int][Math]::Floor($elapsed)
                if ($sec -ne $lastSec) {
                    $lastSec = $sec
                    $syncRef.Form.BeginInvoke([Action]{
                        Update-GridCell $rowIdx $colIdx "Scanning... ($($sec)s)" 
                    })
                }
                
                try {
                    $req = [System.Net.HttpWebRequest]::Create($url)
                    $req.Method = $method
                    $req.AllowAutoRedirect = $false
                    $req.Timeout = 5000
                    
                    if ($method -eq 'GET') {
                        $req.AllowReadStreamBuffering = $false
                    }
                    
                    $resp = $req.GetResponse()
                    $statusCode = [int]$resp.StatusCode
                    $resp.Close()
                    
                    if ($statusCode -eq 200) {
                        $ok = $true
                        break
                    }
                } catch [System.Net.WebException] {
                    $we = $_.Exception
                    if ($we.Response) {
                        try {
                            $r = [System.Net.HttpWebResponse]$we.Response
                            if ([int]$r.StatusCode -eq 200) {
                                $ok = $true
                                $r.Close()
                                break
                            }
                            $r.Close()
                        } catch {}
                    }
                } catch {}
                
                Start-Sleep -Milliseconds $interval
            }
            
            if ($token.IsCancellationRequested) { return }
            
            $finalSec = [int][Math]::Floor(([DateTime]::UtcNow - $start).TotalSeconds)
            if ($ok) {
                $finalSec = [int][Math]::Floor(([DateTime]::UtcNow - $start).TotalSeconds)
                $syncRef.Form.BeginInvoke([Action]{
                    Update-GridCell $rowIdx $colIdx "OK ($finalSec`s)"
                })
                Write-AppLog -Level INFO -Message "OK: $fileName @ $baseUrl (${finalSec}s)"
            } else {
                $syncRef.Form.BeginInvoke([Action]{
                    Update-GridCell $rowIdx $colIdx "TIMEOUT ($finalSec`s)"
                })
                Write-AppLog -Level WARN -Message "TIMEOUT: $fileName @ $baseUrl (${finalSec}s)"
            }
        }
        
        $NULL = $ps.AddScript($pollScript).
            AddArgument($sync).
            AddArgument($rowIdx).
            AddArgument($colIdx).
            AddArgument($FileName).
            AddArgument($url).
            AddArgument($baseUrl).
            AddArgument($token).
            AddArgument($method).
            AddArgument($timeout).
            AddArgument($interval)
        
        [void]$ps.BeginInvoke()
    }
}

# ============================================================================
# SECTION 12: STOP MONITORING
# ============================================================================

function Stop-Monitoring {
    if (-not $sync.Monitoring) { return }
    
    Write-AppLog -Level INFO -Message 'Stop requested.'
    $sync.Monitoring = $false
    
    # Cleanup watchers
    foreach ($wi in $sync.WatcherInfos) {
        try { Unregister-Event -SourceIdentifier $wi.CreatedSid -ErrorAction SilentlyContinue } catch {}
        try { Unregister-Event -SourceIdentifier $wi.ErrorSid -ErrorAction SilentlyContinue } catch {}
        try { $wi.Watcher.EnableRaisingEvents = $false } catch {}
        try { $wi.Watcher.Dispose() } catch {}
    }
    $sync.WatcherInfos = @()
    
    # Dispose runspace pool
    if ($sync.Pool) {
        try { $sync.Pool.Close() } catch {}
        try { $sync.Pool.Dispose() } catch {}
        $sync.Pool = $null
    }
    
    # Restore cert callback
    if ($NULL -ne $sync.CertCallbackPrev) {
        [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $sync.CertCallbackPrev
    }
    
    $btnStart.Enabled = $true
    $btnStop.Enabled = $false
    Set-StatusLabel $false
}

# ============================================================================
# SECTION 13: BUTTON EVENTS
# ============================================================================

$btnStart.Add_Click({
    try { Start-Monitoring } catch {
        Write-AppLog -Level ERROR -Message $_.Exception.Message
        Add-ErrorLine "ERROR: $($_.Exception.Message)"
    }
})

$btnStop.Add_Click({
    try { Stop-Monitoring } catch {
        Write-AppLog -Level ERROR -Message $_.Exception.Message
    }
})

$btnClear.Add_Click({
    try {
        Stop-Monitoring
        $sync.Grid.Rows.Clear()
        $sync.ErrorLines.Clear()
        $sync.ErrorBox.Clear()
        Write-AppLog -Level INFO -Message 'Clear requested.'
    } catch {
        Write-AppLog -Level ERROR -Message $_.Exception.Message
    }
})

$form.Add_FormClosing({
    try { Stop-Monitoring } catch {}
})

# ============================================================================
# SECTION 14: RUN UI
# ============================================================================

Write-AppLog -Level INFO -Message "Application started"
[void][System.Windows.Forms.Application]::Run($form)
