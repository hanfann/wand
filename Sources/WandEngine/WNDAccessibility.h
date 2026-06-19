// WNDAccessibility.h — the shared AXPTranslator token delegate.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface WNDAXDispatcher : NSObject
+ (instancetype)shared;
/// The AXPTranslator singleton, wired to this dispatcher (lazily).
- (nullable id)translator;
- (void)registerToken:(NSString *)token device:(id)device;
- (void)unregisterToken:(NSString *)token;
@end

NS_ASSUME_NONNULL_END
