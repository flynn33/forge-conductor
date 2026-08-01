// ManagerInstaller.swift
// What: Installs and controls the per-user LaunchAgent manager integration.
// How: It stages the executable/framework/app layout, writes validated launchd metadata,
// loads or unloads the agent, and verifies runtime state through native process APIs.
// Why: Persistent service ownership needs one transactional, repeatable installation module.

import Foundation
import Darwin
import Security

enum ManagerArtifactKind: Equatable {
    case executable
    case framework
    case applicationBundle
}

protocol ManagerArtifactValidating {
    func prepareAndSign(_ url: URL, kind: ManagerArtifactKind) throws
    func verify(_ url: URL, kind: ManagerArtifactKind) throws
}

protocol ManagerArtifactCopying {
    func copyItem(at source: URL, to destination: URL) throws
}

protocol ManagerArtifactReplacing {
    func applyReplacement(
        target: URL,
        staged: URL?,
        backup: URL,
        hadOriginal: Bool
    ) throws
}

enum ManagerArtifactSignatureState: Equatable {
    case valid
    case unsigned
    case invalidAdHoc
    case invalidCMS
    case indeterminate
}

struct ManagerArtifactSignatureInspection: Equatable {
    var state: ManagerArtifactSignatureState
    var identifier: String?
    var validationStatus: OSStatus
}

protocol ManagerCodeSignatureInspecting {
    func inspect(_ url: URL, kind: ManagerArtifactKind) throws
        -> ManagerArtifactSignatureInspection
}

struct SecurityManagerCodeSignatureInspector: ManagerCodeSignatureInspecting {
    func inspect(
        _ url: URL,
        kind: ManagerArtifactKind
    ) throws -> ManagerArtifactSignatureInspection {
        var staticCode: SecStaticCode?
        let createStatus = SecStaticCodeCreateWithPath(
            url.standardizedFileURL as CFURL,
            [],
            &staticCode
        )
        guard createStatus == errSecSuccess, let staticCode else {
            throw inspectionError(
                url: url,
                operation: "create static-code reference",
                status: createStatus
            )
        }

        var validationFlags = SecCSFlags(
            rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate
        )
        validationFlags.formUnion(.noNetworkAccess)
        if kind != .executable {
            validationFlags.formUnion(SecCSFlags(rawValue: kSecCSCheckNestedCode))
        }

        let validationStatus = SecStaticCodeCheckValidity(
            staticCode,
            validationFlags,
            nil
        )
        if validationStatus == errSecSuccess {
            return ManagerArtifactSignatureInspection(
                state: .valid,
                identifier: nil,
                validationStatus: validationStatus
            )
        }

        var rawInformation: CFDictionary?
        let informationStatus = SecCodeCopySigningInformation(
            staticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation),
            &rawInformation
        )
        guard informationStatus == errSecSuccess,
              let information = rawInformation as? [CFString: Any] else {
            throw inspectionError(
                url: url,
                operation: "read signature metadata after validation failure",
                status: informationStatus
            )
        }

        let identifier = information[kSecCodeInfoIdentifier] as? String
        let flagsNumber = information[kSecCodeInfoFlags] as? NSNumber
        let certificates = information[kSecCodeInfoCertificates] as? [Any]
        let cms = information[kSecCodeInfoCMS] as? Data
        let hasCMSIdentity = !(certificates?.isEmpty ?? true) || !(cms?.isEmpty ?? true)

        let state: ManagerArtifactSignatureState
        if hasCMSIdentity {
            state = .invalidCMS
        } else if validationStatus == errSecCSUnsigned, identifier == nil {
            state = .unsigned
        } else if let flagsNumber {
            let flags = SecCodeSignatureFlags(rawValue: flagsNumber.uint32Value)
            state = flags.contains(.adhoc) ? .invalidAdHoc : .indeterminate
        } else {
            state = .indeterminate
        }

        return ManagerArtifactSignatureInspection(
            state: state,
            identifier: identifier,
            validationStatus: validationStatus
        )
    }

    private func inspectionError(
        url: URL,
        operation: String,
        status: OSStatus
    ) -> Error {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "unknown Security error"
        return NSError(
            domain: "ManagerInstaller",
            code: 9,
            userInfo: [NSLocalizedDescriptionKey:
                "Cannot \(operation) for \(url.path) (Security \(status)): \(detail)"]
        )
    }
}

private struct FileManagerArtifactCopier: ManagerArtifactCopying {
    func copyItem(at source: URL, to destination: URL) throws {
        try FileManager.default.copyItem(at: source, to: destination)
    }
}

private struct FileManagerArtifactReplacer: ManagerArtifactReplacing {
    func applyReplacement(
        target: URL,
        staged: URL?,
        backup: URL,
        hadOriginal: Bool
    ) throws {
        let fm = FileManager.default
        if let staged {
            if hadOriginal {
                if (try? fm.destinationOfSymbolicLink(atPath: target.path)) != nil {
                    try fm.moveItem(at: target, to: backup)
                    try fm.moveItem(at: staged, to: target)
                } else {
                    _ = try fm.replaceItemAt(
                        target,
                        withItemAt: staged,
                        backupItemName: backup.lastPathComponent,
                        options: [.usingNewMetadataOnly, .withoutDeletingBackupItem]
                    )
                }
            } else {
                try fm.moveItem(at: staged, to: target)
            }
        } else if hadOriginal {
            try fm.moveItem(at: target, to: backup)
        }
    }
}

struct CodesignManagerArtifactValidator: ManagerArtifactValidating {
    private let runner: ProcessRunner
    private let signatureInspector: any ManagerCodeSignatureInspecting

    init(
        runner: ProcessRunner = ProcessRunner(),
        signatureInspector: any ManagerCodeSignatureInspecting =
            SecurityManagerCodeSignatureInspector()
    ) {
        self.runner = runner
        self.signatureInspector = signatureInspector
    }

    func prepareAndSign(_ url: URL, kind: ManagerArtifactKind) throws {
        let inspection = try signatureInspector.inspect(url, kind: kind)
        switch inspection.state {
        case .valid:
            break
        case .unsigned, .invalidAdHoc:
            break
        case .invalidCMS:
            throw signatureRefusalError(
                url: url,
                inspection: inspection,
                reason: "invalid CMS/team signature"
            )
        case .indeterminate:
            throw signatureRefusalError(
                url: url,
                inspection: inspection,
                reason: "indeterminate signature metadata"
            )
        }

        try runRequired(
            executable: "/usr/bin/xattr",
            arguments: ["-cr", url.path],
            timeoutSec: 10,
            operation: "clear quarantine"
        )

        guard inspection.state != .valid else {
            return
        }

        // Sign only the requested top-level artifact. Nested code must already carry
        // a valid identity; recursively replacing nested signatures would erase Team IDs.
        let identifier = fallbackIdentifier(
            for: url,
            kind: kind,
            inspectedIdentifier: inspection.identifier
        )
        let signArguments = [
            "--force",
            "--sign", "-",
            "--timestamp=none",
            "--options", "runtime",
            "--identifier", identifier,
            "--preserve-metadata=identifier,entitlements",
            url.path,
        ]
        try runRequired(
            executable: "/usr/bin/codesign",
            arguments: signArguments,
            timeoutSec: kind == .applicationBundle ? 60 : 30,
            operation: "sign \(kind.description)"
        )
    }

    func verify(_ url: URL, kind: ManagerArtifactKind) throws {
        var verifyArguments = ["--verify", "--strict"]
        if kind != .executable {
            verifyArguments.append("--deep")
        }
        verifyArguments.append(url.path)
        try runRequired(
            executable: "/usr/bin/codesign",
            arguments: verifyArguments,
            timeoutSec: kind == .applicationBundle ? 60 : 30,
            operation: "verify \(kind.description)"
        )
    }

    private func fallbackIdentifier(
        for url: URL,
        kind: ManagerArtifactKind,
        inspectedIdentifier: String?
    ) -> String {
        if let inspectedIdentifier,
           !inspectedIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return inspectedIdentifier
        }

        switch kind {
        case .executable:
            return "com.forge-conductor.cli"
        case .framework:
            return bundleIdentifier(at: url) ?? "com.forge-conductor.core"
        case .applicationBundle:
            return bundleIdentifier(at: url) ?? ManagerInstaller.bundleIdentifier
        }
    }

    private func bundleIdentifier(at url: URL) -> String? {
        guard let value = Bundle(url: url)?.bundleIdentifier?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }

    private func signatureRefusalError(
        url: URL,
        inspection: ManagerArtifactSignatureInspection,
        reason: String
    ) -> Error {
        let detail = SecCopyErrorMessageString(inspection.validationStatus, nil) as String?
            ?? "unknown Security error"
        let identifier = inspection.identifier ?? "(unavailable)"
        return NSError(
            domain: "ManagerInstaller",
            code: 10,
            userInfo: [NSLocalizedDescriptionKey:
                "Refusing to replace \(reason) for \(url.path). "
                + "identifier=\(identifier), Security \(inspection.validationStatus): \(detail)"]
        )
    }

    private func runRequired(
        executable: String,
        arguments: [String],
        timeoutSec: TimeInterval,
        operation: String
    ) throws {
        let result = try runner.run(
            executable: executable,
            arguments: arguments,
            timeoutSec: timeoutSec
        )
        guard result.exitCode == 0, !result.timedOut else {
            let detail = result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "ManagerInstaller",
                code: 7,
                userInfo: [NSLocalizedDescriptionKey:
                    "\(operation) failed for \(arguments.last ?? "artifact") "
                    + "(exit \(result.exitCode)): \(detail)"]
            )
        }
    }
}

private extension ManagerArtifactKind {
    var description: String {
        switch self {
        case .executable: "manager executable"
        case .framework: "manager framework"
        case .applicationBundle: "manager app bundle"
        }
    }
}

/// Installs the manager binary, a proper macOS app bundle (for Login Items naming),
/// LaunchAgent, cleanup of stale legacy agents, and endpoint-protection guidance.
public final class ManagerInstaller: @unchecked Sendable {
    public static let launchAgentLabel = "com.forge-conductor.manager"
    public static let bundleIdentifier = "com.forge-conductor.app"
    public static let appDisplayName = "Forge Conductor"
    public static let preferredBinaryName = "forge-conductor"

    /// Legacy Python/bash LaunchAgents that show as "bash" / "python3" in Login Items.
    public static let staleLaunchAgentLabels = [
        "com.forge.orchestrator",
        "com.forge.telemetry",
        "com.forge.watchdog",
    ]

    public let paths: AppPaths
    public let config: ConfigStore
    private let artifactValidator: any ManagerArtifactValidating
    private let artifactCopier: any ManagerArtifactCopying
    private let artifactReplacer: any ManagerArtifactReplacing

    public init(paths: AppPaths, config: ConfigStore) {
        self.paths = paths
        self.config = config
        self.artifactValidator = CodesignManagerArtifactValidator()
        self.artifactCopier = FileManagerArtifactCopier()
        self.artifactReplacer = FileManagerArtifactReplacer()
    }

    init(
        paths: AppPaths,
        config: ConfigStore,
        artifactValidator: any ManagerArtifactValidating,
        artifactCopier: any ManagerArtifactCopying = FileManagerArtifactCopier(),
        artifactReplacer: any ManagerArtifactReplacing = FileManagerArtifactReplacer()
    ) {
        self.paths = paths
        self.config = config
        self.artifactValidator = artifactValidator
        self.artifactCopier = artifactCopier
        self.artifactReplacer = artifactReplacer
    }

    public convenience init(app: ForgeApp) {
        self.init(paths: app.paths, config: app.config)
    }

    // MARK: - Paths

    public var installedBinaryURL: URL {
        paths.home.appendingPathComponent("bin", isDirectory: true)
            .appendingPathComponent(Self.preferredBinaryName)
    }

    /// App bundle so Login Items shows "Forge Conductor" instead of "bash".
    public var appBundleURL: URL {
        paths.home.appendingPathComponent("\(Self.appDisplayName).app", isDirectory: true)
    }

    public var appExecutableURL: URL {
        appBundleURL
            .appendingPathComponent("Contents", isDirectory: true)
            .appendingPathComponent("MacOS", isDirectory: true)
            .appendingPathComponent(Self.appDisplayName)
    }

    public var launchAgentURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(Self.launchAgentLabel).plist")
    }

    public var launchAgentsDir: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    var launchAgentStandardOutputURL: URL {
        paths.logsDir.appendingPathComponent("launchd-manager.out.log")
    }

    var launchAgentStandardErrorURL: URL {
        paths.logsDir.appendingPathComponent("launchd-manager.err.log")
    }

    // MARK: - Binary install

    @discardableResult
    public func installBinary(from source: URL? = nil) throws -> URL {
        let src = try (source ?? Self.currentExecutableURL()).resolvingSymlinksInPath()
        let commandLink = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin", isDirectory: true)
            .appendingPathComponent("forge-conductor-swift")
        let dest = try stageInstalledArtifacts(from: src, commandLink: commandLink)

        // LM Studio registration is explicit only (install-lmstudio-plugin / GUI Install Plugin).
        // Never mutate ~/.lmstudio as a side effect of copying the binary.
        return dest
    }

    /// Refreshes only Forge-home artifacts. This is the isolated staging seam used before
    /// launchd changes and by tests that must not touch the user's LaunchAgents or command links.
    @discardableResult
    func stageInstalledArtifacts(
        from sourceExecutable: URL,
        commandLink: URL? = nil
    ) throws -> URL {
        try paths.ensureLayout()
        let fm = FileManager.default
        let binDir = paths.home.appendingPathComponent("bin", isDirectory: true)
        let libDir = paths.home.appendingPathComponent("lib", isDirectory: true)
        try fm.createDirectory(at: binDir, withIntermediateDirectories: true)
        try fm.createDirectory(at: libDir, withIntermediateDirectories: true)

        let src = sourceExecutable.resolvingSymlinksInPath()
        guard fm.isExecutableFile(atPath: src.path) else {
            throw NSError(
                domain: "ManagerInstaller",
                code: 4,
                userInfo: [NSLocalizedDescriptionKey: "Source executable is missing or not executable: \(src.path)"]
            )
        }

        let transactionID = UUID().uuidString
        let binaryTarget = installedBinaryURL.standardizedFileURL
        let binaryStage = temporarySibling(
            of: binaryTarget,
            marker: "stage",
            transactionID: transactionID
        )
        let frameworkTarget = binDir.appendingPathComponent("ForgeConductorCore.framework")
        let mirroredFrameworkTarget = libDir.appendingPathComponent("ForgeConductorCore.framework")
        let appTarget = appBundleURL.standardizedFileURL
        let commandLinkTarget = commandLink?.standardizedFileURL
        let appStage = temporarySibling(
            of: appTarget,
            marker: "stage",
            transactionID: transactionID
        )
        let sourceFramework = sourceFramework(for: src)
        let frameworkStage = sourceFramework.map { _ in
            temporarySibling(
                of: frameworkTarget,
                marker: "stage",
                transactionID: transactionID
            )
        }
        let mirroredFrameworkStage = sourceFramework.map { _ in
            temporarySibling(
                of: mirroredFrameworkTarget,
                marker: "stage",
                transactionID: transactionID
            )
        }
        let commandLinkStage = commandLinkTarget.map {
            temporarySibling(
                of: $0,
                marker: "stage",
                transactionID: transactionID
            )
        }

        let temporaryURLs = [
            binaryStage,
            frameworkStage,
            mirroredFrameworkStage,
            appStage,
            commandLinkStage,
        ].compactMap { $0 }
        defer {
            for url in temporaryURLs where itemExists(at: url) {
                try? fm.removeItem(at: url)
            }
        }

        try artifactCopier.copyItem(at: src, to: binaryStage)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryStage.path)
        try artifactValidator.prepareAndSign(binaryStage, kind: .executable)
        try artifactValidator.verify(binaryStage, kind: .executable)

        if let sourceFramework, let frameworkStage, let mirroredFrameworkStage {
            try artifactCopier.copyItem(at: sourceFramework, to: frameworkStage)
            try artifactValidator.prepareAndSign(frameworkStage, kind: .framework)
            try artifactValidator.verify(frameworkStage, kind: .framework)
            try artifactCopier.copyItem(at: frameworkStage, to: mirroredFrameworkStage)
            try artifactValidator.prepareAndSign(mirroredFrameworkStage, kind: .framework)
            try artifactValidator.verify(mirroredFrameworkStage, kind: .framework)
        }

        try stageApplicationBundle(
            from: src,
            executable: binaryStage,
            framework: frameworkStage,
            at: appStage
        )

        if let commandLinkTarget, let commandLinkStage {
            try fm.createDirectory(
                at: commandLinkTarget.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try fm.createSymbolicLink(
                at: commandLinkStage,
                withDestinationURL: binaryTarget
            )
        }

        var replacements = [
            ArtifactReplacement(target: frameworkTarget, staged: frameworkStage),
            ArtifactReplacement(target: mirroredFrameworkTarget, staged: mirroredFrameworkStage),
            ArtifactReplacement(target: binaryTarget, staged: binaryStage),
            ArtifactReplacement(target: appTarget, staged: appStage),
        ]
        if let commandLinkTarget {
            replacements.append(
                ArtifactReplacement(target: commandLinkTarget, staged: commandLinkStage)
            )
        }
        try commitArtifactReplacements(replacements, transactionID: transactionID)
        return binaryTarget
    }

    /// Refresh the source application bundle when available, or build a minimal bundle for
    /// standalone CLI executables so Background Items can still show a real product name.
    @discardableResult
    public func installAppBundle(from sourceExecutable: URL? = nil) throws -> URL {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: installedBinaryURL.path) else {
            throw NSError(
                domain: "ManagerInstaller",
                code: 3,
                userInfo: [NSLocalizedDescriptionKey: "Binary not installed at \(installedBinaryURL.path)"]
            )
        }

        try paths.ensureLayout()
        let source = (sourceExecutable ?? installedBinaryURL).resolvingSymlinksInPath()
        let framework = sourceFramework(for: source)
            ?? {
                let installed = installedBinaryURL.deletingLastPathComponent()
                    .appendingPathComponent("ForgeConductorCore.framework")
                return fm.fileExists(atPath: installed.path) ? installed : nil
            }()
        let transactionID = UUID().uuidString
        let stagedApp = temporarySibling(
            of: appBundleURL,
            marker: "stage",
            transactionID: transactionID
        )
        defer {
            if itemExists(at: stagedApp) {
                try? fm.removeItem(at: stagedApp)
            }
        }

        try stageApplicationBundle(
            from: source,
            executable: installedBinaryURL,
            framework: framework,
            at: stagedApp
        )
        try commitArtifactReplacements([
            ArtifactReplacement(target: appBundleURL, staged: stagedApp),
        ], transactionID: transactionID)
        return appBundleURL
    }

    private func stageApplicationBundle(
        from sourceExecutable: URL,
        executable: URL,
        framework: URL?,
        at stagedBundle: URL
    ) throws {
        let fm = FileManager.default
        if let sourceBundle = sourceAppBundle(containing: sourceExecutable) {
            try artifactCopier.copyItem(at: sourceBundle, to: stagedBundle)
        } else {
            try createMinimalAppBundle(
                at: stagedBundle,
                executable: executable,
                framework: framework
            )
        }

        let executableURL = applicationExecutable(in: stagedBundle)
        guard fm.isExecutableFile(atPath: executableURL.path) else {
            throw NSError(
                domain: "ManagerInstaller",
                code: 5,
                userInfo: [NSLocalizedDescriptionKey:
                    "Staged app bundle is missing executable \(executableURL.path)"]
            )
        }
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)
        try artifactValidator.prepareAndSign(stagedBundle, kind: .applicationBundle)
        try artifactValidator.verify(stagedBundle, kind: .applicationBundle)
    }

    private func createMinimalAppBundle(
        at bundleURL: URL,
        executable: URL,
        framework: URL?
    ) throws {
        let fm = FileManager.default
        let contents = bundleURL.appendingPathComponent("Contents", isDirectory: true)
        let macos = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try fm.createDirectory(at: macos, withIntermediateDirectories: true)
        try fm.createDirectory(at: resources, withIntermediateDirectories: true)

        let version = ForgeApp.version
        let infoPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>CFBundleDevelopmentRegion</key>
          <string>en</string>
          <key>CFBundleDisplayName</key>
          <string>\(Self.appDisplayName)</string>
          <key>CFBundleExecutable</key>
          <string>\(Self.appDisplayName)</string>
          <key>CFBundleIdentifier</key>
          <string>\(Self.bundleIdentifier)</string>
          <key>CFBundleInfoDictionaryVersion</key>
          <string>6.0</string>
          <key>CFBundleName</key>
          <string>\(Self.appDisplayName)</string>
          <key>CFBundlePackageType</key>
          <string>APPL</string>
          <key>CFBundleShortVersionString</key>
          <string>\(escapeXML(version))</string>
          <key>CFBundleVersion</key>
          <string>\(escapeXML(version))</string>
          <key>LSMinimumSystemVersion</key>
          <string>26.0</string>
          <key>LSUIElement</key>
          <true/>
          <key>NSHighResolutionCapable</key>
          <true/>
        </dict>
        </plist>
        """
        try infoPlist.write(
            to: contents.appendingPathComponent("Info.plist"),
            atomically: true,
            encoding: .utf8
        )
        try "APPL????".write(
            to: contents.appendingPathComponent("PkgInfo"),
            atomically: true,
            encoding: .utf8
        )

        // Copy binary as the app executable (BTM keys off this path).
        let exe = applicationExecutable(in: bundleURL)
        try artifactCopier.copyItem(at: executable, to: exe)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: exe.path)

        if let framework {
            let frameworks = contents.appendingPathComponent("Frameworks", isDirectory: true)
            try fm.createDirectory(at: frameworks, withIntermediateDirectories: true)
            try artifactCopier.copyItem(
                at: framework,
                to: frameworks.appendingPathComponent(framework.lastPathComponent)
            )
        }
    }

    private func sourceFramework(for sourceExecutable: URL) -> URL? {
        let name = "ForgeConductorCore.framework"
        var candidates: [URL] = []
        if let sourceBundle = sourceAppBundle(containing: sourceExecutable) {
            candidates.append(
                sourceBundle
                    .appendingPathComponent("Contents/Frameworks", isDirectory: true)
                    .appendingPathComponent(name)
            )
        }
        candidates.append(sourceExecutable.deletingLastPathComponent().appendingPathComponent(name))
        candidates.append(
            sourceExecutable.deletingLastPathComponent()
                .appendingPathComponent("PackageFrameworks", isDirectory: true)
                .appendingPathComponent(name)
        )
        return candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) })
    }

    private func applicationExecutable(in bundleURL: URL) -> URL {
        bundleURL
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(Self.appDisplayName)
    }

    private func temporarySibling(
        of target: URL,
        marker: String,
        transactionID: String
    ) -> URL {
        let parent = target.deletingLastPathComponent()
        let pathExtension = target.pathExtension
        let baseName = pathExtension.isEmpty
            ? target.lastPathComponent
            : target.deletingPathExtension().lastPathComponent
        let suffix = pathExtension.isEmpty ? "" : ".\(pathExtension)"
        return parent.appendingPathComponent(
            ".\(baseName).\(marker)-\(transactionID)\(suffix)"
        )
    }

    private struct ArtifactReplacement {
        let target: URL
        let staged: URL?
    }

    private struct CommitRecord {
        let target: URL
        let staged: URL?
        let backup: URL
        let hadOriginal: Bool
    }

    private func commitArtifactReplacements(
        _ replacements: [ArtifactReplacement],
        transactionID: String
    ) throws {
        let fm = FileManager.default
        var records: [CommitRecord] = []

        do {
            for replacement in replacements {
                let backup = temporarySibling(
                    of: replacement.target,
                    marker: "backup",
                    transactionID: transactionID
                )
                let record = CommitRecord(
                    target: replacement.target,
                    staged: replacement.staged,
                    backup: backup,
                    hadOriginal: itemExists(at: replacement.target)
                )
                records.append(record)
                try artifactReplacer.applyReplacement(
                    target: replacement.target,
                    staged: replacement.staged,
                    backup: backup,
                    hadOriginal: record.hadOriginal
                )
            }
        } catch {
            let rollbackFailures = rollbackArtifactReplacements(records.reversed())
            guard rollbackFailures.isEmpty else {
                throw NSError(
                    domain: "ManagerInstaller",
                    code: 8,
                    userInfo: [NSLocalizedDescriptionKey:
                        "Artifact commit failed: \(error.localizedDescription). "
                        + "Rollback failures: \(rollbackFailures.joined(separator: "; "))"]
                )
            }
            throw error
        }

        for record in records where itemExists(at: record.backup) {
            try? fm.removeItem(at: record.backup)
        }
    }

    private func rollbackArtifactReplacements<S: Sequence>(
        _ records: S
    ) -> [String] where S.Element == CommitRecord {
        let fm = FileManager.default
        var failures: [String] = []
        for record in records {
            do {
                if itemExists(at: record.backup) {
                    if itemExists(at: record.target) {
                        try fm.removeItem(at: record.target)
                    }
                    try fm.moveItem(at: record.backup, to: record.target)
                } else if !record.hadOriginal,
                          itemExists(at: record.target),
                          record.staged.map({ !itemExists(at: $0) }) ?? false {
                    try fm.removeItem(at: record.target)
                }
            } catch {
                failures.append("\(record.target.path): \(error.localizedDescription)")
            }
        }
        return failures
    }

    private func itemExists(at url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
            || (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private func sourceAppBundle(containing executable: URL) -> URL? {
        let macOSDirectory = executable.deletingLastPathComponent()
        guard macOSDirectory.lastPathComponent == "MacOS" else { return nil }
        let contents = macOSDirectory.deletingLastPathComponent()
        guard contents.lastPathComponent == "Contents" else { return nil }
        let bundle = contents.deletingLastPathComponent()
        guard bundle.lastPathComponent == "\(Self.appDisplayName).app" else { return nil }
        let expectedExecutable = bundle
            .appendingPathComponent("Contents/MacOS", isDirectory: true)
            .appendingPathComponent(Self.appDisplayName)
        guard expectedExecutable.standardizedFileURL.path == executable.standardizedFileURL.path,
              FileManager.default.isExecutableFile(atPath: expectedExecutable.path) else {
            return nil
        }
        return bundle
    }

    // MARK: - Stale agent cleanup

    /// Unload and remove legacy com.forge.* LaunchAgents (appear as bash/python3 in Login Items).
    @discardableResult
    public func cleanupStaleLaunchAgents() throws -> [[String: Any]] {
        var results: [[String: Any]] = []
        let uid = getuid()

        for label in Self.staleLaunchAgentLabels {
            let plist = launchAgentsDir.appendingPathComponent("\(label).plist")
            var entry: [String: Any] = ["label": label, "plist": plist.path]

            let bootout = try? ProcessRunner().run(
                executable: "/bin/launchctl",
                arguments: ["bootout", "gui/\(uid)/\(label)"],
                timeoutSec: 10
            )
            _ = try? ProcessRunner().run(
                executable: "/bin/launchctl",
                arguments: ["unload", "-w", plist.path],
                timeoutSec: 10
            )
            // disable so it does not come back via enablement
            _ = try? ProcessRunner().run(
                executable: "/bin/launchctl",
                arguments: ["disable", "gui/\(uid)/\(label)"],
                timeoutSec: 5
            )

            var removed = false
            if FileManager.default.fileExists(atPath: plist.path) {
                // Archive instead of hard-delete for rollback
                let archiveDir = paths.home.appendingPathComponent("legacy-launchagents", isDirectory: true)
                try FileManager.default.createDirectory(at: archiveDir, withIntermediateDirectories: true)
                let dest = archiveDir.appendingPathComponent("\(label).plist")
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.moveItem(at: plist, to: dest)
                removed = true
                entry["archived_to"] = dest.path
            }

            entry["bootout_exit"] = bootout?.exitCode as Any
            entry["removed"] = removed
            entry["ok"] = true
            results.append(entry)
        }

        // Do not run `sfltool resetbtm` — it wipes all Background Items for the user.
        // macOS refreshes Login Items after bootout + log out/in.
        return results
    }

    public func listForgeLaunchAgents() -> [[String: Any]] {
        var out: [[String: Any]] = []
        let labels = Self.staleLaunchAgentLabels + [Self.launchAgentLabel]
        for label in labels {
            let plist = launchAgentsDir.appendingPathComponent("\(label).plist")
            let loaded = (try? ProcessRunner().run(
                executable: "/bin/launchctl",
                arguments: ["print", "gui/\(getuid())/\(label)"],
                timeoutSec: 3
            ))?.exitCode == 0
            out.append([
                "label": label,
                "plist_exists": FileManager.default.fileExists(atPath: plist.path),
                "plist": plist.path,
                "loaded": loaded,
                "stale": Self.staleLaunchAgentLabels.contains(label),
            ])
        }
        return out
    }

    // MARK: - Login LaunchAgent

    @discardableResult
    public func installLoginAgent(openBrowser: Bool = false) throws -> URL {
        // Always stage from this process before launchd starts the manager. Reusing an existing
        // executable here can silently keep an older manager and framework running after upgrade.
        _ = try installBinary()

        try FileManager.default.createDirectory(at: launchAgentsDir, withIntermediateDirectories: true)

        let exe = appExecutableURL.path

        var programArgs = [
            exe,
            "manager",
            "run",
            "--home",
            paths.home.path,
        ]
        if openBrowser {
            programArgs.append("--open")
        }

        // AssociatedBundleIdentifiers ties the agent to the .app for Login Items naming.
        let plist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          <string>\(Self.launchAgentLabel)</string>
          <key>ProgramArguments</key>
          <array>
        \(programArgs.map { "    <string>\(escapeXML($0))</string>" }.joined(separator: "\n"))
          </array>
          <key>AssociatedBundleIdentifiers</key>
          <array>
            <string>\(Self.bundleIdentifier)</string>
          </array>
          <key>WorkingDirectory</key>
          <string>\(escapeXML(paths.home.path))</string>
          <key>RunAtLoad</key>
          <true/>
          <key>KeepAlive</key>
          <true/>
          <key>ProcessType</key>
          <string>Interactive</string>
          <key>EnvironmentVariables</key>
          <dict>
            <key>FORGE_CONDUCTOR_HOME</key>
            <string>\(escapeXML(paths.home.path))</string>
            <key>PATH</key>
            <string>/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin:\(escapeXML(paths.home.appendingPathComponent("bin").path))</string>
          </dict>
          <key>StandardOutPath</key>
          <string>\(escapeXML(launchAgentStandardOutputURL.path))</string>
          <key>StandardErrorPath</key>
          <string>\(escapeXML(launchAgentStandardErrorURL.path))</string>
          <key>ThrottleInterval</key>
          <integer>10</integer>
        </dict>
        </plist>
        """
        // Note: ProcessType Interactive helps some Login Items UIs treat it as a user agent.
        let uid = getuid()
        _ = try? ProcessRunner().run(
            executable: "/bin/launchctl",
            arguments: ["bootout", "gui/\(uid)/\(Self.launchAgentLabel)"],
            timeoutSec: 10
        )
        _ = try? ProcessRunner().run(
            executable: "/bin/launchctl",
            arguments: ["unload", launchAgentURL.path],
            timeoutSec: 10
        )

        // launchd owns these descriptors while the agent is loaded. Rotate only after bootout so
        // the replacement process starts with fresh logs and retained failures stay size-bounded.
        try rotateLaunchAgentLogs()
        try plist.write(to: launchAgentURL, atomically: true, encoding: .utf8)

        // Ensure domain enablement
        _ = try? ProcessRunner().run(
            executable: "/bin/launchctl",
            arguments: ["enable", "gui/\(uid)/\(Self.launchAgentLabel)"],
            timeoutSec: 5
        )

        let load = try ProcessRunner().run(
            executable: "/bin/launchctl",
            arguments: ["bootstrap", "gui/\(uid)", launchAgentURL.path],
            timeoutSec: 15
        )
        if load.exitCode != 0 {
            let load2 = try ProcessRunner().run(
                executable: "/bin/launchctl",
                arguments: ["load", "-w", launchAgentURL.path],
                timeoutSec: 15
            )
            if load2.exitCode != 0 {
                throw NSError(
                    domain: "ManagerInstaller",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey:
                        "launchctl load failed: \(load.stderr) \(load2.stderr)"]
                )
            }
        }

        _ = try? ProcessRunner().run(
            executable: "/bin/launchctl",
            arguments: ["kickstart", "-k", "gui/\(uid)/\(Self.launchAgentLabel)"],
            timeoutSec: 10
        )

        return launchAgentURL
    }

    /// Retains a small, fixed number of bounded launchd log tails during reinstall.
    /// This helper only touches files under the configured Forge home. The active launchd
    /// files remain append-only until the next reinstall because launchd owns their descriptors.
    func rotateLaunchAgentLogs(
        maxBytesPerFile: Int = 1_048_576,
        retainedGenerations: Int = 2
    ) throws {
        guard maxBytesPerFile > 0, retainedGenerations > 0 else {
            throw NSError(
                domain: "ManagerInstaller",
                code: 6,
                userInfo: [NSLocalizedDescriptionKey:
                    "Log rotation requires positive size and retention limits"]
            )
        }
        try FileManager.default.createDirectory(at: paths.logsDir, withIntermediateDirectories: true)
        for logURL in [launchAgentStandardOutputURL, launchAgentStandardErrorURL] {
            try rotateLog(
                at: logURL,
                maxBytesPerFile: maxBytesPerFile,
                retainedGenerations: retainedGenerations
            )
        }
    }

    private func rotateLog(
        at logURL: URL,
        maxBytesPerFile: Int,
        retainedGenerations: Int
    ) throws {
        let fm = FileManager.default
        try pruneExcessLogArchives(
            for: logURL,
            retainedGenerations: retainedGenerations
        )
        guard fm.fileExists(atPath: logURL.path) else {
            try boundRetainedLogArchives(
                for: logURL,
                maxBytesPerFile: maxBytesPerFile,
                retainedGenerations: retainedGenerations
            )
            return
        }

        let currentSize = try fileSize(at: logURL)
        guard currentSize > 0 else {
            try fm.removeItem(at: logURL)
            try boundRetainedLogArchives(
                for: logURL,
                maxBytesPerFile: maxBytesPerFile,
                retainedGenerations: retainedGenerations
            )
            return
        }

        if retainedGenerations > 1 {
            for generation in stride(from: retainedGenerations, through: 2, by: -1) {
                let destination = rotatedLogURL(logURL, generation: generation)
                let source = rotatedLogURL(logURL, generation: generation - 1)
                if fm.fileExists(atPath: source.path) {
                    try writeBoundedTail(
                        from: source,
                        to: destination,
                        maxBytes: maxBytesPerFile
                    )
                    try fm.removeItem(at: source)
                } else if fm.fileExists(atPath: destination.path) {
                    try fm.removeItem(at: destination)
                }
            }
        }

        let newestArchive = rotatedLogURL(logURL, generation: 1)
        try writeBoundedTail(from: logURL, to: newestArchive, maxBytes: maxBytesPerFile)
        try fm.removeItem(at: logURL)
    }

    private func pruneExcessLogArchives(
        for logURL: URL,
        retainedGenerations: Int
    ) throws {
        let fm = FileManager.default
        let directory = logURL.deletingLastPathComponent()
        let prefix = "\(logURL.lastPathComponent)."
        let entries = try fm.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasPrefix(prefix),
                  let generation = Int(name.dropFirst(prefix.count)) else {
                continue
            }
            if generation < 1 || generation > retainedGenerations {
                try fm.removeItem(at: entry)
            }
        }
    }

    private func boundRetainedLogArchives(
        for logURL: URL,
        maxBytesPerFile: Int,
        retainedGenerations: Int
    ) throws {
        for generation in 1...retainedGenerations {
            let archive = rotatedLogURL(logURL, generation: generation)
            guard FileManager.default.fileExists(atPath: archive.path),
                  try fileSize(at: archive) > UInt64(maxBytesPerFile) else {
                continue
            }
            let data = try boundedTailData(from: archive, maxBytes: maxBytesPerFile)
            try data.write(to: archive, options: .atomic)
        }
    }

    private func rotatedLogURL(_ logURL: URL, generation: Int) -> URL {
        URL(fileURLWithPath: "\(logURL.path).\(generation)")
    }

    private func fileSize(at url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.size] as? NSNumber)?.uint64Value ?? 0
    }

    private func writeBoundedTail(from source: URL, to destination: URL, maxBytes: Int) throws {
        let data = try boundedTailData(from: source, maxBytes: maxBytes)
        try data.write(to: destination, options: .atomic)
    }

    private func boundedTailData(from source: URL, maxBytes: Int) throws -> Data {
        let size = try fileSize(at: source)
        let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        try handle.seek(toOffset: offset)
        return try handle.read(upToCount: maxBytes) ?? Data()
    }

    @discardableResult
    public func uninstallLoginAgent() throws -> Bool {
        let uid = getuid()
        _ = try? ProcessRunner().run(
            executable: "/bin/launchctl",
            arguments: ["bootout", "gui/\(uid)/\(Self.launchAgentLabel)"],
            timeoutSec: 10
        )
        _ = try? ProcessRunner().run(
            executable: "/bin/launchctl",
            arguments: ["disable", "gui/\(uid)/\(Self.launchAgentLabel)"],
            timeoutSec: 5
        )
        _ = try? ProcessRunner().run(
            executable: "/bin/launchctl",
            arguments: ["unload", "-w", launchAgentURL.path],
            timeoutSec: 10
        )
        if FileManager.default.fileExists(atPath: launchAgentURL.path) {
            try FileManager.default.removeItem(at: launchAgentURL)
            return true
        }
        return false
    }

    public func isLoginAgentInstalled() -> Bool {
        FileManager.default.fileExists(atPath: launchAgentURL.path)
    }

    public func isLoginAgentLoaded() -> Bool {
        let r = try? ProcessRunner().run(
            executable: "/bin/launchctl",
            arguments: ["print", "gui/\(getuid())/\(Self.launchAgentLabel)"],
            timeoutSec: 5
        )
        return (r?.exitCode == 0) && !(r?.stdout.isEmpty ?? true)
    }

    // MARK: - Firewall

    public func tryAllowFirewall() -> [String: Any] {
        var pathsToAllow = [installedBinaryURL.path, appExecutableURL.path]
        pathsToAllow = pathsToAllow.filter { FileManager.default.fileExists(atPath: $0) }
        guard !pathsToAllow.isEmpty else {
            return ["ok": false, "message": "binary not installed"]
        }
        var details: [[String: Any]] = []
        var anyOK = false
        for path in pathsToAllow {
            let blocked = try? ProcessRunner().run(
                executable: "/usr/libexec/ApplicationFirewall/socketfilterfw",
                arguments: ["--getappblocked", path],
                timeoutSec: 5
            )
            let add = try? ProcessRunner().run(
                executable: "/usr/libexec/ApplicationFirewall/socketfilterfw",
                arguments: ["--add", path],
                timeoutSec: 5
            )
            _ = try? ProcessRunner().run(
                executable: "/usr/libexec/ApplicationFirewall/socketfilterfw",
                arguments: ["--unblockapp", path],
                timeoutSec: 5
            )
            let ok = (add?.exitCode == 0) || (blocked?.stdout.contains("permitted") == true)
            if ok { anyOK = true }
            details.append([
                "path": path,
                "ok": ok,
                "getappblocked": blocked?.stdout ?? "",
            ])
        }
        return [
            "ok": anyOK,
            "items": details,
            "note": "On Jamf-managed Macs, firewall changes may require admin or a config profile.",
        ]
    }

    // MARK: - Endpoint protection report

    public func endpointProtectionReport() -> [String: Any] {
        var extensions: [[String: Any]] = []
        // systemextensionsctl can hang indefinitely on managed Macs — hard-cap and skip on failure.
        if let r = try? ProcessRunner().run(
            executable: "/usr/bin/systemextensionsctl",
            arguments: ["list"],
            timeoutSec: 2
        ), r.exitCode == 0 {
            for line in r.stdout.split(separator: "\n").map(String.init) {
                let lower = line.lowercased()
                if lower.contains("endpoint_security") || lower.contains("network_extension")
                    || lower.contains("falcon") || lower.contains("jamf.protect")
                    || lower.contains("traps") || lower.contains("globalprotect")
                    || lower.contains("cortex") {
                    extensions.append(["line": line.trimmingCharacters(in: .whitespaces)])
                }
            }
        }

        let binary = installedBinaryURL.path
        let binaryExists = FileManager.default.isExecutableFile(atPath: binary)
        let legacyLink = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin/forge-conductor").path
        var legacyTarget = ""
        if let t = try? FileManager.default.destinationOfSymbolicLink(atPath: legacyLink) {
            legacyTarget = t
        }

        let port = config.int("dashboard", "port", default: 7788)
        let agents = listForgeLaunchAgents()
        let staleStillPresent = agents.contains {
            ($0["stale"] as? Bool == true) && ($0["plist_exists"] as? Bool == true || $0["loaded"] as? Bool == true)
        }

        return [
            "ok": true,
            "system_extensions_sample": extensions,
            "binary": [
                "recommended_path": binary,
                "installed": binaryExists,
                "app_bundle": appBundleURL.path,
                "app_executable": appExecutableURL.path,
                "bundle_id": Self.bundleIdentifier,
                "display_name": Self.appDisplayName,
                "legacy_local_bin": legacyLink,
                "legacy_symlink_target": legacyTarget,
                "legacy_warning": legacyTarget.contains("Application Support/ForgeConductor")
                    || legacyTarget.contains(".venv")
                    ? "WARNING: ~/.local/bin/forge-conductor points at the old Python venv."
                    : "",
            ] as [String: Any],
            "login_agent": [
                "label": Self.launchAgentLabel,
                "plist": launchAgentURL.path,
                "installed": isLoginAgentInstalled(),
                "loaded": isLoginAgentLoaded(),
                "shows_in_login_items_as": Self.appDisplayName,
            ] as [String: Any],
            "launch_agents": agents,
            "stale_agents_present": staleStillPresent,
            "stale_hint": staleStillPresent
                ? "Legacy agents still present (show as bash/python3). Run: forge-conductor manager cleanup-stale"
                : "No stale com.forge.* agents",
            "dashboard_port": port,
            "port_in_use": isPortListening(port),
            "allowlist": allowlistInstructions(binaryPath: binary, port: port),
        ]
    }

    public func allowlistInstructions(binaryPath: String, port: Int) -> [String: Any] {
        [
            "macos_login_items": [
                "System Settings → General → Login Items & Extensions → Allow in the Background",
                "Look for \"\(Self.appDisplayName)\" (not bash/python3)",
                "If missing: run manager cleanup-stale then manager install-login, then log out/in once",
                "Endpoint Security Extensions (Falcon/Jamf Protect/Cortex) are IT-managed — leave enabled",
            ],
            "macos_firewall": [
                "Allow incoming for: \(binaryPath)",
                "And: \(appExecutableURL.path)",
            ],
            "crowdstrike_falcon": [
                "Allow process: \(binaryPath)",
                "Allow app bundle: \(appBundleURL.path)",
                "Allow listen 127.0.0.1:\(port)",
            ],
            "jamf_protect": [
                "Exception for \(binaryPath) and \(Self.bundleIdentifier)",
            ],
            "commands": [
                "forge-conductor manager cleanup-stale",
                "forge-conductor manager install-login",
                "forge-conductor manager status",
            ],
        ]
    }

    // MARK: - Helpers

    public static func currentExecutableURL() throws -> URL {
        try SelfExecutable.pathURL()
    }

    private func isPortListening(_ port: Int) -> Bool {
        let r = try? ProcessRunner().run(
            executable: "/usr/sbin/lsof",
            arguments: ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"],
            timeoutSec: 5
        )
        return (r?.exitCode == 0) && !(r?.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    private func escapeXML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}

public enum SelfExecutable {
    public static func path() throws -> String {
        try pathURL().path
    }

    public static func pathURL() throws -> URL {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        var size = UInt32(buf.count)
        if _NSGetExecutablePath(&buf, &size) == 0 {
            let path = String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            return URL(fileURLWithPath: path).resolvingSymlinksInPath()
        }
        let arg0 = CommandLine.arguments[0]
        if arg0.hasPrefix("/") {
            return URL(fileURLWithPath: arg0).resolvingSymlinksInPath()
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent(arg0)
            .resolvingSymlinksInPath()
    }
}

@_silgen_name("_NSGetExecutablePath")
func _NSGetExecutablePath(_ buf: UnsafeMutablePointer<CChar>, _ bufsize: UnsafeMutablePointer<UInt32>) -> Int32
