# 依赖：PowerShell 7（或 5.1）、grok.exe（Grok CLI，已登录）
$ErrorActionPreference = 'Stop'
$utf8 = [System.Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8

# Read the message block explicitly because PowerShell 5.1 parses BOM-less source as ANSI.
$source = [System.IO.File]::ReadAllText($PSCommandPath, $utf8)
$sections = $source.Replace("`r`n", "`n") -split '(?m)^@@(\w+)\r?$'
$messages = @{}
for ($i = 1; $i -lt ($sections.Count - 2); $i += 2) {
    $messages[$sections[$i]] = $sections[$i + 1].Trim()
}

function Stop-Ask([string]$Message) {
    [Console]::Error.WriteLine("grok-ask: $Message")
    exit 2
}

function Invoke-Grok([string]$Prompt) {
    $arguments = @('-p', $Prompt, '--permission-mode', 'plan', '--disable-web-search',
        '-m', $model, '--reasoning-effort', $effort)
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $grok
    $startInfo.WorkingDirectory = $dir
    # PowerShell 5.1 lacks ArgumentList. Quote arguments using the Windows native rules.
    $startInfo.Arguments = ($arguments | ForEach-Object {
        '"' + ($_ -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
    }) -join ' '
    $startInfo.UseShellExecute = $false
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $startInfo.StandardOutputEncoding = $utf8
    $startInfo.StandardErrorEncoding = $utf8
    $process = [System.Diagnostics.Process]::Start($startInfo)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        @{
            Answer = (@($stdout.GetAwaiter().GetResult(), $stderr.GetAwaiter().GetResult()) |
                Where-Object { $_ } | ForEach-Object { $_.TrimEnd([char[]]"`r`n") }) -join "`n"
            ExitCode = $process.ExitCode
        }
    } finally {
        $process.Dispose()
    }
}

if ($args.Count -gt 0 -and $args[0] -cin '-h', '--help') {
    Write-Output $messages.Help
    exit 0
}
if ($args.Count -lt 2) { Stop-Ask ($messages.Help -split '\r?\n')[0] }
$requestedDir = $args[0]
if ([string]::IsNullOrWhiteSpace($requestedDir)) { Stop-Ask ($messages.BadDirectory -f $requestedDir) }
$directory = Get-Item -LiteralPath $requestedDir -Force -ErrorAction SilentlyContinue
if (-not ($directory -is [System.IO.DirectoryInfo])) { Stop-Ask ($messages.BadDirectory -f $requestedDir) }
$dir = $directory.FullName
$task = $args[1..($args.Count - 1)] -join ' '
if ([string]::IsNullOrWhiteSpace($task)) { Stop-Ask $messages.EmptyTask }

$grok = (Get-Command grok.exe -CommandType Application -TotalCount 1 -ErrorAction SilentlyContinue).Path
if (-not $grok) { Stop-Ask $messages.MissingCli }
$model = $env:GROK_ASK_MODEL
if (-not $model) { $model = 'grok-4.7' }
$effort = $env:GROK_ASK_EFFORT
if (-not $effort) { $effort = 'xhigh' }

$prompt = $messages.Prompt -f $task
$base = Join-Path $env:USERPROFILE '.cache\agent-dispatch'
[void][System.IO.Directory]::CreateDirectory($base)
$stamp = '{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmssfff'), $PID
$out = Join-Path $base "grok-$stamp.md"
$result = Invoke-Grok $prompt
$answer = $result.Answer
if ($answer -cmatch 'headless run cannot ask for approval' -and $answer -cnotmatch $messages.DecisionPattern) {
    $result = Invoke-Grok "$prompt`n`n$($messages.RetryPrompt)"
    $answer = "$($messages.RetryNote)`n$($result.Answer)"
}

$header = $messages.Header -f $dir, $model, $effort, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $task
[System.IO.File]::WriteAllText($out, "$header`n$answer`n", $utf8)
Write-Output $answer
Write-Output ''
Write-Output ($messages.Saved -f $result.ExitCode, $out)
exit $result.ExitCode

<#
@@Help
用法：grok-ask <目录> <合并后的方案...>
只在三类场合用：硬件通信或烧录、可能丢数据或泄露凭据、高风险的用户承诺。
只读：--permission-mode plan，禁用联网搜索。
输出：%USERPROFILE%\.cache\agent-dispatch\grok-<时间>.md
环境变量：GROK_ASK_MODEL（默认 grok-4.7）、GROK_ASK_EFFORT（默认 xhigh）。
@@BadDirectory
目录不存在：{0}
@@EmptyTask
任务内容为空
@@MissingCli
找不到 grok.exe，请检查 PATH。
@@DecisionPattern
推翻|没找到
@@RetryPrompt
注意：你上次尝试运行命令，被系统拒绝，整轮作废。这次只读文件、不运行任何命令，直接给出最多三条意见。
@@RetryNote
（第一次尝试运行命令被拒，已带提示重跑一次）
@@Header
# grok-ask
- 目录：{0}
- 模型：{1}（effort={2}）
- 时间：{3}

## 方案
{4}

## 反方意见
@@Saved
[grok-ask] 退出码 {0}，结果已存：{1}
@@Prompt
你是只读反方审稿人。只读：不修改、创建、删除任何文件，不安装、不提交、不发消息。
不读取路径以 99_ 开头或含「AI不读」的目录，不读取 secrets/ 或 age 私钥。不在回答和日志里输出任何密钥、令牌、cookie、密码。
下面是一份已经合并好的方案。你的唯一任务是找它会在哪里出错，不要另写一份方案，不要夸。
用中文，最多列三条，每条只写三行：
1. 会在哪错（具体到哪一步、什么条件下）
2. 能推翻它的最便宜的实验（怎么做、看什么结果）
3. 这个实验值不值得做（一句话）
没亲自核实的判断标「（推测）」。找不到站得住的问题就直接说「没找到」。
只读文件，不要运行任何命令或脚本（包括 codex-worker 等）；需要实测才能确认的，把它写成第 2 行的「推翻实验」，由主控去跑。

---
方案：
{0}
@@End
#>
