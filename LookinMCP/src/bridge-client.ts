/**
 * LookinBridgeClient
 *
 * 负责与 iOS App 内的 LKS_MCPBridge（端口 9877）通信。
 * 支持模拟器（localhost）和真机（需要 iproxy 转发）。
 */

import * as http from "http";

// ─── 数据模型 ────────────────────────────────────────────────────────────────

export interface ViewFrame {
  x: number;
  y: number;
  width: number;
  height: number;
}

export interface ColorValue {
  r: number;   // 0-255
  g: number;   // 0-255
  b: number;   // 0-255
  a: number;   // 0-1
  hex: string; // "#RRGGBB"
}

export interface LabelAttrs {
  text?: string;
  fontName?: string;
  fontSize?: number;
  textColor?: ColorValue;
  numberOfLines?: number;
  /** NSTextAlignment 枚举值：0=left 1=center 2=right 3=justified 4=natural */
  textAlignment?: number;
}

export interface StackViewAttrs {
  /** "horizontal" | "vertical" */
  axis?: string;
  spacing?: number;
  /** UIStackView.Alignment 枚举值 */
  stackAlignment?: number;
}

export interface DisplayItem {
  className?: string;
  oid?: number;
  isHidden?: boolean;
  alpha?: number;
  frame?: ViewFrame;
  customDisplayTitle?: string;
  hostViewController?: string;

  // ── Figma 对比扩展属性 ──────────────────────────────────────────────────

  /** 背景色（UIView.backgroundColor / CALayer.backgroundColor） */
  backgroundColor?: ColorValue;
  /** 圆角（CALayer.cornerRadius） */
  cornerRadius?: number;
  /** 描边宽度（CALayer.borderWidth） */
  borderWidth?: number;
  /** 描边颜色（CALayer.borderColor） */
  borderColor?: ColorValue;
  /** 阴影颜色 */
  shadowColor?: ColorValue;
  /** 阴影透明度（0-1） */
  shadowOpacity?: number;
  /** 阴影模糊半径 */
  shadowRadius?: number;
  /** 阴影偏移 X */
  shadowOffsetWidth?: number;
  /** 阴影偏移 Y */
  shadowOffsetHeight?: number;
  /** UILabel / UITextField / UITextView 相关属性 */
  label?: LabelAttrs;
  /** UIStackView 相关属性 */
  stackView?: StackViewAttrs;

  // ── UserCustom 节点 ────────────────────────────────────────────────────

  /** 该节点为开发者通过 Lookin UserCustom API 注册的业务语义节点，不对应真实 View */
  isCustom?: boolean;
  /** isCustom 节点的业务标题（如"购物车列表容器"） */
  customTitle?: string;
  /** isCustom 节点的业务副标题 */
  customSubtitle?: string;
  /** isCustom 节点在窗口中的位置（可能为空） */
  frameInWindow?: ViewFrame;
  children?: DisplayItem[];
}

export interface HierarchyResponse {
  timestamp: number;
  items: DisplayItem[];
}

export interface PingResponse {
  status: string;
  port: number;
  hasHierarchy: boolean;
}

// ─── Client ──────────────────────────────────────────────────────────────────

export class LookinBridgeClient {
  private readonly host: string;
  private readonly port: number;
  private readonly timeoutMs: number;

  /**
   * @param host 目标主机，默认 127.0.0.1（模拟器）
   * @param port iOS bridge 端口，默认 9877
   * @param timeoutMs 请求超时毫秒数，默认 5000
   */
  constructor(host = "127.0.0.1", port = 9877, timeoutMs = 5000) {
    this.host = host;
    this.port = port;
    this.timeoutMs = timeoutMs;
  }

  // ── 公开接口 ────────────────────────────────────────────────────────────────

  /** 健康检查 */
  async ping(): Promise<PingResponse> {
    const data = await this.request("GET", "/ping");
    return data as PingResponse;
  }

  /** 获取当前 UI 层级树（使用缓存） */
  async getHierarchy(): Promise<HierarchyResponse> {
    const data = await this.request("GET", "/hierarchy");
    return data as HierarchyResponse;
  }

  /** 主动刷新并获取最新 UI 层级树 */
  async refreshHierarchy(): Promise<HierarchyResponse> {
    const data = await this.request("POST", "/refresh");
    return data as HierarchyResponse;
  }

  // ── 工具方法 ────────────────────────────────────────────────────────────────

  /** 根据 oid 在层级树中查找单个视图 */
  findItemByOid(
    items: DisplayItem[],
    oid: number
  ): DisplayItem | undefined {
    for (const item of items) {
      if (item.oid === oid) return item;
      if (item.children) {
        const found = this.findItemByOid(item.children, oid);
        if (found) return found;
      }
    }
    return undefined;
  }

  /** 将层级树打平为一维数组 */
  flattenItems(items: DisplayItem[]): DisplayItem[] {
    const result: DisplayItem[] = [];
    const walk = (list: DisplayItem[]) => {
      for (const item of list) {
        result.push(item);
        if (item.children) walk(item.children);
      }
    };
    walk(items);
    return result;
  }

  // ── HTTP ────────────────────────────────────────────────────────────────────

  private request(method: string, path: string): Promise<unknown> {
    return new Promise((resolve, reject) => {
      const options: http.RequestOptions = {
        hostname: this.host,
        port: this.port,
        path,
        method,
        headers: { "Content-Type": "application/json" },
        timeout: this.timeoutMs,
      };

      const req = http.request(options, (res) => {
        let body = "";
        res.on("data", (chunk) => (body += chunk));
        res.on("end", () => {
          try {
            const json = JSON.parse(body);
            if (res.statusCode && res.statusCode >= 400) {
              reject(
                new Error(
                  `LookinBridge error ${res.statusCode}: ${json.error ?? body}`
                )
              );
            } else {
              resolve(json);
            }
          } catch {
            reject(new Error(`Failed to parse response: ${body}`));
          }
        });
      });

      req.on("timeout", () => {
        req.destroy();
        reject(
          new Error(
            `Connection to iOS app timed out (${this.timeoutMs}ms). ` +
              `Make sure the iOS app is running and LookinServer is integrated.`
          )
        );
      });

      req.on("error", (err: NodeJS.ErrnoException) => {
        if (err.code === "ECONNREFUSED") {
          reject(
            new Error(
              `Cannot connect to iOS app on ${this.host}:${this.port}. ` +
                `Make sure:\n` +
                `  1. iOS app is running (Simulator or with iproxy for real device)\n` +
                `  2. LookinServer with MCP bridge is integrated\n` +
                `  3. For real device: run "iproxy 9877 9877" first`
            )
          );
        } else {
          reject(err);
        }
      });

      req.end();
    });
  }

  /** POST 请求，带 JSON body */
  private requestWithBody(
    method: string,
    path: string,
    body: Record<string, unknown>
  ): Promise<unknown> {
    return new Promise((resolve, reject) => {
      const bodyStr = JSON.stringify(body);
      const options: http.RequestOptions = {
        hostname: this.host,
        port: this.port,
        path,
        method,
        headers: {
          "Content-Type": "application/json",
          "Content-Length": Buffer.byteLength(bodyStr),
        },
        timeout: this.timeoutMs,
      };

      const req = http.request(options, (res) => {
        let data = "";
        res.on("data", (chunk) => (data += chunk));
        res.on("end", () => {
          try {
            const json = JSON.parse(data);
            if (res.statusCode && res.statusCode >= 400) {
              reject(
                new Error(
                  `LookinBridge error ${res.statusCode}: ${json.error ?? data}`
                )
              );
            } else {
              resolve(json);
            }
          } catch {
            reject(new Error(`Failed to parse response: ${data}`));
          }
        });
      });

      req.on("timeout", () => {
        req.destroy();
        reject(
          new Error(
            `Connection to iOS app timed out (${this.timeoutMs}ms). ` +
              `Make sure the iOS app is running.`
          )
        );
      });

      req.on("error", (err: NodeJS.ErrnoException) => {
        if (err.code === "ECONNREFUSED") {
          reject(
            new Error(
              `Cannot connect to iOS app on ${this.host}:${this.port}. ` +
                `Make sure the iOS app is running with LookinServer integrated.`
            )
          );
        } else {
          reject(err);
        }
      });

      req.write(bodyStr);
      req.end();
    });
  }

  /** 修改视图属性 */
  async modifyView(
    oid: number,
    modifications: Record<string, unknown>
  ): Promise<{
    success: boolean;
    oid: number;
    modifiedProps: string[];
    errors?: string[];
    error?: string;
  }> {
    const res = await this.requestWithBody("POST", "/modify", {
      oid,
      modifications,
    });
    return res as {
      success: boolean;
      oid: number;
      modifiedProps: string[];
      errors?: string[];
      error?: string;
    };
  }
}
