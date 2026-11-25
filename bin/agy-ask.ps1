# 依赖：PowerShell 7（或 5.1）、python 3、agy.exe（Antigravity CLI，已登录）
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
    [Console]::Error.WriteLine("agy-ask: $Message")
    exit 2
}

function Invoke-Agy([string]$Prompt) {
    $arguments = @('-p', $Prompt, '--mode', 'plan', '--sandbox', '--model', $model,
        '--settings', $settingsPath, '--print-timeout', $timeout)
    $startInfo = [System.Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $agy
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
            Answer = $stdout.GetAwaiter().GetResult()
            ErrorText = $stderr.GetAwaiter().GetResult()
            ExitCode = $process.ExitCode
        }
    } finally {
        $process.Dispose()
    }
}

$mode = 'plan'
$model = $env:AGY_ASK_MODEL
if (-not $model) { $model = 'gemini-4-neon-high' }
$index = 0
:options while ($index -lt $args.Count) {
    $option = $args[$index]
    $index++
    switch -CaseSensitive -Regex ($option) {
        '^(-h|--help)$' { Write-Output $messages.Help; exit 0 }
        '^--copy$' { $mode = 'copy'; break }
        '^--model$' {
            if ($index -ge $args.Count -or -not $args[$index] -or $args[$index] -like '--*') {
                Stop-Ask $messages.MissingModel
            }
            $model = $args[$index]
            $index++
            break
        }
        '^--$' { break options }
        '^-' { Stop-Ask ($messages.UnknownOption -f $option) }
        default { $index--; break options }
    }
}

if ($args.Count - $index -lt 2) { Stop-Ask ($messages.Help -split '\r?\n')[0] }
$requestedDir = $args[$index]
if ([string]::IsNullOrWhiteSpace($requestedDir)) { Stop-Ask ($messages.BadDirectory -f $requestedDir) }
$directory = Get-Item -LiteralPath $requestedDir -Force -ErrorAction SilentlyContinue
if (-not ($directory -is [System.IO.DirectoryInfo])) { Stop-Ask ($messages.BadDirectory -f $requestedDir) }
$dir = $directory.FullName
$task = $args[($index + 1)..($args.Count - 1)] -join ' '
if ([string]::IsNullOrWhiteSpace($task)) { Stop-Ask $messages.EmptyTask }

$agy = (Get-Command agy.exe -CommandType Application -TotalCount 1 -ErrorAction SilentlyContinue).Path
if (-not $agy) { Stop-Ask $messages.MissingCli }
$timeout = $env:AGY_ASK_TIMEOUT
if (-not $timeout) { $timeout = '20m' }

$prompt = $messages.Prompt -f $messages[$mode], $task
$readOnlyCommands = @('ls', 'dir', 'cat', 'type', 'head', 'tail', 'wc', 'grep', 'rg', 'tree', 'file', 'stat',
    'pwd', 'where', 'which', 'dirname', 'basename', 'realpath', 'readlink', 'uname', 'date',
    'git status', 'git log', 'git diff', 'git show', 'git ls-files', 'git grep', 'git blame', 'git rev-parse', 'git branch --show-current')
$allow = @("read_file($dir)") + @($readOnlyCommands | ForEach-Object { "command($_)" })
$settings = @{ permissions = @{ allow = $allow } } | ConvertTo-Json -Depth 10

$base = Join-Path $env:USERPROFILE '.cache\agent-dispatch'
[void][System.IO.Directory]::CreateDirectory($base)
$stamp = '{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmssfff'), $PID
$out = Join-Path $base "agy-$stamp.md"
$note = ''
$settingsPath = [System.IO.Path]::GetTempFileName()
try {
    [System.IO.File]::WriteAllText($settingsPath, $settings, $utf8)
    $result = Invoke-Agy $prompt
    if ($result.ErrorText -cmatch 'auto-denied' -and [string]::IsNullOrWhiteSpace($result.Answer)) {
        $note = $messages.RetryNote
        $result = Invoke-Agy "$prompt`n`n$($messages.RetryPrompt)"
    }
} finally {
    [System.IO.File]::Delete($settingsPath)
}

$answer = $result.Answer.TrimEnd([char[]]"`r`n")
$body = $answer
if ($result.ErrorText) {
    $body += "`n`n$($messages.ErrorHeading)`n$($result.ErrorText.TrimEnd([char[]]"`r`n"))"
}
$noteLine = if ($note) { "`n- $note" } else { '' }
$header = $messages.Header -f $mode, $model, $dir, (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $noteLine, $task
$rc = $result.ExitCode
try {
    [System.IO.File]::WriteAllText($out, "$header`n$body`n", $utf8)
} catch {
    [Console]::Error.WriteLine($messages.WriteError -f $out)
    $rc = 1
}

if ($note) { Write-Output $note }
Write-Output $body
if ([string]::IsNullOrWhiteSpace($answer)) {
    Write-Output $messages.NoAnswer
    if ($rc -eq 0) { $rc = 1 }
}
Write-Output ''
Write-Output ($messages.Saved -f $rc, $out)
exit $rc

<#
@@Help
用法：agy-ask [--copy] [--model <id>] <目录> <任务...>
  默认：方案模式。只给 Gemini 用户原话和必要背景，不给主控的草稿和倾向。
  --copy：文案/交互顾问模式。任务里写清页面给谁用、要让人做成什么、现在的文案和交互。
输出：%USERPROFILE%\.cache\agent-dispatch\agy-<时间>.md
环境变量：AGY_ASK_MODEL（默认 gemini-4-neon-high）、AGY_ASK_TIMEOUT（默认 20m，0 为不限）。
@@MissingModel
--model 后面缺少参数值
@@UnknownOption
未知参数 {0}
@@BadDirectory
目录不存在：{0}
@@EmptyTask
任务内容为空
@@MissingCli
找不到 agy.exe，请检查 PATH。
@@RetryNote
（第一次尝试用了没放行的工具，整轮被拒，已带提示重跑一次）
@@RetryPrompt
注意：你上次尝试执行了不在白名单里的操作，被系统拒绝，整轮作废。这次只用读文件和 ls/cat/grep/rg/git log/git diff/git show 这类只读命令；任务里要求写文件、改东西的部分直接写「不做：只读顾问」，然后完成其余部分。
@@ErrorHeading
## agy 的错误输出
@@Header
# agy-ask（{0}，{1}）
- 目录：{2}
- 时间：{3}{4}

## 任务
{5}

## 回答
@@WriteError
agy-ask: 写结果文件失败：{0}
@@NoAnswer
[agy-ask] 没有拿到回答
@@Saved
[agy-ask] 退出码 {0}，结果已存：{1}
@@Prompt
你是顾问，只读。这次以顾问身份被脚本调用：输出格式以本提示词为准，你规则文件里「主控」相关的内容这次不适用，不要建议别人去跑派活脚本。
- 不修改、创建或删除任何文件，不安装任何东西，不做提交、推送、发消息等任何写操作。可以读文件、搜代码、跑只读命令。
- 用中文回答，直接给结论，不寒暄。
- 你说的每个判断，能在代码或文件里找到依据的写出文件路径；没有亲眼核实的，在句末标「（推测）」。宁可少说，不要编。
- 不确定、信息不够的地方直接写「不确定：…」，不要补全成肯定句。

{0}

---
任务：
{1}
@@plan
请独立出一份方案，按这个结构回答：
1. 结论（三句话以内）
2. 方案要点（分条，每条写为什么）
3. 风险和代价
4. 我没把握、需要主控核实的点
@@copy
改文案时守住三条：
- 原文里的功能范围、数字、专业术语和承诺不改含义。
- 不新增原文和代码里没有的承诺或能力。
- 拿不准就保留原文，写进第 3 条「需要主控核实」。
请当界面文案和交互顾问，按这个结构回答：
1. 逐条修改：原文 → 改后 → 一句理由（写给不懂技术的使用者，短、像人话、不解释实现）
2. 交互上的问题和建议（没有就写「无」）
3. 你不确定功能实际怎么用、需要主控核实的地方
@@End
#>
