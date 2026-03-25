#ifdef SHOULD_COMPILE_LOOKIN_SERVER

//
//  LKS_MCPBridge.m
//  LookinServer
//

#import "LKS_MCPBridge.h"

#if TARGET_OS_IOS || TARGET_OS_TV || TARGET_OS_VISION

#import <UIKit/UIKit.h>

#include <sys/socket.h>
#include <netinet/in.h>
#include <unistd.h>

static const uint16_t kMCPBridgePort = 9877;

@interface LKS_MCPBridge ()

@property (nonatomic, assign) int serverSocket;
@property (nonatomic, strong) dispatch_source_t acceptSource;
@property (nonatomic, strong) dispatch_queue_t queue;

/// 最近一次 hierarchy 数据（JSON 序列化后）
@property (nonatomic, strong, nullable) NSData *latestHierarchyJSON;
@property (nonatomic, strong) NSLock *dataLock;

@end

@implementation LKS_MCPBridge

#pragma mark - Singleton

+ (instancetype)sharedInstance {
    static LKS_MCPBridge *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[LKS_MCPBridge alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _serverSocket = -1;
        _queue = dispatch_queue_create("com.lookin.mcp-bridge", DISPATCH_QUEUE_SERIAL);
        _dataLock = [[NSLock alloc] init];
    }
    return self;
}

- (void)dealloc {
    [self stop];
}

#pragma mark - Public API

- (void)start {
    if (self.acceptSource != nil) {
        return; // 已启动
    }

    // 创建 TCP socket
    int fd = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (fd < 0) {
        NSLog(@"[LKS_MCPBridge] Failed to create socket: %s", strerror(errno));
        return;
    }

    // 允许地址复用
    int yes = 1;
    setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, sizeof(yes));
    setsockopt(fd, SOL_SOCKET, SO_REUSEPORT, &yes, sizeof(yes));

    // 绑定端口
    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family      = AF_INET;
    addr.sin_addr.s_addr = htonl(INADDR_LOOPBACK); // 仅本地访问，更安全
    addr.sin_port        = htons(kMCPBridgePort);

    if (bind(fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        NSLog(@"[LKS_MCPBridge] Failed to bind port %d: %s", kMCPBridgePort, strerror(errno));
        close(fd);
        return;
    }

    if (listen(fd, 16) < 0) {
        NSLog(@"[LKS_MCPBridge] Failed to listen: %s", strerror(errno));
        close(fd);
        return;
    }

    self.serverSocket = fd;

    // 用 GCD source 监听新连接，避免阻塞线程
    dispatch_source_t source = dispatch_source_create(DISPATCH_SOURCE_TYPE_READ, fd, 0, self.queue);
    self.acceptSource = source;

    __weak typeof(self) weakSelf = self;
    dispatch_source_set_event_handler(source, ^{
        [weakSelf acceptNewConnection];
    });
    dispatch_source_set_cancel_handler(source, ^{
        close(fd);
        NSLog(@"[LKS_MCPBridge] Server socket closed.");
    });

    dispatch_resume(source);
    NSLog(@"[LKS_MCPBridge] HTTP bridge started on port %d (loopback only)", kMCPBridgePort);
}

- (void)stop {
    if (self.acceptSource) {
        dispatch_source_cancel(self.acceptSource);
        self.acceptSource = nil;
    }
    self.serverSocket = -1;
}

- (void)cacheLatestHierarchyInfo:(NSObject *)hierarchyInfo {
    dispatch_async(self.queue, ^{
        NSData *jsonData = [LKS_MCPBridge serializeHierarchyInfo:hierarchyInfo];
        if (jsonData) {
            [self.dataLock lock];
            self.latestHierarchyJSON = jsonData;
            [self.dataLock unlock];
            NSLog(@"[LKS_MCPBridge] Hierarchy cached, %lu bytes", (unsigned long)jsonData.length);
        }
    });
}

#pragma mark - Accept Connection

- (void)acceptNewConnection {
    struct sockaddr_in clientAddr;
    socklen_t clientAddrLen = sizeof(clientAddr);
    int clientFd = accept(self.serverSocket, (struct sockaddr *)&clientAddr, &clientAddrLen);
    if (clientFd < 0) {
        if (errno != EWOULDBLOCK) {
            NSLog(@"[LKS_MCPBridge] accept() error: %s", strerror(errno));
        }
        return;
    }

    // 每个连接在同一个 serial queue 上处理即可（HTTP/1.0 短连接）
    dispatch_async(self.queue, ^{
        [self handleClientSocket:clientFd];
    });
}

#pragma mark - Request Handling

- (void)handleClientSocket:(int)clientFd {
    // 读取请求（最多 64KB）
    char buffer[65536];
    ssize_t bytesRead = recv(clientFd, buffer, sizeof(buffer) - 1, 0);
    if (bytesRead <= 0) {
        close(clientFd);
        return;
    }
    buffer[bytesRead] = '\0';
    NSString *requestStr = [NSString stringWithUTF8String:buffer];
    if (!requestStr) {
        [self sendResponse:clientFd status:400 body:[@"{\"error\":\"bad request\"}" dataUsingEncoding:NSUTF8StringEncoding]];
        return;
    }

    // 解析请求行："GET /path HTTP/1.1"
    NSArray<NSString *> *lines = [requestStr componentsSeparatedByString:@"\r\n"];
    if (lines.count == 0) {
        [self sendResponse:clientFd status:400 body:[NSData data]];
        return;
    }
    NSArray<NSString *> *parts = [lines[0] componentsSeparatedByString:@" "];
    if (parts.count < 2) {
        [self sendResponse:clientFd status:400 body:[NSData data]];
        return;
    }

    NSString *method = parts[0];
    // 去掉 query string
    NSString *fullPath = parts[1];
    NSString *path = [fullPath componentsSeparatedByString:@"?"].firstObject ?: fullPath;

    if ([method isEqualToString:@"GET"] && [path isEqualToString:@"/ping"]) {
        [self handlePing:clientFd];
    } else if ([method isEqualToString:@"GET"] && [path isEqualToString:@"/hierarchy"]) {
        [self handleHierarchy:clientFd];
    } else if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/refresh"]) {
        [self handleRefresh:clientFd];
    } else {
        [self sendResponse:clientFd status:404 body:[@"{\"error\":\"not found\"}" dataUsingEncoding:NSUTF8StringEncoding]];
    }
}

#pragma mark - Route Handlers

- (void)handlePing:(int)clientFd {
    [self.dataLock lock];
    BOOL hasHierarchy = self.latestHierarchyJSON != nil;
    [self.dataLock unlock];

    NSDictionary *response = @{
        @"status": @"ok",
        @"port": @(kMCPBridgePort),
        @"hasHierarchy": @(hasHierarchy)
    };
    NSData *body = [NSJSONSerialization dataWithJSONObject:response options:0 error:nil];
    [self sendResponse:clientFd status:200 body:body ?: [NSData data]];
}

- (void)handleHierarchy:(int)clientFd {
    [self.dataLock lock];
    NSData *jsonData = self.latestHierarchyJSON;
    [self.dataLock unlock];

    if (jsonData) {
        [self sendResponse:clientFd status:200 body:jsonData];
    } else {
        // 没有缓存，尝试实时生成（需主线程）
        dispatch_semaphore_t sema = dispatch_semaphore_create(0);
        __block NSData *freshData = nil;
        dispatch_async(dispatch_get_main_queue(), ^{
            freshData = [LKS_MCPBridge generateFreshHierarchy];
            dispatch_semaphore_signal(sema);
        });
        dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));

        if (freshData) {
            [self.dataLock lock];
            self.latestHierarchyJSON = freshData;
            [self.dataLock unlock];
            [self sendResponse:clientFd status:200 body:freshData];
        } else {
            NSString *msg = @"{\"error\":\"hierarchy not available yet, trigger a connection from Lookin Mac first\"}";
            [self sendResponse:clientFd status:503 body:[msg dataUsingEncoding:NSUTF8StringEncoding]];
        }
    }
}

- (void)handleRefresh:(int)clientFd {
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    __block NSData *freshData = nil;
    dispatch_async(dispatch_get_main_queue(), ^{
        freshData = [LKS_MCPBridge generateFreshHierarchy];
        dispatch_semaphore_signal(sema);
    });
    dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));

    if (freshData) {
        [self.dataLock lock];
        self.latestHierarchyJSON = freshData;
        [self.dataLock unlock];
        [self sendResponse:clientFd status:200 body:freshData];
    } else {
        NSString *msg = @"{\"error\":\"failed to generate hierarchy\"}";
        [self sendResponse:clientFd status:500 body:[msg dataUsingEncoding:NSUTF8StringEncoding]];
    }
}

#pragma mark - HTTP Response

- (void)sendResponse:(int)clientFd status:(NSInteger)status body:(NSData *)body {
    NSString *statusText;
    switch (status) {
        case 200: statusText = @"OK";                    break;
        case 400: statusText = @"Bad Request";            break;
        case 404: statusText = @"Not Found";              break;
        case 500: statusText = @"Internal Server Error";  break;
        case 503: statusText = @"Service Unavailable";    break;
        default:  statusText = @"Unknown";                break;
    }

    NSString *headerStr = [NSString stringWithFormat:
        @"HTTP/1.1 %ld %@\r\n"
        @"Content-Type: application/json\r\n"
        @"Content-Length: %lu\r\n"
        @"Access-Control-Allow-Origin: *\r\n"
        @"Connection: close\r\n"
        @"\r\n",
        (long)status, statusText, (unsigned long)body.length];

    NSData *headerData = [headerStr dataUsingEncoding:NSUTF8StringEncoding];

    // 发送 header
    send(clientFd, headerData.bytes, headerData.length, 0);
    // 发送 body
    if (body.length > 0) {
        send(clientFd, body.bytes, body.length, 0);
    }
    close(clientFd);
}

#pragma mark - Hierarchy Serialization

/// 从主线程实时生成 hierarchy（无需 Lookin Mac 已连接）
+ (nullable NSData *)generateFreshHierarchy {
    Class hierarchyClass = NSClassFromString(@"LookinHierarchyInfo");
    if (!hierarchyClass) { return nil; }

    SEL sel = NSSelectorFromString(@"staticInfoWithLookinVersion:");
    if (![hierarchyClass respondsToSelector:sel]) { return nil; }

    NSString *version = [self lookinServerVersion];

    // staticInfoWithLookinVersion: 不符合 create rule，返回 autorelease 对象（+0）
    // 使用 NSInvocation 安全调用，避免 ARC 对 performSelector: 的 retain 警告
    NSInvocation *inv = [NSInvocation invocationWithMethodSignature:
                         [hierarchyClass methodSignatureForSelector:sel]];
    inv.target   = hierarchyClass;
    inv.selector = sel;
    [inv setArgument:&version atIndex:2];
    [inv invoke];

    __unsafe_unretained id result = nil;
    [inv getReturnValue:&result];
    if (!result) { return nil; }

    return [self serializeHierarchyInfo:result];
}

/// 将 LookinHierarchyInfo 序列化为 JSON Data
+ (nullable NSData *)serializeHierarchyInfo:(NSObject *)info {
    if (![info respondsToSelector:NSSelectorFromString(@"displayItems")]) {
        return nil;
    }
    NSArray *items = [info valueForKey:@"displayItems"];
    if (![items isKindOfClass:[NSArray class]]) { return nil; }

    NSMutableArray *jsonArray = [NSMutableArray arrayWithCapacity:items.count];
    for (id item in items) {
        [jsonArray addObject:[self serializeDisplayItem:item]];
    }

    NSDictionary *root = @{
        @"timestamp": @([[NSDate date] timeIntervalSince1970]),
        @"items": jsonArray
    };
    return [NSJSONSerialization dataWithJSONObject:root
                                          options:NSJSONWritingPrettyPrinted
                                            error:nil];
}

/// 递归序列化 LookinDisplayItem
+ (NSDictionary *)serializeDisplayItem:(NSObject *)item {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    if (!item || ![item isKindOfClass:[NSObject class]]) { return dict; }

    // className / oid：从 viewObject 或 layerObject 读取
    NSObject *viewObject  = [self kvcObject:item key:@"viewObject"];
    NSObject *layerObject = viewObject ? nil : [self kvcObject:item key:@"layerObject"];
    NSObject *targetObject = viewObject ?: layerObject;

    if (targetObject) {
        NSArray *chainList = [self kvcArray:targetObject key:@"classChainList"];
        if (chainList.count > 0) {
            dict[@"className"] = chainList.firstObject;
        }
        NSNumber *oidNum = [self kvcNumber:targetObject key:@"oid"];
        if (oidNum) {
            dict[@"oid"] = @(oidNum.unsignedLongValue);
        }
    }

    // customDisplayTitle
    NSString *title = [self kvcString:item key:@"customDisplayTitle"];
    if (title) { dict[@"customDisplayTitle"] = title; }

    // hostViewControllerObject
    NSObject *vcObject = [self kvcObject:item key:@"hostViewControllerObject"];
    if (vcObject) {
        NSArray *chainList = [self kvcArray:vcObject key:@"classChainList"];
        if (chainList.count > 0) {
            dict[@"hostViewController"] = chainList.firstObject;
        }
    }

    // isHidden
    NSNumber *hidden = [self kvcNumber:item key:@"isHidden"];
    if (hidden) { dict[@"isHidden"] = @(hidden.boolValue); }

    // alpha
    NSNumber *alpha = [self kvcNumber:item key:@"alpha"];
    if (alpha) { dict[@"alpha"] = @(alpha.floatValue); }

    // frame（CGRect stored as NSValue）
    NSValue *frameValue = [self kvcValue:item key:@"frame"];
    if (frameValue) {
        CGRect rect = frameValue.CGRectValue;
        dict[@"frame"] = @{
            @"x":      @(rect.origin.x),
            @"y":      @(rect.origin.y),
            @"width":  @(rect.size.width),
            @"height": @(rect.size.height)
        };
    }

    // customInfo（自定义节点：不对应真实 View，但有业务语义）
    NSObject *customInfo = [self kvcObject:item key:@"customInfo"];
    if (customInfo) {
        dict[@"isCustom"] = @YES;
        NSString *customTitle = [self kvcString:customInfo key:@"title"];
        if (customTitle.length > 0) { dict[@"customTitle"] = customTitle; }
        NSString *customSubtitle = [self kvcString:customInfo key:@"subtitle"];
        if (customSubtitle.length > 0) { dict[@"customSubtitle"] = customSubtitle; }
        NSValue *frameInWindow = [self kvcValue:customInfo key:@"frameInWindow"];
        if (frameInWindow) {
            CGRect rect = frameInWindow.CGRectValue;
            dict[@"frameInWindow"] = @{
                @"x":      @(rect.origin.x),
                @"y":      @(rect.origin.y),
                @"width":  @(rect.size.width),
                @"height": @(rect.size.height)
            };
        }
    }

    // children（递归）
    NSArray *subitems = [self kvcArray:item key:@"subitems"];
    if (subitems) {
        NSMutableArray *children = [NSMutableArray arrayWithCapacity:subitems.count];
        for (id subitem in subitems) {
            [children addObject:[self serializeDisplayItem:subitem]];
        }
        dict[@"children"] = children;
    }

    return dict;
}

#pragma mark - Version Helper

+ (NSString *)lookinServerVersion {
    // 方案1：LookinServer 自身有 +lookinVersion 类方法
    Class cls = NSClassFromString(@"LKS_VersionManager");
    SEL sel = NSSelectorFromString(@"lookinVersion");
    if (cls && [cls respondsToSelector:sel]) {
        NSInvocation *inv = [NSInvocation invocationWithMethodSignature:
                             [cls methodSignatureForSelector:sel]];
        inv.target   = cls;
        inv.selector = sel;
        [inv invoke];
        __unsafe_unretained NSString *v = nil;
        [inv getReturnValue:&v];
        if ([v isKindOfClass:[NSString class]] && v.length > 0) {
            return v;
        }
    }
    // 方案2：读 Bundle 里的 CFBundleShortVersionString（framework 场景）
    NSString *bundleVersion = [NSBundle mainBundle].infoDictionary[@"CFBundleShortVersionString"];
    if ([bundleVersion componentsSeparatedByString:@"."].count == 3) {
        return bundleVersion;
    }
    // 方案3：fallback
    return @"1.2.8";
}

#pragma mark - KVC Safe Helpers

+ (nullable NSObject *)kvcObject:(NSObject *)obj key:(NSString *)key {
    if (![obj respondsToSelector:NSSelectorFromString(key)]) { return nil; }
    id value = [obj valueForKey:key];
    return [value isKindOfClass:[NSObject class]] ? value : nil;
}

+ (nullable NSString *)kvcString:(NSObject *)obj key:(NSString *)key {
    if (![obj respondsToSelector:NSSelectorFromString(key)]) { return nil; }
    id value = [obj valueForKey:key];
    return [value isKindOfClass:[NSString class]] ? value : nil;
}

+ (nullable NSNumber *)kvcNumber:(NSObject *)obj key:(NSString *)key {
    if (![obj respondsToSelector:NSSelectorFromString(key)]) { return nil; }
    id value = [obj valueForKey:key];
    return [value isKindOfClass:[NSNumber class]] ? value : nil;
}

+ (nullable NSValue *)kvcValue:(NSObject *)obj key:(NSString *)key {
    if (![obj respondsToSelector:NSSelectorFromString(key)]) { return nil; }
    id value = [obj valueForKey:key];
    return [value isKindOfClass:[NSValue class]] ? value : nil;
}

+ (nullable NSArray *)kvcArray:(NSObject *)obj key:(NSString *)key {
    if (![obj respondsToSelector:NSSelectorFromString(key)]) { return nil; }
    id value = [obj valueForKey:key];
    return [value isKindOfClass:[NSArray class]] ? value : nil;
}

@end

#endif /* TARGET_OS_IOS || TARGET_OS_TV || TARGET_OS_VISION */

#endif /* SHOULD_COMPILE_LOOKIN_SERVER */
