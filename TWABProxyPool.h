#import <Foundation/Foundation.h>

// Spreads requests over several proxies and steps around ones that are down.
//
// - Each proxy is checked in the background at launch and every few minutes.
// - Every install has its own fixed random number, so users are spread
//   evenly over the healthy proxies of similar speed. Clearly slower ones
//   are only used when the faster ones are down.
// - The pick sticks until that proxy fails, so one stream stays on one proxy.
// - A proxy whose request fails is benched for a while (longer each time it
//   keeps failing) and the next pick uses another one.

// The proxy to use now, chosen from `addresses`. Returns nil only when every
// proxy failed its last check, so the caller can go direct.
NSString *twab_proxyPoolPick(NSArray<NSString *> *addresses);

// Outcome of a request that went through `address`.
void twab_proxyPoolReportResult(NSString *address, NSError *error);

// Starts the background checks. Safe to call more than once.
void twab_proxyPoolStart(void);

// Forgets the current pick, so the next request chooses afresh (after the
// user changes their preferred proxy).
void twab_proxyPoolResetPick(void);

// What the pool knows about one proxy: @"up" (NSNumber BOOL, absent until
// checked), @"latencyMs" (NSNumber, when up), @"benched", @"current".
NSDictionary *twab_proxyPoolInfo(NSString *address);

// Checks every address now and reports how many answered (main queue).
void twab_proxyPoolCheckNow(NSArray<NSString *> *addresses,
                            void (^completion)(NSUInteger online, NSUInteger total));
