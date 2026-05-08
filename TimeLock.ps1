param([int]$LockMinutes = 25)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic

[System.Windows.Forms.Application]::EnableVisualStyles()

# =========================================================
# STATE
# =========================================================

$script:Apps = New-Object System.Collections.Generic.List[string]
$script:ExePaths = New-Object System.Collections.Generic.List[string]
$script:Folders = New-Object System.Collections.Generic.List[string]
$script:UnlockTime = $null
$script:MainForm = $null
$script:SessionForm = $null
$script:SessionTimer = $null
$script:SessionTray = $null

# =========================================================
# PROFILE SYSTEM
# =========================================================

$ProfilePath = "$PSScriptRoot\TimeLockProfiles.json"

function Load-Profiles {
    if (!(Test-Path $ProfilePath)) { return @{} }
    try {
        $json = Get-Content $ProfilePath -Raw | ConvertFrom-Json
        $t = @{}
        foreach ($p in $json.PSObject.Properties) { $t[$p.Name] = $p.Value }
        return $t
    } catch { return @{} }
}

function Save-Profiles($data) {
    $data | ConvertTo-Json -Depth 20 | Set-Content $ProfilePath
}

function Save-Profile($name) {
    $p = Load-Profiles

    $p[$name] = @{
        Apps     = @($script:Apps)
        ExePaths = @($script:ExePaths)
        Folders  = @($script:Folders)
        Minutes  = [int]$minutesBox.Value
    }

    Save-Profiles $p
}

function Load-Profile($name) {

    $p = Load-Profiles
    if (-not $p.ContainsKey($name)) { return }

    $d = $p[$name]

    $script:Apps.Clear()
    $script:ExePaths.Clear()
    $script:Folders.Clear()

    foreach ($i in $d.Apps)     { $script:Apps.Add([string]$i) }
    foreach ($i in $d.ExePaths) { $script:ExePaths.Add([string]$i) }
    foreach ($i in $d.Folders)  { $script:Folders.Add([string]$i) }

    $minutesBox.Value = [int]$d.Minutes

    Refresh-All
    Refresh-Profiles
}

# =========================================================
# BLOCK ENGINE
# =========================================================

function Block-Apps {
    foreach ($e in $script:ExePaths) {
        try {
            $n = [IO.Path]::GetFileNameWithoutExtension($e)
            Get-Process -Name $n -ErrorAction SilentlyContinue | Stop-Process -Force
        } catch {}
    }

    foreach ($a in $script:Apps) {
        try {
            Get-Process -Name $a -ErrorAction SilentlyContinue | Stop-Process -Force
        } catch {}
    }
}

# =========================================================
# FOLDER LOCK
# =========================================================

function Lock-Folders {
    foreach ($f in $script:Folders) {
        if (Test-Path $f) {
            try { attrib +h $f /S /D | Out-Null } catch {}
        }
    }
}

function Unlock-Folders {
    foreach ($f in $script:Folders) {
        if (Test-Path $f) {
            try { attrib -h $f /S /D | Out-Null } catch {}
        }
    }
}

# =========================================================
# UI REFRESH
# =========================================================

function Refresh-All {

    $appList.Items.Clear()

    Get-Process -ErrorAction SilentlyContinue |
        Select-Object -Expand ProcessName -Unique |
        ForEach-Object {

            $i = $appList.Items.Add($_)

            if ($script:Apps -contains $_) {
                $appList.SetItemChecked($i, $true)
            }
        }

    $exeList.Items.Clear()
    foreach ($e in $script:ExePaths) { [void]$exeList.Items.Add($e) }

    $folderList.Items.Clear()
    foreach ($f in $script:Folders) { [void]$folderList.Items.Add($f) }
}

function Refresh-Profiles {
    $profileBox.Items.Clear()
    foreach ($p in (Load-Profiles).Keys) {
        [void]$profileBox.Items.Add($p)
    }
}

# =========================================================
# SESSION FUNCTIONS
# =========================================================

function Update-SessionDisplay {
    try {
        if ($script:SessionForm -eq $null -or $script:SessionForm.IsDisposed) { 
            Stop-Session
            return 
        }
        
        $now = Get-Date
        $remaining = $script:UnlockTime - $now
        
        if ($remaining.TotalSeconds -lt 0) {
            $remaining = New-TimeSpan -Seconds 0
        }
        
        $label = $script:SessionForm.Tag
        if ($label -and -not $label.IsDisposed) {
            $label.Text = ("Time Remaining: {0:hh\:mm\:ss}" -f $remaining)
        }
        
        if ($now -ge $script:UnlockTime) {
            Stop-Session
        }
        
        Block-Apps
    }
    catch {
        # Silently handle errors
    }
}

function Stop-Session {
    try {
        if ($script:SessionTimer) { 
            $script:SessionTimer.Stop() 
            $script:SessionTimer.Dispose()
            $script:SessionTimer = $null
        }
        
        Unlock-Folders
        
        if ($script:SessionTray) { 
            $script:SessionTray.Visible = $false 
            $script:SessionTray.Dispose()
            $script:SessionTray = $null
        }
        
        if ($script:SessionForm -and -not $script:SessionForm.IsDisposed) { 
            $script:SessionForm.Close()
            $script:SessionForm = $null
        }
    }
    catch {}
}

function Start-Session {
    # Clean up any existing session
    Stop-Session
    
    # Set unlock time
    $script:UnlockTime = (Get-Date).AddMinutes([int]$minutesBox.Value)
    
    # Lock folders
    Lock-Folders
    
    # Create session form
    $form = New-Object System.Windows.Forms.Form
    $form.Text = "TimeLock Active"
    $form.Size = New-Object System.Drawing.Size(350, 150)
    $form.StartPosition = "CenterScreen"
    $form.TopMost = $true
    $form.FormBorderStyle = 'FixedDialog'
    $form.MaximizeBox = $false
    
    # Create label
    $label = New-Object System.Windows.Forms.Label
    $label.Location = New-Object System.Drawing.Point(20, 30)
    $label.Size = New-Object System.Drawing.Size(300, 50)
    $label.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Regular)
    $label.TextAlign = 'MiddleCenter'
    $form.Controls.Add($label)
    
    # Store label reference in form tag
    $form.Tag = $label
    
    # Create info label
    $infoLabel = New-Object System.Windows.Forms.Label
    $infoLabel.Location = New-Object System.Drawing.Point(20, 80)
    $infoLabel.Size = New-Object System.Drawing.Size(300, 30)
    $infoLabel.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Regular)
    $infoLabel.Text = "Right-click tray icon for menu"
    $infoLabel.TextAlign = 'MiddleCenter'
    $form.Controls.Add($infoLabel)
    
    # Create tray icon
    $tray = New-Object System.Windows.Forms.NotifyIcon
    $tray.Icon = [System.Drawing.SystemIcons]::Shield
    $tray.Visible = $true
    $tray.Text = "TimeLock - Session Active"
    
    # Create tray menu
    $menu = New-Object System.Windows.Forms.ContextMenuStrip
    $openItem = $menu.Items.Add("Show Window")
    $openItem.Add_Click({
        if ($script:SessionForm -and -not $script:SessionForm.IsDisposed) {
            $script:SessionForm.WindowState = 'Normal'
            $script:SessionForm.Show()
            $script:SessionForm.Activate()
        }
    })
    
    $menu.Items.Add("-")
    
    $exitItem = $menu.Items.Add("Exit Session")
    $exitItem.Add_Click({
        Stop-Session
        if ($script:MainForm -and -not $script:MainForm.IsDisposed) {
            $script:MainForm.Close()
        }
    })
    
    $tray.ContextMenuStrip = $menu
    
    # Handle form closing (hide to tray)
    $form.Add_FormClosing({
        if ($_.CloseReason -eq "UserClosing") {
            $_.Cancel = $true
            $script:SessionForm.Hide()
        }
    })
    
    # Set initial text
    $initialRemaining = $script:UnlockTime - (Get-Date)
    $label.Text = ("Time Remaining: {0:hh\:mm\:ss}" -f $initialRemaining)
    
    # Create and start timer
    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 1000
    $timer.Add_Tick({ Update-SessionDisplay })
    $timer.Start()
    
    # Store references globally
    $script:SessionForm = $form
    $script:SessionTimer = $timer
    $script:SessionTray = $tray
    
    # Show form
    $form.Show()
}

# =========================================================
# MAIN UI
# =========================================================

$form = New-Object System.Windows.Forms.Form
$form.Text = "TimeLock"
$form.Size = New-Object System.Drawing.Size(580, 580)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = 'FixedDialog'
$form.MaximizeBox = $false
$script:MainForm = $form

# APPS
$appList = New-Object System.Windows.Forms.CheckedListBox
$appList.Location = New-Object System.Drawing.Point(10, 10)
$appList.Size = New-Object System.Drawing.Size(540, 120)
$form.Controls.Add($appList)

# EXE
$exeList = New-Object System.Windows.Forms.ListBox
$exeList.Location = New-Object System.Drawing.Point(10, 140)
$exeList.Size = New-Object System.Drawing.Size(420, 80)
$form.Controls.Add($exeList)

$btnExe = New-Object System.Windows.Forms.Button
$btnExe.Text = "Add EXE"
$btnExe.Location = New-Object System.Drawing.Point(440, 140)
$btnExe.Size = New-Object System.Drawing.Size(110, 30)
$form.Controls.Add($btnExe)

$exeDialog = New-Object System.Windows.Forms.OpenFileDialog
$exeDialog.Filter = "EXE (*.exe)|*.exe"

$btnExe.Add_Click({
    if ($exeDialog.ShowDialog() -eq "OK") {
        if (-not $script:ExePaths.Contains($exeDialog.FileName)) {
            $script:ExePaths.Add($exeDialog.FileName)
            [void]$exeList.Items.Add($exeDialog.FileName)
        }
    }
})

# FOLDERS
$folderList = New-Object System.Windows.Forms.ListBox
$folderList.Location = New-Object System.Drawing.Point(10, 230)
$folderList.Size = New-Object System.Drawing.Size(420, 80)
$form.Controls.Add($folderList)

$btnFolder = New-Object System.Windows.Forms.Button
$btnFolder.Text = "Add Folder"
$btnFolder.Location = New-Object System.Drawing.Point(440, 230)
$btnFolder.Size = New-Object System.Drawing.Size(110, 30)
$form.Controls.Add($btnFolder)

$folderDialog = New-Object System.Windows.Forms.FolderBrowserDialog

$btnFolder.Add_Click({
    if ($folderDialog.ShowDialog() -eq "OK") {
        if (-not $script:Folders.Contains($folderDialog.SelectedPath)) {
            $script:Folders.Add($folderDialog.SelectedPath)
            [void]$folderList.Items.Add($folderDialog.SelectedPath)
        }
    }
})

# TIME
$minutesBox = New-Object System.Windows.Forms.NumericUpDown
$minutesBox.Location = New-Object System.Drawing.Point(10, 320)
$minutesBox.Size = New-Object System.Drawing.Size(100, 20)
$minutesBox.Minimum = 1
$minutesBox.Maximum = 1440
$minutesBox.Value = $LockMinutes
$form.Controls.Add($minutesBox)

$timeLabel = New-Object System.Windows.Forms.Label
$timeLabel.Text = "Minutes"
$timeLabel.Location = New-Object System.Drawing.Point(120, 322)
$form.Controls.Add($timeLabel)

# PROFILES
$profileBox = New-Object System.Windows.Forms.ComboBox
$profileBox.Location = New-Object System.Drawing.Point(10, 360)
$profileBox.Size = New-Object System.Drawing.Size(200, 25)
$form.Controls.Add($profileBox)

Refresh-Profiles

$btnSave = New-Object System.Windows.Forms.Button
$btnSave.Text = "Save Profile"
$btnSave.Location = New-Object System.Drawing.Point(220, 358)
$btnSave.Size = New-Object System.Drawing.Size(100, 30)
$form.Controls.Add($btnSave)

$btnSave.Add_Click({
    $name = [Microsoft.VisualBasic.Interaction]::InputBox("Profile name")
    if ($name) {
        Save-Profile $name
        Refresh-Profiles
    }
})

$btnLoad = New-Object System.Windows.Forms.Button
$btnLoad.Text = "Load Profile"
$btnLoad.Location = New-Object System.Drawing.Point(330, 358)
$btnLoad.Size = New-Object System.Drawing.Size(100, 30)
$form.Controls.Add($btnLoad)

$btnLoad.Add_Click({
    if ($profileBox.SelectedItem) {
        Load-Profile $profileBox.SelectedItem
    }
})

# START
$btnStart = New-Object System.Windows.Forms.Button
$btnStart.Text = "START SESSION"
$btnStart.Location = New-Object System.Drawing.Point(10, 410)
$btnStart.Size = New-Object System.Drawing.Size(540, 50)
$btnStart.BackColor = 'LightGreen'
$btnStart.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($btnStart)

$btnStart.Add_Click({
    # Add checked apps
    foreach ($i in $appList.CheckedItems) {
        if (-not $script:Apps.Contains($i.ToString())) {
            $script:Apps.Add($i.ToString())
        }
    }
    
    # Hide main form and start session
    $form.Hide()
    Start-Session
})

# INIT
Refresh-All

# Show main form
[System.Windows.Forms.Application]::Run($form)