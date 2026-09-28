import Foundation

/// A desired tree is not an applied tree until the window server confirms geometry.
public struct LayoutApplication {
    private var appliedLayout: TileLayout?
    private var appliedSignature: String?
    private var failedLayout: TileLayout?
    private var failedSignature: String?
    public private(set) var failureCount = 0
    public private(set) var retryAfter: TimeInterval = 0
    public init() {}
    public func needsApply(_ layout: TileLayout, signature: String, now: TimeInterval, force: Bool = false) -> Bool {
        if force { return true }
        if appliedLayout == layout && appliedSignature == signature { return false }
        if failedLayout == layout && failedSignature == signature && now < retryAfter { return false }
        return true
    }
    public mutating func succeeded(_ layout: TileLayout, signature: String) {
        appliedLayout = layout; appliedSignature = signature
        failedLayout = nil; failedSignature = nil; failureCount = 0; retryAfter = 0
    }
    public mutating func failed(_ layout: TileLayout, signature: String, now: TimeInterval) {
        // Partial writes can also invalidate a previously confirmed frame.
        appliedLayout = nil; appliedSignature = nil
        failureCount = failedLayout == layout && failedSignature == signature ? min(failureCount + 1, 5) : 1
        failedLayout = layout; failedSignature = signature
        retryAfter = now + min(15, pow(2, Double(failureCount - 1)))
    }
}
