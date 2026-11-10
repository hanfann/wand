// Native builder and gesture failure contracts; no simulator or input delivery.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wnullability-completeness"
#import "../Sources/WandEngine/WNDSimulator.m"
#pragma clang diagnostic pop
#include <assert.h>

@interface GestureProbe : WNDSimulator
@property NSUInteger calls, failAt;
- (void)useNativeBuilder;
@end
@implementation GestureProbe
- (void)useNativeBuilder {
  WNDMouseEventFn builder = (WNDMouseEventFn)dlsym(gSKHandle, "IndigoHIDMessageForMouseNSEvent");
  Ivar slot = class_getInstanceVariable(WNDSimulator.class, "_mouseFn");
  assert(builder && slot);
  // Test-only injection avoids constructing any simulator/HID connection.
  memcpy((char *)(__bridge void *)self + ivar_getOffset(slot), &builder, sizeof(builder));
}
- (BOOL)twoFingerTouchAtPoint1:(CGPoint)p1 point2:(CGPoint)p2 direction:(int)direction wait:(BOOL)wait {
  self.calls += 1;
  if (self.calls == self.failAt) {
    [self setValue:@"injected delivery failure" forKey:@"lastSendError"];
    return NO;
  }
  return YES;
}
@end

int main(void) { @autoreleasepool {
  NSError *error=nil;
  assert([WNDSimulator loadFrameworks:&error]);
  if (WNDUsesDTUHID()) assert(gSKHandle==NULL);
  assert([WNDSimulator loadLegacyInputFramework:&error]);
  GestureProbe *probe=[GestureProbe new];
  [probe useNativeBuilder];
  for (int phase=1;phase<=6;phase++) {
    if (phase!=1 && phase!=2 && phase!=6) continue;
    size_t size=0;
    WNDIndigoMessage *message=[probe buildTouchMessageAtRatio:CGPointMake(.25,.75) direction:phase sizeOut:&size];
    assert(message && size>0);
    free(message);
  }
  puts("PASS: native single-contact down/move/up all produce valid Indigo packets");
  // A lazy transport satisfies the availability guard; the override never sends.
  [probe setValue:[[WNDDTUHID alloc] initWithDevice:(id)[NSNull null]] forKey:@"modernHID"];
  for (NSUInteger failAt=1;failAt<=6;failAt++) {
    for (int rotation=0;rotation<2;rotation++) {
      probe.calls=0; probe.failAt=failAt; error=nil;
      BOOL ok=rotation ? [probe rotateAtX:100 y:100 radians:.9 duration:.048 error:&error]
                       : [probe pinchAtX:100 y:100 scale:1.8 duration:.048 error:&error];
      assert(!ok && [error.localizedDescription isEqual:@"injected delivery failure"]);
      assert(probe.calls==failAt); // Stop at failure; never replay or continue.
    }
  }
  probe.calls=0; probe.failAt=0;
  assert([probe pinchAtX:100 y:100 scale:1.8 duration:.048 error:nil]);
  assert(probe.calls==6);
  puts("PASS: pinch/rotate propagate down, move and release failures without replay");
}}
