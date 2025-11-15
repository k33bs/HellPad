# HellPad

A native macOS application for executing HELLDIVERS™ 2 stratagems via customizable hotkeys. Perfect for cloud gaming services like Boosteroid where controller input isn't available.

## Screenshots

|                   Main Interface                   |                   Stratagem Picker                   |                   Combo Mode                   |
| :------------------------------------------------: | :--------------------------------------------------: | :--------------------------------------------: |
| ![Default](.github/images/hellpad_app_default.jpg) | ![Picker](.github/images/hellpad_app_stratagems.jpg) | ![Combo](.github/images/hellpad_app_combo.jpg) |

### App Settings

![Configure Active Apps](.github/images/hellpad_app_settings.jpg)

## Features

- **8 Customizable Stratagem Slots** - Assign any stratagem to any slot
- **Global Hotkeys** - Trigger stratagems from anywhere (T, Y, H, N, U, J, M, K)
- **Combo Mode** - Hold Shift and press multiple keys to queue stratagems, release to execute sequentially
- **Smart Detection** - Only works when your configured apps are active (prevents accidental triggers)
- **Pause/Resume** - Ctrl+P to temporarily disable hotkeys
- **Rebindable Keys** - Change any hotkey to your preference
- **Visual Feedback** - Yellow flash on activation, cyan glow for queued combos
- **Menu Bar App** - Stays out of your way with floating window option

## System Requirements

- **macOS 13.0 or later**
- **Xcode 15+** (for building from source)
- **Accessibility permissions** (required for global hotkeys)

## Installation

### Download Pre-Built App

1. Download the latest `HellPad-v1.0.1.zip` from [Releases](https://github.com/k33bs/HellPad/releases)
2. Unzip and move HellPad.app to your Applications folder
3. **Important:** Right-click HellPad.app → "Open" (first time only)
   - You'll see "unidentified developer" warning
   - Click "Open" to confirm
   - This is normal for unsigned apps
4. Grant Accessibility permissions when prompted

> **Note:** The app is unsigned to protect developer privacy. macOS will warn you on first launch - this is expected for open-source apps.

### Build from Source

1. Clone this repository:

   ```bash
   git clone https://github.com/k33bs/HellPad.git
   cd HellPad
   ```

2. Open `HellPad.xcodeproj` in Xcode

3. Select your development team in Signing & Capabilities

4. Build and run (Cmd+R)

## Usage

### Basic Hotkeys

Press any of the assigned keys (default: T, Y, H, N, U, J, M, K) to execute the corresponding stratagem in-game.

### Combo Mode

1. Hold **Shift**
2. Press keys to queue stratagems (icons glow cyan)
3. Release **Shift** to execute sequence
4. Click mouse when each stratagem appears to throw it (3 second timeout)
5. Press **Shift+ESC** to cancel combo

### Pause/Resume

- **Ctrl+P** - Toggle HellPad on/off (gray overlay when paused)

### Customize Stratagems

- Click any stratagem icon to open the picker
- Select a new stratagem from the grid
- Press ESC or click outside to cancel

### Rebind Keys

- Click any keybind button (T, Y, etc.)
- Press a new key
- Duplicate keys will flash red on the conflicting slot
- Press ESC to cancel

### Configure Active Apps

1. Click menu bar icon
2. Select "Configure Apps..."
3. Add apps where hotkeys should work (e.g., HELLDIVERS™ 2, Chrome, Boosteroid)

## Permissions

HellPad requires **Accessibility** permissions to:

- Monitor global keyboard input
- Simulate keypresses for stratagem execution

Grant permissions in:
`System Settings > Privacy & Security > Accessibility`

## Technical Details

- **Built with:** Swift, SwiftUI, AppKit
- **Hotkey System:** CGEventTap for conditional key monitoring
- **Combo Execution:** Serial queue with semaphore-based mouse click detection
- **Thread-Safe:** Proper locking for all shared state
- **Logging:** OSLog for debugging (viewable in Console.app)

## Development

### Architecture

- `Services/` - Core logic (StratagemManager, EventTapManager, KeyPressSimulator)
- `Views/` - SwiftUI views (ContentView, StratagemPickerView, AppSettingsView)
- `Models/` - Data structures (Stratagem, Keybind, UserData)
- `Utils/` - Constants and helpers
- `Extensions/` - NSImage extensions for icon loading

### Building

1. Ensure **App Sandbox is disabled** in project settings
2. **Hardened Runtime** should be enabled
3. Code sign with your developer certificate

## Contributing

Contributions are welcome! Please feel free to submit pull requests or open issues for bugs and feature requests.

## License

This project is licensed under the GNU General Public License v3.0 - see the [LICENSE](LICENSE) file for details.

## Credits

**Inspired by:** [HellBuddy](https://github.com/chris-codes1/HellBuddy) by chris-codes1 - This is the original Windows application that inspired this port.

**Stratagem Icons:** [Helldivers-2-Stratagems-icons-svg](https://github.com/nvigneux/Helldivers-2-Stratagems-icons-svg) by Nicolas Vigneux

Developed for the HELLDIVERS™ 2 community.

---

**Not affiliated with or endorsed by Arrowhead Game Studios or Sony Interactive Entertainment.**
