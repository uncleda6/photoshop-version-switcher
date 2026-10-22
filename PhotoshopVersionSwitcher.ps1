#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Menu', 'Diagnose', 'Repair', 'Restore', 'Settings')] [string]$Mode = 'Menu',
    [string[]]$PhotoshopPath = @(),
    [string]$BackupPath,
    [string]$StateDirectory = (Join-Path $env:LOCALAPPDATA 'PhotoshopVersionSwitcher\backups'),
    [switch]$NoSettings,
    [switch]$DesktopContext,
    [switch]$KeepLegacyHistory,
    [switch]$OnlySpecifiedPaths,
    [string]$RequestFile
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($env:OS -ne 'Windows_NT') { throw 'Photoshop Version Switcher requires Windows.' }
Import-Module (Join-Path $PSScriptRoot 'src\PhotoshopVersionSwitcher.psm1') -Force

function Open-DefaultApps { Start-Process 'ms-settings:defaultapps?fileExtension=.psd' }

function Invoke-Action([string]$Action, [string[]]$Paths, [string]$RestorePath, [string]$StatePath, [bool]$SkipSettings, [bool]$KeepHistory, [bool]$SpecifiedOnly) {
    switch ($Action) {
        'Diagnose' { return [pscustomobject]@{ Installations = @(Get-PhotoshopInstallation -AdditionalPath $Paths -OnlySpecifiedPaths:$SpecifiedOnly); Associations = @(Get-PhotoshopAssociation); ProcessId = $PID } }
        'Repair' {
            $items = @(Get-PhotoshopInstallation -AdditionalPath $Paths -OnlySpecifiedPaths:$SpecifiedOnly)
            if (-not $items.Count) { throw 'No Photoshop installation found. Supply -PhotoshopPath with the path to Photoshop.exe.' }
            $plan = @(New-RegistrationPlan -Installations $items -KeepLegacyHistory:$KeepHistory)
            $result = Invoke-RegistrationPlan -Plan $plan -StateDirectory $StatePath
            Send-AssociationChanged
            if (-not $SkipSettings) { Open-DefaultApps }
            return [pscustomobject]@{ Result = $result; Installations = $items; NextStep = 'Choose the desired Photoshop version in Windows Default apps for .psd and .psb.' }
        }
        'Restore' {
            if (-not $RestorePath) { throw 'Supply -BackupPath with the backup JSON to restore.' }
            $result = Restore-RegistrationBackup -BackupPath $RestorePath
            Send-AssociationChanged
            return $result
        }
        'Settings' { Open-DefaultApps; return [pscustomobject]@{ Status = 'SettingsOpened' } }
    }
}

function Invoke-DesktopAction([string]$Action, [string]$RestorePath) {
    if ($Action -notin @('Diagnose', 'Repair', 'Restore')) { throw '-DesktopContext supports Diagnose, Repair and Restore.' }
    # Keep the cross-process exchange outside AppData, whose filesystem view may
    # itself be redirected by a packaged parent. This folder is gitignored.
    $directory = Join-Path $PSScriptRoot ('.desktop-requests\' + [Guid]::NewGuid().ToString('N'))
    [IO.Directory]::CreateDirectory($directory) | Out-Null
    $request = Join-Path $directory 'request.json'
    $output = Join-Path $directory 'result.json'
    @{ Mode = $Action; PhotoshopPath = $PhotoshopPath; BackupPath = $RestorePath; StateDirectory = $StateDirectory; KeepLegacyHistory = [bool]$KeepLegacyHistory; OnlySpecifiedPaths = [bool]$OnlySpecifiedPaths; Output = $output } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $request -Encoding UTF8
    $entry = Join-Path $PSScriptRoot 'PhotoshopVersionSwitcher.ps1'
    # Win32_Process.Create calls CreateProcess directly: no cmd.exe or inline PowerShell evaluation.
    if ($entry.Contains('"') -or $request.Contains('"')) { throw 'Invalid script or request path.' }
    $exe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $command = '"' + $exe + '" -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $entry + '" -RequestFile "' + $request + '"'
    $created = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $command }
    if ($created.ReturnValue -ne 0) { throw ('Desktop process could not start: ' + $created.ReturnValue) }
    $started = [DateTime]::UtcNow
    $deadline = $started.AddSeconds(90)
    while (-not (Test-Path -LiteralPath $output)) {
        if ([DateTime]::UtcNow -gt $deadline) { throw ('Desktop process timed out. Request retained at ' + $request) }
        if (([DateTime]::UtcNow - $started).TotalSeconds -gt 2 -and -not (Get-Process -Id $created.ProcessId -ErrorAction SilentlyContinue) -and -not (Test-Path -LiteralPath $output)) { throw ('Desktop process exited without a result. Run Start.cmd from File Explorer. Request retained at ' + $request) }
        Start-Sleep -Milliseconds 200
    }
    $response = Get-Content -LiteralPath $output -Raw | ConvertFrom-Json
    if (-not $response.Success) { throw $response.Error }
    if ($Action -eq 'Repair' -and -not $NoSettings) { Open-DefaultApps }
    return $response.Result
}

if ($RequestFile) {
    $request = Get-Content -LiteralPath $RequestFile -Raw | ConvertFrom-Json
    if ($request.Mode -notin @('Diagnose', 'Repair', 'Restore')) { throw 'Unsupported desktop request.' }
    $output = Join-Path (Split-Path -Parent $RequestFile) 'result.json'
    try { $result = Invoke-Action $request.Mode @($request.PhotoshopPath) $request.BackupPath $request.StateDirectory $true $request.KeepLegacyHistory $request.OnlySpecifiedPaths; $response = @{ Success = $true; Result = $result } }
    catch { $response = @{ Success = $false; Error = $_.Exception.Message } }
    $temp = $output + '.tmp'
    $response | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $temp -Encoding UTF8
    [IO.File]::Move($temp, $output)
    exit
}

function Run-Mode([string]$Action, [string]$RestorePath = $BackupPath) {
    if ($DesktopContext) { Invoke-DesktopAction $Action $RestorePath }
    else { Invoke-Action $Action $PhotoshopPath $RestorePath $StateDirectory ([bool]$NoSettings) ([bool]$KeepLegacyHistory) ([bool]$OnlySpecifiedPaths) }
}

if ($Mode -ne 'Menu') {
    $result = Run-Mode $Mode
    $result | ConvertTo-Json -Depth 10
    if ($Mode -eq 'Restore' -and $result.Status -eq 'PartiallyRestored') { exit 2 }
    exit
}

Write-Host 'Photoshop Version Switcher / Photoshop 多版本打开方式修复' -ForegroundColor Cyan
Write-Host 'Repair the version list, then choose your default in Windows Settings.'
while ($true) {
    Write-Host "`n1. Diagnose / 检测安装版本和当前关联"
    Write-Host '2. Repair / 补齐各版本的 PSD、PSB 打开方式（自动备份）'
    Write-Host '3. Choose default / 打开 Windows 默认应用设置'
    Write-Host '4. Restore / 恢复某次修复前的注册项'
    Write-Host '5. Exit / 退出'
    $choice = Read-Host 'Select / 请选择'
    try {
        switch ($choice) {
            '1' { Run-Mode 'Diagnose' | ConvertTo-Json -Depth 10 | Write-Host }
            '2' {
                $extra = Read-Host 'Optional: full Photoshop.exe path if detection misses a version / 漏检时输入完整路径，通常直接回车'
                if ($extra) { $PhotoshopPath = @($PhotoshopPath) + $extra.Trim('"') }
                Run-Mode 'Repair' | ConvertTo-Json -Depth 10 | Write-Host
                Write-Host 'Now choose 2023, 2025, or another installed version in Windows Settings. / 请在设置中选择所需版本。' -ForegroundColor Green
            }
            '3' { Open-DefaultApps }
            '4' { $restore = Read-Host 'Backup JSON full path / 备份 JSON 完整路径'; Run-Mode 'Restore' $restore.Trim('"') | ConvertTo-Json -Depth 8 | Write-Host }
            '5' { exit }
            default { Write-Host 'Choose 1-5 / 请输入 1-5。' }
        }
    } catch { Write-Host $_.Exception.Message -ForegroundColor Red }
}
