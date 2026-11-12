# zagent

[English](README.md) · [文档（英文）](docs/index.md)

用 [Zig](https://ziglang.org/) 编写的命令行 AI agent。它通过工具在你的机器上
干活——读写文件、搜索项目、执行命令、调用 API——并把对话、计划和长期记忆保留到
下一次运行。

## 功能

- **交互式 REPL** — 全屏对话，提示符固定在最后一行；↑/↓ 可以调出本次及以往运行
  的输入历史；`Ctrl+Z` 挂起、`fg` 重绘整屏。[说明](docs/ui.md)
- **单次查询** — 直接把问题作为命令行参数传入
- **工具调用** — `bash`、`read`、`write`（整文件写入）、`edit`（精确替换）、`apply_patch`、`ls`、`rg`/`grep`、
  `fd`/`find`、`http`、`ask_user`、`plan`、`memory_save`/`memory_search`、
  `announce_task`。[工具](docs/tools.md) · [搜索](docs/searching.md) ·
  [补丁](docs/patching.md) · [HTTP](docs/http.md)
- **多轮工具链** — 模型循环调用工具直到任务完成。[代理循环](docs/agent-loop.md)
- **子 agent** — 把一件自足的任务交给同一个进程里的第二个 agent，并「看着」它：
  到检查点回一份进度报告，由你决定它继续还是停止。[子 agent](docs/subagents.md)
- **MCP 服务** — 启动 `mcp.json` 里描述的服务，把它们的工具按需加载给模型。
  [MCP](docs/mcp.md)
- **会话计划** — 进行中工作的清单，`/clear` 之后仍在，`--resume` 时还原。
  [计划](docs/plan.md)
- **持久会话** — 每次启动都是被保存的会话：`/new` 开新会话，
  `--resume <id>` 带着上下文和计划继续。[会话](docs/sessions.md)
- **记忆** — 按工作区保存的长期笔记，由模型在关键决定处写入，按需检索。
  [记忆](docs/memory.md)
- **选择菜单** — 需求有歧义时给出具体选项而不是猜，并标出推荐项。
  [选择菜单](docs/ui.md#choices)
- **模型自己判断是否完成** — 没有工具调用的最终回答直接结束回合；模型需要先验证
  再说完成了什么、还差什么。[完成状态](docs/agent-loop.md#completion-status)
- **实时进度** — 等待模型、执行工具、观察子 agent 各有一行动画和已用时间。
  [实时进度](docs/ui.md#live-progress)
- **调试追踪** — `--debug` 记录每一次请求、返回、工具调用与结果，并把整次运行渲染
  成一张单文件 HTML 流程图，出问题时照着查。它是编译期选项，正式版本里不含这部分
  代码（重新编译时加 `-Dtrace` 可打开）。
  [调试追踪（英文）](docs/debug.md)
- **服务商预设** — `openai`、`deepseek`、面向任意 Responses 兼容厂商的
  `openai-compatible`，以及用 ChatGPT 订阅的 `codex`。
  [服务商](docs/providers.md) · [ChatGPT / Codex](docs/codex.md)
- **Markdown 渲染与 ANSI 颜色** — 终端里渲染，管道输出保留原始 Markdown。
  [渲染](docs/ui.md#rendering)

## 环境要求

- Zig 0.17.x
- 一个兼容 Responses 的端点的 API key 和基础地址

## 构建

```bash
zig build
```

二进制在 `zig-out/bin/zagent`，`zagent --help` 列出命令行参数。

## 快速开始

```bash
export DEEPSEEK_API_KEY='你的 key'      # 或者 OPENAI_API_KEY，见「服务商」
zagent                                  # 进入交互会话
zagent "现在几点？"                      # 单次查询，直接输出回答
zagent --resume <会话id> "继续任务"
```

只导出 key 就能用：`DEEPSEEK_API_KEY` 自动选中 `deepseek`，`OPENAI_API_KEY`
选中 `openai`。其他厂商：

```bash
export AI_PROVIDER=openai-compatible
export AI_URL=https://dashscope.aliyuncs.com/compatible-mode/v1
export AI_MODEL=qwen-plus
export AI_KEY='你的 key'
zagent
```

配置文件位置、完整环境变量表、token 预算与重试见
[配置（英文）](docs/configuration.md)。把 `zagent.example.conf` 复制到
`$XDG_CONFIG_HOME/zagent` 或 `~/.config/zagent` 即可；`mcp.example.json` 是
可选的 MCP 服务示例。

## 服务商预设

| 预设 | 基础地址 | 默认模型 | Key 环境变量 |
|------|----------|----------|--------------|
| `openai` | `https://api.openai.com/v1` | `gpt-4o-mini` | `OPENAI_API_KEY` |
| `deepseek` | `https://api.deepseek.com` | `deepseek-flash` | `DEEPSEEK_API_KEY` |
| `openai-compatible` | 由 `AI_URL` 指定 | 由 `AI_MODEL` 指定 | `AI_KEY` |
| `codex` | ChatGPT 后端 | `gpt-5.4` | 无需（`zagent login`） |

显式设置的 `AI_URL`、`AI_MODEL` 和 key 总是覆盖预设；未设置 `AI_PROVIDER` 时按
已导出的 key 自动选择。自动选择规则和 Responses 协议的用法见
[服务商（英文）](docs/providers.md)。

## 可选 prompt cache 控制

可在环境或配置文件设置 `AI_PROMPT_CACHE_KEY`、`AI_PROMPT_CACHE_RETENTION`，环境优先。
两者默认均未设置，不发送显式缓存字段。retention 只接受 `in_memory` 或 `24h`，
其他值导致配置加载返回 `InvalidPromptCacheRetention`。兼容端点启用前需确认支持这些字段。
key 应使用稳定、非敏感的标识，不要使用秘密或每轮新生成的随机值；不设置这些字段也可能自动缓存。
参见[配置示例](zagent.example.conf)。

读取／搜索分页与命令输出的默认预算约为 12 KiB，单个工具结果的硬上限仍为 40 KiB。
长命令输出分别保留 stdout、stderr 的头尾，并标明中间省略；需要中间内容时，主动将输出重定向到文件后分页读取。
Debug 请求事件包含输入字节数、工具 schema 字节数及工具集合的 SHA-256 指纹；每轮摘要区分缓存字段未报告与明确报告为零。

## 交互命令

| 命令 | 说明 |
|------|------|
| `/help` | 显示帮助 |
| `/clear` | 清空对话历史 |
| `/new` | 新建会话：清空屏幕并清空临时目录 |
| `/session` | 显示当前会话 ID 和恢复命令 |
| `/plan` | 打印计划；`/plan clear` 清空 |
| `/memory` | 列出记忆条目 |
| `/remember <文本>` | 保存一条记忆 |
| `/forget <序号\|all>` | 删除一条或全部记忆 |
| `/model` | 显示当前模型 |
| `/status` | 显示本轮服务端 token 累计（输入、输出、总数、缓存命中、推理）、usage 返回调用数和账户额度 |
| `/mcp` | 列出 MCP 服务及其工具 |
| `/debug` | 记录每一步并写出 HTML 报告 |
| `/quit` | 退出 |

Enter 提交，Alt+Enter 或 Ctrl+J 换行，`Ctrl+Z` 挂起，`Ctrl+D` 退出，Esc 中断
正在运行的任务，`/` 和 `@` 打开补全弹窗。完整键盘说明见
[界面（英文）](docs/ui.md)。

## 运行前请知悉

工具和本地 MCP 服务直接在宿主机上以当前用户权限运行，继承环境变量、文件权限和
网络访问——没有沙箱，也没有危险命令筛选。请在目标项目目录启动，首次进入目录时
确认信任，并且只执行可信任务。指向不熟悉的项目之前，请先读
[安全与状态（英文）](docs/security.md)。

## 文档

细节全部在 [`docs/`](docs/index.md)，目前为英文：

| 页面 | 内容 |
|------|------|
| [docs/index.md](docs/index.md) | 文档索引 |
| [Configuration](docs/configuration.md) | 配置文件、环境变量、输出预算、重试 |
| [Providers](docs/providers.md) | 预设、自动选择、任意 Responses 兼容端点 |
| [ChatGPT / Codex](docs/codex.md) | 订阅登录、模型、额度、凭据 |
| [Interface](docs/ui.md) | 全屏会话、命令、历史、补全、菜单、渲染 |
| [The agent loop](docs/agent-loop.md) | 工具链、完成判断、迭代上限 |
| [Tools](docs/tools.md) | 内置工具集合与结果长度限制 |
| [Searching](docs/searching.md) | `rg`、`grep`、`fd`、`find` |
| [Patching](docs/patching.md) | `apply_patch` 与 unified diff |
| [HTTP requests](docs/http.md) | `http` 工具 |
| [Sub-agents](docs/subagents.md) | 子 agent 与检查点 |
| [MCP servers](docs/mcp.md) | `mcp.json` 与工具懒加载 |
| [Debug tracing](docs/debug.md) | `--debug`：每一步记录与 HTML 报告 |
| [Sessions](docs/sessions.md) | 持久会话、`--resume`、上下文 |
| [Plan](docs/plan.md) | 进行中工作的清单 |
| [Memory](docs/memory.md) | 跨会话的长期记忆 |
| [Security and state](docs/security.md) | 执行策略、目录信任、状态目录、临时目录 |
| [Development](docs/development.md) | 构建、测试、项目结构 |

## 测试

```bash
zig build test              # 单元测试
zig build test-integration  # 构建二进制并运行 tests/ 下的 Python 集成测试
```

详见 [Development](docs/development.md#tests)。
