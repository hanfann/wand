#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

// EXIF describes panel -> upright interface. Input needs the inverse transform.
static inline CGSize WNDOrientedSize(CGSize panel, NSInteger exif) {
  return exif == 6 || exif == 8 ? CGSizeMake(panel.height, panel.width) : panel;
}
static inline CGPoint WNDPanelPoint(CGPoint point, CGSize panel, NSInteger exif) {
  switch (exif) {
    case 6: return CGPointMake(point.y, panel.height - point.x);
    case 3: return CGPointMake(panel.width - point.x, panel.height - point.y);
    case 8: return CGPointMake(panel.width - point.y, point.x);
    default: return point;
  }
}
