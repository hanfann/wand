#import "WNDPrivateAPI.h"

NS_ASSUME_NONNULL_BEGIN

// A bounded, persistent read-only CoreDevice display connection.
@interface WNDDisplayInfo : NSObject
- (instancetype)initWithDevice:(id<WNDSimDevice>)device;
- (nullable NSDictionary *)readWithError:(NSError **)error;
- (void)close;
@end

NS_ASSUME_NONNULL_END
