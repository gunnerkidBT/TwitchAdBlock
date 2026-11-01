#import <Foundation/Foundation.h>

@interface NSData (TwitchAdBlock)
- (NSData *)twab_requestDataForRequest:(NSURLRequest *)request;
- (NSData *)twab_responseDataForRequest:(NSURLRequest *)request;
- (NSData *)twab_dataHidingLeaderboardsForRequest:(NSURLRequest *)request;
- (NSData *)twab_responseDataForRequest:(NSURLRequest *)request hideTurboOffers:(BOOL)hideTurboOffers;
@end

// Removes feed ads from what the native feed preload hands to React Native. It can be
// JSON text, possibly nested in another object or string. Returns `result` if unchanged.
id twab_stripPreloadFeedAds(id result, NSUInteger depth);
