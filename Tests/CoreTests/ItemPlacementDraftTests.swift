import CoreGraphics
import Testing
import BarKeepersFriendCore

@Suite struct ItemPlacementDraftTests {
    @Test func emptyDraftLeavesEveryControlUntouched() {
        let draft = ItemPlacementDraft()
        let controls = ItemControlStore(
            hiddenInMenuBar: ["hidden"], shownInMenuBar: ["shown"],
            suppressedFromBar: ["suppressed"], barOrder: ["ordered": 3]
        )

        #expect(draft.isEmpty)
        #expect(draft.count == 0)
        #expect(draft.hidden(for: item()) == nil)
        #expect(draft.applying(to: controls) == controls)
    }

    @Test(arguments: [false, true])
    func keylessItemsCannotCreateChanges(hidden: Bool) {
        var draft = ItemPlacementDraft()
        let controls = ItemControlStore()
        draft.setHidden(hidden, for: [(item(nil), !hidden), (item(""), !hidden)], controls: controls)

        #expect(draft.isEmpty)
        #expect(draft.count == 0)
        #expect(draft.hidden(for: item(nil)) == nil)
        #expect(draft.hidden(for: item("")) == nil)
        #expect(draft.applying(to: controls) == controls)
    }

    @Test(arguments: [false, true])
    func repeatingChoicesCountsOwnersRatherThanWindows(hidden: Bool) {
        var draft = ItemPlacementDraft()
        let controls = ItemControlStore()
        let items: [(snapshot: MenuBarItemSnapshot, observedHidden: Bool?)] = [
            (item("ACME", id: 1), !hidden), (item("ACME", id: 2), !hidden), (item("Maccy", id: 1), !hidden)
        ]
        draft.setHidden(hidden, for: items, controls: controls)
        draft.setHidden(hidden, for: items, controls: controls)

        #expect(draft.count == 2)
        #expect(draft.hidden(for: item("ACME", id: 99)) == hidden)
        #expect(draft.hidden(for: item("Maccy", id: 99)) == hidden)
        #expect(draft.hidden(for: item("unconfigured", id: 1)) == nil)
        var expected = controls
        expected.setHidden(hidden, forKey: "ACME")
        expected.setHidden(hidden, forKey: "Maccy")
        #expect(draft.applying(to: controls) == expected)
    }

    @Test(arguments: [false, true])
    func selectingOrReturningToObservedBaselinePreservesNoIntent(baseline: Bool) {
        var draft = ItemPlacementDraft()
        let snapshot = item()
        let controls = ItemControlStore(suppressedFromBar: ["ACME"], barOrder: ["ACME": 7])
        draft.setHidden(baseline, for: [(snapshot, baseline)], controls: controls)
        #expect(draft.isEmpty)

        draft.setHidden(!baseline, for: [(snapshot, baseline)], controls: controls)
        #expect(draft.count == 1)
        draft.setHidden(baseline, for: [(snapshot, baseline)], controls: controls)

        #expect(draft.isEmpty)
        #expect(draft.hidden(for: snapshot) == nil)
        #expect(draft.applying(to: controls) == controls)
        #expect(!draft.applying(to: controls).hasPlacementIntent(snapshot))
    }

    @Test(arguments: [false, true], [false, true])
    func returningToObservedBaselineOverridesOpposingSavedIntent(hidden: Bool, stageSavedFirst: Bool) {
        var draft = ItemPlacementDraft()
        var controls = ItemControlStore()
        controls.setHidden(hidden, for: item())
        if stageSavedFirst {
            draft.setHidden(hidden, for: [(item(), !hidden)], controls: controls)
            #expect(draft.count == 1)
            #expect(draft.applying(to: controls) == controls)
        }

        draft.setHidden(!hidden, for: [(item(), !hidden)], controls: controls)
        draft.setHidden(!hidden, for: [(item(), !hidden)], controls: controls)
        #expect(draft.count == 1)
        #expect(draft.hidden(for: item()) == !hidden)
        var expected = controls
        expected.setHidden(!hidden, for: item())
        #expect(draft.applying(to: controls) == expected)
        #expect(controls.isHidden(item()) == hidden)

        draft = ItemPlacementDraft()
        #expect(draft.isEmpty)
        #expect(draft.applying(to: controls) == controls)
    }

    @Test(arguments: [false, true], [false, true])
    func matchingSavedIntentIsTheRevertBaselineWithOrWithoutObservation(hidden: Bool, hasObservation: Bool) {
        var draft = ItemPlacementDraft()
        var controls = ItemControlStore()
        controls.setHidden(hidden, for: item())
        let observed: Bool? = hasObservation ? hidden : nil
        draft.setHidden(hidden, for: [(item(), observed)], controls: controls)
        #expect(draft.isEmpty)

        draft.setHidden(!hidden, for: [(item(), observed)], controls: controls)
        #expect(draft.hidden(for: item()) == !hidden)
        draft.setHidden(hidden, for: [(item(), observed)], controls: controls)
        #expect(draft.isEmpty)
        #expect(draft.applying(to: controls) == controls)
    }

    @Test(arguments: [false, true])
    func missingBaselineAllowsEitherExplicitChoiceAndDoesNotRebase(hidden: Bool) {
        var draft = ItemPlacementDraft()
        let controls = ItemControlStore()
        draft.setHidden(hidden, for: [(item(), nil)], controls: controls)
        #expect(draft.hidden(for: item()) == hidden)
        #expect(draft.count == 1)

        draft.setHidden(hidden, for: [(item(id: 2), hidden)], controls: controls)
        #expect(draft.count == 1)
        draft.setHidden(!hidden, for: [(item(id: 2), !hidden)], controls: controls)
        #expect(draft.count == 1)
        #expect(draft.hidden(for: item()) == !hidden)
        #expect(draft.applying(to: controls).hasPlacementIntent(item()))
        #expect(draft.applying(to: controls).isHidden(item()) == !hidden)
    }

    @Test(arguments: [false, true], [false, true])
    func mixedSiblingsCannotCancelEachOthersChoice(hidden: Bool, reverseOrder: Bool) {
        var draft = ItemPlacementDraft()
        let controls = ItemControlStore()
        var siblings: [(snapshot: MenuBarItemSnapshot, observedHidden: Bool?)] = [
            (item(id: 1), false), (item(id: 2), true)
        ]
        if reverseOrder { siblings.reverse() }
        draft.setHidden(hidden, for: siblings, controls: controls)
        draft.setHidden(hidden, for: siblings, controls: controls)
        #expect(draft.count == 1)
        #expect(draft.hidden(for: item(id: 1)) == hidden)
        #expect(draft.hidden(for: item(id: 2)) == hidden)

        draft.setHidden(!hidden, for: siblings, controls: controls)
        #expect(draft.count == 1)
        #expect(draft.hidden(for: item(id: 1)) == !hidden)
        #expect(draft.hidden(for: item(id: 2)) == !hidden)
        #expect(draft.applying(to: controls).isHidden(item()) == !hidden)
    }

    @Test(arguments: [false, true], [false, true])
    func unknownSiblingOnlySharesABaselineWhenSavedIntentProvidesIt(hidden: Bool, hasIntent: Bool) {
        var draft = ItemPlacementDraft()
        var controls = ItemControlStore()
        if hasIntent { controls.setHidden(hidden, for: item()) }
        draft.setHidden(hidden, for: [(item(id: 1), hidden), (item(id: 2), nil)], controls: controls)

        #expect(draft.isEmpty == hasIntent)
        #expect(draft.hidden(for: item()) == (hasIntent ? nil : hidden))
    }

    @Test(arguments: [false, true])
    func refreshedObservationsDoNotReplaceTheFirstEditBaseline(hidden: Bool) {
        var draft = ItemPlacementDraft()
        let controls = ItemControlStore()
        draft.setHidden(hidden, for: [(item(), !hidden)], controls: controls)
        draft.setHidden(hidden, for: [(item(id: 9), hidden)], controls: controls)

        #expect(draft.count == 1)
        #expect(draft.hidden(for: item(id: 9)) == hidden)
        #expect(draft.applying(to: controls).hasPlacementIntent(item(id: 9)))
        #expect(draft.applying(to: controls).isHidden(item(id: 9)) == hidden)
        draft.setHidden(!hidden, for: [(item(id: 9), hidden)], controls: controls)
        #expect(draft.isEmpty)
        #expect(draft.applying(to: controls) == controls)
    }

    @Test func mergeChangesOnlyEditedPlacementsInTheCurrentStore() {
        var draft = ItemPlacementDraft()
        draft.setHidden(false, for: [(item("ACME"), true)], controls: ItemControlStore())
        draft.setHidden(true, for: [(item("Maccy"), false)], controls: ItemControlStore())
        let current = ItemControlStore(
            hiddenInMenuBar: ["ACME", "absent.hidden", "untouched.both"],
            shownInMenuBar: ["Maccy", "absent.shown", "untouched.both"],
            suppressedFromBar: ["ACME", "absent.suppressed"], barOrder: ["Maccy": 3, "absent.ordered": 1]
        )
        let expected = ItemControlStore(
            hiddenInMenuBar: ["Maccy", "absent.hidden", "untouched.both"],
            shownInMenuBar: ["ACME", "absent.shown", "untouched.both"],
            suppressedFromBar: current.suppressedFromBar, barOrder: current.barOrder
        )

        #expect(draft.applying(to: current) == expected)
        #expect(draft.applying(to: expected) == expected)
        #expect(!draft.applying(to: current).hasPlacementIntent(forKey: "unconfigured"))
        #expect(draft.count == 2)
        #expect(current.hiddenInMenuBar.contains("ACME"))
        #expect(current.shownInMenuBar.contains("Maccy"))
    }

    @Test(arguments: [Optional<Bool>.none, false, true])
    func partialSiblingRefreshesPreserveDraftsAndIndependentPlacementOverrides(observed: Bool?) {
        var draft = ItemPlacementDraft()
        let controls = ItemControlStore(hiddenInMenuBar: ["ACME"], shownInMenuBar: ["Maccy"])
        draft.setHidden(true, for: [(item("ACME", id: 1), false), (item("ACME", id: 2), false)], controls: controls)
        draft.setHidden(false, for: [(item("Maccy", id: 3), true)], controls: controls)
        let pending = draft

        draft.setHidden(true, for: [], controls: controls)
        #expect(draft == pending)
        draft.setHidden(true, for: [(item("ACME", id: 9), true), (item("ACME", id: 10), observed)], controls: controls)

        #expect(draft == pending)
        #expect(draft.count == 2)
        #expect(draft.hidden(for: item("ACME", id: 9)) == true)
        #expect(draft.hidden(for: item("ACME", id: 10)) == true)
        #expect(draft.hidden(for: item("Maccy", id: 3)) == false)
        #expect(draft.hidden(for: item("unconfigured")) == nil)
        #expect(draft.applying(to: controls) == controls)
        #expect(draft == pending)

        draft.setHidden(false, for: [(item("ACME", id: 9), true), (item("ACME", id: 10), observed)], controls: controls)
        #expect(draft.count == 2)
        #expect(draft.hidden(for: item("ACME")) == false)
        #expect(draft.hidden(for: item("Maccy")) == false)
        var expected = controls
        expected.setHidden(false, forKey: "ACME")
        #expect(draft.applying(to: controls) == expected)
        draft.setHidden(true, for: [(item("Maccy", id: 3), nil)], controls: controls)
        #expect(draft.count == 2)
        #expect(draft.hidden(for: item("ACME")) == false)
        #expect(draft.hidden(for: item("Maccy")) == true)
        expected.setHidden(true, forKey: "Maccy")
        #expect(draft.applying(to: controls) == expected)
    }

    // MARK: - Three tiers

    @Test(arguments: ItemPlacement.allCases)
    func stagingATierRecordsItAndMergesThroughSetPlacement(placement: ItemPlacement) {
        var draft = ItemPlacementDraft()
        let controls = ItemControlStore()
        let observed: ItemPlacement? = ItemPlacement.allCases.first { $0 != placement }
        draft.setPlacement(placement, for: [(item(), observed)], controls: controls)

        #expect(draft.count == 1)
        #expect(draft.placement(for: item(id: 7)) == placement)
        #expect(draft.hidden(for: item(id: 7)) == placement.isHidden)
        var expected = controls
        expected.setPlacement(placement, forKey: "ACME")
        #expect(draft.applying(to: controls) == expected)
        #expect(draft.applying(to: controls).placement(forKey: "ACME") == placement)
    }

    @Test(arguments: ItemPlacement.allCases)
    func returningToTheObservedTierClearsTheEdit(baseline: ItemPlacement) {
        var draft = ItemPlacementDraft()
        let controls = ItemControlStore()
        for other in ItemPlacement.allCases where other != baseline {
            draft.setPlacement(other, for: [(item(), baseline)], controls: controls)
            #expect(draft.placement(for: item()) == other)
            draft.setPlacement(baseline, for: [(item(), baseline)], controls: controls)
            #expect(draft.isEmpty)
        }
        #expect(draft.applying(to: controls) == controls)
    }

    @Test func choosingTheObservedTierStillReplacesAnOpposingSavedTier() {
        var draft = ItemPlacementDraft()
        var controls = ItemControlStore()
        controls.setPlacement(.alwaysHidden, forKey: "ACME")
        draft.setPlacement(.hidden, for: [(item(), .hidden)], controls: controls)

        #expect(draft.count == 1)
        #expect(draft.placement(for: item()) == .hidden)
        #expect(draft.applying(to: controls).placement(forKey: "ACME") == .hidden)
        #expect(draft.applying(to: controls).alwaysHiddenInMenuBar.isEmpty)
        draft.setPlacement(.alwaysHidden, for: [(item(), .hidden)], controls: controls)
        #expect(draft.count == 1)
        #expect(draft.applying(to: controls) == controls)
    }

    @Test func boolEntryPointsNeverStageOrObserveTheAlwaysHiddenTier() {
        var draft = ItemPlacementDraft()
        var controls = ItemControlStore()
        controls.setPlacement(.alwaysHidden, forKey: "ACME")
        draft.setHidden(true, for: [(item(), true)], controls: controls)

        #expect(draft.count == 1)
        #expect(draft.placement(for: item()) == .hidden)
        #expect(draft.hidden(for: item()) == true)
        #expect(draft.applying(to: controls).placement(forKey: "ACME") == .hidden)
    }

    @Test func mixedTiersAmongSiblingsHaveNoSharedBaseline() {
        var draft = ItemPlacementDraft()
        let controls = ItemControlStore()
        let siblings: [(snapshot: MenuBarItemSnapshot, observedPlacement: ItemPlacement?)] = [
            (item(id: 1), .hidden), (item(id: 2), .alwaysHidden)
        ]
        draft.setPlacement(.hidden, for: siblings, controls: controls)
        #expect(draft.count == 1)
        draft.setPlacement(.alwaysHidden, for: siblings, controls: controls)
        #expect(draft.count == 1)
        #expect(draft.placement(for: item(id: 2)) == .alwaysHidden)
        #expect(draft.applying(to: controls).placement(forKey: "ACME") == .alwaysHidden)
    }

    private func item(_ owner: String? = "ACME", id: CGWindowID = 1) -> MenuBarItemSnapshot {
        MenuBarItemSnapshot(windowID: id, ownerPID: 1, ownerBundleID: owner, frame: .zero)
    }
}
