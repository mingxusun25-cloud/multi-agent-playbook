# run-dreaming.ps1：跑一次夜间整理，让 Codex 读 ops/dreaming.md 并照做。
# 依赖：PowerShell 7（或 5.1）、git、codex（Codex CLI，已登录）；记忆库已推到一个私有远端。
# 用法：
#   .\ops\run-dreaming.ps1                      立即跑一次
#   .\ops\run-dreaming.ps1 -DryRun              只打印将执行的命令
#   .\ops\run-dreaming.ps1 -Register [-At 23:30] 注册 Windows 计划任务，每天定时跑
# 环境变量：CODEX_BIN（codex 可执行文件路径，默认从 PATH 找）、DREAMING_MODEL（默认用 config.toml 的模型）。
param([switch]$DryRun, [switch]$Register, [string]$At = '23:30')

$ErrorActionPreference = 'Stop'
$utf8 = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8

$repo = Split-Path -Parent $PSScriptRoot
$taskName = 'agent-memory-dreaming'

if ($Register) {
    $shell = Get-Command pwsh.exe -ErrorAction SilentlyContinue
    if (-not $shell) { $shell = Get-Command powershell.exe }
    $argument = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f $PSCommandPath
    if ($DryRun) {
        Write-Output "[DryRun] 注册计划任务 ${taskName}：每天 $At 运行 $($shell.Source) $argument"
        exit 0
    }
    $action = New-ScheduledTaskAction -Execute $shell.Source -Argument $argument -WorkingDirectory $repo
    $trigger = New-ScheduledTaskTrigger -Daily -At $At
    $settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 2)
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Settings $settings `
        -Description '记忆库夜间整理（ops/run-dreaming.ps1）' -Force | Out-Null
    Write-Output "已注册计划任务 ${taskName}：每天 $At。只在你登录时运行；要锁屏也跑，在「任务计划程序」里改成「不管用户是否登录都要运行」。"
    exit 0
}

$codex = if ($env:CODEX_BIN) { $env:CODEX_BIN } else {
    $found = Get-Command codex -ErrorAction SilentlyContinue
    if ($found) {
        $found.Source
    } elseif ($DryRun) {
        'codex'
    } else {
        [Console]::Error.WriteLine('run-dreaming: 找不到 codex，请装 Codex CLI 或设置 CODEX_BIN')
        exit 2
    }
}
$today = Get-Date -Format 'yyyy-MM-dd'
$prompt = "今天是 $today。读本仓库的 ops/dreaming.md，严格按它完成今晚的夜间整理，最后输出运行报告的路径。"

# 夜间整理要写 .git、推送远端、读 %USERPROFILE% 下各工具的会话记录，所以不开沙箱。
# 它能做什么由 ops/dreaming.md 约束；ops/hooks/pre-commit 兜底拦明文密钥。
$codexArgs = @('exec', '--skip-git-repo-check', '-s', 'danger-full-access', '-C', $repo,
    '-c', 'approval_policy=never')
if ($env:DREAMING_MODEL) { $codexArgs += @('-m', $env:DREAMING_MODEL) }
$codexArgs += '-'

$logDir = Join-Path $env:LOCALAPPDATA 'agent-memory-dreaming'
$log = Join-Path $logDir ('dream-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

if ($DryRun) {
    Write-Output "[DryRun] 仓库：$repo"
    Write-Output "[DryRun] 提交者：dreaming-bot"
    Write-Output "[DryRun] 命令：$codex $($codexArgs -join ' ')"
    Write-Output "[DryRun] 提示词：$prompt"
    Write-Output "[DryRun] 日志：$log"
    exit 0
}

[void][System.IO.Directory]::CreateDirectory($logDir)
& git -C $repo config core.hooksPath ops/hooks
# 夜间提交统一记在 dreaming-bot 名下，dreaming.md 靠它区分哪些是用户的手动改动。
$env:GIT_AUTHOR_NAME = $env:GIT_COMMITTER_NAME = 'dreaming-bot'
$env:GIT_AUTHOR_EMAIL = $env:GIT_COMMITTER_EMAIL = 'dreaming-bot@localhost'

$prompt | & $codex @codexArgs 2>&1 | ForEach-Object { "$_" } | Out-File -FilePath $log -Encoding utf8
$rc = $LASTEXITCODE
Get-Content -LiteralPath $log -Tail 30 -Encoding utf8
Write-Output ''
Write-Output "[run-dreaming] 退出码 $rc，日志：$log"
exit $rc
