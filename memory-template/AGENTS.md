# 记忆库规范

本仓库是你本机多个 Agent（Claude Code、Codex、Antigravity）共用的轻量工程记忆。用 Git 管理，推到一个**私有**远端仓库做备份。

## 一、按项目开关（默认关闭）
1. **`Memory: facts`**：只读 `MEMORY.md`，再按需读 `10_active/<项目>/` 或 `20_wiki/`。
2. **`Memory: off`**（默认）：不读也不写本仓库。

开关写在各项目根目录，见 agent-kit 的 `rules/AGENTS.md`「记忆开关」一节。

## 二、严禁事项
- **明文凭据绝不入仓**：API Key、密码只经 `sops + age` 加密后存入 `secrets/*.enc.env`（用法见 `secrets/README.md`，录入只用 `secret set`，不贴进对话）；不在回复、日志、笔记中输出明文密钥、cookie、密码。提交前有 `ops/hooks/pre-commit` 兜底。
- 不主动扫描你的原始笔记库；需要从旧笔记提炼的，由夜间整理按 `ops/state/digested.md` 登记着读。

## 三、谁写哪里（每页单一写入者）
- `20_wiki/`、`10_active/<项目>/STATUS.md`、`MEMORY.md` 的「近 7 天关键变化」、`ops/state/`：只由夜间整理任务写（提交者 `dreaming-bot`），流程见 `ops/dreaming.md`。日常 Agent 不直接改这些。
- 日常 Agent 和你写 `10_active/<项目>/`（`STATUS.md` 除外）和 `inbox/`。发现值得长期记住的规则或要纠正 wiki 的错误，追加到 `inbox/`（格式见 `inbox/README.md`），当晚整理进 wiki。
- `ops/dreaming.md` 和本文件只由你改。

## 四、收工习惯
- 有重要进展时，更新对应项目的 `10_active/<项目>/HANDOFF.md`（已完成 / 卡点 / 下一步）。只暂存本次自己改的文件和 `inbox/`：
  ```powershell
  git add -- '10_active/<项目>/HANDOFF.md' inbox/; git commit -m "update: <简述>"; git pull --rebase; git push
  ```
- 不用 `git add -A` 或 `git add 10_active`，避免带上夜间整理的 `STATUS.md`。夜间整理运行期间不推送。
