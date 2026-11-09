// WandEngine.h — public surface consumed by Swift.
//
// A WNDSimulator wraps a booted iOS Simulator (SimDevice) and exposes
// HID injection. Coordinates are in POINTS (the same space as accessibility
// frames), origin top-left.
#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface WNDSimulator : NSObject

@property (nonatomic, readonly) NSString *udid;
@property (nonatomic, readonly) NSString *name;
@property (nonatomic, readonly) CGSize screenPointSize; // logical points
@property (nonatomic, readonly) BOOL isWatch;
@property (nonatomic, readonly) CGFloat screenScale;    // 2.0 / 3.0

/// First booted simulator, or nil with error if none / framework load failed.
+ (nullable instancetype)bootedSimulatorWithError:(NSError **)error;

/// Specific simulator by UDID (must be booted).
+ (nullable instancetype)simulatorWithUDID:(nullable NSString *)udid error:(NSError **)error
    NS_SWIFT_NAME(withUDID(_:));

/// Optional guest digitizer transport for watchOS 27. Native crown/keyboard
/// events continue through SimulatorKit's legacy client.
- (void)setGuestTouchSender:(NSString * _Nullable (^ _Nonnull)(NSData *))sender;

// --- HID gestures (points, top-left origin) ---

- (BOOL)tapAtX:(double)x y:(double)y error:(NSError **)error
    NS_SWIFT_NAME(tap(x:y:));

- (BOOL)longPressAtX:(double)x y:(double)y duration:(double)seconds error:(NSError **)error
    NS_SWIFT_NAME(longPress(x:y:duration:));

/// Linear swipe/scroll from (x1,y1) to (x2,y2) over `duration` seconds.
- (BOOL)swipeFromX:(double)x1 y:(double)y1
               toX:(double)x2 y:(double)y2
          duration:(double)duration
             error:(NSError **)error
    NS_SWIFT_NAME(swipe(x1:y1:x2:y2:duration:));

/// Drag-and-drop: press, hold for `holdDuration` (pickup), move to target, release.
- (BOOL)dragFromX:(double)x1 y:(double)y1
              toX:(double)x2 y:(double)y2
      holdDuration:(double)holdDuration
     moveDuration:(double)moveDuration
            error:(NSError **)error
    NS_SWIFT_NAME(drag(x1:y1:x2:y2:hold:move:));

/// Whether the bound simulator is still booted (re-reads device state).
- (BOOL)isBooted;

/// Type a string via the hardware keyboard (the focused field receives it).
- (BOOL)typeText:(NSString *)text error:(NSError **)error NS_SWIFT_NAME(type(_:));

/// Press a single HID usage key (e.g. 0x2A backspace, 0x28 return).
- (BOOL)pressKeyUsage:(int)usage error:(NSError **)error NS_SWIFT_NAME(pressKey(usage:));

/// Pinch at center (x,y). scale>1 zooms in, scale<1 zooms out.
- (BOOL)pinchAtX:(double)x y:(double)y scale:(double)scale duration:(double)duration error:(NSError **)error
    NS_SWIFT_NAME(pinch(x:y:scale:duration:));

/// Two-finger rotation at center (x,y) by `radians` (positive = clockwise).
- (BOOL)rotateAtX:(double)x y:(double)y radians:(double)radians duration:(double)duration error:(NSError **)error
    NS_SWIFT_NAME(rotate(x:y:radians:duration:));

/// watchOS Digital Crown. `delta` is the total rotation (sign = direction);
/// it is emitted as `steps` incremental HID events over `duration` seconds to
/// mimic a physical turn. Only available on watchOS simulators.
- (BOOL)turnCrownBy:(double)delta steps:(NSUInteger)steps duration:(double)duration error:(NSError **)error
    NS_SWIFT_NAME(turnCrown(by:steps:duration:));

/// Flattened accessibility tree of the frontmost app. Each element dict has:
/// role, label, id, value, x, y, w, h, enabled, traits, depth.
- (nullable NSArray<NSDictionary<NSString *, id> *> *)accessibilityTreeWithError:(NSError **)error
    NS_SWIFT_NAME(accessibilityTree());

/// Coarse framebuffer signature for settling when watchOS exposes only an app AX node.
- (uint64_t)screenFingerprint;

/// In-process screenshot (framebuffer IOSurface -> PNG). No subprocess.
- (BOOL)screenshotToPath:(NSString *)path error:(NSError **)error
    NS_SWIFT_NAME(screenshot(toPath:));

/// On-device OCR (Apple Vision) of the current screen. Each dict: text, x, y, w,
/// h (points, top-left), conf. Works on ANY app — no accessibility needed.
- (nullable NSArray<NSDictionary<NSString *, id> *> *)recognizeTextWithError:(NSError **)error
    NS_SWIFT_NAME(recognizeText());

/// Set a field's value directly (any unicode) by matching its identifier/label.
- (BOOL)setAccessibilityValue:(NSString *)value
                forIdentifier:(nullable NSString *)identifier
                        label:(nullable NSString *)label
                        error:(NSError **)error
    NS_SWIFT_NAME(setValue(_:identifier:label:));

/// Diagnostic: verifies the Indigo struct layout matches the wire format.
+ (NSString *)layoutDescription;

/// nil if the Indigo wire-format struct sizes match what wand was built against;
/// otherwise a clear message. A mismatch means the host Xcode's SimulatorKit
/// differs and injecting would send wrong bytes — callers MUST refuse to inject.
+ (nullable NSString *)wireFormatError;

/// nil if this simulator is ready to inject input; otherwise a clear reason
/// (HID client missing, required SimulatorKit symbol absent, …).
- (nullable NSString *)readinessError;

/// The last HID send completion error (e.g. a dropped/disconnected session),
/// or nil if the last send succeeded. Cleared by `clearLastSendError`.
- (nullable NSString *)lastSendError;
- (void)clearLastSendError;

@end

NS_ASSUME_NONNULL_END
