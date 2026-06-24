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
}
