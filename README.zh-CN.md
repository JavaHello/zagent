# zagent

用 Zig 0.17 编写的命令行工作助手，支持编写代码、编辑 Markdown/文本文件、分析数据和执行任务。通过 DeepSeek 或其他兼容 Responses 的 API 调用模型。

## 构建与运行

需要 Zig 0.17。工具和本地 MCP 服务直接在宿主机运行，不需要额外的隔离后端。

```sh
zig build
zig-out/bin/zagent --help

export DEEPSEEK_API_KEY='你的 API key'
cd /path/to/project
/path/to/zagent/zig-out/bin/zagent
```

只导出 `DEEPSEEK_API_KEY` 即可自动选择 DeepSeek；同时存在多个服务商的 key 时，可以显式设置 `AI_PROVIDER=deepseek`。

每次收到用户请求后，先通过一次无工具的模型请求分析任务目标和执行方式，展示简短思路，再开始执行。终端标题使用生成的任务摘要而非用户输入原文，并显示执行状态（思考、工具调用、完成检查或等待输入）；完整标题按 Unicode 字符计数保持少于 80 字。规划失败时使用通用标题，不影响继续执行。任务结束后显示就绪，出错时显示错误；正常退出时恢复原标题（需终端支持标题栈）。stderr 重定向时不发送标题控制序列。

启动时会打印 zagent 艺术字，使用终端主题提供的 ANSI 标准青色，不使用自定义 RGB、256 色或渐变。界面的其他语义配色同样使用终端标准色，随终端主题变化。标准输出不是终端、`TERM=dumb` 或 `NO_COLOR` 非空时不加颜色；窗口窄到放不下完整字形时，改用单行 `✦ zagent`。

```sh
AI_PROVIDER=deepseek /path/to/zagent/zig-out/bin/zagent '分析项目结构，修复问题并运行测试'
/path/to/zagent/zig-out/bin/zagent '整理当前目录中的会议记录，生成行动项文档'
/path/to/zagent/zig-out/bin/zagent '分析 sales.csv，检查缺失值并撰写报告'
```

支持 `AI_URL`、`AI_MODEL`、`AI_KEY` 覆盖服务商默认值。主对话和完成检查统一调用 `POST <AI_URL>/responses`，不会回退到 Chat Completions。`AI_URL` 填基础地址，不包含 `/responses`；`AI_MODEL` 原样发送。`AI_MAX_TOKENS` 对应 Responses 的初始 `max_output_tokens`（默认 8192，即 DeepSeek 对话模型的上限）。响应因 token 上限被截断时，保持输入不变，自动将预算翻倍重试，最多重试 3 次，自动增长上限为 8192；不会执行截断响应中的工具调用。默认值已等于该上限，因此只有把 `AI_MAX_TOKENS` 配得更小时才会触发翻倍。若文本仍被截断，zagent 会保留已生成的部分，并让模型从断点继续（最多 8 次）；被截断的工具调用则改为要求模型分步重试（最多 2 次）。全部失败后才打印已生成内容并以 `ResponseTruncated` 结束。

工具定义使用 Responses 的扁平结构，工具结果通过 `call_id` 关联。请求设置 `store: false`，保留并回放全部输出 items（包括加密推理数据）；会话恢复也保留这些数据。旧版会话的消息、函数调用和结果会转换为 Responses 输入，旧的自由文本 `reasoning_content` 不会作为推理 item 发送。

配置文件位于 `$XDG_CONFIG_HOME/zagent` 或 `~/.config/zagent`，也支持该目录内的 `config` 文件；环境变量优先。支持 `AI_PROVIDER`、`AI_URL`、`AI_KEY`、`AI_MODEL`、`AI_MAX_TOKENS`、`AI_MAX_ITERATIONS`、`AI_MAX_VERIFICATIONS`、`AI_MARKDOWN`、`AI_COMPACT_THRESHOLD`、`AI_COMPACT_KEEP`、`AI_MEMORY`、`AI_MEMORY_AUTO`。完整配置见 [zagent.example.conf](zagent.example.conf)。不要将 key 写入版本库。

## 复制文本

在对话区拖动选择文字，松开后请求复制。普通终端使用 OSC 52；tmux 内使用 `tmux load-buffer -w -`（需要 tmux 3.2+ 且 `tmux` 在 PATH 中），同时写入 tmux 缓冲区并请求同步系统剪贴板，无需开启 `allow-passthrough`，默认 `set-clipboard external` 即可。

终端必须支持并允许 OSC 52 写入剪贴板，SSH 场景也一样。若 tmux 未识别终端支持，需要为对应终端配置 `clipboard` terminal feature。界面显示“已请求复制”，不代表系统剪贴板已确认写入；tmux 命令失败会显示错误提示。

## 工具执行策略

所有文件读写、补丁、目录搜索、HTTP 和 shell 工具直接在当前工作目录执行，继承宿主机环境变量（包括凭据）、文件权限和网络权限。请在目标项目目录启动，并仅执行可信任务。

- 不设沙箱或危险命令筛选，工具可以凭当前用户权限修改宿主机系统。
- 本地 stdio MCP 服务也直接执行，继承宿主环境；配置中的 `env` 用于添加或覆盖环境变量。
- 内置命令工具为 `bash`，通过 `bash --noprofile --norc -c` 执行，支持 Bash 语法；不再支持旧名称 `shell`。
- 工具保留输出限制、进程组清理和超时：默认 180 秒，shell 的 `timeout_seconds` 可设为 1–3600 秒。后台进程不跨调用保留；工具使用宿主机临时目录。Zig 缓存保存在 `.zig-cache/global`。

内置文件工具仅使用 `read`、`write` 和 `ls`，不再支持旧名称。`write` 使用 `content` 创建文件或完整覆盖，使用 `old_text` / `new_text` 精确替换唯一文本块，两种模式不能混用。搜索工具在启动时按 PATH 动态选择：安装了 `rg` 则优先加载 `rg`，否则加载 `grep`；安装了 `fd` 则优先加载 `fd`，否则加载 `find`。只向模型暴露选中的名称，提示词同步调整。

`read` 支持可选的 `start_line` / `end_line`，行号从 1 开始且包含两端；默认从第 1 行读到文件末尾。实现流式跳过前面的行，可读取超过 1 MiB 文件的后部，无需把整个文件载入内存。输出仍限制在约 8192 字节，截断时提示当前行，建议缩小行范围继续读取；单行超过输出限制时仍不能完整返回。`rg` / `grep` 支持 `context_lines`（匹配前后各多少行，非负整数，默认 0）和 `max_matches`（每个文件最多匹配多少行，正整数，默认不限），搜索结果仍受输出字节限制。

局部修改可使用 `write` 做精确文本替换：只匹配一次才写入，匹配不到或存在歧义时保留原文件，写入以原子替换完成并保留权限。多文件修改也支持严格校验的 unified diff；外层的 `*** Begin Patch` / `*** End Patch` 标记可以省略。

## 长任务与恢复

首次进入目录时，zagent 会先询问是否信任该目录，授权前不加载工作区数据、不请求 API、不启动 MCP。必须在终端中输入 `yes` 才会继续，其它回答或 EOF 均退出；管道输入不能授权。信任状态全局保存，下次进入相同目录不再询问，脚本或管道调用前需先交互授权。`--help`、`--version` 和 `models` 管理命令无需授权。信任只表示同意工具以当前用户权限直接执行，不提供代码隔离。

信任、记忆和会话统一保存到 `$XDG_STATE_HOME/zagent/workspaces/<目录规范路径的 SHA-256>/`，未设置时使用 `~/.local/state/zagent/workspaces/<hash>/`。其中 `trusted` 保存完整规范路径并在加载时校验，`memory.md` 保存记忆，`sessions/<id>.json` 保存会话。符号链接别名共用状态，不同目录相互隔离，移动项目会产生新身份。删除对应的 `trusted` 文件可要求下次重新授权。

不读取或迁移项目本地 `.zagent/` 中的记忆和会话。

默认每次启动都会创建一个独立会话 ID，并保存到上述全局目录中的 `sessions/<id>.json`。启动时显示 ID 和恢复命令，`/session` 可再次查看；`/new` 创建新 ID，保留旧会话，`/clear` 只清空当前会话。每批工具完成后及最终回答后都会自动保存，无需等待正常退出。恢复时请进入原工作目录：

```sh
zagent --resume <会话id>
zagent --resume <会话id> "继续任务"
```

恢复会沿用原 ID 和对话上下文；不存在、损坏或格式不合法的 ID 会报错，不会创建空会话。不要将包含敏感内容的会话文件提交到版本库，也不要同时在多个进程中恢复同一个 ID。

会话与原工作目录绑定。会话文件以 `0600` 权限创建，包含任务内容、工具调用和结果，不包含 API 配置。中断发生在工具运行期间时，文件修改可能已经生效；恢复后应检查实际工作目录。

## 上下文压缩与记忆

对话变长后，上下文会超出模型能容纳的范围。zagent 在每次请求前（以及工具循环的每次迭代之间）估算对话大小；超过 `AI_COMPACT_THRESHOLD`（默认 48000 个估算 token）时，把较早的消息替换为一段模型生成的摘要，并原样保留最新的 `AI_COMPACT_KEEP` 条消息（默认 16 条）。摘要按大小分块生成，每块都带上已有摘要，因此压缩很长的历史也不需要一次超大请求。切分点只会落在不会拆散“工具调用 + 工具结果”的位置；如果模型没能给出可用摘要，历史保持不变，本轮继续运行。`/compact` 可手动触发同样的操作。设置 `AI_COMPACT_THRESHOLD=0` 可关闭自动压缩。

全局工作区状态目录中的 `memory.md` 保存按目录关联的跨会话长期记忆，格式是可直接阅读和编辑的 Markdown 列表。模型在关键点调用 `remember` 工具、用户执行 `/remember <文本>`，或每轮结束后的保守提取器判断出现了值得长期保存的信息时，都会写入一条笔记。重复内容会被忽略，最多保留 200 条，每条 500 字节。启动时会把最新的笔记注入系统提示（有固定预算，不会挤掉主要指令）。`/memory` 列出笔记，`/forget <序号>` 或 `/forget all` 删除。记忆文件读写失败不会影响正常对话；`AI_MEMORY=0` 关闭该功能，`AI_MEMORY_AUTO=0` 只关闭每轮自动提取，`AI_MEMORY_FILE` 可指定其它文件。

交互模式支持 `/help`、`/model`、`/status`、`/mcp`、`/compact`、`/memory`、`/remember`、`/forget`、`/clear`、`/quit`。`/status` 显示当前模型、最近一轮的输入/输出 token 数（服务端统计或本地估算）；Codex 模式还会查询 ChatGPT 订阅额度，显示各时间窗口的已用/剩余比例和重置倒计时。其他服务商的账户额度请查看其计费控制台。该命令不调用模型、不消耗对话 token；额度查询失败不会影响对话。`/clear` 同时清空持久化会话。单次查询模式将回答直接写入标准输出，可用于重定向生成文档。

在终端中运行时，交互会话会占满整个屏幕：banner 和对话在上方滚动，输入提示固定在最下方一行，输入多行内容时输入区向上扩展。程序使用终端备用屏幕，退出后 shell 原有内容和回滚记录原样恢复。

按 `Ctrl+Z` 会像其它前台程序一样挂起 zagent：先交还终端，回到 shell；执行 `fg` 后重新进入全屏、重绘完整对话记录，并恢复挂起前正在输入的内容。回答流式输出期间按 `Ctrl+Z` 也会这样恢复。标准输出不是终端（管道或文件）时不启用全屏，仍按原来的内联方式输出。

输入支持多行：Enter 提交，Alt+Enter 或 Ctrl+J 插入换行，输入区随之向上增长。支持括号粘贴的终端会将整段粘贴保留在输入框中，粘贴内的换行不会触发提交；检查后再按 Enter 发送。多行内容可在当前会话中通过历史记录找回，但不写入跨会话的输入历史文件。

在输入行开头键入 `/` 会弹出系统命令候选；在词首键入 `@` 可按路径搜索项目文件；`$` 显示“待定”占位，暂未绑定功能。候选会随输入筛选，用 ↑/↓ 选择、Tab 或 Enter 填入、Esc 关闭，填入后再次按 Enter 提交。文件选择插入 `@路径` 引用（含空格的路径加引号），不会自动附加文件内容。搜索跳过 `.git`、构建缓存、`node_modules` 等目录，并限制遍历量。

按 **Esc** 可中断当前任务、终止正在运行的工具并清空排队问题，保留正在编辑的文字。若补全弹窗已打开，Esc 只关闭弹窗。已完成的操作不会回滚。

需要你选择方案时，`ask_user` 和完成检查会显示交互菜单：用 ↑/↓、j/k 或 Tab 切换，回车确认，也可按数字键 1–9 定位。默认选中推荐项，没有推荐项则选中第一项；选择“自定义回答”可输入文字，Ctrl+C 或 Ctrl+D 取消。菜单显示在 stderr，单次查询模式也可使用。没有可用终端时自动采用推荐项，没有推荐项则交回模型处理。

达到工具迭代上限或模型输出被截断时返回错误。临时网络错误及 HTTP 408/429/500/502/503/504 最多尝试三次。默认有独立的完成检查；预算耗尽或始终读不到可用结论时返回 `CompletionUnverified`（检查请求失败或回复无法解析时，在预算内重新检查，每次尝试都计入预算）。检查只收到该回合的摘要：摘要超出上限时保留最新的工作（回答或失败原因），省略开头，确保检查能看到回合如何结束；过长的工具结果从中间截断，保留结尾的测试结论等关键证据。最后一次检查拒绝后，不再执行没有剩余额度可验证的修复回合；程序输出拒绝原因、建议的下一步（如有）和额度配置提示。可在新提问中继续修复，或在启动前调高 `AI_MAX_VERIFICATIONS`，但调高额度本身不代表任务完成。报告阻塞不等于任务完成。它是模型检查，交付前仍应运行实际测试。

若检查器确认外部前置条件不可用（如私有 Maven 父 POM 无法解析、缺少访问权限），本回合以独立的 `Task blocked` 状态正常结束（退出码 0），展示阻塞原因和解阻步骤，不重复执行、不抛出 `CompletionUnverified`，也不显示 `Task completed`。这只表示已妥善停止，不表示代码或测试已验证通过；补齐依赖后可通过新提问继续验证。

## 验证

```sh
zig build
zig build test
zig build test-integration
```

端到端测试通过本地模拟 API 驱动真实 zagent，覆盖文件编辑、补丁、搜索、工作目录隔离、符号链接逃逸、环境变量隔离、网络隔离、服务错误重试、会话恢复、执行上限退出状态和运行期间替换二进制。

完整工具及 MCP 配置说明见 [README.md](README.md)。

单元测试覆盖应用、内置行编辑器和 Unicode 宽度计算；集成测试脚本使用 Python 3、本地模拟 API 和真实终端，验证流式输出、宿主工具执行、任务完成检查、响应错误、选择菜单与补全。行编辑器位于 `src/editor`，字符宽度实现位于 `src/unicode_width`，无需本地依赖包。配置文件与通用环境变量统一使用 `AI_*` 名称。

## 使用 ChatGPT / Codex 订阅登录

无需安装 Codex CLI。运行已构建的 zagent：

```sh
zagent login
# 在任意设备的浏览器打开提示的官方页面，输入一次性设备码。
export AI_PROVIDER=codex
zagent models
# 从返回的模型列表选择账号有权使用的模型：
export AI_MODEL=gpt-5.4
zagent "查看这个项目"
zagent logout
```

这是官方 Codex 设备码授权协议的独立客户端实现，并非 OpenAI 发布的客户端。账号需要允许设备码登录；若提示不可用，请检查 ChatGPT 的设备码授权设置。无需在低内存机器上启动浏览器。

ChatGPT 订阅使用 `https://chatgpt.com/backend-api/codex/responses` 和 `/models`，不能把订阅令牌当作 `https://api.openai.com/v1` 的 API Key。`AI_PROVIDER=openai` 仍使用 API Key 访问 `/v1/responses`、`/v1/models`，计费和权限独立。Codex 模式禁止修改 `AI_URL`，`AI_KEY` 不用于该模式的认证。模型列表保持服务端原始 JSON 格式。

凭据保存在 `$HOME/.config/zagent/codex-auth.json`（权限 `0600`），请求前检查访问令牌有效期，临近过期时刷新并保存轮换后的刷新令牌。请勿分享该文件。`logout` 删除本地凭据，不撤销服务端授权。刷新失败时重新执行 `zagent login`。不读写现有 Codex CLI 的凭据。避免多个进程同时登录或刷新同一个账号。

Codex 请求使用流式响应，即使调用者只需要最终结果；系统提示转入 `instructions`，不发送该后端不支持的 `max_output_tokens`。订阅的可用模型和限额以账号及服务端返回为准；这些后端协议可能随官方客户端更新而变化。

参考：[官方认证说明](https://developers.openai.com/codex/auth)、[官方网关路由说明](https://learn.chatgpt.com/docs/enterprise/connect-to-a-gateway?gateway-auth=api-key)。
