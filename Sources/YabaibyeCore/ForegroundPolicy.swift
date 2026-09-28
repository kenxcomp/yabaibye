import Foundation
import CoreGraphics

public struct WindowStackEntry {
    public let id: UInt32
    public let owner: Int32
    public let layer: Int
    public let frame: CGRect
    public init(id: UInt32, owner: Int32, layer: Int = 0, frame: CGRect) {
        self.id = id; self.owner = owner; self.layer = layer; self.frame = frame
    }
}
public enum ForegroundPolicy {
    /// The input is front-to-back. Do not reorder active-app sheets or elevated panels.
    public static func obstruction(focusedID: UInt32, activePID: Int32, stack: [WindowStackEntry]) -> UInt32? {
        guard let index = stack.firstIndex(where: { $0.id == focusedID && $0.owner == activePID }), stack[index].layer == 0 else { return nil }
        let focused = stack[index]
        let above = stack[..<index].filter { $0.frame.intersects(focused.frame) }
        guard !above.contains(where: { $0.owner == activePID }) else { return nil }
        return above.first(where: { $0.layer == 0 && $0.owner != activePID })?.id
    }
}
