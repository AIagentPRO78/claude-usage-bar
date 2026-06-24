import Foundation

// Plain-assertion enterprise tests, called from Tests.swift's TestMain.
func runEnterpriseTests(check: (Bool, String) -> Void, approx: (Double, Double, Double) -> Bool) {
    // --- parseAmountCents: API amounts are fractional-cents strings ---
    check(approx(parseAmountCents("41280.000000") ?? -1, 412.80, 1e-6), "parseAmountCents cents->dollars")
    check(parseAmountCents("0") == 0, "parseAmountCents zero")
    check(parseAmountCents("not-a-number") == nil, "parseAmountCents invalid -> nil")
}
