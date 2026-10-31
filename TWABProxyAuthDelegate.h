#import <Foundation/Foundation.h>

// Wraps an optional inner delegate and supplies credentials for proxy auth challenges.
// Wraps a proxied task for the video player, giving it a task number of its own.
// Returns what the player should hold in place of `task`.
NSURLSessionDataTask *twab_playerTaskForProxiedTask(NSURLSessionDataTask *task);

@interface TWABProxyAuthDelegate : NSObject <NSURLSessionDelegate, NSURLSessionTaskDelegate>
@property (nonatomic, weak) id<NSURLSessionDelegate> inner;
@property (nonatomic, copy) NSString *proxyUser;
@property (nonatomic, copy) NSString *proxyPass;
@end
