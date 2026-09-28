import Foundation

public struct Desktop: Equatable, Codable {
    public let id: UInt64
    public let type: Int
    public init(id: UInt64, type: Int = 0) { self.id = id; self.type = type }
}
public struct DisplaySpaces: Equatable, Codable {
    public let uuid: String
    public let current: UInt64
    public let spaces: [Desktop]
    public init(uuid: String, current: UInt64, spaces: [Desktop]) {
        self.uuid = uuid; self.current = current; self.spaces = spaces
    }
}
public struct SpaceTarget: Equatable {
    public let display: DisplaySpaces
    public let desktop: Desktop
    // Index includes fullscreen Spaces, to match the Mission Control AX list.
    public let missionControlIndex: Int
    public init(display: DisplaySpaces, desktop: Desktop, missionControlIndex: Int) {
        self.display = display; self.desktop = desktop; self.missionControlIndex = missionControlIndex
    }
}
public enum SpaceRouter {
    // Preserve WindowServer/Mission Control display order; omit fullscreen desktops from 1...9.
    public static func numbered(_ number: Int, displays: [DisplaySpaces]) -> SpaceTarget? {
        guard number > 0 else { return nil }
        let targets = displays.flatMap { display in
            display.spaces.enumerated().compactMap { index, space in
                space.type == 0 ? SpaceTarget(display: display, desktop: space, missionControlIndex: index) : nil
            }
        }
        return number <= targets.count ? targets[number - 1] : nil
    }
    // At either edge, stay put. Fullscreen desktops can be traversed by relative navigation.
    public static func adjacent(_ delta: Int, display: DisplaySpaces) -> SpaceTarget? {
        guard let index = display.spaces.firstIndex(where: { $0.id == display.current }) else { return nil }
        let next = index + delta
        guard display.spaces.indices.contains(next) else { return nil }
        return SpaceTarget(display: display, desktop: display.spaces[next], missionControlIndex: next)
    }
}
public enum Direction: String, CaseIterable { case left, right, up, down }
public enum Command: Equatable {
    case focusSpace(Int), moveToSpace(Int), toggleFloat, toggleZoom
    case cycle(Int, secondary: Bool), swap(Direction)
}
public struct Binding {
    public let keyCode: UInt32
    public let shift: Bool
    public let control: Bool
    public let command: Command
    public init(_ keyCode: UInt32, shift: Bool = false, control: Bool = false, command: Command) {
        self.keyCode = keyCode; self.shift = shift; self.control = control; self.command = command
    }
    public var label: String {
        let names: [UInt32: String] = [0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I",
            18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
            36: "Return", 17: "T", 33: "[", 30: "]", 123: "←", 124: "→", 126: "↑", 125: "↓"]
        return (control ? "⌃" : "") + "⌥" + (shift ? "⇧" : "") + (names[keyCode] ?? String(keyCode))
    }
    public static let defaults: [Binding] = {
        // Physical ANSI a...i; independent of the active input method.
        let letters: [UInt32] = [0, 11, 8, 2, 14, 3, 5, 4, 34]
        var items = letters.enumerated().flatMap { i, code in
            [Binding(code, command: .focusSpace(i + 1)), Binding(code, shift: true, command: .moveToSpace(i + 1))]
        }
        items.append(Binding(17, command: .toggleFloat))
        items.append(Binding(36, command: .toggleZoom))
        for shift in [false, true] {
            items.append(Binding(33, shift: shift, command: .cycle(-1, secondary: shift)))
            items.append(Binding(30, shift: shift, command: .cycle(1, secondary: shift)))
        }
        for (code, direction) in [(123, Direction.left), (124, .right), (126, .up), (125, .down)] {
            items.append(Binding(UInt32(code), command: .swap(direction)))
        }
        return items
    }()
}
