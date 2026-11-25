# Windows 开发环境（示例页）

## PowerShell

- **脚本文件存成 UTF-8 带 BOM。** Windows PowerShell 5.1 把不带 BOM 的源码当 ANSI 读，中文会乱码；PowerShell 7 两种都认。**已核，2026-01-08（5.1 下对照实验：带 BOM 正常、不带 BOM 乱码）**。`codex:00000000-0000-0000-0000-000000000003#15`
- **产品测试用 5.1 跑一遍。** 用户机器上默认只有 5.1，7 上能过不代表 5.1 能过。**已核**。`inbox:2026-01-08.md#2`

## PATH

- **`install.ps1` 把命令复制到 `%USERPROFILE%\.local\bin`，要手动加进用户 PATH 后重开终端。** **已核**。`git:agent-kit@0000003`
