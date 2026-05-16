#pragma once
#import <Foundation/Foundation.h>

// Default proxy address, decoded at runtime so the host/credentials don't
// appear as plaintext in the public repo nor in `strings` on the dylib.
NSString *twab_defaultProxyAddress(void);
#define PROXY_ADDR (twab_defaultProxyAddress())
