import Foundation

// Plain-assertion enterprise tests, called from Tests.swift's TestMain.
func runEnterpriseTests(check: (Bool, String) -> Void, approx: (Double, Double, Double) -> Bool) {
    // --- parseAmountCents: API amounts are fractional-cents strings ---
    check(approx(parseAmountCents("41280.000000") ?? -1, 412.80, 1e-6), "parseAmountCents cents->dollars")
    check(parseAmountCents("0") == 0, "parseAmountCents zero")
    check(parseAmountCents("not-a-number") == nil, "parseAmountCents invalid -> nil")

    // --- summaries decode (wrapper "summaries"; *_count fields) ---
    let summariesJSON = """
    {"summaries":[
      {"starting_at":"2026-06-19T00:00:00Z","ending_at":"2026-06-20T00:00:00Z","assigned_seat_count":12,"pending_invite_count":1,"daily_active_user_count":7,"weekly_active_user_count":10,"monthly_active_user_count":12},
      {"starting_at":"2026-06-20T00:00:00Z","ending_at":"2026-06-21T00:00:00Z","assigned_seat_count":12,"pending_invite_count":1,"daily_active_user_count":8,"weekly_active_user_count":11,"monthly_active_user_count":12}
    ]}
    """
    var r = OrgRollup()
    do {
        try applySummaries(Data(summariesJSON.utf8), into: &r)
        check(r.seatsAssigned == 12, "summaries seats")
        check(r.dau == 8 && r.wau == 11 && r.mau == 12, "summaries latest bucket DAU/WAU/MAU")
        check(r.asOf != nil, "summaries asOf set from latest starting_at")
    } catch { check(false, "applySummaries threw: \(error)") }

    // --- aggregate usage (nested data[].results[]) ---
    let usageJSON = """
    {"data":[
      {"starting_at":"2026-06-01T00:00:00Z","ending_at":"2026-06-02T00:00:00Z","results":[
        {"uncached_input_tokens":50000000,"cache_read_input_tokens":70000000,"cache_creation":{"ephemeral_1h_input_tokens":1000000,"ephemeral_5m_input_tokens":1000000},"output_tokens":8000000,"requests":1200}
      ]},
      {"starting_at":"2026-06-02T00:00:00Z","ending_at":"2026-06-03T00:00:00Z","results":[
        {"uncached_input_tokens":30000000,"cache_read_input_tokens":40000000,"cache_creation":{"ephemeral_1h_input_tokens":500000,"ephemeral_5m_input_tokens":500000},"output_tokens":4000000,"requests":2200}
      ]}
    ]}
    """
    var ru = OrgRollup()
    do {
        try applyAggregateUsage(Data(usageJSON.utf8), into: &ru)
        check(ru.requests == 3400, "aggregate requests summed across buckets")
        check(ru.tokens == 205000000, "aggregate tokens summed (uncached+cacheRead+cacheCreation+output)")
    } catch { check(false, "applyAggregateUsage threw: \(error)") }

    // --- aggregate cost (amount = fractional-cents String) ---
    let costJSON = """
    {"data":[
      {"results":[{"amount":"10025.000000","currency":"USD"}]},
      {"results":[{"amount":"11425.000000","currency":"USD"}]}
    ]}
    """
    var rc = OrgRollup()
    do {
        try applyAggregateCost(Data(costJSON.utf8), into: &rc)
        check(approx(rc.cost ?? -1, 214.50, 1e-6), "aggregate cost summed (cents->USD)")
    } catch { check(false, "applyAggregateCost threw: \(error)") }
}
