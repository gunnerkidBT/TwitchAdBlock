#include <Foundation/Foundation.h>

@interface NSURLSession (TwitchAdBlock)
- (NSURLSession *)twab_proxySessionWithAddress:(NSString *)address;
@end

typedef NS_ENUM(NSInteger, TWABProxyStatus) {
    TWABProxyStatusUnknown,
    TWABProxyStatusChecking,
    TWABProxyStatusOnline,
    TWABProxyStatusOffline,
};

// Parse "user:pass@host:port", "host:port", or "http(s)://user:pass@host:port".
// Returns @{ host, port, user, pass } or nil on parse failure.
NSDictionary *TWABParseProxyAddress(NSString *address);

// Probe whether the proxy at `address` accepts TCP connections on its port
// within `timeoutSec`. Tests reachability only — does not validate auth or
// upstream behavior. Completion fires on the main queue.
void twab_checkProxyStatus(NSString *address, void (^completion)(TWABProxyStatus status));