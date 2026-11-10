#import <Foundation/Foundation.h>
#import "../Sources/WandEngine/WNDDisplayGeometry.h"
#import "../Sources/WandEngine/WNDDisplayInfo.m"
#include <assert.h>
@interface WNDDisplayInfo (TestDecode)
- (NSDictionary *)decode:(xpc_object_t)reply;
@end
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
  puts("PASS: four orientations; valid panel geometry; malformed/inactive/ambiguous displays refuse targeting");
}}
