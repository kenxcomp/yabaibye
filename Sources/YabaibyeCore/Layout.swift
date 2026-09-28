import Foundation
import CoreGraphics

public enum Layout {
    // Three windows use two columns with a stacked pair; four form a 2 x 2 grid.
    public static func frames(count: Int, in bounds: CGRect, gap: CGFloat = 10) -> [CGRect] {
        guard count > 0 else { return [] }
        let ids = (0..<count).map(String.init)
        let frames = TileLayout(ids: ids).frames(in: bounds, gap: gap)
        return ids.compactMap { frames[$0] }
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
