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

    // --- active seats: join user_cost_report (amount) + user_usage_report (total_tokens) ---
    let userCostJSON = """
    {"data":[
      {"actor":{"user_id":"u1","email":"jane@example.com","name":"Jane Smith","deleted":false},"amount":"9620.000000","currency":"USD"},
      {"actor":{"user_id":"u2","email":"bob@example.com","name":"Bob Lee","deleted":false},"amount":"6110.000000","currency":"USD"},
      {"actor":{"user_id":"u3","email":null,"name":"Deleted User","deleted":true},"amount":"500.000000","currency":"USD"}
    ]}
    """
    let userUsageJSON = """
    {"data":[
      {"actor":{"user_id":"u1","email":"jane@example.com","name":"Jane Smith","deleted":false},"total_tokens":45000000},
      {"actor":{"user_id":"u2","email":"bob@example.com","name":"Bob Lee","deleted":false},"total_tokens":30000000}
    ]}
    """
    do {
        let seats = try buildActiveSeats(costData: Data(userCostJSON.utf8), usageData: Data(userUsageJSON.utf8))
        check(seats.count == 3, "active seats: one per distinct user_id")
        check(seats[0].userId == "u1" && seats[0].name == "Jane Smith", "active seats sorted by cost desc")
        check(approx(seats[0].cost ?? -1, 96.20, 1e-6), "seat cost mapped (cents->USD)")
        check(seats[0].tokens == 45000000, "seat tokens from total_tokens")
        check(seats[1].userId == "u2", "second by cost")
        check(seats[2].name == "Deleted User" && seats[2].tokens == nil, "deleted user kept; no usage row => tokens nil")
    } catch { check(false, "buildActiveSeats threw: \(error)") }

    // --- top-N cap ---
    let many = (1...12).map { ActiveSeat(userId: "u\($0)", name: "U\($0)", email: nil, tokens: nil, cost: Double(20 - $0)) }
    let capped = topSeats(many, limit: 10)
    check(capped.shown.count == 10 && capped.more == 2, "topSeats caps to 10 with +2 more")
    let few = topSeats(Array(many.prefix(3)), limit: 10)
    check(few.shown.count == 3 && few.more == 0, "topSeats no overflow when under limit")

    // --- assembleRollup wires all five payloads together ---
    do {
        let p = AnalyticsPayloads(
            summaries: Data(summariesJSON.utf8),
            usage: Data(usageJSON.utf8),
            cost: Data(costJSON.utf8),
            userUsage: Data(userUsageJSON.utf8),
            userCost: Data(userCostJSON.utf8))
        let roll = try assembleRollup(p)
        check(roll.seatsAssigned == 12 && roll.dau == 8, "assembled summaries")
        check(roll.requests == 3400 && roll.tokens == 205000000, "assembled aggregate usage")
        check(approx(roll.cost ?? -1, 214.50, 1e-6), "assembled cost")
        check(roll.activeSeats.count == 3 && roll.activeSeats[0].name == "Jane Smith", "assembled active seats")
    } catch { check(false, "assembleRollup threw: \(error)") }

    // --- request construction ---
    let req = makeAnalyticsRequest(path: "/v1/organizations/analytics/summaries",
                                   apiKey: "TEST-API-KEY-PLACEHOLDER",
                                   query: [URLQueryItem(name: "bucket_width", value: "1d")])
    check(req.url?.absoluteString == "https://api.anthropic.com/v1/organizations/analytics/summaries?bucket_width=1d",
          "request url + query")
    check(req.value(forHTTPHeaderField: "x-api-key") == "TEST-API-KEY-PLACEHOLDER", "request x-api-key header")
    check(req.value(forHTTPHeaderField: "anthropic-version") == "2023-06-01", "request version header")

    // --- orchestration via stub fetcher ---
    struct StubFetcher: AnalyticsFetching {
        let byPath: [String: Data]
        let throwError: AnalyticsError?
        func get(path: String, query: [URLQueryItem]) throws -> Data {
            if let e = throwError { throw e }
            return byPath[path] ?? Data("{\"data\":[]}".utf8)
        }
    }
    let okStub = StubFetcher(byPath: [
        "/v1/organizations/analytics/summaries": Data(summariesJSON.utf8),
        "/v1/organizations/analytics/usage_report": Data(usageJSON.utf8),
        "/v1/organizations/analytics/cost_report": Data(costJSON.utf8),
        "/v1/organizations/analytics/user_usage_report": Data(userUsageJSON.utf8),
        "/v1/organizations/analytics/user_cost_report": Data(userCostJSON.utf8),
    ], throwError: nil)
    if case .ok(let roll) = fetchEnterpriseState(okStub, now: Date(), lastGood: nil) {
        check(roll.seatsAssigned == 12 && roll.activeSeats.count == 3, "fetchEnterpriseState ok assembles rollup")
    } else { check(false, "fetchEnterpriseState should be .ok with stub data") }

    let authStub = StubFetcher(byPath: [:], throwError: .auth)
    check(fetchEnterpriseState(authStub, now: Date(), lastGood: nil) == .authFailed, "auth error => .authFailed")

    let netStub = StubFetcher(byPath: [:], throwError: .transport)
    let prev = OrgRollup(seatsAssigned: 9)
    if case .offline(let lg) = fetchEnterpriseState(netStub, now: Date(), lastGood: prev) {
        check(lg?.seatsAssigned == 9 && lg?.stale == true, "transport error => .offline(lastGood, stale)")
    } else { check(false, "transport error should be .offline") }

    // --- query builders anchor to the UTC month boundary (regression lock for the local/UTC mix) ---
    let qNow = ISO8601DateFormatter().date(from: "2026-03-15T02:00:00Z")!
    let rq = reportQuery(now: qNow)
    let rqStart = rq.first { $0.name == "starting_at" }?.value ?? ""
    check(rqStart.hasPrefix("2026-03-01"), "reportQuery starting_at uses UTC month start")
    let sq = summariesQuery(now: qNow)
    let sqStart = sq.first { $0.name == "starting_date" }?.value ?? ""
    check(sqStart == "2026-03-01", "summariesQuery starting_date uses UTC month start")
}
