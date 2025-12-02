import Foundation

struct Stratagem: Codable, Identifiable, Hashable {
    let id = UUID()
    let name: String
    let sequence: [String]

    enum CodingKeys: String, CodingKey {
        case name, sequence
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(name)
    }

    static func == (lhs: Stratagem, rhs: Stratagem) -> Bool {
        return lhs.name == rhs.name
    }
}

struct Keybind: Codable, Equatable {
    var keyCode: String
    var letter: String

    enum CodingKeys: String, CodingKey {
        case keyCode = "key_code"
        case letter
    }
}

enum ActivationMode: String, Codable {
    case hold = "hold"      // Hold super key while pressing directionals
    case toggle = "toggle"  // Press super key once, then press directionals
}

struct DirectionalKeybinds: Codable {
    var up: Keybind
    var down: Keybind
    var left: Keybind
    var right: Keybind

    enum CodingKeys: String, CodingKey {
        case up, down, left, right
    }

    static var defaultWASD: DirectionalKeybinds {
        DirectionalKeybinds(
            up: Keybind(keyCode: "0x0D", letter: "W"),
            down: Keybind(keyCode: "0x01", letter: "S"),
            left: Keybind(keyCode: "0x00", letter: "A"),
            right: Keybind(keyCode: "0x02", letter: "D")
        )
    }

    static var defaultArrows: DirectionalKeybinds {
        DirectionalKeybinds(
            up: Keybind(keyCode: "0x7E", letter: "↑"),
            down: Keybind(keyCode: "0x7D", letter: "↓"),
            left: Keybind(keyCode: "0x7B", letter: "←"),
            right: Keybind(keyCode: "0x7C", letter: "→")
        )
    }
}

struct UserData: Codable {
    var equippedStratagems: [String]
    var keybinds: [Keybind]
    var allowedApps: [String]?  // Optional for backwards compatibility
    var superKey: Keybind?      // Optional for backwards compatibility (default: Control)
    var activationMode: ActivationMode?  // Optional for backwards compatibility (default: hold)
    var directionalKeys: DirectionalKeybinds?  // Optional for backwards compatibility (default: WASD)
    var comboKey: Keybind?      // Optional for backwards compatibility (default: Shift)

    enum CodingKeys: String, CodingKey {
        case equippedStratagems = "equipped_stratagems"
        case keybinds
        case allowedApps = "allowed_apps"
        case superKey = "super_key"
        case activationMode = "activation_mode"
        case directionalKeys = "directional_keys"
        case comboKey = "combo_key"
    }
}
