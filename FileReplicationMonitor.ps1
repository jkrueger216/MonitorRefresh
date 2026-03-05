<#
.SYNOPSIS
    File Replication Monitor - GUI Application
.DESCRIPTION
    Monitors specific UNC paths for file creation and concurrently polls web servers to verify replication.
#>

# --- 1. STA & Console Hiding Relaunch ---
if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    if ($env:FILE_REP_MON_STA -eq "1") {
        [System.Windows.Forms.MessageBox]::Show("Failed to start in STA mode.", "Fatal Error")
        exit
    }
    $env:FILE_REP_MON_STA = "1"
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = "powershell.exe"
    $psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`""
    $psi.WindowStyle = 'Hidden'
    [System.Diagnostics.Process]::Start($psi) | Out-Null
    exit
}

# --- 2. Assemblies & Globals ---
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Use $PSScriptRoot for reliable path resolution, fallback to $PWD if running unsaved
$global:ScriptDir = $PSScriptRoot
if ([string]::IsNullOrEmpty($global:ScriptDir)) { $global:ScriptDir = $PWD.Path }

$global:LogDir = Join-Path $global:ScriptDir "logs"
$global:ConfigFile = Join-Path $global:ScriptDir "config.json"

if (-not (Test-Path $global:LogDir)) { New-Item -ItemType Directory -Path $global:LogDir | Out-Null }

# Shared state for cancellation and active jobs tracking
$global:SharedState = [hashtable]::Synchronized(@{
    IsRunning = $false
})
$global:ActiveRunspaces = [System.Collections.Generic.List[psobject]]::new()
$global:Watchers = [System.Collections.Generic.List[System.IO.FileSystemWatcher]]::new()
$global:RunspacePool = $null

# --- 3. Logging & Cleanup ---
function Write-AppLog {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logLine = "[$timestamp] [$Level] $Message"
    # Explicitly use $global:LogDir so scope is never lost
    $logPath = Join-Path $global:LogDir "app-$(Get-Date -Format 'yyyyMMdd').log"
    Add-Content -Path $logPath -Value $logLine
}

function Cleanup-Logs {
    $cutoff = (Get-Date).AddDays(-5).Date
    Get-ChildItem -Path $global:LogDir -Filter "app-*.log" | ForEach-Object {
        if ($_.Name -match "app-(\d{4})(\d{2})(\d{2})\.log") {
            try {
                $logDate = [datetime]::new([int]$matches[1], [int]$matches[2], [int]$matches[3])
                if ($logDate -lt $cutoff) { Remove-Item $_.FullName -Force }
            } catch {
                # Skip invalid date formats
            }
        }
    }
}
Cleanup-Logs

# --- 4. Configuration Management ---
function Get-Config {
    if (-not (Test-Path $ConfigFile)) {
        $defaultConfig = @{
            RootUNC = "\\ServerShare\folder\htdocs\"
            Subfolders = @(
                "instit\annceresult\press\preanre\2026",
                "instit\annceresult\press\preanre",
                "xml"
            )
            FilenameRegex = "^(PendingAuctions\.(pdf|xml)|A_\d{8}_\d\.(xml|pdf)|SPL_\d{8}_\d\.pdf|BPD_SPL_\d{8}_\d\.pdf|R_\d{8}_\d\.(xml|pdf)|NCR_\d{8}_\d\.pdf|CPI_\d{8}\.(xml|pdf)|BBA_\d{14}\.(pdf|xml)|BBPA_\d{14}\.(pdf|xml)|BBR_\d{14}\.(pdf|xml)|BBSPL_\d{14}\.(pdf|xml))$"
            WebServers = @("https://ihs-wb-p02.pktic.fiscalad.treasury.gov")
            PollIntervalMs = 900
            TimeoutSeconds = 180
            UseHeadVsGet = "HEAD"
            CertVerificationEnabled = $false
        }
        $defaultConfig | ConvertTo-Json -Depth 5 | Set-Content $ConfigFile
        Write-AppLog "Generated default config.json"
    }
    return (Get-Content $ConfigFile -Raw | ConvertFrom-Json)
}
$Config = Get-Config

# TLS Settings
if (-not $Config.CertVerificationEnabled) {
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}
}

# --- 5. UI Setup ---
$Form = New-Object System.Windows.Forms.Form
$Form.Text = "File Replication Monitor"
$Form.Size = New-Object System.Drawing.Size(1000, 600)
$Form.StartPosition = "CenterScreen"

$TopPanel = New-Object System.Windows.Forms.Panel
$TopPanel.Dock = "Top"
$TopPanel.Height = 50

$BtnStart = New-Object System.Windows.Forms.Button
$BtnStart.Text = "Start"
$BtnStart.Location = New-Object System.Drawing.Point(10, 10)
$TopPanel.Controls.Add($BtnStart)

$BtnStop = New-Object System.Windows.Forms.Button
$BtnStop.Text = "Stop"
$BtnStop.Location = New-Object System.Drawing.Point(90, 10)
$BtnStop.Enabled = $false
$TopPanel.Controls.Add($BtnStop)

$BtnClear = New-Object System.Windows.Forms.Button
$BtnClear.Text = "Clear"
$BtnClear.Location = New-Object System.Drawing.Point(170, 10)
$TopPanel.Controls.Add($BtnClear)

$LblStatus = New-Object System.Windows.Forms.Label
$LblStatus.Text = "STOPPED!"
$LblStatus.ForeColor = [System.Drawing.Color]::Red
$LblStatus.Font = New-Object System.Drawing.Font("Arial", 12, [System.Drawing.FontStyle]::Bold)
$LblStatus.Location = New-Object System.Drawing.Point(260, 12)
$LblStatus.AutoSize = $true
$TopPanel.Controls.Add($LblStatus)

$Grid = New-Object System.Windows.Forms.DataGridView
$Grid.Dock = "Fill"
$Grid.AllowUserToAddRows = $false
$Grid.ReadOnly = $true
$Grid.RowHeadersVisible = $false
$Grid.AutoSizeColumnsMode = "Fill"

$Grid.Columns.Add("Filename", "Filename") | Out-Null
foreach ($srv in $Config.WebServers) {
    $Grid.Columns.Add($srv, $srv) | Out-Null
}

# Store explicit reference to avoid fragile control indexing
$global:GridControl = $Grid

$BottomPanel = New-Object System.Windows.Forms.Panel
$BottomPanel.Dock = "Bottom"
$BottomPanel.Height = 150

$LogBox = New-Object System.Windows.Forms.RichTextBox
$LogBox.Dock = "Fill"
$LogBox.ReadOnly = $true
$LogBox.BackColor = [System.Drawing.Color]::Black
$LogBox.ForeColor = [System.Drawing.Color]::Yellow
$LogBox.Font = New-Object System.Drawing.Font("Consolas", 9)
$BottomPanel.Controls.Add($LogBox)

$Form.Controls.Add($Grid)
$Form.Controls.Add($TopPanel)
$Form.Controls.Add($BottomPanel)

# --- 6. Helper Functions ---
function Update-UI {
    param($Action)
    if ($Form.InvokeRequired) {
        $Form.Invoke([action]{ &$Action })
    } else {
        &$Action
    }
}

function Log-ErrorUI {
    param([string]$Message)
    Write-AppLog $Message "WARN/ERROR"
    Update-UI {
        $timestamp = Get-Date -Format "HH:mm:ss"
        $LogBox.AppendText("[$timestamp] $Message`n")
        if ($LogBox.Lines.Count -gt 500) {
            $LogBox.Lines = $LogBox.Lines[($LogBox.Lines.Count - 500)..($LogBox.Lines.Count - 1)]
        }
        $LogBox.ScrollToCaret()
    }
}

function Update-CellStatus {
    param($RowIndex, $ColName, $Status)
    Update-UI {
        if ($RowIndex -lt $Grid.Rows.Count) {
            $Grid.Rows[$RowIndex].Cells[$ColName].Value = $Status
        }
    }
}

# --- 7. Polling Logic (Runspace) ---
$PollingScript = {
    param($GridControl, $RowIndex, $ServerName, $Url, $Config, $SharedState, $StartTicks)
    
    $timeoutSeconds = $Config.TimeoutSeconds
    $intervalMs = $Config.PollIntervalMs
    $method = $Config.UseHeadVsGet
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    
    $success = $false
    $lastError = $null
    $timedOut = $false

    while ($SharedState.IsRunning -and $stopwatch.Elapsed.TotalSeconds -le $timeoutSeconds) {
        $elapsedSec = [math]::Floor($stopwatch.Elapsed.TotalSeconds)
        
        # Update UI: Scanning
        $scanMsg = "Scanning... ({0}s)" -f $elapsedSec
        $GridControl.Invoke([action]{
            if ($RowIndex -lt $GridControl.Rows.Count) {
                $GridControl.Rows[$RowIndex].Cells[$ServerName].Value = $scanMsg
            }
        })

        $req = $null
        $resp = $null
        try {
            $req = [System.Net.WebRequest]::Create($Url)
            $req.Method = $method
            $req.AllowAutoRedirect = $false
            $req.Timeout = 5000 # 5s per-request timeout to prevent hanging

            $resp = $req.GetResponse()
            $statusCode = [int]$resp.StatusCode

            if ($statusCode -eq 200) {
                $success = $true
                break
            }
        } catch {
            $lastError = $_.Exception.Message
        } finally {
            # Ensure cleanup of response object
            if ($resp) {
                try { $resp.Close() } catch {}
                try { $resp.Dispose() } catch {}
            }
            if ($req) {
                try { $req.Abort() } catch {}
            }
        }

        Start-Sleep -Milliseconds $intervalMs
    }

    if (-not $SharedState.IsRunning) { return } # Aborted

    # Check if timeout occurred
    if ($stopwatch.Elapsed.TotalSeconds -gt $timeoutSeconds -and -not $success) {
        $timedOut = $true
    }

    $finalSec = [math]::Floor($stopwatch.Elapsed.TotalSeconds)
    if ($success) {
        $finalMsg = "OK ({0}s)" -f $finalSec
        $GridControl.Invoke([action]{ $GridControl.Rows[$RowIndex].Cells[$ServerName].Value = $finalMsg })
    } else {
        if ($timedOut) {
            $finalMsg = "TIMEOUT ({0}s)" -f $finalSec
        } else {
            $finalMsg = "ERROR ({0}s)" -f $finalSec
        }
        $GridControl.Invoke([action]{ $GridControl.Rows[$RowIndex].Cells[$ServerName].Value = $finalMsg })
    }
}

# --- 8. Core Application Logic ---
function Start-Monitoring {
    $rootUnc = $Config.RootUNC
    if (-not $rootUnc.EndsWith("\")) { $rootUnc += "\" }

    # Validation
    if (-not (Test-Path $rootUnc -PathType Container)) {
        [System.Windows.Forms.MessageBox]::Show("Root UNC is not reachable: $rootUnc", "Validation Error")
        return
    }

    foreach ($sub in $Config.Subfolders) {
        $fullPath = Join-Path $rootUnc $sub
        if (-not (Test-Path $fullPath -PathType Container)) {
            [System.Windows.Forms.MessageBox]::Show("Monitored subfolder missing: $fullPath", "Validation Error")
            return
        }
    }

    Write-AppLog "Starting monitoring..."
    $SharedState.IsRunning = $true

    # Use fixed thread pool size (smaller than processor count to avoid excessive idle threads)
    $poolSize = [math]::Min(4, [Environment]::ProcessorCount)
    $global:RunspacePool = [runspacefactory]::CreateRunspacePool(1, $poolSize)
    $global:RunspacePool.ThreadOptions = "ReuseThread"
    $global:RunspacePool.Open()

    foreach ($sub in $Config.Subfolders) {
        Create-Watcher (Join-Path $rootUnc $sub)
    }

    $LblStatus.Text = "MONITORING"
    $LblStatus.ForeColor = [System.Drawing.Color]::Green
    $BtnStart.Enabled = $false
    $BtnStop.Enabled = $true
}

function Create-Watcher([string]$Path) {
    try {
        $watcher = New-Object System.IO.FileSystemWatcher
        $watcher.Path = $Path
        $watcher.IncludeSubdirectories = $false
        $watcher.EnableRaisingEvents = $true

        $actionCreated = {
            $fileEvent = $Event.SourceEventArgs
            $filePath = $fileEvent.FullPath
            $fileName = $fileEvent.Name

            if ([regex]::IsMatch($fileName, $Config.FilenameRegex, 'IgnoreCase')) {
                Write-AppLog "File detected: $filePath"

                Update-UI {
                    $idx = $Grid.Rows.Add()
                    $Grid.Rows[$idx].Cells["Filename"].Value = $fileName

                    # Map URL
                    $rootUnc = $Config.RootUNC
                    if (-not $rootUnc.EndsWith("\")) { $rootUnc += "\" }
                    $relativePath = $filePath.Substring($rootUnc.Length).Replace("\", "/")

                    foreach ($srv in $Config.WebServers) {
                        $baseUrl = $srv
                        if ($baseUrl.EndsWith("/")) { $baseUrl = $baseUrl.Substring(0, $baseUrl.Length - 1) }
                        # Use System.Uri to properly construct URL without double slashes
                        $targetUrl = ([System.Uri]"$baseUrl/").AbsoluteUri.TrimEnd('/') + "/" + $relativePath

                        # Dispatch Job
                        $ps = [powershell]::Create()
                        $null = $ps.AddScript($PollingScript)
                        $null = $ps.AddArgument($global:GridControl)
                        $null = $ps.AddArgument($idx)
                        $null = $ps.AddArgument($srv)
                        $null = $ps.AddArgument($targetUrl)
                        $null = $ps.AddArgument($Config)
                        $null = $ps.AddArgument($SharedState)
                        $null = $ps.AddArgument([datetime]::Now.Ticks)

                        $ps.RunspacePool = $global:RunspacePool
                        $psHandle = @{
                            PowerShell = $ps
                            Handle = $ps.BeginInvoke()
                        }
                        $ActiveRunspaces.Add($psHandle)
                    }
                }
            }
        }

        $actionError = {
            $errArgs = $Event.SourceEventArgs
            $badPath = $Event.MessageData
            Log-ErrorUI "Watcher failed for $badPath : $($errArgs.GetException().Message)"
            Write-AppLog "Watcher error on $badPath" "ERROR"
            
            # Attempt restart with small delay to avoid rapid retry loops
            try {
                Start-Sleep -Milliseconds 500
                Update-UI { 
                    $Watchers = $Watchers | Where-Object { $_.Path -ne $badPath } 
                    Create-Watcher $badPath
                }
                Log-ErrorUI "Successfully restarted watcher for $badPath"
            } catch {
                Update-UI {
                    [System.Windows.Forms.MessageBox]::Show(
                        "Monitoring broken for $badPath. Restart failed. Please check network and restart the application.",
                        "Watcher Critical Failure",
                        [System.Windows.Forms.MessageBoxButtons]::OK,
                        [System.Windows.Forms.MessageBoxIcon]::Error
                    )
                }
            }
        }

        Register-ObjectEvent -InputObject $watcher -EventName "Created" -Action $actionCreated | Out-Null
        Register-ObjectEvent -InputObject $watcher -EventName "Error" -Action $actionError -MessageData $Path | Out-Null
        
        $Watchers.Add($watcher)
        Write-AppLog "Started monitoring $Path"
    } catch {
        Log-ErrorUI "Failed to create watcher for $Path : $($_.Exception.Message)"
    }
}

function Stop-Monitoring {
    Write-AppLog "Stopping monitoring..."
    $SharedState.IsRunning = $false

    # Stop Watchers
    foreach ($w in $Watchers) {
        $w.EnableRaisingEvents = $false
        $w.Dispose()
    }
    $Watchers.Clear()
    Get-EventSubscriber | Where-Object { $_.SourceObject -is [System.IO.FileSystemWatcher] } | Unregister-Event

    # Properly cleanup active runspaces
    foreach ($psHandle in $ActiveRunspaces) {
        try {
            $ps = $psHandle.PowerShell
            $handle = $psHandle.Handle
            if ($ps -and $handle) {
                # Wait for completion with timeout
                if (-not $handle.IsCompleted) {
                    $ps.Stop()
                }
                # Properly drain the pipeline
                try { $ps.EndInvoke($handle) | Out-Null } catch {}
            }
            if ($ps) { $ps.Dispose() }
        } catch {
            # Best effort cleanup
        }
    }
    $ActiveRunspaces.Clear()

    if ($global:RunspacePool) {
        $global:RunspacePool.Close()
        $global:RunspacePool.Dispose()
        $global:RunspacePool = $null
    }

    $LblStatus.Text = "STOPPED!"
    $LblStatus.ForeColor = [System.Drawing.Color]::Red
    $BtnStart.Enabled = $true
    $BtnStop.Enabled = $false
}

function Clear-UI {
    Stop-Monitoring
    $Grid.Rows.Clear()
    $LogBox.Clear()
}

# --- 9. Event Hooks & Start ---
$BtnStart.Add_Click({ Start-Monitoring })
$BtnStop.Add_Click({ Stop-Monitoring })
$BtnClear.Add_Click({ Clear-UI })

$Form.Add_FormClosing({ Stop-Monitoring })

Write-AppLog "Application Initialized."
[System.Windows.Forms.Application]::Run($Form)
