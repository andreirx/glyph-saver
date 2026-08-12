//
//  main.swift — PreviewApp: the saver view in an NSWindow for live watching
//  Module maturity: PROTOTYPE (slice GS-2)
//
//  Dev tool ONLY (docs/PLAN.md "Test hosts"). NOT shipped in the .saver bundle,
//  NOT acceptance evidence — the gates are `swift test`, build.sh, verify.sh.
//  It exists so a human can watch the SAME GlyphSaverView + ZapRenderer render
//  live, at a resizable window, without going through System Settings.
//
//  Built by scripts/preview.sh, which compiles Sources/Saver + Sources/GlyphCore
//  + this file into one executable and copies the bundle resources (Shaders.metal,
//  textures, JSONs) next to the binary. GlyphSaverView loads resources via
//  Bundle(for:) → Bundle.main → the executable's directory, so the loose
//  resources are found exactly as they would be inside the bundle.
//
//  We drive animateOneFrame ourselves on a Timer (30 fps) rather than relying on
//  ScreenSaverView.startAnimation, which is meant for the screensaver engine.
//

import AppKit

let app = NSApplication.shared
app.setActivationPolicy(.regular)

let frame = NSRect(x: 0, y: 0, width: 1280, height: 800)

let window = NSWindow(contentRect: frame,
                      styleMask: [.titled, .closable, .miniaturizable, .resizable],
                      backing: .buffered,
                      defer: false)
window.title = "Glyph Saver — Preview (dev tool, not shipped)"

guard let view = GlyphSaverView(frame: frame, isPreview: false) else {
    FileHandle.standardError.write(Data("PreviewApp: GlyphSaverView init failed\n".utf8))
    exit(1)
}
window.contentView = view
window.center()
window.makeKeyAndOrderFront(nil)

// 30 fps, matching the saver's animationTimeInterval.
let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { _ in
    view.animateOneFrame()
}
RunLoop.main.add(timer, forMode: .common)

app.activate(ignoringOtherApps: true)
app.run()
