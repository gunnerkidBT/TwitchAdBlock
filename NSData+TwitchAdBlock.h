#import <Foundation/Foundation.h>

@interface NSData (TwitchAdBlock)
- (NSData *)twab_requestDataForRequest:(NSURLRequest *)request;
- (NSData *)twab_responseDataForRequest:(NSURLRequest *)request;
- (NSData *)twab_dataHidingLeaderboardsForRequest:(NSURLRequest *)request;
- (NSData *)twab_responseDataForRequest:(NSURLRequest *)request hideTurboOffers:(BOOL)hideTurboOffers;
@end