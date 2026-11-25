# 依赖：PowerShell 7（或 5.1）、python 3；装 Codex、Claude Code、Antigravity 中的哪几个就同步哪几个的规则
param([switch]$DryRun)

$ErrorActionPreference = 'Stop'
$utf8 = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8

# Read the message block explicitly because PowerShell 5.1 parses BOM-less source as ANSI.
$source = [System.IO.File]::ReadAllText($PSCommandPath, $utf8)
$messageText = [regex]::Match($source, '(?ms)^@@Messages\r?\n(.*?)\r?\n#>').Groups[1].Value
$messages = ConvertFrom-StringData $messageText

function Backup-File([string]$Target) {
    $time = Get-Date
    do {
        $backup = '{0}.bak-{1:yyyyMMdd-HHmmss}' -f $Target, $time
        $time = $time.AddSeconds(1)
    } while (Test-Path -LiteralPath $backup)

    if ($DryRun) {
        Write-Output ($messages.DryBackup -f $Target, $backup)
    } else {
        [System.IO.File]::Copy($Target, $backup)
        Write-Output ($messages.BackedUp -f $backup)
    }
}

$bin = Join-Path $env:USERPROFILE '.local\bin'
$claude = Join-Path $env:USERPROFILE '.claude'
$files = @(
    @{ Source = 'rules\AGENTS.md'; Target = Join-Path $env:USERPROFILE '.codex\AGENTS.md' }
    @{ Source = 'rules\AGENTS.md'; Target = Join-Path $env:USERPROFILE '.gemini\config\AGENTS.md' }
    @{ Source = 'rules\GEMINI.md'; Target = Join-Path $env:USERPROFILE '.gemini\GEMINI.md' }
    @{ Source = 'rules\CLAUDE.md'; Target = Join-Path $claude 'CLAUDE.md' }
)
foreach ($name in 'codex-worker.ps1', 'codex-worker.cmd', 'secret.ps1', 'secret.cmd',
    'agy-ask.ps1', 'agy-ask.cmd', 'grok-ask.ps1', 'grok-ask.cmd',
    'claude-bg-guard.py', 'claude-bg-guard.cmd', 'claude-secret-guard.py', 'claude-secret-guard.cmd') {
    $files += @{ Source = "bin\$name"; Target = Join-Path $bin $name }
}

foreach ($file in $files) {
    $source = Join-Path $PSScriptRoot $file.Source
    $target = $file.Target
    if ([System.IO.File]::Exists($target)) {
        $sourceHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
        $targetHash = (Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash
        if ($sourceHash -eq $targetHash) {
            Write-Output ($messages.UpToDate -f $target)
            continue
        }
        Backup-File $target
    }

    if ($DryRun) {
        Write-Output ($messages.DrySync -f $source, $target)
    } else {
        [void][System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($target))
        [System.IO.File]::Copy($source, $target, $true)
        Write-Output ($messages.Synced -f $target)
    }
}

$settingsPath = Join-Path $claude 'settings.json'
# Use the standard-library JSON parser to preserve existing fields beyond PowerShell's serialization depth.
$mergeHooks = @'
import json
import re
import sys
from pathlib import Path

path, bindir = map(Path, sys.argv[1:])
data = json.loads(path.read_text(encoding="utf-8-sig")) if path.exists() else {}
groups = data.setdefault("hooks", {}).setdefault("PreToolUse", [])
if not isinstance(groups, list):
    raise ValueError("hooks.PreToolUse must be an array")

def matches(group, tool):
    matcher = group.get("matcher")
    if not matcher or matcher == "*":
        return True
    try:
        return re.fullmatch(matcher, tool) is not None
    except re.error:
        return False

changed = False
for name, tool in (("claude-bg-guard.cmd", "Bash"),
                   ("claude-bg-guard.cmd", "PowerShell"),
                   ("claude-secret-guard.cmd", "Bash"),
                   ("claude-secret-guard.cmd", "PowerShell"),
                   ("claude-secret-guard.cmd", "Read")):
    quoted_path = str(bindir / name).replace("'", "''")
    command = "& '" + quoted_path + "'; exit $LASTEXITCODE"
    if any(matches(group, tool) and any(
            hook.get("type") == "command" and hook.get("command") == command
            for hook in group.get("hooks", [])
    ) for group in groups):
        continue
    groups.append({"matcher": tool, "hooks": [
        {"type": "command", "shell": "powershell", "command": command}
    ]})
    changed = True

if changed:
    print(json.dumps(data, ensure_ascii=False, indent=2))
'@
$merged = $mergeHooks | & python.exe -I -X utf8 - $settingsPath $bin
if ($LASTEXITCODE -ne 0) { throw ($messages.HookError -f $settingsPath) }
if (-not $merged) {
    Write-Output ($messages.HooksCurrent -f $settingsPath)
} else {
    $hasSettings = [System.IO.File]::Exists($settingsPath)
    if ($hasSettings) { Backup-File $settingsPath }
    if ($DryRun) {
        Write-Output ($messages.DryHooks -f $settingsPath)
    } else {
        $temporaryPath = Join-Path $claude ([System.IO.Path]::GetRandomFileName())
        try {
            [System.IO.File]::WriteAllText($temporaryPath, (($merged -join "`n") + "`n"), $utf8)
            if ($hasSettings) {
                [System.IO.File]::Replace($temporaryPath, $settingsPath, [NullString]::Value)
            } else {
                [System.IO.File]::Move($temporaryPath, $settingsPath)
            }
        } finally {
            [System.IO.File]::Delete($temporaryPath)
        }
        Write-Output ($messages.HooksInstalled -f $settingsPath)
    }
}

$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
$pathEntries = $userPath -split ';' | ForEach-Object {
    [Environment]::ExpandEnvironmentVariables($_.Trim().Trim('"')).TrimEnd('\', '/')
}
if ($bin -notin $pathEntries) {
    Write-Output ($messages.PathNotice -f $bin)
}

<#
@@Messages
DryBackup = [DryRun] 备份 {0} -> {1}
BackedUp = 已备份：{0}
UpToDate = 已是最新：{0}
DrySync = [DryRun] 同步 {0} -> {1}
Synced = 已同步：{0}
HookError = 无法读取或合并 Claude Code 钩子：{0}
HooksCurrent = 钩子已挂过：{0}
DryHooks = [DryRun] 挂接 Claude Code 钩子：{0}
HooksInstalled = 已挂 Claude Code 钩子：{0}
PathNotice = 用户 PATH 未包含 {0}。请将它加入用户 PATH，然后重新打开终端。
#>
