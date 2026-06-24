import Foundation

// Pure logic for the Enterprise Analytics module: domain types, response
// decoding, aggregation, and formatting. No AppKit, no network — exercised by
// EnterpriseTests.swift. Reuses fmtCost/fmtTokens from UsageCore.swift.

// MARK: - Amounts

/// API cost amounts are decimal strings in fractional cents ("41280.000000" =
/// $412.80). Returns USD dollars, or nil if unparseable.
func parseAmountCents(_ s: String) -> Double? {
    guard let cents = Double(s) else { return nil }
    return cents / 100.0
}

// MARK: - Domain types

struct ActiveSeat: Equatable {
    let userId: String
    let name: String?     // "Jane Smith"; "Deleted User" when deleted; nil if unavailable
    let email: String?
    let tokens: Int?
    let cost: Double?     // USD dollars
}

struct OrgRollup: Equatable {
    var asOf: Date?
    var seatsAssigned: Int = 0
    var dau: Int = 0
    var wau: Int = 0
    var mau: Int = 0
    var requests: Int? = nil
    var tokens: Int? = nil
    var cost: Double? = nil          // USD dollars (credits-as-USD on seat plans)
    var activeSeats: [ActiveSeat] = []   // sorted by cost desc
    var stale: Bool = false
}

enum EnterpriseState: Equatable {
    case notConfigured
    case authFailed
    case offline(OrgRollup?)   // last good rollup, if any
    case ok(OrgRollup)
}

// MARK: - Summaries

let rfc3339: ISO8601DateFormatter = {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime]
    return f
}()

struct SummariesResponse: Decodable {
    struct Bucket: Decodable {
        let startingAt: String
        let assignedSeatCount: Int
        let dailyActiveUserCount: Int
        let weeklyActiveUserCount: Int
        let monthlyActiveUserCount: Int
        enum CodingKeys: String, CodingKey {
            case startingAt              = "starting_at"
            case assignedSeatCount       = "assigned_seat_count"
            case dailyActiveUserCount    = "daily_active_user_count"
            case weeklyActiveUserCount   = "weekly_active_user_count"
            case monthlyActiveUserCount  = "monthly_active_user_count"
        }
    }
    let summaries: [Bucket]
}

func applySummaries(_ data: Data, into rollup: inout OrgRollup) throws {
    let resp = try JSONDecoder().decode(SummariesResponse.self, from: data)
    guard let latest = resp.summaries.max(by: { $0.startingAt < $1.startingAt }) else { return }
    rollup.seatsAssigned = latest.assignedSeatCount
    rollup.dau = latest.dailyActiveUserCount
    rollup.wau = latest.weeklyActiveUserCount
    rollup.mau = latest.monthlyActiveUserCount
    rollup.asOf = rfc3339.date(from: latest.startingAt)
}

// MARK: - Aggregate usage + cost (bucketed: data[].results[])

struct UsageReportResponse: Decodable {
    struct CacheCreation: Decodable {
        let ephemeral1h: Int?
        let ephemeral5m: Int?
        enum CodingKeys: String, CodingKey {
            case ephemeral1h = "ephemeral_1h_input_tokens"
            case ephemeral5m = "ephemeral_5m_input_tokens"
        }
    }
    struct Result: Decodable {
        let uncachedInputTokens: Int?
        let cacheReadInputTokens: Int?
        let cacheCreation: CacheCreation?
        let outputTokens: Int?
        let requests: Int?
        enum CodingKeys: String, CodingKey {
            case uncachedInputTokens = "uncached_input_tokens"
            case cacheReadInputTokens = "cache_read_input_tokens"
            case cacheCreation = "cache_creation"
            case outputTokens = "output_tokens"
            case requests
        }
        var tokenSum: Int {
            (uncachedInputTokens ?? 0) + (cacheReadInputTokens ?? 0)
            + (cacheCreation?.ephemeral1h ?? 0) + (cacheCreation?.ephemeral5m ?? 0)
            + (outputTokens ?? 0)
        }
    }
    struct Bucket: Decodable { let results: [Result] }
    let data: [Bucket]
}

func applyAggregateUsage(_ data: Data, into rollup: inout OrgRollup) throws {
    let resp = try JSONDecoder().decode(UsageReportResponse.self, from: data)
    var tokens = 0, requests = 0
    for bucket in resp.data {
        for r in bucket.results {
            tokens += r.tokenSum
            requests += (r.requests ?? 0)
        }
    }
    rollup.tokens = tokens
    rollup.requests = requests
}

struct CostReportResponse: Decodable {
    struct Result: Decodable { let amount: String? }
    struct Bucket: Decodable { let results: [Result] }
    let data: [Bucket]
}

func applyAggregateCost(_ data: Data, into rollup: inout OrgRollup) throws {
    let resp = try JSONDecoder().decode(CostReportResponse.self, from: data)
    var total = 0.0
    var any = false
    for bucket in resp.data {
        for r in bucket.results {
            if let a = r.amount, let usd = parseAmountCents(a) { total += usd; any = true }
        }
    }
    rollup.cost = any ? total : nil
}
