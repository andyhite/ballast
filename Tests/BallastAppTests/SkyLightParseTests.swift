import Testing
import Foundation
@testable import BallastApp
@testable import BallastCore

struct SkyLightParseTests {
    private func entry(_ dict: [String: Any]) -> AnyObject { dict as NSDictionary }

    @Test func readsManagedSpaceIDAndID64() {
        let snapshot = SkyLightSpaceProvider.parse([entry([
            "Display Identifier": "ABC",
            "Current Space": ["id64": NSNumber(value: 4)],
            "Spaces": [
                ["ManagedSpaceID": NSNumber(value: 3), "uuid": "u3", "type": NSNumber(value: 0)],
                ["id64": NSNumber(value: 4), "uuid": "u4", "type": NSNumber(value: 4)],
            ],
        ])], builtin: [], small: [])

        #expect(snapshot.displays.count == 1)
        #expect(snapshot.displays[0].activeSpace == 4)
        #expect(snapshot.displays[0].spaces == [
            SpaceInfo(id: 3, uuid: "u3", kind: .user),
            SpaceInfo(id: 4, uuid: "u4", kind: .fullscreen),
        ])
    }

    @Test func missingSpacesKeepsTheDisplay() {
        let snapshot = SkyLightSpaceProvider.parse([entry([
            "Display Identifier": "ABC",
            "Current Space": ["ManagedSpaceID": NSNumber(value: 9)],
        ])], builtin: [], small: [])

        #expect(snapshot.displays == [DisplaySpaces(displayUUID: "ABC", spaces: [], activeSpace: 9)])
    }

    @Test func lowercaseDisplayIDsAreUppercasedBeforeMatching() {
        let snapshot = SkyLightSpaceProvider.parse([entry([
            "Display Identifier": "abc-def",
            "Spaces": [],
        ])], builtin: ["ABC-DEF"], small: ["ABC-DEF"])

        #expect(snapshot.displays.map(\.displayUUID) == ["ABC-DEF"])
        #expect(snapshot.displays[0].builtin)
        #expect(snapshot.displays[0].small)
    }

    @Test func malformedEntriesAreSkippedNotFatal() {
        let snapshot = SkyLightSpaceProvider.parse([
            "not a dictionary" as NSString,
            entry(["Spaces": []]), // no display identifier
            entry([
                "Display Identifier": "ABC",
                "Current Space": "garbage",
                "Spaces": [
                    "garbage",
                    ["uuid": "no-id"], // no space id
                    ["ManagedSpaceID": NSNumber(value: 7), "uuid": "u7"], // type defaults to a user desktop
                ],
            ]),
        ], builtin: [], small: [])

        #expect(snapshot.displays.count == 1)
        #expect(snapshot.displays[0].activeSpace == nil)
        #expect(snapshot.displays[0].spaces == [SpaceInfo(id: 7, uuid: "u7", kind: .user)])
    }
}
