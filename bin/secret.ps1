# 依赖：PowerShell 7（或 5.1）、git、sops、age
$ErrorActionPreference = 'Stop'
$utf8 = [System.Text.UTF8Encoding]::new($false)
[Console]::InputEncoding = $utf8
[Console]::OutputEncoding = $utf8
$OutputEncoding = $utf8

# secret：用 sops + age 加密存放的 API Key。Key 只录一次，Agent 用它但看不到它。
#   secret run <名字>... -- <命令> [参数...]   只注入点名的 Key；输出里的 Key 原文替换成 [REDACTED:名字]
#   secret set <名字>                          在你自己的终端里隐藏输入，加密写回并提交（Agent 不能代跑）
#   secret list                                只列名字
#   secret verify <私钥文件>                   只用这一把私钥解一次
# 生成钥匙：age-keygen -o <文件>（一定带 -o，否则私钥会打到屏幕上）。加第二把钥匙（如离线恢复钥匙）见 memory-template/secrets/README.md。

function Stop-Secret([string]$Message) { [Console]::Error.WriteLine("secret: $Message"); exit 2 }

$file = if ($env:AGENT_SECRETS_FILE) { $env:AGENT_SECRETS_FILE } else { Join-Path $env:USERPROFILE 'agent-memory\secrets\keys.enc.env' }
$repo = Split-Path -Parent (Split-Path -Parent $file)
$nameRe = '^[A-Z][A-Z0-9_]*$'

function Invoke-OriginFetch([int]$TimeoutMs) {
    $git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $git) { return $false }

    $info = [System.Diagnostics.ProcessStartInfo]::new()
    $info.FileName = $git.Source
    $info.WorkingDirectory = $repo
    $info.Arguments = '-c credential.interactive=false fetch --quiet --prune origin'
    $info.UseShellExecute = $false
    $info.CreateNoWindow = $true
    $info.RedirectStandardInput = $true
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.EnvironmentVariables['GIT_TERMINAL_PROMPT'] = '0'
    $process = [System.Diagnostics.Process]::new()
    $process.StartInfo = $info
    try {
        [void]$process.Start()
        $process.StandardInput.Close()
        [void]$process.StandardOutput.ReadToEndAsync()
        [void]$process.StandardError.ReadToEndAsync()
        if ($process.WaitForExit($TimeoutMs)) { return ($process.ExitCode -eq 0) }

        # 5.1 的 Process.Kill() 只能杀一个进程，fetch 启动的 SSH 等子进程也要停掉。
        & taskkill.exe /T /F /PID $process.Id *> $null
        if (-not $process.HasExited) { $process.Kill() }
    } catch {
        return $false
    } finally {
        $process.Dispose()
    }
    return $false
}

function Confirm-Origin([switch]$ReadOnly) {
    $timeout = if ($ReadOnly) { 2000 } else { 10000 }
    if (-not (Invoke-OriginFetch $timeout)) {
        if ($ReadOnly) { return }
        Stop-Secret '无法从 origin 获取最新状态（可能离线、认证失败或超时），未保存。'
    }

    $ErrorActionPreference = 'Continue'
    $PSNativeCommandUseErrorActionPreference = $false
    $upstream = & git -C $repo rev-parse --symbolic-full-name '@{upstream}' 2>$null
    if ($upstream -notlike 'refs/remotes/origin/*') {
        $branch = & git -C $repo symbolic-ref --quiet --short HEAD 2>$null
        $upstream = "refs/remotes/origin/$branch"
    }
    & git -C $repo merge-base --is-ancestor $upstream HEAD 2>$null
    if ($LASTEXITCODE -eq 0) { return }
    if ($LASTEXITCODE -eq 1) {
        if ($ReadOnly) { [Console]::Error.WriteLine('secret: 本机密文可能是旧的'); return }
        Stop-Secret ('本地缺少 origin 上的提交，未保存。请先运行 git -C "{0}" pull --ff-only。' -f $repo)
    }
    if (-not $ReadOnly) { Stop-Secret '无法确认当前分支在 origin 上的状态，未保存。' }
}

function Get-Names {
    if (-not (Test-Path -LiteralPath $file)) { Stop-Secret "找不到密文：$file" }
    Get-Content -LiteralPath $file | Where-Object { $_ -match '^[A-Z][A-Z0-9_]*=' -and $_ -notmatch '^sops_' } | ForEach-Object { $_.Split('=')[0] }
}
function Get-Plain {
    $ErrorActionPreference = 'Continue'
    $PSNativeCommandUseErrorActionPreference = $false
    $out = & sops -d --input-type dotenv --output-type dotenv $file 2>$null
    if ($LASTEXITCODE -ne 0) { Stop-Secret '解密失败：本机没有能解这个文件的 age 私钥，或文件损坏' }
    return @($out)
}

if ($args.Count -lt 1) { Stop-Secret '用法：secret run|set|list|verify ...（看脚本开头的说明）' }
$cmd = $args[0]
$rest = @($args | Select-Object -Skip 1)

switch ($cmd) {
    'list' { Get-Names; exit 0 }

    'run' {
        # PowerShell 调脚本时常把 -- 吞掉：有 -- 就按它分，没有就把开头的全大写参数当 Key 名
        $i = [Array]::IndexOf($rest, '--')
        if ($i -lt 0) {
            $i = 0
            while ($i -lt $rest.Count -and $rest[$i] -cmatch $nameRe) { $i++ }
            $want = if ($i -gt 0) { @($rest[0..($i - 1)]) } else { @() }
            $command = @($rest | Select-Object -Skip $i)
        } else {
            $want = if ($i -gt 0) { @($rest[0..($i - 1)]) } else { @() }
            $command = @($rest | Select-Object -Skip ($i + 1))
        }
        if ($want.Count -lt 1) { Stop-Secret '用法：secret run <名字>... -- <命令>' }
        if ($command.Count -lt 1) { Stop-Secret '-- 后面缺少命令' }
        foreach ($n in $want) { if ($n -cnotmatch $nameRe) { Stop-Secret "Key 名字只能是大写字母、数字、下划线：$n" } }
        Confirm-Origin -ReadOnly
        $plain = Get-Plain
        $values = @{}
        foreach ($n in $want) {
            $line = $plain | Where-Object { $_.StartsWith("$n=") } | Select-Object -First 1
            if ($line) { $values[$n] = $line.Substring($n.Length + 1) }
        }
        $plain = $null
        $missing = @($want | Where-Object { -not $values.ContainsKey($_) })
        if ($missing.Count -gt 0) { Stop-Secret ("密文里没有：" + ($missing -join ' ') + "。请用户在自己的终端跑 secret set <名字> 录入，不要把 Key 贴进对话。") }
        foreach ($n in $want) { Set-Item -Path "env:$n" -Value $values[$n] }
        $order = @($want | Sort-Object { $values[$_].Length } -Descending)
        $exe = $command[0]
        $exeArgs = @($command | Select-Object -Skip 1)
        # 5.1 会将原生命令的 stderr 当成 PowerShell 错误，继续交给过滤器。
        $ErrorActionPreference = 'Continue'
        $PSNativeCommandUseErrorActionPreference = $false
        & $exe @exeArgs 2>&1 | ForEach-Object {
            $s = if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { "$_" }
            foreach ($n in $order) { if ($values[$n].Length -gt 0) { $s = $s.Replace($values[$n], "[REDACTED:$n]") } }
            $s
        }
        $rc = $LASTEXITCODE
        foreach ($n in $want) { Remove-Item -Path "env:$n" -ErrorAction SilentlyContinue }
        exit $rc
    }

    'set' {
        if ($rest.Count -ne 1 -or $rest[0] -cnotmatch $nameRe) { Stop-Secret '用法：secret set <名字>（大写字母、数字、下划线）' }
        $n = $rest[0]
        Confirm-Origin
        if ([Console]::IsInputRedirected -or [Console]::IsOutputRedirected) { Stop-Secret 'secret set 只能在你自己的终端里交互运行；Agent 不代录 Key。' }
        $s1 = Read-Host "输入 $n 的值（不回显）" -AsSecureString
        $s2 = Read-Host '再输一次确认' -AsSecureString
        $v1 = [System.Net.NetworkCredential]::new('', $s1).Password
        $v2 = [System.Net.NetworkCredential]::new('', $s2).Password
        if (-not $v1) { Stop-Secret '值为空，未保存' }
        if ($v1 -cne $v2) { Stop-Secret '两次输入不一致，未保存' }
        $plain = if (Test-Path -LiteralPath $file) { @(Get-Plain) } else { @() }
        $plain = @($plain | Where-Object { $_ -and -not $_.StartsWith("$n=") }) + "$n=$v1"
        $v1 = $null; $v2 = $null
        $rel = 'secrets/' + (Split-Path -Leaf $file)
        Push-Location $repo
        try {
            $enc = ($plain -join "`n") | & sops encrypt --input-type dotenv --output-type dotenv --filename-override $rel 2>$null
            $rc = $LASTEXITCODE
        } finally { Pop-Location }
        $plain = $null
        if ($rc -ne 0 -or -not ($enc | Where-Object { $_ -match '^sops_mac=' })) { Stop-Secret '加密失败，未保存' }
        $tmp = "$file.tmp"
        [System.IO.File]::WriteAllText($tmp, (($enc -join "`n") + "`n"), $utf8)
        Move-Item -LiteralPath $tmp -Destination $file -Force
        Write-Output "已加密保存 $n。"
        git -C $repo add -- $rel
        git -C $repo commit -q -m "secrets: 更新 $n" --only -- $rel
        git -C $repo push -q 2>$null
        if ($LASTEXITCODE -eq 0) { Write-Output '已提交并推送。' } else { [Console]::Error.WriteLine("已提交，推送失败。请检查 $repo 的远端状态后手动处理。") }
        exit 0
    }

    'verify' {
        if ($rest.Count -ne 1 -or -not (Test-Path -LiteralPath $rest[0])) { Stop-Secret '用法：secret verify <只含一把私钥的文件>' }
        $k = @(Get-Content -LiteralPath $rest[0] | Where-Object { $_ -match '^AGE-SECRET-KEY-' }).Count
        if ($k -ne 1) { Stop-Secret "这个文件里有 $k 把私钥；要单独验证，文件里只能有一把" }
        # sops 除了 SOPS_AGE_KEY_FILE 还会读 %APPDATA%\sops\age\keys.txt：把默认位置指到空目录，其他来源清掉，才算单独验证
        $saved = @{}
        foreach ($v in 'SOPS_AGE_KEY_FILE','SOPS_AGE_KEY','SOPS_AGE_KEY_CMD','APPDATA','XDG_CONFIG_HOME') { $saved[$v] = [Environment]::GetEnvironmentVariable($v) }
        $empty = Join-Path $env:TEMP ('secret-verify-' + [guid]::NewGuid())
        New-Item -ItemType Directory $empty | Out-Null
        $keyPath = (Resolve-Path -LiteralPath $rest[0]).Path
        $env:SOPS_AGE_KEY = $null; $env:SOPS_AGE_KEY_CMD = $null
        $env:SOPS_AGE_KEY_FILE = $keyPath; $env:APPDATA = $empty; $env:XDG_CONFIG_HOME = $empty
        & sops -d --input-type dotenv --output-type dotenv $file *> $null
        $rc = $LASTEXITCODE
        # 原来没有的变量要删掉：用 .NET 恢复成 $null 会变成空字符串，sops 见到「存在但为空」的 SOPS_AGE_KEY_FILE 就不再找默认位置
        foreach ($v in $saved.Keys) {
            if ($null -eq $saved[$v]) { Remove-Item -Path "env:$v" -ErrorAction SilentlyContinue }
            else { Set-Item -Path "env:$v" -Value $saved[$v] }
        }
        Remove-Item -Recurse -Force $empty
        if ($rc -eq 0) { Write-Output "OK：这把钥匙单独能解开 $(Split-Path -Leaf $file)"; exit 0 }
        [Console]::Error.WriteLine("失败：这把钥匙单独解不开 $(Split-Path -Leaf $file)"); exit 1
    }

    'add-device' { Stop-Secret '本版不提供 add-device：把新公钥写进 .sops.yaml 后跑 sops updatekeys -y <密文>，见 secrets/README.md' }
    default { Stop-Secret "未知子命令 $cmd" }
}
