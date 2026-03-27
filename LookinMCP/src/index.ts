#!/usr/bin/env node
/**
 * LookinMCP - MCP Server for Lookin iOS UI Debugger
 *
 * 通过 stdio 与 AI 客户端（CodeMaker / Claude Desktop 等）通信，
 * 将 iOS App 的 UI 层级数据暴露给 AI。
 *
 * 使用方式（CodeMaker MCP 配置）：
 * {
 *   "lookin": {
 *     "type": "stdio",
 *     "command": "npx",
 *     "args": ["-y", "lookin-mcp"]
 *   }
 * }
 */

import { Server } from "@modelcontextprotocol/sdk/server/index.js";
import { StdioServerTransport } from "@modelcontextprotocol/sdk/server/stdio.js";
import {
  CallToolRequestSchema,
  ListToolsRequestSchema,
  Tool,
} from "@modelcontextprotocol/sdk/types.js";

import { LookinBridgeClient, DisplayItem, ColorValue } from "./bridge-client.js";

// ─── 初始化 ──────────────────────────────────────────────────────────────────

// 从环境变量读取配置（支持真机场景）
const BRIDGE_HOST = process.env.LOOKIN_HOST ?? "127.0.0.1";
const BRIDGE_PORT = parseInt(process.env.LOOKIN_PORT ?? "9877", 10);

const client = new LookinBridgeClient(BRIDGE_HOST, BRIDGE_PORT);

const server = new Server(
  {
    name: "lookin-mcp",
    version: "1.0.0",
  },
  {
    capabilities: {
      tools: {},
    },
  }
);

// ─── 工具定义 ────────────────────────────────────────────────────────────────

const TOOLS: Tool[] = [
  {
    name: "lookin_ping",
    description:
      "检查是否能连接到 iOS App 的 Lookin MCP Bridge。用于诊断连接问题。",
    inputSchema: {
      type: "object",
      properties: {},
    },
  },
  {
    name: "lookin_get_hierarchy",
    description:
      "获取当前 iOS App 的 UI 层级树。返回所有视图（UIView/CALayer）的层级结构，" +
      "包括类名、frame、isHidden、alpha、所属 ViewController 等信息。" +
      "数据来自缓存，若要刷新请使用 lookin_refresh_hierarchy。",
    inputSchema: {
      type: "object",
      properties: {},
    },
  },
  {
    name: "lookin_refresh_hierarchy",
    description:
      "主动触发刷新，重新抓取当前 iOS App 的 UI 层级树并返回最新数据。" +
      "在页面切换后或想获取实时数据时使用。",
    inputSchema: {
      type: "object",
      properties: {},
    },
  },
  {
    name: "lookin_find_view",
    description:
      "在 UI 层级树中查找特定视图。支持按类名（模糊匹配）、ViewController 名、" +
      "是否隐藏等条件过滤，返回匹配的视图列表。",
    inputSchema: {
      type: "object",
      properties: {
        className: {
          type: "string",
          description: "按类名过滤（模糊匹配，如 'UILabel'、'Button'）",
        },
        viewController: {
          type: "string",
          description: "按所属 ViewController 类名过滤（模糊匹配）",
        },
        isHidden: {
          type: "boolean",
          description: "过滤隐藏/显示状态，不传则返回所有",
        },
        maxResults: {
          type: "number",
          description: "最多返回结果数量，默认 50",
        },
      },
    },
  },
  {
    name: "lookin_get_view_detail",
    description:
      "根据视图的 oid（对象 ID）获取单个视图的详细信息，包括 frame、类名、" +
      "父子关系等。oid 从 lookin_get_hierarchy 的结果中获取。",
    inputSchema: {
      type: "object",
      properties: {
        oid: {
          type: "number",
          description: "视图的对象 ID（从 hierarchy 结果中的 oid 字段获取）",
        },
      },
      required: ["oid"],
    },
  },
  {
    name: "lookin_summarize",
    description:
      "对当前 UI 层级树进行智能摘要，输出：\n" +
      "- 当前可见的 ViewController 列表\n" +
      "- 各层级的视图数量统计\n" +
      "- 隐藏视图数量\n" +
      "- 层级最深路径\n" +
      "适合在不需要全量数据时快速了解页面结构。",
    inputSchema: {
      type: "object",
      properties: {},
    },
  },
  {
    name: "lookin_get_view_attrs",
    description:
      "根据视图 oid 获取该视图的完整 UI 属性，包括：\n" +
      "- frame（位置与尺寸）\n" +
      "- backgroundColor、cornerRadius、borderWidth/Color\n" +
      "- shadowColor/Opacity/Radius/Offset\n" +
      "- UILabel/UITextField/UITextView 的 text、font、textColor、numberOfLines\n" +
      "- UIStackView 的 axis、spacing\n" +
      "适合在与 Figma 数据对比前，先获取某个视图的完整属性。",
    inputSchema: {
      type: "object",
      properties: {
        oid: {
          type: "number",
          description: "视图的对象 ID（从 hierarchy 结果中的 oid 字段获取）",
        },
      },
      required: ["oid"],
    },
  },
  {
    name: "lookin_modify_view",
    description:
      "在运行时直接修改 iOS App 中某个视图的属性，无需重新编译。\n" +
      "支持修改的属性包括：\n" +
      "- frame.x / frame.y / frame.width / frame.height（或完整 frame）\n" +
      "- backgroundColor、cornerRadius、borderWidth、borderColor\n" +
      "- alpha、hidden、clipsToBounds\n" +
      "- fontSize、textColor、textAlignment、numberOfLines、text（UILabel）\n" +
      "- spacing、axis（UIStackView）\n\n" +
      "修改后立即生效，适合快速调试 UI 还原度。",
    inputSchema: {
      type: "object",
      properties: {
        oid: {
          type: "number",
          description: "视图的对象 ID",
        },
        modifications: {
          type: "object",
          description:
            "要修改的属性键值对。例如：\n" +
            '{ "cornerRadius": 8, "backgroundColor": "#FF5500" }\n' +
            '{ "frame.width": 100, "frame.height": 50 }\n' +
            '{ "fontSize": 14, "textColor": { "r": 51, "g": 51, "b": 51 } }',
        },
      },
      required: ["oid", "modifications"],
    },
  },
];

// ─── 工具处理 ────────────────────────────────────────────────────────────────

server.setRequestHandler(ListToolsRequestSchema, async () => ({
  tools: TOOLS,
}));

server.setRequestHandler(CallToolRequestSchema, async (request) => {
  const { name, arguments: args } = request.params;

  try {
    switch (name) {
      case "lookin_ping": {
        const result = await client.ping();
        return {
          content: [
            {
              type: "text",
              text: formatPingResult(result),
            },
          ],
        };
      }

      case "lookin_get_hierarchy": {
        const result = await client.getHierarchy();
        return {
          content: [
            {
              type: "text",
              text: formatHierarchyResult(result.items, result.timestamp),
            },
          ],
        };
      }

      case "lookin_refresh_hierarchy": {
        const result = await client.refreshHierarchy();
        return {
          content: [
            {
              type: "text",
              text:
                `✅ 已刷新（${new Date(result.timestamp * 1000).toLocaleTimeString()}）\n\n` +
                formatHierarchyResult(result.items, result.timestamp),
            },
          ],
        };
      }

      case "lookin_find_view": {
        const params = args as {
          className?: string;
          viewController?: string;
          isHidden?: boolean;
          maxResults?: number;
        };
        const hierarchy = await client.getHierarchy();
        const all = client.flattenItems(hierarchy.items);
        const maxResults = params.maxResults ?? 50;

        const filtered = all.filter((item) => {
          if (
            params.className &&
            !item.className
              ?.toLowerCase()
              .includes(params.className.toLowerCase())
          ) {
            return false;
          }
          if (
            params.viewController &&
            !item.hostViewController
              ?.toLowerCase()
              .includes(params.viewController.toLowerCase())
          ) {
            return false;
          }
          if (
            params.isHidden !== undefined &&
            item.isHidden !== params.isHidden
          ) {
            return false;
          }
          return true;
        });

        const results = filtered.slice(0, maxResults);
        const text =
          results.length === 0
            ? "未找到匹配的视图"
            : `找到 ${filtered.length} 个视图（显示前 ${results.length} 个）：\n\n` +
              results.map((item) => formatViewSummary(item)).join("\n");

        return { content: [{ type: "text", text }] };
      }

      case "lookin_get_view_detail": {
        const params = args as { oid: number };
        const hierarchy = await client.getHierarchy();
        const item = client.findItemByOid(hierarchy.items, params.oid);

        if (!item) {
          return {
            content: [
              {
                type: "text",
                text: `未找到 oid=${params.oid} 的视图。请先调用 lookin_refresh_hierarchy 刷新数据。`,
              },
            ],
          };
        }

        return {
          content: [
            {
              type: "text",
              text: formatViewDetail(item),
            },
          ],
        };
      }

      case "lookin_summarize": {
        const hierarchy = await client.getHierarchy();
        return {
          content: [
            {
              type: "text",
              text: summarizeHierarchy(
                hierarchy.items,
                hierarchy.timestamp
              ),
            },
          ],
        };
      }

      case "lookin_get_view_attrs": {
        const params = args as { oid: number };
        const hierarchy = await client.getHierarchy();
        const item = client.findItemByOid(hierarchy.items, params.oid);
        if (!item) {
          return {
            content: [{
              type: "text",
              text: `未找到 oid=${params.oid} 的视图，请先调用 lookin_refresh_hierarchy 刷新数据。`,
            }],
          };
        }
        return {
          content: [{ type: "text", text: formatViewAttrs(item) }],
        };
      }

      case "lookin_modify_view": {
        const params = args as {
          oid: number;
          modifications: Record<string, unknown>;
        };
        const result = await client.modifyView(params.oid, params.modifications);
        if (result.success) {
          return {
            content: [{
              type: "text",
              text: `✅ 已修改视图 #${result.oid}\n` +
                    `修改的属性：${result.modifiedProps.join(", ")}\n\n` +
                    `💡 提示：可调用 lookin_refresh_hierarchy 查看修改后的层级树`,
            }],
          };
        } else {
          return {
            content: [{
              type: "text",
              text: `❌ 修改失败：${result.error ?? "未知错误"}`,
            }],
            isError: true,
          };
        }
      }

      default:
        throw new Error(`Unknown tool: ${name}`);
    }
  } catch (error) {
    const message =
      error instanceof Error ? error.message : String(error);
    return {
      content: [{ type: "text", text: `❌ 错误：${message}` }],
      isError: true,
    };
  }
});

// ─── 格式化函数 ──────────────────────────────────────────────────────────────

function formatPingResult(result: {
  status: string;
  port: number;
  hasHierarchy: boolean;
}): string {
  return (
    `✅ 已连接到 iOS App\n` +
    `  端口：${result.port}\n` +
    `  状态：${result.status}\n` +
    `  已有层级数据：${result.hasHierarchy ? "是" : "否（请调用 lookin_refresh_hierarchy）"}`
  );
}

function formatHierarchyResult(
  items: DisplayItem[],
  timestamp: number
): string {
  const timeStr = new Date(timestamp * 1000).toLocaleTimeString();
  const lines: string[] = [`UI 层级树（采集时间：${timeStr}）\n`];
  renderTree(items, 0, lines);
  return lines.join("\n");
}

function renderTree(
  items: DisplayItem[],
  depth: number,
  lines: string[]
): void {
  for (const item of items) {
    const indent = "  ".repeat(depth);
    const hidden = item.isHidden ? " [hidden]" : "";
    const alpha =
      item.alpha !== undefined && item.alpha < 1
        ? ` [alpha=${item.alpha.toFixed(2)}]`
        : "";
    const frame = item.frame
      ? ` {${item.frame.x},${item.frame.y} ${item.frame.width}×${item.frame.height}}`
      : "";
    const vc = item.hostViewController
      ? ` <${item.hostViewController}>`
      : "";
    const title = item.customDisplayTitle
      ? ` "${item.customDisplayTitle}"`
      : "";
    const oid = item.oid ? ` #${item.oid}` : "";

    // 自定义节点用不同格式展示，突出业务语义
    if (item.isCustom) {
      const customLabel = item.customTitle ?? item.customDisplayTitle ?? "(custom)";
      const sub = item.customSubtitle ? ` · ${item.customSubtitle}` : "";
      const fw = item.frameInWindow
        ? ` {${item.frameInWindow.x},${item.frameInWindow.y} ${item.frameInWindow.width}×${item.frameInWindow.height}}`
        : "";
      lines.push(`${indent}[Custom] ${customLabel}${sub}${fw}`);
    } else {
      lines.push(
        `${indent}${item.className ?? "Unknown"}${title}${hidden}${alpha}${frame}${vc}${oid}`
      );
    }

    if (item.children) {
      renderTree(item.children, depth + 1, lines);
    }
  }
}

function formatViewSummary(item: DisplayItem): string {
  const parts: string[] = [`• ${item.className ?? "Unknown"}`];
  if (item.customDisplayTitle) parts.push(`"${item.customDisplayTitle}"`);
  if (item.frame)
    parts.push(
      `{${item.frame.x},${item.frame.y} ${item.frame.width}×${item.frame.height}}`
    );
  if (item.isHidden) parts.push("[hidden]");
  if (item.isCustom) {
    const label = item.customTitle ?? "(custom)";
    const sub = item.customSubtitle ? `·${item.customSubtitle}` : "";
    parts.push(`[custom: ${label}${sub}]`);
  }
  if (item.hostViewController) parts.push(`<${item.hostViewController}>`);
  if (item.oid) parts.push(`#${item.oid}`);
  return parts.join(" ");
}

function formatViewDetail(item: DisplayItem): string {
  const lines: string[] = [
    `📦 视图详情`,
    `─────────────────────────────`,
    `类名：${item.className ?? "Unknown"}`,
  ];
  if (item.customDisplayTitle) lines.push(`自定义标题：${item.customDisplayTitle}`);
  if (item.oid !== undefined) lines.push(`对象 ID (oid)：${item.oid}`);
  if (item.frame) {
    lines.push(
      `位置：x=${item.frame.x}, y=${item.frame.y}`,
      `尺寸：${item.frame.width} × ${item.frame.height}`
    );
  }
  lines.push(`隐藏：${item.isHidden ? "是" : "否"}`);
  if (item.isCustom) {
    lines.push(`节点类型：业务自定义节点（不对应真实 View）`);
    if (item.customTitle) lines.push(`业务标题：${item.customTitle}`);
    if (item.customSubtitle) lines.push(`业务副标题：${item.customSubtitle}`);
    if (item.frameInWindow) {
      lines.push(
        `窗口位置：x=${item.frameInWindow.x}, y=${item.frameInWindow.y}`,
        `窗口尺寸：${item.frameInWindow.width} × ${item.frameInWindow.height}`
      );
    }
  }
  if (item.alpha !== undefined) lines.push(`透明度：${item.alpha}`);
  if (item.hostViewController)
    lines.push(`所属 ViewController：${item.hostViewController}`);
  if (item.children && item.children.length > 0) {
    lines.push(
      `\n子视图（${item.children.length} 个）：`,
      ...item.children.map(
        (c) => `  • ${c.className ?? "Unknown"}` + (c.oid ? ` #${c.oid}` : "")
      )
    );
  }
  return lines.join("\n");
}

function summarizeHierarchy(items: DisplayItem[], timestamp: number): string {
  const all: DisplayItem[] = [];
  const walk = (list: DisplayItem[]) => {
    for (const item of list) {
      all.push(item);
      if (item.children) walk(item.children);
    }
  };
  walk(items);

  const totalCount = all.length;
  const hiddenCount = all.filter((i) => i.isHidden).length;
  const vcSet = new Set(
    all.map((i) => i.hostViewController).filter(Boolean)
  );

  // 统计最深层级
  let maxDepth = 0;
  const calcDepth = (list: DisplayItem[], depth: number) => {
    for (const item of list) {
      maxDepth = Math.max(maxDepth, depth);
      if (item.children) calcDepth(item.children, depth + 1);
    }
  };
  calcDepth(items, 0);

  const timeStr = new Date(timestamp * 1000).toLocaleTimeString();
  const lines = [
    `📊 UI 层级摘要（采集时间：${timeStr}）`,
    `─────────────────────────────`,
    `总视图数：${totalCount}`,
    `隐藏视图：${hiddenCount}`,
    `最大层级深度：${maxDepth}`,
    `涉及 ViewController：`,
    ...[...vcSet].map((vc) => `  • ${vc}`),
  ];

  if (vcSet.size === 0) {
    lines.push("  （未识别到 ViewController 信息）");
  }

  return lines.join("\n");
}

// ─── 新增：视图完整属性格式化 ─────────────────────────────────────────────────

function colorStr(c: ColorValue): string {
  return `rgba(${c.r},${c.g},${c.b},${c.a})  ${c.hex}`;
}

function formatViewAttrs(item: DisplayItem): string {
  const lines: string[] = [
    `🔍 视图完整属性`,
    `═══════════════════════════════`,
    `类名：${item.className ?? "Unknown"}${item.oid !== undefined ? `  #${item.oid}` : ""}`,
    ``,
    `── 布局 ──`,
  ];

  if (item.frame) {
    lines.push(
      `  frame:   x=${item.frame.x}  y=${item.frame.y}  w=${item.frame.width}  h=${item.frame.height}`
    );
  }
  lines.push(`  hidden:  ${item.isHidden ? "YES" : "NO"}`);
  if (item.alpha !== undefined && item.alpha < 1) {
    lines.push(`  alpha:   ${item.alpha}`);
  }

  lines.push(``, `── 外观 ──`);
  if (item.backgroundColor && typeof item.backgroundColor === "object") {
    lines.push(`  backgroundColor:  ${colorStr(item.backgroundColor)}`);
  } else {
    lines.push(`  backgroundColor:  (未设置 / 透明)`);
  }
  if (item.cornerRadius !== undefined && item.cornerRadius !== null) {
    lines.push(`  cornerRadius:     ${item.cornerRadius}`);
  }
  if (item.borderWidth !== undefined && item.borderWidth > 0) {
    lines.push(`  borderWidth:      ${item.borderWidth}`);
    if (item.borderColor && typeof item.borderColor === "object") {
      lines.push(`  borderColor:      ${colorStr(item.borderColor)}`);
    }
  }
  if (item.shadowOpacity !== undefined && item.shadowOpacity > 0) {
    lines.push(
      `  shadow:  opacity=${item.shadowOpacity}  radius=${item.shadowRadius ?? 0}`,
      `           offset=(${item.shadowOffsetWidth ?? 0}, ${item.shadowOffsetHeight ?? 0})`,
    );
    if (item.shadowColor) {
      lines.push(`           color=${colorStr(item.shadowColor)}`);
    }
  }

  if (item.label && Object.keys(item.label).length > 0) {
    lines.push(``, `── 文本 ──`);
    if (item.label.text !== undefined) {
      lines.push(`  text:        "${item.label.text}"`);
    }
    if (item.label.fontName) {
      lines.push(`  font:        ${item.label.fontName}  ${item.label.fontSize ?? "?"}pt`);
    }
    if (item.label.textColor) {
      lines.push(`  textColor:   ${colorStr(item.label.textColor)}`);
    }
    if (item.label.numberOfLines !== undefined) {
      lines.push(`  lines:       ${item.label.numberOfLines === 0 ? "∞" : item.label.numberOfLines}`);
    }
    const alignMap: Record<number, string> = { 0: "left", 1: "center", 2: "right", 3: "justified", 4: "natural" };
    if (item.label.textAlignment !== undefined) {
      lines.push(`  alignment:   ${alignMap[item.label.textAlignment] ?? item.label.textAlignment}`);
    }
  }

  if (item.stackView && Object.keys(item.stackView).length > 0) {
    lines.push(``, `── UIStackView ──`);
    if (item.stackView.axis) lines.push(`  axis:      ${item.stackView.axis}`);
    if (item.stackView.spacing !== undefined) lines.push(`  spacing:   ${item.stackView.spacing}`);
  }

  if (item.hostViewController) {
    lines.push(``, `── 归属 ──`, `  ViewController: ${item.hostViewController}`);
  }

  return lines.join("\n");
}

