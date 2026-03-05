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
 param($GridControl, $RowIndex, $ServerName, $ColIndex, $Url, $Form1, $MonitoringActive)
 
 $timeout = (Get-Date).AddMinutes(3)
 $success = $false
 $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
 
 while ($MonitoringActive.IsRunning -and $stopwatch.Elapsed.TotalSeconds -lt 180) {
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
 $Form1.Invoke([action]{
  if ($RowIndex -lt $GridControl.Rows.Count) {
   if ($success) {
    $GridControl.Rows[$RowIndex].Cells[$ColIndex].Value = "FOUND (200)"
    $GridControl.Rows[$RowIndex].Cells[$ColIndex].Style.BackColor = [System.Drawing.Color]::LightGreen
   } else {
    $GridControl.Rows[$RowIndex].Cells[$ColIndex].Value = "TIMEOUT ($finalSec s)"
    $GridControl.Rows[$RowIndex].Cells[$ColIndex].Style.BackColor = [System.Drawing.Color]::LightCoral
   }
  }
 })
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
        
        foreach ($subPath in $monitorPaths) {
            $fullPath = Join-Path -Path $rootPath -ChildPath $subPath
            if (Test-Path $fullPath) {
                $dirInfo = New-Object System.IO.DirectoryInfo($fullPath)
                foreach ($file in $dirInfo.EnumerateFiles()) {
                    [System.Windows.Forms.Application]::DoEvents()
                    if ($file.LastWriteTime -ge $targetDate -and $file.LastWriteTime -lt $nextDay) {
                        if ($file.Name -match $regexPattern) {
                            
                            # Add row with file info first
                            $rowIndex = $grid.Rows.Add(@($file.Name, $subPath))
                            
                            foreach ($srv in $webServers) {
                                $colIndex = $grid.Columns[$srv].Index
                                $fullUrl = "https://$srv/$subPath/$($file.Name)".Replace('\\\', '/')
                                
                                try {
                                    $req = [System.Net.WebRequest]::Create($fullUrl)
                                    $req.Method = "HEAD"
                                    $req.Timeout = 2000
                                    $req.UseDefaultCredentials = $true
                                    $resp = $req.GetResponse()
                                    
                                    # Update specific cell for this server with color
                                    $grid.Rows[$rowIndex].Cells[$colIndex].Value = "FOUND ($($resp.StatusCode))"
                                    $grid.Rows[$rowIndex].Cells[$colIndex].Style.BackColor = [System.Drawing.Color]::LightGreen
                                    $resp.Close()
                                } catch {
                                    $msg = $_.Exception.Message
                                    if ($msg -match "timed out") { $msg = "Timeout" }
                                    # Update specific cell for this server with color
                                    $grid.Rows[$rowIndex].Cells[$colIndex].Value = "MISSING ($msg)"
                                    $grid.Rows[$rowIndex].Cells[$colIndex].Style.BackColor = [System.Drawing.Color]::LightCoral
                                }
                            }
                        }
                    }
                }
            }
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
$script:RunspacePool = $null
$script:ActiveRunspaces = @()

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
 $poolSize = [math]::Min(8, [System.Environment]::ProcessorCount)
 $script:RunspacePool = [runspacefactory]::CreateRunspacePool(1, $poolSize)
 $script:RunspacePool.Open()
 $script:ActiveRunspaces = @()
 
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
    
    # Dispatch polling for each web server to RunspacePool (non-blocking)
    foreach ($webServer in $lstWeb.Items) {
     try {
      $colIndex = $DataGridView1.Columns[$webServer].Index
      $fullUrl = "https://$webServer/$subPath/$fileName".Replace('\\', '/')
      
      # Create PowerShell instance to run polling in background
      $ps = [powershell]::Create()
      $ps.RunspacePool = $script:RunspacePool
      $null = $ps.AddScript($PollingScript)
      $null = $ps.AddArgument($DataGridView1)  # GridControl
      $null = $ps.AddArgument($rowIndex)
      $null = $ps.AddArgument($webServer)
      $null = $ps.AddArgument($colIndex)
      $null = $ps.AddArgument($fullUrl)
      $null = $ps.AddArgument($Form1)
      $null = $ps.AddArgument($script:MonitoringActive)
      
      # Launch async (non-blocking) and store for cleanup
      $handle = $ps.BeginInvoke()
      $script:ActiveRunspaces += @{ PowerShell = $ps; Handle = $handle }
     } catch {
      # Silently ignore per-server dispatch errors
     }
    }
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
  $script:ActiveRunspaces = @()
 }
 
 # Close and dispose the runspace pool
 if ($script:RunspacePool) {
  $script:RunspacePool.Close()
  $script:RunspacePool.Dispose()
  $script:RunspacePool = $null
 }
}

# --- Main Form Initialization ---
Add-Type -AssemblyName System.Windows.Forms
# Loads UI elements ($Form1, $txtRoot, $lstWeb, etc.) from a separate file
. (Join-Path $PSScriptRoot 'monitor.designer.ps1') 
& $loadConfig
$Form1.ShowDialog()
