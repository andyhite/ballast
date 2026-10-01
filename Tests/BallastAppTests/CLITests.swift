import Foundation
import Testing
@testable import BallastApp

/// Argument parsing, exit codes, and pure report logic. Nothing here starts
/// the app or posts a command: a valid `send` would drive a live instance.
@MainActor
@Suite
struct CLITests {
    private func tempFile(_ text: String?) throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ballast-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("config.toml")
        if let text { try text.write(to: url, atomically: true, encoding: .utf8) }
        return url.path
    }

    @Test("bad invocations exit 1", arguments: [
        ["bogus"], ["--config"], ["--config="], ["spaces", "extra"], ["doctor", "extra"],
        ["run", "--confg", "x"], ["login-item", "on", "off"], ["check-config", "a", "b"],
        ["send", "no-such-command"],
    ])
    func badInvocation(args: [String]) {
        #expect(BallastCLI.main(args, env: [:]) == 1)
    }

    @Test func helpExitsZero() {
        #expect(BallastCLI.main(["help"], env: [:]) == 0)
    }

    @Test func checkConfigExitCodes() throws {
        let valid = try tempFile("[layout]\nfeature_size = 0.6\n")
        let invalid = try tempFile("[layout]\narrange = \"spiral\"\n")
        let missing = try tempFile(nil)
        #expect(BallastCLI.main(["check-config", valid], env: [:]) == 0)
        #expect(BallastCLI.main(["check-config", invalid], env: [:]) == 1)
        #expect(BallastCLI.main(["check-config", missing], env: [:]) == 1)
        #expect(BallastCLI.main(["check-config", "--config=\(valid)"], env: [:]) == 0)
        #expect(BallastCLI.main(["--config", invalid, "check-config"], env: [:]) == 1)
    }

    @Test func defaultConfigPrecedence() {
        #expect(BallastCLI.defaultConfigURL(env: ["BALLAST_CONFIG": "/a/b.toml", "XDG_CONFIG_HOME": "/x"]).path == "/a/b.toml")
        #expect(BallastCLI.defaultConfigURL(env: ["BALLAST_CONFIG": "", "XDG_CONFIG_HOME": "/x"]).path == "/x/ballast/config.toml")
        let home = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/ballast/config.toml").path
        #expect(BallastCLI.defaultConfigURL(env: ["XDG_CONFIG_HOME": "relative/dir"]).path == home)
        #expect(BallastCLI.defaultConfigURL(env: [:]).path == home)
    }

    // MARK: Doctor report

    private static let ax = "Accessibility permission"

    @Test func missingAccessibilityAloneStillCanManage() {
        let checks = [
            DoctorCheck(name: Self.ax, status: .warn, detail: "terminal"),
            DoctorCheck(name: "Other", status: .pass, detail: "ok"),
        ]
        #expect(checks.canManage)
        #expect(!checks.accessibilityGranted)
    }

    @Test func otherFailureBlocksManagement() {
        let checks = [
            DoctorCheck(name: Self.ax, status: .pass, detail: "ok"),
            DoctorCheck(name: "Displays have separate Spaces", status: .fail, detail: "off"),
        ]
        #expect(!checks.canManage)
        #expect(checks.accessibilityGranted)
    }

    @Test func renderSummarizesCounts() {
        let checks = [
            DoctorCheck(name: "A", status: .pass, detail: "ok"),
            DoctorCheck(name: "B", status: .warn, detail: "hmm"),
            DoctorCheck(name: "C", status: .fail, detail: "bad"),
        ]
        let lines = checks.render().split(separator: "\n").map(String.init)
        #expect(lines.first == "✓ A — ok")
        #expect(lines.last == "1 failed, 1 warned, 3 total.")
        #expect([DoctorCheck(name: "A", status: .pass, detail: "ok")].render().hasSuffix("All checks passed."))
    }
}
