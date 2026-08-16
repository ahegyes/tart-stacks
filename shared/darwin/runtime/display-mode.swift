// display-mode — establish a macOS guest's display mode once, permanently.
//
// A macOS clone boots at Tart's unconfigured 1024x768 and stays there for its
// whole life: under `tart set --display-refit` that mode is not one the display
// even offers, and nothing inside the guest picks another. WindowServer records
// a per-display preference only when a mode is established through a display
// reconfiguration, and `.permanently` is what writes it — after which refit
// tracks the host window on its own. So this runs on a window boot, does its
// work on the first one, and is inert on every boot after.
//
// Delivered from the repo by tart-up rather than baked into the image: a clone
// that already exists gets it without a rebuild, and it version-tracks tart-up
// instead of whatever image the VM happens to descend from. `swift` comes from
// the Command Line Tools on the upstream base image, so a guest without them
// fails here with its own message rather than silently keeping a 4:3 screen.
//
// usage: display-mode <width>x<height>   — the geometry the VM was created with

import CoreGraphics
import Foundation

// Tart's own default virtual display. A guest sitting exactly here has never
// had a mode established; any other mode is one refit or a human chose, and
// taking it over would fight the mechanism this exists to hand off to.
let unconfigured = (width: 1024, height: 768)

func fail(_ message: String, _ code: Int32) -> Never {
    FileHandle.standardError.write(Data("display-mode: \(message)\n".utf8))
    exit(code)
}

let arguments = CommandLine.arguments
guard arguments.count == 2 else { fail("usage: display-mode <width>x<height>", 64) }
let geometry = arguments[1].split(separator: "x")
guard geometry.count == 2,
      let targetWidth = Int(geometry[0]), let targetHeight = Int(geometry[1]),
      targetWidth > 0, targetHeight > 0 else {
    fail("expected a WIDTHxHEIGHT geometry, got '\(arguments[1])'", 64)
}

let display = CGMainDisplayID()
guard let current = CGDisplayCopyDisplayMode(display) else {
    fail("the guest reports no display to configure", 1)
}
guard current.width == unconfigured.width, current.height == unconfigured.height else {
    exit(0)
}

// Retina modes are duplicates of the same sizes at a doubled backing store, so
// the default enumeration hides them; without them the only candidates are 1x
// modes, which render visibly soft on a display the host draws at 2x.
let options = [kCGDisplayShowDuplicateLowResolutionModes as String: kCFBooleanTrue!] as CFDictionary
guard let modes = CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode],
      !modes.isEmpty else {
    fail("the display offers no modes to choose from", 1)
}
let retina = modes.filter { $0.pixelWidth > $0.width }
let candidates = retina.isEmpty ? modes : retina

// Nearest match, not a lookup: under refit the offered modes are sized to the
// host window's CONTENT rect, so the configured geometry is usually absent
// from the list (a 1920x1080 VM is offered 1920x1037). The largest backing
// store breaks a tie, keeping the sharper of two equally close modes.
guard let target = candidates.min(by: { a, b in
    let distanceA = abs(a.width - targetWidth) + abs(a.height - targetHeight)
    let distanceB = abs(b.width - targetWidth) + abs(b.height - targetHeight)
    return distanceA == distanceB ? a.pixelWidth > b.pixelWidth : distanceA < distanceB
}) else {
    fail("no usable display mode", 1)
}

var configuration: CGDisplayConfigRef?
guard CGBeginDisplayConfiguration(&configuration) == .success else {
    fail("could not begin a display reconfiguration", 1)
}
guard CGConfigureDisplayWithDisplayMode(configuration, display, target, nil) == .success else {
    CGCancelDisplayConfiguration(configuration)
    fail("could not select \(target.width)x\(target.height)", 1)
}
let result = CGCompleteDisplayConfiguration(configuration, .permanently)
guard result == .success else {
    fail("could not apply \(target.width)x\(target.height) (CGError \(result.rawValue))", 1)
}
