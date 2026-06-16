import Foundation

/// Matches each poll's snapshot of elements against the previous snapshot so
/// every physical element keeps a stable id across calls — regardless of its
/// position in the array or any attribute change the caller's `isSame`
/// comparator doesn't consider.
///
/// An element with no match in the previous snapshot is assigned a freshly
/// minted id via `makeID` — unless `fallbackKey` recognizes it as a churned
/// identity for a previously-tracked element that also went unmatched (see
/// `fallbackKey` below). Elements that disappear are dropped entirely — ids
/// are never recycled; a different-but-similar element that appears later is
/// treated as new and gets its own fresh id.
public final class WindowIdentityTracker<Element> {
    private let isSame: (Element, Element) -> Bool
    private let fallbackKey: ((Element) -> AnyHashable?)?
    private let makeID: () -> String
    private var previous: [(id: String, element: Element)] = []

    /// - Parameters:
    ///   - isSame: Primary identity comparator, e.g. `CFEqual` on an
    ///     `AXUIElement`. Exact matches always win.
    ///   - fallbackKey: Optional secondary signal consulted only for elements
    ///     that found no `isSame` match this round. If a previously-tracked
    ///     element (which also found no `isSame` match this round) returns an
    ///     equal, non-nil key, its id is reused instead of minting a fresh
    ///     one. This recovers identity when the primary signal is unstable
    ///     across otherwise-unremarkable updates — e.g. an Electron app's
    ///     window `AXUIElement` reference changing after its content
    ///     re-renders, even though the on-screen window (and thus, say, its
    ///     frame) is unchanged. Returns `nil` for an element with no usable
    ///     fallback signal, which falls through to minting a fresh id.
    ///   - makeID: Generates a fresh id for elements with no match at all.
    public init(isSame: @escaping (Element, Element) -> Bool,
                fallbackKey: ((Element) -> AnyHashable?)? = nil,
                makeID: @escaping () -> String = { UUID().uuidString }) {
        self.isSame = isSame
        self.fallbackKey = fallbackKey
        self.makeID = makeID
    }

    public func match(_ elements: [Element]) -> [(id: String, element: Element)] {
        var remaining = previous
        var unmatchedIndices: [Int] = []
        var results: [(id: String, element: Element)?] = elements.map { element -> (id: String, element: Element)? in
            if let index = remaining.firstIndex(where: { isSame($0.element, element) }) {
                let id = remaining[index].id
                remaining.remove(at: index)
                return (id, element)
            }
            return nil
        }

        for index in results.indices where results[index] == nil {
            unmatchedIndices.append(index)
        }

        if let fallbackKey {
            for index in unmatchedIndices {
                let element = elements[index]
                guard let key = fallbackKey(element) else { continue }
                if let matchIndex = remaining.firstIndex(where: { fallbackKey($0.element) == key }) {
                    results[index] = (remaining[matchIndex].id, element)
                    remaining.remove(at: matchIndex)
                }
            }
        }

        let matched = results.enumerated().map { index, result in
            result ?? (makeID(), elements[index])
        }
        previous = matched
        return matched
    }
}
