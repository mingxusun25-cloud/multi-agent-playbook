# 多模型协作与工程记忆架构

> 一套面向单台 Windows 电脑的多模型协同开发与长期记忆方案。核心思路：**把模型当成偏科的团队成员来分工，用脚手架和机械护栏控质量、控安全，用读写分离的轻量 Git 仓库做跨会话记忆。**
>
> 可交互版本：用浏览器打开 [`live-demo.html`](live-demo.html)，按 `1` `2` 切视图，点节点看讲解。

---

## 一、多模型协作架构

```mermaid
%%{init: {"flowchart": {"curve": "basis", "nodeSpacing": 40, "rankSpacing": 55}} }%%
flowchart TB
    Human(["👤 人 · 负责人<br/>需求定义 · 方案拍板 · 推送终审"])

    subgraph L1["① 主控层 · 双主控可热切换"]
        direction LR
        Claude["<b>Claude Code · 主控</b><br/>架构拆解 · 定接口与验收<br/>前端视觉 · 合并验收 · 提交发布"]
        GeminiMain["<b>Antigravity / Gemini · 备用主控</b><br/>讨论稿 · 脑暴 · 文案交互<br/>额度紧张时读交接单接棒"]
        Claude <==>|"写交接单 / 接棒"| GeminiMain
    end

    subgraph L2["② 调度层 · agent-kit"]
        direction LR
        AgyAsk["<b>agy-ask · 只读顾问</b><br/>Gemini 独立出方案<br/>--copy 改文案与交互"]
        GrokAsk["<b>grok-ask · 只读反方</b><br/>专挑高风险方案漏洞<br/>附推翻实验"]
        CodexW["<b>codex-worker · 主力执行</b><br/>--code 写代码 · --review 审高风险 diff<br/>--net 调研"]
    end

    subgraph L3["③ 护栏与凭据"]
        direction LR
        Hooks["<b>机械护栏（钩子）</b><br/>bg-guard 拦裸后台 · secret-guard 拦泄密<br/>pre-commit 拦明文密钥进记忆库"]
        Secret["<b>凭据注入</b><br/>sops + age 加密存放<br/>secret run 按名注入 · 输出 [REDACTED]"]
    end

    subgraph L4["④ 各放各处"]
        direction LR
        Git["<b>代码 · Git</b><br/>并行会话各开 worktree<br/>提交推送只由主控做"]
        Docs["<b>资料目录</b><br/>讨论稿 · 截图 · 交付件<br/>不放进代码仓库根目录"]
        Mem["<b>记忆库 · 私有 Git 仓</b><br/>见下一节"]
    end

    Human ==>|"需求 / 拍板"| L1
    L1 -->|"派活"| AgyAsk & GrokAsk & CodexW
    AgyAsk -.->|"独立方案 / 文案建议"| L1
    GrokAsk -.->|"≤3 条漏洞 + 推翻实验"| L1
    CodexW -.->|"代码改动 / 实测回执"| L1
    L1 ==>|"全程经钩子"| Hooks
    CodexW -->|"用 Key 时"| Secret
    Hooks ==>|"提交 / 推送"| Git

    classDef human fill:#f1f5f9,stroke:#334155,stroke-width:2px,color:#0f172a
    classDef lead fill:#eef2ff,stroke:#4f46e5,stroke-width:2px,color:#1e1b4b
    classDef kit fill:#ecfdf5,stroke:#059669,stroke-width:1.5px,color:#064e3b
    classDef guard fill:#fff1f2,stroke:#e11d48,stroke-width:1.5px,color:#4c0519
    classDef sync fill:#f0f9ff,stroke:#0284c7,stroke-width:1.5px,color:#0c4a6e
    class Human human
    class Claude,GeminiMain lead
    class AgyAsk,GrokAsk,CodexW kit
    class Hooks,Secret guard
    class Git,Docs,Mem sync
```

> 图例：粗实线 = 主流程（需求、强制经过的护栏）；细实线 = 派活 / 调用；虚线 = 回执。

### 设计要点
1. **按模型性格分工**：Claude 主管拆解、审美与验收；Gemini 当独立军师和文案交互顾问（额度紧张时接棒主控）；Codex 承接成块后端/脚本、高风险审查和调研；Grok 只在高风险方案上当反方挑错。
2. **双主控热切换**：两家额度池独立，切主控前落盘约 30～40 行的 `.agent-handoff.md`（记录目标、已拍板决定、已验证/未验证状态和活跃 worker），另一家读完接棒。
3. **机械护栏替代口头提醒**：能写成脚本或钩子硬拦的，不只写进提示词——防野后台丢任务、防明文读私钥、防明文密钥入库。
4. **派活脚本把规矩写死**：`codex-worker` 的三个档位各自固定规则和回执格式（Windows 上 Codex 沙箱不稳，三档都不开沙箱，靠规则约束）；`agy-ask` 用只读白名单、`grok-ask` 用 plan 模式，都只读；主控不裸调 `codex exec`。

### 「高风险三类」

`grok-ask` 反方审稿和 `codex-worker --review` 只用在这三类上，按你的项目改：

- 硬件通信或烧录（改协议、刷固件）
- 可能丢数据或泄露凭据（存储迁移、删除逻辑、凭据处理）
- 高风险的用户承诺（对外文案里写到的功能、数字、保证）

---

## 二、工程记忆架构

```mermaid
%%{init: {"flowchart": {"curve": "basis", "nodeSpacing": 35, "rankSpacing": 60}} }%%
flowchart LR
    subgraph S1["① 按项目开关（默认关闭）"]
        Cfg{{"<b>项目根本机文件</b><br/>Memory: off（默认）<br/>Memory: facts"}}
    end

    subgraph S2["② 日常会话 · 多 Agent"]
        direction TB
        Read["<b>开工 · 按需读</b><br/>先读总索引<br/>再下钻 STATUS / wiki"]
        Write["<b>收工 · 只追加</b><br/>已核实结论写入 inbox<br/>不直接改主库与 wiki"]
    end

    subgraph S3["③ 暂存层（日常 Agent 可写）"]
        direction TB
        Inbox["<b>inbox/日期.md</b><br/>只追加<br/>结论 · 踩坑 · 纠错候选"]
        Handoff["<b>HANDOFF.md</b><br/>会话间任务交接"]
    end

    subgraph S4["④ 夜间整理（唯一主库写入者）"]
        Night[["<b>夜间 Codex 任务</b><br/>Windows 计划任务触发<br/>采集会话 + inbox · 去重账本"]]
    end

    subgraph S5["⑤ 记忆主库（私有 Git 仓 · 日常只读）"]
        direction TB
        Index[("<b>MEMORY.md</b><br/>总索引 ≤ 80 行")]
        Status[("<b>STATUS.md</b><br/>项目进展与待办")]
        Wiki[("<b>20_wiki/</b><br/>长期知识 · 标已核/未核 + 出处")]
    end

    subgraph S6["⑥ 凭据隔离（不进记忆正文）"]
        Enc["<b>加密凭据（sops + age）</b><br/>只经 secret run 按名注入<br/>输出自动 [REDACTED]"]
    end

    Cfg ==>|"facts 时才读"| Read
    Index ==>|"先读总索引"| Read
    Status -.->|"按需下钻"| Read
    Wiki -.->|"按需下钻"| Read
    Write ==>|"只追加"| Inbox
    Write -->|"更新交接"| Handoff
    Inbox ==>|"每晚汇总"| Night
    Night ==>|"去重 · 核对 · 写入"| Index & Status & Wiki
    Enc -.->|"注入 · 输出脱敏"| S2

    classDef sw fill:#fffbeb,stroke:#d97706,stroke-width:2px,color:#78350f
    classDef daily fill:#eef2ff,stroke:#4f46e5,stroke-width:2px,color:#1e1b4b
    classDef stage fill:#fff7ed,stroke:#ea580c,stroke-width:1.5px,color:#7c2d12
    classDef night fill:#f5f3ff,stroke:#7c3aed,stroke-width:2px,color:#2e1065
    classDef store fill:#ecfdf5,stroke:#059669,stroke-width:1.5px,color:#064e3b
    classDef sec fill:#fff1f2,stroke:#e11d48,stroke-width:1.5px,color:#4c0519
    class Cfg sw
    class Read,Write daily
    class Inbox,Handoff stage
    class Night night
    class Index,Status,Wiki store
    class Enc sec
```

> 读法：沿 ② 收工 → ③ 暂存 → ④ 夜间整理 → ⑤ 主库 → ② 开工 形成闭环；日常会话只读主库、只写暂存，主库只有夜间任务一个写入者。

### 设计要点
1. **默认关闭、按需加载**：未声明记忆模式的项目默认 `Memory: off`；开启 `Memory: facts` 时先只读不超过 80 行的 `MEMORY.md`，再按需读具体项目的 `STATUS.md` 或 `20_wiki/`，省上下文。
2. **每页单一写入者（读写分离）**：日常 Agent 只往 `inbox/` 追加和更新 `HANDOFF.md`；`MEMORY.md` 滚动区、`STATUS.md` 和 `20_wiki/` 只由夜间整理任务写，从结构上消灭并发写冲突和垃圾堆积。
3. **证据与溯源**：wiki 每条标「已核 / 未核」及出处（提交号或会话 ID），避免旧推测被后续会话当成既定事实；`未核` 条目 30 天移到「待核」、60 天删除。
4. **夜间整理自带护栏**：大删改不直推 main，改推 `dream/<日期>` 分支等人审；来源不全的晚上不做按时间的删除；提交前扫明文密钥。完整流程见 [`memory-template/ops/dreaming.md`](../memory-template/ops/dreaming.md)。
5. **严格边界**：明文凭据绝不进入记忆库，统一走 `sops + age` 加密和 `secret run` 按名注入并脱敏。
