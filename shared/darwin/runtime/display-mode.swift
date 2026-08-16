// display-mode — establish a macOS guest's display mode once, permanently.
//
// A macOS clone boots at Tart's unconfigured 1024x768 and stays there for its
// whole life: under `tart set --display-refit` that mode is not one the display
// even offers, and nothing inside the guest picks another. WindowServer records
// a per-display preference only when a mode is established through a display
// reconfiguration, and only a permanent one writes it — after which refit
// tracks the host window on its own. So this runs on a window boot, does its
// work on the first one, and is inert on every boot after.
//
// Delivered from the repo by tart-up rather than baked into the image: a clone
// that already exists gets it without a rebuild, and it version-tracks tart-up
// instead of whatever image the VM happens to descend from. `swift` comes from
// the Command Line Tools on the upstream base image, so a guest without them
// fails here with its own message rather than silently keeping a 4:3 screen.
//
// The decision is two pure functions so it can be exercised without a display:
// `swift -DSELFTEST display-mode.swift` runs the fixtures at the foot of this
// file instead of reconfiguring anything. test/display-mode.sh is that caller.
//
// usage: display-mode <width>x<height>   — the geometry the VM was created with

import CoreGraphics
import Foundation

// Tart's own default virtual display, and the whole gate: a guest sitting
// exactly here has never had a mode established.
let unconfiguredWidth = 1024
let unconfiguredHeight = 768

/// A display mode reduced to the numbers the choice depends on, so the choice
/// can be made — and tested — without a CoreGraphics display.
struct Candidate {
    let width: Int
    let height: Int
    let pixelWidth: Int
    let pixelHeight: Int

    var isRetina: Bool { pixelWidth > width }
    var backingArea: Int { pixelWidth * pixelHeight }
}

/// Whether a guest showing `current` needs the mode it was configured for.
///
/// A clone created AT 1024x768 is already showing its configured geometry, so
/// it is left alone; without that, every window boot would drag a deliberate
/// `tart-new --display 1024x768` clone onto some other mode and back.
func needsEstablishing(current: (width: Int, height: Int),
                       configured: (width: Int, height: Int)) -> Bool {
    guard current.width == unconfiguredWidth, current.height == unconfiguredHeight else {
        return false
    }
    return !(configured.width == unconfiguredWidth && configured.height == unconfiguredHeight)
}

/// The candidate closest to the configured geometry, preferring a Retina mode
/// only among equally close ones.
///
/// Logical size comes first because it is what the VM was configured for:
/// preferring Retina outright picks a visibly wrong size whenever the closest
/// Retina mode is further away than an exact 1x match. Under refit the offered
/// modes are sized to the host window's CONTENT rect, so the configured
/// geometry is usually absent from the list (a 1920x1080 VM is offered
/// 1920x1037 and 1920x1036) — this is a nearest match, not a lookup.
func chooseIndex(_ candidates: [Candidate], configured: (width: Int, height: Int)) -> Int? {
    func distance(_ candidate: Candidate) -> Int {
        abs(candidate.width - configured.width) + abs(candidate.height - configured.height)
    }
    return candidates.indices.min { a, b in
        let left = candidates[a], right = candidates[b]
        if distance(left) != distance(right) { return distance(left) < distance(right) }
        if left.isRetina != right.isRetina { return left.isRetina }
        if left.backingArea != right.backingArea { return left.backingArea > right.backingArea }
        return a < b
    }
}

func fail(_ message: String, _ code: Int32) -> Never {
    FileHandle.standardError.write(Data("display-mode: \(message)\n".utf8))
    exit(code)
}

/// Parses `WIDTHxHEIGHT`, refusing anything else — a guessed geometry is a
/// wrong screen, not a missing one.
func parseGeometry(_ text: String) -> (width: Int, height: Int) {
    let parts = text.split(separator: "x")
    guard parts.count == 2,
          let width = Int(parts[0]), let height = Int(parts[1]),
          width > 0, height > 0 else {
        fail("expected a WIDTHxHEIGHT geometry, got '\(text)'", 64)
    }
    return (width, height)
}

func run() {
    let arguments = CommandLine.arguments
    guard arguments.count == 2 else { fail("usage: display-mode <width>x<height>", 64) }
    let configured = parseGeometry(arguments[1])

    let display = CGMainDisplayID()
    guard let current = CGDisplayCopyDisplayMode(display) else {
        fail("the guest reports no display to configure", 1)
    }
    guard needsEstablishing(current: (current.width, current.height), configured: configured) else {
        exit(0)
    }

    // Retina modes are duplicates of the same sizes at a doubled backing store,
    // so the default enumeration hides them; without them the only candidates
    // are 1x modes, which render soft on a display the host draws at 2x.
    let options = [kCGDisplayShowDuplicateLowResolutionModes as String: kCFBooleanTrue!] as CFDictionary
    guard let all = CGDisplayCopyAllDisplayModes(display, options) as? [CGDisplayMode] else {
        fail("the display offers no modes to choose from", 1)
    }
    // CoreGraphics marks the modes a desktop session can actually run in; the
    // rest are enumerable but not selectable for a GUI.
    let modes = all.filter { $0.isUsableForDesktopGUI() }
    let candidates = modes.map {
        Candidate(width: $0.width, height: $0.height,
                  pixelWidth: $0.pixelWidth, pixelHeight: $0.pixelHeight)
    }
    guard let index = chooseIndex(candidates, configured: configured) else {
        fail("the display offers no mode a desktop can use", 1)
    }
    let target = modes[index]

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
}

#if SELFTEST

// The mode list a real 1920x1080 macOS guest offers under --display-refit,
// measured on one. Retina and 1x entries duplicate the same logical sizes,
// which is what makes the preference order worth pinning.
let measured: [Candidate] = [
    Candidate(width: 640, height: 346, pixelWidth: 1280, pixelHeight: 692),
    Candidate(width: 640, height: 480, pixelWidth: 1280, pixelHeight: 960),
    Candidate(width: 800, height: 600, pixelWidth: 1600, pixelHeight: 1200),
    Candidate(width: 960, height: 518, pixelWidth: 1920, pixelHeight: 1036),
    Candidate(width: 1280, height: 691, pixelWidth: 2560, pixelHeight: 1382),
    Candidate(width: 1280, height: 692, pixelWidth: 1280, pixelHeight: 692),
    Candidate(width: 1280, height: 960, pixelWidth: 1280, pixelHeight: 960),
    Candidate(width: 1600, height: 864, pixelWidth: 3200, pixelHeight: 1728),
    Candidate(width: 1600, height: 864, pixelWidth: 1600, pixelHeight: 864),
    Candidate(width: 1600, height: 1200, pixelWidth: 1600, pixelHeight: 1200),
    Candidate(width: 1920, height: 1036, pixelWidth: 1920, pixelHeight: 1036),
    Candidate(width: 1920, height: 1037, pixelWidth: 3840, pixelHeight: 2074),
    Candidate(width: 2560, height: 1382, pixelWidth: 2560, pixelHeight: 1382),
    Candidate(width: 2560, height: 1382, pixelWidth: 5120, pixelHeight: 2764),
]

var failures = 0
func check(_ label: String, _ actual: String, _ expected: String) {
    if actual == expected {
        print("  ok   \(label)")
    } else {
        failures += 1
        print("  FAIL \(label)\n         want » \(expected) « got » \(actual) «")
    }
}
func chosen(_ candidates: [Candidate], _ width: Int, _ height: Int) -> String {
    guard let index = chooseIndex(candidates, configured: (width, height)) else { return "none" }
    let candidate = candidates[index]
    return "\(candidate.width)x\(candidate.height)@\(candidate.pixelWidth)x\(candidate.pixelHeight)"
}

print("display-mode selftest — the gate:")
check("a fresh clone configured larger is established",
      "\(needsEstablishing(current: (1024, 768), configured: (1920, 1080)))", "true")
check("an established mode is left alone",
      "\(needsEstablishing(current: (1920, 1037), configured: (1920, 1080)))", "false")
check("a clone configured AT 1024x768 is already correct",
      "\(needsEstablishing(current: (1024, 768), configured: (1024, 768)))", "false")
check("a guest at some other mode is left alone",
      "\(needsEstablishing(current: (1280, 692), configured: (1920, 1080)))", "false")

print("display-mode selftest — the choice:")
check("1920x1080 takes the nearest Retina mode", chosen(measured, 1920, 1080), "1920x1037@3840x2074")
check("an exact 1x match beats a distant Retina mode", chosen(measured, 1280, 960), "1280x960@1280x960")
check("equal distance prefers Retina", chosen(measured, 1600, 864), "1600x864@3200x1728")
// Two plausible 2x modes, equally far from the target and equally sharp, whose
// area and width disagree — the pair that shows the tie-break reads AREA. A
// mode scaled 1x across and 2x down would rank them too, and no display has one.
check("equal distance and scale prefers the larger backing store",
      chosen([Candidate(width: 108, height: 98, pixelWidth: 216, pixelHeight: 196),
              Candidate(width: 101, height: 109, pixelWidth: 202, pixelHeight: 218)], 100, 100),
      "101x109@202x218")
check("no candidates yields no choice", chosen([], 1920, 1080), "none")

print("")
print("  \(failures == 0 ? "selftest passed" : "selftest FAILED")")
exit(failures == 0 ? 0 : 1)

#else

run()

#endif
