import Foundation
import CoreGraphics

public enum DropZone: String, CaseIterable {
    case center, left, right, top, bottom
    public static func hit(at point: CGPoint, in rect: CGRect) -> DropZone? {
        guard rect.width > 0, rect.height > 0, rect.contains(point) else { return nil }
        let x = (point.x - rect.minX) / rect.width, y = (point.y - rect.minY) / rect.height
        // The middle 50% is the swap zone. Corners select the nearest normalized edge.
        let distances: [(DropZone, CGFloat)] = [(.left, x), (.right, 1-x), (.top, y), (.bottom, 1-y)]
        let nearest = distances.min { $0.1 < $1.1 }!
        return nearest.1 < 0.25 ? nearest.0 : .center
    }
    public func preview(in rect: CGRect) -> CGRect {
        switch self {
        case .center: return rect
        case .left: return CGRect(x: rect.minX, y: rect.minY, width: rect.width / 2, height: rect.height)
        case .right: return CGRect(x: rect.midX, y: rect.minY, width: rect.width / 2, height: rect.height)
        case .top: return CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rect.height / 2)
        case .bottom: return CGRect(x: rect.minX, y: rect.midY, width: rect.width, height: rect.height / 2)
        }
    }
}

/// Equal-weight sibling regions. Removing a leaf collapses empty/one-child groups;
/// adjacent groups of the same axis flatten so extracting a nested tile rebalances its row.
public struct TileLayout: Equatable, Codable {
    public enum Axis: Equatable, Codable { case horizontal, vertical }
    public indirect enum Node: Equatable, Codable {
        case window(String)
        case split(Axis, [Node])
        var ids: [String] {
            switch self { case .window(let id): return [id]; case .split(_, let nodes): return nodes.flatMap(\.ids) }
        }
        func normalized() -> Node? {
            guard case .split(let axis, let nodes) = self else { return self }
            let children = nodes.compactMap { $0.normalized() }.flatMap { node -> [Node] in
                if case .split(let childAxis, let children) = node, childAxis == axis { return children }
                return [node]
            }
            if children.isEmpty { return nil }
            if children.count == 1 { return children[0] }
            return .split(axis, children)
        }
        func removing(_ id: String) -> Node? {
            switch self {
            case .window(let value): return value == id ? nil : self
            case .split(let axis, let nodes): return Node.split(axis, nodes.compactMap { $0.removing(id) }).normalized()
            }
        }
        func replacing(_ id: String, with replacement: Node) -> Node {
            switch self {
            case .window(let value): return value == id ? replacement : self
            case .split(let axis, let nodes): return .split(axis, nodes.map { $0.replacing(id, with: replacement) })
            }
        }
        func swapping(_ a: String, _ b: String) -> Node {
            switch self {
            case .window(let id): return .window(id == a ? b : id == b ? a : id)
            case .split(let axis, let nodes): return .split(axis, nodes.map { $0.swapping(a, b) })
            }
        }
    }
    public private(set) var root: Node?
    public private(set) var customized = false
    public var ids: [String] { root?.ids ?? [] }
    public init(ids: [String]) {
        var seen = Set<String>()
        root = Self.grid(ids.filter { seen.insert($0).inserted })
    }
    private static func grid(_ ids: [String]) -> Node? {
        guard !ids.isEmpty else { return nil }
        if ids.count == 1 { return .window(ids[0]) }
        let columns = Int(ceil(sqrt(Double(ids.count))))
        var offset = 0
        let groups = (0..<columns).map { column -> Node in
            let count = ids.count / columns + (column < ids.count % columns ? 1 : 0)
            defer { offset += count }
            return Node.split(.vertical, ids[offset..<(offset + count)].map(Node.window)).normalized()!
        }
        return Node.split(.horizontal, groups).normalized()
    }
    public mutating func reconcile(_ members: [String]) {
        let memberSet = Set(members)
        let order = ids.filter { memberSet.contains($0) } + members.filter { !ids.contains($0) }
        // Rebuild automatic layouts even when membership is unchanged so saved defaults
        // follow the current grid policy. Explicit drag partitions retain their geometry.
        guard customized else { root = Self.grid(order); return }
        if Set(ids) == memberSet { return }
        for id in ids where !memberSet.contains(id) { root = root?.removing(id) }
        for id in order where !ids.contains(id) {
            root = root.map { Node.split(.horizontal, [$0, .window(id)]).normalized()! } ?? .window(id)
        }
    }
    @discardableResult public mutating func drop(_ source: String, onto target: String, zone: DropZone) -> Bool {
        guard source != target, ids.contains(source), ids.contains(target), let existing = root else { return false }
        if zone == .center { root = existing.swapping(source, target) }
        else {
            let axis: Axis = (zone == .left || zone == .right) ? .horizontal : .vertical
            let before = zone == .left || zone == .top
            let pair: [Node] = before ? [.window(source), .window(target)] : [.window(target), .window(source)]
            root = existing.removing(source)?.replacing(target, with: .split(axis, pair)).normalized()
        }
        if zone != .center { customized = true }
        return true
    }
    public func frames(in bounds: CGRect, gap: CGFloat = 10, padding: CGFloat? = nil) -> [String: CGRect] {
        guard bounds.width > 0, bounds.height > 0 else { return [:] }
        let requestedPadding = padding ?? gap
        let safePadding = requestedPadding.isFinite ? max(0, requestedPadding) : 10
        let requestedGap = gap.isFinite ? max(0, gap) : 10
        let inset = min(safePadding, min(bounds.width, bounds.height) / 4)
        var result: [String: CGRect] = [:]
        func visit(_ node: Node, _ rect: CGRect) {
            switch node {
            case .window(let id): result[id] = rect
            case .split(let axis, let children):
                guard !children.isEmpty else { return }
                let length = axis == .horizontal ? rect.width : rect.height
                let safeGap = min(requestedGap, length / CGFloat(children.count * 2))
                let size = (length - safeGap * CGFloat(children.count - 1)) / CGFloat(children.count)
                for (i, child) in children.enumerated() {
                    var part = rect
                    if axis == .horizontal { part.origin.x += CGFloat(i) * (size + safeGap); part.size.width = size }
                    else { part.origin.y += CGFloat(i) * (size + safeGap); part.size.height = size }
                    visit(child, part)
                }
            }
        }
        if let root { visit(root, bounds.insetBy(dx: inset, dy: inset)) }
        return result
    }
}
