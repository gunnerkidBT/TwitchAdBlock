#include <Foundation/NSJSONSerialization.h>
#include <Foundation/NSURL.h>
#include <Foundation/NSURLResponse.h>
#import <os/log.h>
#import "NSURL+TwitchAdBlock.h"

// Cache the Luminous-V1 verdict per proxy URL so we don't block every
// playlist fetch on a network round-trip. The verdict is determined the
// first time twab_URLWithProxyURL: is called for a given proxy host:port
// and reused for subsequent calls. Cleared when the host:port changes.
static NSString *twab_lastPingedProxy;
static BOOL twab_lastPingedIsLuminous;
static dispatch_semaphore_t twab_pingLock;
static dispatch_once_t twab_pingLockOnce;

// Build a Basic auth header value from a proxy URL's user:pass. Returns nil
// when the URL has no credentials. NSURLSession (unlike browsers'
// XMLHttpRequest) doesn't auto-apply user:pass from a URL — we have to
// inject it explicitly or the proxy returns 407.
NSString *twab_basicAuthHeader(NSURL *url) {
  if (!url.user.length) return nil;
  NSString *raw = [NSString stringWithFormat:@"%@:%@", url.user, url.password ?: @""];
  NSData *data = [raw dataUsingEncoding:NSUTF8StringEncoding];
  return [NSString stringWithFormat:@"Basic %@", [data base64EncodedStringWithOptions:0]];
}

@implementation NSURL (TwitchAdBlock)
- (NSURL *)twab_URLWithProxyURL:(NSURL *)proxyURL {
  // Keep log args short — usher URLs carry massive query strings that
  // overflow os_log's message buffer and cause adjacent log lines to be
  // dropped (we lost ping diagnostics this way in earlier builds).
  os_log(OS_LOG_DEFAULT, "[TWAB-Proxy] enter host=%{public}@ proxyHost=%{public}@:%{public}@",
         self.host ?: @"?", proxyURL.host ?: @"?", proxyURL.port ?: @0);
  NSArray *comps = self.path.pathComponents;
  if (!comps.count || comps.count < 2) {
    os_log(OS_LOG_DEFAULT, "[TWAB-Proxy] early-return: path<2 components path=%{public}@",
           self.path ?: @"(nil)");
    return self;
  }
  BOOL isVOD = [comps[1] isEqualToString:@"vod"];
  NSString *playlistItem = [self.lastPathComponent stringByDeletingPathExtension];

  dispatch_once(&twab_pingLockOnce, ^{ twab_pingLock = dispatch_semaphore_create(1); });

  // Key the cache on scheme://host:port — credentials and path don't affect
  // whether the proxy speaks Luminous V1.
  NSString *cacheKey = [NSString stringWithFormat:@"%@://%@:%@",
                        proxyURL.scheme ?: @"http",
                        proxyURL.host ?: @"?",
                        proxyURL.port ?: @80];

  dispatch_semaphore_wait(twab_pingLock, DISPATCH_TIME_FOREVER);
  BOOL haveVerdict = [cacheKey isEqualToString:twab_lastPingedProxy];
  BOOL cachedIsLuminous = twab_lastPingedIsLuminous;
  dispatch_semaphore_signal(twab_pingLock);

  BOOL isLuminousV1;
  if (haveVerdict) {
    isLuminousV1 = cachedIsLuminous;
  } else {
    __block NSInteger statusCode = -1;
    __block NSString *errDesc = nil;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);
    NSURL *pingURL = [proxyURL URLByAppendingPathComponent:@"ping"];
    NSMutableURLRequest *pingReq = [NSMutableURLRequest requestWithURL:pingURL];
    pingReq.timeoutInterval = 3.0;
    NSString *auth = twab_basicAuthHeader(proxyURL);
    if (auth) [pingReq setValue:auth forHTTPHeaderField:@"Authorization"];
    NSDate *start = [NSDate date];
    [[NSURLSession.sharedSession
        dataTaskWithRequest:pingReq
          completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
            if ([response isKindOfClass:NSHTTPURLResponse.class])
              statusCode = ((NSHTTPURLResponse *)response).statusCode;
            errDesc = error.localizedDescription;
            dispatch_semaphore_signal(sem);
          }] resume];
    // 3.5s wait — slightly longer than the request timeout so a timed-out
    // request gets logged with its error description instead of the
    // semaphore expiring first.
    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 3500 * NSEC_PER_MSEC));
    NSTimeInterval elapsed = -[start timeIntervalSinceNow];
    isLuminousV1 = (statusCode == 200);
    os_log(OS_LOG_DEFAULT,
        "[TWAB-Proxy] ping %{public}@ status=%ld err=%{public}@ luminous=%d in %.2fs",
        cacheKey, (long)statusCode, errDesc ?: @"(none)", isLuminousV1, elapsed);

    dispatch_semaphore_wait(twab_pingLock, DISPATCH_TIME_FOREVER);
    twab_lastPingedProxy = [cacheKey copy];
    twab_lastPingedIsLuminous = isLuminousV1;
    dispatch_semaphore_signal(twab_pingLock);
  }

  if (isLuminousV1) {
    NSString *playlistType = isVOD ? @"vod" : @"playlist";

    // Build the playlist URL fragment in the ttv-lol-pro V2 format:
    //   <streamId>.m3u8?<query>
    // The full query string is preserved (allow_source, fast_bread, etc.)
    // so the proxy can negotiate the same HLS variants. For live playlists
    // (not VOD), token + sig are stripped first — the proxy fetches a
    // fresh playlist on the user's behalf and doesn't need the user's auth
    // token (this is both a privacy and an ad-evasion measure: the
    // ad-bearing token stays out of the proxy hop).
    NSString *queryString = self.query ?: @"";
    if (!isVOD && queryString.length) {
      NSURLComponents *qcomps = [NSURLComponents new];
      qcomps.percentEncodedQuery = queryString;
      NSMutableArray *items = qcomps.queryItems.mutableCopy ?: [NSMutableArray array];
      NSUInteger before = items.count;
      [items filterUsingPredicate:[NSPredicate predicateWithBlock:
          ^BOOL(NSURLQueryItem *item, NSDictionary *bindings) {
        return ![item.name isEqualToString:@"token"] &&
               ![item.name isEqualToString:@"sig"];
      }]];
      qcomps.queryItems = items.count ? items : nil;
      queryString = qcomps.percentEncodedQuery ?: @"";
      os_log(OS_LOG_DEFAULT,
          "[TWAB-Proxy] stripped %lu auth param(s) from playlist query",
          (unsigned long)(before - items.count));
    }

    NSString *fragment = queryString.length
        ? [NSString stringWithFormat:@"%@.m3u8?%@", playlistItem, queryString]
        : [NSString stringWithFormat:@"%@.m3u8", playlistItem];

    // Mimic JavaScript encodeURIComponent: encode everything except
    // alphanumerics and -_.~ (which are URI unreserved chars).
    // URLPathAllowedCharacterSet would leave / unencoded, breaking the
    // proxy's URL parsing.
    NSMutableCharacterSet *allowed = [NSMutableCharacterSet alphanumericCharacterSet];
    [allowed addCharactersInString:@"-_.~"];
    NSString *encoded = [fragment stringByAddingPercentEncodingWithAllowedCharacters:allowed];

    NSString *proxyStr = proxyURL.absoluteString;
    if (![proxyStr hasSuffix:@"/"]) proxyStr = [proxyStr stringByAppendingString:@"/"];
    NSString *fullURLString = [NSString stringWithFormat:@"%@%@/%@",
                               proxyStr, playlistType, encoded];
    return [NSURL URLWithString:fullURLString] ?: self;
  }
  return self;
}
@end