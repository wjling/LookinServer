
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
        guard let hierarchyClass = NSClassFromString("LookinHierarchyInfo") as? NSObject.Type else {
            return nil
        }
        // 使用 KVC 方式：通过 NSInvocation-free 的 ObjC runtime 调用类方法
        // perform() 对类方法也适用，但返回值是对象指针，工厂方法 (+1 retain) 需要 takeRetainedValue
        // 若日后改为实例方法可换成 value(forKey:)
        let sel = NSSelectorFromString("staticInfoWithLookinVersion:")
        guard hierarchyClass.responds(to: sel) else { return nil }
        // staticInfoWithLookinVersion: 不符合 create rule（非 alloc/new/copy），ObjC ARC 返回 +0（autorelease）
        // 必须用 takeUnretainedValue()，否则 Swift 再 release 一次 → double free → crash
        let version = lookinServerVersion()
        guard let info = hierarchyClass.perform(sel, with: version)?.takeUnretainedValue() else {
            return nil
        }
        return serializeHierarchyInfo(info)
    }
    
    /// 将 LookinHierarchyInfo 序列化为 JSON Data
    static func serializeHierarchyInfo(_ info: AnyObject) -> Data? {
        // 用 KVC 获取 displayItems，安全处理各种返回类型
        guard let infoObj = info as? NSObject,
              let items = infoObj.value(forKey: "displayItems") as? [AnyObject] else {
            return nil
        }
        
        let jsonArray = items.map { serializeDisplayItem($0) }
        
        let root: [String: Any] = [
            "timestamp": Date().timeIntervalSince1970,
            "items": jsonArray
        ]
        
        return try? JSONSerialization.data(withJSONObject: root, options: [.prettyPrinted])
    }
    
    /// 递归序列化 LookinDisplayItem
    ///
    /// 安全原则：
    /// 1. 只读取 LookinDisplayItem.h 中**明确声明**的属性，避免 NSUndefinedKeyException
    /// 2. 用 responds(to:) 守门，防止跨版本属性缺失导致的 crash
    /// 3. KVC 自动处理基本类型装箱（BOOL/float/CGRect → NSNumber/NSValue）
    static func serializeDisplayItem(_ item: AnyObject) -> [String: Any] {
        var dict = [String: Any]()
        guard let itemObj = item as? NSObject else { return dict }
        
        // className / oid：从 viewObject 或 layerObject（均为 LookinObject 类型）读取
        // LookinObject.classChainList: [String]，第一个元素是自身 class 名
        // LookinObject.oid: unsigned long，KVC 自动装箱为 NSNumber
        if let viewObject = kvcObject(itemObj, key: "viewObject") {
            if let chainList = viewObject.value(forKey: "classChainList") as? [String],
               let first = chainList.first {
                dict["className"] = first
            }
            if let oidNum = viewObject.value(forKey: "oid") as? NSNumber {
                dict["oid"] = oidNum.uintValue
            }
        } else if let layerObject = kvcObject(itemObj, key: "layerObject") {
            if let chainList = layerObject.value(forKey: "classChainList") as? [String],
               let first = chainList.first {
                dict["className"] = first
            }
            if let oidNum = layerObject.value(forKey: "oid") as? NSNumber {
                dict["oid"] = oidNum.uintValue
            }
        }

        // customDisplayTitle：用户自定义的展示标题（可选）
        if let title = kvcString(itemObj, key: "customDisplayTitle") {
            dict["customDisplayTitle"] = title
        }

        // hostViewController（LookinObject，同样读 classChainList）
        if let vcObject = kvcObject(itemObj, key: "hostViewControllerObject"),
           let chainList = vcObject.value(forKey: "classChainList") as? [String],
           let first = chainList.first {
            dict["hostViewController"] = first
        }

        // isHidden（BOOL → NSNumber via KVC）
        if let hidden = kvcNumber(itemObj, key: "isHidden") {
            dict["isHidden"] = hidden.boolValue
        }

        // alpha（float → NSNumber via KVC）
        if let alpha = kvcNumber(itemObj, key: "alpha") {
            dict["alpha"] = alpha.floatValue
        }

        // frame（CGRect → NSValue via KVC）
        if let frameValue = kvcValue(itemObj, key: "frame") {
            let rect = frameValue.cgRectValue
            dict["frame"] = [
                "x": Double(rect.origin.x),
                "y": Double(rect.origin.y),
                "width": Double(rect.size.width),
                "height": Double(rect.size.height)
            ]
        }

        // customInfo：判断是否为 custom display item
        if kvcObject(itemObj, key: "customInfo") != nil {
            dict["isCustom"] = true
        }

        // subitems（递归）
        if let subitems = kvcArray(itemObj, key: "subitems") {
            dict["children"] = subitems.map { serializeDisplayItem($0) }
        }
        
        return dict
    }
    
    // MARK: - Version Helper

    /// 读取 LookinServer 的真实版本号
    /// 优先从 LKS_VersionManager（ObjC class）读，fallback 读 Bundle，最终 fallback "1.0.0"
    private static func lookinServerVersion() -> String {
        // 方案1：LookinServer 自身有 +lookinVersion 类方法
        if let cls = NSClassFromString("LKS_VersionManager") as? NSObject.Type,
           cls.responds(to: NSSelectorFromString("lookinVersion")),
           let v = cls.perform(NSSelectorFromString("lookinVersion"))?.takeUnretainedValue() as? String {
            return v
        }
        // 方案2：读 Bundle 里的 CFBundleShortVersionString
        if let v = Bundle(for: LKS_MCPBridge.self).infoDictionary?["CFBundleShortVersionString"] as? String,
           v.split(separator: ".").count == 3 {
            return v
        }
        // 方案3：hardcode 当前已知版本，格式合法即可
        return "1.2.8"
    }

    // MARK: - KVC Safe Helpers
    // 用 responds(to:) 守门，避免 NSUndefinedKeyException crash
    
    private static func kvcObject(_ obj: NSObject, key: String) -> NSObject? {
        let sel = NSSelectorFromString(key)
        guard obj.responds(to: sel) else { return nil }
        return obj.value(forKey: key) as? NSObject
    }
    
    private static func kvcString(_ obj: NSObject, key: String) -> String? {
        let sel = NSSelectorFromString(key)
        guard obj.responds(to: sel) else { return nil }
        return obj.value(forKey: key) as? String
    }
    
    private static func kvcNumber(_ obj: NSObject, key: String) -> NSNumber? {
        let sel = NSSelectorFromString(key)
        guard obj.responds(to: sel) else { return nil }
        return obj.value(forKey: key) as? NSNumber
    }
    
    private static func kvcValue(_ obj: NSObject, key: String) -> NSValue? {
        let sel = NSSelectorFromString(key)
        guard obj.responds(to: sel) else { return nil }
        return obj.value(forKey: key) as? NSValue
    }
    
    private static func kvcArray(_ obj: NSObject, key: String) -> [AnyObject]? {
        let sel = NSSelectorFromString(key)
        guard obj.responds(to: sel) else { return nil }
        return obj.value(forKey: key) as? [AnyObject]
    }
}

#endif
