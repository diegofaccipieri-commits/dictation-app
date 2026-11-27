import Testing
@testable import RelogioDuploCore

@Suite struct SystemClockPlanTests {
    let digitalWithDate = ["IsAnalog": 0, "ShowDate": 1, "ShowDayOfWeek": 1]
    let compact = ["IsAnalog": 1, "ShowDate": 2, "ShowDayOfWeek": 0]

    @Test func compactingWritesOnlyWhatDiffersAndKeepsTheOriginal() {
        let plan = SystemClockPlan.compact(current: ["IsAnalog": 0, "ShowDate": 2], backup: nil)
        #expect(plan.writes == ["IsAnalog": 1, "ShowDayOfWeek": 0])
        #expect(plan.removals.isEmpty)
        #expect(plan.backup == ["IsAnalog": 0, "ShowDate": 2])
    }

    @Test func compactingAnAlreadyCompactClockWritesNothing() {
        let plan = SystemClockPlan.compact(current: compact, backup: nil)
        #expect(plan.writes.isEmpty)
        #expect(plan.backup == compact)
    }

    @Test func compactingAgainNeverOverwritesTheFirstBackup() {
        let plan = SystemClockPlan.compact(current: compact, backup: digitalWithDate)
        #expect(plan.writes.isEmpty)
        #expect(plan.backup == digitalWithDate)
    }

    @Test func restoringPutsBackWhatThePersonHad() {
        let plan = SystemClockPlan.restore(current: compact, backup: ["IsAnalog": 0, "ShowDate": 1])
        #expect(plan?.writes == ["IsAnalog": 0, "ShowDate": 1])
        #expect(plan?.removals == ["ShowDayOfWeek"])   // a pessoa não tinha essa chave
        #expect(plan?.backup == nil)
    }

    @Test func restoringWithoutBackupDoesNothing() {
        #expect(SystemClockPlan.restore(current: compact, backup: nil) == nil)
    }
}
