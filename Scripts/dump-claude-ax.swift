import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

// Dump the Claude Desktop AX tree, structured by depth, with the key signal
// elements (rate-limit banner, chat input, send button) called out and the
// path from the window root to each one shown explicitly.
//
// Usage: swift Scripts/dump-claude-ax.swift [pid]
//        (pid defaults to the running Claude Desktop process)

let pidArg: pid_t? = CommandLine.arguments.dropFirst().first.flatMap { pid_t($0) }

let app: NSRunningApplication
if let pid = pidArg {
    guard let a = NSRunningApplication(processIdentifier: pid) else {
        print("ERROR: no running application with pid \(pid)")
        exit(1)
    }
    app = a
} else {
    guard let a = NSWorkspace.shared.runningApplications.first(where: {
        $0.bundleIdentifier == "com.anthropic.claudefordesktop"
    }) else {
        print("ERROR: Claude Desktop not running")
        exit(1)
    }
    app = a
}

print("PID: \(app.processIdentifier)  bundle: \(app.bundleIdentifier ?? "?")  name: \(app.localizedName ?? "?")")
print("isFinishedLaunching: \(app.isFinishedLaunching)  isHidden: \(app.isHidden)  activationPolicy: \(app.activationPolicy.rawValue)")

let appElement = AXUIElementCreateApplication(app.processIdentifier)
let trusted = AXIsProcessTrustedWithOptions(nil)
print("AXIsProcessTrusted: \(trusted)")

// Some apps gate richer tree behind the enhanced-UI flag.
AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)

var windowsRef: CFTypeRef?
let winStatus = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)
guard winStatus == .success, let axWindows = windowsRef as? [AXUIElement] else {
    print("ERROR: AXWindows copy failed: \(winStatus.rawValue)")
    exit(1)
}
print("AXWindows count: \(axWindows.count)\n")

// Caps so a runaway tree doesn't blow up the terminal.
let maxDepth = 60
let maxNodesPerWindow = 4000
let maxValueChars = 80
let maxTitleChars = 80

func short(_ s: String?, cap: Int) -> String {
    guard let s else { return "nil" }
    if s.count <= cap { return s.replacingOccurrences(of: "\n", with: "\\n") }
    return String(s.prefix(cap)).replacingOccurrences(of: "\n", with: "\\n") + "…"
}

func frameStr(_ f: CGRect?) -> String {
    guard let f else { return "nil" }
    return String(format: "(x:%.0f y:%.0f w:%.0f h:%.0f)", f.minX, f.minY, f.width, f.height)
}

struct NodeSig {
    let depth: Int
    let role: String?
    let subrole: String?
    let title: String?
    let value: String?
    let frame: CGRect?
    let identifier: String?
    let isEnabled: Bool?
    let childCount: Int
}

func readSig(_ element: AXUIElement, depth: Int) -> NodeSig {
    func copyString(_ attr: String) -> String? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &v) == .success else { return nil }
        return v as? String
    }
    func copyFrame(_ attr: String) -> CGRect? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &v) == .success else { return nil }
        guard let axVal = v, AXValueGetType(axVal as! AXValue) == .cgRect else { return nil }
        var r = CGRect.zero
        guard AXValueGetValue(axVal as! AXValue, .cgRect, &r) else { return nil }
        return r
    }
    func copyNum(_ attr: String) -> Bool? {
        var v: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attr as CFString, &v) == .success else { return nil }
        return (v as? NSNumber)?.boolValue
    }
    var childCount = 0
    var kids: CFTypeRef?
    if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &kids) == .success,
       let arr = kids as? [AXUIElement] {
        childCount = arr.count
    }
    return NodeSig(
        depth: depth,
        role: copyString(kAXRoleAttribute),
        subrole: copyString(kAXSubroleAttribute),
        title: copyString(kAXTitleAttribute),
        value: copyString(kAXValueAttribute),
        frame: copyFrame(kAXPositionAttribute).flatMap { pos -> CGRect? in
            guard let size = copyFrame(kAXSizeAttribute) else { return nil }
            return CGRect(origin: pos.origin, size: size.size)
        } ?? copyFrame("AXFrame"),
        identifier: copyString("AXIdentifier"),
        isEnabled: copyNum(kAXEnabledAttribute),
        childCount: childCount
    )
}

struct Finding {
    let label: String
    let path: [String]
    let role: String
    let title: String?
    let value: String?
    let frame: CGRect?
    let childCount: Int
}

func dumpTree(root: AXUIElement, label: String, maxNodes: Int) -> (findings: [Finding], roleHistogram: [String: Int], totalNodes: Int) {
    var roleHistogram: [String: Int] = [:]
    var findings: [Finding] = []
    var nodeCount = 0
    var pathStack: [String] = []

    func recurse(_ element: AXUIElement, depth: Int) {
        if nodeCount >= maxNodes { return }
        nodeCount += 1

        let sig = readSig(element, depth: depth)
        let role = sig.role ?? "?"
        roleHistogram[role, default: 0] += 1

        // Push role label onto the path stack so we can recover the full chain.
        let pathLabel: String
        if let t = sig.title, !t.isEmpty {
            pathLabel = "\(role)[\"\(short(t, cap: 30))\"]"
        } else if let v = sig.value, !v.isEmpty {
            pathLabel = "\(role)=\"\(short(v, cap: 30))\""
        } else if let id = sig.identifier, !id.isEmpty {
            pathLabel = "\(role)#\(id)"
        } else {
            pathLabel = role
        }
        pathStack.append(pathLabel)

        // Collect findings.
        let isTextInput = role == "AXTextArea" || role == "AXTextField"
        let isButton = role == "AXButton"
        let looksLikeBanner = (sig.value?.lowercased().contains("limit") ?? false) ||
                               (sig.value?.lowercased().contains("resets at") ?? false) ||
                               (sig.value?.lowercased().contains("server is") ?? false)
        let looksLikeSend = isButton && (sig.title?.lowercased().contains("send") ?? false ||
                                         sig.value?.lowercased().contains("send") ?? false ||
                                         sig.identifier?.lowercased().contains("send") ?? false)

        if isTextInput {
            findings.append(Finding(
                label: "TEXT INPUT",
                path: pathStack,
                role: role,
                title: sig.title,
                value: sig.value,
                frame: sig.frame,
                childCount: sig.childCount))
        }
        if looksLikeSend {
            findings.append(Finding(
                label: "SEND BUTTON",
                path: pathStack,
                role: role,
                title: sig.title,
                value: sig.value,
                frame: sig.frame,
                childCount: sig.childCount))
        }
        if looksLikeBanner {
            findings.append(Finding(
                label: "BANNER-LIKE",
                path: pathStack,
                role: role,
                title: sig.title,
                value: sig.value,
                frame: sig.frame,
                childCount: sig.childCount))
        }

        // Recurse into children.
        if depth < maxDepth, sig.childCount > 0 {
            var kids: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &kids) == .success,
               let arr = kids as? [AXUIElement] {
                for c in arr { recurse(c, depth: depth + 1) }
            }
        }

        pathStack.removeLast()
    }

    print("========== \(label) ==========")
    recurse(root, depth: 0)
    print("totalNodes=\(nodeCount)")
    return (findings, roleHistogram, nodeCount)
}

// Dump a tree as indented one-liners (role + key attrs only — not the full
// path output, which we keep separately as findings).
func dumpCompact(_ root: AXUIElement, label: String) -> Int {
    var nodeCount = 0
    var roleHistogram: [String: Int] = [:]
    let maxNodes = 1500  // cap the visual dump; findings still use the full pass

    func recurse(_ element: AXUIElement, depth: Int) {
        if nodeCount >= maxNodes {
            if nodeCount == maxNodes { print("…(truncated, more nodes follow)") }
            nodeCount += 1
            return
        }
        nodeCount += 1

        let sig = readSig(element, depth: depth)
        let role = sig.role ?? "?"
        roleHistogram[role, default: 0] += 1

        let indent = String(repeating: "  ", count: min(depth, 20))
        var parts: [String] = ["role=\(role)"]
        if let s = sig.subrole, !s.isEmpty { parts.append("subrole=\(s)") }
        if let t = sig.title, !t.isEmpty { parts.append("title=\"\(short(t, cap: maxTitleChars))\"") }
        if let v = sig.value, !v.isEmpty { parts.append("value=\"\(short(v, cap: maxValueChars))\"") }
        if let id = sig.identifier, !id.isEmpty { parts.append("id=\(id)") }
        parts.append("frame=\(frameStr(sig.frame))")
        if let e = sig.isEnabled, !e { parts.append("DISABLED") }
        parts.append("children=\(sig.childCount)")
        print("\(indent)\(parts.joined(separator: " "))")

        if depth < maxDepth, sig.childCount > 0 {
            var kids: CFTypeRef?
            if AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &kids) == .success,
               let arr = kids as? [AXUIElement] {
                for c in arr { recurse(c, depth: depth + 1) }
            }
        }
    }
    print("\n--- compact dump: \(label) ---")
    recurse(root, depth: 0)
    let topRoles = roleHistogram.sorted { $0.value > $1.value }.prefix(20)
        .map { "\($0.key)=\($0.value)" }.joined(separator: ", ")
    print("(compact histogram: \(topRoles))")
    return nodeCount
}

// Window-level attrs we always print.
func dumpWindowHeader(_ w: AXUIElement, index: Int) {
    var tRef: CFTypeRef?
    var rRef: CFTypeRef?
    var srRef: CFTypeRef?
    var pRef: CFTypeRef?
    var sRef: CFTypeRef?
    var fRef: CFTypeRef?
    var mRef: CFTypeRef?
    AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &tRef)
    AXUIElementCopyAttributeValue(w, kAXRoleAttribute as CFString, &rRef)
    AXUIElementCopyAttributeValue(w, kAXSubroleAttribute as CFString, &srRef)
    AXUIElementCopyAttributeValue(w, kAXPositionAttribute as CFString, &pRef)
    AXUIElementCopyAttributeValue(w, kAXSizeAttribute as CFString, &sRef)
    AXUIElementCopyAttributeValue(w, kAXFocusedAttribute as CFString, &fRef)
    AXUIElementCopyAttributeValue(w, kAXMainAttribute as CFString, &mRef)

    let title = tRef as? String
    let role = rRef as? String
    let subrole = srRef as? String
    let isFocused = (fRef as? NSNumber)?.boolValue ?? false
    let isMain = (mRef as? NSNumber)?.boolValue ?? false

    var frameStr1 = "nil"
    if let pAx = pRef, let sAx = sRef,
       AXValueGetType(pAx as! AXValue) == .cgPoint,
       AXValueGetType(sAx as! AXValue) == .cgSize {
        var p = CGPoint.zero
        var s = CGSize.zero
        AXValueGetValue(pAx as! AXValue, .cgPoint, &p)
        AXValueGetValue(sAx as! AXValue, .cgSize, &s)
        frameStr1 = String(format: "(x:%.0f y:%.0f w:%.0f h:%.0f)", p.x, p.y, s.width, s.height)
    }
    print("Window #\(index + 1)")
    print("  title:     \(title ?? "nil")")
    print("  role:      \(role ?? "nil")")
    print("  subrole:   \(subrole ?? "nil")")
    print("  frame:     \(frameStr1)")
    print("  isFocused: \(isFocused)")
    print("  isMain:    \(isMain)")
}

var allFindings: [Finding] = []
var totalNodes = 0
for (i, w) in axWindows.enumerated() {
    print("")
    dumpWindowHeader(w, index: i)
    let (findings, _, n) = dumpTree(root: w, label: "full tree pass for window #\(i + 1)", maxNodes: maxNodesPerWindow)
    totalNodes += n
    _ = dumpCompact(w, label: "window #\(i + 1)")
    if !findings.isEmpty {
        print("\n--- findings in window #\(i + 1) ---")
        for f in findings {
            let pathStr = f.path.joined(separator: " → ")
            print("  [\(f.label)] \(f.role)\(f.title.map { " title=\"\(short($0, cap: 40))\"" } ?? "")\(f.value.map { " value=\"\(short($0, cap: 40))\"" } ?? "") frame=\(frameStr(f.frame)) children=\(f.childCount)")
            print("    path: \(pathStr)")
        }
    } else {
        print("\n(no text inputs / send buttons / banner-like nodes found in window #\(i + 1))")
    }
    allFindings.append(contentsOf: findings)
}

print("\n========== Summary ==========")
print("Windows inspected: \(axWindows.count)")
print("Total nodes walked: \(totalNodes)")
print("Findings: \(allFindings.count)")
let labels = Set(allFindings.map { $0.label })
for l in labels.sorted() {
    let count = allFindings.filter { $0.label == l }.count
    print("  \(l): \(count)")
}
