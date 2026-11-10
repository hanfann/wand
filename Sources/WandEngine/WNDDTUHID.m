// The DTUHID wire protocol and _4sim connection recipe were documented by
// Meta's MIT-licensed idb: FBSimulatorControl/HID and XPC. See THIRD_PARTY_NOTICES.
#import "WNDDTUHID.h"
#import "WNDXPC.h"
#import <xpc/xpc.h>
#import <dlfcn.h>

static NSString *const DigitizerService = @"com.apple.coredevice.feature.remote.hid.digitizer";

static xpc_object_t Envelope(NSString *service, const char *type, xpc_object_t payload, BOOL barrier) {
  xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
  xpc_dictionary_set_string(message, "messageType", type);
  xpc_dictionary_set_string(message, "featureIdentifier", service.UTF8String);
  xpc_dictionary_set_bool(message, "isBarrier", barrier);
  xpc_dictionary_set_value(message, "payload", payload);
  return message;
}

static xpc_object_t WNDPoint(CGPoint point) {
  xpc_object_t value = xpc_dictionary_create(NULL, NULL, 0);
  xpc_dictionary_set_double(value, "x", point.x);
  xpc_dictionary_set_double(value, "y", point.y);
  return value;
}

// Each channel has its own queue so waiting on a reply never blocks its delivery.
// XPC callbacks and the command thread share only the synchronized failure field.
@interface WNDDTUChannel : NSObject
@property(nonatomic, strong) xpc_connection_t connection;
@property(nonatomic, strong) dispatch_queue_t queue;
@property(nonatomic, copy) NSString *service;
@property(atomic, copy) NSString *failure;
@property(nonatomic) BOOL retryable;
- (NSString *)connect:(id<WNDSimDevice>)device service:(NSString *)service;
- (NSString *)send:(const char *)type payload:(xpc_object_t)payload;
- (void)close;
@end

@implementation WNDDTUChannel
- (NSString *)connect:(id<WNDSimDevice>)device service:(NSString *)service {
  NSError *error = nil;
  self.service = service;
  self.queue = dispatch_queue_create("com.wand.dtuhid", DISPATCH_QUEUE_SERIAL);
  self.connection = WNDCreateConnection(device, service, self.queue, &error);
  if (!self.connection) return [NSString stringWithFormat:@"DTUHID %@ unavailable: %@", service, error.localizedDescription ?: @"no port"];
  __weak WNDDTUChannel *weakSelf = self;
  xpc_connection_set_event_handler(self.connection, ^(xpc_object_t event) {
    if (xpc_get_type(event) == XPC_TYPE_ERROR) {
      const char *detail = xpc_dictionary_get_string(event, XPC_ERROR_KEY_DESCRIPTION);
      weakSelf.failure = [NSString stringWithFormat:@"DTUHID interrupted (%s); input may have applied. Inspect the screen and restart this device's Wand daemon before retrying", detail ?: "unknown"];
    }
  });
  xpc_connection_resume(self.connection);

  // Prove that a live dtuhidd consumed a harmless probe. A successful lookup/send
  // alone can point at a launchd job that has crashed during simulator boot.
  xpc_object_t payload = xpc_dictionary_create(NULL, NULL, 0);
  xpc_dictionary_set_uint64(payload, "usageCode", 0);
  xpc_dictionary_set_uint64(payload, "state", 2);
  dispatch_semaphore_t reply = dispatch_semaphore_create(0);
  __block NSString *probeError = nil;
  xpc_connection_send_message_with_reply(self.connection,
    Envelope(service, "IndigoKeyboardButtonEvent", payload, YES), self.queue, ^(xpc_object_t event) {
      if (xpc_get_type(event) == XPC_TYPE_ERROR) probeError = @"DTUHID liveness probe returned an XPC error";
      dispatch_semaphore_signal(reply);
    });
  if (dispatch_semaphore_wait(reply, dispatch_time(DISPATCH_TIME_NOW, 4 * NSEC_PER_SEC))) {
    self.retryable = YES;
    return @"DTUHID liveness probe timed out; no input was sent";
  }
  if (probeError) { self.retryable = YES; return probeError; }
  usleep(200000); // Once per connection: let the peer open its virtual HID device.
  return self.failure;
}

- (NSString *)send:(const char *)type payload:(xpc_object_t)payload {
  if (self.failure) return self.failure;
  dispatch_semaphore_t sent = dispatch_semaphore_create(0);
  xpc_connection_send_message(self.connection, Envelope(self.service, type, payload, NO));
  xpc_connection_send_barrier(self.connection, ^{ dispatch_semaphore_signal(sent); });
  if (dispatch_semaphore_wait(sent, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC))) {
    self.failure = @"DTUHID send timed out; input may have applied. Inspect the screen and restart this device's Wand daemon before retrying";
  }
  return self.failure;
}
- (void)close {
  if (self.connection) { xpc_connection_cancel(self.connection); self.connection = nil; }
}
- (void)dealloc { [self close]; }
@end

@implementation WNDDTUHID {
  id<WNDSimDevice> _device;
  WNDDTUChannel *_digitizer;
}
- (instancetype)initWithDevice:(id<WNDSimDevice>)device {
  if ((self = [super init])) _device = device;
  return self;
}
- (NSString *)ensure:(WNDDTUChannel *__strong *)channel service:(NSString *)service {
  if (*channel) return (*channel).failure;
  NSString *failure = nil;
  // Only harmless connection probes are retried. Never replay an input event.
  for (int attempt = 0; attempt < 3; attempt++) {
    WNDDTUChannel *candidate = [WNDDTUChannel new];
    failure = [candidate connect:_device service:service];
    if (!failure) { *channel = candidate; return nil; }
    [candidate close];
    if (!candidate.retryable) break;
    if (attempt < 2) usleep(4000000);
  }
  return failure;
}
- (NSString *)touch:(CGPoint)first second:(const CGPoint *)second phase:(int)phase {
  NSString *failure = [self ensure:&_digitizer service:DigitizerService];
  if (failure) return failure;
  xpc_object_t payload = xpc_dictionary_create(NULL, NULL, 0);
  xpc_dictionary_set_value(payload, "pointOne", WNDPoint(first));
  if (second) xpc_dictionary_set_value(payload, "pointTwo", WNDPoint(*second));
  xpc_dictionary_set_uint64(payload, "eventType", phase == 1 ? 0 : phase == 2 ? 2 : 1);
  xpc_dictionary_set_uint64(payload, "edge", 0);
  xpc_dictionary_set_uint64(payload, "target", 0);
  return [_digitizer send:"IndigoDigitizerEvent" payload:payload];
}
- (NSString *)key:(int)usage down:(BOOL)down {
  NSString *failure = [self ensure:&_digitizer service:DigitizerService];
  if (failure) return failure;
  xpc_object_t payload = xpc_dictionary_create(NULL, NULL, 0);
  xpc_dictionary_set_uint64(payload, "usageCode", usage);
  xpc_dictionary_set_uint64(payload, "state", down ? 1 : 2);
  return [_digitizer send:"IndigoKeyboardButtonEvent" payload:payload];
}
- (NSString *)crown:(double)delta phase:(uint64_t)phase {
  // The digitizer endpoint accepts all Indigo event kinds, including scroll.
  // On watchOS 27.2, a separate .hid.scroll peer accepted Crown events without
  // moving Settings. Sharing the touch/keyboard peer delivers real Crown input
  // and avoids registering competing virtual HID devices per connection.
  NSString *failure = [self ensure:&_digitizer service:DigitizerService];
  if (failure) return failure;
  xpc_object_t payload = xpc_dictionary_create(NULL, NULL, 0);
  xpc_object_t point = WNDPoint(CGPointMake(0, delta));
  xpc_dictionary_set_double(point, "z", 0);
  xpc_dictionary_set_value(payload, "point", point);
  xpc_dictionary_set_uint64(payload, "phase", phase);
  xpc_dictionary_set_uint64(payload, "momentum", 0);
  xpc_dictionary_set_uint64(payload, "target", 0);
  return [_digitizer send:"IndigoScrollEvent" payload:payload];
}
- (NSString *)failure { return _digitizer.failure; }
- (void)close { [_digitizer close]; }
@end
