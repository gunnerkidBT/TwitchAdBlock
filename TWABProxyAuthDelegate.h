#import <Foundation/Foundation.h>

// Wraps an optional inner delegate and supplies credentials for proxy auth challenges.
@interface TWABProxyAuthDelegate : NSObject <NSURLSessionDelegate, NSURLSessionTaskDelegate>
@property (nonatomic, weak) id<NSURLSessionDelegate> inner;
@property (nonatomic, copy) NSString *proxyUser;
@property (nonatomic, copy) NSString *proxyPass;
@end
