import XCTest
@testable import PhotonCore

final class EditStackTests: XCTestCase {

    private func settings(exposure: Double) -> DevelopSettings {
        var s = DevelopSettings()
        s.basic.exposure = exposure
        return s
    }

    func testInitialStateIsImportEntry() {
        let stack = EditStack()
        XCTAssertEqual(stack.history.count, 1)
        XCTAssertEqual(stack.history[0].name, "Import")
        XCTAssertEqual(stack.current, DevelopSettings())
        XCTAssertFalse(stack.canUndo)
        XCTAssertFalse(stack.canRedo)
    }

    func testRecordAppendsAndMovesCursor() {
        var stack = EditStack()
        stack.record("Exposure +1.00", settings: settings(exposure: 1))
        XCTAssertEqual(stack.history.count, 2)
        XCTAssertEqual(stack.current.basic.exposure, 1)
        XCTAssertTrue(stack.canUndo)
    }

    func testRecordingIdenticalSettingsIsIgnored() {
        var stack = EditStack()
        stack.record("No-op", settings: DevelopSettings())
        XCTAssertEqual(stack.history.count, 1)
    }

    func testUndoRedo() {
        var stack = EditStack()
        stack.record("Exposure +1.00", settings: settings(exposure: 1))
        stack.record("Exposure +2.00", settings: settings(exposure: 2))
        XCTAssertEqual(stack.undo().basic.exposure, 1)
        XCTAssertEqual(stack.undo().basic.exposure, 0)
        XCTAssertFalse(stack.canUndo)
        XCTAssertEqual(stack.redo().basic.exposure, 1)
        XCTAssertTrue(stack.canRedo)
    }

    func testRecordAfterUndoTruncatesRedoTail() {
        var stack = EditStack()
        stack.record("Exposure +1.00", settings: settings(exposure: 1))
        stack.record("Exposure +2.00", settings: settings(exposure: 2))
        stack.undo()
        stack.record("Contrast +50", settings: {
            var s = settings(exposure: 1)
            s.basic.contrast = 50
            return s
        }())
        XCTAssertEqual(stack.history.count, 3)
        XCTAssertFalse(stack.canRedo)
        XCTAssertEqual(stack.current.basic.contrast, 50)
    }

    func testAmendCoalescesSliderDrag() {
        var stack = EditStack()
        stack.record("Exposure +0.10", settings: settings(exposure: 0.1))
        stack.amend("Exposure +0.50", settings: settings(exposure: 0.5))
        stack.amend("Exposure +1.20", settings: settings(exposure: 1.2))
        XCTAssertEqual(stack.history.count, 2, "drag must collapse into one history step")
        XCTAssertEqual(stack.current.basic.exposure, 1.2)
        XCTAssertEqual(stack.history.last?.name, "Exposure +1.20")
    }

    func testJumpDoesNotTruncate() {
        var stack = EditStack()
        stack.record("A", settings: settings(exposure: 1))
        stack.record("B", settings: settings(exposure: 2))
        let firstID = stack.history[1].id
        stack.jump(to: firstID)
        XCTAssertEqual(stack.current.basic.exposure, 1)
        XCTAssertEqual(stack.history.count, 3, "jumping through history must not delete steps")
        XCTAssertTrue(stack.canRedo)
    }

    func testSnapshotsRestoreAsHistoryStep() {
        var stack = EditStack()
        stack.record("Exposure +1.00", settings: settings(exposure: 1))
        stack.addSnapshot(named: "Bright")
        stack.record("Exposure -2.00", settings: settings(exposure: -2))
        stack.restoreSnapshot(stack.snapshots[0].id)
        XCTAssertEqual(stack.current.basic.exposure, 1)
        XCTAssertEqual(stack.history.last?.name, "Restore Snapshot: Bright")
        XCTAssertEqual(stack.history.count, 4)
    }

    func testResetReturnsToImportState() {
        var stack = EditStack(initial: settings(exposure: 0.3))
        stack.record("Exposure +2.00", settings: settings(exposure: 2))
        stack.reset()
        XCTAssertEqual(stack.current.basic.exposure, 0.3)
    }

    func testCodableRoundTrip() throws {
        var stack = EditStack()
        stack.record("Exposure +1.00", settings: settings(exposure: 1))
        stack.addSnapshot(named: "Snap")
        let data = try JSONEncoder().encode(stack)
        let decoded = try JSONDecoder().decode(EditStack.self, from: data)
        XCTAssertEqual(decoded, stack)
    }

    // MARK: Settings subsets (copy / sync)

    func testApplyingSubsetOnlyCopiesChosenPanels() {
        var source = DevelopSettings()
        source.basic.exposure = 2
        source.effects.grainAmount = 40
        source.crop = CropSettings(x: 0.1, y: 0.1, width: 0.5, height: 0.5)

        var target = DevelopSettings()
        target.basic.contrast = 10

        let merged = target.applying(source, subset: [.effects])
        XCTAssertEqual(merged.effects.grainAmount, 40)
        XCTAssertEqual(merged.basic.exposure, 0, "basic panel was not in the subset")
        XCTAssertEqual(merged.basic.contrast, 10, "target's own panels must survive")
        XCTAssertNil(merged.crop, "crop was not in the subset")
    }

    func testDefaultCopySubsetExcludesGeometry() {
        XCTAssertFalse(SettingsSubset.defaultCopy.contains(.crop))
        XCTAssertFalse(SettingsSubset.defaultCopy.contains(.spots))
        XCTAssertFalse(SettingsSubset.defaultCopy.contains(.transform))
        XCTAssertTrue(SettingsSubset.defaultCopy.contains(.basic))
        XCTAssertTrue(SettingsSubset.defaultCopy.contains(.masks))
    }
}
