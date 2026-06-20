// One-shot probe: confirm which private SPI symbols resolve on this machine.
// Run: swift /Users/milikadelic/claude-auto-resume/Scripts/probe-skylight.swift
//
// Prints "OK <symbol>" for each resolved symbol, "MISSING <symbol>" otherwise.
// Bails out cleanly if the framework can't be dlopened.

import Foundation
import Darwin

func probe(_ handle: UnsafeMutableRawPointer?, _ name: String) {
    if dlsym(handle, name) != nil {
        print("OK     \(name)")
    } else {
        let err = String(cString: dlerror())
        print("MISS   \(name)  (\(err))")
    }
}

print("--- /System/Library/PrivateFrameworks/SkyLight.framework ---")
guard let sky = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/Resources/WindowServer", RTLD_LAZY) else {
    let err = String(cString: dlerror())
    print("dlopen failed: \(err)")
    print("(fallback: trying bare framework path)")
    if let sky2 = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework", RTLD_LAZY) {
        print("fallback dlopen ok; probing")
        probe(sky2, "SLEventPostToPid")
        probe(sky2, "SLPSPostEventRecordTo")
        probe(sky2, "SLPSSetFrontProcessWithOptions")
        probe(sky2, "SLEventCreateMouseEvent")
    } else {
        print("fallback also failed: \(String(cString: dlerror()))")
    }
    exit(0)
}
print("dlopen ok")
probe(sky, "SLEventPostToPid")
probe(sky, "SLPSPostEventRecordTo")
probe(sky, "SLPSSetFrontProcessWithOptions")
probe(sky, "SLEventCreateMouseEvent")

print("--- /System/Library/Frameworks/ApplicationServices.framework ---")
if let ax = dlopen("/System/Library/Frameworks/ApplicationServices.framework/Versions/A/ApplicationServices", RTLD_LAZY) {
    print("dlopen ok")
    probe(ax, "_AXObserverAddNotificationAndCheckRemote")
    probe(ax, "AXObserverAddNotification")
} else {
    print("dlopen failed: \(String(cString: dlerror()))")
}
