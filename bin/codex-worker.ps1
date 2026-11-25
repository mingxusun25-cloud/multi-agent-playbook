# 依赖：PowerShell 7（或 5.1）、git、codex（Codex CLI，已登录）
$ErrorActionPreference = 'Stop'
$utf8 = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8

function Stop-Worker([string]$Message) {
    [Console]::Error.WriteLine("codex-worker: $Message")
    exit 2
}

function Find-Codex {
    if ($env:CODEX_WORKER_BIN -and (Test-Path -LiteralPath $env:CODEX_WORKER_BIN -PathType Leaf)) {
        $override = Get-Item -LiteralPath $env:CODEX_WORKER_BIN -Force
        if ($override.BaseName -ne 'codex-worker') { return $override.FullName }
    }

    $command = Get-Command codex.exe -CommandType Application -ErrorAction SilentlyContinue
    if ($command) { return $command.Path }

    $packages = if (Get-Command Get-AppxPackage -ErrorAction SilentlyContinue) {
        Get-AppxPackage -Name 'OpenAI.Codex' -ErrorAction SilentlyContinue
    }
    foreach ($package in $packages) {
        $candidate = Join-Path $package.InstallLocation 'app\resources\codex.exe'
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }

    foreach ($suffix in '.codex\plugins\.plugin-appserver\codex.exe', '.codex\.sandbox-bin\codex.exe') {
        $candidate = Join-Path $env:USERPROFILE $suffix
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
    }
    Stop-Worker '找不到 codex.exe，请检查 PATH、OpenAI.Codex 应用，或设置 CODEX_WORKER_BIN。'
}

$usage = 'codex-worker [--code|--review|--net] [--resume <会话ID>] <目录> <任务...>'
$lane = ''
$resume = ''
$index = 0
:options while ($index -lt $args.Count) {
    $option = $args[$index]
    $index++
    switch -CaseSensitive -Regex ($option) {
        '^(-h|--help)$' {
            Write-Output @"
用法：$usage
  --code     写代码（默认），目录必须是 git 工作树；可在本机跑测试。
  --review   只读审查，不改文件，不联网。
  --net      联网调研，只在新的临时目录里写入；<目录> 用作参考。
  --resume   续跑已有会话，档位和目录必须与首次一致。
环境变量：CODEX_WORKER_BIN、CODEX_WORKER_MODEL、CODEX_WORKER_EFFORT（默认 high）。
"@
            exit 0
        }
        '^--(code|review|net)$' {
            $selectedLane = $Matches[1]
            if ($lane -and $lane -cne $selectedLane) {
                Stop-Worker "只能选一个档位（已选 ${lane}，又给了 $selectedLane）"
            }
            $lane = $selectedLane
            break
        }
        '^--resume$' {
            if ($index -ge $args.Count -or -not $args[$index] -or $args[$index] -like '--*') {
                Stop-Worker '--resume 后面缺少参数值'
            }
            $resume = $args[$index]
            $index++
            break
        }
        '^--$' { break options }
        '^-' { Stop-Worker "未知参数 $option" }
        default { $index--; break options }
    }
}

if (-not $lane) { $lane = 'code' }
if ($args.Count - $index -lt 2) { Stop-Worker "用法：$usage" }
$requestedDir = $args[$index]
if ([string]::IsNullOrWhiteSpace($requestedDir)) { Stop-Worker '目录不能为空' }
$directory = Get-Item -LiteralPath $requestedDir -Force -ErrorAction SilentlyContinue
if (-not ($directory -is [System.IO.DirectoryInfo])) { Stop-Worker "目录不存在：$requestedDir" }
$dir = $directory.FullName
$task = $args[($index + 1)..($args.Count - 1)] -join ' '
if ([string]::IsNullOrWhiteSpace($task)) { Stop-Worker '任务内容为空' }

if ($lane -eq 'code') {
    try { $insideWorkTree = & git.exe -C $dir rev-parse --is-inside-work-tree 2>$null }
    catch { $insideWorkTree = $null }
    if ($insideWorkTree -cne 'true' -or $LASTEXITCODE -ne 0) {
        Stop-Worker "--code 要求 <目录> 是 git 工作树，方便主控读 diff：$dir"
    }
}

$base = Join-Path $env:USERPROFILE '.cache\agent-dispatch'
$sessions = Join-Path $base 'sessions'
$sessionIdPattern = '^[A-Za-z0-9._-]+\z'

if ($resume) {
    if ($resume -cnotmatch $sessionIdPattern) { Stop-Worker "会话 ID 格式不对：$resume" }
    $metadata = Join-Path $sessions $resume
    if (-not (Test-Path -LiteralPath $metadata -PathType Leaf)) {
        Stop-Worker "找不到会话 $resume 的记录（只能续跑由 codex-worker 发起的会话）"
    }
    $records = [System.IO.File]::ReadAllLines($metadata, $utf8)
    $oldLane = @(($records -clike 'lane=*') -creplace '^lane=', '')
    $oldDir = @(($records -clike 'dir=*') -creplace '^dir=', '')
    if ($oldLane.Count -ne 1 -or $oldLane[0] -cne $lane) {
        Stop-Worker "会话 $resume 是 $oldLane 档，这次给的是 $lane 档。换档请开新会话"
    }
    if ($oldDir.Count -ne 1 -or -not [StringComparer]::OrdinalIgnoreCase.Equals($oldDir[0], $dir)) {
        Stop-Worker "会话 $resume 绑定的目录是 ${oldDir}，这次给的是 $dir"
    }
}

$codex = Find-Codex
[void][System.IO.Directory]::CreateDirectory($sessions)
$stamp = '{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmssfff'), $PID
$prefix = Join-Path $base "codex-$stamp"
$out = "$prefix.md"
$log = "$prefix.log"
$promptFile = "$prefix.prompt"
$workdir = $dir
$extraConfig = @()

$commonRules = @'
- 不提交、不推送、不切分支、不改 git 配置。
- 不在回执和输出里写出密钥、令牌、cookie、密码。
- 中文回执，按这个结构：
  1. 做了什么（改了哪些文件 / 查了哪些地方，各一句话）
  2. 证据：命令和结果原样贴出；跑不了的说明原因
  3. 没做完、没把握、需要主控决定的事
'@

switch ($lane) {
    'code' {
        $sandbox = 'danger-full-access'
        $rules = @'
你是执行者，由主控派活（写代码档，没有沙箱，规矩靠你自己守）。规则：
- 只修改当前目录（工作树）里的文件；目录外的东西只读，临时文件放系统临时目录。
- 可以直接在本机跑测试，可以联网查文档。
- 新写工具、模块或做性能优化前，先查 GitHub 和包管理器有没有成熟的现成方案；回执里写搜了什么、用或不用的理由。
- 不提交、不推送、不切分支，不安装全局软件，不烧录固件，不发消息，不删目录外的文件，不读 age 私钥、不直接解密密文；要用 API Key 只走 secret run <名字> -- <命令>，缺 Key 写进回执。需要这些就停下，写进回执。
- 遵守仓库里的 AGENTS.md。只做任务要求的，不顺手加功能。能跑的测试自己跑。
'@
    }
    'review' {
        $sandbox = 'danger-full-access'
        $rules = @'
你是审查者，由主控派活（只读档，Windows 上未开沙箱，规矩靠你自己守）。规则：
- 只读：不修改、创建、删除任何文件，不安装、不联网。
- 每条发现写清怎么触发、后果、建议改法，按严重程度排序；能复现的贴出复现命令和输出。
'@
    }
    'net' {
        $sandbox = 'danger-full-access'
        $workdir = Join-Path $base "net-$stamp"
        [void][System.IO.Directory]::CreateDirectory($workdir)
        $rules = @"
你是调研员，由主控派活（联网档，Windows 上未开沙箱，规矩靠你自己守）。规则：
- 可以联网搜索和读网页。可写的只有当前临时目录，截图、下载的材料放这里。
- 不要用 Computer Use 操作桌面，不登录任何账号，不在网页上提交表单、发消息、下单。
- 参考位置（只读）：$dir
- 结论附来源链接；没找到可靠来源的写「没查到」，不要编。
"@
    }
}

$effort = $env:CODEX_WORKER_EFFORT
if (-not $effort) { $effort = 'high' }
$config = @('-c', ('sandbox_mode="{0}"' -f $sandbox), '-c', 'approval_policy="never"',
    '-c', ('model_reasoning_effort="{0}"' -f $effort)) + $extraConfig
if ($env:CODEX_WORKER_MODEL) { $config += @('-m', $env:CODEX_WORKER_MODEL) }

if ($resume) {
    $prompt = "（续跑，仍是 $lane 档，规则重申如下。）`n$rules`n$commonRules`n`n---`n追加指令：`n$task`n"
    # resume 子命令从进程工作目录启动，并通过配置读取 sandbox_mode。
    $arguments = @('exec', 'resume', '--skip-git-repo-check') + $config + @('-o', $out, '--', $resume, '-')
} else {
    $prompt = "$rules`n$commonRules`n`n---`n任务：`n$task`n"
    $arguments = @('exec', '--skip-git-repo-check', '-s', $sandbox, '-C', $workdir) + $config + @('-o', $out, '-')
}

$startInfo = [System.Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = $codex
$startInfo.WorkingDirectory = $workdir
# Windows PowerShell 5.1 没有 ArgumentList，按 Windows 原生参数规则保留配置里的双引号。
$startInfo.Arguments = ($arguments | ForEach-Object {
    '"' + ($_ -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}) -join ' '
$startInfo.UseShellExecute = $false
$startInfo.RedirectStandardInput = $true
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true
$startInfo.StandardOutputEncoding = $utf8
$startInfo.StandardErrorEncoding = $utf8

[System.IO.File]::WriteAllText($promptFile, $prompt, $utf8)
$process = [System.Diagnostics.Process]::new()
$process.StartInfo = $startInfo
$promptStream = [System.IO.File]::OpenRead($promptFile)
$logWriter = [System.IO.StreamWriter]::new($log, $false, $utf8)
try {
    [void]$process.Start()
    # 同时读两路输出和写入 stdin，避免 Codex 填满某一路管道时阻塞。
    $stdout = $process.StandardOutput.ReadLineAsync()
    $stderr = $process.StandardError.ReadLineAsync()
    $stdin = $promptStream.CopyToAsync($process.StandardInput.BaseStream)
    while ($stdin -or $stdout -or $stderr) {
        [System.Threading.Tasks.Task[]]$pending = @($stdin, $stderr, $stdout).Where({ $null -ne $_ })
        $ready = $pending[[System.Threading.Tasks.Task]::WaitAny($pending)]
        if ($ready -eq $stdin) {
            try { [void]$stdin.GetAwaiter().GetResult() }
            catch [System.IO.IOException] { $logWriter.WriteLine('codex-worker: Codex 提前关闭了标准输入。') }
            $process.StandardInput.BaseStream.Close()
            $stdin = $null
        } else {
            $line = $ready.GetAwaiter().GetResult()
            if ($null -ne $line) { $logWriter.WriteLine($line) }
            if ($ready -eq $stdout) {
                $stdout = $null
                if ($null -ne $line) { $stdout = $process.StandardOutput.ReadLineAsync() }
            } else {
                $stderr = $null
                if ($null -ne $line) { $stderr = $process.StandardError.ReadLineAsync() }
            }
        }
    }
    $process.WaitForExit()
    $exitCode = $process.ExitCode
} finally {
    $logWriter.Dispose()
    $promptStream.Dispose()
    $process.Dispose()
    Remove-Item -LiteralPath $promptFile
}

$sessionLine = Select-String -LiteralPath $log -Pattern '^session id:\s*(.+)$' -CaseSensitive -Encoding UTF8 |
    Select-Object -First 1
$sid = $resume
if ($sessionLine) { $sid = $sessionLine.Matches[0].Groups[1].Value.Trim() }
if ($sid -and -not $resume -and $sid -cmatch $sessionIdPattern -and $sid -notin '.', '..') {
    $metadata = Join-Path $sessions $sid
    [System.IO.File]::WriteAllText($metadata, "lane=$lane`ndir=$dir`ncreated=$stamp`n", $utf8)
}

if ((Test-Path -LiteralPath $out -PathType Leaf) -and (Get-Item -LiteralPath $out).Length -gt 0) {
    Write-Output ([System.IO.File]::ReadAllText($out, $utf8))
} else {
    Write-Output "（没有拿到最后回答，看日志：$log）"
    Get-Content -LiteralPath $log -Encoding UTF8 -Tail 20
}
if ($exitCode -ne 0) { Write-Output '[codex-worker] 注意：codex 退出码非 0' }

$resumeHint = $sid
if (-not $sid) { $sid = '未知'; $resumeHint = '<ID>' }
Write-Output ''
Write-Output "[codex-worker] 档位 $lane（沙箱 $sandbox），退出码 $exitCode"
if ($lane -eq 'net') { Write-Output "[codex-worker] 临时目录：$workdir" }
Write-Output "[codex-worker] 回执：$out"
Write-Output "[codex-worker] 日志：$log"
Write-Output "[codex-worker] 会话 ID：$sid（追加：codex-worker --resume $resumeHint --$lane <目录> `"…`"）"
exit $exitCode
