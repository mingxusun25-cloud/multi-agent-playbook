# 加密的 API Key（sops + age）

本目录只放 `*.enc.env` 密文。明文 `.env` 会被 `.gitignore` 和 `ops/hooks/pre-commit` 两道拦下。
日常用 agent-kit 的 `secret` 命令，不直接调 sops。

## 日常用法

| 要做什么 | 命令 | 谁来跑 |
|---|---|---|
| 用 Key 跑一个命令 | `secret run OPENAI_API_KEY -- python x.py` | Agent 或你 |
| 录入或更新 Key | `secret set OPENAI_API_KEY` | **只能你**在自己的终端里跑（隐藏输入，自动加密、提交、推送） |
| 看有哪些 Key | `secret list` | 任何人（只出名字，不解密） |
| 验证一把私钥单独能解 | `secret verify <私钥文件>` | 你 |

- `secret run` 只把点名的 Key 注入这一个命令；命令输出里如果出现 Key 原文，会换成 `[REDACTED:名字]`。
- 不要把 Key 贴进任何 AI 对话：对话会被夜间整理采集。Agent 缺 Key 时会请你跑 `secret set`。
- Key 名字用大写加下划线。
- `secret` 默认找 `%USERPROFILE%\agent-memory\secrets\keys.enc.env`；记忆库放在别处就设用户环境变量 `AGENT_SECRETS_FILE`。

## 第一次设置

1. 装 `sops` 和 `age`（`winget install Mozilla.SOPS FiloSottile.age` 或 scoop）。
2. 生成本机钥匙，**一定带 `-o`**（不带会把私钥打到屏幕上）：
   ```powershell
   New-Item -ItemType Directory -Force "$env:APPDATA\sops\age" | Out-Null
   age-keygen -o "$env:APPDATA\sops\age\keys.txt"
   ```
   屏幕上只显示 `Public key: age1…`。
3. 再生成一把**离线恢复钥匙**存到电脑以外的地方（密码管理器、打印件）：`age-keygen -o recovery.txt`，记下公钥后把文件移走。
4. 把仓库根的 `.sops.yaml.example` 复制成 `.sops.yaml`，填上两把公钥，提交。
5. `secret set <名字>` 录第一把 Key。

## 换电脑或丢了电脑

- 新电脑：按上面第 2 步生成新钥匙，把它的公钥加进 `.sops.yaml`，在**能解密的环境**（旧电脑，或临时放上恢复钥匙）里跑 `sops updatekeys -y secrets/keys.enc.env`，提交推送；然后在新电脑 `secret verify` 确认单独能解，删掉临时放上的恢复钥匙。
- 丢了电脑：从 `.sops.yaml` 删掉它的公钥，跑 `sops updatekeys`，并**换掉密文里所有的 API Key**：旧密文在 git 历史里，那把钥匙仍能解开旧版本。

## 注意
- Windows 上 git 常开 `core.autocrlf`。`.gitattributes` 已把 `secrets/*.enc.env` 标成不转换换行；密文变成 CRLF 后 sops 会解不开。
- 验证某把钥匙时，文件里只能有这一把。
- 每个克隆启用一次提交前检查：`git config core.hooksPath ops/hooks`。
