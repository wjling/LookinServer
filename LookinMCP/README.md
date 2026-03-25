# lookin-server-mcp

MCP Server for [LookinServer](https://github.com/wjling/LookinServer/tree/mcp) —— 让 AI 能够实时读取 iOS App 的 UI 层级树，辅助界面调试与 Figma 转代码还原。

---

## 原理

```
iOS App                    MCP Server               AI（CodeMaker / Claude）
┌─────────────────┐        ┌──────────────┐         ┌──────────────────────┐
│  LookinServer   │        │              │         │                      │
│  + MCP Bridge   │◄──────►│ lookin-server│◄───────►│  lookin_get_hierarchy│
│  port: 9877     │  HTTP  │     -mcp     │  stdio  │  lookin_find_view    │
└─────────────────┘        └──────────────┘         └──────────────────────┘
```

iOS 侧通过 `LKS_MCPBridge`（NWListener HTTP Server）暴露 UI 数据，MCP Server 作为中间层供 AI 工具调用。

---

## 快速开始

### 第一步：iOS 项目集成 LookinServer（含 MCP Bridge）

**CocoaPods：**

```ruby
# 使用包含 MCP Bridge 的 fork 版本，必须用 /Swift subspec
pod 'LookinServer/Swift',
    :git => 'https://github.com/wjling/LookinServer.git',
    :branch => 'mcp',
    :configurations => ['Debug']
```

执行 `pod install` 后运行 App，Console 看到以下日志说明集成成功：

```
[LKS_MCPBridge] HTTP bridge started on port 9877
```

**SPM：**

在 Xcode → Package Dependencies 添加：
- URL：`https://github.com/wjling/LookinServer.git`
- Branch：`mcp`

---

### 第二步：配置 MCP Server

在 CodeMaker（或 Claude Desktop）的 MCP 配置中添加：

**模拟器（开箱即用）：**

```json
{
  "mcpServers": {
    "lookin": {
      "command": "npx",
      "args": ["-y", "lookin-server-mcp"]
    }
  }
}
```

**真机（需要 USB 端口转发）：**

```bash
# 先在终端运行（需要 libimobiledevice）
iproxy 9877 9877
```

```json
{
  "mcpServers": {
    "lookin": {
      "command": "npx",
      "args": ["-y", "lookin-server-mcp"],
      "env": {
        "LOOKIN_HOST": "127.0.0.1",
        "LOOKIN_PORT": "9877"
      }
    }
  }
}
```

---

### 第三步：运行 App，与 AI 对话

```
你：当前页面有哪些 View？
AI：→ 调用 lookin_get_hierarchy，返回完整层级树

你：找出所有隐藏的 UILabel
AI：→ 调用 lookin_find_view(className: "UILabel", isHidden: true)

你：帮我分析当前页面结构
AI：→ 调用 lookin_summarize，输出摘要
```

---

## 可用工具

| 工具 | 说明 |
|------|------|
| `lookin_ping` | 检查是否连接到 iOS App |
| `lookin_get_hierarchy` | 获取完整 UI 层级树 |
| `lookin_refresh_hierarchy` | 主动刷新并获取最新层级树 |
| `lookin_find_view` | 按类名 / ViewController / 隐藏状态搜索视图 |
| `lookin_get_view_detail` | 获取单个视图的详细信息 |
| `lookin_summarize` | 层级树智能摘要（页面结构概览） |

---

## 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `LOOKIN_HOST` | `127.0.0.1` | iOS Bridge 主机地址（模拟器用默认值） |
| `LOOKIN_PORT` | `9877` | iOS Bridge 端口 |

---

## 注意事项

- **与 Lookin Mac App 互不干扰**：MCP Bridge 使用独立端口 9877，不影响原有 Lookin 调试功能
- **仅在 Debug 模式使用**：建议 Podfile 加 `:configurations => ['Debug']`，Release 包不含此代码
- **需要 `/Swift` subspec**：CocoaPods 默认只引入 Core（OC），MCP Bridge 在 Swift subspec 中

---

## License

GPL-3.0