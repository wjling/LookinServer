# lookin-mcp

MCP Server for [Lookin](https://lookin.work) iOS UI Debugger.

让 AI（CodeMaker / Claude 等）能够实时读取 iOS App 的 UI 层级树，帮助分析、调试界面问题。

---

## 快速使用

### 第一步：iOS 项目集成 LookinServer（含 MCP Bridge）

在 `Podfile` 中使用 fork 版本：

```ruby
pod 'LookinServer', :git => 'https://github.com/your-username/LookinServer.git', :branch => 'mcp-bridge'
```

或 SPM：

```swift
.package(url: "https://github.com/your-username/LookinServer.git", branch: "mcp-bridge")
```

### 第二步：配置 CodeMaker MCP

在 CodeMaker 的 MCP 配置中添加：

```json
{
  "lookin": {
    "type": "stdio",
    "command": "npx",
    "args": ["-y", "lookin-mcp"],
    "autoApprove": true
  }
}
```

**真机调试**时，需要额外配置端口转发：

```json
{
  "lookin": {
    "type": "stdio",
    "command": "npx",
    "args": ["-y", "lookin-mcp"],
    "env": {
      "LOOKIN_HOST": "127.0.0.1",
      "LOOKIN_PORT": "9877"
    }
  }
}
```

并在终端运行：

```bash
iproxy 9877 9877   # USB 端口转发（需要 libimobiledevice）
```

### 第三步：运行 iOS App，开始使用

```
你：当前页面有哪些 View？
AI：调用 lookin_get_hierarchy → 返回完整层级树

你：找出所有隐藏的 UILabel
AI：调用 lookin_find_view(className: "UILabel", isHidden: true)

你：帮我分析当前页面结构
AI：调用 lookin_summarize → 输出摘要
```

---

## 可用工具

| 工具 | 说明 |
|------|------|
| `lookin_ping` | 检查是否连接到 iOS App |
| `lookin_get_hierarchy` | 获取完整 UI 层级树 |
| `lookin_refresh_hierarchy` | 刷新并获取最新层级树 |
| `lookin_find_view` | 按类名/VC/隐藏状态搜索视图 |
| `lookin_get_view_detail` | 获取单个视图详情 |
| `lookin_summarize` | 层级树智能摘要 |

---

## 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `LOOKIN_HOST` | `127.0.0.1` | iOS Bridge 主机（模拟器用默认值） |
| `LOOKIN_PORT` | `9877` | iOS Bridge 端口 |

---

## 注意事项

- iOS 模拟器：开箱即用，无需额外配置
- iOS 真机：需要 `iproxy 9877 9877` 做 USB 端口转发
- Lookin Mac App 与本 MCP 可以**同时使用**，互不干扰

---

## License

MIT
