# multi-agent-playbook

在一台 Windows 电脑上，让 Claude Code、Codex、Gemini（Antigravity）、Grok 按分工协作写代码，并用一个读写分离的 Git 仓库给它们做长期工程记忆。

这里是一套能直接装的规则文件、派活脚本、钩子和记忆库模板，按你自己的情况改几处占位就能用。

## 是什么

```
                 你：提需求、拍板、终审推送
                          │
        ┌─────────────────┴─────────────────┐
        │  主控：Claude Code  ⇄  Antigravity  │  额度紧张时写交接单换主控
        └──┬──────────────┬───────────────┬──┘
           │              │               │
     agy-ask         grok-ask        codex-worker
   Gemini 只读顾问   Grok 只读反方    Codex 主力执行
   独立出方案/改文案  挑高风险方案的错   --code / --review / --net
           │              │               │
           └──────── 全程经过钩子 ─────────┘
        bg-guard 拦裸后台 · secret-guard 拦泄密
        secret run：Key 加密存放、按名注入、输出脱敏

   记忆库（私有 Git 仓）：日常只读索引、只往 inbox 追加；
   每晚 Windows 计划任务让 Codex 读 ops/dreaming.md，整理进 wiki。
```

- 完整架构图和设计要点：[docs/architecture.md](docs/architecture.md)
- 可交互讲解页：下载后用浏览器打开 [docs/live-demo.html](docs/live-demo.html)

## 目录

| 路径 | 内容 |
|---|---|
| `rules/AGENTS.md` | 公共规则，Claude、Codex、Gemini 都读 |
| `rules/CLAUDE.md` | Claude 当主控：怎么派活、怎么验收、交接单 |
| `rules/GEMINI.md` | Gemini 当顾问 / 备用主控 |
| `bin/codex-worker` | 派活给 Codex，三档：`--code` 写代码、`--review` 只读审查、`--net` 联网调研 |
| `bin/agy-ask` | 让 Gemini 只读出一份独立方案，`--copy` 改界面文案 |
| `bin/grok-ask` | 让 Grok 当只读反方，给高风险方案挑错 |
| `bin/secret` | 用 sops + age 加密存 API Key；`secret run` 只注入点名的 Key，输出里的原文换成 `[REDACTED]` |
| `bin/claude-bg-guard` | Claude Code 钩子：拦 `Start-Job`、不带 `-Wait` 的 `Start-Process`、`nohup`、结尾 `&` |
| `bin/claude-secret-guard` | Claude Code 钩子：拦直接解密、读 age 私钥、全量打印环境变量 |
| `install.ps1` | 把规则同步到各工具目录、命令复制到 `%USERPROFILE%\.local\bin`、挂钩子 |
| `memory-template/` | 记忆库模板：目录约定、夜间整理提示词和定时脚本、提交前密钥检查、虚构示例数据 |
| `docs/` | 架构图和讲解页 |
| `tests/` | 钩子用例和 `secret` 回归测试 |

`bin/` 里每个命令都是 `.cmd` 启动器 + `.ps1`（或 `.py`）本体，优先用 PowerShell 7，没有就回退到 Windows PowerShell 5.1。每个脚本开头写了它的依赖。

## 依赖

| 工具 | 用在哪 | 必需？ |
|---|---|---|
| Git for Windows | 全部（钩子、worktree、记忆库） | 必需 |
| Python 3（PATH 里叫 `python.exe`） | 安装器、两个钩子、`agy-ask` | 必需 |
| Claude Code | 主控 | 必需 |
| Codex CLI（已登录） | `codex-worker`、夜间整理 | 必需 |
| Antigravity CLI `agy`（已登录） | `agy-ask`、备用主控 | 可选，不装就没有独立方案和文案顾问 |
| Grok CLI `grok`（已登录） | `grok-ask` | 可选，不装就没有反方审稿 |
| sops、age | `secret` | 可选，不用加密 Key 就不装 |
| PowerShell 7 | 所有 `.ps1` | 可选，没有就用 5.1 |

## 安装

1. 克隆本仓库，**先改规则里的占位**：`rules/AGENTS.md` 的「关于我」、禁读目录、`<agent-kit 目录>`、`<agent-memory 目录>`、`<资料目录>`；`rules/CLAUDE.md` 的「高风险三类」。
2. 在仓库根用 PowerShell 运行，先预览再装：
   ```powershell
   .\install.ps1 -DryRun
   .\install.ps1
   ```
   它会：
   - 把 `rules/` 复制到 `%USERPROFILE%\.codex\AGENTS.md`、`.claude\CLAUDE.md`、`.gemini\GEMINI.md`、`.gemini\config\AGENTS.md`；
   - 把 `bin/` 的命令复制到 `%USERPROFILE%\.local\bin`；
   - 在 `%USERPROFILE%\.claude\settings.json` 的 `PreToolUse` 挂两个钩子。

   已有文件不同就先备份成 `.bak-<时间>`。
3. 按提示把 `%USERPROFILE%\.local\bin` 加进用户 PATH，重开终端。
4. 以后改规则：改仓库里的文件，再跑一次 `install.ps1`。

## 记忆库（可选）

1. 把 `memory-template/` 复制成一个新目录（默认 `%USERPROFILE%\agent-memory`），**删掉示例数据**：`10_active/demo-todo-app/`、`20_wiki/` 里的三页、`inbox/2026-01-15.md`、`ops/state/` 里的示例行，`MEMORY.md` 换成你自己的。
2. 在里面 `git init`，推到一个**私有**远端，然后启用提交前密钥检查：
   ```powershell
   git config core.hooksPath ops/hooks
   ```
3. 要用加密 Key：按 `secrets/README.md` 生成 age 钥匙、建 `.sops.yaml`，再 `secret set <名字>`。记忆库不在默认位置时，设用户环境变量 `AGENT_SECRETS_FILE` 指向 `secrets\keys.enc.env`。
4. 夜间整理：先手动跑一次看结果，再注册计划任务（默认每天 23:30）：
   ```powershell
   .\ops\run-dreaming.ps1 -DryRun
   .\ops\run-dreaming.ps1
   .\ops\run-dreaming.ps1 -Register
   ```
   它让 Codex 读 `ops/dreaming.md` 照做：采集当天的 Codex、Claude Code、Antigravity 会话和 `inbox/`，整理进 `20_wiki/` 和各项目的 `STATUS.md`，写运行报告到 `ops/state/runs/`。大删改不直推 main，推到 `dream/<日期>` 分支等你审。**注意**：夜间任务要写 `.git` 和推送，所以不开沙箱，能做什么全靠 `dreaming.md` 约束。
5. 在想用记忆的项目根放三个不入库的文件（都写进 `.git/info/exclude`）：
   ```text
   AGENTS.local.md   →  Memory: facts
   CLAUDE.local.md   →  @AGENTS.local.md
   GEMINI.md         →  @[本机记忆开关](AGENTS.local.md)
   ```
   没声明的项目默认 `Memory: off`，不读也不写记忆库。

## 按自己情况改

- **分工**：额度最紧的那家当主控，把成块的活派给额度宽的。只有 Claude 和 Codex 也能用，删掉 `agy-ask` / `grok-ask` 相关的规则行即可。
- **高风险三类**：决定什么时候请 Grok 当反方、什么时候派 `--review`，按你的项目改（例如支付、数据迁移、对外承诺）。
- **模型和超时**：`AGY_ASK_MODEL`、`AGY_ASK_TIMEOUT`、`GROK_ASK_MODEL`、`GROK_ASK_EFFORT`、`CODEX_WORKER_MODEL`、`CODEX_WORKER_EFFORT`、`DREAMING_MODEL` 环境变量。
- **派活结果**：都存在 `%USERPROFILE%\.cache\agent-dispatch\`；日志里可能有命令输出，别外传。
- **记忆来源**：夜间整理认哪些来源、出处 ID 怎么写，改 `memory-template/ops/dreaming.md` 第二节的表。

## 测试

需要 Python、Git、sops、age-keygen。在仓库根运行（5.1 和 7 各跑一次更稳）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests\test.ps1
pwsh -NoProfile -File tests\test.ps1
```

覆盖：`claude-bg-guard` 和 `claude-secret-guard` 的共享用例（`tests/*-cases.json`），以及 `secret` 在临时仓库、临时钥匙下的注入、脱敏、落后和离线保护。不碰你真实的密文。

## License

MIT
