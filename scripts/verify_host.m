//
//  verify_host.m — GS-1 loadtest + offscreen frame capture (Objective-C)
//  Module maturity: PROTOTYPE (slice GS-1)
//
//  Invoked by scripts/verify.sh. Two jobs, in one process, on the INSTALLED
//  bundle — the same dyld/class/init path the real ScreenSaverEngine uses:
//
//    (b) LOADTEST:  NSBundle(path:) the installed ~/Library/Screen Savers/
//                   GlyphSaver.saver, load it, resolve `principalClass`,
//                   assert it is a ScreenSaverView subclass, and instantiate it
//                   via -initWithFrame:isPreview: (the engine's exact entry).
//    (c) CAPTURE:   render two frames a few animation-seconds apart THROUGH the
//                   real GlyphSaverView instance (its @objc verification seam,
//                   which uses the view's own renderer/format/size — never the
//                   ZapRenderer directly) and write them as PNGs.
//
//  ObjC (not Swift) on purpose: instantiating a dynamically-loaded class via
//  -initWithFrame:isPreview: (a struct + BOOL initializer that is not `required`
//  on ScreenSaverView) is idiomatic and type-safe here, whereas Swift cannot
//  call a non-`required` init through a runtime-resolved metatype.
//
//  Deliverable 8 forbids ScreenSaverEngine launch and `screencapture`; this
//  host uses neither. Exit nonzero on any failure (verify.sh checks the code).
//

#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <ScreenSaver/ScreenSaver.h>
#import <ImageIO/ImageIO.h>
#import <CoreGraphics/CoreGraphics.h>

// Informal declaration of the verification seam implemented (in Swift) by
// GlyphSaverView. Declared on NSObject so the compiler emits a correctly-typed
// objc_msgSend; guarded at the call site with -respondsToSelector:.
@interface NSObject (GlyphSaverVerify)
- (CGImageRef)renderVerificationFrameAtTime:(double)t;
@end

static int fail(NSString *msg) {
    fprintf(stderr, "VERIFY FAILED: %s\n", msg.UTF8String);
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
            fprintf(stderr, "usage: %s <installed-saver-bundle> <out1.png> <out2.png>\n", argv[0]);
            return 2;
        }
        NSString *bundlePath = [NSString stringWithUTF8String:argv[1]];
        NSString *out1 = [NSString stringWithUTF8String:argv[2]];
        NSString *out2 = [NSString stringWithUTF8String:argv[3]];

        // NSView creation touches AppKit; give it a shared application (we never
        // run the loop). This does not open a window.
        [NSApplication sharedApplication];

        // ---- (b) LOADTEST: bundle → principalClass → initWithFrame:isPreview: ----
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
        fprintf(stdout, "LOADTEST OK: %s instantiated via -initWithFrame:isPreview:\n",
                NSStringFromClass(principal).UTF8String);

        // ---- (c) CAPTURE: two frames a few animation-seconds apart ----
        if (![view respondsToSelector:@selector(renderVerificationFrameAtTime:)])
            return fail(@"view does not respond to renderVerificationFrameAtTime:");

        CGImageRef img1 = [view renderVerificationFrameAtTime:2.0];
        if (img1 == NULL) return fail(@"frame 1 render returned NULL");
        if (!writePNG(img1, out1)) return fail([NSString stringWithFormat:@"writing %@ failed", out1]);

        CGImageRef img2 = [view renderVerificationFrameAtTime:7.0];
        if (img2 == NULL) return fail(@"frame 2 render returned NULL");
        if (!writePNG(img2, out2)) return fail([NSString stringWithFormat:@"writing %@ failed", out2]);

        fprintf(stdout, "RENDER OK: wrote %s and %s (t=2.0s, t=7.0s)\n",
                out1.UTF8String, out2.UTF8String);
        return 0;
    }
}
