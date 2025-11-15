import SwiftUI
import AppKit

struct AppSettingsView: View {
    @ObservedObject var stratagemManager: StratagemManager
    @State private var runningApps: [RunningApp] = []
    var closeAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Configure Active Apps")
                .font(.headline)

            Text("Hotkeys will only work when these apps are active:")
                .font(.caption)
                .foregroundColor(.secondary)

            HStack(spacing: 16) {
                // Left side: Currently allowed apps
                VStack(alignment: .leading, spacing: 8) {
                    Text("Allowed Apps")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    List {
                        ForEach(stratagemManager.allowedApps, id: \.self) { appName in
                            HStack {
                                Text(appName)
                                Spacer()
                                Button(action: {
                                    stratagemManager.allowedApps.removeAll { $0 == appName }
                                    saveSettings()
                                }) {
                                    Image(systemName: "minus.circle.fill")
                                        .foregroundColor(.red)
                                }
                                .buttonStyle(PlainButtonStyle())
                            }
                        }
                    }
                }

                Divider()

                // Right side: Running apps selector
                VStack(alignment: .leading, spacing: 8) {
                    Text("Running Apps")
                        .font(.subheadline)
                        .fontWeight(.medium)

                    List {
                        ForEach(runningApps, id: \.name) { app in
                            HStack {
                                if let icon = app.icon {
                                    Image(nsImage: icon)
                                        .resizable()
                                        .frame(width: 16, height: 16)
                                }
                                Text(app.name)
                                Spacer()
                                Button(action: {
                                    if !stratagemManager.allowedApps.contains(app.name) {
                                        stratagemManager.allowedApps.append(app.name)
                                        saveSettings()
                                    }
                                }) {
                                    Image(systemName: "plus.circle.fill")
                                        .foregroundColor(.green)
                                }
                                .buttonStyle(PlainButtonStyle())
                                .disabled(stratagemManager.allowedApps.contains(app.name))
                            }
                        }
                    }

                    Button("Refresh") {
                        loadRunningApps()
                    }
                }
            }

            HStack {
                Spacer()
                Button("Done") {
                    closeAction()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 600, height: 400)
        .onAppear {
            loadRunningApps()
        }
    }

    private func loadRunningApps() {
        let workspace = NSWorkspace.shared
        runningApps = workspace.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app in
                guard let name = app.localizedName else { return nil }
                return RunningApp(name: name, icon: app.icon)
            }
            .sorted { $0.name < $1.name }
    }

    private func saveSettings() {
        // Trigger save by calling private method through reflection or use a public method
        // For now, we'll add a public save method to StratagemManager
        stratagemManager.saveAllSettings()
    }
}

struct RunningApp {
    let name: String
    let icon: NSImage?
}
