
#if canImport(UIKit)
import Foundation
import Network

// MARK: - LKS_MCPBridge
// 
// 为 AI（MCP Server）提供一个独立的 HTTP 侧信道。
// 端口：9877（与 Lookin 主协议端口 47164-47179 不冲突）
//
// 支持的接口：
//   GET  /ping             - 健康检查
//   GET  /hierarchy        - 获取最新 UI 层级树（JSON）
//   POST /refresh          - 主动触发重新获取 hierarchy
//
// 使用方式：LKS_MCPBridge.shared.start()

@objc public class LKS_MCPBridge: NSObject {

    // MARK: - Singleton
    @objc public static let shared = LKS_MCPBridge()
    
    // MARK: - Port
    static let port: UInt16 = 9877
    
    // MARK: - State
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.lookin.mcp-bridge", qos: .utility)
    
    /// 最近一次 hierarchy 数据（JSON 序列化后的字典数组）
    private var latestHierarchyJSON: Data?
    private let dataLock = NSLock()
    
    private override init() {
        super.init()
    }
    
    // MARK: - Public API
    
    /// 启动 HTTP Server，如果已启动则忽略
    @objc public func start() {
        guard listener == nil else { return }
        do {
            let params = NWParameters.tcp
            let listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: Self.port)!)
            self.listener = listener
            
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    NSLog("[LKS_MCPBridge] HTTP bridge started on port \(LKS_MCPBridge.port)")
                case .failed(let error):
                    NSLog("[LKS_MCPBridge] Listener failed: \(error)")
                    self?.listener = nil
                default:
                    break
                }
            }
            
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection: connection)
            }
            
            listener.start(queue: queue)
        } catch {
            NSLog("[LKS_MCPBridge] Failed to start listener: \(error)")
        }
    }
    
    /// 停止 HTTP Server
    @objc public func stop() {
        listener?.cancel()
        listener = nil
    }
    
    /// 缓存最新 hierarchy 数据（由 LKS_RequestHandler 调用）
    /// - Parameter hierarchyInfo: LookinHierarchyInfo 对象（ObjC）
    @objc public func cacheLatestHierarchyInfo(_ hierarchyInfo: AnyObject) {
        queue.async { [weak self] in
            guard let self = self else { return }
            if let jsonData = Self.serializeHierarchyInfo(hierarchyInfo) {
                self.dataLock.lock()
                self.latestHierarchyJSON = jsonData
                self.dataLock.unlock()
                NSLog("[LKS_MCPBridge] Hierarchy cached, \(jsonData.count) bytes")
            }
        }
    }
    
    // MARK: - Connection Handling
    
    private func handle(connection: NWConnection) {
        connection.start(queue: queue)
        receive(from: connection)
    }
    
    private func receive(from connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                self.processRequest(data: data, connection: connection)
            }
            if isComplete || error != nil {
                connection.cancel()
            }
        }
    }
    
    private func processRequest(data: Data, connection: NWConnection) {
        guard let requestStr = String(data: data, encoding: .utf8) else {
            sendResponse(connection: connection, status: 400, body: Data("{\"error\":\"bad request\"}".utf8))
            return
        }
        
        // 解析 HTTP 请求行
        let lines = requestStr.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else {
            sendResponse(connection: connection, status: 400, body: Data())
            return
        }
        
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else {
            sendResponse(connection: connection, status: 400, body: Data())
            return
        }
        
        let method = parts[0]
        let path = parts[1].components(separatedBy: "?").first ?? parts[1]
        
        switch (method, path) {
        case ("GET", "/ping"):
            handlePing(connection: connection)
            
        case ("GET", "/hierarchy"):
            handleHierarchy(connection: connection)
            
        case ("POST", "/refresh"):
            handleRefresh(connection: connection)
            
        default:
            let body = Data("{\"error\":\"not found\"}".utf8)
            sendResponse(connection: connection, status: 404, body: body)
        }
    }
    
    // MARK: - Route Handlers
    
    private func handlePing(connection: NWConnection) {
        let response: [String: Any] = [
            "status": "ok",
            "port": Self.port,
            "hasHierarchy": latestHierarchyJSON != nil
        ]
        let body = (try? JSONSerialization.data(withJSONObject: response)) ?? Data()
        sendResponse(connection: connection, status: 200, body: body)
    }
    
    private func handleHierarchy(connection: NWConnection) {
        dataLock.lock()
        let jsonData = latestHierarchyJSON
        dataLock.unlock()
        
        if let jsonData = jsonData {
            sendResponse(connection: connection, status: 200, body: jsonData)
        } else {
            // 没有缓存，尝试实时生成
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                let freshData = Self.generateFreshHierarchy()
                if let freshData = freshData {
                    self.dataLock.lock()
                    self.latestHierarchyJSON = freshData
                    self.dataLock.unlock()
                    self.sendResponse(connection: connection, status: 200, body: freshData)
                } else {
                    let body = Data("{\"error\":\"hierarchy not available yet, trigger a connection from Lookin Mac first\"}".utf8)
                    self.sendResponse(connection: connection, status: 503, body: body)
                }
            }
        }
    }
    
    private func handleRefresh(connection: NWConnection) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let freshData = Self.generateFreshHierarchy()
            if let freshData = freshData {
                self.dataLock.lock()
                self.latestHierarchyJSON = freshData
                self.dataLock.unlock()
                self.sendResponse(connection: connection, status: 200, body: freshData)
            } else {
                let body = Data("{\"error\":\"failed to generate hierarchy\"}".utf8)
                self.sendResponse(connection: connection, status: 500, body: body)
            }
        }
    }
    
    // MARK: - HTTP Response
    
    private func sendResponse(connection: NWConnection, status: Int, body: Data) {
        let statusText: String
        switch status {
        case 200: statusText = "OK"
        case 400: statusText = "Bad Request"
        case 404: statusText = "Not Found"
        case 500: statusText = "Internal Server Error"
        case 503: statusText = "Service Unavailable"
        default: statusText = "Unknown"
        }
        
        let header = """
        HTTP/1.1 \(status) \(statusText)\r
        Content-Type: application/json\r
        Content-Length: \(body.count)\r
        Access-Control-Allow-Origin: *\r
        Connection: close\r
        \r

        """
        
        var response = Data(header.utf8)
        response.append(body)
        
        connection.send(content: response, completion: .contentProcessed { error in
            if let error = error {
                NSLog("[LKS_MCPBridge] Send error: \(error)")
            }
            connection.cancel()
        })
    }
    
    // MARK: - Hierarchy Serialization
    
    /// 从主线程实时生成 hierarchy（无需 Lookin Mac 已连接）
    private static func generateFreshHierarchy() -> Data? {
        // 调用 LookinHierarchyInfo.staticInfoWithLookinVersion:(nil)
        // 用 NSInvocation 风格：先获取 Class 实例，再用 perform on instance
        guard let hierarchyClass = NSClassFromString("LookinHierarchyInfo") as? NSObject.Type else {
            return nil
        }
        let sel = NSSelectorFromString("staticInfoWithLookinVersion:")
        guard hierarchyClass.responds(to: sel) else { return nil }
        // 类方法通过 objc_msgSend 风格调用，Swift 用 value(forKey:) 无法处理带参数的类方法
        // 改用 NSObject perform 的实例形式：先获取 allocated 对象（此处直接用 class object）
        // Swift 调用类方法：NSObject 子类的 perform 仅支持实例；对 Class 用 unsafeBitCast
        let classAsObj = unsafeBitCast(hierarchyClass, to: NSObject.self)
        guard let result = classAsObj.perform(sel, with: nil) else { return nil }
        let info = result.takeUnretainedValue()
        return serializeHierarchyInfo(info)
    }
    
    /// 将 LookinHierarchyInfo 序列化为 JSON Data
    static func serializeHierarchyInfo(_ info: AnyObject) -> Data? {
        // 获取 displayItems 属性
        let displayItemsSel = NSSelectorFromString("displayItems")
        guard info.responds(to: displayItemsSel),
              let items = info.perform(displayItemsSel)?.takeUnretainedValue() as? [AnyObject] else {
            return nil
        }
        
        let jsonArray = items.map { item -> [String: Any] in
            serializeDisplayItem(item)
        }
        
        let root: [String: Any] = [
            "timestamp": Date().timeIntervalSince1970,
            "items": jsonArray
        ]
        
        return try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted])
    }
    
    /// 递归序列化 LookinDisplayItem
    static func serializeDisplayItem(_ item: AnyObject) -> [String: Any] {
        var dict = [String: Any]()
        
        // className
        if let viewObject = item.perform(NSSelectorFromString("viewObject"))?.takeUnretainedValue() {
            if let className = viewObject.perform(NSSelectorFromString("classChainString"))?.takeUnretainedValue() as? String {
                dict["className"] = className
            } else if let selfClassName = viewObject.perform(NSSelectorFromString("selfClassName"))?.takeUnretainedValue() as? String {
                dict["className"] = selfClassName
            }
            // oid (object identifier)
            if let oidValue = viewObject.perform(NSSelectorFromString("oid"))?.takeUnretainedValue() as? NSNumber {
                dict["oid"] = oidValue.uintValue
            }
        } else if let layerObject = item.perform(NSSelectorFromString("layerObject"))?.takeUnretainedValue() {
            if let className = layerObject.perform(NSSelectorFromString("selfClassName"))?.takeUnretainedValue() as? String {
                dict["className"] = className
            }
        }
        
        // isHidden
        if item.responds(to: NSSelectorFromString("isHidden")) {
            let hiddenSel = NSSelectorFromString("isHidden")
            let result = unsafeBitCast(item.perform(hiddenSel), to: NSNumber.self)
            dict["isHidden"] = result.boolValue
        }
        
        // alpha
        if item.responds(to: NSSelectorFromString("alpha")) {
            // alpha is float, need special handling via KVC
            if let alpha = (item as? NSObject)?.value(forKey: "alpha") {
                dict["alpha"] = alpha
            }
        }
        
        // frame
        if let frameStr = (item as? NSObject)?.value(forKeyPath: "frame") as? NSValue {
            let rect = frameStr.cgRectValue
            dict["frame"] = [
                "x": rect.origin.x,
                "y": rect.origin.y,
                "width": rect.size.width,
                "height": rect.size.height
            ]
        }
        
        // customDisplayTitle
        if let title = (item as? NSObject)?.value(forKey: "customDisplayTitle") as? String {
            dict["customDisplayTitle"] = title
        }
        
        // hostViewController
        if let vcObject = item.perform(NSSelectorFromString("hostViewControllerObject"))?.takeUnretainedValue() {
            if let vcClassName = vcObject.perform(NSSelectorFromString("selfClassName"))?.takeUnretainedValue() as? String {
                dict["hostViewController"] = vcClassName
            }
        }
        
        // subitems (递归)
        if let subitems = (item as? NSObject)?.value(forKey: "subitems") as? [AnyObject] {
            dict["children"] = subitems.map { serializeDisplayItem($0) }
        }
        
        return dict
    }
}

#endif
