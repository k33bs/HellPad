import Foundation

struct Stratagem: Codable, Identifiable, Hashable {
    let id = UUID()
    let name: String
    let sequence: [String]
    let category: String

    enum CodingKeys: String, CodingKey {
        case name, sequence, category
    }

    // Category sort order matching in-game grouping
    static let categoryOrder = ["Common", "Objectives", "Offensive", "Supply", "Defense"]

    var categorySortIndex: Int {
        Self.categoryOrder.firstIndex(of: category) ?? 999
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
}

struct Loadout: Codable, Identifiable {
    let id: UUID
    var name: String
    var equippedStratagems: [String]  // 8 stratagem names
    var keybinds: [Keybind]           // 8 slot keybinds

    init(id: UUID = UUID(), name: String, equippedStratagems: [String], keybinds: [Keybind]) {
        self.id = id
        self.name = name
        self.equippedStratagems = equippedStratagems
        self.keybinds = keybinds
    }
}

/// Wrapper for loadout export files (.hellpad)
struct LoadoutExport: Codable {
    let version: String
    let loadouts: [Loadout]

    init(loadouts: [Loadout], version: String = "1.0") {
        self.version = version
        self.loadouts = loadouts
    }
}

struct UserData: Codable {
    var equippedStratagems: [String]
    var keybinds: [Keybind]
    var allowedApps: [String]?  // Optional for backwards compatibility
    var superKey: Keybind?      // Optional for backwards compatibility (default: Control)
    var activationMode: ActivationMode?  // Optional for backwards compatibility (default: hold)
    var directionalKeys: DirectionalKeybinds?  // Optional for backwards compatibility (default: WASD)
    var comboKey: Keybind?      // Optional for backwards compatibility (default: Command)
    var loadoutKey: Keybind?    // Optional for backwards compatibility (default: Option)
    var loadouts: [Loadout]?    // Optional for backwards compatibility
    var activeLoadoutId: String? // UUID as string, nil when no loadout active or dirty
    var hoverPreviewEnabled: Bool?  // Optional for backwards compatibility (default: true)
    var voiceFeedbackEnabled: Bool?  // Optional for backwards compatibility (default: false)
    var selectedVoice: String?  // Voice identifier for TTS (nil = system default)
    var voiceVolume: Float?  // 0.0 to 1.0 (default: 0.5)
    var recentStratagemNames: [String]?  // Optional for backwards compatibility

    enum CodingKeys: String, CodingKey {
        case equippedStratagems = "equipped_stratagems"
        case keybinds
        case allowedApps = "allowed_apps"
        case superKey = "super_key"
        case activationMode = "activation_mode"
        case directionalKeys = "directional_keys"
        case comboKey = "combo_key"
        case loadoutKey = "loadout_key"
        case loadouts
        case activeLoadoutId = "active_loadout_id"
        case hoverPreviewEnabled = "hover_preview_enabled"
        case voiceFeedbackEnabled = "voice_feedback_enabled"
        case selectedVoice = "selected_voice"
        case voiceVolume = "voice_volume"
        case recentStratagemNames = "recent_stratagem_names"
    }
}
