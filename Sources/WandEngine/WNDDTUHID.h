// Xcode 27 host-to-simulator HID. Connections are lazy and persist across gestures.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import "WNDPrivateAPI.h"

NS_ASSUME_NONNULL_BEGIN
@interface WNDDTUHID : NSObject
- (instancetype)initWithDevice:(id<WNDSimDevice>)device;
- (nullable NSString *)touch:(CGPoint)first second:(nullable const CGPoint *)second phase:(int)phase;
- (nullable NSString *)key:(int)usage down:(BOOL)down;
- (nullable NSString *)crown:(double)delta phase:(uint64_t)phase;
@property(nonatomic, readonly, nullable) NSString *failure;
- (void)close;
@end
NS_ASSUME_NONNULL_END
