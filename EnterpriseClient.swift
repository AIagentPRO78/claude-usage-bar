import Foundation

enum AnalyticsError: Error, Equatable {
    case auth            // 401 / 403
    case http(Int)
    case transport       // network/offline/timeout
    case decode
}

private let analyticsBase = URL(string: "https://api.anthropic.com")!

let SUMMARIES_PATH   = "/v1/organizations/analytics/summaries"
let USAGE_PATH       = "/v1/organizations/analytics/usage_report"
let COST_PATH        = "/v1/organizations/analytics/cost_report"
let USER_USAGE_PATH  = "/v1/organizations/analytics/user_usage_report"
let USER_COST_PATH   = "/v1/organizations/analytics/user_cost_report"

func makeAnalyticsRequest(path: String, apiKey: String, query: [URLQueryItem]) -> URLRequest {
    var comps = URLComponents(url: analyticsBase.appendingPathComponent(path),
                              resolvingAgainstBaseURL: false)!
    comps.queryItems = query.isEmpty ? nil : query
    var req = URLRequest(url: comps.url!)
    req.httpMethod = "GET"
    req.setValue(apiKey, forHTTPHeaderField: "x-api-key")
    req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
    req.timeoutInterval = 20
    return req
}

protocol AnalyticsFetching {
    func get(path: String, query: [URLQueryItem]) throws -> Data
}

// Synchronous GET (runs on the enterprise background queue) using the stored key.
struct URLSessionAnalyticsClient: AnalyticsFetching {
    let apiKey: String
    let session: URLSession = .shared

    func get(path: String, query: [URLQueryItem]) throws -> Data {
        let req = makeAnalyticsRequest(path: path, apiKey: apiKey, query: query)
        let sem = DispatchSemaphore(value: 0)
        var result: Result<Data, AnalyticsError> = .failure(.transport)
        let task = session.dataTask(with: req) { data, resp, err in
            defer { sem.signal() }
            if err != nil { result = .failure(.transport); return }
            guard let http = resp as? HTTPURLResponse else { result = .failure(.transport); return }
            switch http.statusCode {
            case 200...299: result = .success(data ?? Data())
            case 401, 403:  result = .failure(.auth)
            default:        result = .failure(.http(http.statusCode))
            }
        }
        task.resume()
        sem.wait()
        switch result {
        case .success(let d): return d
        case .failure(let e): throw e
        }
    }
}

private let ymdUTCFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone(identifier: "UTC")
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

// summaries uses starting_date/ending_date (YYYY-MM-DD); starting_date must be
// >= 3 days ago, so clamp the month start back if we're in the first days of a month.
private func ymdUTC(_ d: Date) -> String { ymdUTCFormatter.string(from: d) }

private func startOfMonthUTC(_ now: Date) -> Date {
    var cal = Calendar(identifier: .gregorian)
    cal.timeZone = TimeZone(identifier: "UTC")!
    return cal.date(from: cal.dateComponents([.year, .month], from: now)) ?? now
}

func summariesQuery(now: Date) -> [URLQueryItem] {
    let monthStart = startOfMonthUTC(now)
    let threeDaysAgo = now.addingTimeInterval(-3 * 86400)
    let start = min(monthStart, threeDaysAgo)
    return [URLQueryItem(name: "starting_date", value: ymdUTC(start))]
}

// Note: summariesQuery uses date-only params (starting_date, YYYY-MM-DD) while
// reportQuery uses RFC3339 params (starting_at/ending_at) — both anchored to the
// same UTC month start, but on slightly different time grids per the API.
func reportQuery(now: Date) -> [URLQueryItem] {
    let start = startOfMonthUTC(now)
    return [
        URLQueryItem(name: "starting_at", value: rfc3339.string(from: start)),
        URLQueryItem(name: "ending_at", value: rfc3339.string(from: now)),
        URLQueryItem(name: "bucket_width", value: "1d"),
        URLQueryItem(name: "limit", value: "31"),   // a full month of daily buckets fits one page
    ]
}

func fetchEnterpriseState(_ fetcher: AnalyticsFetching, now: Date, lastGood: OrgRollup?) -> EnterpriseState {
    let sQ = summariesQuery(now: now)
    let rQ = reportQuery(now: now)
    do {
        let payloads = AnalyticsPayloads(
            summaries: try fetcher.get(path: SUMMARIES_PATH, query: sQ),
            usage:     try fetcher.get(path: USAGE_PATH, query: rQ),
            cost:      try fetcher.get(path: COST_PATH, query: rQ),
            userUsage: try fetcher.get(path: USER_USAGE_PATH, query: rQ),
            userCost:  try fetcher.get(path: USER_COST_PATH, query: rQ))
        let rollup = try assembleRollup(payloads)
        return .ok(rollup)
    } catch AnalyticsError.auth {
        return .authFailed
    } catch {
        var stale = lastGood
        stale?.stale = true
        return .offline(stale)
    }
}
