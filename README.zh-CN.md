# task-board 任务板

装在 Claude 桌面应用 **Code** 标签里的一块任务板，显示在输入框上方，把你所有 Claude Code 对话的情况并排摆出来：哪些在跑、哪些在等你、哪些做完了，以及做完的对话提示缓存还剩多久。

[English](README.md)

![任务板：左边是在跑的对话，右边是做完的对话](docs/board.png)

点开一张在跑的卡片，可以看到它的任务清单（按阶段分组）、每一步用了多久、主对话用的模型，以及每一步派出去的子代理：

![一个对话的明细：阶段、步骤、子代理和主模型](docs/details.png)

## 显示什么

**Running**（左栏）：每个正在进行的对话一张卡片。

| 颜色 | 状态 | 含义 |
| --- | --- | --- |
| 蓝 | `43%` / `running` | 正在干活；百分比是任务清单的完成度 |
| 黄 | `needs input` | 在等你：授权框、向你提问，或 MCP 表单 |
| 浅蓝 | `waiting` | 停在一个跑得久的工具调用上，不需要你 |

卡片上还有已用时间、正在跑的子代理数和 token 用量。右上角的小圆环是账号 5 小时额度的用量（设置页 Usage 里的 *Current session*），旁边写着多久后重置。

**Done**（右栏）：做完的对话，显示提示缓存还剩多久。缓存过期后再发消息，要把整个上下文重新写一遍，所以看这个就知道哪些对话现在接着聊还便宜。当前所在的对话缓存快过期时，会弹一次提醒。

操作：

- 点卡片，跳到那个对话。
- 点在跑卡片上的小箭头，在任务板上方展开明细：
  - 阶段条；
  - 每一步一行，带耗时；
  - 子代理列在派它出去的那一步下面，写类型、模型、推理强度、正在用的工具、任务、调用次数和用时；
  - 最下面一行 **Main**，写主对话自己的模型和推理强度。没有子代理时会写明 “no subagents this turn”。
- 点已完成卡片上的眼睛图标可以隐藏它；那个对话再有新请求时会自动回来。**Details**（或 `/task-board`）会打开一个窗口，列出最近所有对话（包括隐藏的），可以点 **Unhide** 恢复。
- **Suggest next step**（默认开着，一个开关管所有对话）：每轮回答后，额外请求一次，猜三条你可能想说的下一句。点一下就填进输入框，不会自动发送。每轮会多花一次请求，不需要的话在任务板上把它关掉。

## 使用条件

- **Windows 10 或 11**。后台扫描用的是 Windows 自带的 PowerShell 5.1。
- **Claude 桌面应用的 Code 标签**。任务板是为桌面端画的；在终端里只显示一行简化版。
- 能加载 hooks 模块插件（mod）的 Claude Code 版本。本插件在 Claude Code 2.1.289 上开发和测试。
- 用量圆环要有 Claude 订阅账号才有数据，没有时不显示。

## 安装

```bash
claude plugin marketplace add unopot/Claude-WINdesktop-task-board
```

```bash
claude plugin install task-board@unopot-mods
```

然后完全退出 Claude 桌面应用（包括右下角托盘图标），再重新打开。发第一条消息后几秒钟，输入框上方就会出现任务板。

以后更新：

```bash
claude plugin marketplace update unopot-mods
```

```bash
claude plugin update task-board@unopot-mods
```

## 可选：按阶段分组

任务板读的是 Claude 做多步任务时建的任务清单。想看到阶段条，需要打开任务清单工具，并让 Claude 在任务标题前加阶段名：

1. 在 `~/.claude/settings.json` 里加上：

   ```json
   { "env": { "CLAUDE_CODE_ENABLE_TODO_TOOLS": "1" } }
   ```

2. 在 `~/.claude/CLAUDE.md` 里加一段：

   ```markdown
   多步任务（3 步以上）用 TaskCreate 建清单，标题写成 `阶段名: 步骤名`
   （阶段名短，如 `Survey: Read files`），同一阶段的步骤连着建；
   开始做一步就标 in_progress，做完马上标 completed。
   ```

不做这两步也完全能用，只是明细里的步骤不分阶段。

## 设置

在 Claude Code 里运行 `/plugin configure task-board@unopot-mods`：

| 设置 | 默认值 | 说明 |
| --- | --- | --- |
| 提示缓存有效期 | 60 分钟 | 订阅账号 60；按量付费的 API 一般是 5 |
| 缓存过期前提醒 | 5 分钟 | 填 0 不提醒 |
| 回答太短不给建议 | 80 个字符 | 回答更短时不生成建议，也不多花请求 |
| 建议里可以用技能和斜杠命令 | 开 | 建议可以是 `/某个技能` |

## 原理和隐私

- 每个对话会启动一个小的 PowerShell 进程，每 3 秒增量读取 `~/.claude/projects` 下的对话记录，再读桌面应用的会话列表拿标题和跳转链接。数据不离开你的电脑，插件自己不发任何网络请求。
- 对话弹出授权框、`AskUserQuestion` 提问或 MCP 表单时，会给自己打上 needs input 标记；那次调用结束或这一轮结束就清掉。
- 会在 `~/.claude` 下写三样小东西，卸载后可以手动删除：
  - `task-board-prefs.json`：开关和隐藏的对话；
  - `task-board-usage.json`：最新的用量读数，各对话共用；
  - `task-board-input/` 文件夹：needs input 标记。

## 已知限制

- 目前只支持 Windows。
- 插件收不到“你点了批准”的那一刻，所以批准一个要跑很久的命令后，卡片会保持黄色，直到那个命令跑完。
- 子代理是按它开始时正在进行的那一步来归属的；在两步之间派出的子代理列在 **Main** 下面。

## 卸载

```bash
claude plugin uninstall task-board@unopot-mods
```

```bash
claude plugin marketplace remove unopot-mods
```

## 开发

插件在 [`task-board/`](task-board) 文件夹里，仓库根目录就是它的插件市场。

```bash
claude plugin validate task-board
```

```bash
claude plugin test task-board
```

## 许可证

[MIT](LICENSE) © 2026 unopot
