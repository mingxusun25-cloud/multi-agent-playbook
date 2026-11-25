# 依赖：python 3；作为 Claude Code 的 PreToolUse 钩子挂载（Bash / PowerShell）
import json, re, sys

# Isolated mode ignores PYTHONIOENCODING. Set the pipe encodings here.
sys.stdin.reconfigure(encoding="utf-8")
sys.stderr.reconfigure(encoding="utf-8")

try:
    data = json.load(sys.stdin)
except Exception:
    sys.exit(0)
tool_input = data.get("tool_input") or {}
if tool_input.get("run_in_background") is True:
    sys.exit(0)
command = tool_input.get("command") or ""
# 屏蔽 Bash heredoc、PowerShell here-string 和引号内的文字。
command = re.sub(r"<<-?[ \t]*(['\"]?)(\w+)\1[^\n]*\n.*?^[ \t]*\2[ \t]*\r?$",
                 "<<HEREDOC", command, flags=re.S | re.M)
command = re.sub(r"@(['\"])\r?\n.*?^\1@", '""', command, flags=re.S | re.M)
command = re.sub(r"'[^']*'|\"(?:[^\"\\`]|[\\`].)*\"", '""', command, flags=re.S)


def block():
    sys.stderr.write("这条命令自行丢到后台，任务跑完不会通知你。"
                     "请在工具调用中设 run_in_background: true，"
                     "或用 Start-Process -Wait 等待进程结束。\n")
    sys.exit(2)


if re.search(r"(^|[\s;(&|])nohup\s", command) or re.search(r"(?<![&>|])&[ \t]*(\)|;|$)", command, re.M):
    block()

command = re.sub(r"`\r?\n", "", command)  # PowerShell 续行
ps_command = re.compile(
    r"(?:^|[\n;|&({=])[ \t]*(?:[\w.]+\\)?"
    r"(Start-Job|Start-ThreadJob|Start-Process)(?=[\s;|&(){}]|$)", re.I
)
# -Wait 要属于这次调用。括号内的参数表达式可以包含分隔符或别的命令。
ps_token = re.compile(r"(?<!\S)-Wait(?=[:\s;|&(){}]|$)(?::[^\s;|&(){}]*)?|[;|&\n(){}]", re.I)


def has_wait(start):
    depth = 0
    for match in ps_token.finditer(command, start):
        token = match.group()
        if token in ("(", "{"):
            depth += 1
        elif token in (")", "}") and depth:
            depth -= 1
        elif not depth:
            if token in (";", "|", "&", "\n", ")", "}"):
                break
            if token.lower() in ("-wait", "-wait:$true"):
                return True
    return False


for match in ps_command.finditer(command):
    if match[1].lower() != "start-process" or not has_wait(match.end()):
        block()
