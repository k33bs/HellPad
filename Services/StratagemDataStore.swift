import AppKit
import Combine
import CryptoKit
import Foundation
import os.log

private let logger = Logger(subsystem: "com.hellpad.app", category: "stratagem-data")

// MARK: - DataVersion

/// numeric semver-ish version parsed from tags like "v1.0.10". compares component-wise so
/// v1.0.10 > v1.0.9; a shorter version is padded with zeros so "1.0" == "v1.0.0".
struct DataVersion: Comparable, Sendable, CustomStringConvertible {
    let components: [Int]

    init?(_ string: String) {
        var s = string.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") || s.hasPrefix("V") { s.removeFirst() }
        let parts = s.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard !parts.isEmpty, !parts.contains(nil) else { return nil }
        components = parts.compactMap { $0 }
    }

    var description: String { "v" + components.map(String.init).joined(separator: ".") }

    static func < (a: DataVersion, b: DataVersion) -> Bool {
        let n = max(a.components.count, b.components.count)
        for i in 0..<n {
            let x = i < a.components.count ? a.components[i] : 0
            let y = i < b.components.count ? b.components[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    static func == (a: DataVersion, b: DataVersion) -> Bool { !(a < b) && !(b < a) }
}

// MARK: - StratagemDataStore

/// owns the on-disk stratagem data: the extracted `stratagems/` dir that the app reads from,
/// plus the kept zips used for rollback. all functions are synchronous and file-system only.
enum StratagemDataStore {
    enum StoreError: LocalizedError {
        case bundledZipMissing
        case unzipFailed(Int32)
        case invalidArchive(String)
        case noPreviousVersion

        var errorDescription: String? {
            switch self {
            case .bundledZipMissing: return "Bundled stratagems.zip is missing from the app."
            case .unzipFailed(let code): return "unzip exited with status \(code)."
            case .invalidArchive(let why): return "Archive is not a stratagem release: \(why)."
            case .noPreviousVersion: return "No previous stratagem data to revert to."
            }
        }
    }

    // ~/Library/Application Support/HellPad — same folder StratagemManager uses for user_data.json
    static let appSupportDirectory: URL = FileManager.default
        .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent(HBConstants.appName, isDirectory: true)

    static var dataDirectory: URL { appSupportDirectory.appendingPathComponent("stratagems", isDirectory: true) }
    static var stratagemsJSONURL: URL { dataDirectory.appendingPathComponent("stratagems.json") }
    static func iconURL(slug: String) -> URL {
        dataDirectory.appendingPathComponent("icons", isDirectory: true).appendingPathComponent("\(slug).png")
    }

    static var currentZipURL: URL { appSupportDirectory.appendingPathComponent("stratagems.zip") }
    static var previousZipURL: URL { appSupportDirectory.appendingPathComponent("stratagems.previous.zip") }
    static var bundledZipURL: URL? { Bundle.main.url(forResource: "stratagems", withExtension: "zip") }

    // constant is under our control and asserted by runSelfChecks(); a malformed value is a build bug
    static let bundledVersion: DataVersion = {
        guard let v = DataVersion(HBConstants.StratagemData.bundledVersion) else {
            fatalError("HBConstants.StratagemData.bundledVersion is not a valid version string")
        }
        return v
    }()

    private static var versionFileURL: URL { dataDirectory.appendingPathComponent("VERSION") }
    private static func sidecar(_ zip: URL) -> URL { zip.appendingPathExtension("version") }
    private static func readVersion(_ url: URL) -> DataVersion? {
        (try? String(contentsOf: url, encoding: .utf8)).flatMap(DataVersion.init)
    }

    /// nil when VERSION, stratagems.json or icons/ is missing — a half-written dir reads as "nothing installed"
    static var installedVersion: DataVersion? {
        let fm = FileManager.default
        guard fm.fileExists(atPath: stratagemsJSONURL.path),
              fm.fileExists(atPath: dataDirectory.appendingPathComponent("icons").path) else { return nil }
        return readVersion(versionFileURL)
    }

    /// the kept previous zip's version, if one exists
    private static var keptPreviousVersion: DataVersion? {
        guard FileManager.default.fileExists(atPath: previousZipURL.path) else { return nil }
        return readVersion(sidecar(previousZipURL))
    }

    /// what revertToPrevious() would install: the kept previous zip, else the bundle whenever the
    /// installed data isn't the bundle. the bundle is the one source we never copy, so "no kept
    /// zip but not on the bundle" always means the bundle is what we came from.
    static var previousVersion: DataVersion? {
        if let kept = keptPreviousVersion { return kept }
        if let installed = installedVersion, installed != bundledVersion { return bundledVersion }
        return nil
    }

    static var previousIsBundle: Bool { keptPreviousVersion == nil && previousVersion != nil }

    // MARK: install

    /// installs the bundled zip when nothing is installed or the bundle is newer than what is
    static func seedIfNeeded() throws {
        if let installed = installedVersion, installed >= bundledVersion { return }
        logger.info("Seeding stratagem data \(bundledVersion.description) from bundle (installed: \(installedVersion?.description ?? "none"))")
        try installBundled()
    }

    /// bundle is always available, so it is never kept as `stratagems.zip`; whatever was current
    /// becomes previous so the user can revert to it
    static func installBundled() throws {
        guard let zip = bundledZipURL else { throw StoreError.bundledZipMissing }
        try install(zipURL: zip, version: bundledVersion)
        try rotateCurrentToPrevious()
        // a kept zip older than the bundle is a trap: reverting to it would be undone by the next
        // launch's seedIfNeeded. this happens when an app update ships a newer bundle over a download.
        for zipURL in [currentZipURL, previousZipURL] {
            if let v = readVersion(sidecar(zipURL)), v < bundledVersion {
                try? FileManager.default.removeItem(at: zipURL)
                try? FileManager.default.removeItem(at: sidecar(zipURL))
            }
        }
    }

    static func installDownloaded(zipURL: URL, version: DataVersion) throws {
        try install(zipURL: zipURL, version: version)
        try rotateCurrentToPrevious()
        try keepAsCurrent(zipURL, version: version)
    }

    /// reinstalls stratagems.previous.zip, then swaps the two kept zips so the version we just
    /// left becomes "previous" (a second revert goes forward again). when the previous is the
    /// bundle, this is exactly a reset — installBundled already rotates current → previous.
    static func revertToPrevious() throws {
        guard let version = keptPreviousVersion else {
            guard previousIsBundle else { throw StoreError.noPreviousVersion }
            try installBundled()
            return
        }
        try install(zipURL: previousZipURL, version: version)

        let fm = FileManager.default
        let stash = appSupportDirectory.appendingPathComponent("stratagems.swap.zip")
        try? fm.removeItem(at: stash)
        try? fm.removeItem(at: sidecar(stash))
        try fm.moveItem(at: previousZipURL, to: stash)
        try? fm.moveItem(at: sidecar(previousZipURL), to: sidecar(stash))
        if fm.fileExists(atPath: currentZipURL.path) {
            try fm.moveItem(at: currentZipURL, to: previousZipURL)
            try? fm.moveItem(at: sidecar(currentZipURL), to: sidecar(previousZipURL))
        }
        try fm.moveItem(at: stash, to: currentZipURL)
        try? fm.moveItem(at: sidecar(stash), to: sidecar(currentZipURL))
    }

    /// unzip → validate → atomic swap → VERSION last. throws leave the installed data untouched.
    private static func install(zipURL: URL, version: DataVersion) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: appSupportDirectory, withIntermediateDirectories: true)
        // temp dir lives next to the target so the swap never crosses volumes
        let tmp = appSupportDirectory.appendingPathComponent("stratagems.tmp-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        // ponytail: /usr/bin/unzip instead of a zip library — no Foundation zip API, app isn't sandboxed
        let unzip = Process()
        unzip.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        unzip.arguments = ["-o", "-q", zipURL.path, "-d", tmp.path]
        unzip.standardOutput = FileHandle.nullDevice
        unzip.standardError = FileHandle.nullDevice
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else { throw StoreError.unzipFailed(unzip.terminationStatus) }

        // validate before touching the live dir — this is the trust boundary for downloaded archives
        let json = tmp.appendingPathComponent("stratagems.json")
        guard let data = try? Data(contentsOf: json),
              let list = try? JSONDecoder().decode([Stratagem].self, from: data), !list.isEmpty else {
            throw StoreError.invalidArchive("stratagems.json missing or undecodable")
        }
        let icons = tmp.appendingPathComponent("icons")
        guard let entries = try? fm.contentsOfDirectory(atPath: icons.path),
              entries.contains(where: { $0.hasSuffix(".png") }) else {
            throw StoreError.invalidArchive("icons/ missing or empty")
        }
        try? fm.removeItem(at: tmp.appendingPathComponent("viewer.html"))

        if fm.fileExists(atPath: dataDirectory.path) {
            _ = try fm.replaceItemAt(dataDirectory, withItemAt: tmp)
        } else {
            try fm.moveItem(at: tmp, to: dataDirectory)
        }
        // VERSION last: a crash before this line leaves a dir that installedVersion rejects → re-seeded next launch
        try version.description.write(to: versionFileURL, atomically: true, encoding: .utf8)
        logger.info("Installed stratagem data \(version.description) (\(list.count) stratagems)")
    }

    private static func rotateCurrentToPrevious() throws {
        let fm = FileManager.default
        try? fm.removeItem(at: previousZipURL)
        try? fm.removeItem(at: sidecar(previousZipURL))
        guard fm.fileExists(atPath: currentZipURL.path) else { return }
        try fm.moveItem(at: currentZipURL, to: previousZipURL)
        try? fm.moveItem(at: sidecar(currentZipURL), to: sidecar(previousZipURL))
    }

    private static func keepAsCurrent(_ zip: URL, version: DataVersion) throws {
        let fm = FileManager.default
        try? fm.removeItem(at: currentZipURL)
        try fm.copyItem(at: zip, to: currentZipURL)
        try version.description.write(to: sidecar(currentZipURL), atomically: true, encoding: .utf8)
    }
}

// MARK: - StratagemRelease

/// one GitHub release of the generator repo, reduced to what the app needs
struct StratagemRelease: Sendable {
    let version: DataVersion
    let tag: String
    let notes: String
    let assetURL: URL
    let sha256: String?

    enum ParseError: LocalizedError {
        case badTag(String), noAsset
        var errorDescription: String? {
            switch self {
            case .badTag(let t): return "Release tag \"\(t)\" is not a version."
            case .noAsset: return "Release has no \(HBConstants.StratagemData.assetPrefix)*.zip asset."
            }
        }
    }

    private struct GitHubRelease: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: URL
        }
        let tag_name: String
        let body: String?
        let assets: [Asset]
    }

    static func parse(_ data: Data) throws -> StratagemRelease {
        let gh = try JSONDecoder().decode(GitHubRelease.self, from: data)
        guard let version = DataVersion(gh.tag_name) else { throw ParseError.badTag(gh.tag_name) }
        guard let asset = gh.assets.first(where: {
            $0.name.hasPrefix(HBConstants.StratagemData.assetPrefix) && $0.name.hasSuffix(".zip")
        }) else { throw ParseError.noAsset }
        let body = gh.body ?? ""
        let sha = body.range(of: "[0-9a-f]{64}", options: .regularExpression).map { String(body[$0]) }
        return StratagemRelease(version: version, tag: gh.tag_name, notes: body, assetURL: asset.browser_download_url, sha256: sha)
    }

    /// plain text for display: drops the SHA256 section, strips `#` headings and `**` bold markers
    var displayNotes: String {
        let cut = notes.range(of: "### SHA256").map { String(notes[..<$0.lowerBound]) } ?? notes
        return cut
            .components(separatedBy: "\n")
            .map { line -> String in
                var l = Substring(line)
                while l.hasPrefix("#") { l.removeFirst() }
                return l.replacingOccurrences(of: "**", with: "").trimmingCharacters(in: .whitespaces)
            }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - StratagemDataController

/// glue between the store, the network and the UI (startup prompt + Settings › Data tab).
/// file/network work runs off the main actor; published state is written on it.
@MainActor
final class StratagemDataController: ObservableObject {
    enum NetError: LocalizedError {
        case httpStatus(Int), tooLarge(Int), checksumMismatch, relaunchFailed(String)
        var errorDescription: String? {
            switch self {
            case .httpStatus(let c): return "GitHub returned HTTP \(c)."
            case .tooLarge(let n): return "Download is \(n / 1_000_000) MB, over the \(HBConstants.StratagemData.maxDownloadBytes / 1_000_000) MB limit."
            case .checksumMismatch: return "Downloaded file does not match the release SHA256."
            case .relaunchFailed(let why): return "Data installed, but relaunch failed (\(why)). Quit and reopen HellPad."
            }
        }
    }

    @Published private(set) var installedVersion: DataVersion?
    @Published private(set) var previousVersion: DataVersion?
    @Published private(set) var previousIsBundle = false
    @Published private(set) var availableRelease: StratagemRelease?
    @Published private(set) var status = ""
    @Published private(set) var isBusy = false
    let bundledVersion = StratagemDataStore.bundledVersion

    init() {
        refreshVersions()
    }

    func refreshVersions() {
        installedVersion = StratagemDataStore.installedVersion
        previousVersion = StratagemDataStore.previousVersion
        previousIsBundle = StratagemDataStore.previousIsBundle
    }

    /// returns the release when it is newer than what is installed, nil otherwise (including on error)
    func checkForUpdate() async -> StratagemRelease? {
        isBusy = true
        status = "Checking…"
        defer { isBusy = false }
        // seconds in the suffix + a floor on the "Checking…" state so a repeat "Check Now" visibly
        // does something even when the verdict is unchanged (a same-minute stamp looked dead)
        let checked = "· checked \(Date().formatted(date: .omitted, time: .standard))"
        do {
            async let minimumVisible: Void = Task.sleep(nanoseconds: 400_000_000)
            let release = try await Self.fetchLatestRelease()
            _ = try? await minimumVisible
            if let installed = installedVersion, release.version <= installed {
                availableRelease = nil
                status = "Up to date (\(installed.description)) \(checked)"
                return nil
            }
            availableRelease = release
            status = "\(release.version.description) available \(checked)"
            return release
        } catch {
            status = "Check failed: \(error.localizedDescription) \(checked)"
            logger.info("Stratagem update check failed: \(error.localizedDescription)")
            return nil
        }
    }

    func applyUpdate(_ release: StratagemRelease) async throws {
        try await run(label: "Downloading \(release.version.description)…") {
            let zip = try await Self.download(release)
            defer { try? FileManager.default.removeItem(at: zip) }
            try await Task.detached(priority: .userInitiated) {
                try StratagemDataStore.installDownloaded(zipURL: zip, version: release.version)
            }.value
        }
    }

    func revertToPrevious() async throws {
        try await run(label: "Reverting…") {
            try await Task.detached(priority: .userInitiated) { try StratagemDataStore.revertToPrevious() }.value
        }
    }

    func resetToBundled() async throws {
        try await run(label: "Resetting…") {
            try await Task.detached(priority: .userInitiated) { try StratagemDataStore.installBundled() }.value
        }
    }

    /// shared busy/status/relaunch wrapper for the three apply paths
    private func run(label: String, _ work: () async throws -> Void) async throws {
        isBusy = true
        status = label
        do {
            try await work()
        } catch {
            isBusy = false
            status = "Update failed: \(error.localizedDescription)"
            logger.error("Stratagem data operation failed: \(error.localizedDescription)")
            throw error
        }
        refreshVersions()
        status = "Installed \(installedVersion?.description ?? "?") — relaunching"
        relaunch()
    }

    // MARK: network (nonisolated: pure functions, safe to call from any task)

    nonisolated static func fetchLatestRelease() async throws -> StratagemRelease {
        var request = URLRequest(url: HBConstants.StratagemData.releasesAPI, timeoutInterval: 10)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let (data, response) = try await URLSession.shared.data(for: request)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else { throw NetError.httpStatus(code) }
        return try StratagemRelease.parse(data)
    }

    nonisolated static func download(_ release: StratagemRelease) async throws -> URL {
        let (data, response) = try await URLSession.shared.data(from: release.assetURL)
        let code = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard code == 200 else { throw NetError.httpStatus(code) }
        guard data.count <= HBConstants.StratagemData.maxDownloadBytes else { throw NetError.tooLarge(data.count) }
        if let expected = release.sha256 {
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard digest == expected else { throw NetError.checksumMismatch }
        }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("hellpad-stratagems-\(release.tag).zip")
        try data.write(to: url, options: .atomic)
        return url
    }

    /// launches a second instance from the same bundle path (Accessibility grant survives), then quits this one
    private func relaunch() {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, error in
            Task { @MainActor in
                if let error {
                    // keep running on the freshly installed data rather than leaving the user with no app
                    self.isBusy = false
                    self.status = NetError.relaunchFailed(error.localizedDescription).localizedDescription
                    logger.error("Relaunch failed: \(error.localizedDescription)")
                    return
                }
                NSApp.terminate(nil)
            }
        }
    }
}

// MARK: - Debug self-checks

#if DEBUG
extension StratagemDataStore {
    /// the smallest runnable check that fails if version compare, release parsing or note stripping break
    static func runSelfChecks() {
        assert(DataVersion("v1.0.10")! > DataVersion("v1.0.9")!)
        assert(DataVersion("1.0") == DataVersion("v1.0.0"))
        assert(DataVersion("x") == nil && DataVersion("") == nil)
        assert(DataVersion(HBConstants.StratagemData.bundledVersion) != nil)

        let sha = String(repeating: "a", count: 64)
        let fixture = """
        {"tag_name":"v9.9.9","body":"## v9.9.9\\n\\n**New**\\n- Thing\\n\\n### SHA256\\n```\\n\(sha)\\n```","assets":[{"name":"helldivers2-stratagems-v9.9.9.zip","browser_download_url":"https://example.com/x.zip"}]}
        """
        let release = try! StratagemRelease.parse(Data(fixture.utf8))
        assert(release.version == DataVersion("v9.9.9")!)
        assert(release.sha256 == sha)
        assert(release.displayNotes == "v9.9.9\n\nNew\n- Thing")
        logger.debug("StratagemDataStore self-checks passed")
    }
}
#endif
