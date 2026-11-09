// WNDSimulator.m
#import "WandEngine.h"
#import "WNDIndigo.h"
#import "WNDPrivateAPI.h"
#import "WNDAccessibility.h"

#import <AppKit/AppKit.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import <IOSurface/IOSurface.h>
#import <Vision/Vision.h>
#import <objc/runtime.h>
#import <dlfcn.h>
#import <mach/mach_time.h>
#import <malloc/malloc.h>

static NSString *const WNDErrorDomain = @"com.wand.engine";

// Native builder ABI includes the coordinate-space width and height.
typedef WNDIndigoMessage *(*WNDMouseEventFn)(CGPoint *p0, CGPoint *p1, int target, int eventType, int edge, double width, double height);
// IndigoHIDMessageForKeyboardArbitrary(usageCode, op) — op 1=down 2=up.
typedef WNDIndigoMessage *(*WNDKeyboardFn)(int keyCode, int op);
// IndigoHIDMessageForDigitalCrownEvent(delta) — watchOS Digital Crown. A single
// double arg: the rotation delta (sign = direction). Returns a 0xC0 message.
// Signature recovered from SimulatorKit disassembly (one d0 arg → stur at +0x3c).
typedef WNDIndigoMessage *(*WNDCrownFn)(double delta);

static size_t WNDMessageSize(WNDIndigoMessage *message) {
  if (!message) return 0;
  uint32_t stride = message->innerSize;
  uint8_t count = message->eventType; // Number of payloads, not the input kind.
  if ((stride != 0x90 && stride != 0xA0) || count < 1 || count > 4) return 0;
  size_t size = 0x20 + stride * count;
  return malloc_size(message) >= size ? size : 0;
}

static void *gCSHandle = NULL;  // CoreSimulator
static void *gSKHandle = NULL;  // SimulatorKit
static void *gAXHandle = NULL;  // AccessibilityPlatformTranslation

static NSError *WNDMakeError(NSInteger code, NSString *msg) {
  return [NSError errorWithDomain:WNDErrorDomain code:code
                         userInfo:@{NSLocalizedDescriptionKey: msg}];
}

// Resolve the active developer dir (DEVELOPER_DIR env, else `xcode-select -p`).
static NSString *WNDDeveloperDir(void) {
  const char *env = getenv("DEVELOPER_DIR");
  if (env && strlen(env) > 0) {
    return [NSString stringWithUTF8String:env];
  }
  FILE *fp = popen("/usr/bin/xcode-select -p 2>/dev/null", "r");
  if (!fp) return @"/Applications/Xcode.app/Contents/Developer";
  char buf[1024];
  NSMutableString *out = [NSMutableString string];
  while (fgets(buf, sizeof(buf), fp)) [out appendString:[NSString stringWithUTF8String:buf]];
  pclose(fp);
  NSString *trimmed = [out stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
  return trimmed.length ? trimmed : @"/Applications/Xcode.app/Contents/Developer";
}

@interface WNDSimulator () {
  id<WNDSimDevice> _device;
  id<WNDLegacyHIDClient> _hidClient;
  dispatch_queue_t _hidQueue;
  dispatch_queue_t _axQueue;
  WNDMouseEventFn _mouseFn;
  WNDKeyboardFn _keyboardFn;
  WNDCrownFn _crownFn;
  CGSize _pixelSize;
  BOOL _isWatch;
  NSString *_lastSendError;
  NSString * _Nullable (^_guestSender)(NSData *);

}
@end

@implementation WNDSimulator

#pragma mark - Framework loading

+ (BOOL)loadFrameworks:(NSError **)error {
  static dispatch_once_t once;
  static BOOL ok = NO;
  dispatch_once(&once, ^{
    NSString *dev = WNDDeveloperDir();
    gCSHandle = dlopen("/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator", RTLD_NOW);
    // Newer Xcodes moved SimulatorKit from Developer/Library/PrivateFrameworks
    // to Contents/SharedFrameworks (a sibling of Developer). Try both.
    NSArray<NSString *> *skPaths = @[
      [dev stringByAppendingString:@"/Library/PrivateFrameworks/SimulatorKit.framework/SimulatorKit"],
      [[dev stringByDeletingLastPathComponent] stringByAppendingString:@"/SharedFrameworks/SimulatorKit.framework/SimulatorKit"],
    ];
    for (NSString *skPath in skPaths) {
      gSKHandle = dlopen(skPath.UTF8String, RTLD_NOW);
      if (gSKHandle) break;
    }
    gAXHandle = dlopen("/System/Library/PrivateFrameworks/AccessibilityPlatformTranslation.framework/AccessibilityPlatformTranslation", RTLD_NOW);
    ok = (gCSHandle != NULL && gSKHandle != NULL);
  });
  if (!ok && error) {
    *error = WNDMakeError(1, [NSString stringWithFormat:
      @"Failed to load private frameworks (CoreSimulator=%p SimulatorKit=%p). dlerror: %s",
      gCSHandle, gSKHandle, dlerror()]);
  }
  return ok;
}

#pragma mark - Discovery

+ (nullable instancetype)bootedSimulatorWithError:(NSError **)error {
  return [self simulatorWithUDID:nil error:error];
}

+ (nullable instancetype)simulatorWithUDID:(NSString *)udid error:(NSError **)error {
  if (![self loadFrameworks:error]) return nil;

  Class ctxCls = objc_getClass("SimServiceContext");
  if (!ctxCls) {
    if (error) *error = WNDMakeError(2, @"SimServiceContext class not found");
    return nil;
  }
  NSError *e = nil;
  NSString *dev = WNDDeveloperDir();
  id ctx = [(id<WNDServiceContextClass>)ctxCls sharedServiceContextForDeveloperDir:dev error:&e];
  if (!ctx) {
    if (error) *error = e ?: WNDMakeError(3, @"sharedServiceContextForDeveloperDir failed");
    return nil;
  }
  id set = [(id<WNDServiceContext>)ctx defaultDeviceSetWithError:&e];
  if (!set) {
    if (error) *error = e ?: WNDMakeError(4, @"defaultDeviceSetWithError failed");
    return nil;
  }
  NSArray *devices = [(id<WNDDeviceSet>)set devices];
  id<WNDSimDevice> match = nil;
  for (id<WNDSimDevice> d in devices) {
    BOOL booted = ([d state] == 3); // SimDeviceStateBooted
    if (!booted) continue;
    if (udid) {
      if ([[d UDID].UUIDString caseInsensitiveCompare:udid] == NSOrderedSame) { match = d; break; }
    } else {
      match = d; break;
    }
  }
  if (!match) {
    if (error) *error = WNDMakeError(5, udid
      ? [NSString stringWithFormat:@"No booted simulator with UDID %@", udid]
      : @"No booted simulator found");
    return nil;
  }
  return [[self alloc] initWithDevice:match];
}

- (instancetype)initWithDevice:(id<WNDSimDevice>)device {
  self = [super init];
  if (!self) return nil;
  _device = device;

  _udid = [device UDID].UUIDString;
  _name = [device name];

  id<WNDDeviceType> dt = (id<WNDDeviceType>)[device deviceType];
  CGSize px = [dt mainScreenSize];
  float scale = [dt mainScreenScale];
  if (scale <= 0) scale = 1.0;

  // watchOS detection for the Digital Crown guard. The device-type identifier
  // (e.g. ...SimDeviceType.Apple-Watch-Series-11-46mm) is not user-editable;
  // fall back to the display name if the selector is unavailable.
  NSString *typeId = nil;
  if ([dt respondsToSelector:@selector(identifier)]) {
    @try { typeId = [dt identifier]; } @catch (__unused id e) {}
  }
  _isWatch = ([typeId rangeOfString:@"Watch" options:NSCaseInsensitiveSearch].location != NSNotFound) ||
             ([[device name] rangeOfString:@"Watch" options:NSCaseInsensitiveSearch].location != NSNotFound);
  _pixelSize = px;
  _screenScale = scale;
  _screenPointSize = CGSizeMake(px.width / scale, px.height / scale);

  Class hidCls = objc_lookUpClass("SimulatorKit.SimDeviceLegacyHIDClient");
  if (hidCls) {
    NSError *e = nil;
    _hidClient = [(id<WNDLegacyHIDClient>)[hidCls alloc] initWithDevice:device error:&e];
  }
  _hidQueue = dispatch_queue_create("com.wand.hid", DISPATCH_QUEUE_SERIAL);
  _axQueue = dispatch_queue_create("com.wand.ax", DISPATCH_QUEUE_SERIAL);
  _mouseFn = (WNDMouseEventFn)dlsym(gSKHandle, "IndigoHIDMessageForMouseNSEvent");
  _keyboardFn = (WNDKeyboardFn)dlsym(gSKHandle, "IndigoHIDMessageForKeyboardArbitrary");
  _crownFn = (WNDCrownFn)dlsym(gSKHandle, "IndigoHIDMessageForDigitalCrownEvent");
  return self;
}

#pragma mark - Message construction

- (CGPoint)ratioForPoint:(CGPoint)pt {
  return CGPointMake((pt.x * _screenScale) / _pixelSize.width,
                     (pt.y * _screenScale) / _pixelSize.height);
}

// Keep Apple's complete message, including its runtime-dependent payload stride,
// capability bits and digitizer summary. Supported native strides: 0x90/0xA0.
// The final doubles are the coordinate-space dimensions (see Apple's caller);
// normalized points therefore use 1 x 1. Omitting them divides by undefined data.
- (WNDIndigoMessage *)buildTouchMessageAtRatio:(CGPoint)ratio direction:(int)direction sizeOut:(size_t *)sizeOut {
  if (!_mouseFn) return NULL;
  WNDIndigoMessage *message = _mouseFn(&ratio, NULL, 0x32, direction, 0, 1.0, 1.0);
  size_t size = WNDMessageSize(message);
  if (size && message->innerSize == 0x90) {
    for (uint8_t i = 0; i < message->eventType; i++) {
      char *payload = (char *)message + 0x20 + i * message->innerSize;
      memcpy(payload + 0x1c, &ratio.x, sizeof(double));
      memcpy(payload + 0x24, &ratio.y, sizeof(double));
    }
  }
  if (sizeOut) *sizeOut = size;
  return message;
}

// The guest bridge acknowledges each Mach send. Keep the legacy backend for
// older Xcodes; completion errors and timeouts must both fail the command.
- (BOOL)sendMessage:(WNDIndigoMessage *)message size:(size_t)size wait:(BOOL)wait {
  if (!message || size == 0) {
    _lastSendError = @"invalid or unsupported native HID message";
    return NO;
  }
  if (!_hidClient) { _lastSendError = @"HID client unavailable"; return NO; }
  void *copy = malloc(size);
  memcpy(copy, message, size);
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  __block NSError *sendError = nil;
  [_hidClient sendWithMessage:copy freeWhenDone:YES completionQueue:_hidQueue completion:^(NSError *error) {
    sendError = error;
    dispatch_semaphore_signal(sem);
  }];
  if (dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC)) != 0) {
    _lastSendError = @"HID send timed out";
    return NO;
  }
  if (sendError) { _lastSendError = sendError.localizedDescription; return NO; }
  if (getenv("WAND_HID_DEBUG")) {
    fprintf(stderr, "[WAND_HID] native stride=0x%x count=%u bytes=%zu acknowledged\n", message->innerSize, message->eventType, size);
  }
  return YES;
}

- (void)setGuestTouchSender:(NSString * _Nullable (^)(NSData *))sender {
  _guestSender = [sender copy];
}

- (BOOL)sendGuestTouches:(CGPoint *)points count:(uint32_t)count direction:(uint32_t)direction {
  uint32_t header[] = {direction, count};
  NSMutableData *packet = [NSMutableData dataWithBytes:header length:sizeof(header)];
  [packet appendBytes:points length:count * sizeof(CGPoint)];
  NSString *failure = _guestSender(packet);
  if (failure) _lastSendError = failure;
  return failure == nil;
}

- (BOOL)touchAtPoint:(CGPoint)pt direction:(int)direction wait:(BOOL)wait {
  CGPoint r = [self ratioForPoint:pt];
  if (_guestSender) return [self sendGuestTouches:&r count:1 direction:direction];
  size_t sz = 0;
  WNDIndigoMessage *m = [self buildTouchMessageAtRatio:r direction:direction sizeOut:&sz];
  BOOL ok = [self sendMessage:m size:sz wait:wait];
  free(m);
  return ok;
}

// Let the native builder author all finger and summary payloads. Their stride
// changed in Xcode 27, so patching hard-coded finger offsets corrupts the packet.
- (BOOL)twoFingerTouchAtPoint1:(CGPoint)p1 point2:(CGPoint)p2 direction:(int)direction wait:(BOOL)wait {
  if (!_mouseFn) return NO;
  CGPoint r1 = [self ratioForPoint:p1], r2 = [self ratioForPoint:p2];
  if (_guestSender) { CGPoint points[] = {r1, r2}; return [self sendGuestTouches:points count:2 direction:direction]; }
  WNDIndigoMessage *message = _mouseFn(&r1, &r2, 0x32, direction, 0, 1.0, 1.0);
  size_t size = WNDMessageSize(message);
  if (size && message->innerSize == 0x90) {
    for (uint8_t i = 0; i < message->eventType; i++) {
      CGPoint point = i == 2 ? r2 : r1;
      char *payload = (char *)message + 0x20 + i * message->innerSize;
      memcpy(payload + 0x1c, &point.x, sizeof(double));
      memcpy(payload + 0x24, &point.y, sizeof(double));
    }
  }
  BOOL ok = [self sendMessage:message size:size wait:wait];
  free(message);
  return ok;
}

#pragma mark - Gestures

- (BOOL)tapAtX:(double)x y:(double)y error:(NSError **)error {
  if (!_hidClient && !_guestSender) { if (error) *error = WNDMakeError(10, @"HID client unavailable"); return NO; }
  CGPoint p = CGPointMake(x, y);
  if (![self touchAtPoint:p direction:WND_BUTTON_TYPE_DOWN wait:YES]) {
    if (error) *error = WNDMakeError(13, _lastSendError); return NO;
  }
  usleep(60 * 1000);
  if (![self touchAtPoint:p direction:WND_BUTTON_TYPE_UP wait:YES]) {
    if (error) *error = WNDMakeError(13, _lastSendError); return NO;
  }
  return YES;
}

- (BOOL)longPressAtX:(double)x y:(double)y duration:(double)seconds error:(NSError **)error {
  if (!_hidClient && !_guestSender) { if (error) *error = WNDMakeError(10, @"HID client unavailable"); return NO; }
  CGPoint p = CGPointMake(x, y);
  if (![self touchAtPoint:p direction:WND_BUTTON_TYPE_DOWN wait:YES]) {
    if (error) *error = WNDMakeError(13, _lastSendError); return NO;
  }
  usleep((useconds_t)(seconds * 1e6));
  if (![self touchAtPoint:p direction:WND_BUTTON_TYPE_UP wait:YES]) {
    if (error) *error = WNDMakeError(13, _lastSendError); return NO;
  }
  return YES;
}

- (BOOL)swipeFromX:(double)x1 y:(double)y1 toX:(double)x2 y:(double)y2
          duration:(double)duration error:(NSError **)error {
  if (!_hidClient && !_guestSender) { if (error) *error = WNDMakeError(10, @"HID client unavailable"); return NO; }
  return [self dragFromX:x1 y:y1 toX:x2 y:y2 holdDuration:0 moveDuration:duration error:error];
}

- (BOOL)dragFromX:(double)x1 y:(double)y1 toX:(double)x2 y:(double)y2
      holdDuration:(double)holdDuration moveDuration:(double)moveDuration error:(NSError **)error {
  if (!_hidClient && !_guestSender) { if (error) *error = WNDMakeError(10, @"HID client unavailable"); return NO; }

  CGPoint start = CGPointMake(x1, y1);
  CGPoint end = CGPointMake(x2, y2);

  // Touch down at the start.
  if (![self touchAtPoint:start direction:WND_BUTTON_TYPE_DOWN wait:YES]) {
    if (error) *error = WNDMakeError(13, _lastSendError); return NO;
  }

  // Hold (drag-and-drop pickup) — re-emit the contact so recognizers fire.
  if (holdDuration > 0) {
    NSUInteger holdSteps = MAX((NSUInteger)1, (NSUInteger)(holdDuration / 0.05));
    for (NSUInteger i = 0; i < holdSteps; i++) {
      if (![self touchAtPoint:start direction:6 wait:NO]) {
        if (error) *error = WNDMakeError(13, _lastSendError); return NO;
      }
      usleep(50 * 1000);
    }
  } else {
    usleep(20 * 1000);
  }

  // Interpolate from start to end. ~1 sample per frame (12ms).
  double dur = moveDuration > 0 ? moveDuration : 0.3;
  NSUInteger steps = MAX((NSUInteger)2, (NSUInteger)(dur / 0.012));
  useconds_t perStep = (useconds_t)((dur / steps) * 1e6);
  for (NSUInteger i = 1; i <= steps; i++) {
    double t = (double)i / (double)steps;
    CGPoint p = CGPointMake(start.x + (end.x - start.x) * t,
                            start.y + (end.y - start.y) * t);
    if (![self touchAtPoint:p direction:6 wait:NO]) {
      if (error) *error = WNDMakeError(13, _lastSendError); return NO;
    }
    usleep(perStep);
  }

  // Release at the end.
  if (![self touchAtPoint:end direction:WND_BUTTON_TYPE_UP wait:YES]) {
    if (error) *error = WNDMakeError(13, _lastSendError); return NO;
  }
  return YES;
}

// Two-finger gesture along a parameterized path. `pointsAtT` yields the two
// finger positions for t in [0,1]. Down, interpolate, up.
- (void)twoFingerGestureDuration:(double)duration
                        positions:(void (^)(double t, CGPoint *p1, CGPoint *p2))positions {
  double dur = duration > 0 ? duration : 0.4;
  NSUInteger steps = MAX((NSUInteger)4, (NSUInteger)(dur / 0.012));
  useconds_t perStep = (useconds_t)((dur / steps) * 1e6);

  CGPoint p1, p2;
  positions(0.0, &p1, &p2);
  [self twoFingerTouchAtPoint1:p1 point2:p2 direction:WND_BUTTON_TYPE_DOWN wait:YES];
  usleep(20 * 1000);
  for (NSUInteger i = 1; i <= steps; i++) {
    double t = (double)i / (double)steps;
    positions(t, &p1, &p2);
    [self twoFingerTouchAtPoint1:p1 point2:p2 direction:6 wait:NO];
    usleep(perStep);
  }
  positions(1.0, &p1, &p2);
  [self twoFingerTouchAtPoint1:p1 point2:p2 direction:WND_BUTTON_TYPE_UP wait:YES];
}

- (BOOL)pinchAtX:(double)x y:(double)y scale:(double)scale duration:(double)duration error:(NSError **)error {
  if ((!_hidClient && !_guestSender) || !_mouseFn) { if (error) *error = WNDMakeError(10, @"HID client unavailable"); return NO; }
  CGPoint center = CGPointMake(x, y);
  double base = MIN(_screenPointSize.width, _screenPointSize.height) / 4.0;
  double startGap = (scale >= 1.0) ? base : base * scale;
  double endGap   = (scale >= 1.0) ? base * scale : base;
  [self twoFingerGestureDuration:duration positions:^(double t, CGPoint *p1, CGPoint *p2) {
    double gap = startGap + (endGap - startGap) * t;
    *p1 = CGPointMake(center.x - gap / 2.0, center.y);
    *p2 = CGPointMake(center.x + gap / 2.0, center.y);
  }];
  return YES;
}

- (BOOL)rotateAtX:(double)x y:(double)y radians:(double)radians duration:(double)duration error:(NSError **)error {
  if ((!_hidClient && !_guestSender) || !_mouseFn) { if (error) *error = WNDMakeError(10, @"HID client unavailable"); return NO; }
  CGPoint center = CGPointMake(x, y);
  double radius = MIN(_screenPointSize.width, _screenPointSize.height) / 5.0;
  [self twoFingerGestureDuration:duration positions:^(double t, CGPoint *p1, CGPoint *p2) {
    double a = radians * t;
    *p1 = CGPointMake(center.x + radius * cos(a),          center.y + radius * sin(a));
    *p2 = CGPointMake(center.x + radius * cos(a + M_PI),   center.y + radius * sin(a + M_PI));
  }];
  return YES;
}

// watchOS Digital Crown. Apple's IndigoHIDMessageForDigitalCrownEvent(double)
// builds a single 0xC0 crown message; we emit `steps` fractional turns over
// `duration` so the guest sees a continuous rotation rather than one jump.
- (BOOL)turnCrownBy:(double)delta steps:(NSUInteger)steps duration:(double)duration error:(NSError **)error {
  if (!_isWatch) { if (error) *error = WNDMakeError(13, @"Digital Crown is only available on watchOS simulators"); return NO; }
  if (!_crownFn) { if (error) *error = WNDMakeError(12, @"Digital Crown HID unavailable (non-watchOS sim?)"); return NO; }
  if (steps < 1) steps = 1;
  double per = delta / (double)steps;
  double dur = duration > 0 ? duration : 0.25;
  useconds_t perStep = (useconds_t)((dur / steps) * 1e6);
  for (NSUInteger i = 0; i < steps; i++) {
    WNDIndigoMessage *m = _crownFn(per);
    if (!m) continue;
    size_t size = WNDMessageSize(m);
    BOOL ok = [self sendMessage:m size:size wait:NO];
    free(m);
    if (!ok) { if (error) *error = WNDMakeError(13, _lastSendError); return NO; }
    usleep(perStep);
  }
  return YES;
}

- (BOOL)isBooted {
  @try { return [_device state] == 3; } @catch (__unused id e) { return NO; }
}

#pragma mark - Keyboard

// HID usage code (USB HID Keyboard/Keypad page) + shift flag for an ASCII char.
static BOOL WNDUsageForChar(unichar c, int *usage, BOOL *shift) {
  *shift = NO;
  if (c >= 'a' && c <= 'z') { *usage = 0x04 + (c - 'a'); return YES; }
  if (c >= 'A' && c <= 'Z') { *usage = 0x04 + (c - 'A'); *shift = YES; return YES; }
  if (c >= '1' && c <= '9') { *usage = 0x1E + (c - '1'); return YES; }
  switch (c) {
    case '0': *usage = 0x27; return YES;
    case ' ': *usage = 0x2C; return YES;
    case '\n': case '\r': *usage = 0x28; return YES; // return
    case '\t': *usage = 0x2B; return YES;
    case '-': *usage = 0x2D; return YES;
    case '=': *usage = 0x2E; return YES;
    case '.': *usage = 0x37; return YES;
    case ',': *usage = 0x36; return YES;
    case '/': *usage = 0x38; return YES;
    case ';': *usage = 0x33; return YES;
    case '\'': *usage = 0x34; return YES;
    case '!': *usage = 0x1E; *shift = YES; return YES;
    case '@': *usage = 0x1F; *shift = YES; return YES;
    case '#': *usage = 0x20; *shift = YES; return YES;
    case '$': *usage = 0x21; *shift = YES; return YES;
    case '%': *usage = 0x22; *shift = YES; return YES;
    case '^': *usage = 0x23; *shift = YES; return YES;
    case '&': *usage = 0x24; *shift = YES; return YES;
    case '*': *usage = 0x25; *shift = YES; return YES;
    case '(': *usage = 0x26; *shift = YES; return YES;
    case ')': *usage = 0x27; *shift = YES; return YES;
    case '_': *usage = 0x2D; *shift = YES; return YES;
    case '+': *usage = 0x2E; *shift = YES; return YES;
    case '?': *usage = 0x38; *shift = YES; return YES;
    case ':': *usage = 0x33; *shift = YES; return YES;
    default: return NO;
  }
}

- (BOOL)sendKeyUsage:(int)usage down:(BOOL)down {
  if (!_keyboardFn) return NO;
  WNDIndigoMessage *m = _keyboardFn(usage, down ? WND_BUTTON_TYPE_DOWN : WND_BUTTON_TYPE_UP);
  if (!m) return NO;
  size_t size = WNDMessageSize(m);
  BOOL ok = [self sendMessage:m size:size wait:NO];
  free(m);
  return ok;
}

- (BOOL)typeText:(NSString *)text error:(NSError **)error {
  if (!_keyboardFn) { if (error) *error = WNDMakeError(11, @"Keyboard HID unavailable"); return NO; }
  for (NSUInteger i = 0; i < text.length; i++) {
    unichar c = [text characterAtIndex:i];
    int usage; BOOL shift;
    if (!WNDUsageForChar(c, &usage, &shift)) continue;
    if (shift) { [self sendKeyUsage:0xE1 down:YES]; usleep(6 * 1000); }
    [self sendKeyUsage:usage down:YES];
    usleep(9 * 1000);
    [self sendKeyUsage:usage down:NO];
    usleep(5 * 1000);
    if (shift) { [self sendKeyUsage:0xE1 down:NO]; usleep(6 * 1000); }
  }
  if (_lastSendError) { if (error) *error = WNDMakeError(13, _lastSendError); return NO; }
  return YES;
}

- (BOOL)pressKeyUsage:(int)usage error:(NSError **)error {
  if (!_keyboardFn) { if (error) *error = WNDMakeError(11, @"Keyboard HID unavailable"); return NO; }
  if (![self sendKeyUsage:usage down:YES]) { if (error) *error = WNDMakeError(13, _lastSendError); return NO; }
  usleep(9 * 1000);
  if (![self sendKeyUsage:usage down:NO]) { if (error) *error = WNDMakeError(13, _lastSendError); return NO; }
  return YES;
}

#pragma mark - Accessibility

- (nullable NSArray<NSDictionary<NSString *, id> *> *)accessibilityTreeWithError:(NSError **)error {
  if (![[self class] loadFrameworks:error]) return nil;
  __block NSArray *result = nil;
  __block NSError *err = nil;
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  // AXPTranslator delegation must not run on the main queue.
  dispatch_async(_axQueue, ^{
    result = [self walkAccessibilityTree:&err];
    dispatch_semaphore_signal(sem);
  });
  dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
  if (!result && error) *error = err;
  return result;
}

- (nullable NSArray<NSDictionary<NSString *, id> *> *)walkAccessibilityTree:(NSError **)error {
  WNDAXDispatcher *disp = [WNDAXDispatcher shared];
  id translator = [disp translator];
  if (!translator) {
    if (error) *error = WNDMakeError(20, @"AXPTranslator unavailable");
    return nil;
  }
  NSString *token = [NSUUID UUID].UUIDString;
  [disp registerToken:token device:_device];

  id root = [(id<WNDAXPTranslator>)translator frontmostApplicationWithDisplayId:0 bridgeDelegateToken:token];
  if (!root) {
    [disp unregisterToken:token];
    if (error) *error = WNDMakeError(21, @"No frontmost application (accessibility)");
    return nil;
  }
  [(id<WNDAXPTranslationObject>)root setBridgeDelegateToken:token];

  id element = [(id<WNDAXPTranslator>)translator macPlatformElementFromTranslation:root];
  if (!element) {
    [disp unregisterToken:token];
    if (error) *error = WNDMakeError(22, @"Could not translate frontmost element");
    return nil;
  }
  id tr = [(id<WNDAXPElement>)element translation];
  if (tr) [(id<WNDAXPTranslationObject>)tr setBridgeDelegateToken:token];

  // SpringBoard remediation: a zero-frame root indicates a stale accessibility
  // server (common on long-lived iOS 26 sims). Retry once with a fresh token.
  if (CGRectEqualToRect([(id<NSAccessibility>)element accessibilityFrame], CGRectZero)) {
    [disp unregisterToken:token];
    usleep(400 * 1000);
    NSString *t2 = [NSUUID UUID].UUIDString;
    [disp registerToken:t2 device:_device];
    id root2 = [(id<WNDAXPTranslator>)translator frontmostApplicationWithDisplayId:0 bridgeDelegateToken:t2];
    if (root2) {
      [(id<WNDAXPTranslationObject>)root2 setBridgeDelegateToken:t2];
      id el2 = [(id<WNDAXPTranslator>)translator macPlatformElementFromTranslation:root2];
      if (el2) {
        id tr2 = [(id<WNDAXPElement>)el2 translation];
        if (tr2) [(id<WNDAXPTranslationObject>)tr2 setBridgeDelegateToken:t2];
        element = el2; token = t2;
      }
    }
  }

  NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
  [self serializeElement:element token:token depth:0 into:out];
  [disp unregisterToken:token];
  return out;
}

#pragma mark - Set value (universal text)

- (BOOL)setAccessibilityValue:(NSString *)value forIdentifier:(NSString *)identifier label:(NSString *)label error:(NSError **)error {
  if (![[self class] loadFrameworks:error]) return NO;
  __block BOOL ok = NO;
  __block NSError *err = nil;
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  dispatch_async(_axQueue, ^{
    WNDAXDispatcher *disp = [WNDAXDispatcher shared];
    id translator = [disp translator];
    if (!translator) { err = WNDMakeError(20, @"AXPTranslator unavailable"); dispatch_semaphore_signal(sem); return; }
    NSString *token = [NSUUID UUID].UUIDString;
    [disp registerToken:token device:self->_device];
    id root = [(id<WNDAXPTranslator>)translator frontmostApplicationWithDisplayId:0 bridgeDelegateToken:token];
    if (root) {
      [(id<WNDAXPTranslationObject>)root setBridgeDelegateToken:token];
      id element = [(id<WNDAXPTranslator>)translator macPlatformElementFromTranslation:root];
      if (element) {
        id tr = [(id<WNDAXPElement>)element translation];
        if (tr) [(id<WNDAXPTranslationObject>)tr setBridgeDelegateToken:token];
        id match = [self findElement:element token:token identifier:identifier label:label depth:0];
        if (match) {
          [(id<WNDAXPElement>)match setAccessibilityValue:value];
          ok = YES;
        } else {
          err = WNDMakeError(23, @"element not found for setValue");
        }
      }
    }
    [disp unregisterToken:token];
    dispatch_semaphore_signal(sem);
  });
  dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
  if (!ok && error) *error = err;
  return ok;
}

- (id)findElement:(id)element token:(NSString *)token identifier:(NSString *)identifier label:(NSString *)label depth:(int)depth {
  if (depth > 60) return nil;
  id<NSAccessibility> ax = (id<NSAccessibility>)element;
  id tr = [(id<WNDAXPElement>)element translation];
  if (tr) [(id<WNDAXPTranslationObject>)tr setBridgeDelegateToken:token];
  NSString *eid = [ax accessibilityIdentifier];
  NSString *elabel = [ax accessibilityLabel];
  if ((identifier && eid && [eid isEqualToString:identifier]) ||
      (label && elabel && [elabel isEqualToString:label])) {
    return element;
  }
  for (id child in [ax accessibilityChildren]) {
    id m = [self findElement:child token:token identifier:identifier label:label depth:depth + 1];
    if (m) return m;
  }
  return nil;
}

#pragma mark - Screenshot + OCR (works without app accessibility)

// Copy the current framebuffer as a CGImage (caller releases). NULL on failure.
- (CGImageRef)copyScreenCGImage CF_RETURNS_RETAINED {
  id ioClient = [_device io];
  if (!ioClient) return NULL;
  NSArray *ports = nil;
  @try { ports = [(id<WNDIOClient>)ioClient ioPorts]; } @catch (__unused id e) { return NULL; }
  IOSurfaceRef surface = NULL;
  for (id port in ports) {
    id desc = nil;
    if ([port respondsToSelector:@selector(descriptor)]) {
      @try { desc = [(id<WNDIOPort>)port descriptor]; } @catch (__unused id e) {}
    }
    if (!desc) continue;
    if ([desc respondsToSelector:@selector(framebufferSurface)]) {
      @try { surface = [(id<WNDDisplaySurface>)desc framebufferSurface]; } @catch (__unused id e) {}
    }
    if (!surface && [desc respondsToSelector:@selector(ioSurface)]) {
      @try { surface = [(id<WNDDisplaySurface>)desc ioSurface]; } @catch (__unused id e) {}
    }
    if (surface) break;
  }
  if (!surface) return NULL;
  IOSurfaceIncrementUseCount(surface);
  CIImage *ci = [CIImage imageWithIOSurface:surface];
  CGImageRef cg = NULL;
  if (ci) {
    static CIContext *ctx;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ ctx = [CIContext contextWithOptions:nil]; });
    cg = [ctx createCGImage:ci fromRect:ci.extent];
  }
  IOSurfaceDecrementUseCount(surface);
  return cg;
}

- (uint64_t)screenFingerprint {
  CGImageRef image = [self copyScreenCGImage];
  if (!image) return 0;
  uint8_t pixels[64 * 64] = {0};
  CGColorSpaceRef space = CGColorSpaceCreateDeviceGray();
  CGContextRef context = CGBitmapContextCreate(pixels, 64, 64, 8, 64, space, kCGImageAlphaNone);
  CGColorSpaceRelease(space);
  if (!context) { CGImageRelease(image); return 0; }
  CGContextDrawImage(context, CGRectMake(0, 0, 64, 64), image);
  CGContextRelease(context);
  CGImageRelease(image);
  uint64_t signature = 14695981039346656037ULL;
  for (size_t i = 0; i < sizeof(pixels); i++) {
    signature ^= pixels[i] & 0xf0;
    signature *= 1099511628211ULL;
  }
  return signature;
}

- (BOOL)screenshotToPath:(NSString *)path error:(NSError **)error {
  CGImageRef cg = [self copyScreenCGImage];
  if (!cg) { if (error) *error = WNDMakeError(30, @"could not capture framebuffer"); return NO; }
  NSURL *url = [NSURL fileURLWithPath:path];
  CGImageDestinationRef dest = CGImageDestinationCreateWithURL((__bridge CFURLRef)url, (__bridge CFStringRef)@"public.png", 1, NULL);
  BOOL ok = NO;
  if (dest) {
    CGImageDestinationAddImage(dest, cg, NULL);
    ok = CGImageDestinationFinalize(dest);
    CFRelease(dest);
  }
  CGImageRelease(cg);
  if (!ok && error) *error = WNDMakeError(31, @"could not write PNG");
  return ok;
}

- (nullable NSArray<NSDictionary<NSString *, id> *> *)recognizeTextWithError:(NSError **)error {
  CGImageRef cg = [self copyScreenCGImage];
  if (!cg) { if (error) *error = WNDMakeError(30, @"could not capture framebuffer"); return nil; }
  VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCGImage:cg options:@{}];
  VNRecognizeTextRequest *req = [[VNRecognizeTextRequest alloc] init];
  req.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
  req.usesLanguageCorrection = YES;
  NSError *e = nil;
  BOOL ran = [handler performRequests:@[req] error:&e];
  CGImageRelease(cg);
  if (!ran) { if (error) *error = e ?: WNDMakeError(32, @"OCR failed"); return nil; }

  double W = _screenPointSize.width, H = _screenPointSize.height;
  NSMutableArray *out = [NSMutableArray array];
  for (VNRecognizedTextObservation *obs in req.results) {
    VNRecognizedText *t = [[obs topCandidates:1] firstObject];
    if (!t || t.string.length == 0) continue;
    CGRect bb = obs.boundingBox; // normalized, bottom-left origin
    double x = bb.origin.x * W;
    double y = (1.0 - bb.origin.y - bb.size.height) * H; // flip to top-left
    [out addObject:@{
      @"text": t.string,
      @"x": @(x), @"y": @(y),
      @"w": @(bb.size.width * W), @"h": @(bb.size.height * H),
      @"conf": @(t.confidence),
    }];
  }
  return out;
}

- (void)serializeElement:(id)element token:(NSString *)token depth:(int)depth into:(NSMutableArray *)out {
  if (depth > 60 || out.count > 3000) return;
  id<NSAccessibility> ax = (id<NSAccessibility>)element;
  id<WNDAXPElement> axp = (id<WNDAXPElement>)element;

  id tr = [axp translation];
  if (tr) [(id<WNDAXPTranslationObject>)tr setBridgeDelegateToken:token];

  NSRect frame = [ax accessibilityFrame];
  NSString *role = [ax accessibilityRole];
  NSString *label = [ax accessibilityLabel];
  NSString *ident = [ax accessibilityIdentifier];
  id valueObj = [ax accessibilityValue];
  NSString *value = nil;
  if ([valueObj isKindOfClass:NSString.class]) value = valueObj;
  else if ([valueObj isKindOfClass:NSNumber.class]) value = [valueObj stringValue];

  BOOL enabled = YES;
  @try { enabled = [ax isAccessibilityEnabled]; } @catch (__unused id e) {}

  uint64_t traits = 0;
  id traitsVal = [axp accessibilityAttributeValue:@"AXTraits"];
  if ([traitsVal isKindOfClass:NSNumber.class]) traits = [traitsVal unsignedLongLongValue];

  NSMutableDictionary *d = [NSMutableDictionary dictionary];
  d[@"role"] = role ?: @"";
  if (label.length) d[@"label"] = label;
  if (ident.length) d[@"id"] = ident;
  if (value.length) d[@"value"] = value;
  d[@"x"] = @(frame.origin.x);
  d[@"y"] = @(frame.origin.y);
  d[@"w"] = @(frame.size.width);
  d[@"h"] = @(frame.size.height);
  d[@"enabled"] = @(enabled);
  d[@"traits"] = @(traits);
  d[@"depth"] = @(depth);
  [out addObject:d];

  NSArray *children = [ax accessibilityChildren];
  for (id child in children) {
    [self serializeElement:child token:token depth:depth + 1 into:out];
  }
}

+ (NSString *)layoutDescription {
  NSError *error = nil;
  if (![self loadFrameworks:&error]) return error.localizedDescription;
  WNDMouseEventFn builder = (WNDMouseEventFn)dlsym(gSKHandle, "IndigoHIDMessageForMouseNSEvent");
  if (!builder) return @"native touch builder unavailable";
  CGPoint point = CGPointMake(0.25, 0.75);
  WNDIndigoMessage *message = builder(&point, NULL, 0x32, 1, 0, 1.0, 1.0);
  size_t size = WNDMessageSize(message);
  NSString *description = [NSString stringWithFormat:@"Native Indigo: payload=0x%x count=%u touchMsg=0x%zx (%@)",
    message ? message->innerSize : 0, message ? message->eventType : 0, size, size ? @"OK" : @"unsupported"];
  free(message);
  return description;
}

+ (nullable NSString *)wireFormatError {
  if (getenv("WAND_FORCE_UNSUPPORTED")) return @"forced unsupported build (WAND_FORCE_UNSUPPORTED set) — test of the fail-loud guard.";
  NSString *layout = [self layoutDescription];
  if ([layout hasSuffix:@"(OK)"]) return nil;
  return [@"unsupported native SimulatorKit HID format: " stringByAppendingString:layout];
}

- (nullable NSString *)readinessError {
  if (!_hidClient && !_guestSender) return @"HID client unavailable (SimDeviceLegacyHIDClient failed to init) — cannot inject input.";
  if (!_mouseFn)   return @"required symbol IndigoHIDMessageForMouseNSEvent not found in SimulatorKit — incompatible Xcode build.";
  if (!_keyboardFn) return @"required symbol IndigoHIDMessageForKeyboardArbitrary not found in SimulatorKit — incompatible Xcode build.";
  return nil;  // crown symbol is optional (watchOS-only; guarded at call site)
}

- (nullable NSString *)lastSendError { return _lastSendError; }
- (void)clearLastSendError { _lastSendError = nil; }

@end
