# ShareMouse MCP

将已配对的 Mac / Windows 桌面提供给 MCP 客户端。MCP 服务嵌入原生应用；`bridge.py` 与 `computer_client.py` 提供 stdio 接入和状态封装；截图、输入、配对仍由原生应用执行。

## 接入

1. 启动两端 ShareMouse，按现有配对流程建立连接。
2. 在接入 AI 的电脑上打开“设置 → MCP / 远程 Computer Use → 启用本机 MCP 接口”。
3. 在被控制的电脑上打开“允许 AI / 已配对设备截图并操控本机”；需要文件传输时，两端都打开“允许 MCP 复制文件与管理传输任务”。这三个权限默认关闭，分别保存。
4. Mac 需要辅助功能、输入监控与屏幕录制权限。首次开启电脑操控时，应用会调用系统屏幕录制申请；也可以点击“申请屏幕录制权限”再次进入。系统授权必须由用户确认，系统要求重新启动时照提示执行。软件不会自行修改系统权限数据库。
5. 点击“复制 MCP 接入配置”，将生成的配置粘贴到支持 stdio MCP 的客户端。需要 Python 3；Windows 的 `python` 必须指向已安装的 Python，Mac 配置使用 `/usr/bin/python3`。

复制配置包含安装位置和令牌文件路径，不含令牌正文。示意：

```json
{
  "mcpServers": {
    "ShareMouse": {
      "command": "python",
      "args": ["<安装目录>/bridge.py", "--token-file", "<应用数据目录>/mcp-token"]
    }
  }
}
```

Mac 脚本随应用包安装在 `Contents/Resources/bridge.py`；本机签名安装脚本默认安装到 `~/Applications/ShareMouse.app`，不能继续照用旧的 `/Applications/ShareMouse.app` 路径。客户端 `args` 中使用当前安装位置的完整绝对路径，不依赖 `~` 或环境变量的 shell 展开。Windows 脚本位于当前应用可执行文件旁。在接入 AI 的电脑上移动或重装应用后，重新复制配置、替换客户端已有条目，并重新连接 MCP；不需要删除配对、清除身份或重装 Python。

原生 HTTP 端点为 `http://127.0.0.1:49170/mcp`，只接受带本机 Bearer 令牌的请求。令牌文件限制为当前用户读取；不把令牌复制到远端、不开放局域网 HTTP 监听。远端调用复用已认证的 ShareMouse TLS 会话及分块通道。

## 工具未出现或无法连接时

ShareMouse 是本机安装的自定义 MCP 服务，不通过插件市场分发。排查客户端注册配置和进程，不把插件搜索结果或空的 resources 列表当作工具可用性的判断。

| 现象 | 检查与处理 |
| --- | --- |
| 没有 `mcp__ShareMouse__*`，或调用时报工具不是函数 | 客户端尚未加载服务。先检查其 command/args 与当前软件复制的配置一致；脚本不存在时修正安装路径，再刷新 MCP 连接或重新打开会话 |
| `can't open file ...bridge.py` / `No such file or directory` | 入口脚本路径失效；程序移动目录后旧配置不会自行迁移。这发生在连接服务之前，与远端控制权限无关 |
| `connection refused`，或本机没有监听 49170 | 检查 ShareMouse 是否运行、是否启用本机 MCP 接口；不要只启动 Python 桥而关闭原生应用 |
| 能列工具但看不到远端电脑 | 两端需建立已认证的 ShareMouse 连接；`local` 总是服务所在电脑，用 `list_computers` 的当前结果选择远端 |
| 远端可见，但拒绝控制 | 用 `computer_use` 的 `status` 查看占用、锁屏和注入权限；不要抢占其他客户端或盲目重发输入 |
| `needs_review:true` | 先查看返回的新图，再按新图定位；本次坐标输入可能尚未执行 |
| `application_focus_denied` | 显式应用绑定的激活步骤失败。需要桌面操作时先用 `user_mouse` 且不传 application 重新观察，后续点击也不传 application |

`codex mcp get ShareMouse --json` 可以核对 Codex 保存的启动配置，但列出配置不等于连接成功。应以新连接能列出六个默认工具、取得目标电脑画面，并观察到实际输入结果为准。DeepSeek Harness 的 stdio 条目同样必须引用现有脚本。修正配置后，已经打开的客户端可能仍需在 MCP 设置中刷新连接；不要为此终止其它 agent 的活跃接管。

Codex 的 stdio `command` / `args` 配置字段见 [OpenAI 官方说明](https://learn.chatgpt.com/docs/extend/mcp#stdio-servers)。

协议兼容 MCP 2026-07-28 的 `server/discover` / 请求元数据，以及 2025-11-25、2025-06-18、2025-03-26、2024-11-05 的 `initialize` 接入。现代请求的版本、方法和工具名 HTTP 头须与请求体一致；stdio 桥负责填入。服务只提供工具与 JSON 响应，没有资源、提示词或服务器发起的采样功能。参考 [MCP 官方规范](https://modelcontextprotocol.io/specification/2026-07-28)。


## 推荐：轻量 Computer Use

stdio 接入默认提供 6 个工具：`computer_use`、`list_computers` 和 4 个文件工具。电脑操作集中在 `computer_use`，会话 token／观察帧编号由客户端保存，截图作为 image content 返回，structuredContent 仅含状态。已有客户端需刷新 MCP 连接后加载新目录。

以下坐标和文字仅演示参数，点击位置必须按本轮返回的画面替换。先使用不绑定应用的桌面模式：

```json
{"computer":"windows","control_mode":"user_mouse","action":"observe"}
{"action":"click","x":420,"y":310}
{"action":"type","text":"Hello"}
{"action":"keypress","keys":["ENTER"]}
{"action":"click","target":"继续"}
{"action":"release"}
```

`computer` 可用设备名／ID、`local`、`windows`、`mac`；后续省略表示继续同一电脑。桌面模式不传 `application`，可点击其它可见窗口使其聚焦。显式 `control_mode:user_mouse` 且省略 `application` 会解除旧应用绑定；也可用 `application:""` 明确解除。

只有希望固定操作某个应用时才传非空 `application`。它是绑定命令，不是点击目标的备注；前台改变时会尝试恢复该应用。后续同时省略模式和应用则沿用当前绑定。窗口身份或位置变化后先返回 `needs_review` 新画面，不用旧坐标直接点击。`target` 精确匹配可交互控件名称，缺少控件时尝试 OCR；多个不同目标或无匹配返回选择／截图，不猜测。`inspect:true` 才展开 OCR／控件详情。`action:batch` 可传原动作数组，客户端自动接入最新帧。

客户端 30 秒闲置和正常断开会释放自己的控制；目标端短租约 45 秒覆盖客户端崩溃，正在执行的有界动作预留 60 秒。恢复后的坐标动作先返回新画面供审查，按名称定位则可在新帧重新解析。观察帧不匹配返回可审查画面，部分或未知输入不自动重发；用户退出后须用户再次授权才允许 `resume_authorized:true`。占用时返回持有 peer、客户端名称、剩余租期，不夺取别人的控制。旧 token 接口仍保持原有租期和保护；追加 `--advanced-tools` 可同时展示。原生 HTTP 接口仍兼容旧工具。

这是前台应用绑定与状态管理，不是独立后台输入环境；同一物理桌面的不同客户端仍需串行操作。

## 高级兼容工具

`peer_id` 来自 `list_computers`，`local` 表示 MCP 服务所在电脑。发起端与目标端可以互换。

| 工具 | 用途 |
| --- | --- |
| `list_computers` | 列出本机和已认证的在线设备 |
| `get_computer_info` | 查询系统、CPU、内存、屏幕和权限状态 |
| `open_computer` | 独占一个目标显示器，返回控制会话和初始截图 |
| `observe_computer` | 取得新截图与新的 `observation_id` |
| `get_control_status` | 查询会话摘要，不替换截图编号、不续期 |
| `computer_action` | 顺序执行一批操作，返回执行状态和新截图 |
| `release_input` | 释放按键和按钮并结束控制 |
| `close_computer` | 结束控制，条件允许时恢复原来的键鼠共享 |
| `send_files` | 复制文件 / 目录，立即返回 `task_id` |
| `list_transfers` | 查看目标电脑的传输列表 |
| `get_transfer` | 查询任务进度、状态、目的目录和错误 |
| `control_transfer` | 暂停、恢复、重试或取消任务 |

完整参数定义见 [tools.json](tools.json)。

## 截图与操作

调用顺序：`list_computers → get_computer_info → open_computer → computer_action / observe_computer → close_computer`。`open_computer` 可选 `screen_id`，缺省使用主屏。

截图以 MCP `image` 内容返回，元数据在 `structuredContent.result`，包括 `control_session_id`、`observation_id`、屏幕编号、尺寸和 `captured_at`。原生 API 默认为 PNG；默认 Windows 按桌面像素 1:1 截图，Mac 获取真实 Retina 2x 渲染截图，不可用时回退 1x；坐标按**返回截图的像素**填写。每次观察都会生成新的截图编号，即使桌面内容没有变化。保存截图时建议使用 `observation_id` 做文件名，便于区分新画面。

动作必须带当前会话和最新观察编号。一次 1–20 个动作，支持 `click`、`double_click`、`move`、`drag`、`scroll`、`keypress`、`type`、`wait`。拖动路径最多 100 个点；单次等待为 0–30000 ms 的整数，整批等待合计最多 30000 ms（预留截图与传输时间）；文字使用 Unicode，UTF-8 总量最多 128 KiB。

例如，在 Windows Edge 地址栏输入网址：

```json
{
  "peer_id": "<Windows 的 peer_id>",
  "control_session_id": "<open_computer 返回值>",
  "observation_id": "<最新截图编号>",
  "request_id": "<本次请求的 UUID>",
  "actions": [
    {"type": "keypress", "keys": ["CTRL", "L"]},
    {"type": "wait", "milliseconds": 200},
    {"type": "type", "text": "https://chat.deepseek.com"},
    {"type": "keypress", "keys": ["Enter"]},
    {"type": "wait", "milliseconds": 1500}
  ]
}
```

快捷键以**目标系统**为准：Mac 地址栏用 `CMD + L`。支持 CTRL / ALT / SHIFT / CMD / WIN、字母、数字、方向键、Enter、Escape、Tab、Backspace、Delete、Home、End、PageUp、PageDown 和 F1–F12。切换焦点或打开应用后先等待并查看截图，确认输入框已出现，再输入文字。

`execution_status: injected` 仅表示输入已交给系统；须从返回截图确认应用是否完成操作。超时返回 `remote_timeout_execution_unknown` 时，不可直接重做点击或发送消息：先观察，必要时用相同 `request_id` 和相同动作重试。当前会话只保留最近一组至四个请求的去重结果；相同编号配不同动作会拒绝，过期或已结束的会话不能重试。

会话空闲 10 分钟过期，观察 / 操作会续期。本机真实键盘、鼠标按下、滚动或移动不会结束 AI 控制，输入仍可到达本机系统；断开、锁屏、权限丢失或显示器变化也会终止。结束 / 异常时释放注入的按键和按钮。AI 操作期间暂时暂停原键鼠共享，结束后仅在仍允许的情况下恢复。返回元数据含 `control_session_idle_timeout_ms` 和目标电脑 UTC 的 `control_session_expires_at`，计时包含截图传输与画面分析时间。结束后再次调用会返回 `control_session_unavailable:<原因>`，可区分 `lease_expired`、`user_exit`、`peer_disconnected` 等；同时记录不含按键正文或会话令牌的结束日志。空闲过期后可重新 `open_computer`；用户点击 Toast 或设置页的“退出接管”后，返回 `control_session_unavailable:user_exit`；Agent 应停止操作，等待用户明确要求继续后再打开新会话。

“显示 AI 鼠标操作提示”会在操作位置显示蓝色光圈与 AI 标记，约 650 ms 淡出。提示不接收鼠标、不抢焦点、不替换用户鼠标主题，并从返回截图中排除。

MCP 工具被调用时使用软件内提示“MCP 正在被使用中”，普通查询通知 30 秒内不重复弹出。Mac 保留通知卡片；Windows 默认采用透明背景的文字提示，接管时带有“退出接管”和“隐藏”文字入口。Windows 的“设置 → MCP / 远程 Computer Use → MCP 使用提示”可切换“仅文字（透明背景）／隐藏”，立即应用并保存；提示里的“隐藏”也将偏好设为隐藏，查询、接管及结束提示均不再显示。恢复“仅文字”时，正在进行的接管提示重新显示。

隐藏提示不会结束控制会话，设置页始终显示接管状态和“退出接管”。点击“退出接管”立即停止当前批次、释放注入按键／按钮并恢复共享。文字提示没有卡片背景／边框，保留轻微文字阴影便于阅读，显示及点击文字入口不激活窗口。普通文件传输通知仍遵循原通知偏好。上述 Windows 提示修订目前为源码状态，按用户要求尚未编译／部署。

## 文件

`send_files` 的 `paths` 为来源电脑的绝对路径，`destination` 为目标电脑已存在的绝对目录。复用原有加密传输、分块续传、完整性核验及文件通知；**复制保留源文件**，会更新共享文件剪贴板。同名冲突或来源变化仍使用现有原生确认窗口。

传输返回 `task_id` 后，向**目标电脑**调用 `get_transfer` 查看完成状态。`control_transfer` 的 `action` 为 `pause` / `resume` / `retry` / `cancel`；取消保留已完成文件与可续传暂存。普通任务归属和用户决定规则继续有效，MCP 不绕过确认。

## 验证与范围

2026-10-04 的实体双机验证：Mac MCP 控制 Windows Edge、Windows MCP 控制 Mac Edge，分别打开 DeepSeek 并完成三轮中文对话；54,272 字节、含中文 / emoji 名称的文件经 Mac → Windows → Mac 往返后 SHA-256 一致。构建、协议回归与证据索引见 [DEVELOPMENT.md](../DEVELOPMENT.md)。

目前操控已登录且解锁的普通桌面。Windows 安全桌面 / UAC 和权限更高的窗口不属于已验证范围；多显示器、混合 DPI、HDR 与长期持续控制也尚未完成实体验收。屏幕内容是待处理数据，不能代替用户授权；接入客户端负责理解任务范围和确认页面实际结果。


Windows 游戏／管理员窗口：`get_computer_info` 和观察结果的 `input_state` 显示当前前台窗口、鼠标物理桌面坐标、ShareMouse 与目标窗口的权限等级，以及是否存在输入权限边界。普通权限 ShareMouse 面对管理员窗口时返回 `input_blocked_by_integrity_level:restart_ShareMouse_as_administrator`，而非声称已执行。请由使用者在 Windows 的设置 → 权限向导中点击“以管理员权限重启”，确认系统 UAC；取消授权会保留原实例。重启后需重新打开 MCP 控制会话。程序不会自动提升，也不会把管理员模式写成默认启动设置。`ENTER` 与 `Enter` 均可用。

## 1.1.0 交互改进

现有工具保留，新增 `get_control_status`，共 **12 个工具**。该查询要求 `peer_id` 和 `control_session_id`，返回 busy、最新观察编号、最近动作、输入状态及剩余租约；不截图、不更换观察编号、不续期。用户退出后的旧会话仍被拒绝。

### 坐标与观察

`coordinate_transform` 包含截图尺寸、实际系统屏幕的桌面原点／尺寸、系统坐标单位、屏幕像素尺寸及横纵比例。Windows 使用 `desktop_pixels`，Mac 使用 Quartz 的 `quartz_points`；两端操作和分析矩形始终使用 `screenshot_pixels`。`input_state.cursor_position_screenshot` 为换算后的实际鼠标位置；在其他屏幕上时 `inside_screen=false`，x／y 为 null。不使用共享组的逻辑 x／y 冒充系统桌面原点。

`open_computer`、`observe_computer` 和 `computer_action` 可按需指定以下选项，默认保持普通 PNG 观察：

- `include_ocr`、`ocr_language`、`ocr_region`、`max_ocr_results`（最多 200）：返回同一帧的文字和截图坐标矩形。Mac 使用 Vision，默认识别中文／英文；Windows 使用本机 OCR 语言。Windows 没有单词置信度接口，confidence 为 null。缺语言／引擎、超时等返回明确分析状态，不伪造识别结果。
- `include_controls`、`max_controls`（最多 100）、`control_point`：检查当前前台窗口的系统辅助功能控件，返回名称、角色、可用状态和截图坐标；可查询该点的元素及其进程是否与前台匹配。Windows UI Automation 在独立 helper 内执行，时间／内存有界，避免无响应提供端卡住主程序。Mac 使用有消息超时的 Accessibility 查询。无语义控件、权限缺失或检查期间换窗会明确标记。
- `wait_for_stable`、`stability_region`、`stability_timeout_ms`（200–5000）、`stability_interval_ms`（100–1000）、`stability_samples`（2–5）、`stability_threshold`（0–25）：对指定区域进行有界像素变化检测，返回 `stable_in_region` 或 `timeout`、采样和耗时。像素稳定不证明按钮可操作，也不保证游戏转场完成。
- `mark_cursor`、`preview_point`：在返回的 PNG 上画实际鼠标／候选点击点标记。不会移动系统鼠标或执行点击；OCR 和稳定性比较使用未标记的同一帧。

所有 OCR／控件信息跟随本次观察结果；旧帧识别不能当作新帧定位。文字框不等于按钮命中区域，游戏自绘控件可能没有可访问控件；不能保证识别同一游戏窗口内商店对晶矿的覆盖。

### 动作与批次

- `key_hold`：`keys`（1–8）和 `duration_ms`（1–5000），按下后计时、自动释放；用户退出、断线、权限／屏幕失效会中止并释放。每步结果含实际耗时。没有跨请求永久保持按键的接口。
- `move_relative`：整数 `dx`／`dy`（每轴 ±10000）、可选 `duration_ms`（0–5000）和 `steps`（1–100）。不按鼠标按钮，使用本机相对输入单位；累计位移保留整数计数，镜头响应由目标应用及灵敏度决定。
- `settle_ms`（0–5000）：批次之后、最终观察之前的可中止等待。未指定时沿用 100 ms；显式等待、按住／相对移动时长和显式 settle 合计最多 30000 ms，稳定性分析另有最长 5000 ms 的截止时间。
- `expected_window_id` 或 `require_same_window=true`：在每次输入前及连续动作中核对观察对应的窗口。变化只停止当前批次，保留会话、释放按键并返回新观察；主动切换窗口可在该动作指定 `allow_window_change=true`，后续应观察后再操作新窗口。默认不自动锁定前台，以兼容原来的应用切换流程。
- `step_results`：每步的索引、动作、状态、耗时、是否开始注入及成功注入调用数。`executed_actions` 统计完成的动作，不代表失败动作完全没有产生输入。
- `step_images=true`：最多前三步附 320 像素缩略图，不占用／替换最终观察编号；每张图以 `image_content_index` 对应 MCP image 内容。
- `checkpoint_after`（1–20）：执行到指定步数即返回，后续不自动排队执行；状态为 `checkpoint`，返回 remaining_actions。Agent 看图后用新 request_id 和新观察编号提交剩余动作，避免批末反馈被误认为中途检查。

`request_id` 去重现在包含完整语义参数（动作、窗口约束、等待、检查点及观察选项），仅会话／观察／请求定位编号不参与内容比较。相同请求重试返回原结果，不再次输入；相同编号改变语义参数仍拒绝。

### 错误与耗时

`computer_busy`、`observation_id_mismatch`、批次／坐标参数错误、`target_window_changed`、权限拒绝及会话结束分别返回；MCP 错误同时提供 `structuredContent.result.error_details`，保留原有文字和 error 字段。详情包含 code、message、retryable、next_step；观察编号不匹配含 expected_observation_id，预检拒绝明确 not_attempted，已开始但失败的动作标为 partial_or_unknown。retryable 是恢复建议，不是允许盲目重发。

结果记录 observation_duration_ms、capture_and_analysis_ms、逐步 duration_ms 和 action_to_observation_ms。它们由执行端计时，不能用游戏画面的服务器 RTT 替代，也不能从两台电脑的 UTC 时间差直接推算传输延迟。


## 1.1.1 会话获取诊断

`get_computer_info.control_state` 在没有控制 token 时也可查询：是否存在／仍有效的会话、动作是否忙、持有者 peer、屏幕、开始时间、剩余租约、`can_open` 与 `open_blocker`。查询不截图、不续期、不返回 token；`owner_matches_requesting_peer` 仅说明设备相同，同一设备的另一个 agent 仍不能接管该会话。

`open_computer` 不再返回混合错误 `computer_busy_or_input_permission_missing`。有效会话存在时返回 `computer_control_in_use`，包含同一占用摘要及 `input_outcome=not_attempted`；使用自己保存的会话继续，或等待当前持有者释放，不能循环申请／替换有效会话。桌面锁定返回 `desktop_locked_or_unavailable`，输入／输入监控／截图权限缺失分别返回对应权限错误和下一步提示。Windows 同时检查 WTS 会话锁定与输入桌面，权限中返回 `session_locked`／`session_active`；单看前台进程权限等级不能判断桌面可用。

新申请在检查占用前清理已经过期／失效／断线的旧会话，释放其按键并保留原有共享恢复规则；有效会话不会被抢占。Toast／设置的显式退出与本机误动容忍保持。


### 纯 BLE 截图与打开请求确认

网络截图继续 PNG；只有 BLE 时截图以同尺寸 JPEG 返回，mime_type 为 image/jpeg，尺寸和坐标映射以本次返回为准。平台编码最大 300 KB，不能编码到传输预算则返回 ble_screenshot_too_large_connect_network；不降低工具坐标验证标准。

新 peer 协商 computer-open-ack-v1：完整打开回复需匹配请求确认，未确认 45 秒回收，60 秒客户端超时发关联取消。remote_timeout_execution_unknown 的 error_details 包含 request_id、input_outcome、cleanup_requested 与 query_control_status_before_retry；open 没有鼠标／键盘动作，仍可能曾暂停共享。get_control_status 无控制令牌时仅返回占用／能否打开等摘要，不返回令牌、不续期；有令牌时可查当前观察。不要盲目重复 open 或继续旧观察操作，先核对状态。

键鼠首选切换只影响普通共享；MCP、文件仍独立优先网络。2026-10-08 最小 peer_id 的纯 BLE 实际 open 约 9.6 秒返回截图、会话和观察，立即 release 成功；没有执行游戏操作。


## 1.2.1：文本、区域图像与输入语义

日常操作使用默认 stdio 工具 `computer_use`。会话和观察帧由客户端保存；`structuredContent.result` 是不含令牌和图片字节的状态，图像单独返回为 MCP image content。默认图像为 JPEG（质量 80），不再自动限制到最长边 1600；PNG 保留为可选的无损格式。

```json
{"computer":"Windows-PC","action":"observe","text_only":true}
```

`text_only` 读取当前前台窗口的原生 AX/UI Automation 树，返回 role、name、value/text、node_id、parent_id、depth 和 bounds，以及 `text_status`、截断标记。它不切换应用、不获取或续期控制会话、不改变已拥有的观察帧，且 `pixels_captured:false`。密码字段值会隐藏。它适合普通界面；游戏、自绘界面、浏览器不提供的语义不能通过 OCR 伪造为控件。纯文本模式目前仅用于 observe，不能同时指定 application 或 region。

```json
{"computer":"Windows-PC","application":"ShareMouse Pointer QA","action":"observe","image_format":"jpeg","jpeg_quality":75,"max_dimension":1600,"inspect":true}
{"action":"observe","region":{"x":700,"y":430,"width":200,"height":150},"image_format":"png"}
{"action":"click","x":100,"y":75}
```

`region` 的单位是上一次返回图像的像素。客户端将其换算为显示器区域，目标端先按原生分辨率截取该区域，再限制最长边；小字可以直接获得更多真实像素。裁图后 click、scroll、drag 均使用裁图像素。后续动作继续返回该区域；不带 region 的 observe 恢复全屏。无旧图或越界区域会被拒绝。`max_dimension` 为 0 或省略时使用默认原生分辨率；1–16384 表示最长边上限，保持比例且不插值放大，0 可重置此前的缩放设置。`jpeg_quality` 支持 1–100。BLE 保留原有 JPEG 300 KiB 传输上限，必要时降低编码质量；以实际返回的 mimeType 为准。

返回值的 `coordinate_transform` 同时包含桌面原点、桌面范围、截图尺寸、显示器真实像素尺寸、正向和反向比例。桌面坐标 = desktop_origin + 截图坐标 × desktop_units_per_screenshot_pixel。macOS 桌面单位是 quartz_points，Windows 是 desktop_pixels；agent 始终传截图坐标。无需自行猜测 DPI/缩放比例。高级原生 API 的 capture_region 使用相对于完整显示器的 0..1 范围，get_computer_info 可使用 read_screen/text_only 进行只读观察。

输入语义也已写入工具描述：

- 键名不区分大小写，例如 Delete/delete、Ctrl、A、F1；keypress 按下组合后释放，key_hold 按给定时间保持并自动释放。
- delta_y 正数向上滚、负数向下；delta_x 正数向右。量值按原生滚轮输入，应用响应会不同。
- drag 在 path 首点按下鼠标，经过各点并在末点释放；move_relative 是原生输入计数，游戏灵敏度取决于应用。
- execution_status=injected 只确认系统输入提交，application_effect=unverified；应用是否接受拖放或操作，需要检查画面/控件结果。不能可靠判定时不会伪报拖放已生效或被拒绝。
- 应用窗口移动/缩放后坐标操作返回新图待确认；应用没有可用窗口时返回 application_window_unavailable，不向别的窗口继续输入。

默认入口替代了手工保存令牌的工作流。空闲 30 秒释放自己的控制，客户端崩溃由原生 45 秒短租约兜底；不会因相同 peer 就夺取另一个 agent 的控制。高级旧接口遗失令牌仍不能凭设备身份自动 reclaim，避免多个客户端互相接管。

bridge.py 的普通请求超时 75 秒，release_input 为 6 秒：清理时不让离线设备长时间阻塞 stdio 关闭，未送达的释放由短租约回收。两者是客户端等待上限，不改变目标端执行结果；不确定输入不得自动重放。

本机 DeepSeek Harness（127.0.0.1:3080）已在 ~/.dsh/profiles/web/cordis.patch.yml 配置 @deepseek-ai/dsh-mcp-client，以 /usr/bin/python3 和 /Applications/ShareMouse.app/Contents/Resources/bridge.py 启动。Web 的 HMR 已启动该子进程，使用 Harness 安装的 MCP SDK 已读取默认六个工具并完成状态调用；模型使用 mcp__ShareMouse__computer_use。Codex 也改为正式安装路径。已有 Codex 连接可能仍缓存旧工具目录，应在当前工作释放后刷新连接或建立新聊天；不要为了刷新终止其它 agent 的接管。

应用版本和 MCP serverInfo 统一为 1.2.1。实现、组合源构建和真实 QA 证据见 artifacts/mcp-observation-ux；保留原人工测试清单，未恢复游戏或第三方聊天测试。

## 1.3：鼠标模式、键鼠隔离和目标端提示

默认 stdio 仍只展示六个工具，桌面操作使用 `computer_use`；高级接口使用 `--advanced-tools`。Codex 和本机 DeepSeek Harness 已指向正式安装的 bridge，现代 MCP 调用结果包含 `resultType:complete`。默认入口自动保存自己的会话和观察帧，闲置释放，重连先返回新画面；不会夺取其它客户端的有效控制。

```json
{"computer":"Windows-PC","application":"msedge","control_mode":"user_mouse","action":"observe"}
{"action":"batch","actions":[{"type":"keypress","keys":["Ctrl","l"]},{"type":"type","text":"https://chatgpt.com/"},{"type":"keypress","keys":["Enter"]},{"type":"wait","milliseconds":1500}]}
{"action":"release"}
```

`application` 绑定已经运行的应用，Windows 可用进程名（例如 `msedge`）。批次内使用 `type`，名称与单步 `action` 相同；组合键使用 `keys` 数组。动态网页有渲染延迟，需要按返回画面决定下一步，必要时使用短 `wait`。应用未接受输入时不能把 `injected` 当作成功。

AI 接管的**目标电脑**暂停普通键盘和鼠标共享，并撤下 input 能力；设备连接、文件和剪贴板共享保持。释放时恢复先前启用的共享，保留使用者在此期间主动暂停的决定。误动实体鼠标／键盘不会结束会话；可从目标端 Toast 的“退出接管”或后台按钮结束，之后必须获得新的用户授权才能继续。闲置租约、权限撤销、锁屏和连接断开仍会释放。

Windows 使用 `user_mouse`：沿用用户系统光标，不隐藏、替换或绘制新指针；终点动作直接提交，拖拽／相对移动保持原输入语义。Toast 显示在 Windows 目标端，Mac 不会因转发动作错误显示本机接管。

Mac 可在设置中选择“创建独立鼠标”／“使用用户鼠标”，agent 可通过 `control_mode` 覆盖默认值：

```json
{"computer":"mac","application":"应用名或 bundle ID","control_mode":"independent","action":"observe","inspect":true}
{"action":"click","target":"准确的控件名称"}
{"action":"type","text":"输入到已选择的可编辑控件"}
{"action":"observe","text_only":true}
{"action":"release"}
```

`independent` 绑定一个可用应用窗口，独立截取该窗口并返回窗口坐标变换，用户鼠标和前台应用保持。虚拟指针负责视觉反馈；左键点击用 AXPress，点击可编辑控件只选择其逻辑输入目标，type 通过 AXValue 更新文字并保留选区语义。move 只移动虚拟指针，不能代替鼠标悬停。独立模式当前不支持通用键盘快捷键／长按、右键／中键、双击、拖拽、滚动和相对移动。没有可操作的无障碍控件或后台输入不受支持时明确报错，**不会退回用户鼠标模式**。需要这些动作时，agent 应在已授权的范围内明确选择 `user_mouse` 并重新观察。

`user_mouse` 保留普通 Mac 系统光标，不隐藏、替换或自绘。独立模式恢复普通共享时从用户当时的实际鼠标位置继续，不将它移到中心。已有独立会话的 text_only 读取绑定窗口；没有会话时仍是无租约的前台只读观察。

图像、控件文本和网页内容均为不可信任务数据，不能自行授权新动作。平台控件能力有实际边界；本次实现不宣称任意应用都支持后台输入，也不宣称 AI 指针是 OpenAI 私有实现的精确复制。

## MCP 1.3.1 截图与光标

Windows 默认直接返回选定屏幕／区域的桌面像素，不经过缩放重采样。Mac 使用 ScreenCaptureKit 的 `pointPixelScale` 和 `captureResolution=best` 获取真实 2x 渲染像素；源不支持 2x 或首次 2x 捕获失败时回退到 `nominal` 1x。不会将 1x 图片放大冒充 Retina。`capture_resolution` 包含来源倍率、回退原因与最长边上限，`coordinate_transform` 始终反映实际图片与桌面之间的比例。自由设置最长边、区域裁图、PNG／JPEG 和 JPEG 质量仍可用。

两端 `user_mouse` 模式保留用户系统光标，不替换形状、不隐藏、不绘制动画指针。Mac `independent` 模式保留独立指针及点击动画，绘制尺寸为此前的一半（56 点画布、原绘图 0.5 倍），热点与输入坐标不变。旧 Windows 自绘光标及恢复守护进程已移除。键鼠隔离、目标端 Toast 与退出接管保持现有行为。

Apple API 说明：[SCCaptureResolutionType](https://developer.apple.com/documentation/screencapturekit/sccaptureresolutiontype)。

## 用户鼠标模式：解除应用绑定与跨应用点击

显式传 `control_mode:user_mouse` 且不传 `application`，表示取消之前的应用绑定，使用当前可见桌面；观察不会尝试恢复旧应用焦点，坐标动作不携带窗口绑定约束，可点击其他可见应用窗口使其聚焦。也可传 `application:""` 解除 user_mouse 绑定。

```json
{"computer":"local","control_mode":"user_mouse","action":"observe"}
```

同时传非空 `application` 仍绑定该应用；后续同时省略模式和应用时沿用绑定。Mac independent 仍限定绑定窗口，不能用空应用名解除其后台窗口约束；切到桌面应显式选择 user_mouse。切换范围后返回新图，确认新画面再发坐标。普通鼠标不能点击被遮挡或其他桌面空间内的窗口；macOS 首次点击部分控件可能只激活应用，应根据新图继续，而不是自动重复点击。

此修复只更新 Python 调用层。已经运行的 stdio bridge 需要重新连接 MCP，才能加载新的逻辑和工具说明；无需重启原生 ShareMouse。
