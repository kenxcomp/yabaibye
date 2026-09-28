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
    // Resolve relative to the focused display, retaining WindowServer display order.
    public static func navigationDisplay(currentDisplayID: String, other: Bool, displays: [DisplaySpaces]) -> DisplaySpaces? {
        guard let index = displays.firstIndex(where: { $0.uuid.caseInsensitiveCompare(currentDisplayID) == .orderedSame }) else { return nil }
        guard other else { return displays[index] }
        guard displays.count > 1 else { return nil }
        return displays[(index + 1) % displays.count]
    }
    // At either edge, stay put. Fullscreen desktops can be traversed by relative navigation.
    public static func adjacent(_ delta: Int, display: DisplaySpaces) -> SpaceTarget? {
        guard let index = display.spaces.firstIndex(where: { $0.id == display.current }) else { return nil }
        let next = index + delta
        guard display.spaces.indices.contains(next) else { return nil }
        return SpaceTarget(display: display, desktop: display.spaces[next], missionControlIndex: next)
    }
}
public enum Direction: String, CaseIterable, Codable { case left, right, up, down }
public enum Command: Equatable, Codable {
    case focusSpace(Int), moveToSpace(Int), toggleFloat, toggleZoom
    case cycle(Int, secondary: Bool), swap(Direction)
}
public struct Binding: Equatable, Codable {
    public let keyCode: UInt32
    public let shift: Bool
    public let control: Bool
    public let option: Bool
    public let cmd: Bool
    public let command: Command
    public init(_ keyCode: UInt32, shift: Bool = false, control: Bool = false, option: Bool = true, cmd: Bool = false, command: Command) {
        self.keyCode = keyCode; self.shift = shift; self.control = control; self.option = option; self.cmd = cmd; self.command = command
    }
    public var label: String {
        (control ? "⌃" : "") + (option ? "⌥" : "") + (shift ? "⇧" : "") + (cmd ? "⌘" : "") + (Self.keyNames[keyCode] ?? String(keyCode))
    }
    public static let keyNames: [UInt32: String] = [0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",24:"=",25:"9",26:"7",27:"-",28:"8",29:"0",30:"]",31:"O",32:"U",33:"[",34:"I",35:"P",36:"Return",37:"L",38:"J",39:"'",40:"K",41:";",42:"\\",43:",",44:"/",45:"N",46:"M",47:".",48:"Tab",49:"Space",50:"`",51:"Delete",53:"Escape",123:"←",124:"→",125:"↓",126:"↑"]
    public var actionLabel: String {
        switch command {
        case .focusSpace(let n): return "切换到 Space \(n)"
        case .moveToSpace(let n): return "移窗到 Space \(n)"
        case .toggleFloat: return "平铺 / 浮动"
        case .toggleZoom: return "铺满桌面 / 恢复"
        case .cycle(let n, let secondary): return (secondary ? "另一屏幕" : "当前屏幕") + (n < 0 ? "：上个 Space" : "：下个 Space")
        case .swap(let direction): return "交换窗口：" + [Direction.left:"←", .right:"→", .up:"↑", .down:"↓"][direction]!
        }
    }
    public static let defaults: [Binding] = {
        // Physical ANSI home row; independent of the active input method.
        let letters: [UInt32] = [0, 1, 2, 3, 5, 4, 38, 40, 37]
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
