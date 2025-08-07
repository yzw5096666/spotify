#import <Foundation/Foundation.h>
#import <objc/runtime.h>

// 默认值（当 Documents/proxy.conf 不存在时，首次创建时写入这三行；
// 如果读取失败，也会 fallback 用这两个默认的 Host/Port））
static NSString *const DEFAULT_FLAG       = @"no";
static NSString *const DEFAULT_PROXY_HOST = @"192.168.31.17";
static NSNumber *const DEFAULT_PROXY_PORT = @10808;

// 交换 class method 实现的辅助函数
static void swizzleClassMethod(Class cls, SEL orig, SEL repl) {
    Method o = class_getClassMethod(cls, orig);
    Method n = class_getClassMethod(cls, repl);
    method_exchangeImplementations(o, n);
}

@interface NSURLSessionConfiguration (YTSocksProxy)
+ (NSDictionary *)yt_proxyDict;                // 如果启用返回 proxy 字典，否则返回 nil
+ (NSURLSessionConfiguration *)yt_defaultSessionConfiguration;
+ (NSURLSessionConfiguration *)yt_ephemeralSessionConfiguration;
@end

@implementation NSURLSessionConfiguration (YTSocksProxy)

// 返回 Documents/proxy.conf 的完整路径
+ (NSString *)documentsProxyConfPath {
    NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    if (paths.count == 0) return nil;
    return [paths.firstObject stringByAppendingPathComponent:@"proxy.conf"];
}

// 如果 Documents 下没有 proxy.conf，则自动创建一个，内容写入三行默认值：flag/no、host、port
+ (void)ensureProxyConfInDocuments {
    NSString *docConfPath = [self documentsProxyConfPath];
    if (docConfPath == nil) return;

    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:docConfPath]) {
        NSString *defaultText = [NSString stringWithFormat:@"%@\n%@\n%@\n",
                                 DEFAULT_FLAG,
                                 DEFAULT_PROXY_HOST,
                                 DEFAULT_PROXY_PORT];
        [defaultText writeToFile:docConfPath
                      atomically:YES
                        encoding:NSUTF8StringEncoding
                           error:nil];
    }
}

// 从 Documents/proxy.conf 读取：
// 第一行 flag（"yes"/"no"），第二行 host，第三行 port，
// 第四行 username（可选），第五行 password（可选）。
// outEnabled 传出是否启用代理；outHost/outPort 传出 Host/Port；
// outUser/outPass 传出用户名/密码，如果文件行数 < 5，则 outUser/outPass 置 nil。
+ (void)loadProxyEnabled:(BOOL *)outEnabled
                    host:(NSString **)outHost
                    port:(NSNumber **)outPort
                    user:(NSString **)outUser
                  pass:(NSString **)outPass {
    // 默认
    NSString *proxyHost = DEFAULT_PROXY_HOST;
    NSNumber *proxyPort = DEFAULT_PROXY_PORT;
    NSString *proxyUser = nil;
    NSString *proxyPass = nil;
    BOOL enabled = NO;

    NSString *docConfPath = [self documentsProxyConfPath];
    if (docConfPath) {
        NSError *err = nil;
        NSString *txt = [NSString stringWithContentsOfFile:docConfPath
                                                  encoding:NSUTF8StringEncoding
                                                     error:&err];
        if (!err && txt.length > 0) {
            NSArray<NSString *> *lines = [txt componentsSeparatedByCharactersInSet:
                                          [NSCharacterSet newlineCharacterSet]];
            if (lines.count >= 3) {
                // 第一行：flag
                NSString *flag = [lines[0] stringByTrimmingCharactersInSet:
                                  [NSCharacterSet whitespaceAndNewlineCharacterSet]];
                if ([[flag lowercaseString] isEqualToString:@"yes"]) {
                    enabled = YES;
                    // 第二行：host
                    NSString *h = [lines[1] stringByTrimmingCharactersInSet:
                                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
                    if (h.length > 0) {
                        proxyHost = h;
                    }
                    // 第三行：port
                    NSString *p = [lines[2] stringByTrimmingCharactersInSet:
                                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
                    NSInteger portNum = [p integerValue];
                    if (portNum > 0 && portNum <= 65535) {
                        proxyPort = @(portNum);
                    }
                    // 第四行：username（可选）
                    if (lines.count >= 4) {
                        NSString *u = [lines[3] stringByTrimmingCharactersInSet:
                                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
                        if (u.length > 0) {
                            proxyUser = u;
                        }
                    }
                    // 第五行：password（可选）
                    if (lines.count >= 5) {
                        NSString *pw = [lines[4] stringByTrimmingCharactersInSet:
                                        [NSCharacterSet whitespaceAndNewlineCharacterSet]];
                        if (pw.length > 0) {
                            proxyPass = pw;
                        }
                    }
                }
            }
            // 如果行数 < 3，则视为格式不对，enabled 仍为 NO
        }
    }

    *outEnabled = enabled;
    *outHost    = proxyHost;
    *outPort    = proxyPort;
    *outUser    = proxyUser;
    *outPass    = proxyPass;
}

// 根据 loadProxyEnabled:host:port:user:pass: 的结果返回 proxy 字典
// 如果 enabled == NO，则返回 nil；否则构造包含 host/port，
// 如果 user/pass 非 nil，也一并加入用户名/密码字段
+ (NSDictionary *)yt_proxyDict {
    // 1) 确保 Documents/proxy.conf 存在；如果不存在，创建并写入三行默认值
    [self ensureProxyConfInDocuments];

    // 2) 从 Documents 读取 enabled, host, port, user, pass
    BOOL enabled = NO;
    NSString *host = nil;
    NSNumber *port = nil;
    NSString *user = nil;
    NSString *pass = nil;
    [self loadProxyEnabled:&enabled host:&host port:&port user:&user pass:&pass];

    if (!enabled) {
        return nil; // 不启用代理
    }

    // 3) 构造 SOCKS5 proxy 字典
    NSMutableDictionary *dict = [@{
        // CFNetwork 层面的 key
        (NSString *)kCFStreamPropertySOCKSProxyHost:   host,
        (NSString *)kCFStreamPropertySOCKSProxyPort:   port,
        (NSString *)kCFStreamPropertySOCKSVersion:     (NSString *)kCFStreamSocketSOCKSVersion5,
        // Foundation 拦截时常用的 key
        @"SOCKSEnable": @YES,
        @"SOCKSProxy":  host,
        @"SOCKSPort":   port,
        // 关闭 HTTP/HTTPS 代理，避免冲突
        @"HTTPEnable":  @NO,
        @"HTTPSEnable": @NO
    } mutableCopy];

    // 如果用户提供了用户名和密码，就加入对应字段
    if (user.length > 0 && pass.length > 0) {
        dict[(NSString *)kCFStreamPropertySOCKSUser]     = user;
        dict[(NSString *)kCFStreamPropertySOCKSPassword] = pass;
        dict[@"SOCKSUser"]    = user;
        dict[@"SOCKSPassword"] = pass;
    }

    return [dict copy];
}

+ (NSURLSessionConfiguration *)yt_defaultSessionConfiguration {
    NSURLSessionConfiguration *config = [self yt_defaultSessionConfiguration];
    NSDictionary *proxyDict = [self yt_proxyDict];
    if (proxyDict) {
        config.connectionProxyDictionary = proxyDict;
    }
    return config;
}

+ (NSURLSessionConfiguration *)yt_ephemeralSessionConfiguration {
    NSURLSessionConfiguration *config = [self yt_ephemeralSessionConfiguration];
    NSDictionary *proxyDict = [self yt_proxyDict];
    if (proxyDict) {
        config.connectionProxyDictionary = proxyDict;
    }
    return config;
}

@end

__attribute__((constructor))
static void yt_swizzle_proxy() {
    Class cls = objc_getClass("NSURLSessionConfiguration");
    swizzleClassMethod(cls,
                       @selector(defaultSessionConfiguration),
                       @selector(yt_defaultSessionConfiguration));
    swizzleClassMethod(cls,
                       @selector(ephemeralSessionConfiguration),
                       @selector(yt_ephemeralSessionConfiguration));
    NSLog(@"✅ SOCKS5 代理模块已加载（按 Documents/proxy.conf 中的设置决定是否走代理与认证）");
}
