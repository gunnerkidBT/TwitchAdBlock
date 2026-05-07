#import "NSURLSession+TwitchAdBlock.h"
#import "TWABProxyAuthDelegate.h"

// Parse "user:pass@host:port", "host:port", or "http(s)://user:pass@host:port"
// Returns a dict with keys: host (NSString), port (NSNumber),
//                           user (NSString, may be nil), pass (NSString, may be nil)
static NSDictionary *TWABParseProxyAddress(NSString *address) {
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
