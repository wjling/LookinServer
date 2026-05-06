#ifdef SHOULD_COMPILE_LOOKIN_SERVER

//
//  LKS_MCPBridge.h
//  LookinServer
//
//  为 AI（MCP Server）提供一个独立的 HTTP 侧信道。
//  端口：9877（与 Lookin 主协议端口 47164-47179 不冲突）
//
//  支持的接口：
//    GET  /ping             - 健康检查
//    GET  /hierarchy        - 获取最新 UI 层级树（JSON，轻量版不含详细属性）
//    POST /refresh          - 主动触发重新获取 hierarchy
//    POST /view_attrs       - 按需获取单个视图的详细属性（cornerRadius/borderWidth/shadow 等）
//    POST /modify           - 修改视图属性
//
//  使用方式：[[LKS_MCPBridge sharedInstance] start];
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LKS_MCPBridge : NSObject

+ (instancetype)sharedInstance;

/// 启动 HTTP Server，如果已启动则忽略
- (void)start;

/// 停止 HTTP Server
- (void)stop;

/// 缓存最新 hierarchy 数据（由 LKS_RequestHandler 调用）
/// @param hierarchyInfo LookinHierarchyInfo 对象
- (void)cacheLatestHierarchyInfo:(NSObject *)hierarchyInfo;

@end

NS_ASSUME_NONNULL_END

#endif /* SHOULD_COMPILE_LOOKIN_SERVER */
