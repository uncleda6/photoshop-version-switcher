#Requires -Version 5.1
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$project = Split-Path -Parent $PSScriptRoot
$parseFailures = @()
foreach ($file in Get-ChildItem -LiteralPath $project -Recurse -File | Where-Object { $_.Extension -in @('.ps1', '.psm1') }) {
    $tokens = $null; $errors = $null
    [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    $parseFailures += @($errors)
}
if ($parseFailures.Count) { throw ($parseFailures | Out-String) }
Write-Host 'PASS: all PowerShell source files parse.'
Import-Module (Join-Path $project 'src\PhotoshopVersionSwitcher.psm1') -Force
$testId = [Guid]::NewGuid().ToString('N')
$hivePath = 'Software\PhotoshopVersionSwitcherTests\' + $testId
$root = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($hivePath)
$work = Join-Path $env:TEMP ('PhotoshopVersionSwitcherTests-' + $testId)
[IO.Directory]::CreateDirectory($work) | Out-Null
$passed = 0
function Assert([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Test([string]$Name, [scriptblock]$Body) { & $Body; $script:passed++; Write-Host ('PASS: ' + $Name) }
function Set-TestValue([string]$Path, [string]$Name, $Data, [Microsoft.Win32.RegistryValueKind]$Kind = [Microsoft.Win32.RegistryValueKind]::String) {
    $key = $root.CreateSubKey($Path); try { $key.SetValue($Name, $Data, $Kind) } finally { $key.Dispose() }
}
function Read-TestValue([string]$Path, [string]$Name) {
    $key = $root.OpenSubKey($Path); if (-not $key) { return $null }; try { $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) } finally { $key.Dispose() }
}
function Fake-Install([string]$Year, [int]$Major, [string]$Id, [string]$Drive) {
    [pscustomobject]@{ Name = 'Adobe Photoshop ' + $Year; Version = "$Major.0"; Major = $Major; Path = $Drive + ':\Apps with spaces\Photoshop ' + $Year + '\Photoshop.exe'; Id = $Id; PSDProgId = 'PhotoshopVersionSwitcher.PSD.' + $Id; PSBProgId = 'PhotoshopVersionSwitcher.PSB.' + $Id }
}
$items = @((Fake-Install '2023' 24 'V24_012345abcdef' 'C'), (Fake-Install '2025' 26 'V26_abcdef012345' 'G'))
try {
    Test 'two relocated installations receive independent PSD and PSB handlers' {
        $plan = @(New-RegistrationPlan -Installations $items -Root $root)
        foreach ($item in $items) {
            $commands = @($plan | Where-Object { $_.Path -like ('*' + $item.Id + '\shell\open\command') })
            Assert ($commands.Count -eq 2) 'Each version must register PSD and PSB commands.'
            foreach ($command in $commands) { Assert ($command.Data -ceq ('"' + $item.Path + '" "%1"')) 'Executable and document paths must be independently quoted.' }
        }
        Assert (@($plan | Where-Object { $_.Path -match 'UserChoice|App Paths|Applications\\Photoshop.exe' }).Count -eq 0) 'Registration must not rewrite defaults or shared executable paths.'
    }
    Test 'native Adobe handlers are reused without rewriting their commands' {
        $native = [pscustomobject]@{ Name = 'Adobe Photoshop 2023'; Version = '24.0'; Major = 24; Path = 'C:\Adobe\Photoshop.exe'; Id = 'V24_000000000000'; PSDProgId = 'Photoshop.Image.24'; PSBProgId = 'Photoshop.PSBFile.170' }
        $plan = @(New-RegistrationPlan -Installations @($native) -Root $root)
        Assert (@($plan | Where-Object { $_.Path -like '*\shell\open\command' }).Count -eq 0) 'Native command values must remain untouched.'
        Assert (@($plan | Where-Object { $_.Name -eq '.psb' -and $_.Data -eq 'Photoshop.PSBFile.170' }).Count -eq 1) 'PSB must map to its own native handler.'
    }
    Test 'legacy history cleanup removes only the ambiguous Photoshop executable' {
        $history = 'Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.psd\OpenWithList'
        Set-TestValue $history 'a' 'Photoshop.exe'
        Set-TestValue $history 'b' 'OtherViewer.exe'
        Set-TestValue $history 'MRUList' 'ba'
        $plan = @(New-RegistrationPlan -Installations $items -Root $root)
        Assert (@($plan | Where-Object { $_.Action -eq 'Remove' -and $_.Name -eq 'a' }).Count -eq 1) 'Photoshop history must be removed.'
        Assert (@($plan | Where-Object { $_.Action -eq 'Remove' -and $_.Name -eq 'b' }).Count -eq 0) 'Other app history must remain.'
        Assert (@($plan | Where-Object { $_.Name -eq 'MRUList' -and $_.Data -eq 'b' }).Count -eq 1) 'MRUList must be updated consistently.'
    }
    Test 'apply is idempotent and preserves an existing default and unrelated data' {
        Set-TestValue 'Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.psd\UserChoice' 'ProgId' 'Photoshop.Image.24'
        Set-TestValue 'Software\UnrelatedApplication' 'Keep' 'untouched'
        $plan = @(New-RegistrationPlan -Installations $items -Root $root)
        $script:firstApply = Invoke-RegistrationPlan -Plan $plan -StateDirectory $work -Root $root
        Assert ($firstApply.Status -eq 'Applied' -and (Test-Path -LiteralPath $firstApply.BackupPath)) 'Apply must create a backup before writing.'
        Assert ((Read-TestValue 'Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.psd\UserChoice' 'ProgId') -eq 'Photoshop.Image.24') 'Default must be preserved.'
        Assert ((Read-TestValue 'Software\UnrelatedApplication' 'Keep') -eq 'untouched') 'Unrelated registry data must be preserved.'
        $again = Invoke-RegistrationPlan -Plan @(New-RegistrationPlan -Installations $items -Root $root) -StateDirectory $work -Root $root
        Assert ($again.Status -eq 'NoChanges') 'A repeated repair must not accumulate changes or backups.'
    }
    Test 'restore returns previous history and removes only newly created empty keys' {
        $result = Restore-RegistrationBackup -BackupPath $firstApply.BackupPath -Root $root
        Assert ($result.Status -eq 'Restored') 'Restore must finish without conflicts.'
        $history = 'Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.psd\OpenWithList'
        Assert ((Read-TestValue $history 'a') -eq 'Photoshop.exe') 'Original Photoshop history must be restored.'
        Assert ((Read-TestValue $history 'b') -eq 'OtherViewer.exe') 'Other app history must remain.'
        Assert ((Read-TestValue $history 'MRUList') -eq 'ba') 'Original MRUList must be restored.'
        Assert ($null -eq $root.OpenSubKey('Software\PhotoshopVersionSwitcher')) 'Empty tool-created registry hierarchy must be removed.'
        Assert ((Read-TestValue 'Software\UnrelatedApplication' 'Keep') -eq 'untouched') 'Restore must not affect an unrelated sibling.'
    }
    Test 'restore preserves later user edits and reports a conflict' {
        $plan = @([pscustomobject]@{ Action = 'Set'; Path = 'Software\Classes\Photoshop.Image.24\Application'; Name = 'ApplicationName'; Kind = 'String'; Data = 'Adobe Photoshop 2023' })
        $applied = Invoke-RegistrationPlan -Plan $plan -StateDirectory $work -Root $root
        Set-TestValue $plan[0].Path 'ApplicationName' 'Later user edit'
        $result = Restore-RegistrationBackup -BackupPath $applied.BackupPath -Root $root
        Assert ($result.Status -eq 'PartiallyRestored' -and $result.Conflicts.Count -eq 1) 'Restore must report a concurrent edit.'
        Assert ((Read-TestValue $plan[0].Path 'ApplicationName') -eq 'Later user edit') 'Restore must not clobber a later user edit.'
    }
    Test 'backup preserves registry types and unexpanded values' {
        $path = 'Software\Classes\Photoshop.Image.26\Application'
        Set-TestValue $path 'ApplicationDescription' '%LOCALAPPDATA%\Example' ([Microsoft.Win32.RegistryValueKind]::ExpandString)
        Set-TestValue $path 'BinaryFixture' ([byte[]]@(0, 1, 128, 255)) ([Microsoft.Win32.RegistryValueKind]::Binary)
        $plan = @(
            [pscustomobject]@{ Action = 'Set'; Path = $path; Name = 'ApplicationDescription'; Kind = 'String'; Data = 'New' },
            [pscustomobject]@{ Action = 'Set'; Path = $path; Name = 'BinaryFixture'; Kind = 'String'; Data = 'New' }
        )
        $applied = Invoke-RegistrationPlan -Plan $plan -StateDirectory $work -Root $root
        Restore-RegistrationBackup -BackupPath $applied.BackupPath -Root $root | Out-Null
        $key = $root.OpenSubKey($path)
        try {
            Assert ($key.GetValueKind('ApplicationDescription') -eq [Microsoft.Win32.RegistryValueKind]::ExpandString) 'ExpandString type must survive rollback.'
            Assert ($key.GetValue('ApplicationDescription', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) -ceq '%LOCALAPPDATA%\Example') 'Environment variables must not be expanded in backups.'
            Assert ([Convert]::ToBase64String($key.GetValue('BinaryFixture')) -ceq 'AAGA/w==') 'Binary data must survive rollback.'
        } finally { $key.Dispose() }
    }
    Test 'out-of-scope operations and forged backups fail before writing' {
        $bad = @([pscustomobject]@{ Action = 'Set'; Path = 'Software\UnrelatedApplication'; Name = 'Keep'; Kind = 'String'; Data = 'bad' })
        $rejected = $false
        try { Invoke-RegistrationPlan -Plan $bad -StateDirectory $work -Root $root | Out-Null } catch { $rejected = $true }
        Assert $rejected 'Arbitrary registry writes must be rejected.'
        $document = Get-Content -LiteralPath $firstApply.BackupPath -Raw | ConvertFrom-Json
        $document.Entries[0].Path = 'Software\UnrelatedApplication'
        $forged = Join-Path $work 'forged.json'; $document | ConvertTo-Json -Depth 14 | Set-Content -LiteralPath $forged -Encoding UTF8
        $rejected = $false
        try { Restore-RegistrationBackup -BackupPath $forged -Root $root | Out-Null } catch { $rejected = $true }
        Assert $rejected 'An out-of-scope backup must be rejected.'
        Assert ((Read-TestValue 'Software\UnrelatedApplication' 'Keep') -eq 'untouched') 'Rejected backup must not modify unrelated data.'
    }
    Test 'a selected newly created handler cannot be removed by rollback' {
        $plan = @(New-RegistrationPlan -Installations @($items[0]) -Root $root)
        $applied = Invoke-RegistrationPlan -Plan $plan -StateDirectory $work -Root $root
        Set-TestValue 'Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.psd\UserChoice' 'ProgId' $items[0].PSDProgId
        $rejected = $false
        try { Restore-RegistrationBackup -BackupPath $applied.BackupPath -Root $root | Out-Null } catch { $rejected = $true }
        Assert $rejected 'Rollback must not leave UserChoice pointing at a removed handler.'
        Set-TestValue 'Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\.psd\UserChoice' 'ProgId' 'Photoshop.Image.24'
        Restore-RegistrationBackup -BackupPath $applied.BackupPath -Root $root | Out-Null
    }
    Test 'explicit discovery ignores missing or non-Photoshop binaries' {
        $missing = Join-Path $work 'missing\Photoshop.exe'
        $itemsFound = @(Get-PhotoshopInstallation -OnlySpecifiedPaths -AdditionalPath @($missing, (Join-Path $env:WINDIR 'System32\notepad.exe')))
        Assert ($itemsFound.Count -eq 0) 'Missing files and other executable names must not be registered.'
    }
    Write-Host ("`nAll {0} behavioral tests passed under PowerShell {1}." -f $passed, $PSVersionTable.PSVersion) -ForegroundColor Green
}
finally {
    $root.Dispose()
    [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($hivePath, $false)
    # The absolute fixture directory is constructed once under TEMP and never comes from a backup.
    if ([IO.Path]::GetFullPath($work).StartsWith([IO.Path]::GetFullPath($env:TEMP).TrimEnd('\') + '\', [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $work -Recurse -Force }
}
