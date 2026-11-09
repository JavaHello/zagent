# zagent

用 Zig 0.17 编写的命令行工作助手，支持编写代码、编辑 Markdown/文本文件、分析数据和执行任务。通过 DeepSeek 或其他兼容 Responses 的 API 调用模型。

## 构建与运行

需要 Zig 0.17，以及 Linux 的 bubblewrap（和 GNU coreutils）或 macOS 自带的 `sandbox-exec`。工具启动失败时会返回错误，不会退回宿主机执行。

```sh
zig build
zig-out/bin/zagent --help

export DEEPSEEK_API_KEY='你的 API key'
cd /path/to/project
/path/to/zagent/zig-out/bin/zagent
```

只导出 `DEEPSEEK_API_KEY` 即可自动选择 DeepSeek；同时存在多个服务商的 key 时，可以显式设置 `AI_PROVIDER=deepseek`。

终端标题会显示当前任务摘要及执行状态（思考、工具调用、完成检查或等待输入）。任务结束后显示就绪，出错时显示错误；正常退出时恢复原标题（需终端支持标题栈）。stderr 重定向时不发送标题控制序列。

启动时会打印 zagent 艺术字，每个字符单独着色：从左上角的青色到右下角的品红，形成一条对角渐变。`COLORTERM` 为 `truecolor` 或 `24bit` 时使用 24 位真彩色，否则退回 256 色调色板；标准输出不是终端、`NO_COLOR` 非空，或窗口窄到放不下这些字形时，改用单行 `✦ zagent` 且不加颜色。

```sh
AI_PROVIDER=deepseek /path/to/zagent/zig-out/bin/zagent '分析项目结构，修复问题并运行测试'
/path/to/zagent/zig-out/bin/zagent '整理当前目录中的会议记录，生成行动项文档'
/path/to/zagent/zig-out/bin/zagent '分析 sales.csv，检查缺失值并撰写报告'
```

支持 `AI_URL`、`AI_MODEL`、`AI_KEY` 覆盖服务商默认值。主对话和完成检查统一调用 `POST <AI_URL>/responses`，不会回退到 Chat Completions。`AI_URL` 填基础地址，不包含 `/responses`；`AI_MODEL` 原样发送。`AI_MAX_TOKENS` 对应 Responses 的初始 `max_output_tokens`（默认 8192，即 DeepSeek 对话模型的上限）。响应因 token 上限被截断时，保持输入不变，自动将预算翻倍重试，最多重试 3 次，自动增长上限为 8192；不会执行截断响应中的工具调用。默认值已等于该上限，因此只有把 `AI_MAX_TOKENS` 配得更小时才会触发翻倍。若文本仍被截断，zagent 会保留已生成的部分，并让模型从断点继续（最多 8 次）；被截断的工具调用则改为要求模型分步重试（最多 2 次）。全部失败后才打印已生成内容并以 `ResponseTruncated` 结束。

工具定义使用 Responses 的扁平结构，工具结果通过 `call_id` 关联。请求设置 `store: false`，保留并回放全部输出 items（包括加密推理数据）；会话恢复也保留这些数据。旧版会话的消息、函数调用和结果会转换为 Responses 输入，旧的自由文本 `reasoning_content` 不会作为推理 item 发送。

配置文件位于 `$XDG_CONFIG_HOME/zagent` 或 `~/.config/zagent`，也支持该目录内的 `config` 文件；环境变量优先。完整配置见 [zagent.example.conf](zagent.example.conf)。不要将 key 写入版本库。

## 工具沙箱

文件读写、补丁、目录搜索、HTTP 和 shell 工具都在独立沙箱内执行。本地 MCP 服务也使用该边界。

- 启动 zagent 时所在的工作目录可读写。其他项目、宿主机 home、进程和凭据不挂载到沙箱。
- 系统程序与库只读。Linux 下 `/usr`（含 `/bin`、`/sbin`、`/lib`）只读；macOS 下 `/usr`、`/bin`、`/sbin`、`/System`、`/Library`、`/private/etc`、`/dev` 以及 `/opt/homebrew` 只读。工具不继承 API key 等宿主机环境变量；MCP 只额外接收配置里显式声明的 `env`。
- 工作目录中已有的文件都对工具开放，包括放在其中的凭据；请据此选择工作目录。
- 默认禁止工具访问网络。需要下载或联网安装依赖时，由使用者设置 `AI_TOOL_NETWORK=1`。它会开放宿主机网络，包括本地服务。模型 API 和显式配置的远程 MCP 服务由主进程联网。
- 单个命令默认最多运行 180 秒；shell 工具可用 `timeout_seconds` 设置 1–3600 秒。后台进程和临时目录不跨工具调用保留；工作目录中的文件保留。Zig 缓存保存在 `.zig-cache/global`。
- Linux 下可在单个 shell 调用中启动测试服务和客户端，使用沙箱内的回环网络。

局部修改可使用 `edit_file` 做精确文本替换：只匹配一次才写入，匹配不到或存在歧义时保留原文件，写入以原子替换完成并保留权限。多文件修改也支持严格校验的 unified diff；外层的 `*** Begin Patch` / `*** End Patch` 标记可以省略。

## 长任务与恢复

通过 `AI_SESSION_FILE` 启用会话保存。每批工具完成后及最终回答后都会写入快照；再次使用同一文件可恢复对话。会话与原工作目录绑定。

```sh
export AI_SESSION_FILE="$HOME/.local/state/zagent/my-project.json"
zagent '实现需求并测试'
# 中断或退出后，在同一个工作目录继续：
zagent '继续完成，检查已有文件和测试结果'
```

建议把会话文件放在工具工作目录之外，避免工具修改。文件包含任务内容、工具调用和结果，不包含 API 配置。不要让多个进程同时使用同一会话文件。中断发生在工具运行期间时，文件修改可能已经生效；恢复后应检查实际工作目录。

交互模式支持 `/help`、`/model`、`/mcp`、`/clear`、`/quit`。`/clear` 同时清空持久化会话。单次查询模式将回答直接写入标准输出，可用于重定向生成文档。

在终端中运行时，交互会话会占满整个屏幕：banner 和对话在上方滚动，输入提示固定在最下方一行，输入多行内容时输入区向上扩展。程序使用终端备用屏幕，退出后 shell 原有内容和回滚记录原样恢复。

按 `Ctrl+Z` 会像其它前台程序一样挂起 zagent：先交还终端，回到 shell；执行 `fg` 后重新进入全屏、重绘完整对话记录，并恢复挂起前正在输入的内容。回答流式输出期间按 `Ctrl+Z` 也会这样恢复。标准输出不是终端（管道或文件）时不启用全屏，仍按原来的内联方式输出。

输入支持多行：Enter 提交，Alt+Enter 或 Ctrl+J 插入换行，输入区随之向上增长。支持括号粘贴的终端会将整段粘贴保留在输入框中，粘贴内的换行不会触发提交；检查后再按 Enter 发送。多行内容可在当前会话中通过历史记录找回，但不写入跨会话的输入历史文件。

在输入行开头键入 `/` 会弹出系统命令候选；在词首键入 `@` 可按路径搜索项目文件；`$` 显示“待定”占位，暂未绑定功能。候选会随输入筛选，用 ↑/↓ 选择、Tab 或 Enter 填入、Esc 关闭，填入后再次按 Enter 提交。文件选择插入 `@路径` 引用（含空格的路径加引号），不会自动附加文件内容。搜索跳过 `.git`、构建缓存、`node_modules` 等目录，并限制遍历量。

需要你选择方案时，`ask_user` 和完成检查会显示交互菜单：用 ↑/↓、j/k 或 Tab 切换，回车确认，也可按数字键 1–9 定位。默认选中推荐项，没有推荐项则选中第一项；选择“自定义回答”可输入文字，Ctrl+C 或 Ctrl+D 取消。菜单显示在 stderr，单次查询模式也可使用。没有可用终端时自动采用推荐项，没有推荐项则交回模型处理。

达到工具迭代上限或模型输出被截断时返回错误。临时网络错误及 HTTP 408/429/500/502/503/504 最多尝试三次。默认有独立的完成检查；预算耗尽或始终读不到可用结论时返回 `CompletionUnverified`（检查请求失败或回复无法解析时，在预算内重新检查，每次尝试都计入预算）。检查只收到该回合的摘要：摘要超出上限时保留最新的工作（回答或失败原因），省略开头，确保检查能看到回合如何结束；过长的工具结果从中间截断，保留结尾的测试结论等关键证据。报告阻塞不等于任务完成。它是模型检查，交付前仍应运行实际测试。

## 验证

```sh
zig build
zig build test
python3 tests/sandbox_integration.py
python3 tests/completion_integration.py
python3 tests/responses_failure_integration.py
python3 tests/menu_integration.py
```

端到端测试通过本地模拟 API 驱动真实 zagent，覆盖文件编辑、补丁、搜索、工作目录隔离、符号链接逃逸、环境变量隔离、网络隔离、服务错误重试、会话恢复、执行上限退出状态和运行期间替换二进制。

完整工具及 MCP 配置说明见 [README.md](README.md)。
