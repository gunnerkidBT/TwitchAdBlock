#import "NSURLSession+TwitchAdBlock.h"
#import "TWABProxyAuthDelegate.h"
#import <os/log.h>
#include <sys/socket.h>
#include <sys/select.h>
#include <netdb.h>
#include <fcntl.h>
#include <errno.h>
#include <unistd.h>

NSDictionary *TWABParseProxyAddress(NSString *address) {
    if (!address.length) return nil;
    NSString *normalized = address;
    // Add scheme if missing so NSURL can parse it
    if (![normalized hasPrefix:@"http://"] && ![normalized hasPrefix:@"https://"]) {
        normalized = [@"http://" stringByAppendingString:normalized];
    }
    NSURL *url = [NSURL URLWithString:normalized];
    if (!url.host) return nil;
    NSNumber *port = url.port ?: @8080;
    return @{
        @"host" : url.host,
        @"port" : port,
        @"user" : url.user  ?: @"",
        @"pass" : url.password ?: @"",
    };
}

@implementation NSURLSession (TwitchAdBlock)

- (NSURLSession *)twab_proxySessionWithAddress:(NSString *)address {
    NSDictionary *info = TWABParseProxyAddress(address);
    NSURLSessionConfiguration *configuration =
        [self.configuration copy] ?: NSURLSessionConfiguration.ephemeralSessionConfiguration;

    if (info) {
        NSString *host = info[@"host"];
        NSNumber *port = info[@"port"];
        configuration.connectionProxyDictionary = @{
            @"HTTPEnable"  : @YES,
            @"HTTPProxy"   : host,
            @"HTTPPort"    : port,
            @"HTTPSEnable" : @YES,
            @"HTTPSProxy"  : host,
            @"HTTPSPort"   : port,
        };
    }

    // Build delegate: always use TWABProxyAuthDelegate so proxy auth challenges are handled.
    TWABProxyAuthDelegate *authDelegate = [TWABProxyAuthDelegate new];
    authDelegate.inner     = self.delegate;
    authDelegate.proxyUser = info[@"user"];
    authDelegate.proxyPass = info[@"pass"];

    return [NSURLSession sessionWithConfiguration:configuration
                                         delegate:authDelegate
                                    delegateQueue:self.delegateQueue ?: [NSOperationQueue new]];
}

@end

// Try to open a TCP connection to host:port with a hard timeout (seconds).
// Returns YES on connect, NO on any failure. Blocks the calling thread.
static BOOL twab_tcpConnectReachable(NSString *host, int port, int timeoutSec) {
    if (!host.length || port <= 0) return NO;
    struct addrinfo hints = {0};
    hints.ai_family   = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;
    char portStr[16];
    snprintf(portStr, sizeof(portStr), "%d", port);
    struct addrinfo *res = NULL;
    if (getaddrinfo(host.UTF8String, portStr, &hints, &res) != 0 || !res) return NO;

    BOOL connected = NO;
    for (struct addrinfo *ai = res; ai && !connected; ai = ai->ai_next) {
        int sock = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (sock < 0) continue;
        int flags = fcntl(sock, F_GETFL, 0);
        fcntl(sock, F_SETFL, flags | O_NONBLOCK);

        int rc = connect(sock, ai->ai_addr, ai->ai_addrlen);
        if (rc == 0) {
            connected = YES;
        } else if (errno == EINPROGRESS) {
            fd_set wfds;
            FD_ZERO(&wfds);
            FD_SET(sock, &wfds);
            struct timeval tv = { timeoutSec, 0 };
            int sel = select(sock + 1, NULL, &wfds, NULL, &tv);
            if (sel > 0) {
                int err = 0;
                socklen_t len = sizeof(err);
                if (getsockopt(sock, SOL_SOCKET, SO_ERROR, &err, &len) == 0 && err == 0) {
                    connected = YES;
                }
            }
        }
        close(sock);
    }
    freeaddrinfo(res);
    return connected;
}

void twab_checkProxyStatus(NSString *address, void (^completion)(TWABProxyStatus)) {
    void (^reply)(TWABProxyStatus) = ^(TWABProxyStatus s) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(s); });
    };
    if (!address.length) { reply(TWABProxyStatusOffline); return; }
    NSDictionary *info = TWABParseProxyAddress(address);
    if (!info) {
        os_log_error(OS_LOG_DEFAULT, "[TWAB-Proxy] probe: unparseable address");
        reply(TWABProxyStatusOffline);
        return;
    }
    NSString *host = info[@"host"];
    int port = [info[@"port"] intValue];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        // 10s gives slow cellular paths and far-region proxies a chance to
        // complete the TCP handshake. The UI shows "Checking…" the whole time.
        NSDate *start = [NSDate date];
        BOOL up = twab_tcpConnectReachable(host, port, 10);
        NSTimeInterval elapsed = -[start timeIntervalSinceNow];
        os_log(OS_LOG_DEFAULT,
            "[TWAB-Proxy] probe %{public}@:%d reachable=%d in %.2fs",
            host, port, up, elapsed);
        reply(up ? TWABProxyStatusOnline : TWABProxyStatusOffline);
    });
}
