import ApplicationServices

/// Adapts a live `AXUIElement` to the `AccessibilityElement` protocol by
/// reading its role, title, value, and children attributes.
public struct AXUIElementAdapter: AccessibilityElement {
    public let element: AXUIElement

    public init(_ element: AXUIElement) {
        self.element = element
    }

    public var role: String? {
        stringAttribute(kAXRoleAttribute)
    }

    public var title: String? {
        stringAttribute(kAXTitleAttribute)
    }

    public var value: String? {
        stringAttribute(kAXValueAttribute)
    }

    public var frame: CGRect? {
        guard let position = pointAttribute(kAXPositionAttribute),
              let size = sizeAttribute(kAXSizeAttribute) else { return nil }
        return CGRect(origin: position, size: size)
    }

    public var children: [AccessibilityElement] {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
        guard result == .success, let children = value as? [AXUIElement] else { return [] }
        return children.map { AXUIElementAdapter($0) }
    }

    private func stringAttribute(_ attribute: String) -> String? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success else { return nil }
        return value as? String
    }

    private func pointAttribute(_ attribute: String) -> CGPoint? {
        guard let axValue = axValueAttribute(attribute) else { return nil }
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else { return nil }
        return point
    }

    private func sizeAttribute(_ attribute: String) -> CGSize? {
        guard let axValue = axValueAttribute(attribute) else { return nil }
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else { return nil }
        return size
    }

    private func axValueAttribute(_ attribute: String) -> AXValue? {
        var value: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard result == .success, let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)
    }
}
