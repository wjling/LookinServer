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
    name: "lookin_diff_with_figma",
    description:
      "将 iOS 视图的实际属性与 Figma 设计稿数据进行对比，输出差异报告。\n" +
      "可帮助开发者快速发现 UI 还原中的偏差，如颜色、字号、圆角、间距不符等问题。\n\n" +
      "使用方式：\n" +
      "1. 通过 Figma MCP（get_figma_data）获取对应节点数据\n" +
      "2. 从层级树找到对应 iOS 视图的 oid\n" +
      "3. 调用本工具传入 oid 和 figmaNode 数据\n\n" +
      "输出格式：每项属性标注 ✅ 匹配 / ⚠️ 偏差 / ❌ 不匹配 / ➖ 仅 Figma 有 / ➕ 仅 iOS 有",
    inputSchema: {
      type: "object",
      properties: {
        oid: {
          type: "number",
          description: "iOS 视图的对象 ID",
        },
        figmaNode: {
          type: "object",
          description:
            "从 Figma MCP get_figma_data 获取的单个节点对象，包含 layout、fills、" +
            "strokes、borderRadius、textStyle 等字段。直接传入 nodes 数组中的某一项即可。",
        },
        tolerance: {
          type: "number",
          description: "数值类属性（尺寸、颜色分量等）的容差，默认为 1（即 1pt/1色值单位内视为匹配）",
        },
      },
      required: ["oid", "figmaNode"],
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

      case "lookin_diff_with_figma": {
        const params = args as {
          oid: number;
          figmaNode: Record<string, unknown>;
          tolerance?: number;
        };
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
          content: [{
            type: "text",
            text: diffWithFigma(item, params.figmaNode, params.tolerance ?? 1),
          }],
        };
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

// ─── 新增：Figma Diff 核心逻辑 ────────────────────────────────────────────────

interface DiffItem {
  label: string;
  status: "✅" | "⚠️" | "❌" | "➖" | "➕";
  detail: string;
}

/** 从 Figma globalVars.styles 中解析颜色字符串，返回 {r,g,b,a} */
function parseFigmaColor(raw: unknown): { r: number; g: number; b: number; a: number } | null {
  if (!raw) return null;

  // 数组形式：取第一个元素
  const val = Array.isArray(raw) ? raw[0] : raw;
  if (typeof val !== "string") return null;

  // #RRGGBB
  const hexMatch = val.match(/^#([0-9a-fA-F]{6})$/);
  if (hexMatch) {
    const n = parseInt(hexMatch[1], 16);
    return { r: (n >> 16) & 0xff, g: (n >> 8) & 0xff, b: n & 0xff, a: 1 };
  }
  // rgba(r, g, b, a) 或 rgb(r, g, b)
  const rgbaMatch = val.match(/rgba?\(\s*(\d+(?:\.\d+)?)\s*,\s*(\d+(?:\.\d+)?)\s*,\s*(\d+(?:\.\d+)?)(?:\s*,\s*([\d.]+))?\s*\)/);
  if (rgbaMatch) {
    const [, r, g, b, a] = rgbaMatch;
    return {
      r: Math.round(parseFloat(r)),
      g: Math.round(parseFloat(g)),
      b: Math.round(parseFloat(b)),
      a: a !== undefined ? parseFloat(a) : 1,
    };
  }
  return null;
}

/** 从 Figma borderRadius 字符串中提取数值（如 "20px" → 20） */
function parsePx(val: unknown): number | null {
  if (val === undefined || val === null) return null;
  if (typeof val === "number") return val;
  if (typeof val === "string") {
    const m = val.match(/^([\d.]+)px$/);
    return m ? parseFloat(m[1]) : null;
  }
  return null;
}

function colorEqual(ios: ColorValue, figma: { r: number; g: number; b: number; a: number }, tol: number): boolean {
  // RGB 容差：tol 单位为 0-255 的整数色值
  // Alpha 容差：固定 0.05（约 5%），独立于 tol，因为 alpha 是 0-1 范围
  return (
    Math.abs(ios.r - figma.r) <= tol &&
    Math.abs(ios.g - figma.g) <= tol &&
    Math.abs(ios.b - figma.b) <= tol &&
    Math.abs(ios.a - figma.a) <= 0.05
  );
}

function numEqual(a: number, b: number, tol: number): boolean {
  return Math.abs(a - b) <= tol;
}

function diffWithFigma(
  item: DisplayItem,
  figmaNode: Record<string, unknown>,
  tolerance: number
): string {
  const diffs: DiffItem[] = [];

  // globalVars 可能在 figmaNode 本身，也可能在整个 get_figma_data 响应的顶层
  // 按优先级依次查找，兼容 AI 直接传整个响应 或 单个节点 两种调用方式
  const topLevel = figmaNode as Record<string, unknown>;
  const globalVars =
    (topLevel["globalVars"] as Record<string, unknown> | undefined) ??
    ((topLevel["document"] as Record<string, unknown> | undefined)?.["globalVars"] as Record<string, unknown> | undefined) ??
    {};
  const styles = (globalVars["styles"] as Record<string, unknown> | undefined) ?? {};

  // ── 解析 Figma 节点的 layout ─────────────────────────────────────────────
  // 优先从 globalVars.styles 取（使用了 Figma 变量语义），其次直接读节点标准字段
  const layoutKey = figmaNode["layout"] as string | undefined;
  const layout = layoutKey ? (styles[layoutKey] as Record<string, unknown> | undefined) : undefined;

  // 尺寸：globalVars.styles.dimensions → Figma 标准字段 width/height → absoluteBoundingBox
  const absBB = figmaNode["absoluteBoundingBox"] as Record<string, number> | undefined;
  const figmaDimensions: Record<string, number | undefined> =
    (layout?.["dimensions"] as Record<string, number> | undefined) ?? {
      width: (figmaNode["width"] as number | undefined) ?? absBB?.["width"],
      height: (figmaNode["height"] as number | undefined) ?? absBB?.["height"],
    };

  // 位置：globalVars → absoluteBoundingBox（注意：Figma 坐标是相对画板，非相对父节点）
  const figmaLocation: Record<string, number | undefined> =
    (layout?.["locationRelativeToParent"] as Record<string, number> | undefined) ?? {
      x: absBB?.["x"],
      y: absBB?.["y"],
    };

  const figmaPadding = layout?.["padding"] as string | undefined;
  // gap：globalVars.styles → Figma 标准字段 itemSpacing
  const figmaGap =
    (layout?.["gap"] as string | undefined) ??
    ((figmaNode["itemSpacing"] as number | undefined) !== undefined
      ? String(figmaNode["itemSpacing"]) + "px"
      : undefined);
  const figmaMode = layout?.["mode"] as string | undefined;

  // ── frame 对比 ────────────────────────────────────────────────────────────
  if (item.frame && (figmaDimensions["width"] !== undefined || figmaDimensions["height"] !== undefined)) {
    const fw = figmaDimensions["width"];
    const fh = figmaDimensions["height"];
    if (fw !== undefined) {
      const ok = numEqual(item.frame.width, fw, tolerance);
      diffs.push({
        label: "width",
        status: ok ? "✅" : "❌",
        detail: ok
          ? `${item.frame.width}pt`
          : `iOS=${item.frame.width}pt  Figma=${fw}pt  diff=${item.frame.width - fw > 0 ? "+" : ""}${(item.frame.width - fw).toFixed(1)}pt`,
      });
    }
    if (fh !== undefined) {
      const ok = numEqual(item.frame.height, fh, tolerance);
      diffs.push({
        label: "height",
        status: ok ? "✅" : "❌",
        detail: ok
          ? `${item.frame.height}pt`
          : `iOS=${item.frame.height}pt  Figma=${fh}pt  diff=${item.frame.height - fh > 0 ? "+" : ""}${(item.frame.height - fh).toFixed(1)}pt`,
      });
    }
  } else if (!item.frame && (figmaDimensions["width"] !== undefined || figmaDimensions["height"] !== undefined)) {
    diffs.push({ label: "frame", status: "➖", detail: `Figma 有尺寸数据但 iOS 未获取到 frame` });
  }

  if (item.frame && figmaLocation) {
    const fx = figmaLocation["x"];
    const fy = figmaLocation["y"];
    if (fx !== undefined) {
      const ok = numEqual(item.frame.x, fx, tolerance);
      diffs.push({
        label: "x (相对父节点)",
        status: ok ? "✅" : "⚠️",
        detail: ok ? `${item.frame.x}pt` : `iOS=${item.frame.x}pt  Figma=${fx}pt`,
      });
    }
    if (fy !== undefined) {
      const ok = numEqual(item.frame.y, fy, tolerance);
      diffs.push({
        label: "y (相对父节点)",
        status: ok ? "✅" : "⚠️",
        detail: ok ? `${item.frame.y}pt` : `iOS=${item.frame.y}pt  Figma=${fy}pt`,
      });
    }
  }

  // ── backgroundColor 对比 ─────────────────────────────────────────────────
  const figmaBgColorKey = figmaNode["fills"] as string | undefined;
  if (figmaBgColorKey) {
    const rawColor = styles[figmaBgColorKey];
    const figmaColor = parseFigmaColor(rawColor);
    if (figmaColor) {
      if (item.backgroundColor) {
        const ok = colorEqual(item.backgroundColor, figmaColor, tolerance);
        diffs.push({
          label: "backgroundColor",
          status: ok ? "✅" : "❌",
          detail: ok
            ? `${item.backgroundColor.hex}  rgba(${figmaColor.r},${figmaColor.g},${figmaColor.b},${figmaColor.a})`
            : `iOS=${item.backgroundColor.hex} rgba(${item.backgroundColor.r},${item.backgroundColor.g},${item.backgroundColor.b},${item.backgroundColor.a})\n     Figma=${figmaBgColorKey} → rgba(${figmaColor.r},${figmaColor.g},${figmaColor.b},${figmaColor.a})`,
        });
      } else {
        diffs.push({
          label: "backgroundColor",
          status: "➖",
          detail: `Figma 指定 ${figmaBgColorKey} → rgba(${figmaColor.r},${figmaColor.g},${figmaColor.b},${figmaColor.a})，iOS 未设置`,
        });
      }
    }
  }

  // ── cornerRadius 对比 ─────────────────────────────────────────────────────
  const figmaCornerRadiusRaw = figmaNode["borderRadius"];
  const figmaCornerRadius = parsePx(figmaCornerRadiusRaw);
  if (figmaCornerRadius !== null) {
    if (item.cornerRadius !== undefined) {
      const ok = numEqual(item.cornerRadius, figmaCornerRadius, tolerance);
      diffs.push({
        label: "cornerRadius",
        status: ok ? "✅" : "❌",
        detail: ok
          ? `${item.cornerRadius}pt`
          : `iOS=${item.cornerRadius}pt  Figma=${figmaCornerRadius}pt`,
      });
    } else {
      diffs.push({
        label: "cornerRadius",
        status: "➖",
        detail: `Figma=${figmaCornerRadius}pt，iOS 未获取到（可能为 0 或数据未加载）`,
      });
    }
  }

  // ── border 对比 ───────────────────────────────────────────────────────────
  const figmaStrokeWeightRaw = figmaNode["strokeWeight"];
  const figmaStrokeWeight = parsePx(figmaStrokeWeightRaw);
  if (figmaStrokeWeight !== null && figmaStrokeWeight > 0) {
    if (item.borderWidth !== undefined) {
      const ok = numEqual(item.borderWidth, figmaStrokeWeight, tolerance * 0.5); // 描边精度要求高
      diffs.push({
        label: "borderWidth",
        status: ok ? "✅" : "⚠️",
        detail: ok
          ? `${item.borderWidth}pt`
          : `iOS=${item.borderWidth}pt  Figma=${figmaStrokeWeight}pt`,
      });
    } else {
      diffs.push({
        label: "borderWidth",
        status: "➖",
        detail: `Figma=${figmaStrokeWeight}pt，iOS 未获取到`,
      });
    }

    const strokeColorKey = figmaNode["strokes"] as string | undefined;
    if (strokeColorKey) {
      const rawStroke = styles[strokeColorKey] as Record<string, unknown> | undefined;
      const strokeColors = rawStroke?.["colors"] as unknown[] | undefined;
      const figmaStrokeColor = parseFigmaColor(strokeColors?.[0] ?? strokeColorKey);
      if (figmaStrokeColor && item.borderColor) {
        const ok = colorEqual(item.borderColor, figmaStrokeColor, tolerance);
        diffs.push({
          label: "borderColor",
          status: ok ? "✅" : "❌",
          detail: ok
            ? `${item.borderColor.hex}`
            : `iOS=${item.borderColor.hex}  Figma=rgba(${figmaStrokeColor.r},${figmaStrokeColor.g},${figmaStrokeColor.b},${figmaStrokeColor.a})`,
        });
      }
    }
  }

  // ── 文字属性对比（UILabel） ───────────────────────────────────────────────
  const figmaTextStyle = figmaNode["textStyle"] as string | undefined;
  if (figmaTextStyle) {
    const ts = styles[figmaTextStyle] as Record<string, unknown> | undefined;
    if (ts) {
      const figmaFontSize = ts["fontSize"] as number | undefined;
      const figmaFontFamily = ts["fontFamily"] as string | undefined;
      const figmaFontWeight = ts["fontWeight"] as number | undefined;

      if (item.label) {
        // fontSize
        if (figmaFontSize !== undefined && item.label.fontSize !== undefined) {
          const ok = numEqual(item.label.fontSize, figmaFontSize, tolerance);
          diffs.push({
            label: "fontSize",
            status: ok ? "✅" : "❌",
            detail: ok
              ? `${item.label.fontSize}pt`
              : `iOS=${item.label.fontSize}pt  Figma=${figmaFontSize}pt`,
          });
        } else if (figmaFontSize !== undefined) {
          diffs.push({ label: "fontSize", status: "➖", detail: `Figma=${figmaFontSize}pt，iOS 未获取到` });
        }

        // fontFamily
        if (figmaFontFamily && item.label.fontName) {
          // iOS fontName 可能是 "PingFangSC-Regular"，只取 family 部分对比
          const iosFamilyNorm = item.label.fontName.replace(/[-_].+$/, "").toLowerCase().replace(/\s/g, "");
          const figmaFamilyNorm = figmaFontFamily.toLowerCase().replace(/\s/g, "");
          const ok = iosFamilyNorm.includes(figmaFamilyNorm) || figmaFamilyNorm.includes(iosFamilyNorm);
          diffs.push({
            label: "fontFamily",
            status: ok ? "✅" : "⚠️",
            detail: ok
              ? `${item.label.fontName}`
              : `iOS="${item.label.fontName}"  Figma="${figmaFontFamily}"`,
          });
        }

        // fontWeight（Figma 用数字：400=Regular, 500=Medium, 700=Bold）
        if (figmaFontWeight !== undefined && item.label.fontName) {
          const iosFontNameLower = item.label.fontName.toLowerCase();
          const figmaWeightLabel =
            figmaFontWeight >= 700 ? "bold/heavy" :
            figmaFontWeight >= 500 ? "medium/semibold" : "regular/light";
          const iosWeightLabel =
            iosFontNameLower.includes("bold") || iosFontNameLower.includes("heavy") ? "bold/heavy" :
            iosFontNameLower.includes("medium") || iosFontNameLower.includes("semibold") ? "medium/semibold" : "regular/light";
          const ok = figmaWeightLabel === iosWeightLabel;
          diffs.push({
            label: "fontWeight",
            status: ok ? "✅" : "⚠️",
            detail: ok
              ? `${figmaFontWeight} (${figmaWeightLabel})`
              : `iOS 字重="${iosWeightLabel}"  Figma=${figmaFontWeight} (${figmaWeightLabel})`,
          });
        }
      } else {
        // 是文字节点但 iOS 没有 label 数据
        if (figmaFontSize !== undefined) {
          diffs.push({ label: "fontSize", status: "➖", detail: `Figma=${figmaFontSize}pt，iOS 视图未识别为文字控件` });
        }
      }
    }
  }

  // ── 文字颜色对比 ──────────────────────────────────────────────────────────
  // Figma TEXT 节点的 fills 就是文字颜色
  if (figmaNode["type"] === "TEXT" && figmaBgColorKey) {
    const rawTextColor = styles[figmaBgColorKey];
    const figmaTextColor = parseFigmaColor(rawTextColor);
    if (figmaTextColor && item.label?.textColor) {
      const ok = colorEqual(item.label.textColor, figmaTextColor, tolerance);
      diffs.push({
        label: "textColor",
        status: ok ? "✅" : "❌",
        detail: ok
          ? `${item.label.textColor.hex}`
          : `iOS=${item.label.textColor.hex} rgba(${item.label.textColor.r},${item.label.textColor.g},${item.label.textColor.b},${item.label.textColor.a})\n     Figma=rgba(${figmaTextColor.r},${figmaTextColor.g},${figmaTextColor.b},${figmaTextColor.a})`,
      });
    }
  }

  // ── UIStackView spacing / padding 对比 ────────────────────────────────────
  if (figmaGap && item.stackView?.spacing !== undefined) {
    const figmaSpacing = parsePx(figmaGap);
    if (figmaSpacing !== null) {
      const ok = numEqual(item.stackView.spacing, figmaSpacing, tolerance);
      diffs.push({
        label: "spacing (gap)",
        status: ok ? "✅" : "⚠️",
        detail: ok
          ? `${item.stackView.spacing}pt`
          : `iOS=${item.stackView.spacing}pt  Figma=${figmaSpacing}pt`,
      });
    }
  } else if (figmaGap && !item.stackView) {
    diffs.push({ label: "spacing (gap)", status: "➖", detail: `Figma gap=${figmaGap}，iOS 视图不是 UIStackView 或数据未获取` });
  }

  // ── 输出报告 ──────────────────────────────────────────────────────────────
  if (diffs.length === 0) {
    return (
      `📋 Figma Diff 报告\n` +
      `═══════════════════════════════\n` +
      `视图：${item.className ?? "Unknown"}  #${item.oid}\n\n` +
      `⚠️ 未能提取到可对比的属性。\n` +
      `请确认：\n` +
      `  1. figmaNode 数据包含 layout/fills/strokes/borderRadius/textStyle 字段\n` +
      `  2. figmaNode 附带了 globalVars.styles 字典（传入完整 get_figma_data 响应即可）\n` +
      `  3. iOS 端已更新到最新 LookinServer（支持 attributesGroupList 序列化）`
    );
  }

  const passCount = diffs.filter((d) => d.status === "✅").length;
  const warnCount = diffs.filter((d) => d.status === "⚠️").length;
  const failCount = diffs.filter((d) => d.status === "❌").length;
  const onlyFigma = diffs.filter((d) => d.status === "➖").length;

  const headerLine =
    failCount > 0 ? "❌ 存在不匹配属性" :
    warnCount > 0 ? "⚠️  存在偏差" : "✅ 全部匹配";

  const lines = [
    `📋 Figma Diff 报告  ${headerLine}`,
    `═══════════════════════════════`,
    `视图：${item.className ?? "Unknown"}  #${item.oid ?? "?"}`,
    `Figma 节点：${(figmaNode["name"] as string) ?? "(未知)"}  [${(figmaNode["type"] as string) ?? ""}]`,
    `容差：±${tolerance}`,
    ``,
    `结果：✅ ${passCount} 匹配  ⚠️ ${warnCount} 偏差  ❌ ${failCount} 不匹配  ➖ ${onlyFigma} 仅 Figma`,
    `───────────────────────────────`,
    ...diffs.map((d) => `${d.status}  ${d.label.padEnd(22)} ${d.detail}`),
  ];

  if (failCount > 0 || warnCount > 0) {
    lines.push(``, `💡 修复建议：`);
    for (const d of diffs) {
      if (d.status === "❌") {
        lines.push(`  • ${d.label}：${d.detail.split("\n")[0]}`);
      }
    }
  }

  return lines.join("\n");
}

// ─── 启动 ────────────────────────────────────────────────────────────────────

async function main() {
  const transport = new StdioServerTransport();
  await server.connect(transport);
  // 日志输出到 stderr，避免污染 stdout（MCP 通信用）
  console.error(
    `[lookin-mcp] Server started. Connecting to iOS bridge at ${BRIDGE_HOST}:${BRIDGE_PORT}`
  );
}

main().catch((err) => {
  console.error("[lookin-mcp] Fatal error:", err);
  process.exit(1);
});
