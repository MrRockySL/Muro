// Remote Core Animation context declaration used by WallpaperAgent.
// This private runtime surface is loaded dynamically on macOS 26+.

#import <Foundation/Foundation.h>
#import <QuartzCore/QuartzCore.h>

@interface CAContext : NSObject
@property (readonly) unsigned int contextId;
@property (retain) CALayer *layer;
+ (id)remoteContext;
+ (id)remoteContextWithOptions:(id)options;
@end
