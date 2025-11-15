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

struct Keybind: Codable {
    var keyCode: String
    var letter: String

    enum CodingKeys: String, CodingKey {
        case keyCode = "key_code"
        case letter
    }
}

struct UserData: Codable {
    var equippedStratagems: [String]
    var keybinds: [Keybind]
    var allowedApps: [String]?  // Optional for backwards compatibility

    enum CodingKeys: String, CodingKey {
        case equippedStratagems = "equipped_stratagems"
        case keybinds
        case allowedApps = "allowed_apps"
    }
}

struct HelldiversKeybinds: Codable {
    let stratagemMenu: String

    enum CodingKeys: String, CodingKey {
        case stratagemMenu = "stratagem_menu"
    }
}
