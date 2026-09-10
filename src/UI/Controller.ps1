Set-StrictMode -Version Latest

function Get-UiText {
    param([string] $Key)
    Get-Translation $script:strings $Key
}

function Show-ActionError {
    param([string] $Key = 'Error.Action')
    $null = [Windows.MessageBox]::Show($script:window, (Get-UiText $Key), (Get-UiText 'MainWindow.Title'), 'OK', 'Error')
}

function Get-ResultMessage {
    param($Result)
    (Get-UiText ('Message.' + $Result.Message)) -f $Result.Details.Code
}

function Update-Details {
    $selected = $script:controls.ChecksDataGrid.SelectedItem
    $script:controls.HistoryDataGrid.ItemsSource = $null
    if ($null -eq $selected) {
        $script:controls.SelectionTextBlock.Text = Get-UiText 'Label.Select'
        $script:controls.DetailsTextBlock.Text = ''
        return
    }
    $result = $script:state.Results[$selected.Name]
    $script:controls.SelectionTextBlock.Text = '{0} — {1}' -f $selected.Name, $selected.StatusText
    $history = @()
    if ($script:state.History.ContainsKey($selected.Name)) { $history = @($script:state.History[$selected.Name].ToArray()) }
    $rate = '—'
    if ($history.Count -gt 0) { $rate = '{0:N1} %' -f (100 * @($history | Where-Object { $_.Success }).Count / $history.Count) }
    $note = Get-UiText 'Label.HistoryNote'
    if ($result.Type -eq 'Ping') { $note += "`n" + (Get-UiText 'Label.PingNote') }
    $script:controls.DetailsTextBlock.Text = (Get-UiText 'Label.Details') -f $result.Target, $result.Type, $selected.Checked, $result.DurationMs, $selected.StatusText, (Get-ResultMessage $result), $rate, $note
    $script:controls.HistoryDataGrid.ItemsSource = @($history | ForEach-Object {
        [pscustomobject]@{ Checked = $_.Timestamp.ToLocalTime().ToString('g'); StatusText = Get-UiText ('Status.' + $_.Status); DurationMs = $_.DurationMs; MessageText = Get-ResultMessage $_ }
    })
}

function Update-CheckRows {
    $selectedName = $null
    if ($null -ne $script:controls.ChecksDataGrid.SelectedItem) { $selectedName = $script:controls.ChecksDataGrid.SelectedItem.Name }
    $search = $script:controls.SearchTextBox.Text
    $group = $script:controls.GroupComboBox.SelectedValue
    $colors = @{ Unknown = '#8895A7'; Disabled = '#8895A7'; Running = '#287DC1'; Online = '#299447'; Degraded = '#D68A06'; Offline = '#D63232'; Error = '#D63232' }
    $rows = @(foreach ($check in $script:state.Configuration.Checks) {
        $result = $script:state.Results[$check.Name]
        if ($group -and $check.Group -ne $group) { continue }
        if ($search -and ($check.Name + ' ' + $check.Target).IndexOf($search, [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
        if ($script:controls.ErrorsOnlyCheckBox.IsChecked -and $result.Status -notin @('Degraded', 'Offline', 'Error')) { continue }
        $checked = '—'
        if ($result.Status -notin @('Unknown', 'Disabled')) { $checked = $result.Timestamp.ToLocalTime().ToString('T') }
        $ping = '—'; $service = '—'; $http = '—'
        if ($result.Status -notin @('Unknown', 'Disabled')) {
            if ($check.Type -eq 'Ping') { $ping = '{0} ms' -f $result.DurationMs }
            if ($check.Type -eq 'Tcp') { $service = Get-UiText ('Status.' + $result.Status) }
            if ($check.Type -eq 'Http' -and $result.Details.Code -is [int]) { $http = [string] $result.Details.Code }
        }
        [pscustomobject]@{
            Name = $check.Name; Type = $check.Type; Target = $check.Target; Group = $check.Group
            Status = $result.Status; StatusText = Get-UiText ('Status.' + $result.Status)
            Color = $colors[$result.Status]; Ping = $ping; Service = $service; Http = $http; Checked = $checked
        }
    })
    $script:controls.ChecksDataGrid.ItemsSource = $rows
    if ($selectedName) {
        foreach ($row in $rows) { if ($row.Name -eq $selectedName) { $script:controls.ChecksDataGrid.SelectedItem = $row; break } }
    }
    $results = @($script:state.Results.Values)
    $script:controls.SummaryTextBlock.Text = (Get-UiText 'Label.Summary') -f $results.Count, @($results | Where-Object Status -eq 'Online').Count, @($results | Where-Object Status -eq 'Degraded').Count, @($results | Where-Object { $_.Status -in @('Offline', 'Error') }).Count
    Update-Details
}

function Get-CheckGroupOptions {
    param([hashtable] $Configuration, [string] $AllLabel)
    [pscustomobject]@{ Label = ('{0} ({1})' -f $AllLabel, $Configuration.Checks.Count); Value = '' }
    # Windows PowerShell 5.1 requires an expression to group by a hashtable key.
    $Configuration.Checks | Group-Object -Property { $_['Group'] } | Sort-Object Name | ForEach-Object {
        [pscustomobject]@{ Label = '{0} ({1})' -f $_.Name, $_.Count; Value = $_.Name }
    }
}

function Set-UiConfiguration {
    param([hashtable] $Configuration, [string] $Path)
    if ($null -ne $script:state) { Close-MonitorState $script:state }
    $script:configurationPath = $Path
    $script:strings = Import-Translations (Join-Path $script:sourceDirectory 'Localization') $Configuration.Language
    foreach ($key in $script:strings.Keys) { $script:window.Resources[$key] = $script:strings[$key] }
    # DataGrid columns are outside the visual tree, so set their resource headers explicitly.
    $columnKeys = @('Name', 'Type', 'Target', 'Ping', 'Service', 'Http', 'Checked', 'Status')
    for ($index = 0; $index -lt $columnKeys.Count; $index++) {
        $script:controls.ChecksDataGrid.Columns[$index].Header = Get-UiText ('Column.' + $columnKeys[$index])
    }
    $columnKeys = @('Checked', 'Status', 'Duration', 'Message')
    for ($index = 0; $index -lt $columnKeys.Count; $index++) {
        $script:controls.HistoryDataGrid.Columns[$index].Header = Get-UiText ('Column.' + $columnKeys[$index])
    }
    $script:state = New-MonitorState $Configuration (Join-Path $script:sourceDirectory 'Checks/Checks.ps1')
    $script:state.Paused = [bool] $script:controls.PauseMenuItem.IsChecked
    foreach ($check in $Configuration.Checks) {
        $status = 'Unknown'
        if (-not $check.Enabled) { $status = 'Disabled' }
        $script:state.Results[$check.Name] = New-CheckResult $check $status $status
    }
    $groups = @(Get-CheckGroupOptions -Configuration $Configuration -AllLabel (Get-UiText 'Label.All'))
    $script:controls.GroupsListBox.ItemsSource = $groups
    $script:controls.GroupComboBox.ItemsSource = $groups
    $script:controls.GroupComboBox.SelectedIndex = 0
    $script:controls.GroupsListBox.SelectedIndex = 0
    Update-CheckRows
}

function Request-Configuration {
    param([string] $Path)
    try {
        $configuration = Import-MonitorConfiguration $Path
        # Apply after active checks finish; file replacement never blocks the dispatcher.
        $script:pendingConfiguration = @{ Configuration = $configuration; Path = $Path }
        $script:state.Pending.Clear()
    }
    catch { Show-ActionError 'Error.Configuration' }
}

function Open-ConfigurationDialog {
    $dialog = New-Object Microsoft.Win32.OpenFileDialog
    $dialog.Filter = Get-UiText 'Dialog.Configuration'
    if ($dialog.ShowDialog($script:window)) { Request-Configuration $dialog.FileName }
}

function Export-CheckResults {
    try {
        $dialog = New-Object Microsoft.Win32.SaveFileDialog
        $dialog.Filter = Get-UiText 'Dialog.Csv'
        $dialog.FileName = 'supervision.csv'
        if ($dialog.ShowDialog($script:window)) {
            # Export the filtered view. Escape spreadsheet formulas in user-controlled cells.
            $export = @($script:controls.ChecksDataGrid.ItemsSource | Select-Object Name, Type, Target, Group, Status, Checked)
            foreach ($row in $export) {
                foreach ($property in $row.PSObject.Properties) {
                    if ([string] $property.Value -match '^[\s]*[=+@-]') { $property.Value = "'" + $property.Value }
                }
            }
            $export | Export-Csv -LiteralPath $dialog.FileName -NoTypeInformation -Encoding UTF8
        }
    }
    catch { Show-ActionError }
}

function Invoke-UiTick {
    try {
        $received = @(Receive-MonitorResults $script:state)
        foreach ($result in $received) {
            $level = 'Info'
            if (-not $result.Success) { $level = 'Warning' }
            # Names, targets and request data are intentionally excluded from disk diagnostics.
            $logged = Write-ApplicationLog $script:logDirectory $level 'Checks' ('Type={0}; Status={1}; DurationMs={2}; Message={3}; Code={4}' -f $result.Type, $result.Status, $result.DurationMs, $result.Message, $result.Details.Code)
            if (-not $logged) { $script:loggingFailed = $true }
            $line = '{0:T}  {1}  {2}  {3}' -f $result.Timestamp.ToLocalTime(), $result.Name, (Get-UiText ('Status.' + $result.Status)), (Get-ResultMessage $result)
            $script:journal.Insert(0, $line)
            if ($script:journal.Count -gt 300) { $script:journal.RemoveAt(300) }
        }
        if ($received.Count -gt 0) {
            Update-CheckRows
            $script:controls.JournalTextBox.Text = $script:journal -join "`r`n"
        }
        if ($null -ne $script:pendingConfiguration -and -not $script:state.Running) {
            $pending = $script:pendingConfiguration
            $script:pendingConfiguration = $null
            Set-UiConfiguration $pending.Configuration $pending.Path
        }
        if (-not $script:state.Running -and -not $script:state.Paused -and [DateTime]::UtcNow -ge $script:state.NextRun) { Start-MonitorCycle $script:state }
        $activity = (Get-UiText 'Label.Ready') -f $script:state.NextRun.ToLocalTime().ToString('T')
        if ($script:state.Running) { $activity = Get-UiText 'Label.Running' }
        elseif ($script:state.Paused) { $activity = Get-UiText 'Label.Paused' }
        if ($script:loggingFailed) { $activity += ' | ' + (Get-UiText 'Error.Logging') }
        $script:controls.ActivityTextBlock.Text = $activity
        $script:controls.RefreshButton.IsEnabled = -not $script:state.Running
        $script:controls.RefreshMenuItem.IsEnabled = -not $script:state.Running
    }
    catch {
        $script:timer.Stop()
        Show-ActionError
    }
}

function Show-MonitorWindow {
    param([hashtable] $Configuration, [string] $Path, [string] $SourceDirectory, [bool] $ConfigurationFailed)
    $script:sourceDirectory = $SourceDirectory
    $script:state = $null
    $script:pendingConfiguration = $null
    $script:loggingFailed = $false
    $script:journal = New-Object 'System.Collections.Generic.List[string]'
    $script:logDirectory = Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) 'my-little-supervision/Logs'
    $reader = [Xml.XmlReader]::Create((Join-Path $SourceDirectory 'UI/MainWindow.xaml'))
    try { $script:window = [Windows.Markup.XamlReader]::Load($reader) }
    finally { $reader.Dispose() }
    $script:controls = @{}
    foreach ($name in @('OpenMenuItem', 'ExportMenuItem', 'ExitMenuItem', 'PauseMenuItem', 'RefreshMenuItem', 'ReloadMenuItem', 'LogsMenuItem', 'AboutMenuItem', 'RefreshButton', 'ExportButton', 'FolderButton', 'OpenButton', 'GroupsListBox', 'SearchTextBox', 'GroupComboBox', 'ErrorsOnlyCheckBox', 'ChecksDataGrid', 'HistoryDataGrid', 'DetailsTextBlock', 'SelectionTextBlock', 'JournalTextBox', 'SummaryTextBlock', 'ActivityTextBlock')) {
        $script:controls[$name] = $script:window.FindName($name)
    }
    Set-UiConfiguration $Configuration $Path
    $script:controls.RefreshButton.Add_Click({ Start-MonitorCycle $script:state })
    $script:controls.RefreshMenuItem.Add_Click({ Start-MonitorCycle $script:state })
    $script:controls.OpenButton.Add_Click({ Open-ConfigurationDialog })
    $script:controls.OpenMenuItem.Add_Click({ Open-ConfigurationDialog })
    $script:controls.ReloadMenuItem.Add_Click({ Request-Configuration $script:configurationPath })
    $script:controls.ExportButton.Add_Click({ Export-CheckResults })
    $script:controls.ExportMenuItem.Add_Click({ Export-CheckResults })
    $script:controls.ExitMenuItem.Add_Click({ $script:window.Close() })
    $script:controls.PauseMenuItem.Add_Click({ $script:state.Paused = [bool] $script:controls.PauseMenuItem.IsChecked })
    $script:controls.FolderButton.Add_Click({
        try { Invoke-Item -LiteralPath (Split-Path -Parent $script:configurationPath) } catch { Show-ActionError }
    })
    $script:controls.LogsMenuItem.Add_Click({
        try {
            $null = New-Item -ItemType Directory -Path $script:logDirectory -Force
            Invoke-Item -LiteralPath $script:logDirectory
        }
        catch { Show-ActionError }
    })
    $script:controls.AboutMenuItem.Add_Click({ $null = [Windows.MessageBox]::Show($script:window, (Get-UiText 'About.Text'), (Get-UiText 'MainWindow.Title')) })
    $script:controls.SearchTextBox.Add_TextChanged({ Update-CheckRows })
    $script:controls.ErrorsOnlyCheckBox.Add_Click({ Update-CheckRows })
    $script:controls.GroupComboBox.Add_SelectionChanged({
        $script:controls.GroupsListBox.SelectedValue = $script:controls.GroupComboBox.SelectedValue
        Update-CheckRows
    })
    $script:controls.GroupsListBox.Add_SelectionChanged({
        $script:controls.GroupComboBox.SelectedValue = $script:controls.GroupsListBox.SelectedValue
    })
    $script:controls.ChecksDataGrid.Add_SelectionChanged({ Update-Details })
    $script:timer = New-Object Windows.Threading.DispatcherTimer
    $script:timer.Interval = [TimeSpan]::FromMilliseconds(250)
    $script:timer.Add_Tick({ Invoke-UiTick })
    $script:window.Add_ContentRendered({
        if ($ConfigurationFailed) { Show-ActionError 'Error.Configuration' }
        $script:timer.Start()
    })
    try { $null = $script:window.ShowDialog() }
    finally {
        $script:timer.Stop()
        if ($null -ne $script:state) { Close-MonitorState $script:state }
    }
}
