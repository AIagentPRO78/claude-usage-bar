import Foundation

// Lightweight test runner for the pure logic in UsageCore.swift.
// Build & run:  ./build.sh test   (or see run-tests.sh)
// No XCTest/SPM dependency — keeps the project a plain swiftc build.

@main
struct TestMain {
    static var passed = 0
    static var failed = 0

    static func check(_ cond: Bool, _ name: String) {
        if cond { passed += 1 }
        else { failed += 1; FileHandle.standardError.write("FAIL: \(name)\n".data(using: .utf8)!) }
    }

    static func approx(_ a: Double, _ b: Double, _ eps: Double = 1e-6) -> Bool { abs(a - b) < eps }

    static func entry(_ model: String, date: Date, input: Int = 0, output: Int = 0,
                      cacheRead: Int = 0, w5: Int = 0, w1: Int = 0, key: String? = nil) -> Entry {
        Entry(date: date, model: model, input: input, output: output,
              cacheRead: cacheRead, cacheWrite5m: w5, cacheWrite1h: w1, dedupKey: key)
    }

    static func ref(_ t: TimeInterval) -> Date { Date(timeIntervalSinceReferenceDate: t) }

    static func main() {
        // --- pricing / cost ---
        check(pricing(for: "claude-opus-4-8")?.output == 75, "opus output price")
        check(pricing(for: "claude-sonnet-4-6")?.input == 3, "sonnet input price")
        check(pricing(for: "<synthetic>") == nil, "synthetic has no price")

        let opus1M = entry("claude-opus-4-8", date: ref(0), input: 1_000_000)
        check(approx(opus1M.cost, 15.0), "opus 1M input = $15")
        let mixed = entry("claude-opus-4-8", date: ref(0), output: 1_000_000, cacheRead: 1_000_000)
        check(approx(mixed.cost, 75.0 + 1.5), "opus output+cacheRead cost")
        check(entry("gpt-4", date: ref(0), input: 1_000_000).cost == 0, "unknown model costs 0")

        check(shortModel("claude-opus-4-8") == "Opus", "shortModel opus")

        // --- totals ---
        var t = Totals()
        t.add(entry("claude-opus-4-8", date: ref(0), input: 10, output: 20, cacheRead: 30, w5: 1, w1: 2))
        check(t.input == 10 && t.output == 20 && t.cacheRead == 30, "totals components")
        check(t.cacheWrite == 3, "totals cacheWrite = 5m+1h")
        check(t.tokens == 63, "totals total tokens")
        check(t.byModel["Opus"]?.tokens == 63, "totals per-model")

        // --- dedup (global) ---
        let dupes = [
            entry("claude-opus-4-8", date: ref(0), input: 5, key: "m1|r1"),
            entry("claude-opus-4-8", date: ref(1), input: 5, key: "m1|r1"),   // dup
            entry("claude-opus-4-8", date: ref(2), input: 5, key: "m2|r2"),
            entry("claude-opus-4-8", date: ref(3), input: 5, key: nil),       // keyless always kept
            entry("claude-opus-4-8", date: ref(4), input: 5, key: nil),
        ]
        check(dedupeEntries(dupes).count == 4, "dedup drops one keyed dupe, keeps keyless")

        // --- floorHour ---
        check(floorHour(ref(3661)) == ref(3600), "floorHour floors to hour grid")
        check(floorHour(ref(7200)) == ref(7200), "floorHour exact boundary unchanged")

        // --- activeBlock ---
        // Two entries 6h apart => two blocks; the second is the active one.
        let now = ref(6 * 3600 + 60)   // 1 min into the 2nd entry's life
        let blk = activeBlock([
            entry("claude-opus-4-8", date: ref(0), input: 100, key: "a"),
            entry("claude-opus-4-8", date: ref(6 * 3600), input: 200, key: "b"),
        ], now: now)
        check(blk.isActive, "block active when now < reset")
        check(blk.totals.input == 200, "active block only counts its own entries")
        check(blk.resetAt == ref(6 * 3600).addingTimeInterval(K.fiveHours), "block reset = start+5h")

        // Idle: last activity 6h ago, now beyond reset => inactive.
        let idle = activeBlock([entry("claude-opus-4-8", date: ref(0), input: 1, key: "x")],
                               now: ref(6 * 3600))
        check(!idle.isActive, "block inactive after 5h elapsed")

        // Empty input.
        check(!activeBlock([], now: ref(0)).isActive, "empty entries => no active block")

        // --- today / month windows ---
        let nowReal = Date()
        let todayStart = Calendar.current.startOfDay(for: nowReal)
        let mixedDays = [
            entry("claude-opus-4-8", date: todayStart.addingTimeInterval(60), input: 100, key: "t1"),
            entry("claude-opus-4-8", date: todayStart.addingTimeInterval(-3600), input: 999, key: "y1"), // yesterday
        ]
        check(todayTotals(mixedDays, now: nowReal).input == 100, "todayTotals excludes prior day")
        check(monthTotals(mixedDays, now: nowReal).input >= 100, "monthTotals includes today")

        // --- projection ---
        let monthStart = startOfMonth(nowReal)
        let tenDaysIn = monthStart.addingTimeInterval(10 * 86400)
        let proj = projectedMonthCost(100, now: tenDaysIn)
        check(proj > 100 && proj.isFinite, "projection scales up from elapsed fraction")
        check(approx(projectedMonthCost(50, now: monthStart), 50), "projection at month start = cost")

        // --- formatting ---
        check(fmtTokens(950) == "950", "fmtTokens < 1k raw")
        check(fmtTokens(12_300) == "12K", "fmtTokens K")
        check(fmtTokens(1_500_000) == "1.50M", "fmtTokens M")
        check(fmtCost(4.3) == "$4.30", "fmtCost two decimals")
        check(fmtRemaining(ref(3600), now: ref(0)) == "1h 0m", "fmtRemaining hours")
        check(fmtRemaining(ref(120), now: ref(0)) == "2m", "fmtRemaining minutes only")
        check(fmtRemaining(ref(0), now: ref(100)) == "0m", "fmtRemaining clamps negative")

        runEnterpriseTests(check: TestMain.check, approx: TestMain.approx)

        print("\(passed) passed, \(failed) failed")
        exit(failed == 0 ? 0 : 1)
    }
}
