public enum AXTreeWalker {
    /// Maximum depth a walk will descend before giving up on a branch.
    ///
    /// Real accessibility trees are walked live over IPC (see
    /// `AXUIElementAdapter`), where a pathologically deep or cyclic tree from
    /// a misbehaving app would otherwise turn an unbounded recursive walk into
    /// a stack overflow or an IPC storm. Chat UIs are nowhere near this deep —
    /// this is a backstop, not a realistic limit.
    private static let maximumDepth = 200

    /// Depth-first search for the first element matching `predicate`.
    public static func findFirst(in root: AccessibilityElement,
                                  where predicate: (AccessibilityElement) -> Bool) -> AccessibilityElement? {
        findFirst(in: root, depth: 0, where: predicate)
    }

    private static func findFirst(in root: AccessibilityElement, depth: Int,
                                   where predicate: (AccessibilityElement) -> Bool) -> AccessibilityElement? {
        guard depth < maximumDepth else { return nil }
        if predicate(root) { return root }
        for child in root.children {
            if let match = findFirst(in: child, depth: depth + 1, where: predicate) {
                return match
            }
        }
        return nil
    }

    /// Depth-first search collecting every element matching `predicate`.
    public static func findAll(in root: AccessibilityElement,
                                where predicate: (AccessibilityElement) -> Bool) -> [AccessibilityElement] {
        findAll(in: root, depth: 0, where: predicate)
    }

    private static func findAll(in root: AccessibilityElement, depth: Int,
                                 where predicate: (AccessibilityElement) -> Bool) -> [AccessibilityElement] {
        guard depth < maximumDepth else { return [] }
        var results: [AccessibilityElement] = []
        if predicate(root) { results.append(root) }
        for child in root.children {
            results.append(contentsOf: findAll(in: child, depth: depth + 1, where: predicate))
        }
        return results
    }
}
