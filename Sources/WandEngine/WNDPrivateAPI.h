// WNDPrivateAPI.h
// Declarations of the private Apple classes/methods we message dynamically.
//
// We never link these symbols. Classes are obtained via objc_getClass /
// objc_lookUpClass after dlopen, and messaged through these protocols (class
// methods are declared as instance methods so we can message the Class object
// after casting it to id<...>). This is the standard pattern for driving
// CoreSimulator without linking the private framework.
#ifndef WND_PRIVATE_API_H
#define WND_PRIVATE_API_H

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOSurface/IOSurface.h>

NS_ASSUME_NONNULL_BEGIN

// +[SimServiceContext sharedServiceContextForDeveloperDir:error:]
@protocol WNDServiceContextClass <NSObject>
- (nullable id)sharedServiceContextForDeveloperDir:(NSString *)developerDir error:(NSError **)error;
@end

// SimServiceContext instance
@protocol WNDServiceContext <NSObject>
- (nullable id)defaultDeviceSetWithError:(NSError **)error;
@end

// SimDeviceSet
@protocol WNDDeviceSet <NSObject>
- (NSArray *)devices;
@end

// SimDeviceType
@protocol WNDDeviceType <NSObject>
- (CGSize)mainScreenSize;   // pixels
- (float)mainScreenScale;   // 2.0 / 3.0
- (NSString *)identifier;   // e.g. com.apple.CoreSimulator.SimDeviceType.Apple-Watch-…
@end

// SimDevice
@protocol WNDSimDevice <NSObject>
- (NSUUID *)UDID;
- (NSString *)name;
- (unsigned long long)state;          // 3 == Booted
- (id)deviceType;                     // id<WNDDeviceType>
- (id)io;                             // SimDeviceIOClient
- (void)sendAccessibilityRequestAsync:(id)request
                       completionQueue:(dispatch_queue_t)queue
                     completionHandler:(void (^)(id _Nullable response))handler;
@end

// SimDeviceIOClient
@protocol WNDIOClient <NSObject>
- (NSArray *)ioPorts;
@end

// SimDeviceIOPortInterface
@protocol WNDIOPort <NSObject>
- (nullable id)descriptor;
@end

// SimDisplayIOSurfaceRenderable — the main-display framebuffer surface provider.
@protocol WNDDisplaySurface <NSObject>
- (nullable IOSurfaceRef)framebufferSurface;
- (nullable IOSurfaceRef)ioSurface;
@end

// SimulatorKit.SimDeviceLegacyHIDClient
@protocol WNDLegacyHIDClient <NSObject>
- (nullable instancetype)initWithDevice:(id)device error:(NSError **)error;
- (void)sendWithMessage:(void *)message
            freeWhenDone:(BOOL)freeWhenDone
         completionQueue:(dispatch_queue_t)queue
              completion:(void (^)(NSError *_Nullable error))completion;
@end

// --- AccessibilityPlatformTranslation ---

// +[AXPTranslator sharedInstance]
@protocol WNDAXPTranslatorClass <NSObject>
- (id)sharedInstance;
@end

// AXPTranslator (process-wide singleton). bridgeTokenDelegate routes per-token
// callbacks to the right simulator.
@protocol WNDAXPTranslator <NSObject>
- (void)setBridgeTokenDelegate:(id)delegate;
- (nullable id)frontmostApplicationWithDisplayId:(unsigned int)displayId bridgeDelegateToken:(NSString *)token;
- (nullable id)objectAtPoint:(CGPoint)point displayId:(unsigned int)displayId bridgeDelegateToken:(NSString *)token;
- (nullable id)macPlatformElementFromTranslation:(id)translation;
@end

// +[AXPTranslatorResponse emptyResponse]
@protocol WNDAXPResponseClass <NSObject>
- (id)emptyResponse;
@end

// AXPTranslationObject
@protocol WNDAXPTranslationObject <NSObject>
- (void)setBridgeDelegateToken:(NSString *)token;
- (nullable NSString *)bridgeDelegateToken;
- (int)pid;
@end

// AXPMacPlatformElement (NSAccessibilityElement subclass). NSAccessibility
// properties (accessibilityLabel/Role/Frame/...) come from AppKit; here we only
// declare the AXP-specific members we message directly.
@protocol WNDAXPElement <NSObject>
- (nullable id)translation;
- (nullable id)accessibilityAttributeValue:(id)attribute;
- (NSArray<NSString *> *)accessibilityActionNames;
- (BOOL)accessibilityPerformPress;
- (void)setAccessibilityValue:(nullable id)value;
@end

NS_ASSUME_NONNULL_END

#endif // WND_PRIVATE_API_H
