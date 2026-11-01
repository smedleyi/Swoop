#import <AppKit/AppKit.h>

/// Reads a touch's position. Returns NO when the getter throws, which it does for
/// some valid touches, such as ones Universal Control forwards from another Mac.
BOOL SwoopTouchPosition(NSTouch *touch, NSPoint *position);
