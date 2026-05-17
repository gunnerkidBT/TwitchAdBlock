#import <Foundation/Foundation.h>

@interface NSURL (TwitchAdBlock)
- (NSURL *)twab_URLWithProxyURL:(NSURL *)proxyURL;
@end

// Builds a "Basic <base64>" header value from a URL's user/password.
// Returns nil if the URL has no embedded credentials. NSURLSession does
// not auto-extract credentials from URLs the way browsers do, so callers
// must inject the header themselves on requests that need proxy auth.
NSString *twab_basicAuthHeader(NSURL *url);