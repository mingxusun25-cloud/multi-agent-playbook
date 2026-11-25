# 依赖：python 3；作为 Claude Code 的 PreToolUse 钩子挂载（Bash / PowerShell / Read）
import json, re, sys

# Isolated mode ignores PYTHONIOENCODING. Set the pipe encodings here.
sys.stdin.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
ti = data.get("tool_input") or {}
tool = data.get("tool_name") or ""

def block(msg):
    sys.stderr.write(msg + "\n")
    sys.exit(2)

keyfile = re.compile(r"(sops[/\\]+age[/\\]+keys[^/\\\s'\"]*\.txt|AGE-SECRET-KEY-)", re.I)

if tool == "Read":
    if keyfile.search(ti.get("file_path") or ""):
        block("不读 age 私钥文件。要用 Key 就跑 secret run <名字> -- <命令>。")
    sys.exit(0)

cmd = ti.get("command") or ""
# 去掉 heredoc 正文（文档、提交信息里提到这些命令不算）；不去掉引号：pwsh -c '<代码>' 里的命令也要查
cmd = re.sub(r"<<-?\s*(['\"]?)(\w+)\1[^\n]*\n.*?\n[ \t]*\2[ \t]*(?=\n|$)", "<<HEREDOC", cmd, flags=re.S)
rules = [
    (r"\bsops\b[^|;&\n]*\s(-d|--decrypt|decrypt|exec-env|exec-file|edit)\b",
     "不直接用 sops 解密、编辑或 exec-env（会把 Key 带进输出）。用 secret run <名字> -- <命令>；要录或改 Key，请用户在自己的终端跑 secret set <名字>。"),
    (r"\bage\b\s+(-d|--decrypt)\b",
     "不直接用 age 解密。用 secret run <名字> -- <命令>。"),
    (r"\bage-keygen(?:\.exe)?\b(?![^|;&\n]*\s-[oy]\s)",
     "age-keygen 必须带 -o <文件>，否则私钥会打到屏幕上进入对话和日志。"),
    (r"\b(cat|type|less|more|head|tail|Get-Content|gc|cp|copy|scp)\b[^|;&\n]*(sops[/\\]+age[/\\]+keys|keys\.txt)",
     "不读、不拷 age 私钥文件。新设备用 age-keygen -o 自己生成，再用 secret add-device 加公钥。"),
    (r"(^|[\s;&|(])(printenv|env)\s*($|[|;&)])|\bGet-ChildItem\s+env:|\bgci\s+env:|\bdir\s+env:|^\s*set\s*$",
     "不全量打印环境变量（可能带出 Key）。要查某个变量是否存在，用 test -n \"$名字\" && echo 有。"),
]
for pat, msg in rules:
    if re.search(pat, cmd, re.I | re.M):
        block(msg)
