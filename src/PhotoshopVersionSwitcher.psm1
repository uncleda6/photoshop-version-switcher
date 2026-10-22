Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-PropertyValue($Object, [string]$Name) {
    if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]) { $Object.$Name }
}

function Get-ExecutablePath([string]$Command) {
    if ($Command -match '^\s*"([^"]+\.exe)"') { return $Matches[1] }
    if ($Command -match '^\s*(.+?\.exe)(?:\s|,|$)') { return $Matches[1] }
    return $null
}

function Get-PathIdentifier([string]$Path, [int]$Major) {
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $bytes = $sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Path.ToLowerInvariant())) }
    finally { $sha.Dispose() }
    'V{0}_{1}' -f $Major, ([BitConverter]::ToString($bytes).Replace('-', '').Substring(0, 12).ToLowerInvariant())
}

function Get-NativeHandler([string]$Path, [int]$Major, [string]$Extension) {
    $candidates = @('Photoshop.Image.' + $Major)
    if ($Extension -eq '.psb') {
        $candidates = @([Microsoft.Win32.Registry]::ClassesRoot.GetSubKeyNames() | Where-Object { $_ -match '^Photoshop\.PSBFile\.\d+$' })
    }
    foreach ($candidate in $candidates) {
        $key = [Microsoft.Win32.Registry]::ClassesRoot.OpenSubKey($candidate + '\shell\open\command')
        if ($null -eq $key) { continue }
        try { $command = Get-ExecutablePath ([string]$key.GetValue('')) } finally { $key.Dispose() }
        if ($command -and $command.Equals($Path, [StringComparison]::OrdinalIgnoreCase)) { return $candidate }
    }
    return $null
}

function Get-PhotoshopInstallation {
    [CmdletBinding()]
    param([string[]]$AdditionalPath = @(), [switch]$OnlySpecifiedPaths)
    $paths = New-Object 'Collections.Generic.List[string]'
    foreach ($path in $AdditionalPath) { $paths.Add($path) }
    if (-not $OnlySpecifiedPaths) {
        foreach ($pattern in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
            foreach ($item in @(Get-ItemProperty $pattern -ErrorAction SilentlyContinue)) {
                if ([string](Get-PropertyValue $item 'DisplayName') -notmatch 'Photoshop') { continue }
                foreach ($name in @('InstallLocation', 'DisplayIcon')) {
                    $value = [string](Get-PropertyValue $item $name)
                    if ($value) { $paths.Add($value) }
                }
            }
        }
        foreach ($pattern in @('HKLM:\SOFTWARE\Adobe\Photoshop\*', 'HKCU:\SOFTWARE\Adobe\Photoshop\*')) {
            foreach ($item in @(Get-ItemProperty $pattern -ErrorAction SilentlyContinue)) {
                foreach ($name in @('ApplicationPath', 'Path')) {
                    $value = [string](Get-PropertyValue $item $name)
                    if ($value) { $paths.Add($value) }
                }
            }
        }
        foreach ($hive in @([Microsoft.Win32.Registry]::CurrentUser, [Microsoft.Win32.Registry]::LocalMachine)) {
            $key = $hive.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\App Paths\Photoshop.exe')
            if ($key) { try { $paths.Add([string]$key.GetValue('')) } finally { $key.Dispose() } }
        }
        foreach ($base in @($env:ProgramFiles, ${env:ProgramFiles(x86)})) {
            if (-not $base) { continue }
            foreach ($dir in @(Get-ChildItem -LiteralPath (Join-Path $base 'Adobe') -Directory -Filter '*Photoshop*' -ErrorAction SilentlyContinue)) { $paths.Add($dir.FullName) }
        }
    }
    $seen = @{}
    $installations = New-Object 'Collections.Generic.List[object]'
    foreach ($candidate in $paths) {
        if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
        $path = [Environment]::ExpandEnvironmentVariables($candidate.Trim().Trim('"'))
        if (Test-Path -LiteralPath $path -PathType Container) { $path = Join-Path $path 'Photoshop.exe' }
        elseif (-not (Test-Path -LiteralPath $path -PathType Leaf)) { $path = Get-ExecutablePath $candidate }
        if (-not $path -or -not (Test-Path -LiteralPath $path -PathType Leaf)) { continue }
        $file = Get-Item -LiteralPath $path
        if ($file.Name -ine 'Photoshop.exe' -or $seen.ContainsKey($file.FullName)) { continue }
        $version = $file.VersionInfo
        if ($version.ProductName -notmatch 'Adobe Photoshop' -or $version.FileMajorPart -lt 1) { continue }
        $seen[$file.FullName] = $true
        $id = Get-PathIdentifier $file.FullName $version.FileMajorPart
        $name = $version.ProductName.Trim()
        if ($name -notmatch '\d{4}|CS\d' -and $version.FileMajorPart -ge 14) { $name = 'Adobe Photoshop ' + (1999 + $version.FileMajorPart) }
        $psd = Get-NativeHandler $file.FullName $version.FileMajorPart '.psd'
        $psb = Get-NativeHandler $file.FullName $version.FileMajorPart '.psb'
        if (-not $psd) { $psd = 'PhotoshopVersionSwitcher.PSD.' + $id }
        if (-not $psb) { $psb = 'PhotoshopVersionSwitcher.PSB.' + $id }
        $installations.Add([pscustomobject]@{ Name = $name; Version = $version.FileVersion; Major = $version.FileMajorPart; Path = $file.FullName; Id = $id; PSDProgId = $psd; PSBProgId = $psb })
    }
    foreach ($group in @($installations | Group-Object Name)) {
        if ($group.Count -gt 1) { foreach ($item in $group.Group) { $item.Name += ' [' + $item.Id.Substring($item.Id.Length - 6) + ']' } }
    }
    $installations | Sort-Object Major, Path
}

function Assert-RegistrationOperation($Operation) {
    $path = [string]$Operation.Path
    $handler = '(?:Photoshop\.(?:Image|PSBFile)\.\d+|PhotoshopVersionSwitcher\.(?:PSD|PSB)\.V\d+_[a-f0-9]{12})'
    $allowed = @(
        ('^Software\\Classes\\' + $handler + '(?:\\Application|\\DefaultIcon|\\shell\\open\\command)?$'),
        '^Software\\Classes\\\.(?:psd|psb)\\OpenWithProgids$',
        '^Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\FileExts\\\.(?:psd|psb)\\(?:OpenWithProgids|OpenWithList)$',
        '^Software\\PhotoshopVersionSwitcher\\Capabilities\\V\d+_[a-f0-9]{12}(?:\\FileAssociations)?$',
        '^Software\\RegisteredApplications$'
    )
    if (-not @($allowed | Where-Object { $path -match $_ }).Count) { throw "Registry path outside repair scope: $path" }
    if ($path -eq 'Software\RegisteredApplications' -and $Operation.Name -notmatch '^Adobe Photoshop') { throw 'Unexpected registered application name.' }
    if ($Operation.Action -notin @('Set', 'Remove')) { throw 'Unsupported registry operation.' }
    if ($Operation.Kind -notin @('String', 'ExpandString', 'DWord', 'QWord', 'MultiString', 'Binary', 'None', $null)) { throw 'Unsupported registry data type.' }
}

function Get-RegistrySnapshot($Root, [string]$Path, [string]$Name) {
    $key = $Root.OpenSubKey($Path)
    try {
        if ($null -eq $key -or $key.GetValueNames() -notcontains $Name) { return [pscustomobject]@{ Exists = $false; Kind = $null; Data = $null } }
        $kind = $key.GetValueKind($Name).ToString()
        $data = $key.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if ($kind -in @('Binary', 'None')) { $data = [Convert]::ToBase64String([byte[]]$data) }
        return [pscustomobject]@{ Exists = $true; Kind = $kind; Data = $data }
    }
    finally { if ($key) { $key.Dispose() } }
}

function Test-SnapshotEqual($A, $B) {
    ($A | ConvertTo-Json -Compress -Depth 8) -ceq ($B | ConvertTo-Json -Compress -Depth 8)
}

function Set-RegistrySnapshot($Root, [string]$Path, [string]$Name, $Snapshot) {
    if (-not $Snapshot.Exists) {
        $key = $Root.OpenSubKey($Path, $true)
        if ($key) { try { $key.DeleteValue($Name, $false) } finally { $key.Dispose() } }
        return
    }
    $kind = [Microsoft.Win32.RegistryValueKind][Enum]::Parse([Microsoft.Win32.RegistryValueKind], $Snapshot.Kind)
    $data = $Snapshot.Data
    if ($Snapshot.Kind -in @('Binary', 'None')) { $data = [Convert]::FromBase64String([string]$data) }
    if ($Snapshot.Kind -eq 'MultiString') { $data = [string[]]$data }
    if ($Snapshot.Kind -eq 'DWord') { $data = [int]$data }
    if ($Snapshot.Kind -eq 'QWord') { $data = [long]$data }
    $key = $Root.CreateSubKey($Path)
    try { $key.SetValue($Name, $data, $kind) } finally { $key.Dispose() }
}

function New-RegistrationPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object[]]$Installations, $Root = [Microsoft.Win32.Registry]::CurrentUser, [switch]$KeepLegacyHistory)
    $ops = New-Object 'Collections.Generic.List[object]'
    function Add-Value([string]$Path, [string]$Name, $Value, [string]$Kind = 'String') {
        $ops.Add([pscustomobject]@{ Action = 'Set'; Path = $Path; Name = $Name; Kind = $Kind; Data = $Value })
    }
    foreach ($item in $Installations) {
        if ($item.Name -notmatch '^Adobe Photoshop' -or $item.Id -notmatch '^V\d+_[a-f0-9]{12}$' -or $item.Path -notmatch '(?i)\\Photoshop\.exe$' -or $item.Path.Contains('"') -or $item.Path.Contains("`n")) { throw 'Invalid Photoshop installation descriptor.' }
        $caps = 'Software\PhotoshopVersionSwitcher\Capabilities\' + $item.Id
        foreach ($extension in @('.psd', '.psb')) {
            $progId = if ($extension -eq '.psd') { $item.PSDProgId } else { $item.PSBProgId }
            $class = 'Software\Classes\' + $progId
            if ($progId -like 'PhotoshopVersionSwitcher.*') {
                Add-Value $class '' ($item.Name + ' ' + $extension.ToUpperInvariant().Trim('.'))
                Add-Value ($class + '\shell\open\command') '' ('"' + $item.Path + '" "%1"')
                Add-Value ($class + '\DefaultIcon') '' ('"' + $item.Path + '",0')
            }
            Add-Value ($class + '\Application') 'ApplicationName' $item.Name
            Add-Value ($class + '\Application') 'ApplicationDescription' $item.Name
            Add-Value ($class + '\Application') 'ApplicationCompany' 'Adobe'
            Add-Value ($class + '\Application') 'ApplicationIcon' ('"' + $item.Path + '",0')
            Add-Value ('Software\Classes\' + $extension + '\OpenWithProgids') $progId '' 'None'
            Add-Value ('Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\' + $extension + '\OpenWithProgids') $progId '' 'None'
            Add-Value ($caps + '\FileAssociations') $extension $progId
        }
        Add-Value $caps 'ApplicationName' $item.Name
        Add-Value $caps 'ApplicationDescription' ($item.Name + ' PSD/PSB file associations')
        Add-Value $caps 'ApplicationIcon' ('"' + $item.Path + '",0')
        Add-Value 'Software\RegisteredApplications' $item.Name $caps
    }
    if (-not $KeepLegacyHistory) {
        foreach ($extension in @('.psd', '.psb')) {
            $path = 'Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\' + $extension + '\OpenWithList'
            $key = $Root.OpenSubKey($path)
            if (-not $key) { continue }
            try {
                $removed = @($key.GetValueNames() | Where-Object { $_ -ne 'MRUList' -and $key.GetValue($_) -ieq 'Photoshop.exe' })
                foreach ($name in $removed) { $ops.Add([pscustomobject]@{ Action = 'Remove'; Path = $path; Name = $name; Kind = $null; Data = $null }) }
                if ($removed.Count -and $key.GetValueNames() -contains 'MRUList') {
                    $mru = [string]$key.GetValue('MRUList')
                    foreach ($name in $removed) { $mru = $mru.Replace($name, '') }
                    Add-Value $path 'MRUList' $mru
                }
            } finally { $key.Dispose() }
        }
    }
    foreach ($op in $ops) { Assert-RegistrationOperation $op }
    # Repeated installs must not generate conflicting writes for the same registry value.
    $unique = @{}
    foreach ($op in $ops) { $unique[$op.Path + "`0" + $op.Name] = $op }
    @($unique.Values | Sort-Object Path, Name)
}

function Save-BackupDocument([string]$Path, $Document) {
    $temp = $Path + '.tmp'
    [IO.File]::WriteAllText($temp, ($Document | ConvertTo-Json -Depth 14), (New-Object Text.UTF8Encoding($true)))
    if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temp, $Path, [System.Management.Automation.Language.NullString]::Value) }
    else { [IO.File]::Move($temp, $Path) }
}

function Invoke-RegistrationPlan {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [object[]]$Plan, [Parameter(Mandatory)] [string]$StateDirectory, $Root = [Microsoft.Win32.Registry]::CurrentUser)
    $entries = New-Object 'Collections.Generic.List[object]'
    $keys = @{}
    foreach ($op in $Plan) {
        Assert-RegistrationOperation $op
        $before = Get-RegistrySnapshot $Root $op.Path $op.Name
        $after = [pscustomobject]@{ Exists = ($op.Action -eq 'Set'); Kind = $op.Kind; Data = $op.Data }
        if ($op.Kind -eq 'None') { $after.Data = '' }
        if (Test-SnapshotEqual $before $after) { continue }
        $entries.Add([pscustomobject]@{ Path = $op.Path; Name = $op.Name; Before = $before; After = $after })
        $path = $op.Path
        while ($path) {
            if (-not $keys.ContainsKey($path)) {
                $key = $Root.OpenSubKey($path)
                $keys[$path] = [pscustomobject]@{ Path = $path; Existed = ($null -ne $key) }
                if ($key) { $key.Dispose() }
            }
            $index = $path.LastIndexOf('\')
            if ($index -lt 0) { break }
            $path = $path.Substring(0, $index)
        }
    }
    if (-not $entries.Count) { return [pscustomobject]@{ Status = 'NoChanges'; Changes = 0; BackupPath = $null } }
    [IO.Directory]::CreateDirectory($StateDirectory) | Out-Null
    $backupPath = Join-Path $StateDirectory ('backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N') + '.json')
    $document = [pscustomobject]@{ Tool = 'PhotoshopVersionSwitcher'; SchemaVersion = 1; RegistryRoot = $Root.Name; CreatedUtc = [DateTime]::UtcNow.ToString('o'); Status = 'Prepared'; Entries = @($entries.ToArray()); Keys = @($keys.Values) }
    Save-BackupDocument $backupPath $document
    try {
        foreach ($entry in $entries) {
            if (-not (Test-SnapshotEqual (Get-RegistrySnapshot $Root $entry.Path $entry.Name) $entry.Before)) { throw ('Registry value changed during repair: ' + $entry.Path + '\' + $entry.Name) }
            Set-RegistrySnapshot $Root $entry.Path $entry.Name $entry.After
        }
        $document.Status = 'Applied'
        Save-BackupDocument $backupPath $document
    }
    catch {
        $failure = $_
        try { Restore-RegistrationBackup -BackupPath $backupPath -Root $Root | Out-Null } catch { Write-Warning ('Automatic rollback needs attention: ' + $_.Exception.Message) }
        throw $failure
    }
    [pscustomobject]@{ Status = 'Applied'; Changes = $entries.Count; BackupPath = $backupPath }
}

function Restore-RegistrationBackup {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string]$BackupPath, $Root = [Microsoft.Win32.Registry]::CurrentUser)
    $document = Get-Content -LiteralPath $BackupPath -Raw | ConvertFrom-Json
    if ($document.Tool -ne 'PhotoshopVersionSwitcher' -or $document.SchemaVersion -ne 1 -or $document.RegistryRoot -ne $Root.Name) { throw 'Backup format or registry root does not match.' }
    foreach ($entry in $document.Entries) {
        Assert-RegistrationOperation ([pscustomobject]@{ Path = $entry.Path; Name = $entry.Name; Action = 'Set'; Kind = $entry.Before.Kind })
        foreach ($snapshot in @($entry.Before, $entry.After)) {
            if ($snapshot.Exists -and $snapshot.Kind -notin @('String', 'ExpandString', 'DWord', 'QWord', 'MultiString', 'Binary', 'None')) { throw 'Invalid backup registry type.' }
        }
        if ($entry.Path -match '^Software\\Classes\\(PhotoshopVersionSwitcher\.(?:PSD|PSB)\.V\d+_[a-f0-9]{12})\\shell\\open\\command$' -and -not $entry.Before.Exists) {
            $progId = $Matches[1]
            foreach ($extension in @('.psd', '.psb')) {
                $choice = Get-RegistrySnapshot $Root ('Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\' + $extension + '\UserChoice') 'ProgId'
                if ($choice.Exists -and $choice.Data -eq $progId) { throw 'Select a different default app in Windows Settings before restoring a newly created handler.' }
            }
        }
    }
    $conflicts = New-Object 'Collections.Generic.List[string]'
    $restored = 0
    foreach ($entry in @($document.Entries | Sort-Object { $_.Path.Length } -Descending)) {
        $current = Get-RegistrySnapshot $Root $entry.Path $entry.Name
        if (Test-SnapshotEqual $current $entry.Before) { continue }
        if (-not (Test-SnapshotEqual $current $entry.After)) { $conflicts.Add($entry.Path + '\' + $entry.Name); continue }
        Set-RegistrySnapshot $Root $entry.Path $entry.Name $entry.Before
        $restored++
    }
    foreach ($keyState in @($document.Keys | Sort-Object { $_.Path.Length } -Descending)) {
        if ($keyState.Existed) { continue }
        $isAncestor = @($document.Entries | Where-Object { $_.Path -eq $keyState.Path -or $_.Path.StartsWith($keyState.Path + '\', [StringComparison]::OrdinalIgnoreCase) }).Count -gt 0
        if (-not $isAncestor) { throw 'Invalid backup key ancestry.' }
        $key = $Root.OpenSubKey($keyState.Path)
        $empty = $false
        if ($key) { try { $empty = ($key.ValueCount -eq 0 -and $key.SubKeyCount -eq 0) } finally { $key.Dispose() } }
        if ($empty) { $Root.DeleteSubKey($keyState.Path, $false) }
    }
    $document.Status = if ($conflicts.Count) { 'PartiallyRestored' } else { 'Restored' }
    Save-BackupDocument $BackupPath $document
    [pscustomobject]@{ Status = $document.Status; Restored = $restored; Conflicts = @($conflicts.ToArray()); BackupPath = $BackupPath }
}

function Initialize-ShellInterop {
    if ('PhotoshopVersionSwitcher.Native' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;
namespace PhotoshopVersionSwitcher {
    public static class Native {
        [DllImport("shell32.dll")] public static extern void SHChangeNotify(uint id, uint flags, IntPtr a, IntPtr b);
        [DllImport("shlwapi.dll", CharSet = CharSet.Unicode)] public static extern uint AssocQueryString(uint flags, uint kind, string assoc, string extra, StringBuilder text, ref uint count);
        public static string Executable(string extension) {
            uint count = 32768; var text = new StringBuilder((int)count);
            return AssocQueryString(0, 2, extension, "open", text, ref count) == 0 ? text.ToString() : null;
        }
    }
}
'@
}

function Send-AssociationChanged {
    Initialize-ShellInterop
    [PhotoshopVersionSwitcher.Native]::SHChangeNotify(0x08000000, 0x1000, [IntPtr]::Zero, [IntPtr]::Zero)
}

function Get-PhotoshopAssociation {
    Initialize-ShellInterop
    foreach ($extension in @('.psd', '.psb')) {
        $choice = Get-RegistrySnapshot ([Microsoft.Win32.Registry]::CurrentUser) ('Software\Microsoft\Windows\CurrentVersion\Explorer\FileExts\' + $extension + '\UserChoice') 'ProgId'
        [pscustomobject]@{ Extension = $extension; UserChoice = $choice.Data; ShellExecutable = [PhotoshopVersionSwitcher.Native]::Executable($extension) }
    }
}

Export-ModuleMember -Function Get-PhotoshopInstallation, New-RegistrationPlan, Invoke-RegistrationPlan, Restore-RegistrationBackup, Send-AssociationChanged, Get-PhotoshopAssociation
