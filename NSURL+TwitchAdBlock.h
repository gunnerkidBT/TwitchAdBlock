#import <Foundation/Foundation.h>

@interface NSURL (TwitchAdBlock)
- (NSURL *)twab_URLWithProxyURL:(NSURL *)proxyURL;
@end

// Whether the proxy answers /ping with 200 (Luminous V2). Returns nil until known,
// starting a background ping if none is running. Never blocks.
NSNumber *twab_proxyPingVerdict(NSURL *proxyURL);

// Builds a "Basic <base64>" header value from a URL's user/password.
// Returns nil if the URL has no embedded credentials. NSURLSession does
// not auto-extract credentials from URLs the way browsers do, so callers
// must inject the header themselves on requests that need proxy auth.
NSString *twab_basicAuthHeader(NSURL *url);