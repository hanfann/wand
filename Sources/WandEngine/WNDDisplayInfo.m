// CoreDevice displayinfo protocol documented by Meta idb (MIT).
// The panel orientation is independent of AX and physical device orientation.
#import "WNDDisplayInfo.h"
#import "WNDXPC.h"

// The older runtime exposes presented UI orientation on the primary screen's
// properties. This is interface orientation, not physical device attitude.
@protocol WNDLegacyScreenProperties <NSObject>
- (unsigned int)uiOrientation;
- (unsigned int)screenID;
@end
@protocol WNDLegacyScreen <NSObject>
- (id<WNDLegacyScreenProperties>)screenProperties;
@end

@implementation WNDDisplayInfo {
  id<WNDSimDevice> _device;
  xpc_connection_t _connection;
  dispatch_queue_t _queue;
  NSString *_version;
  id<WNDLegacyScreen> _legacyScreen;
  BOOL _legacyTimedOut;
}
- (instancetype)initWithDevice:(id<WNDSimDevice>)device {
  if ((self = [super init])) {
    _device = device;
    _queue = dispatch_queue_create("com.wand.display", DISPATCH_QUEUE_SERIAL);
    _version = [[NSBundle bundleWithPath:@"/Library/Developer/PrivateFrameworks/CoreDevice.framework"] objectForInfoDictionaryKey:@"CFBundleVersion"];
  }
  return self;
}
- (NSDictionary *)readLegacyWithError:(NSError **)error {
  if (_legacyTimedOut) {
    if (error) *error = [NSError errorWithDomain:@"wand.display" code:2 userInfo:@{NSLocalizedDescriptionKey:
      @"Legacy display read previously stalled; stop this daemon before retrying"}];
    return nil;
  }
  dispatch_semaphore_t ready = dispatch_semaphore_create(0);
  __block NSDictionary *result = nil;
  dispatch_async(_queue, ^{ @autoreleasepool {
    NSDictionary *value = nil;
    @try {
      if (!self->_legacyScreen) {
        id<WNDLegacyScreen> primary = nil;
        for (id<WNDIOPort> port in [(id<WNDIOClient>)[self->_device io] ioPorts]) {
          id descriptor = [port descriptor];
          if (![descriptor respondsToSelector:@selector(screenProperties)]) continue;
          id<WNDLegacyScreenProperties> properties = [(id<WNDLegacyScreen>)descriptor screenProperties];
          if (!properties || [properties screenID] != 0) continue;
          if (primary) { primary = nil; break; }
          primary = descriptor;
        }
        self->_legacyScreen = primary;
      }
      unsigned int orientation = [[self->_legacyScreen screenProperties] uiOrientation];
      // UIInterfaceOrientation -> EXIF panel-to-interface rotation.
      NSNumber *exif = @{@1:@1, @2:@3, @3:@6, @4:@8}[@(orientation)];
      id<WNDDeviceType> type = (id<WNDDeviceType>)[self->_device deviceType];
      CGSize pixels = [type mainScreenSize];
      double scale = [type mainScreenScale];
      if (exif && isfinite(pixels.width) && isfinite(pixels.height) && isfinite(scale) &&
          pixels.width > 0 && pixels.height > 0 && scale > 0) {
        value = @{@"exif":exif, @"width":@(pixels.width), @"height":@(pixels.height), @"scale":@(scale)};
      }
    } @catch (__unused NSException *exception) {}
    @synchronized (ready) { result = value; }
    dispatch_semaphore_signal(ready);
  }});
  BOOL timedOut = dispatch_semaphore_wait(ready, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) != 0;
  NSDictionary *value = nil;
  @synchronized (ready) { value = result; }
  if (timedOut) { _legacyTimedOut = YES; value = nil; } // never accumulate stuck reads
  if (!value && error) *error = [NSError errorWithDomain:@"wand.display" code:2 userInfo:@{NSLocalizedDescriptionKey:
    timedOut ? @"Legacy display geometry deadline exceeded; no input sent" : @"Legacy primary screen orientation unavailable; no input sent"}];
  return value;
}
- (NSDictionary *)readWithError:(NSError **)error {
  NSError *failure = nil;
  if (!_connection) {
    _connection = WNDCreateConnection(_device, @"com.apple.coredevice.feature.getdisplayinfo", _queue, &failure);
    if (!_connection) { if (error) *error = failure; return nil; }
    xpc_connection_set_event_handler(_connection, ^(xpc_object_t event) {});
    xpc_connection_resume(_connection);
  }
  xpc_object_t request = xpc_dictionary_create(NULL, NULL, 0);
  xpc_dictionary_set_string(request, "CoreDevice.actionIdentifier", "com.apple.coredevice.action.displayinfo");
  xpc_dictionary_set_string(request, "CoreDevice.deviceIdentifier", [_device UDID].UUIDString.UTF8String);
  xpc_dictionary_set_string(request, "CoreDevice.invocationIdentifier", NSUUID.UUID.UUIDString.UTF8String);
  xpc_dictionary_set_int64(request, "CoreDevice.CoreDeviceDDIProtocolVersion", 1);
  xpc_dictionary_set_value(request, "CoreDevice.input", xpc_dictionary_create(NULL, NULL, 0));
  xpc_object_t version = xpc_dictionary_create(NULL, NULL, 0), components = xpc_array_create(NULL, 0);
  NSArray *parts = [_version componentsSeparatedByString:@"."];
  for (NSString *part in parts) xpc_array_append_value(components, xpc_uint64_create(part.longLongValue));
  xpc_dictionary_set_value(version, "components", components);
  xpc_dictionary_set_int64(version, "originalComponentsCount", parts.count);
  xpc_dictionary_set_string(version, "stringValue", _version.UTF8String ?: "");
  xpc_dictionary_set_value(request, "CoreDevice.coreDeviceVersion", version);
  dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
  __block xpc_object_t response = nil;
  xpc_connection_send_message_with_reply(_connection, request, _queue, ^(xpc_object_t reply) {
    @synchronized (semaphore) { response = reply; }
    dispatch_semaphore_signal(semaphore);
  });
  BOOL timedOut = dispatch_semaphore_wait(semaphore, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) != 0;
  xpc_object_t reply = nil;
  @synchronized (semaphore) { reply = response; }
  NSDictionary *result = timedOut ? nil : [self decode:reply];
  if (!result) {
    [self close]; // a future read can reconnect; no input is replayed
    if (error) *error = [NSError errorWithDomain:@"wand.display" code:1 userInfo:@{NSLocalizedDescriptionKey:
      timedOut ? @"Display geometry deadline exceeded; no input sent" : @"No unambiguous active display geometry; no input sent"}];
  }
  return result;
}
- (NSDictionary *)decode:(xpc_object_t)reply {
  if (!reply || xpc_get_type(reply) != XPC_TYPE_DICTIONARY || xpc_dictionary_get_value(reply, "CoreDevice.error")) return nil;
  xpc_object_t output = xpc_dictionary_get_value(reply, "CoreDevice.output");
  if (!output || xpc_get_type(output) != XPC_TYPE_DICTIONARY || !xpc_dictionary_get_bool(output, "current")) return nil;
  xpc_object_t displays = xpc_dictionary_get_value(output, "displays");
  if (!displays || xpc_get_type(displays) != XPC_TYPE_ARRAY || xpc_array_get_count(displays) > 32) return nil;
  NSDictionary *selected = nil;
  NSUInteger integratedCount = 0;
  for (size_t i = 0; i < xpc_array_get_count(displays); i++) {
    xpc_object_t item = xpc_array_get_value(displays, i);
    if (xpc_get_type(item) != XPC_TYPE_DICTIONARY) return nil;
    xpc_object_t type = xpc_dictionary_get_value(item, "type");
    if (!type || xpc_get_type(type) != XPC_TYPE_DICTIONARY || !xpc_dictionary_get_value(type, "integrated")) continue;
    // HID targets panel zero. Refuse multi-panel/foldable configurations until
    // input and screenshots can explicitly address the selected panel together.
    if (++integratedCount > 1) return nil;
    xpc_object_t active = xpc_dictionary_get_value(item, "active");
    if (active && xpc_get_type(active) != XPC_TYPE_BOOL) return nil;
    if (active ? !xpc_bool_get_value(active) : !xpc_dictionary_get_bool(item, "primary")) continue;
    if (selected) return nil;
    const char *rotation = xpc_dictionary_get_string(item, "currentOrientation");
    NSNumber *exif = rotation ? @{@"rot0":@1, @"rot90":@6, @"rot180":@3, @"rot270":@8}[@(rotation)] : nil;
    xpc_object_t bounds = xpc_dictionary_get_value(item, "bounds");
    if (!exif || !bounds || xpc_get_type(bounds) != XPC_TYPE_ARRAY || xpc_array_get_count(bounds) != 2) return nil;
    xpc_object_t size = xpc_array_get_value(bounds, 1);
    if (xpc_get_type(size) != XPC_TYPE_ARRAY || xpc_array_get_count(size) != 2) return nil;
    if (xpc_get_type(xpc_array_get_value(size, 0)) != XPC_TYPE_DOUBLE ||
        xpc_get_type(xpc_array_get_value(size, 1)) != XPC_TYPE_DOUBLE) return nil;
    double width = xpc_double_get_value(xpc_array_get_value(size, 0)), height = xpc_double_get_value(xpc_array_get_value(size, 1));
    int64_t scale = xpc_dictionary_get_int64(item, "pointScale");
    if (!isfinite(width) || !isfinite(height) || width <= 0 || height <= 0 || scale <= 0) return nil;
    selected = @{@"exif":exif, @"width":@(width), @"height":@(height), @"scale":@(scale)};
  }
  return selected;
}
- (void)close { if (_connection) { xpc_connection_cancel(_connection); _connection = nil; } }
- (void)dealloc { [self close]; }
@end
