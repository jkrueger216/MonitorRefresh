# Define the path to the config file in the same directory as the script
$configPath = Join-Path -Path $PSScriptRoot -ChildPath "config.json"
$regexPattern = 
'^(PendingAuctions\.(pdf|xml)|A_\d{8}_\d\.(xml|pdf)|SPL_\d{8}_\d\.pdf|BPD_SPL_\d{8}_\d\.pdf|R_\d{8}_\d\.(xml|pdf)|NCR_\d{8}_\d\.pdf|CPI_\d{8}\.(xml|pdf)|BBA_\d{14}\.(pdf|xml)|BBPA_\d{14}\.(pdf|xml)|BBR_\d{14}\.(pdf|xml)|BBSPL_\d{14}\.(pdf|xml))$'

# --- Logic to SAVE configuration ---
$saveConfig = {
 $configData = @{
 # Capture the Root Path text box
 RootPath = $txtRoot.Text
 
 # Capture all items in the Monitor ListBox
 MonitorPaths = @($lstMonitor.Items)
 
 # Capture all items in the Web Server ListBox
 WebServers = @($lstWeb.Items)
 }
 # Convert to JSON and save to file
 $configData | ConvertTo-Json | Set-Content -Path $configPath -Force
}

# --- Logic to LOAD configuration ---
$loadConfig = {
 if (Test-Path $configPath) {
  try {
   $json = Get-Content -Path $configPath -Raw | ConvertFrom-Json
   
   # Restore Root Path
   if ($json.RootPath) { $txtRoot.Text = $json.RootPath }
   # Restore Monitor Paths
   if ($json.MonitorPaths) {
    $lstMonitor.Items.Clear()
    foreach ($path in $json.MonitorPaths) {
     $lstMonitor.Items.Add($path) | Out-Null
    }
   }
   # Restore Web Servers
   if ($json.WebServers) {
    $lstWeb.Items.Clear()
    foreach ($srv in $json.WebServers) {
     $lstWeb.Items.Add($srv) | Out-Null
    }
   }
  }
  catch {
   [System.Windows.Forms.MessageBox]::Show("Error loading config.json: $_")
  }
 }
}

# --- Event Handlers (Add/Remove Web Servers, Add/Remove Monitor Paths) ---

$btnAddWeb_Click = {
 $webserver = $txtWeb.Text.Trim()
 if ($webserver -ne "") {
  $lstWeb.Items.Add($webserver) | Out-Null
  $txtWeb.Clear()
  # SAVE CHANGES
  & $saveConfig
 }
}

$btnRmvWeb_Click = {
 if ($lstWeb.SelectedIndex -ge 0) {
  $lstWeb.Items.RemoveAt($lstWeb.SelectedIndex)
  # SAVE CHANGES
  & $saveConfig
 }
}

$btnAddMon_Click = {
 $path = $txtMonitor.Text.Trim()
 if ($path -ne "" -and (Test-Path $path)) {
     if (-not $lstMonitor.Items.Contains($path)) {
         $lstMonitor.Items.Add($path) | Out-Null
         $txtMonitor.Clear()
         & $saveConfig
     }
 } else {
     [System.Windows.Forms.MessageBox]::Show("Please enter a valid directory path.")
 }
}

$btnRmvMon_Click = {
 if ($lstMonitor.SelectedIndex -ge 0) {
  $lstMonitor.Items.RemoveAt($lstMonitor.SelectedIndex)
  # SAVE CHANGES
  & $saveConfig
 }
}

# --- Async Polling Script Block (runs in RunspacePool) ---
$PollingScript = {
 param($GridControl, $RowIndex, $ServerName, $ColIndex, $Url, $Form1, $StopSignal)
 
 # Wait before polling - file just created, may not be replicated yet
 Start-Sleep -Milliseconds 2000  # 2-second delay for file to be ready
 
 $success = $false
 $cancelled = $false
 $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()

 # Fallback: if stop signal was not passed for any reason, keep polling by timeout
 if (-not $StopSignal) {
  $StopSignal = New-Object System.Threading.ManualResetEventSlim($false)
 }
 
 while (-not $StopSignal.IsSet -and $stopwatch.Elapsed.TotalSeconds -lt 180) {
  $elapsedSec = [math]::Floor($stopwatch.Elapsed.TotalSeconds)
  
  # Update UI: Scanning status with elapsed time
  $Form1.Invoke([action]{
   if ($RowIndex -lt $GridControl.Rows.Count) {
    $GridControl.Rows[$RowIndex].Cells[$ColIndex].Value = "Scanning... ($elapsedSec s)"
   }
  })
  
  $req = $null
  $resp = $null
  try {
   $req = [System.Net.WebRequest]::Create($Url)
   $req.Method = "HEAD"
   $req.Timeout = 5000  # 5 second request timeout
   $req.AllowAutoRedirect = $false
   $req.UseDefaultCredentials = $true
   
   $resp = $req.GetResponse()
   $statusCode = [int]$resp.StatusCode
   
   if ($statusCode -eq 200) {
    $success = $true
    break
   }
  } catch {
   # Silently continue on error; will retry or timeout
  } finally {
   if ($resp) {
    try { $resp.Close() } catch {}
    try { $resp.Dispose() } catch {}
   }
   if ($req) {
    try { $req.Abort() } catch {}
   }
  }
  
  # Small 500ms sleep before retry
  Start-Sleep -Milliseconds 500
 }
 
 # Final status update
 $finalSec = [math]::Floor($stopwatch.Elapsed.TotalSeconds)
 if (-not $success -and $StopSignal.IsSet) { $cancelled = $true }
 $Form1.Invoke([action]{
  if ($RowIndex -lt $GridControl.Rows.Count) {
   if ($success) {
    $GridControl.Rows[$RowIndex].Cells[$ColIndex].Value = "FOUND (200)"
    $GridControl.Rows[$RowIndex].Cells[$ColIndex].Style.BackColor = [System.Drawing.Color]::LightGreen
   } elseif ($cancelled) {
    $GridControl.Rows[$RowIndex].Cells[$ColIndex].Value = "CANCELLED ($finalSec s)"
    $GridControl.Rows[$RowIndex].Cells[$ColIndex].Style.BackColor = [System.Drawing.Color]::LightYellow
   } else {
    $GridControl.Rows[$RowIndex].Cells[$ColIndex].Value = "TIMEOUT ($finalSec s)"
    $GridControl.Rows[$RowIndex].Cells[$ColIndex].Style.BackColor = [System.Drawing.Color]::LightCoral
   }
  }
 })
}

# Shared dispatcher: queues per-server polling jobs for a single file row
$DispatchPollingJobsForFile = {
 param($GridControl, $RowIndex, $SubPath, $FileName, $WebServers, $Form1, $RunspacePool, $StopSignal, $RunspaceCollection)

 foreach ($webServer in $WebServers) {
  try {
   $colIndex = $GridControl.Columns[$webServer].Index
   $fullUrl = "https://$webServer/$SubPath/$FileName".Replace('\', '/')

   $ps = [powershell]::Create()
   $ps.RunspacePool = $RunspacePool
   $null = $ps.AddScript($PollingScript)
   $null = $ps.AddArgument($GridControl)
   $null = $ps.AddArgument($RowIndex)
   $null = $ps.AddArgument($webServer)
   $null = $ps.AddArgument($colIndex)
   $null = $ps.AddArgument($fullUrl)
   $null = $ps.AddArgument($Form1)
   $null = $ps.AddArgument($StopSignal)

   $handle = $ps.BeginInvoke()
   [void]$RunspaceCollection.Add(@{ PowerShell = $ps; Handle = $handle })
  } catch {
   # Silently ignore per-server dispatch errors
  }
 }
}

# --- History Scan Form Logic (UPDATED with Dynamic Columns, Colors, and SSL fix) ---

$btnHistory_Click = {
    # --- 1. SETUP UI & LOGIC ---
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    # CRITICAL FIX: Ensure history scan uses modern security protocols
    [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }

    # Form Setup
    $histForm = New-Object System.Windows.Forms.Form
    $histForm.Text = "History / File Scanner"
    $histForm.Size = New-Object System.Drawing.Size(800, 550)
    $histForm.StartPosition = "CenterParent"

    # Controls (Labels, Picker, Button, Grid)
    $lblDate = New-Object System.Windows.Forms.Label
    $lblDate.Location = "10, 10"
    $dtPicker = New-Object System.Windows.Forms.DateTimePicker
    $dtPicker.Location = "130, 7"
    $dtPicker.Value = (Get-Date).Date
    $btnScan = New-Object System.Windows.Forms.Button
    $btnScan.Location = "650, 35"
    $btnScan.Text = "Scan Files"
    $grid = New-Object System.Windows.Forms.DataGridView
    $grid.Location = "10, 70"; $grid.Size = "760, 420"; $grid.Anchor = "Top, Bottom, Left, Right"

    # --- Dynamic Column Creation ---
    $grid.Columns.Clear()
    $grid.Columns.Add("File", "File") | Out-Null
    $grid.Columns[0].Width = 200 # Fixed width for file name
    $grid.Columns.Add("Path", "Monitor Path") | Out-Null 
    $grid.Columns[1].Width = 150 # Fixed width for path

    # Get web servers list from main form config
    $webServers = @($lstWeb.Items) 
    foreach ($webServerName in $webServers) {
        $grid.Columns.Add($webServerName, $webServerName) | Out-Null
        # Make new columns fill remaining space
        $grid.Columns[$grid.Columns.Count - 1].AutoSizeMode = "Fill" 
    }

    # --- 2. SCANNING LOGIC ---
    $btnScan.Add_Click({
        $btnScan.Enabled = $false
        $btnScan.Text = "Scanning..."
        $grid.Rows.Clear()
        
        $targetDate = $dtPicker.Value.Date
        $nextDay = $targetDate.AddDays(1)
        
        $monitorPaths = $lstMonitor.Items
        $rootPath = $txtRoot.Text

        $historyStopSignal = New-Object System.Threading.ManualResetEventSlim($false)
        $historyRunspacePool = [runspacefactory]::CreateRunspacePool(1, [math]::Min(8, [System.Environment]::ProcessorCount))
        $historyRunspacePool.Open()
        $historyRunspaces = New-Object System.Collections.ArrayList

        try {
            foreach ($subPath in $monitorPaths) {
                $fullPath = Join-Path -Path $rootPath -ChildPath $subPath
                if (Test-Path $fullPath) {
                    $dirInfo = New-Object System.IO.DirectoryInfo($fullPath)
                    foreach ($file in $dirInfo.EnumerateFiles()) {
                        [System.Windows.Forms.Application]::DoEvents()
                        if ($file.LastWriteTime -ge $targetDate -and $file.LastWriteTime -lt $nextDay) {
                            if ($file.Name -match $regexPattern) {
                                # Add row with file info, then dispatch shared polling jobs
                                $rowIndex = $grid.Rows.Add(@($file.Name, $subPath))
                                & $DispatchPollingJobsForFile $grid $rowIndex $subPath $file.Name $webServers $histForm $historyRunspacePool $historyStopSignal $historyRunspaces
                            }
                        }
                    }
                }
            }

            # Keep the dialog responsive while background jobs complete
            while ($true) {
                $pending = $false
                foreach ($job in $historyRunspaces) {
                    if ($job.Handle -and -not $job.Handle.IsCompleted) {
                        $pending = $true
                        break
                    }
                }

                [System.Windows.Forms.Application]::DoEvents()
                if (-not $pending) { break }
                Start-Sleep -Milliseconds 100
            }
        } finally {
            $historyStopSignal.Set()

            foreach ($job in $historyRunspaces) {
                try {
                    if ($job.Handle) {
                        $job.PowerShell.EndInvoke($job.Handle) | Out-Null
                    }
                } catch {
                    # Ignore cleanup faults
                } finally {
                    try { $job.PowerShell.Dispose() } catch {}
                }
            }

            try { $historyRunspacePool.Close() } catch {}
            try { $historyRunspacePool.Dispose() } catch {}
            try { $historyStopSignal.Dispose() } catch {}
        }

        $btnScan.Enabled = $true
        $btnScan.Text = "Scan Files"
        [System.Windows.Forms.MessageBox]::Show("Scan Complete")
    })
    $histForm.Controls.AddRange(@($lblDate, $dtPicker, $btnScan, $grid))
    $histForm.ShowDialog()
}

# --- Main Start/Stop Monitoring Logic (UPDATED with Async Polling and Resource Cleanup) ---

# Global state for monitoring and runspace management
$script:MonitoringActive = @{ IsRunning = $false }
$script:StopSignal = $null
$script:RunspacePool = $null
$script:ActiveRunspaces = New-Object System.Collections.ArrayList

$btnStart_Click = {
 # SAVE CHANGES (captures the current Root path)
 & $saveConfig
 
 # --- CRITICAL FIX: Ensure main monitor uses modern security protocols ---
 [System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }
 [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
 # ------------------------------------------------------
 
 # --- 1. UI State Management ---
 $tabConf.enabled = $false
 $btnStart.enabled = $false; $btnStart.BackColor = [System.Drawing.Color]::LightGray
 $btnStop.enabled = $true; $btnStop.BackColor = [System.Drawing.Color]::LightCoral
 $lblStatus.Text = "Status: MONITORING"; $lblStatus.ForeColor = [System.Drawing.Color]::Green
 
 # --- 1.5. Initialize RunspacePool for async polling ---
 $script:MonitoringActive.IsRunning = $true
 if ($script:StopSignal) {
  try { $script:StopSignal.Dispose() } catch {}
 }
 $script:StopSignal = New-Object System.Threading.ManualResetEventSlim($false)
 $poolSize = [math]::Min(8, [System.Environment]::ProcessorCount)
 $script:RunspacePool = [runspacefactory]::CreateRunspacePool(1, $poolSize)
 $script:RunspacePool.Open()
 $script:ActiveRunspaces = New-Object System.Collections.ArrayList
 
 # --- 2. Dynamic Grid Setup (Reset Columns) ---
 $DataGridView1.Columns.Clear()
 # Add File and Path columns first for consistent layout
 $DataGridView1.Columns.Add("File", "File") | Out-Null
 $DataGridView1.Columns.Add("Path", "Monitor Path") | Out-Null

 # Create a column for every Web Server in lstWeb
 foreach ($webItem in $lstWeb.Items) {
  $DataGridView1.Columns.Add($webItem, $webItem) | Out-Null
 }
 
 # --- 3. Monitoring Logic ---
 $script:activeWatchers = @() 
 $root = $txtRoot.Text 
 foreach ($subPath in $lstMonitor.Items) { #
  
  $watchPath = Join-Path -Path $root -ChildPath $subPath
  if (Test-Path $watchPath) {
   $newWatcher = New-Object System.IO.FileSystemWatcher
   $newWatcher.Path = $watchPath
   $newWatcher.Filter = "*.*"
   $newWatcher.IncludeSubdirectories = $false
   $newWatcher.SynchronizingObject = $Form1 #
   
   # --- 4. The Action Logic (NOW ASYNC - Dispatches to RunspacePool) ---
   $action = {
    param($source, $e)
    # --- Check if item is a Directory ---
    $fullPhysicalPath = Join-Path -Path $watchPath -ChildPath $e.Name
    if ([System.IO.Directory]::Exists($fullPhysicalPath)) { return }
    # Check if file matches regex
    $fileName = $e.Name
    if (-not ($fileName -match $regexPattern)) { return }
    
    # Add grid row for this file
    $rowIndex = $DataGridView1.Rows.Add(@($fileName, $subPath))
    
    # Dispatch shared polling jobs for all web servers (non-blocking)
    & $DispatchPollingJobsForFile $DataGridView1 $rowIndex $subPath $fileName $lstWeb.Items $Form1 $script:RunspacePool $script:StopSignal $script:ActiveRunspaces
   }.GetNewClosure() 
   $newWatcher.add_Created($action)
   $newWatcher.EnableRaisingEvents = $true
   $script:activeWatchers += $newWatcher
  }
 }
}

$btnStop_Click = {
 # --- Existing UI State Management ---
 $tabConf.enabled = $true
 $btnStart.enabled = $true; $btnStart.BackColor = [System.Drawing.Color]::LightGreen
 $btnStop.enabled = $false; $btnStop.BackColor = [System.Drawing.Color]::LightGray
 $lblStatus.Text = "Status: STOPPED!"; $lblStatus.ForeColor = [System.Drawing.Color]::Red
 
 # --- Stop Monitoring & Clean Up Async Resources ---
 $script:MonitoringActive.IsRunning = $false
 if ($script:StopSignal) {
  try { $script:StopSignal.Set() } catch {}
 }
 
 # Disable all watchers and dispose them
 foreach ($watcher in $script:activeWatchers) {
  $watcher.EnableRaisingEvents = $false
  $watcher.Dispose()
 }
 $script:activeWatchers = @()
 
 # Wait for active runspaces to complete and clean up
 if ($script:ActiveRunspaces.Count -gt 0) {
 foreach ($job in $script:ActiveRunspaces) {
   try {
    if ($job.Handle -and -not $job.Handle.IsCompleted) {
     $job.Handle.AsyncWaitHandle.WaitOne(1000) | Out-Null  # Wait max 1 sec
    }
    $job.PowerShell.EndInvoke($job.Handle) | Out-Null
    $job.PowerShell.Dispose()
   } catch {
    # Silently ignore cleanup errors
   }
  }
  $script:ActiveRunspaces = New-Object System.Collections.ArrayList
 }
 
 # Close and dispose the runspace pool
 if ($script:RunspacePool) {
  $script:RunspacePool.Close()
  $script:RunspacePool.Dispose()
  $script:RunspacePool = $null
 }

 if ($script:StopSignal) {
  try { $script:StopSignal.Dispose() } catch {}
  $script:StopSignal = $null
 }
}

# --- Main Form Initialization ---
Add-Type -AssemblyName System.Windows.Forms
# Loads UI elements ($Form1, $txtRoot, $lstWeb, etc.) from a separate file
. (Join-Path $PSScriptRoot 'monitor.designer.ps1') 
& $loadConfig
$Form1.ShowDialog()
