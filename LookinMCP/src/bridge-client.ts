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

export interface DisplayItem {
  className?: string;
  oid?: number;
  isHidden?: boolean;
  alpha?: number;
  frame?: ViewFrame;
  customDisplayTitle?: string;
  hostViewController?: string;
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
}
