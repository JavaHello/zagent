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

主模型通过内置工具 `announce_task` 提供 `title`（标题）和 `description`（任务目标及执行思路），无需额外的规划请求。描述直接展示给用户，标题发送到终端标题，不使用用户输入原文。提交的标题必须少于 80 个 Unicode 字符；完整终端标题（含程序名和状态）也保持少于 80 字，并过滤终端控制序列。任务结束后显示就绪并保留该任务标题，后续追问没有声明新任务时标题继续沿用上一个任务；出错时显示错误；正常退出时恢复原标题（需终端支持标题栈）。stderr 重定向时不发送标题控制序列。

启动时会打印 zagent 艺术字，使用终端主题提供的 ANSI 标准青色，不使用自定义 RGB、256 色或渐变。界面的其他语义配色同样使用终端标准色，随终端主题变化。标准输出不是终端、`TERM=dumb` 或 `NO_COLOR` 非空时不加颜色；窗口窄到放不下完整字形时，改用单行 `✦ zagent`。

```sh
AI_PROVIDER=deepseek /path/to/zagent/zig-out/bin/zagent '分析项目结构，修复问题并运行测试'
/path/to/zagent/zig-out/bin/zagent '整理当前目录中的会议记录，生成行动项文档'
/path/to/zagent/zig-out/bin/zagent '分析 sales.csv，检查缺失值并撰写报告'
```

支持 `AI_URL`、`AI_MODEL`、`AI_KEY` 覆盖服务商默认值。主对话和完成检查统一调用 `POST <AI_URL>/responses`，不会回退到 Chat Completions。`AI_URL` 填基础地址，不包含 `/responses`；`AI_MODEL` 原样发送。`AI_MAX_TOKENS` 对应 Responses 的初始 `max_output_tokens`（默认 8192，即 DeepSeek 对话模型的上限）。响应因 token 上限被截断时，保持输入不变，自动将预算翻倍重试，最多重试 3 次，自动增长上限为 8192；不会执行截断响应中的工具调用。默认值已等于该上限，因此只有把 `AI_MAX_TOKENS` 配得更小时才会触发翻倍。若文本仍被截断，zagent 会保留已生成的部分，并让模型从断点继续（最多 8 次）；被截断的工具调用则改为要求模型分步重试（最多 2 次）。全部失败后才打印已生成内容并以 `ResponseTruncated` 结束。

工具定义使用 Responses 的扁平结构，工具结果通过 `call_id` 关联。请求设置 `store: false`，保留并回放全部输出 items（包括加密推理数据）；会话恢复也保留这些数据。只接受包含当前字段的会话快照，不迁移旧格式或忽略已删除字段。自由文本 `reasoning_content` 不会作为推理 item 发送。

配置文件位于 `$XDG_CONFIG_HOME/zagent` 或 `~/.config/zagent`，也支持该目录内的 `config` 文件；环境变量优先。支持 `AI_PROVIDER`、`AI_URL`、`AI_KEY`、`AI_MODEL`、`AI_MAX_TOKENS`、`AI_MAX_ITERATIONS`、`AI_REASONING_EFFORT`、`AI_SERVICE_TIER`。完整配置见 [zagent.example.conf](zagent.example.conf)。不要将 key 写入版本库。Markdown 根据终端能力自动渲染，管道和文件输出保留原始 Markdown，无需配置开关。

## 服务商配置

`AI_PROVIDER` 选择内置预设，预设只提供未被显式设置的默认值：

| 预设 | 基础地址 | 默认模型 | Key 环境变量 |
|------|----------|----------|--------------|
| `openai` | `https://api.openai.com/v1` | `gpt-4o-mini` | `OPENAI_API_KEY` |
| `deepseek` | `https://api.deepseek.com` | `deepseek-flash` | `DEEPSEEK_API_KEY` |
| `openai-compatible` | 由 `AI_URL` 指定 | 由 `AI_MODEL` 指定 | `AI_KEY` |
| `codex` | ChatGPT 后端（见下文） | `gpt-5.4` | 无需（`zagent login`） |

`openai-compatible` 面向其他所有兼容 OpenAI Responses 的厂商，例如阿里云百炼、Moonshot、智谱，以及自建的 vLLM、LiteLLM 网关。它不预设地址和模型：必须提供 `AI_URL` 和 `AI_MODEL`，key 从 `AI_KEY` 读取，缺少哪一项会在启动时直接指出。名称大小写不敏感，也接受 `openai_compatible` 和 `compatible` 两种写法。

```sh
export AI_PROVIDER=openai-compatible
export AI_URL=https://dashscope.aliyuncs.com/compatible-mode/v1
export AI_MODEL=qwen-plus
export AI_KEY='你的百炼 API key'
```

`AI_URL` 填基础地址，不含 `/responses`；`AI_MODEL` 原样发送。服务端必须实现 Responses API，zagent 不会回退到 Chat Completions。只设置 `AI_KEY` 不会自动选中任何服务商，因为它不指向具体地址；未设置 `AI_PROVIDER` 时仍按导出的 `OPENAI_API_KEY` / `DEEPSEEK_API_KEY` 自动选择，两者都存在时 `openai` 优先。

## 复制文本

在对话区拖动选择文字，松开后请求复制。普通终端使用 OSC 52；tmux 内使用 `tmux load-buffer -w -`（需要 tmux 3.2+ 且 `tmux` 在 PATH 中），同时写入 tmux 缓冲区并请求同步系统剪贴板，无需开启 `allow-passthrough`，默认 `set-clipboard external` 即可。

终端必须支持并允许 OSC 52 写入剪贴板，SSH 场景也一样。若 tmux 未识别终端支持，需要为对应终端配置 `clipboard` terminal feature。界面显示“已请求复制”，不代表系统剪贴板已确认写入；tmux 命令失败会显示错误提示。

## 工具执行策略

每次启动自动在 `$TMPDIR`（未设置时为 `/tmp`）下创建唯一私有临时目录（权限 `0700`），并把当前工作目录与该临时目录一起写入系统提示词，不再提供 `temp_dir` 工具调用。提示词要求模型把复杂、多步骤的工作，以及会改动用户系统、系统设置或用户配置的操作放到临时目录，避免影响工作空间和宿主机，只把最终成果复制回来。目录内直接使用现有 `write`、`read`、`apply_patch`、`bash` 等工具，不引入 workspace_id 或新的文件接口。这个目录是临时的，不是长期存储：它属于当前进程，同时启动的多个 agent 各自使用不同路径，不会互相冲突，恢复会话时也会新建目录而不是沿用旧路径；`/new` 会清空目录但保留提示词中声明的路径；退出时整个目录连同其中的文件一起删除。模型也可以自行删除该目录或其中留下的文件。需要保留的内容必须在进程结束前复制到工作空间或用 `remember` 记录。临时目录不写入会话（`/status` 会显示当前路径）。这些只是普通宿主机目录，不提供沙箱隔离，也不增加授权步骤。

所有文件读写、补丁、目录搜索、HTTP 和 shell 工具直接在当前工作目录执行，继承宿主机环境变量（包括凭据）、文件权限和网络权限。请在目标项目目录启动，并仅执行可信任务。

- 不设沙箱或危险命令筛选，工具可以凭当前用户权限修改宿主机系统。
- 本地 stdio MCP 服务也直接执行，继承宿主环境；配置中的 `env` 用于添加或覆盖环境变量。
- 内置命令工具为 `bash`，通过 `bash --noprofile --norc -c` 执行，支持 Bash 语法；不再支持旧名称 `shell`。
- 工具保留输出限制、进程组清理和超时：默认 180 秒，shell 的 `timeout_seconds` 可设为 1–3600 秒。后台进程不跨调用保留；工具使用宿主机临时目录。Zig 缓存保存在 `.zig-cache/global`。
- 单次工具结果上限为 40 KiB。`read` 按页读取并给出下一页的 `offset`；`ls` 与各搜索工具在接近上限处停下并说明结果未列全，提示模型缩小调用，而不是把截断结果当作完整结果；`bash` 输出或 `http` 响应超出时在上限处截断并标注 `... (truncated)`；其余仍超限的结果（包括 MCP 服务的返回）在限长处截断并按错误返回。工具描述中不再出现任何字节数字，限制只存在于代码里。

内置文件工具仅使用 `read`、`write` 和 `ls`，不再支持旧名称。`write` 使用 `content` 创建文件或完整覆盖，使用 `old_text` / `new_text` 精确替换唯一文本块，两种模式不能混用。搜索工具在启动时按 PATH 动态选择：安装了 `rg` 则优先加载 `rg`，否则加载 `grep`；安装了 `fd` 则优先加载 `fd`，否则加载 `find`。默认只向模型暴露选中的名称，提示词同步调整。四个工具独立执行同名程序：显式调用 `rg` / `fd` 不会转用 `grep` / `find`，反之亦然；程序不存在或执行失败直接报错，不做运行时回退。搜索路径支持安全的 shell 风格 glob 展开，不执行 shell 代码。

`read` 使用 `offset`（起始行，从 1 开始）与 `limit`（读取行数）分页读取文件，默认从第 1 行开始、读到输出上限或文件末尾。返回的每一行都以文件中的行号加冒号开头、紧跟行内容（例如 `42:内容`），便于模型直接引用某一行，不必自己数行；页内只放整行，超出上限时给出下一行的 `offset`，用同一 `offset` 继续读取即可，不会重复或跳过内容。实现流式跳过前面的行，可读取超过 1 MiB 文件的后部，无需把整个文件载入内存，每页输出控制在 40 KiB 以内。单行本身超过输出上限时（例如压缩后的 JSON）只返回其开头，并按 UTF-8 字符边界截断，此时提示改用 `bash` 读取剩余部分。`rg` / `grep` 支持 `context_lines`（匹配前后各多少行，非负整数，默认 0）和 `max_matches`（每个文件最多匹配多少行，正整数，默认不限），搜索结果仍受输出字节限制。

局部修改可使用 `write` 做精确文本替换：只匹配一次才写入，匹配不到或存在歧义时保留原文件，写入以原子替换完成并保留权限。多文件修改使用 Git Unified Diff，即 `git diff` 写出、`git apply` 读取的格式：`diff --git` 及其 `index`、`similarity index`、`old mode` / `new mode`、`new file mode`、`deleted file mode`、`rename from` / `rename to` 都会被读取，`a/` / `b/` 前缀会去掉，git 加引号的路径（如 `"a/caf\303\251.txt"`）会还原成原字节，hunk 的行数由正文重新计算；上下文与删除行必须与文件精确匹配，且只允许唯一匹配，匹配不到或有两处匹配时整个补丁不落地。补丁声明的权限也会生效（包括只改权限的补丁，以及 git 为空的创建/删除文件写出的无 hunk 段）。二进制补丁、copy、符号链接和子模块补丁会被拒绝并说明原因；外层的 `*** Begin Patch` / `*** End Patch` 标记可以省略。

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

## 上下文与记忆

历史不会自动压缩：既不发起额外的摘要请求，也没有按 token 阈值触发的压缩步骤，模型也无法丢弃自己早先的工具输出——它无法可靠判断自己还需要多少上下文。要清空重来用 `/clear`。唯一的节省是免费且机械的：同一文件区段再次读取且输出完全相同时，第二次结果会被替换为一行指向先前结果的标记，而不是重复全文；助手调用与其结果始终成对保留，因为每次 Responses 请求都要为每个 `function_call` 提供对应的 `function_call_output`，且助手消息会原样重放收到的输出项。

全局工作区状态目录中的 `memory.md` 保存按目录关联的跨会话长期记忆，格式是可直接阅读和编辑的 Markdown 列表。是否保存、何时保存完全由主模型按需调用 `remember` 决定，不再每轮额外请求模型自动提取；用户也可执行 `/remember <文本>`。重复内容会被忽略，最多保留 200 条，每条 500 字节。记忆正文不再注入系统提示；模型在需要历史偏好、项目约定、决策或已知解决方案时，通过 `memory_search` 按需查询。本地关键词检索支持英文忽略大小写及中文无空格短语（相邻字符匹配），按相关性排序、同分优先较新记录；默认最多返回 5 条，可指定 1–10 条。这不是语义搜索，无匹配时可换用短关键词或同义词。`remember` 支持新增及精确替换、删除笔记。`/memory` 列出笔记，`/forget <序号>` 或 `/forget all` 删除。记忆文件读写失败不会影响正常对话；`AI_MEMORY_FILE` 可指定其它文件。

交互模式支持 `/help`、`/model`、`/status`、`/mcp`、`/memory`、`/remember`、`/forget`、`/clear`、`/quit`。`/status` 显示当前模型、最近一轮的输入/输出 token 数（服务端统计或本地估算）；Codex 模式还会查询 ChatGPT 订阅额度，显示各时间窗口的已用/剩余比例和重置倒计时。其他服务商的账户额度请查看其计费控制台。该命令不调用模型、不消耗对话 token；额度查询失败不会影响对话。`/clear` 同时清空持久化会话。单次查询模式将回答直接写入标准输出，可用于重定向生成文档。

在终端中运行时，交互会话会占满整个屏幕：banner 和对话在上方滚动，输入提示固定在最下方一行，输入多行内容时输入区向上扩展。程序使用终端备用屏幕，退出后 shell 原有内容和回滚记录原样恢复。

按 `Ctrl+Z` 会像其它前台程序一样挂起 zagent：先交还终端，回到 shell；执行 `fg` 后重新进入全屏、重绘完整对话记录，并恢复挂起前正在输入的内容。回答流式输出期间按 `Ctrl+Z` 也会这样恢复。标准输出不是终端（管道或文件）时不启用全屏，仍按原来的内联方式输出。

输入支持多行：Enter 提交，Alt+Enter 或 Ctrl+J 插入换行，输入区随之向上增长。支持括号粘贴的终端会将整段粘贴保留在输入框中，粘贴内的换行不会触发提交；检查后再按 Enter 发送。多行内容可在当前会话中通过历史记录找回，但不写入跨会话的输入历史文件。

在输入行开头键入 `/` 会弹出系统命令候选；在词首键入 `@` 可按路径搜索项目文件；`$` 显示“待定”占位，暂未绑定功能。候选会随输入筛选，用 ↑/↓ 选择、Tab 或 Enter 填入、Esc 关闭，填入后再次按 Enter 提交。文件选择插入 `@路径` 引用（含空格的路径加引号），不会自动附加文件内容。搜索跳过 `.git`、构建缓存、`node_modules` 等目录，并限制遍历量。

任务运行期间输入框仍然可用：此时输入的内容不会排在任务后面等待，而是直接交给正在运行的任务，随它的下一次请求发给模型，用来实时调整正在进行的工作，不必等任务结束后再问一遍。已经在流式输出的回答不会被打断，这段输入会跟随之后的请求生效。只读命令（`/help`、`/model`、`/status`、`/mcp`、`/session`）仍可立即执行；会改变会话状态的命令需等任务结束后再执行。

按 **Esc** 可中断当前任务、终止正在运行的工具并丢弃任务运行期间输入的内容，保留正在编辑的文字。若补全弹窗已打开，Esc 只关闭弹窗；若问题菜单已打开，Esc 只在问题内部后退（从自定义输入退回选项列表，再从列表放弃该问题），任务继续运行。已完成的操作不会回滚。

需要你选择方案时，`ask_user` 会显示交互菜单：用 ↑/↓ 或 j/k 在问题内切换，回车确认，也可按数字键 1–9 定位。默认选中推荐项，没有推荐项则选中第一项；最后一行的“自定义回答”选中后可输入文字，输入时按 Esc 退回选项列表重新选择。在全屏模式下，问题占据输入行原来的位置、并接管键盘：菜单打开期间输入框不可用，所按的键只作用于菜单，不会被当成对运行中任务的指示。

模型一次提出多个问题时，它们会画成同一张表单，用 Tab / Shift+Tab 在问题之间来回：

```
  1/3 采用哪种方案？  → 原地重写
  2/3 跑哪些测试？  → 全量
  3/3 还有别的要交代吗？
    > 1) 没有
      2) 有（推荐）
      3) 自定义回答
  Tab/Shift+Tab 切换问题 · ↑/↓ 选择 · 回车确认 · Esc 取消
```

回车确认当前问题并跳到下一个还没回答的，回答完最后一个即提交；已回答的问题会显示所选答案，按 Tab 或 Shift+Tab 可以回到它继续修改，选错了在提交前都还能改。只有当前问题显示选项行，问题再多也不会把对话挤出屏幕。离开表单时，已经回答的问题保留答案，其余按放弃处理。

Ctrl+D 或 Esc 放弃表单并让模型自行决定后续，任务继续运行；Ctrl+C 在提问期间不作退出用（习惯性按下不会丢掉问题）。要中断任务，回到提示符后再按 Esc。菜单显示在 stderr，单次查询模式也可使用。没有可用终端时自动采用推荐项，没有推荐项则交回模型处理。

达到工具迭代上限或模型输出被截断时返回错误。临时网络错误及 HTTP 408/429/500/502/503/504 最多尝试三次。完成与否由主模型自行判断，不再额外调用 verifier，也不在最终回答后自动启动修复回合。没有工具调用的最终回答直接结束当前回合（退出码 0），无需输出状态标记，也不解析回答文本来判断状态。终端显示 `Turn finished` 只表示回合结束，不代表实际工作一定成功。模型应在完成实际工作及必要验证后再宣称成功，并在回答中说明部分完成、失败、权限或依赖缺失以及需要用户决策的情况。

阻塞、失败、等待用户输入和暂停分别显示不同状态，正常结束当前回合（退出码 0），不显示 `Task completed`；模型应说明原因和下一步。完成声明不能替代实际测试。

## 验证

```sh
zig build
zig build test
zig build test-integration
```

端到端测试通过本地模拟 API 驱动真实 zagent，覆盖文件编辑、补丁、搜索、工作目录隔离、符号链接逃逸、环境变量隔离、网络隔离、服务错误重试、会话恢复、执行上限退出状态和运行期间替换二进制。

MCP 只支持 `2026-07-28` 协议。发现失败或服务仅支持旧协议时直接报错，不再回退到 `initialize` 握手，也不保存或回传旧协议的 HTTP session ID。

MCP 使用上下文懒加载：启动时仍连接服务、发现工具，但模型初始只接收服务名称、简短描述和 `load_mcp_tools` 入口。用户问题需要某个服务时，模型按名称加载，后续请求才包含该服务的工具描述和参数 schema；已加载服务在当前进程内持续可用。可在 `mcp.json` 的服务项中设置 `description`，未设置时回退到服务 instructions 的摘要（目录描述最多 320 字节）；完整 instructions 在加载时返回。这不延迟服务启动或连接。

启动 MCP 服务时只即时显示 `⚙ mcp: starting "…"` 等进度行；连接结果的 `✓` / `✗` 报告画在艺术字下方（`Model` 行之上），因为交互式会话随后会接管整个终端、从空屏开始，连接时写出的行会被清掉。

完整工具及 MCP 配置说明见 [README.md](README.md)。

单元测试覆盖应用、内置行编辑器和 Unicode 宽度计算；集成测试脚本使用 Python 3、本地模拟 API 和真实终端，验证流式输出、宿主工具执行、任务完成检查、响应错误、运行中输入实时介入任务、选择菜单与补全。行编辑器位于 `src/editor`，字符宽度实现位于 `src/unicode_width`，无需本地依赖包。配置文件与通用环境变量统一使用 `AI_*` 名称。

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

Codex 模式可在配置文件或环境变量中设置以下可选项（环境变量优先）：

```ini
AI_REASONING_EFFORT=high
AI_SERVICE_TIER=fast
```

分别透传为 `"reasoning":{"effort":"high"}` 和 `"service_tier":"fast"`。未配置或有效值为空时不发送对应字段，其他服务商不发送这两个选项。具体值是否可用由模型和服务端决定。

参考：[官方认证说明](https://developers.openai.com/codex/auth)、[官方网关路由说明](https://learn.chatgpt.com/docs/enterprise/connect-to-a-gateway?gateway-auth=api-key)。
