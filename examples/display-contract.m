#import <Foundation/Foundation.h>
#import "../Sources/WandEngine/WNDDisplayGeometry.h"
#import "../Sources/WandEngine/WNDDisplayInfo.m"
#include <assert.h>
@interface WNDDisplayInfo (TestDecode)
- (NSDictionary *)decode:(xpc_object_t)reply;
@end
@interface TestProperties : NSObject
@property unsigned int uiOrientation, screenID;
@end
@implementation TestProperties @end
@interface TestScreen : NSObject
@property(nonatomic, strong) id screenProperties;
@property CGSize displaySize;
@end
@implementation TestScreen @end
@interface StalledScreen : TestScreen
@property(nonatomic, strong) dispatch_semaphore_t releaseRead;
@property(atomic) NSUInteger reads;
@end
@implementation StalledScreen
- (id)screenProperties {
  self.reads += 1;
  if (self.reads == 1) dispatch_semaphore_wait(self.releaseRead, DISPATCH_TIME_FOREVER);
  return [super screenProperties];
}
@end
@interface TestPort : NSObject
@property(nonatomic, strong) id descriptor;
@end
@implementation TestPort @end
@interface TestIO : NSObject
@property(nonatomic, strong) NSArray *ioPorts;
@end
@implementation TestIO @end
@interface TestDeviceType : NSObject
@property CGSize mainScreenSize;
@property float mainScreenScale;
@end
@implementation TestDeviceType @end
@interface TestDevice : NSObject
@property(nonatomic, strong) id io, deviceType;
@end
@implementation TestDevice @end
static void point(CGPoint p, double x, double y) { assert(fabs(p.x-x)<0.0001 && fabs(p.y-y)<0.0001); }
int main(void) { @autoreleasepool {
  CGSize panel=CGSizeMake(100,200);
  point(WNDPanelPoint(CGPointMake(20,30),panel,1),20,30);
  point(WNDPanelPoint(CGPointMake(20,30),panel,3),80,170);
  point(WNDPanelPoint(CGPointMake(20,30),panel,6),30,180);
  point(WNDPanelPoint(CGPointMake(20,30),panel,8),70,20);
  assert(CGSizeEqualToSize(WNDOrientedSize(panel,6),CGSizeMake(200,100)));
  assert(CGSizeEqualToSize(WNDOrientedSize(panel,8),CGSizeMake(200,100)));
  assert(CGSizeEqualToSize(WNDOrientedSize(panel,3),panel));
  WNDDisplayInfo *reader=[[WNDDisplayInfo alloc] initWithDevice:(id)[NSObject new]];
  assert([reader decode:nil]==nil);
  xpc_object_t reply=xpc_dictionary_create(NULL,NULL,0);
  assert([reader decode:reply]==nil);
  xpc_object_t output=xpc_dictionary_create(NULL,NULL,0);
  xpc_dictionary_set_value(reply,"CoreDevice.output",output);
  xpc_dictionary_set_bool(output,"current",true);
  xpc_object_t displays=xpc_array_create(NULL,0);
  xpc_dictionary_set_value(output,"displays",displays);
  assert([reader decode:reply]==nil);
  xpc_object_t item=xpc_dictionary_create(NULL,NULL,0), type=xpc_dictionary_create(NULL,NULL,0);
  xpc_dictionary_set_value(type,"integrated",xpc_dictionary_create(NULL,NULL,0));
  xpc_dictionary_set_value(item,"type",type);
  xpc_dictionary_set_bool(item,"active",true);
  xpc_dictionary_set_int64(item,"pointScale",2);
  xpc_object_t origin=xpc_array_create(NULL,0), size=xpc_array_create(NULL,0), bounds=xpc_array_create(NULL,0);
  xpc_array_append_value(origin,xpc_double_create(0)); xpc_array_append_value(origin,xpc_double_create(0));
  xpc_array_append_value(size,xpc_double_create(1512)); xpc_array_append_value(size,xpc_double_create(2316));
  xpc_array_append_value(bounds,origin); xpc_array_append_value(bounds,size);
  xpc_dictionary_set_value(item,"bounds",bounds); xpc_array_append_value(displays,item);
  NSDictionary *rotations=@{@"rot0":@1,@"rot90":@6,@"rot180":@3,@"rot270":@8};
  for (NSString *rotation in rotations) {
    xpc_dictionary_set_string(item,"currentOrientation",rotation.UTF8String);
    NSDictionary *decoded=[reader decode:reply];
    assert([decoded[@"exif"] isEqual:rotations[rotation]]);
    assert([decoded[@"width"] doubleValue]==1512 && [decoded[@"height"] doubleValue]==2316);
    assert([decoded[@"scale"] intValue]==2);
  }
  xpc_dictionary_set_string(item,"currentOrientation","unknown"); assert([reader decode:reply]==nil);
  xpc_dictionary_set_string(item,"currentOrientation","rot0");
  xpc_dictionary_set_bool(item,"active",false); assert([reader decode:reply]==nil);
  xpc_dictionary_set_string(item,"active","true"); assert([reader decode:reply]==nil);
  xpc_dictionary_set_bool(item,"active",true);
  xpc_dictionary_set_int64(item,"pointScale",0); assert([reader decode:reply]==nil);
  xpc_dictionary_set_int64(item,"pointScale",2);
  xpc_array_set_value(size,0,xpc_double_create(NAN)); assert([reader decode:reply]==nil);
  xpc_array_set_value(size,0,xpc_string_create("1512")); assert([reader decode:reply]==nil);
  xpc_array_set_value(size,0,xpc_double_create(1512));
  assert([reader decode:reply]!=nil);
  xpc_array_append_value(displays,item); assert([reader decode:reply]==nil);
  TestProperties *properties=[TestProperties new];
  properties.screenID=1; // A screen identity is not a zero-based HID panel index.
  TestScreen *screen=[TestScreen new]; screen.screenProperties=properties;
  screen.displaySize=CGSizeMake(1200,2600);
  TestPort *port=[TestPort new]; port.descriptor=screen;
  TestIO *io=[TestIO new]; io.ioPorts=@[port];
  TestDeviceType *typeInfo=[TestDeviceType new]; typeInfo.mainScreenSize=CGSizeMake(1200,2600); typeInfo.mainScreenScale=3;
  TestDevice *device=[TestDevice new]; device.io=io; device.deviceType=typeInfo;
  WNDDisplayInfo *legacy=[[WNDDisplayInfo alloc] initWithDevice:(id)device];
  NSArray *expected=@[@1,@3,@6,@8];
  for (unsigned int orientation=1;orientation<=4;orientation++) {
    properties.uiOrientation=orientation;
    NSDictionary *decoded=[legacy readLegacyWithError:nil];
    assert([decoded[@"exif"] isEqual:expected[orientation-1]]);
    assert([decoded[@"width"] intValue]==1200 && [decoded[@"scale"] intValue]==3);
  }
  properties.uiOrientation=0; assert([legacy readLegacyWithError:nil]==nil);
  properties.uiOrientation=1; assert([legacy readLegacyWithError:nil]!=nil);
  TestScreen *disconnected=[TestScreen new]; disconnected.screenProperties=properties;
  TestPort *unused=[TestPort new]; unused.descriptor=disconnected;
  io.ioPorts=@[unused,port];
  legacy=[[WNDDisplayInfo alloc] initWithDevice:(id)device];
  assert([legacy readLegacyWithError:nil]!=nil);
  io.ioPorts=@[port,port];
  legacy=[[WNDDisplayInfo alloc] initWithDevice:(id)device];
  assert([legacy readLegacyWithError:nil]==nil);
  StalledScreen *stalled=[StalledScreen new];
  stalled.displaySize=screen.displaySize;
  stalled.releaseRead=dispatch_semaphore_create(0);
  stalled.screenProperties=properties;
  port.descriptor=stalled; io.ioPorts=@[port];
  legacy=[[WNDDisplayInfo alloc] initWithDevice:(id)device];
  double started=NSProcessInfo.processInfo.systemUptime;
  NSError *error=nil;
  assert([legacy readLegacyWithError:&error]==nil);
  assert(NSProcessInfo.processInfo.systemUptime-started < 2);
  assert([error.localizedDescription containsString:@"deadline"]);
  started=NSProcessInfo.processInfo.systemUptime;
  for (int i=0;i<100;i++) assert([legacy readLegacyWithError:nil]==nil);
  assert(NSProcessInfo.processInfo.systemUptime-started < 0.1);
  assert(stalled.reads==1); // No queue of blocked reads on repeated commands.
  dispatch_semaphore_signal(stalled.releaseRead);
  puts("PASS: modern/legacy orientations; valid panel geometry; malformed/inactive/ambiguous displays refuse targeting");
  puts("PASS: stalled legacy read has a bounded deadline and refuses further work");
}}
