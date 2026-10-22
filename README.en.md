# Photoshop Version Switcher

Restore separate Photoshop versions in Windows **Open with** and **Default apps**, then choose which version opens PSD and PSB files.

[中文说明](README.md) · [Download ZIP](https://github.com/uncleda6/photoshop-version-switcher/archive/refs/heads/main.zip) · [Report an issue](https://github.com/uncleda6/photoshop-version-switcher/issues)

This utility addresses missing older versions, ambiguous `Photoshop.exe` entries and duplicate names when multiple Photoshop releases are installed.

## Quick start

1. Download and fully extract the ZIP.
2. Double-click `Start.cmd`. Choose **1** to inspect detected installations.
3. Choose **2** to repair the version list. If a version is missing, enter its full `Photoshop.exe` path; otherwise press Enter.
4. In Windows Settings, search for `.psd`, select your preferred Photoshop version and click **Set default**.
5. Repeat for `.psb` if needed. Switch back through the same Windows interface.

Windows 10 / 11; Windows PowerShell 5.1 or PowerShell 7. Administrator privileges are normally unnecessary. Save your work and close other Photoshop versions before testing a double-click, since a running instance may accept the document.

## Command line

```powershell
.\PhotoshopVersionSwitcher.ps1 -Mode Diagnose
.\PhotoshopVersionSwitcher.ps1 -Mode Repair
.\PhotoshopVersionSwitcher.ps1 -Mode Repair -PhotoshopPath 'D:\Adobe\Photoshop 2025\Photoshop.exe'
.\PhotoshopVersionSwitcher.ps1 -Mode Repair -OnlySpecifiedPaths -PhotoshopPath 'D:\Adobe\Photoshop 2025\Photoshop.exe'
.\PhotoshopVersionSwitcher.ps1 -Mode Repair -NoSettings
.\PhotoshopVersionSwitcher.ps1 -Mode Restore -BackupPath 'C:\path\to\backup.json'
```

`-OnlySpecifiedPaths` limits discovery and registration for that run; it does not unregister other versions. `-KeepLegacyHistory` preserves ambiguous `Photoshop.exe` history if desired.

## Changes and rollback

The tool discovers Photoshop from installed-app records, Adobe registry records, common Adobe folders and explicitly supplied paths. It verifies executable metadata and reuses native version-specific Adobe handlers only when their commands point at the detected installation. Otherwise, it creates path-specific handlers. It registers separate application names, capabilities and PSD/PSB `OpenWithProgids` entries.

It removes only ambiguous `Photoshop.exe` entries from PSD/PSB legacy open history, preserving other apps and maintaining MRU ordering. That change is also backed up.

Backups are written **before** changes to `%LOCALAPPDATA%\PhotoshopVersionSwitcher\backups`. Restore reverts values only while they still match this repair's output; later edits are preserved and reported as conflicts. If a newly created handler is now selected as the default, first choose another valid default in Windows Settings before restoring its registration.

The scope is per-user registration and related PSD/PSB history. Existing Windows default choices are preserved. The utility does not calculate UserChoice hashes, change registry permissions, rewrite machine-wide App Paths, rename/uninstall Photoshop, or read/save PSD documents. It works offline without additional modules, telemetry or a resident process.

The registration design follows Microsoft's [OpenWithProgIDs documentation](https://learn.microsoft.com/en-us/windows/win32/shell/how-to-include-an-application-on-the-open-with-dialog-box). Default selection uses the [Windows app defaults platform](https://learn.microsoft.com/en-us/windows/apps/develop/windows-integration/default-apps-platform).

## Advanced: desktop-context diagnosis

The original incident showed different association results in the command environment and an independent desktop process. This is an observation from that incident, not a claim about every Windows or Codex environment. Prefer launching `Start.cmd` from File Explorer. To compare or operate from an independent local desktop process:

```powershell
.\PhotoshopVersionSwitcher.ps1 -Mode Diagnose -DesktopContext
.\PhotoshopVersionSwitcher.ps1 -Mode Repair -DesktopContext
.\PhotoshopVersionSwitcher.ps1 -Mode Restore -DesktopContext -BackupPath 'C:\path\to\backup.json'
```

This uses a temporary Windows PowerShell process through local WMI/CIM and waits for its JSON result. Exchange files are retained in the gitignored `.desktop-requests` directory beside the script, so extract the tool into a writable folder. Organizational policy may block this feature. It does not elevate privileges, terminate Photoshop or restart Explorer.

## Verification and limitations

The original repair method was manually verified on Windows 11 with Photoshop 2023 and 2025: both versions appeared in the picker, and an Explorer double-click launched 2023 after all Photoshop instances were closed.

The reusable project has isolated registry tests for separate handlers, relocated paths, native handler reuse, default preservation, idempotence, type-preserving rollback, later-edit conflicts and scope validation. The reusable tool also detected both installed versions and successfully applied and restored 27 registration changes on the original machine, preserving its default choice. All 10 behavioral tests passed locally under PowerShell 5.1 and 7. GitHub Actions runs the tests under both shells. CI does not install Adobe software or equate registry tests with a real Photoshop launch.

```powershell
.\tests\Run-Tests.ps1
```

Tests use a unique `HKCU\Software\PhotoshopVersionSwitcherTests` subtree and temporary directory, separate from live associations. Other Photoshop versions need additional real-world feedback. This utility is not a fix for corrupt files, Photoshop launch failures, plugins or enforced organization policies.

Backups and diagnostic output contain local installation paths. Redact usernames and personal paths before sharing an issue; do not upload complete backups automatically.

MIT licensed. Unaffiliated with Adobe. No Adobe binaries or third-party UserChoice-hash scripts are included.
