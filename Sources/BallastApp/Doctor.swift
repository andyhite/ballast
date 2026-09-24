import ApplicationServices
import Foundation

/// Outcome of one environment check.
public enum CheckStatus: Sendable {
    case pass
    case warn
    case fail
}

/// One named environment check and its human-readable detail.
public struct DoctorCheck: Sendable {
    public let name: String
    public let status: CheckStatus
    public let detail: String

    public init(name: String, status: CheckStatus, detail: String) {
        self.name = name
        self.status = status
        self.detail = detail
    }
}

/// Full environment report produced by `Doctor.run()`.
public struct DoctorReport: Sendable {
    public let checks: [DoctorCheck]

    public init(checks: [DoctorCheck]) {
        self.checks = checks
    }

    /// `true` unless some check other than Accessibility permission failed.
    /// Accessibility is handled separately by the app (it has its own
    /// prompt/retry flow), so a missing AX grant alone does not mean the
    /// rest of the environment is unmanageable.
    public var canManage: Bool {
        !checks.contains { $0.status == .fail && $0.name != Doctor.accessibilityCheckName }
    }

    public var accessibilityGranted: Bool {
        checks.first { $0.name == Doctor.accessibilityCheckName }?.status == .pass
    }

    public var stageManager: Bool {
        checks.first { $0.name == Doctor.stageManagerCheckName }?.status == .warn
    }

    /// Plain-text rendering: one line per check plus a trailing summary.
    public func render() -> String {
        var lines: [String] = []
        for check in checks {
            let marker: String
            switch check.status {
            case .pass: marker = "✓"
            case .warn: marker = "!"
            case .fail: marker = "✗"
            }
            lines.append("\(marker) \(check.name) — \(check.detail)")
        }

        let failCount = checks.filter { $0.status == .fail }.count
        let warnCount = checks.filter { $0.status == .warn }.count
        let summary: String
        if failCount == 0 && warnCount == 0 {
            summary = "All checks passed."
        } else {
            summary = "\(failCount) failed, \(warnCount) warned, \(checks.count) total."
        }
        lines.append(summary)

        return lines.joined(separator: "\n")
    }
}

/// Environment diagnostics: permissions, system preferences, and private
/// symbol availability. Every check here is read-only.
public enum Doctor {

    fileprivate static let accessibilityCheckName = "Accessibility permission"
    fileprivate static let stageManagerCheckName = "Stage Manager"
    private static let skyLightDataCheckName = "SkyLight data sanity"

    /// Major macOS versions Ballast has been tested against.
    public static let testedMacOSRange: ClosedRange<Int> = 14...26

    public static func run() -> DoctorReport {
        var checks: [DoctorCheck] = []

        checks.append(accessibilityCheck())
        checks.append(separateSpacesCheck())
        checks.append(autoRearrangeCheck())
        checks.append(stageManagerCheck())
        checks.append(macOSVersionCheck())
        checks.append(contentsOf: privateSymbolChecks())
        checks.append(skyLightSanityCheck())

        return DoctorReport(checks: checks)
    }

    // MARK: - Individual checks

    private static func accessibilityCheck() -> DoctorCheck {
        if AXIsProcessTrusted() {
            return DoctorCheck(name: accessibilityCheckName, status: .pass, detail: "granted")
        }
        return DoctorCheck(
            name: accessibilityCheckName,
            status: .fail,
            detail: "not granted — enable in System Settings → Privacy & Security → Accessibility"
        )
    }

    private static func separateSpacesCheck() -> DoctorCheck {
        let name = "Displays have separate Spaces"
        if SystemSettings.displaysHaveSeparateSpaces {
            return DoctorCheck(name: name, status: .pass, detail: "on")
        }
        return DoctorCheck(
            name: name,
            status: .fail,
            detail:
                "off — enable in System Settings → Desktop & Dock → Mission Control " +
                "(a logout is required for the change to take effect)"
        )
    }

    private static func autoRearrangeCheck() -> DoctorCheck {
        let name = "Automatically rearrange Spaces based on most recent use"
        if !SystemSettings.autoRearrangeSpaces {
            return DoctorCheck(name: name, status: .pass, detail: "off")
        }
        return DoctorCheck(
            name: name,
            status: .fail,
            detail:
                "on — disable in System Settings → Desktop & Dock → Mission Control, or run " +
                "`defaults write com.apple.dock mru-spaces -bool false && killall Dock`"
        )
    }

    private static func stageManagerCheck() -> DoctorCheck {
        if SystemSettings.stageManagerEnabled {
            return DoctorCheck(
                name: stageManagerCheckName,
                status: .warn,
                detail: "on — every Space becomes a floating passthrough while Stage Manager is active"
            )
        }
        return DoctorCheck(name: stageManagerCheckName, status: .pass, detail: "off")
    }

    private static func macOSVersionCheck() -> DoctorCheck {
        let name = "macOS version"
        let version = SystemSettings.macOSVersion
        let major = version.majorVersion
        let versionString = "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
        if testedMacOSRange.contains(major) {
            return DoctorCheck(name: name, status: .pass, detail: versionString)
        }
        return DoctorCheck(
            name: name,
            status: .warn,
            detail: "\(versionString) is outside the tested range (\(testedMacOSRange.lowerBound)...\(testedMacOSRange.upperBound))"
        )
    }

    private static func privateSymbolChecks() -> [DoctorCheck] {
        SkyLightSpaceProvider.symbolStatus().map { status in
            DoctorCheck(
                name: "Private symbol: \(status.name)",
                status: status.resolved ? .pass : .fail,
                detail: status.resolved ? "resolved" : "failed to resolve — macOS may have changed SkyLight"
            )
        }
    }

    private static func skyLightSanityCheck() -> DoctorCheck {
        switch SkyLightSpaceProvider.make() {
        case .failure(let missing):
            return DoctorCheck(
                name: skyLightDataCheckName,
                status: .fail,
                detail: "cannot check — missing symbols: \(missing.names.joined(separator: ", "))"
            )
        case .success(let provider):
            guard let snapshot = provider.snapshot() else {
                return DoctorCheck(
                    name: skyLightDataCheckName,
                    status: .fail,
                    detail: "SLSCopyManagedDisplaySpaces returned malformed data"
                )
            }
            if snapshot.displays.isEmpty {
                return DoctorCheck(name: skyLightDataCheckName, status: .fail, detail: "no displays reported")
            }
            for display in snapshot.displays {
                let hasUUID = display.displayUUID.count == 36 && display.displayUUID.contains("-")
                if !hasUUID {
                    return DoctorCheck(
                        name: skyLightDataCheckName,
                        status: .fail,
                        detail:
                            "display identifier \"\(display.displayUUID)\" is not a UUID " +
                            "(enable \"Displays have separate Spaces\")"
                    )
                }
                let userSpaceCount = display.spaces.filter { $0.kind == .user }.count
                if userSpaceCount == 0 {
                    return DoctorCheck(
                        name: skyLightDataCheckName,
                        status: .fail,
                        detail: "display \(display.displayUUID) reports zero user Spaces"
                    )
                }
            }
            let totalUserSpaces = snapshot.displays.reduce(0) { $0 + $1.spaces.filter { $0.kind == .user }.count }
            return DoctorCheck(
                name: skyLightDataCheckName,
                status: .pass,
                detail: "\(snapshot.displays.count) displays, \(totalUserSpaces) user Spaces"
            )
        }
    }
}
