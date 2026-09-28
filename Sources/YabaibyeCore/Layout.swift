import Foundation
import CoreGraphics

public enum Layout {
    // Balanced binary tiling, splitting each region along its longer axis.
    public static func frames(count: Int, in bounds: CGRect, gap: CGFloat = 10) -> [CGRect] {
        guard count > 0, bounds.width > 0, bounds.height > 0 else { return [] }
        let inset = max(0, min(gap, min(bounds.width, bounds.height) / 4))
        return split(count, bounds.insetBy(dx: inset, dy: inset), gap: inset)
    }
    private static func split(_ count: Int, _ bounds: CGRect, gap: CGFloat) -> [CGRect] {
        if count == 1 { return [bounds] }
        let firstCount = (count + 1) / 2
        let horizontal = bounds.width >= bounds.height
        let length = horizontal ? bounds.width : bounds.height
        let safeGap = min(gap, length / 4)
        let firstLength = ((length - safeGap) * CGFloat(firstCount) / CGFloat(count)).rounded(.down)
        var first = bounds, second = bounds
        if horizontal {
            first.size.width = firstLength
            second.origin.x += firstLength + safeGap
            second.size.width -= firstLength + safeGap
        } else {
            first.size.height = firstLength
            second.origin.y += firstLength + safeGap
            second.size.height -= firstLength + safeGap
        }
        return split(firstCount, first, gap: gap) + split(count - firstCount, second, gap: gap)
    }
    public static func neighbor(of index: Int, direction: Direction, frames: [CGRect]) -> Int? {
        guard frames.indices.contains(index) else { return nil }
        let origin = frames[index]
        var best: (Int, CGFloat)?
        for (candidate, frame) in frames.enumerated() where candidate != index {
            let dx = frame.midX - origin.midX, dy = frame.midY - origin.midY
            let primary: CGFloat, perpendicular: CGFloat, overlaps: Bool
            switch direction {
            case .left: primary = -dx; perpendicular = abs(dy); overlaps = frame.maxY > origin.minY && frame.minY < origin.maxY
            case .right: primary = dx; perpendicular = abs(dy); overlaps = frame.maxY > origin.minY && frame.minY < origin.maxY
            case .up: primary = -dy; perpendicular = abs(dx); overlaps = frame.maxX > origin.minX && frame.minX < origin.maxX
            case .down: primary = dy; perpendicular = abs(dx); overlaps = frame.maxX > origin.minX && frame.minX < origin.maxX
            }
            guard primary > 1 else { continue }
            let score = primary + perpendicular * 2 + (overlaps ? 0 : 100_000)
            if best == nil || score < best!.1 { best = (candidate, score) }
        }
        return best?.0
    }
}
