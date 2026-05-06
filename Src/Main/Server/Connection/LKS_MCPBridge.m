#ifdef SHOULD_COMPILE_LOOKIN_SERVER

//
//  LKS_MCPBridge.m
//  LookinServer
//

#import "LKS_MCPBridge.h"

#if TARGET_OS_IOS || TARGET_OS_TV || TARGET_OS_VISION

#import <UIKit/UIKit.h>
#import "NSObject+LookinServer.h"
#import "LKS_AttrGroupsMaker.h"
#import "LookinAttributesGroup.h"
#import "LookinAttributesSection.h"
#import "LookinAttribute.h"

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
    // 循环读取直到收到完整 HTTP header（以 \r\n\r\n 结尾）或超过 64KB 限制
    // 单次 recv 不保证读完所有 TCP 数据，必须循环
    char buffer[65536];
    size_t totalRead = 0;
    BOOL headerComplete = NO;

    while (totalRead < sizeof(buffer) - 1) {
        ssize_t n = recv(clientFd, buffer + totalRead, sizeof(buffer) - 1 - totalRead, 0);
        if (n < 0) {
            if (errno == EINTR) { continue; } // 被信号中断，重试
            break; // 真实错误
        }
        if (n == 0) { break; } // 连接关闭
        totalRead += n;
        buffer[totalRead] = '\0';
        // 检测 HTTP header 是否已完整（以 \r\n\r\n 结尾）
        if (memmem(buffer, totalRead, "\r\n\r\n", 4) != NULL) {
            headerComplete = YES;
            break;
        }
    }

    if (totalRead == 0) {
        close(clientFd);
        return;
    }
    buffer[totalRead] = '\0';
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
    
    // 解析 HTTP body（用于 POST 请求）
    NSData *httpBody = nil;
    if ([method isEqualToString:@"POST"]) {
        // 查找 Content-Length
        NSInteger contentLength = 0;
        for (NSString *line in lines) {
            if ([line.lowercaseString hasPrefix:@"content-length:"]) {
                NSString *lengthStr = [[line substringFromIndex:15] stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
                contentLength = [lengthStr integerValue];
                break;
            }
        }
        
        // 查找 header 结束位置（\r\n\r\n）
        NSRange headerEndRange = [requestStr rangeOfString:@"\r\n\r\n"];
        if (headerEndRange.location != NSNotFound && contentLength > 0) {
            NSUInteger bodyStartInBuffer = headerEndRange.location + 4;
            NSUInteger bodyAlreadyRead = totalRead - bodyStartInBuffer;
            
            // 已读取的 body 部分
            NSMutableData *bodyData = [NSMutableData dataWithBytes:buffer + bodyStartInBuffer length:bodyAlreadyRead];
            
            // 如果还有剩余 body 需要读取
            while ((NSInteger)bodyData.length < contentLength) {
                char bodyBuffer[4096];
                ssize_t n = recv(clientFd, bodyBuffer, MIN(sizeof(bodyBuffer), contentLength - bodyData.length), 0);
                if (n <= 0) break;
                [bodyData appendBytes:bodyBuffer length:n];
            }
            httpBody = bodyData;
        }
    }

    if ([method isEqualToString:@"GET"] && [path isEqualToString:@"/ping"]) {
        [self handlePing:clientFd];
    } else if ([method isEqualToString:@"GET"] && [path isEqualToString:@"/hierarchy"]) {
        [self handleHierarchy:clientFd];
    } else if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/refresh"]) {
        [self handleRefresh:clientFd];
    } else if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/modify"]) {
        [self handleModify:clientFd httpBody:httpBody];
    } else if ([method isEqualToString:@"POST"] && [path isEqualToString:@"/view_attrs"]) {
        [self handleViewAttrs:clientFd httpBody:httpBody];
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
/// 保持轻量：不包含 attributesGroupList，详细属性通过 /view_attrs 接口按需获取
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

    // ── Figma 对比所需扩展属性 ─────────────────────────────────────────────

    // backgroundColor（来自 LookinDisplayItem.backgroundColor，类型为 LookinColor/UIColor）
    NSObject *bgColorObj = [self kvcObject:item key:@"backgroundColor"];
    if (bgColorObj) {
        NSDictionary *colorDict = [self serializeColor:bgColorObj];
        if (colorDict) { dict[@"backgroundColor"] = colorDict; }
    }

    // 从 attributesGroupList 中提取详细属性
    NSArray *attrGroupList = [self kvcArray:item key:@"attributesGroupList"];
    if (attrGroupList.count > 0) {
        NSMutableDictionary *layerAttrs = [NSMutableDictionary dictionary];
        NSMutableDictionary *labelAttrs = [NSMutableDictionary dictionary];
        NSMutableDictionary *stackAttrs = [NSMutableDictionary dictionary];

        for (NSObject *group in attrGroupList) {
            NSArray *sections = [self kvcArray:group key:@"sections"];
            for (NSObject *section in sections) {
                NSString *sectionId = [self kvcString:section key:@"identifier"];
                NSArray *attrs = [self kvcArray:section key:@"attributes"];

                // ViewLayer - cornerRadius
                if ([sectionId hasSuffix:@"Corner"]) {
                    for (NSObject *attr in attrs) {
                        id value = [self kvcObject:attr key:@"value"];
                        if ([value isKindOfClass:[NSNumber class]]) {
                            layerAttrs[@"cornerRadius"] = value; break;
                        }
                    }
                }
                // ViewLayer - border
                else if ([sectionId hasSuffix:@"Border"]) {
                    for (NSObject *attr in attrs) {
                        NSString *attrId = [self kvcString:attr key:@"identifier"];
                        id value = [self kvcObject:attr key:@"value"];
                        if (!value) continue;
                        if ([attrId hasSuffix:@"Width"] && [value isKindOfClass:[NSNumber class]]) {
                            layerAttrs[@"borderWidth"] = value;
                        } else if ([attrId hasSuffix:@"Color"]) {
                            NSDictionary *c = [self serializeColor:value];
                            if (c) { layerAttrs[@"borderColor"] = c; }
                        }
                    }
                }
                // ViewLayer - shadow
                else if ([sectionId hasSuffix:@"Shadow"]) {
                    for (NSObject *attr in attrs) {
                        NSString *attrId = [self kvcString:attr key:@"identifier"];
                        id value = [self kvcObject:attr key:@"value"];
                        if (!value || ![value isKindOfClass:[NSNumber class]]) {
                            // 颜色单独走序列化
                            if ([attrId hasSuffix:@"Color"]) {
                                NSDictionary *c = [self serializeColor:value];
                                if (c) { layerAttrs[@"shadowColor"] = c; }
                            }
                            continue;
                        }
                        if ([attrId hasSuffix:@"Opacity"]) {
                            layerAttrs[@"shadowOpacity"] = value;
                        } else if ([attrId hasSuffix:@"Radius"]) {
                            layerAttrs[@"shadowRadius"] = value;
                        } else if ([attrId hasSuffix:@"OffsetW"]) {
                            layerAttrs[@"shadowOffsetWidth"] = value;
                        } else if ([attrId hasSuffix:@"OffsetH"]) {
                            layerAttrs[@"shadowOffsetHeight"] = value;
                        }
                    }
                }
                // ── P0 核心属性（高效版本）──
                else if ([sectionId hasSuffix:@"ContentMode"]) {
                    for (NSObject *attr in attrs) {
                        id value = [self kvcObject:attr key:@"value"];
                        if ([value isKindOfClass:[NSNumber class]]) {
                            layerAttrs[@"contentMode"] = value;
                            break;
                        }
                    }
                }
                else if ([sectionId isEqualToString:@"v_i"]) {  // InterationAndMasks 的简写标识符
                    for (NSObject *attr in attrs) {
                        NSString *attrId = [self kvcString:attr key:@"identifier"];
                        if ([attrId hasSuffix:@"MasksToBounds"]) {
                            id value = [self kvcObject:attr key:@"value"];
                            if ([value isKindOfClass:[NSNumber class]]) {
                                BOOL boolValue = [value boolValue];
                                layerAttrs[@"masksToBounds"] = @(boolValue);
                                layerAttrs[@"clipsToBounds"] = @(boolValue);
                                break;
                            }
                        }
                    }
                }
                else if ([sectionId hasSuffix:@"TintColor"]) {
                    for (NSObject *attr in attrs) {
                        id value = [self kvcObject:attr key:@"value"];
                        if (value) {
                            NSDictionary *c = [self serializeColor:value];
                            if (c) { layerAttrs[@"tintColor"] = c; break; }
                        }
                    }
                }
                // UILabel - text
                else if ([sectionId hasSuffix:@"UILabel_Text"]) {
                    for (NSObject *attr in attrs) {
                        id value = [self kvcObject:attr key:@"value"];
                        if (value && [value isKindOfClass:[NSString class]]) {
                            labelAttrs[@"text"] = value;
                        }
                    }
                }
                // UILabel - font
                else if ([sectionId hasSuffix:@"UILabel_Font"]) {
                    for (NSObject *attr in attrs) {
                        NSString *attrId = [self kvcString:attr key:@"identifier"];
                        id value = [self kvcObject:attr key:@"value"];
                        if (!value) continue;
                        if ([attrId hasSuffix:@"Name"] && [value isKindOfClass:[NSString class]]) {
                            labelAttrs[@"fontName"] = value;
                            // 从字体名称推断 fontWeight
                            NSString *fontName = (NSString *)value;
                            if ([fontName containsString:@"Bold"]) {
                                labelAttrs[@"fontWeight"] = @700;
                            } else if ([fontName containsString:@"Semibold"] || [fontName containsString:@"SemiBold"]) {
                                labelAttrs[@"fontWeight"] = @600;
                            } else if ([fontName containsString:@"Medium"]) {
                                labelAttrs[@"fontWeight"] = @500;
                            } else if ([fontName containsString:@"Light"]) {
                                labelAttrs[@"fontWeight"] = @300;
                            } else if ([fontName containsString:@"Thin"]) {
                                labelAttrs[@"fontWeight"] = @100;
                            } else if ([fontName containsString:@"Regular"] || [fontName containsString:@"Normal"]) {
                                labelAttrs[@"fontWeight"] = @400;
                            } else {
                                labelAttrs[@"fontWeight"] = @400; // 默认 Regular
                            }
                        } else if ([attrId hasSuffix:@"Size"] && [value isKindOfClass:[NSNumber class]]) {
                            labelAttrs[@"fontSize"] = value;
                        }
                    }
                }
                // UILabel - textColor
                else if ([sectionId hasSuffix:@"UILabel_TextColor"]) {
                    for (NSObject *attr in attrs) {
                        id value = [self kvcObject:attr key:@"value"];
                        if (value) {
                            NSDictionary *c = [self serializeColor:value];
                            if (c) { labelAttrs[@"textColor"] = c; }
                        }
                    }
                }
                // UILabel - numberOfLines
                else if ([sectionId hasSuffix:@"NumberOfLines"]) {
                    for (NSObject *attr in attrs) {
                        id value = [self kvcObject:attr key:@"value"];
                        if ([value isKindOfClass:[NSNumber class]]) {
                            labelAttrs[@"numberOfLines"] = value; break;
                        }
                    }
                }
                // UILabel - alignment
                else if ([sectionId hasSuffix:@"UILabel_Alignment"]) {
                    for (NSObject *attr in attrs) {
                        id value = [self kvcObject:attr key:@"value"];
                        if ([value isKindOfClass:[NSNumber class]]) {
                            labelAttrs[@"textAlignment"] = value; break;
                        }
                    }
                }
                // UILabel - lineBreakMode
                else if ([sectionId hasSuffix:@"BreakMode"]) {
                    for (NSObject *attr in attrs) {
                        id value = [self kvcObject:attr key:@"value"];
                        if ([value isKindOfClass:[NSNumber class]]) {
                            labelAttrs[@"lineBreakMode"] = value; break;
                        }
                    }
                }
                // UIStackView - axis
                else if ([sectionId hasSuffix:@"UIStackView_Axis"]) {
                    for (NSObject *attr in attrs) {
                        id value = [self kvcObject:attr key:@"value"];
                        if ([value isKindOfClass:[NSNumber class]]) {
                            // axis: 0=horizontal, 1=vertical
                            stackAttrs[@"axis"] = ([value intValue] == 1) ? @"vertical" : @"horizontal";
                            break;
                        }
                    }
                }
                // UIStackView - spacing
                else if ([sectionId hasSuffix:@"UIStackView_Spacing"]) {
                    for (NSObject *attr in attrs) {
                        id value = [self kvcObject:attr key:@"value"];
                        if ([value isKindOfClass:[NSNumber class]]) {
                            stackAttrs[@"spacing"] = value; break;
                        }
                    }
                }
                // UIStackView - alignment
                else if ([sectionId hasSuffix:@"UIStackView_Alignment"]) {
                    for (NSObject *attr in attrs) {
                        id value = [self kvcObject:attr key:@"value"];
                        if ([value isKindOfClass:[NSNumber class]]) {
                            stackAttrs[@"stackAlignment"] = value; break;
                        }
                    }
                }
                // UITextField / UITextView - text（合并处理，与 UILabel 相同结构）
                else if ([sectionId hasSuffix:@"UITextField_Text"] ||
                         [sectionId hasSuffix:@"UITextView_Text"]) {
                    for (NSObject *attr in attrs) {
                        id value = [self kvcObject:attr key:@"value"];
                        if ([value isKindOfClass:[NSString class]]) {
                            labelAttrs[@"text"] = value; break;
                        }
                    }
                }
                // UITextField / UITextView - font（合并处理）
                else if ([sectionId hasSuffix:@"UITextField_Font"] ||
                         [sectionId hasSuffix:@"UITextView_Font"]) {
                    for (NSObject *attr in attrs) {
                        NSString *attrId = [self kvcString:attr key:@"identifier"];
                        id value = [self kvcObject:attr key:@"value"];
                        if (!value) continue;
                        if ([attrId hasSuffix:@"Name"] && [value isKindOfClass:[NSString class]]) {
                            labelAttrs[@"fontName"] = value;
                            // 从字体名称推断 fontWeight
                            NSString *fontName = (NSString *)value;
                            if ([fontName containsString:@"Bold"]) {
                                labelAttrs[@"fontWeight"] = @700;
                            } else if ([fontName containsString:@"Semibold"] || [fontName containsString:@"SemiBold"]) {
                                labelAttrs[@"fontWeight"] = @600;
                            } else if ([fontName containsString:@"Medium"]) {
                                labelAttrs[@"fontWeight"] = @500;
                            } else if ([fontName containsString:@"Light"]) {
                                labelAttrs[@"fontWeight"] = @300;
                            } else if ([fontName containsString:@"Thin"]) {
                                labelAttrs[@"fontWeight"] = @100;
                            } else if ([fontName containsString:@"Regular"] || [fontName containsString:@"Normal"]) {
                                labelAttrs[@"fontWeight"] = @400;
                            } else {
                                labelAttrs[@"fontWeight"] = @400; // 默认 Regular
                            }
                        } else if ([attrId hasSuffix:@"Size"] && [value isKindOfClass:[NSNumber class]]) {
                            labelAttrs[@"fontSize"] = value;
                        }
                    }
                }
                // UITextField / UITextView - textColor（合并处理）
                else if ([sectionId hasSuffix:@"UITextField_TextColor"] ||
                         [sectionId hasSuffix:@"UITextView_TextColor"]) {
                    for (NSObject *attr in attrs) {
                        id value = [self kvcObject:attr key:@"value"];
                        if (value) {
                            NSDictionary *c = [self serializeColor:value];
                            if (c) { labelAttrs[@"textColor"] = c; break; }
                        }
                    }
                }
                // UIButton - contentEdgeInsets（按需创建字典，内联序列化）
                else if ([sectionId hasSuffix:@"UIButton_ContentInsets"]) {
                    for (NSObject *attr in attrs) {
                        NSValue *value = [self kvcValue:attr key:@"value"];
                        if (value && [value isKindOfClass:[NSValue class]]) {
                            UIEdgeInsets insets = value.UIEdgeInsetsValue;
                            if (!dict[@"button"]) dict[@"button"] = [NSMutableDictionary new];
                            dict[@"button"][@"contentInsets"] = @{
                                @"top": @(insets.top), @"left": @(insets.left),
                                @"bottom": @(insets.bottom), @"right": @(insets.right)
                            };
                            break;
                        }
                    }
                }
            }
        }

        if (layerAttrs.count > 0) { [dict addEntriesFromDictionary:layerAttrs]; }
        if (labelAttrs.count > 0) { dict[@"label"] = labelAttrs; }
        if (stackAttrs.count > 0) { dict[@"stackView"] = stackAttrs; }
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

/// 将 UIColor / LookinColor / CGColorRef 对象序列化为 {r, g, b, a} 字典
/// 返回 nil 表示无法解析
+ (nullable NSDictionary *)serializeColor:(id)colorObj {
    if (!colorObj || colorObj == [NSNull null]) { return nil; }

    CGFloat r = 0, g = 0, b = 0, a = 0;
    BOOL success = NO;

    // ① CGColorRef 桥接类型（CALayer.borderColor / shadowColor 的实际类型）
    // 必须放在 UIColor 之前检测，因为 UIColor 也可通过 CGColor 降级
    @try {
        CFTypeRef cfRef = (__bridge CFTypeRef)colorObj;
        if (cfRef && CGColorGetTypeID() == CFGetTypeID(cfRef)) {
            CGColorRef cgColor = (CGColorRef)cfRef;
            const CGFloat *comps = CGColorGetComponents(cgColor);
            size_t numComps = CGColorGetNumberOfComponents(cgColor);
            if (comps && numComps >= 3) {
                r = comps[0]; g = comps[1]; b = comps[2];
                a = (numComps >= 4) ? comps[3] : 1.0;
                success = YES;
            } else if (comps && numComps == 2) {
                // 灰度色空间：comp[0]=white, comp[1]=alpha
                r = g = b = comps[0]; a = comps[1]; success = YES;
            }
        }
    } @catch (...) { /* 不是合法的 CGColorRef，继续尝试其他方式 */ }

    // ② UIColor（iOS）
    if (!success && [colorObj isKindOfClass:[UIColor class]]) {
        success = [((UIColor *)colorObj) getRed:&r green:&g blue:&b alpha:&a];
        if (!success) {
            // 可能是灰度色空间
            CGFloat white = 0;
            success = [((UIColor *)colorObj) getWhite:&white alpha:&a];
            if (success) { r = g = b = white; }
        }
    }
    // ③ NSObject with rgba components (LookinColor wrapper or similar)
    else if (!success && [colorObj respondsToSelector:NSSelectorFromString(@"redComponent")]) {
        NSNumber *rn = [colorObj valueForKey:@"redComponent"];
        NSNumber *gn = [colorObj valueForKey:@"greenComponent"];
        NSNumber *bn = [colorObj valueForKey:@"blueComponent"];
        NSNumber *an = [colorObj valueForKey:@"alphaComponent"];
        if (rn && gn && bn && an) {
            r = rn.doubleValue; g = gn.doubleValue;
            b = bn.doubleValue; a = an.doubleValue;
            success = YES;
        }
    }
    // ④ NSObject wrapping a UIColor（如 LookinColor 有 uiColor 属性）
    else if (!success && [colorObj respondsToSelector:NSSelectorFromString(@"uiColor")]) {
        UIColor *inner = [colorObj valueForKey:@"uiColor"];
        if (inner) { return [self serializeColor:inner]; }
    }

    if (!success) { return nil; }

    // 转为 0-255 整数 + alpha 保留两位小数，便于与 Figma 比较
    return @{
        @"r": @((int)round(r * 255)),
        @"g": @((int)round(g * 255)),
        @"b": @((int)round(b * 255)),
        @"a": @(round(a * 100) / 100.0),
        @"hex": [NSString stringWithFormat:@"#%02X%02X%02X",
                 (int)round(r * 255), (int)round(g * 255), (int)round(b * 255)]
    };
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

#pragma mark - View Attrs (按需获取单个视图的详细属性)

- (void)handleViewAttrs:(int)clientFd httpBody:(NSData *)httpBody {
    if (!httpBody || httpBody.length == 0) {
        NSString *msg = @"{\"error\":\"Missing request body\"}";
        [self sendResponse:clientFd status:400 body:[msg dataUsingEncoding:NSUTF8StringEncoding]];
        return;
    }
    
    NSError *parseError = nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:httpBody options:0 error:&parseError];
    if (!json || ![json isKindOfClass:[NSDictionary class]]) {
        NSString *msg = [NSString stringWithFormat:@"{\"error\":\"Invalid JSON: %@\"}", parseError.localizedDescription ?: @"parse failed"];
        [self sendResponse:clientFd status:400 body:[msg dataUsingEncoding:NSUTF8StringEncoding]];
        return;
    }
    
    NSNumber *oidNum = json[@"oid"];
    if (!oidNum) {
        NSString *msg = @"{\"error\":\"Missing required field: oid\"}";
        [self sendResponse:clientFd status:400 body:[msg dataUsingEncoding:NSUTF8StringEncoding]];
        return;
    }
    
    unsigned long oid = [oidNum unsignedLongValue];
    
    // 主线程执行属性获取
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    __block NSDictionary *result = nil;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        result = [LKS_MCPBridge getViewAttrsForOid:oid];
        dispatch_semaphore_signal(sema);
    });
    
    dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    
    if (result) {
        NSData *body = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingPrettyPrinted error:nil];
        [self sendResponse:clientFd status:200 body:body ?: [NSData data]];
    } else {
        NSString *msg = @"{\"error\":\"Timeout or internal error\"}";
        [self sendResponse:clientFd status:500 body:[msg dataUsingEncoding:NSUTF8StringEncoding]];
    }
}

/// 根据 oid 获取视图的详细属性（在主线程执行）
+ (NSDictionary *)getViewAttrsForOid:(unsigned long)oid {
    NSObject *obj = [NSObject lks_objectWithOid:oid];
    if (!obj) {
        return @{@"error": [NSString stringWithFormat:@"Object with oid=%lu not found", oid]};
    }
    
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"oid"] = @(oid);
    
    // 获取 UIView 或 CALayer
    UIView *view = [obj isKindOfClass:[UIView class]] ? (UIView *)obj : nil;
    CALayer *layer = view ? view.layer : ([obj isKindOfClass:[CALayer class]] ? (CALayer *)obj : nil);
    
    if (!layer) {
        return @{@"error": @"Object is not a UIView or CALayer"};
    }
    
    result[@"className"] = NSStringFromClass([obj class]);
    
    // ── 布局属性 ──
    if (view) {
        CGRect frame = view.frame;
        result[@"frame"] = @{
            @"x": @(frame.origin.x),
            @"y": @(frame.origin.y),
            @"width": @(frame.size.width),
            @"height": @(frame.size.height)
        };
        result[@"isHidden"] = @(view.isHidden);
        result[@"alpha"] = @(view.alpha);
        result[@"clipsToBounds"] = @(view.clipsToBounds);
        result[@"contentMode"] = @(view.contentMode);
        result[@"isOpaque"] = @(view.isOpaque);
        
        if (view.backgroundColor) {
            NSDictionary *bgColor = [self serializeColor:view.backgroundColor];
            if (bgColor) result[@"backgroundColor"] = bgColor;
        }
        if (view.tintColor) {
            NSDictionary *tintColor = [self serializeColor:view.tintColor];
            if (tintColor) result[@"tintColor"] = tintColor;
        }
    }
    
    // ── Layer 属性 ──
    result[@"cornerRadius"] = @(layer.cornerRadius);
    result[@"borderWidth"] = @(layer.borderWidth);
    result[@"masksToBounds"] = @(layer.masksToBounds);
    
    if (layer.borderColor) {
        UIColor *borderUIColor = [UIColor colorWithCGColor:layer.borderColor];
        NSDictionary *borderColor = [self serializeColor:borderUIColor];
        if (borderColor) result[@"borderColor"] = borderColor;
    }
    
    // ── 阴影属性 ──
    result[@"shadowOpacity"] = @(layer.shadowOpacity);
    if (layer.shadowOpacity > 0) {
        result[@"shadowRadius"] = @(layer.shadowRadius);
        result[@"shadowOffsetWidth"] = @(layer.shadowOffset.width);
        result[@"shadowOffsetHeight"] = @(layer.shadowOffset.height);
        if (layer.shadowColor) {
            UIColor *shadowUIColor = [UIColor colorWithCGColor:layer.shadowColor];
            NSDictionary *shadowColor = [self serializeColor:shadowUIColor];
            if (shadowColor) result[@"shadowColor"] = shadowColor;
        }
    }
    
    // ── UILabel 属性 ──
    if ([view isKindOfClass:[UILabel class]]) {
        UILabel *label = (UILabel *)view;
        NSMutableDictionary *labelAttrs = [NSMutableDictionary dictionary];
        
        if (label.text) labelAttrs[@"text"] = label.text;
        if (label.font) {
            labelAttrs[@"fontName"] = label.font.fontName;
            labelAttrs[@"fontSize"] = @(label.font.pointSize);
            // 从 UIFontDescriptor 获取精确字重（替换 fontName 字符串推断）
            UIFontDescriptor *desc = label.font.fontDescriptor;
            NSDictionary *traits = [desc objectForKey:UIFontDescriptorTraitsAttribute];
            if (traits && [traits isKindOfClass:[NSDictionary class]]) {
                NSNumber *weightTrait = traits[UIFontWeightTrait];
                if (weightTrait && [weightTrait isKindOfClass:[NSNumber class]]) {
                    // UIFontWeightTrait: -1.0(ultraLight) ~ 1.0(black)
                    // 映射到 CSS weight 100-900
                    CGFloat w = [weightTrait floatValue];
                    // 映射公式：ultraLight(-1.0)→100, regular(0.0)→400, black(1.0)→900
                    NSInteger cssWeight = (NSInteger)round(400 + w * 500);
                    cssWeight = MAX(100, MIN(900, cssWeight)); // clamp 到 100-900
                    labelAttrs[@"fontWeight"] = @(cssWeight);
                    labelAttrs[@"fontWeightTrait"] = weightTrait; // 保留原始值
                }
            }
            // 兜底：如果 UIFontDescriptor 获取失败，回退到 fontName 推断
            if (!labelAttrs[@"fontWeight"]) {
                NSString *fontName = label.font.fontName;
                if ([fontName containsString:@"Bold"]) {
                    labelAttrs[@"fontWeight"] = @700;
                } else if ([fontName containsString:@"Semibold"] || [fontName containsString:@"SemiBold"]) {
                    labelAttrs[@"fontWeight"] = @600;
                } else if ([fontName containsString:@"Medium"]) {
                    labelAttrs[@"fontWeight"] = @500;
                } else if ([fontName containsString:@"Light"]) {
                    labelAttrs[@"fontWeight"] = @300;
                } else {
                    labelAttrs[@"fontWeight"] = @400;
                }
            }
        }
        if (label.textColor) {
            NSDictionary *textColor = [self serializeColor:label.textColor];
            if (textColor) labelAttrs[@"textColor"] = textColor;
        }
        labelAttrs[@"textAlignment"] = @(label.textAlignment);
        labelAttrs[@"numberOfLines"] = @(label.numberOfLines);
        labelAttrs[@"lineBreakMode"] = @(label.lineBreakMode);
        
        // ── 行高 & 字间距（从 attributedText 提取）──
        if (label.attributedText && label.attributedText.length > 0) {
            // 行高
            NSParagraphStyle *para = [label.attributedText attribute:NSParagraphStyleAttributeName atIndex:0 effectiveRange:NULL];
            if (para) {
                if (para.minimumLineHeight > 0) {
                    labelAttrs[@"lineHeight"] = @(para.minimumLineHeight);
                }
                if (para.maximumLineHeight > 0 && para.maximumLineHeight != para.minimumLineHeight) {
                    labelAttrs[@"maxLineHeight"] = @(para.maximumLineHeight);
                }
                if (para.lineHeightMultiple > 0) {
                    labelAttrs[@"lineHeightMultiple"] = @(para.lineHeightMultiple);
                }
            }
            // 字间距
            NSNumber *kern = [label.attributedText attribute:NSKernAttributeName atIndex:0 effectiveRange:NULL];
            if (kern) {
                labelAttrs[@"letterSpacing"] = kern;
            }
        }
        // 无 attributedText 时，返回 font 默认行高作为参考
        if (!labelAttrs[@"lineHeight"] && label.font) {
            labelAttrs[@"fontLineHeight"] = @(label.font.lineHeight);
        }
        
        if (labelAttrs.count > 0) result[@"label"] = labelAttrs;
    }
    
    // ── UIButton 属性 ──
    if ([view isKindOfClass:[UIButton class]]) {
        UIButton *button = (UIButton *)view;
        NSMutableDictionary *buttonAttrs = [NSMutableDictionary dictionary];
        
        NSString *title = [button titleForState:UIControlStateNormal];
        if (title) buttonAttrs[@"title"] = title;
        
        UIColor *titleColor = [button titleColorForState:UIControlStateNormal];
        if (titleColor) {
            NSDictionary *color = [self serializeColor:titleColor];
            if (color) buttonAttrs[@"titleColor"] = color;
        }
        
        UIEdgeInsets insets = button.contentEdgeInsets;
        buttonAttrs[@"contentInsets"] = @{
            @"top": @(insets.top),
            @"left": @(insets.left),
            @"bottom": @(insets.bottom),
            @"right": @(insets.right)
        };
        
        if (buttonAttrs.count > 0) result[@"button"] = buttonAttrs;
    }
    
    // ── UIImageView 属性 ──
    if ([view isKindOfClass:[UIImageView class]]) {
        UIImageView *imageView = (UIImageView *)view;
        NSMutableDictionary *imageAttrs = [NSMutableDictionary dictionary];
        
        imageAttrs[@"contentMode"] = @(imageView.contentMode);
        if (imageView.image) {
            imageAttrs[@"imageSize"] = @{
                @"width": @(imageView.image.size.width),
                @"height": @(imageView.image.size.height)
            };
        }
        
        if (imageAttrs.count > 0) result[@"imageView"] = imageAttrs;
    }
    
    // ── UIStackView 属性 ──
    if ([view isKindOfClass:[UIStackView class]]) {
        UIStackView *stack = (UIStackView *)view;
        NSMutableDictionary *stackAttrs = [NSMutableDictionary dictionary];
        
        stackAttrs[@"axis"] = (stack.axis == UILayoutConstraintAxisVertical) ? @"vertical" : @"horizontal";
        stackAttrs[@"spacing"] = @(stack.spacing);
        stackAttrs[@"alignment"] = @(stack.alignment);
        stackAttrs[@"distribution"] = @(stack.distribution);
        
        if (stackAttrs.count > 0) result[@"stackView"] = stackAttrs;
    }
    
    // ── CAGradientLayer 渐变层 ──
    for (CALayer *sublayer in layer.sublayers) {
        if ([sublayer isKindOfClass:[CAGradientLayer class]]) {
            CAGradientLayer *gradient = (CAGradientLayer *)sublayer;
            NSMutableDictionary *gradientDict = [NSMutableDictionary dictionary];
            
            // colors
            if (gradient.colors) {
                NSMutableArray *colorsArr = [NSMutableArray array];
                for (id cgColor in gradient.colors) {
                    if (CFGetTypeID((__bridge CFTypeRef)cgColor) == CGColorGetTypeID()) {
                        UIColor *uiColor = [UIColor colorWithCGColor:(__bridge CGColorRef)cgColor];
                        NSDictionary *colorDict = [self serializeColor:uiColor];
                        if (colorDict) [colorsArr addObject:colorDict];
                    }
                }
                gradientDict[@"colors"] = colorsArr;
            }
            
            // locations
            if (gradient.locations) {
                NSMutableArray *locationsArr = [NSMutableArray array];
                for (NSNumber *loc in gradient.locations) {
                    [locationsArr addObject:loc];
                }
                gradientDict[@"locations"] = locationsArr;
            }
            
            // startPoint / endPoint (归一化坐标 0-1)
            gradientDict[@"startPoint"] = @{ @"x": @(gradient.startPoint.x), @"y": @(gradient.startPoint.y) };
            gradientDict[@"endPoint"] = @{ @"x": @(gradient.endPoint.x), @"y": @(gradient.endPoint.y) };
            
            // 类型
            gradientDict[@"type"] = [gradient isKindOfClass:[CAGradientLayer class]] ? @"axial" : @"unknown";
            
            result[@"gradient"] = gradientDict;
            break; // 通常只有一个渐变层
        }
    }
    
    // ── Auto Layout 约束间距 ──
    if (view && view.constraints.count > 0) {
        NSMutableArray *constraintsArr = [NSMutableArray array];
        for (NSLayoutConstraint *c in view.constraints) {
            UIView *first = (UIView *)c.firstItem;
            UIView *second = (UIView *)c.secondItem;
            
            // 只收集涉及当前视图的间距/尺寸约束
            BOOL involvesSelf = (first == view || second == view);
            if (!involvesSelf) continue;
            
            NSString *type = nil;
            if (c.firstAttribute == NSLayoutAttributeLeading && c.secondAttribute == NSLayoutAttributeLeading) {
                type = @"leading";
            } else if (c.firstAttribute == NSLayoutAttributeTrailing && c.secondAttribute == NSLayoutAttributeTrailing) {
                type = @"trailing";
            } else if (c.firstAttribute == NSLayoutAttributeTop && c.secondAttribute == NSLayoutAttributeTop) {
                type = @"top";
            } else if (c.firstAttribute == NSLayoutAttributeBottom && c.secondAttribute == NSLayoutAttributeBottom) {
                type = @"bottom";
            } else if (c.firstAttribute == NSLayoutAttributeWidth && c.secondAttribute == NSLayoutAttributeNotAnAttribute) {
                type = @"width";
            } else if (c.firstAttribute == NSLayoutAttributeHeight && c.secondAttribute == NSLayoutAttributeNotAnAttribute) {
                type = @"height";
            } else if (c.firstAttribute == NSLayoutAttributeCenterX && c.secondAttribute == NSLayoutAttributeCenterX) {
                type = @"centerX";
            } else if (c.firstAttribute == NSLayoutAttributeCenterY && c.secondAttribute == NSLayoutAttributeCenterY) {
                type = @"centerY";
            }
            
            if (type) {
                [constraintsArr addObject:@{
                    @"type": type,
                    @"constant": @(c.constant),
                    @"multiplier": @(c.multiplier),
                    @"priority": @((float)c.priority),
                    @"relation": (c.relation == NSLayoutRelationEqual ? @"eq" :
                                  c.relation == NSLayoutRelationGreaterThanOrEqual ? @"gte" : @"lte"),
                    @"secondItem": second ? NSStringFromClass([second class]) : @"nil"
                }];
            }
        }
        if (constraintsArr.count > 0) {
            result[@"constraints"] = constraintsArr;
        }
    }
    
    return result;
}

#pragma mark - Modify View

- (void)handleModify:(int)clientFd httpBody:(NSData *)httpBody {
    if (!httpBody || httpBody.length == 0) {
        NSString *msg = @"{\"success\":false,\"error\":\"Missing request body\"}";
        [self sendResponse:clientFd status:400 body:[msg dataUsingEncoding:NSUTF8StringEncoding]];
        return;
    }
    
    NSError *parseError = nil;
    NSDictionary *json = [NSJSONSerialization JSONObjectWithData:httpBody options:0 error:&parseError];
    if (!json || ![json isKindOfClass:[NSDictionary class]]) {
        NSString *msg = [NSString stringWithFormat:@"{\"success\":false,\"error\":\"Invalid JSON: %@\"}", parseError.localizedDescription ?: @"parse failed"];
        [self sendResponse:clientFd status:400 body:[msg dataUsingEncoding:NSUTF8StringEncoding]];
        return;
    }
    
    NSNumber *oidNum = json[@"oid"];
    NSDictionary *modifications = json[@"modifications"];
    
    if (!oidNum || !modifications || ![modifications isKindOfClass:[NSDictionary class]]) {
        NSString *msg = @"{\"success\":false,\"error\":\"Missing required fields: oid, modifications\"}";
        [self sendResponse:clientFd status:400 body:[msg dataUsingEncoding:NSUTF8StringEncoding]];
        return;
    }
    
    unsigned long oid = [oidNum unsignedLongValue];
    
    // 主线程执行修改
    dispatch_semaphore_t sema = dispatch_semaphore_create(0);
    __block NSDictionary *result = nil;
    
    dispatch_async(dispatch_get_main_queue(), ^{
        result = [self applyModifications:modifications toObjectWithOid:oid];
        dispatch_semaphore_signal(sema);
    });
    
    dispatch_semaphore_wait(sema, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC));
    
    if (result) {
        NSData *body = [NSJSONSerialization dataWithJSONObject:result options:0 error:nil];
        [self sendResponse:clientFd status:200 body:body ?: [NSData data]];
    } else {
        NSString *msg = @"{\"success\":false,\"error\":\"Timeout or internal error\"}";
        [self sendResponse:clientFd status:500 body:[msg dataUsingEncoding:NSUTF8StringEncoding]];
    }
}

- (NSDictionary *)applyModifications:(NSDictionary *)modifications toObjectWithOid:(unsigned long)oid {
    NSObject *obj = [NSObject lks_objectWithOid:oid];
    if (!obj) {
        return @{@"success": @NO, @"error": [NSString stringWithFormat:@"Object with oid=%lu not found", oid]};
    }
    
    NSMutableArray *modifiedProps = [NSMutableArray array];
    NSMutableArray *errors = [NSMutableArray array];
    
    // 检查是否是 UIView 或 CALayer
    UIView *view = [obj isKindOfClass:[UIView class]] ? (UIView *)obj : nil;
    CALayer *layer = view ? view.layer : ([obj isKindOfClass:[CALayer class]] ? (CALayer *)obj : nil);
    
    for (NSString *key in modifications) {
        id value = modifications[key];
        
        @try {
            // Frame 相关
            if ([key isEqualToString:@"frame"] && view) {
                NSDictionary *frameDict = value;
                CGRect frame = view.frame;
                if (frameDict[@"x"]) frame.origin.x = [frameDict[@"x"] doubleValue];
                if (frameDict[@"y"]) frame.origin.y = [frameDict[@"y"] doubleValue];
                if (frameDict[@"width"]) frame.size.width = [frameDict[@"width"] doubleValue];
                if (frameDict[@"height"]) frame.size.height = [frameDict[@"height"] doubleValue];
                view.frame = frame;
                [modifiedProps addObject:key];
            }
            else if ([key hasPrefix:@"frame."] && view) {
                NSString *subKey = [key substringFromIndex:6];
                CGRect frame = view.frame;
                CGFloat val = [value doubleValue];
                if ([subKey isEqualToString:@"x"]) frame.origin.x = val;
                else if ([subKey isEqualToString:@"y"]) frame.origin.y = val;
                else if ([subKey isEqualToString:@"width"]) frame.size.width = val;
                else if ([subKey isEqualToString:@"height"]) frame.size.height = val;
                view.frame = frame;
                [modifiedProps addObject:key];
            }
            // backgroundColor
            else if ([key isEqualToString:@"backgroundColor"]) {
                UIColor *color = [self parseColor:value];
                if (color && view) {
                    view.backgroundColor = color;
                    [modifiedProps addObject:key];
                } else if (color && layer) {
                    layer.backgroundColor = color.CGColor;
                    [modifiedProps addObject:key];
                }
            }
            // cornerRadius
            else if ([key isEqualToString:@"cornerRadius"] && layer) {
                layer.cornerRadius = [value doubleValue];
                [modifiedProps addObject:key];
            }
            // borderWidth
            else if ([key isEqualToString:@"borderWidth"] && layer) {
                layer.borderWidth = [value doubleValue];
                [modifiedProps addObject:key];
            }
            // borderColor
            else if ([key isEqualToString:@"borderColor"] && layer) {
                UIColor *color = [self parseColor:value];
                if (color) {
                    layer.borderColor = color.CGColor;
                    [modifiedProps addObject:key];
                }
            }
            // alpha
            else if ([key isEqualToString:@"alpha"] && view) {
                view.alpha = [value doubleValue];
                [modifiedProps addObject:key];
            }
            // hidden
            else if ([key isEqualToString:@"hidden"] && view) {
                view.hidden = [value boolValue];
                [modifiedProps addObject:key];
            }
            // clipsToBounds
            else if ([key isEqualToString:@"clipsToBounds"] && view) {
                view.clipsToBounds = [value boolValue];
                [modifiedProps addObject:key];
            }
            // UILabel specific
            else if ([key isEqualToString:@"fontSize"] && [view isKindOfClass:[UILabel class]]) {
                UILabel *label = (UILabel *)view;
                UIFont *font = label.font;
                label.font = [font fontWithSize:[value doubleValue]];
                [modifiedProps addObject:key];
            }
            else if ([key isEqualToString:@"textColor"] && [view isKindOfClass:[UILabel class]]) {
                UILabel *label = (UILabel *)view;
                UIColor *color = [self parseColor:value];
                if (color) {
                    label.textColor = color;
                    [modifiedProps addObject:key];
                }
            }
            else if ([key isEqualToString:@"textAlignment"] && [view isKindOfClass:[UILabel class]]) {
                UILabel *label = (UILabel *)view;
                label.textAlignment = (NSTextAlignment)[value integerValue];
                [modifiedProps addObject:key];
            }
            else if ([key isEqualToString:@"numberOfLines"] && [view isKindOfClass:[UILabel class]]) {
                UILabel *label = (UILabel *)view;
                label.numberOfLines = [value integerValue];
                [modifiedProps addObject:key];
            }
            else if ([key isEqualToString:@"text"] && [view isKindOfClass:[UILabel class]]) {
                UILabel *label = (UILabel *)view;
                label.text = [value isKindOfClass:[NSString class]] ? value : [value description];
                [modifiedProps addObject:key];
            }
            // UIStackView specific
            else if ([key isEqualToString:@"spacing"] && [view isKindOfClass:[UIStackView class]]) {
                UIStackView *stack = (UIStackView *)view;
                stack.spacing = [value doubleValue];
                [modifiedProps addObject:key];
            }
            else if ([key isEqualToString:@"axis"] && [view isKindOfClass:[UIStackView class]]) {
                UIStackView *stack = (UIStackView *)view;
                // 0 = horizontal, 1 = vertical
                stack.axis = [value integerValue];
                [modifiedProps addObject:key];
            }
            else {
                [errors addObject:[NSString stringWithFormat:@"Unknown or unsupported property: %@", key]];
            }
        } @catch (NSException *e) {
            [errors addObject:[NSString stringWithFormat:@"Error setting %@: %@", key, e.reason]];
        }
    }
    
    NSMutableDictionary *response = [@{
        @"success": @(errors.count == 0 || modifiedProps.count > 0),
        @"oid": @(oid),
        @"modifiedProps": modifiedProps
    } mutableCopy];
    
    if (errors.count > 0) {
        response[@"errors"] = errors;
    }
    
    return response;
}

- (UIColor *)parseColor:(id)value {
    if ([value isKindOfClass:[NSString class]]) {
        NSString *str = value;
        // #RRGGBB or #RRGGBBAA
        if ([str hasPrefix:@"#"]) {
            NSString *hex = [str substringFromIndex:1];
            unsigned int hexValue = 0;
            [[NSScanner scannerWithString:hex] scanHexInt:&hexValue];
            
            if (hex.length == 6) {
                return [UIColor colorWithRed:((hexValue >> 16) & 0xFF) / 255.0
                                       green:((hexValue >> 8) & 0xFF) / 255.0
                                        blue:(hexValue & 0xFF) / 255.0
                                       alpha:1.0];
            } else if (hex.length == 8) {
                return [UIColor colorWithRed:((hexValue >> 24) & 0xFF) / 255.0
                                       green:((hexValue >> 16) & 0xFF) / 255.0
                                        blue:((hexValue >> 8) & 0xFF) / 255.0
                                       alpha:(hexValue & 0xFF) / 255.0];
            }
        }
    } else if ([value isKindOfClass:[NSDictionary class]]) {
        NSDictionary *dict = value;
        CGFloat r = [dict[@"r"] doubleValue] / 255.0;
        CGFloat g = [dict[@"g"] doubleValue] / 255.0;
        CGFloat b = [dict[@"b"] doubleValue] / 255.0;
        CGFloat a = dict[@"a"] ? [dict[@"a"] doubleValue] : 1.0;
        return [UIColor colorWithRed:r green:g blue:b alpha:a];
    }
    return nil;
}

@end

#endif /* TARGET_OS_IOS || TARGET_OS_TV || TARGET_OS_VISION */

#endif /* SHOULD_COMPILE_LOOKIN_SERVER */
