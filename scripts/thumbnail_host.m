//
//  thumbnail_host.m — render ONE frame of the built saver to a PNG (Objective-C)
//  Module maturity: PROTOTYPE (slice GS-2, deliverable 7)
//
//  Invoked by scripts/build.sh to bake Contents/Resources/thumbnail.png(@2x):
//  the System Settings grid shows a static bundle asset (GS-1 field finding), so
//  the tile must be a real, brand-true frame of the saver, not a placeholder.
//
//  Same in-process load path as scripts/verify_host.m (the engine's exact
//  dyld/class/init route) — NSBundle(path:) the just-built bundle, resolve the
//  principal ScreenSaverView subclass, instantiate via -initWithFrame:isPreview:,
//  and render through the view's own @objc verification seam
//  (-renderVerificationFrameAtTime:). NO ScreenSaverEngine, NO `screencapture`,
//  NO `metal` tool. Differs from verify_host only in writing a SINGLE frame at a
//  caller-chosen time (the proverb is settled ink, on-screen at every time).
//
//  usage: thumbnail_host <built-saver-bundle> <out.png> <time-seconds>
//  Exit nonzero on any failure so build.sh (set -e) aborts.
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <ScreenSaver/ScreenSaver.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>

@interface NSObject (GlyphSaverVerify)
- (CGImageRef)renderVerificationFrameAtTime:(double)t;
@end

static int fail(NSString *msg) {
    fprintf(stderr, "THUMBNAIL FAILED: %s\n", msg.UTF8String);
    return 1;
}

static BOOL writePNG(CGImageRef img, NSString *path) {
    if (img == NULL) return NO;
    NSURL *url = [NSURL fileURLWithPath:path];
    CGImageDestinationRef dest = CGImageDestinationCreateWithURL(
        (__bridge CFURLRef)url, (__bridge CFStringRef)@"public.png", 1, NULL);
    if (dest == NULL) return NO;
    CGImageDestinationAddImage(dest, img, NULL);
    BOOL ok = CGImageDestinationFinalize(dest);
    CFRelease(dest);
    return ok;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 4) {
            fprintf(stderr, "usage: %s <saver-bundle> <out.png> <time-seconds>\n", argv[0]);
            return 2;
        }
        NSString *bundlePath = [NSString stringWithUTF8String:argv[1]];
        NSString *outPath = [NSString stringWithUTF8String:argv[2]];
        double t = atof(argv[3]);

        // NSView creation touches AppKit; give it a shared app (loop never runs).
        [NSApplication sharedApplication];

        NSBundle *bundle = [NSBundle bundleWithPath:bundlePath];
        if (bundle == nil)
            return fail([NSString stringWithFormat:@"NSBundle(path:) nil for %@", bundlePath]);
        NSError *err = nil;
        if (![bundle loadAndReturnError:&err])
            return fail([NSString stringWithFormat:@"bundle load failed: %@", err]);
        Class principal = bundle.principalClass;
        if (principal == Nil)
            return fail(@"principalClass is nil (NSPrincipalClass unresolved)");
        if (![principal isSubclassOfClass:[ScreenSaverView class]])
            return fail([NSString stringWithFormat:@"principalClass %@ is not a ScreenSaverView subclass",
                         NSStringFromClass(principal)]);

        NSRect frame = NSMakeRect(0, 0, 1280, 800);
        ScreenSaverView *view = [[principal alloc] initWithFrame:frame isPreview:NO];
        if (view == nil)
            return fail(@"-initWithFrame:isPreview: returned nil");
        if (![view respondsToSelector:@selector(renderVerificationFrameAtTime:)])
            return fail(@"view does not respond to renderVerificationFrameAtTime:");

        CGImageRef img = [view renderVerificationFrameAtTime:t];
        if (img == NULL) return fail(@"frame render returned NULL");
        if (!writePNG(img, outPath))
            return fail([NSString stringWithFormat:@"writing %@ failed", outPath]);

        fprintf(stdout, "THUMBNAIL OK: wrote %s (t=%.2fs) via %s\n",
                outPath.UTF8String, t, NSStringFromClass(principal).UTF8String);
        return 0;
    }
}
