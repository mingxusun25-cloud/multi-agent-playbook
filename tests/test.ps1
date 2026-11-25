# 用共享样例验证两个钩子，并用临时 Git 仓库和测试钥匙验证 secret。依赖：python、Git for Windows、sops、age-keygen。
$ErrorActionPreference = 'Stop'
$utf8 = [System.Text.UTF8Encoding]::new($false)
$root = Split-Path -Parent $PSScriptRoot
$guard = Join-Path $root 'bin\claude-bg-guard.py'
$secret = Join-Path $root 'bin\secret.ps1'
$engine = Join-Path $PSHOME $(if ($PSVersionTable.PSEdition -eq 'Desktop') { 'powershell.exe' } else { 'pwsh.exe' })
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('agent-kit-test-' + [guid]::NewGuid())
[void][System.IO.Directory]::CreateDirectory($tmp)

function Assert-Test($Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Invoke-TestProcess([string]$Exe, [string[]]$Arguments, [string]$InputText = '') {
    $stdin = Join-Path $tmp 'stdin'
    $stdout = Join-Path $tmp 'stdout'
    $stderr = Join-Path $tmp 'stderr'
    [System.IO.File]::WriteAllText($stdin, $InputText, $utf8)
    $process = Start-Process -FilePath $Exe -ArgumentList $Arguments -NoNewWindow -Wait -PassThru `
        -RedirectStandardInput $stdin -RedirectStandardOutput $stdout -RedirectStandardError $stderr
    return @{
        Code = $process.ExitCode
        Out = [System.IO.File]::ReadAllText($stdout, $utf8)
        Err = [System.IO.File]::ReadAllText($stderr, $utf8)
    }
}

function Invoke-Secret([string[]]$Arguments) {
    Invoke-TestProcess $engine (@('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
        '-File', ('"{0}"' -f $secret)) + $Arguments)
}

function Invoke-TestGit {
    & git @args
    if ($LASTEXITCODE -ne 0) { throw '临时仓库的 Git 命令失败' }
}

function Write-TestCipher([string]$Repo, [string]$Value) {
    $plain = Join-Path $tmp 'fixture.env'
    [System.IO.File]::WriteAllText($plain, ("TEST_KEY={0}" + [char]10) -f $Value, $utf8)
    Push-Location $Repo
    try {
        $enc = & sops -e --input-type dotenv --output-type dotenv --filename-override secrets/keys.enc.env $plain
        Assert-Test ($LASTEXITCODE -eq 0 -and ($enc -match '^sops_mac=')) '测试数据加密失败'
        $content = ($enc -join [char]10) + [char]10
        [System.IO.File]::WriteAllText((Join-Path $Repo 'secrets\keys.enc.env'), $content, $utf8)
    } finally {
        Pop-Location
    }
}

$envNames = @('AGENT_SECRETS_FILE', 'SOPS_AGE_KEY_FILE', 'SOPS_AGE_KEY', 'SOPS_AGE_KEY_CMD',
    'SOPS_AGE_SSH_PRIVATE_KEY_FILE', 'SOPS_AGE_SSH_PRIVATE_KEY_CMD', 'APPDATA', 'USERPROFILE',
    'GIT_CONFIG_NOSYSTEM', 'GIT_CONFIG_GLOBAL', 'GIT_AUTHOR_NAME', 'GIT_AUTHOR_EMAIL', 'GIT_COMMITTER_NAME', 'GIT_COMMITTER_EMAIL',
    'AGENT_KIT_TEST_EXPECTED')
$saved = @{}
foreach ($name in $envNames) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
try {
    Write-Output "PowerShell $($PSVersionTable.PSVersion)"
    $cases = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'bg-guard-cases.json'), $utf8) | ConvertFrom-Json
    foreach ($case in $cases) {
        $payload = if ($null -ne $case.raw) { $case.raw } else {
            $tool = if ($case.tool) { $case.tool } else { 'Bash' }
            @{ tool_name = $tool; tool_input = @{
                command = $case.command; run_in_background = [bool]$case.run_in_background
            }} | ConvertTo-Json -Depth 4 -Compress
        }
        $result = Invoke-TestProcess 'python.exe' @('-I', ('"{0}"' -f $guard)) $payload
        Assert-Test ($result.Code -eq $case.exit) "bg-guard 失败：$($case.name)（期望 $($case.exit)，实际 $($result.Code)）"
        if ($case.exit -eq 2) {
            Assert-Test ($result.Err.Contains('run_in_background: true')) "bg-guard 失败：$($case.name)（缺少后台执行提示）"
        }
    }
    Write-Output "bg-guard ok ($($cases.Count) cases)"

    $secretGuard = Join-Path $root 'bin\claude-secret-guard.py'
    $secretCases = [System.IO.File]::ReadAllText((Join-Path $PSScriptRoot 'secret-guard-cases.json'), $utf8) | ConvertFrom-Json
    foreach ($case in $secretCases) {
        $payload = @{ tool_name = $case.tool; tool_input = $case.input } | ConvertTo-Json -Depth 4 -Compress
        $result = Invoke-TestProcess 'python.exe' @('-I', ('"{0}"' -f $secretGuard)) $payload
        Assert-Test ($result.Code -eq $case.exit) "secret-guard 失败：$($case.name)（期望 $($case.exit)，实际 $($result.Code)）"
    }
    Write-Output "secret-guard ok ($($secretCases.Count) cases)"

    $seed = Join-Path $tmp 'seed'
    $repo = Join-Path $tmp 'repo'
    $origin = Join-Path $tmp 'origin.git'
    $offline = Join-Path $tmp 'offline.git'
    $env:SOPS_AGE_KEY = $null
    $env:SOPS_AGE_KEY_CMD = $null
    $env:SOPS_AGE_SSH_PRIVATE_KEY_FILE = $null
    $env:SOPS_AGE_SSH_PRIVATE_KEY_CMD = $null
    $env:APPDATA = Join-Path $tmp 'config'
    $env:USERPROFILE = Join-Path $tmp 'profile'
    $env:SOPS_AGE_KEY_FILE = Join-Path $tmp 'age-test.txt'
    $env:GIT_CONFIG_NOSYSTEM = '1'
    $env:GIT_CONFIG_GLOBAL = Join-Path $tmp 'gitconfig'
    $env:GIT_AUTHOR_NAME = $env:GIT_COMMITTER_NAME = 'agent-kit test'
    $env:GIT_AUTHOR_EMAIL = $env:GIT_COMMITTER_EMAIL = 'agent-kit-test@example.invalid'

    $generated = Invoke-TestProcess 'age-keygen.exe' @('-o', ('"{0}"' -f $env:SOPS_AGE_KEY_FILE))
    Assert-Test ($generated.Code -eq 0) '测试钥匙生成失败'
    $public = & age-keygen -y $env:SOPS_AGE_KEY_FILE
    Assert-Test ($LASTEXITCODE -eq 0) '测试公钥读取失败'
    [void][System.IO.Directory]::CreateDirectory((Join-Path $seed 'secrets'))
    [System.IO.File]::WriteAllLines((Join-Path $seed '.sops.yaml'), [string[]]@(
        'creation_rules:', "  - age: $public"
    ), $utf8)
    Invoke-TestGit -C $seed init -q -b main
    $oldValue = 'z7q8'
    $newValue = 'new-fixture-value'
    Write-TestCipher $seed $oldValue
    Invoke-TestGit -C $seed add -- .sops.yaml secrets/keys.enc.env
    Invoke-TestGit -C $seed commit -qm init
    Invoke-TestGit clone -q --bare $seed $origin
    Invoke-TestGit clone -q $origin $repo
    $env:AGENT_SECRETS_FILE = Join-Path $repo 'secrets\keys.enc.env'
    $before = Invoke-TestGit -C $repo rev-parse HEAD

    $echoer = Join-Path $tmp 'echo-env.py'
    [System.IO.File]::WriteAllLines($echoer, [string[]]@(
        'import os, sys'
        'value = os.environ["TEST_KEY"]'
        'assert value == os.environ["AGENT_KIT_TEST_EXPECTED"]'
        'print(value)'
        'if len(sys.argv) > 1:'
        '    print(value, file=sys.stderr)'
        '    sys.exit(7)'
    ), $utf8)
    $runArgs = @('run', 'TEST_KEY', '--', 'python.exe', '-I', ('"{0}"' -f $echoer))
    $env:AGENT_KIT_TEST_EXPECTED = $oldValue

    $result = Invoke-Secret @('set', 'TEST_KEY')
    Assert-Test ($result.Code -eq 2 -and $result.Err.Contains('自己的终端')) '同步时 set 应进入交互检查'
    Write-TestCipher $seed $newValue
    Invoke-TestGit -C $seed add -- secrets/keys.enc.env
    Invoke-TestGit -C $seed commit -qm 'advance fixture'
    Invoke-TestGit -C $seed push -q $origin main
    Assert-Test ((Invoke-TestGit -C $repo rev-parse origin/main) -eq $before) '测试初始化时 origin/main 不应已更新'

    $result = Invoke-Secret @('set', 'TEST_KEY')
    $pullHint = 'git -C "{0}" pull --ff-only' -f $repo
    Assert-Test ($result.Code -eq 2 -and -not $result.Out -and $result.Err.Contains($pullHint)) '落后时 set 应拒绝并提示快进'
    $result = Invoke-Secret $runArgs
    if ($result.Code -ne 0 -or $result.Out.Trim() -ne '[REDACTED:TEST_KEY]') {
        $errorText = $result.Err.Replace($oldValue, '[FIXTURE]').Replace($newValue, '[FIXTURE]').Trim()
        throw "落后时 run 应继续使用本地值并脱敏（退出码 $($result.Code)，stderr 为 $errorText）"
    }
    Assert-Test ($result.Err.Trim() -eq 'secret: 本机密文可能是旧的') '落后时 run 应在 stderr 警告'

    Move-Item -LiteralPath $origin -Destination $offline
    $result = Invoke-Secret @('set', 'TEST_KEY')
    Assert-Test ($result.Code -eq 2 -and -not $result.Out -and $result.Err.Contains('无法从 origin 获取最新状态')) '离线时 set 应拒绝并说明原因'
    $result = Invoke-Secret $runArgs
    Assert-Test ($result.Code -eq 0 -and $result.Out.Trim() -eq '[REDACTED:TEST_KEY]' -and -not $result.Err) '离线时 run 应脱敏且静默继续'
    Assert-Test ((Invoke-TestGit -C $repo rev-parse HEAD) -eq $before -and -not (Invoke-TestGit -C $repo status --porcelain)) '保护后仓库或密文有改动'

    Move-Item -LiteralPath $offline -Destination $origin
    Invoke-TestGit -C $repo pull -q --ff-only
    $env:AGENT_KIT_TEST_EXPECTED = $newValue
    $result = Invoke-Secret $runArgs
    Assert-Test ($result.Code -eq 0 -and $result.Out.Trim() -eq '[REDACTED:TEST_KEY]' -and -not $result.Err) '同步后 run 应脱敏且不警告'
    $result = Invoke-Secret ($runArgs + '--stderr')
    Assert-Test ($result.Code -eq 7 -and [regex]::Matches($result.Out, '\[REDACTED:TEST_KEY\]').Count -eq 2 -and -not $result.Err) 'run 应脱敏子进程的两路输出并透传退出码'
    Write-Output 'secret freshness ok'

    # 记忆库的提交前钩子：用 Git for Windows 自带的 bash 跑
    $memRepo = Join-Path $tmp 'memory'
    Invoke-TestGit init -q -b main $memRepo
    Invoke-TestGit -C $memRepo config core.hooksPath ((Join-Path $root 'memory-template\ops\hooks') -replace '\\', '/')
    [System.IO.File]::WriteAllText((Join-Path $memRepo 'ok.md'), "普通笔记`n", $utf8)
    Invoke-TestGit -C $memRepo add ok.md
    Invoke-TestGit -C $memRepo commit -qm ok
    $fakeKey = 'sk-' + ('a' * 24)
    [System.IO.File]::WriteAllText((Join-Path $memRepo 'leak.md'), "key: $fakeKey`n", $utf8)
    & git -C $memRepo add leak.md
    $result = Invoke-TestProcess 'git.exe' @('-C', ('"{0}"' -f $memRepo), 'commit', '-qm', 'leak')
    Assert-Test ($result.Code -ne 0 -and $result.Err.Contains('新增行像是明文密钥')) 'pre-commit 没拦住像密钥的新增行'
    & git -C $memRepo reset -q
    [void][System.IO.Directory]::CreateDirectory((Join-Path $memRepo 'secrets'))
    [System.IO.File]::WriteAllText((Join-Path $memRepo 'secrets\keys.enc.env'), "PLAIN=1`n", $utf8)
    & git -C $memRepo add -f secrets/keys.enc.env
    $result = Invoke-TestProcess 'git.exe' @('-C', ('"{0}"' -f $memRepo), 'commit', '-qm', 'plain')
    Assert-Test ($result.Code -ne 0 -and $result.Err.Contains('没有 sops 加密元数据')) 'pre-commit 没拦住未加密的 secrets 文件'
    Write-Output 'memory pre-commit ok'
    Write-Output 'win tests ok'
} finally {
    foreach ($name in $envNames) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    Remove-Item -LiteralPath $tmp -Recurse -Force
}
