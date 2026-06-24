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
