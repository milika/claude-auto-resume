import CoreGraphics

/// A read-only view of one node in an accessibility tree. Implemented by a
/// real `AXUIElement` adapter (see `AXUIElementAdapter`) and, in tests, by
/// plain mock trees.
public protocol AccessibilityElement {
    var role: String? { get }
    var title: String? { get }
    var value: String? { get }
    /// On-screen position and size, in global screen coordinates — `nil` if
    /// the element doesn't expose one or the value can't be read.
    var frame: CGRect? { get }
    var children: [AccessibilityElement] { get }
}
