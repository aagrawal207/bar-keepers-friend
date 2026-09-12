import CoreGraphics
import Foundation
import Testing
@testable import BarKeepersFriendCore

@Suite struct ItemGroupTests {

    private func snapshot(_ owner: String?, id: CGWindowID = 1) -> MenuBarItemSnapshot {
        MenuBarItemSnapshot(
            windowID: id, ownerPID: 1, ownerBundleID: owner, title: nil,
            frame: CGRect(x: 0, y: 0, width: 22, height: 22)
        )
    }

    // MARK: - Membership

    @Test func initDeduplicatesKeysPreservingFirstOccurrenceOrder() {
        let group = ItemGroup(name: "Work", ownerKeys: ["b", "a", "b", "c", "a"])
        #expect(group.ownerKeys == ["b", "a", "c"])
    }

    @Test func appendAndRemoveKeepOrderAndUniqueness() {
        var group = ItemGroup(name: "Work", ownerKeys: ["a"])
        group.appendKey("b")
        group.appendKey("a")
        #expect(group.ownerKeys == ["a", "b"])
        // Mutating calls are hoisted: #expect cannot apply a mutating member to its captured operand.
        let removedMember = group.removeKey("a")
        let removedMissing = group.removeKey("missing")
        #expect(removedMember)
        #expect(!removedMissing)
        #expect(group.ownerKeys == ["b"])
        #expect(group.contains(key: "b"))
        #expect(!group.contains(key: "a"))
    }

    @Test func assigningMovesAKeyBetweenGroupsAndKeepsEveryOtherMember() {
        let work = ItemGroup(name: "Work", ownerKeys: ["Maccy", "Itsycal"])
        let home = ItemGroup(name: "Home", ownerKeys: ["Wisp"])
        let moved = ItemGroupLibrary.assigning(key: "Maccy", to: home.id, in: [work, home])
        #expect(moved.map(\.ownerKeys) == [["Itsycal"], ["Wisp", "Maccy"]])
        #expect(moved.map(\.id) == [work.id, home.id])
        #expect(ItemGroupLibrary.group(containing: "Maccy", in: moved)?.id == home.id)
        #expect(ItemGroupLibrary.group(containing: "Itsycal", in: moved)?.id == work.id)
        #expect(ItemGroupLibrary.group(containing: "Nobody", in: moved) == nil)
    }

    @Test func assigningAnExistingMemberOrUnknownGroupChangesNothing() {
        let work = ItemGroup(name: "Work", ownerKeys: ["Maccy", "Itsycal"])
        let home = ItemGroup(name: "Home")
        let groups = [work, home]
        #expect(ItemGroupLibrary.assigning(key: "Maccy", to: work.id, in: groups) == groups)
        #expect(ItemGroupLibrary.assigning(key: "Maccy", to: UUID(), in: groups) == groups)
    }

    @Test func unassigningRemovesTheKeyFromWhicheverGroupHoldsIt() {
        let work = ItemGroup(name: "Work", ownerKeys: ["Maccy"])
        let home = ItemGroup(name: "Home", ownerKeys: ["Wisp"])
        let groups = [work, home]
        let updated = ItemGroupLibrary.unassigning(key: "Wisp", in: groups)
        #expect(updated.map(\.ownerKeys) == [["Maccy"], []])
        #expect(ItemGroupLibrary.unassigning(key: "Nobody", in: groups) == groups)
    }

    @Test func removingAGroupUngroupsItsKeys() {
        let work = ItemGroup(name: "Work", ownerKeys: ["Maccy", "Itsycal"])
        let home = ItemGroup(name: "Home", ownerKeys: ["Wisp"])
        let remaining = ItemGroupLibrary.removing(groupID: work.id, from: [work, home])
        #expect(remaining == [home])
        #expect(ItemGroupLibrary.group(containing: "Maccy", in: remaining) == nil)
        #expect(ItemGroupLibrary.groupedKeys(in: remaining) == ["Wisp"])
        #expect(ItemGroupLibrary.removing(groupID: UUID(), from: [work, home]) == [work, home])
    }

    // MARK: - Names

    @Test func addingTrimsValidatesAndAppendsAnEmptyGroup() throws {
        let groups = try ItemGroupLibrary.adding(name: "  Work  ", to: [])
        #expect(groups.map(\.name) == ["Work"])
        #expect(groups[0].ownerKeys.isEmpty)
        let more = try ItemGroupLibrary.adding(name: "Home", to: groups)
        #expect(more.map(\.name) == ["Work", "Home"])
        #expect(more[0].id == groups[0].id)
    }

    @Test func nameValidationRejectsEmptyLongAndCaseInsensitiveDuplicates() {
        let work = ItemGroup(name: "Work")
        let groups = [work]
        #expect(ItemGroupLibrary.nameProblem("", in: groups) == .emptyName)
        #expect(ItemGroupLibrary.nameProblem("   \n", in: groups) == .emptyName)
        #expect(ItemGroupLibrary.nameProblem(String(repeating: "x", count: 41), in: groups) == .nameTooLong)
        #expect(ItemGroupLibrary.nameProblem(String(repeating: "x", count: 40), in: groups) == nil)
        #expect(ItemGroupLibrary.nameProblem(" wORK ", in: groups) == .duplicateName)
        #expect(ItemGroupLibrary.nameProblem("Home", in: groups) == nil)
        // A rename may keep or re-case its own name.
        #expect(ItemGroupLibrary.nameProblem("WORK", in: groups, excluding: work.id) == nil)

        #expect(throws: ItemGroupLibrary.ValidationError.duplicateName) {
            try ItemGroupLibrary.adding(name: "work", to: groups)
        }
        #expect(throws: ItemGroupLibrary.ValidationError.emptyName) {
            try ItemGroupLibrary.adding(name: " ", to: groups)
        }
        #expect(throws: ItemGroupLibrary.ValidationError.nameTooLong) {
            try ItemGroupLibrary.adding(name: String(repeating: "y", count: 41), to: groups)
        }
    }

    @Test func addingBeyondTheMaximumIsRejected() throws {
        var groups: [ItemGroup] = []
        for index in 0..<ItemGroupLibrary.maxGroups {
            groups = try ItemGroupLibrary.adding(name: "Group \(index)", to: groups)
        }
        #expect(groups.count == 20)
        #expect(throws: ItemGroupLibrary.ValidationError.tooManyGroups) {
            try ItemGroupLibrary.adding(name: "One more", to: groups)
        }
    }

    @Test func renamingTrimsValidatesAndLeavesMembersAlone() throws {
        let work = ItemGroup(name: "Work", ownerKeys: ["Maccy"])
        let home = ItemGroup(name: "Home")
        let renamed = try ItemGroupLibrary.renaming(groupID: work.id, to: "  Focus ", in: [work, home])
        #expect(renamed.map(\.name) == ["Focus", "Home"])
        #expect(renamed[0].id == work.id)
        #expect(renamed[0].ownerKeys == ["Maccy"])
        let recased = try ItemGroupLibrary.renaming(groupID: work.id, to: "WORK", in: [work, home])
        #expect(recased[0].name == "WORK")

        #expect(throws: ItemGroupLibrary.ValidationError.duplicateName) {
            try ItemGroupLibrary.renaming(groupID: work.id, to: "home", in: [work, home])
        }
        #expect(throws: ItemGroupLibrary.ValidationError.emptyName) {
            try ItemGroupLibrary.renaming(groupID: work.id, to: "", in: [work, home])
        }
        #expect(throws: ItemGroupLibrary.ValidationError.unknownGroup) {
            try ItemGroupLibrary.renaming(groupID: UUID(), to: "Anything", in: [work, home])
        }
    }

    @Test func validationMessagesAreUserFacing() {
        #expect(ItemGroupLibrary.ValidationError.nameTooLong.message.contains("40"))
        #expect(ItemGroupLibrary.ValidationError.tooManyGroups.message.contains("20"))
        for error in [ItemGroupLibrary.ValidationError.emptyName, .duplicateName, .unknownGroup] {
            #expect(!error.message.isEmpty)
        }
    }

    // MARK: - Effective controls

    @Test func effectiveControlsMarksGroupedKeysHiddenAndLeavesOthersUntouched() {
        var base = ItemControlStore()
        base.setHidden(false, forKey: "Shown ungrouped")
        base.setHidden(true, forKey: "Hidden ungrouped")
        base.setHidden(false, forKey: "Grouped but saved Shown")
        base.setSuppressed(true, forKey: "Grouped but saved Shown")
        base.setOrderIndex(3, forKey: "Untouched")
        let groups = [
            ItemGroup(name: "Work", ownerKeys: ["Grouped but saved Shown", "Grouped without intent"]),
            ItemGroup(name: "Home", ownerKeys: ["Other grouped"])
        ]

        let effective = ItemGroupLibrary.effectiveControls(groups: groups, base: base)
        for key in ["Grouped but saved Shown", "Grouped without intent", "Other grouped"] {
            #expect(effective.isHidden(forKey: key))
            #expect(effective.hasPlacementIntent(forKey: key))
        }
        #expect(!effective.shownInMenuBar.contains("Grouped but saved Shown"))
        #expect(!effective.isHidden(forKey: "Shown ungrouped"))
        #expect(effective.shownInMenuBar.contains("Shown ungrouped"))
        #expect(effective.isHidden(forKey: "Hidden ungrouped"))
        #expect(!effective.hasPlacementIntent(forKey: "Untouched"))
        #expect(effective.suppressedFromBar == base.suppressedFromBar)
        #expect(effective.barOrder == base.barOrder)

        // The saved store is a value the caller still owns; grouping never rewrites it.
        #expect(!base.isHidden(forKey: "Grouped but saved Shown"))
        #expect(!base.hasPlacementIntent(forKey: "Grouped without intent"))
        #expect(ItemGroupLibrary.effectiveControls(groups: [], base: base) == base)
    }

    @Test func effectiveControlsAfterRemovingAGroupRestoresTheSavedIntent() {
        var base = ItemControlStore()
        base.setHidden(false, forKey: "Maccy")
        let work = ItemGroup(name: "Work", ownerKeys: ["Maccy"])
        #expect(ItemGroupLibrary.effectiveControls(groups: [work], base: base).isHidden(forKey: "Maccy"))
        let removed = ItemGroupLibrary.removing(groupID: work.id, from: [work])
        let restored = ItemGroupLibrary.effectiveControls(groups: removed, base: base)
        #expect(!restored.isHidden(forKey: "Maccy"))
        #expect(restored == base)
    }

    @Test func isGroupedUsesTheControlKeyAndIgnoresKeylessSnapshots() {
        let groups = [ItemGroup(name: "Work", ownerKeys: ["Maccy"])]
        #expect(ItemGroupLibrary.isGrouped(snapshot("Maccy"), groups: groups))
        #expect(!ItemGroupLibrary.isGrouped(snapshot("Wisp"), groups: groups))
        #expect(!ItemGroupLibrary.isGrouped(snapshot(nil), groups: groups))
        #expect(!ItemGroupLibrary.isGrouped(snapshot(""), groups: groups))
        #expect(!ItemGroupLibrary.isGrouped(snapshot("Maccy"), groups: []))
    }

    // MARK: - Normalization

    @Test func normalizedDropsDuplicateIDsCrossGroupKeysAndExcessGroups() {
        let shared = UUID()
        let first = ItemGroup(id: shared, name: "First", ownerKeys: ["a", "b"])
        let duplicateID = ItemGroup(id: shared, name: "Duplicate", ownerKeys: ["z"])
        let second = ItemGroup(name: "Second", ownerKeys: ["b", "c"])
        let normalized = ItemGroupLibrary.normalized([first, duplicateID, second])
        #expect(normalized.map(\.name) == ["First", "Second"])
        #expect(normalized.map(\.ownerKeys) == [["a", "b"], ["c"]])
        #expect(normalized[1].id == second.id)

        let many = (0..<25).map { ItemGroup(name: "G\($0)", ownerKeys: ["k\($0)"]) }
        let capped = ItemGroupLibrary.normalized(many)
        #expect(capped.count == ItemGroupLibrary.maxGroups)
        #expect(capped == Array(many.prefix(20)))
        #expect(ItemGroupLibrary.normalized(normalized) == normalized)
    }

    // MARK: - Codable

    @Test func codableRoundTripPreservesIdentityNameAndOrder() throws {
        let group = ItemGroup(name: "Work", ownerKeys: ["Maccy", "Itsycal", "Wisp"])
        let data = try JSONEncoder().encode([group])
        let decoded = try JSONDecoder().decode([ItemGroup].self, from: data)
        #expect(decoded == [group])
        #expect(decoded[0].id == group.id)
        #expect(decoded[0].ownerKeys == ["Maccy", "Itsycal", "Wisp"])

        let objects = try #require(try JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        let object = try #require(objects.first)
        #expect(Set(object.keys) == ["id", "name", "ownerKeys"])
        #expect(object["id"] as? String == group.id.uuidString)
        #expect(object["ownerKeys"] as? [String] == ["Maccy", "Itsycal", "Wisp"])
    }

    @Test func decodingIsLenientAboutMissingFields() throws {
        let missingID = try JSONDecoder().decode(
            ItemGroup.self, from: Data(#"{"name":"Work","ownerKeys":["Maccy","Maccy","Wisp"]}"#.utf8)
        )
        #expect(missingID.name == "Work")
        #expect(missingID.ownerKeys == ["Maccy", "Wisp"])

        let id = UUID()
        let missingName = try JSONDecoder().decode(
            ItemGroup.self, from: Data(#"{"id":"\#(id.uuidString)","ownerKeys":["Maccy"]}"#.utf8)
        )
        #expect(missingName.id == id)
        #expect(missingName.name == ItemGroupLibrary.fallbackName)

        let blankName = try JSONDecoder().decode(ItemGroup.self, from: Data(#"{"name":"   "}"#.utf8))
        #expect(blankName.name == ItemGroupLibrary.fallbackName)
        #expect(blankName.ownerKeys.isEmpty)

        let padded = try JSONDecoder().decode(ItemGroup.self, from: Data(#"{"name":"  Work "}"#.utf8))
        #expect(padded.name == "Work")

        let empty = try JSONDecoder().decode(ItemGroup.self, from: Data("{}".utf8))
        #expect(empty.name == ItemGroupLibrary.fallbackName)
        #expect(empty.ownerKeys.isEmpty)
    }

    @Test func decodingRejectsWrongTypesSoACallerCanDropThatElement() {
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ItemGroup.self, from: Data(#"{"name":"Work","ownerKeys":"Maccy"}"#.utf8))
        }
        #expect(throws: (any Error).self) {
            try JSONDecoder().decode(ItemGroup.self, from: Data(#"{"id":"not-a-uuid","name":"Work"}"#.utf8))
        }
    }
}
