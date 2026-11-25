# 记忆总索引（≤ 80 行）

> 示例数据：下面的项目和条目都是虚构的，用来演示格式。开始用之前清空换成你自己的。

## 当前活跃项目（详情见 `10_active/<项目>/`）
- [demo-todo-app](10_active/demo-todo-app/STATUS.md)：一个待办清单 Web 应用，正在做离线同步。

## 长期有效知识导航（详情见 `20_wiki/`）
- [开发工具与 Agent 协作](20_wiki/devtools-and-agents.md)：派活档位怎么选、钩子拦什么、派活脚本的坑。
- [Windows 开发环境](20_wiki/windows-env.md)：PowerShell 5.1 与 7 的差异、编码、PATH。
- [demo-todo-app 项目知识](20_wiki/work-demo-todo-app.md)：架构决定、约定、踩过的坑。

## 凭据
- 所有 API Key 在 `secrets/keys.enc.env`（加密），用 `secret run <名字> -- <命令>` 注入；名字列表用 `secret list` 看。

## 近 7 天关键变化（滚动保留最多 5 条，夜间整理写）
- 2026-01-15 demo-todo-app 本地存储从 localStorage 换成 IndexedDB（`git:demo-todo-app@a1b2c3d`）。
