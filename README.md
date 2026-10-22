# Photoshop Version Switcher

**让 Windows 的“打开方式”同时显示 Photoshop 的不同版本，再自由选择 PSD / PSB 的默认打开版本。**

[English](README.en.md) · [下载 ZIP](https://github.com/uncleda6/photoshop-version-switcher/archive/refs/heads/main.zip) · [报告问题](https://github.com/uncleda6/photoshop-version-switcher/issues)

适用于这些情况：

- 安装了 PS2023 和 PS2025，双击 PSD 却总进入另一个版本。
- “选择默认应用”里找不到旧版 Photoshop。
- 选择旧版 `Photoshop.exe` 后仍显示新版，或列表中出现两个同名 Photoshop。

工具会检测安装路径，为各版本补齐独立的应用名称、PSD / PSB 候选项和 Windows 默认应用注册。**默认版本由你在 Windows 设置里选择。**

## 快速使用

1. 下载 ZIP 并**完整解压**。
2. 双击 `Start.cmd`，选择 `1` 检查检测结果。
3. 选择 `2` 修复。漏检某个版本时，输入它的 `Photoshop.exe` 完整路径；通常直接回车即可。
4. 在自动打开的 Windows 设置中搜索 `.psd`，选择需要的 Photoshop 版本，再点击“设置默认值”。
5. `.psb` 需要单独选择一次。切换回来时，重新在同一界面选择另一个版本即可。

正常情况下不需要管理员权限。支持 Windows 10 / 11，使用系统自带 Windows PowerShell 5.1；也兼容 PowerShell 7。

如果另一个 Photoshop 版本正在运行，先保存工作并退出它，再验证双击。判断修复是否成功，应同时检查**列表里的版本名称和实际打开文件的版本**。

## 使用示意

```text
为 .psd 文件选择默认应用

  Adobe Photoshop 2023
  Adobe Photoshop 2025

                       [设置默认值]
```

具体排列由 Windows 决定。可能一个版本位于“默认应用”，另一个位于“建议的应用”。

## 命令行

```powershell
# 只检测；不会修改关联，也不会启动 Photoshop
.\PhotoshopVersionSwitcher.ps1 -Mode Diagnose

# 修复候选列表，并打开 Windows 默认应用设置
.\PhotoshopVersionSwitcher.ps1 -Mode Repair

# 补充安装在其他盘符的版本（下面是示例路径）
.\PhotoshopVersionSwitcher.ps1 -Mode Repair -PhotoshopPath 'D:\Adobe\Photoshop 2025\Photoshop.exe'

# 仅注册明确指定的版本，不自动检测其他安装
.\PhotoshopVersionSwitcher.ps1 -Mode Repair -OnlySpecifiedPaths -PhotoshopPath 'D:\Adobe\Photoshop 2025\Photoshop.exe'

# 修复后暂不打开设置
.\PhotoshopVersionSwitcher.ps1 -Mode Repair -NoSettings

# 保留旧的 Photoshop.exe 打开历史（通常无需此参数）
.\PhotoshopVersionSwitcher.ps1 -Mode Repair -KeepLegacyHistory
```

`-OnlySpecifiedPaths` 只限制本次检测和注册范围；不会注销其他版本。

## 备份和恢复

修复在写入前自动创建 JSON 备份，结果中会显示完整路径。默认保存到：

```text
%LOCALAPPDATA%\PhotoshopVersionSwitcher\backups
```

```powershell
.\PhotoshopVersionSwitcher.ps1 -Mode Restore -BackupPath 'C:\path\to\backup.json'
```

- 恢复只处理该次修复改过的注册表值。
- 如果之后其他软件或用户修改了同一值，会保留新修改并报告冲突。
- 如果当前默认指向工具新建的候选项，先在 Windows 设置中改用另一个有效应用，再恢复。工具会拒绝删除正在作为默认值的新建处理程序。
- 恢复应用注册与更改 Windows 默认选择是两件事；恢复后仍可在 Windows 设置中选择版本。

备份和诊断结果可能包含本机用户名、安装路径。提交 Issue 时请只贴必要字段并遮盖个人信息，不要直接上传完整备份。

## 为什么不是简单改一个 Photoshop.exe 路径？

多个版本的主程序都叫 `Photoshop.exe`。共享的程序名和旧打开历史，可能让 Windows 只展示一个版本。本工具优先复用已验证指向正确安装路径的 Adobe 版本专用 ProgID；缺失时创建与安装路径绑定的独立处理程序，并注册每个版本的名称和能力。

清理重复项时，只移除 `.psd` / `.psb` 打开历史中含糊的 `Photoshop.exe` 记录，同时更新其 MRU 顺序；其他应用的历史保留。每项改动均纳入备份。

注册机制依据 Microsoft 的 [OpenWithProgIDs 文档](https://learn.microsoft.com/en-us/windows/win32/shell/how-to-include-an-application-on-the-open-with-dialog-box)；默认应用由 [Windows 默认应用界面](https://learn.microsoft.com/en-us/windows/apps/develop/windows-integration/default-apps-platform)确认。

## 工具的修改范围

修改仅限当前用户的 Photoshop 应用注册、PSD / PSB 候选项、相关旧打开历史及工具自己的能力注册。它保留已有默认选择，不写 `UserChoice` 哈希，不改注册表权限，不改系统级 App Paths，不卸载或重命名 Photoshop，也不读取或保存你的 PSD 内容。

工具离线工作，无额外下载、遥测、后台常驻或外部 PowerShell 模块。

## 高级：命令行检测与桌面显示不同

原始故障排查曾遇到：工具进程读到 2023，桌面进程和 Windows 界面却仍使用 2025。**不能据此断言所有 Windows 或 Codex 环境都会如此。**

优先从文件资源管理器双击 `Start.cmd` 运行。需要比较独立桌面进程的结果时：

```powershell
.\PhotoshopVersionSwitcher.ps1 -Mode Diagnose -DesktopContext
.\PhotoshopVersionSwitcher.ps1 -Mode Repair -DesktopContext
.\PhotoshopVersionSwitcher.ps1 -Mode Restore -DesktopContext -BackupPath 'C:\path\to\backup.json'
```

此选项通过本地 WMI/CIM 启动一个临时 Windows PowerShell 进程，并等待 JSON 结果；组织策略可能阻止此功能。交换文件保存在脚本旁边的 `.desktop-requests` 文件夹（已加入 `.gitignore`），因此应把工具解压到可写文件夹。它不提升权限，也不自动终止 Photoshop 或重启资源管理器。

## 验证状态与限制

- 原始修复方法在 Windows 11、Photoshop 2023 / 2025 共存环境中，验证过两个版本同时出现在选择列表，以及关闭 Photoshop 后从资源管理器双击真实 PSD 打开 2023。
- 本项目提供隔离注册表测试，覆盖独立处理程序、非系统盘和空格路径、原有 Adobe 处理程序复用、默认值保留、重复执行、恢复、并发修改冲突及备份范围校验。
- 可复用工具在同机实际检测到 2023 / 2025，并完成一次 27 项注册改动的写入与完整恢复；恢复后原有默认选择保持不变。PowerShell 5.1、7 均通过 10 项行为测试。
- GitHub Actions 在 Windows 上运行 PowerShell 5.1 / 7 两组测试。CI 不包含 Adobe 商业软件，也不把注册表测试当作 Photoshop 实际启动验证。
- 不保证解决 Photoshop 自身启动失败、文件损坏、插件问题或组织策略强制的默认应用设置。其他 Photoshop 版本需要更多实际反馈。

运行测试：

```powershell
.\tests\Run-Tests.ps1
```

测试只在随机命名的 `HKCU\Software\PhotoshopVersionSwitcherTests` 子键及临时文件夹中创建和清理夹具，独立于真实文件关联。

## 反馈

请提供 Windows 版本、Photoshop 版本、列表中显示的名字、修复前后实际打开的版本，以及是否使用 `-DesktopContext`。分享命令行检测结果前请遮盖用户名和个人路径。

MIT 许可证。社区工具，与 Adobe 无隶属关系。未捆绑 Adobe 软件或第三方默认关联哈希脚本。
