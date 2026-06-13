import Foundation

// MARK: - Constants

enum K {
    static let fiveHours: TimeInterval = 5 * 3600
    static let secondsPerHour: TimeInterval = 3600
}

// MARK: - Pricing (USD per 1M tokens)

struct Pricing {
    let input: Double      // per MTok
    let output: Double
    let cacheRead: Double
    let cacheWrite5m: Double
    let cacheWrite1h: Double
}

/// Match by substring on the model id. Returns nil for synthetic/unknown models.
func pricing(for model: String) -> Pricing? {
    let m = model.lowercased()
    if m.contains("opus") {
        return Pricing(input: 15, output: 75, cacheRead: 1.5, cacheWrite5m: 18.75, cacheWrite1h: 30)
    }
    if m.contains("sonnet") {
        return Pricing(input: 3, output: 15, cacheRead: 0.3, cacheWrite5m: 3.75, cacheWrite1h: 6)
    }
    if m.contains("haiku") {
        return Pricing(input: 1, output: 5, cacheRead: 0.1, cacheWrite5m: 1.25, cacheWrite1h: 2)
    }
    return nil
}

func shortModel(_ m: String) -> String {
    let s = m.lowercased()
    if s.contains("opus") { return "Opus" }
    if s.contains("sonnet") { return "Sonnet" }
    if s.contains("haiku") { return "Haiku" }
    return m
}

// MARK: - Parsed usage entry

struct Entry {
    let date: Date
    let model: String
    let input: Int
    let output: Int
    let cacheRead: Int
    let cacheWrite5m: Int
    let cacheWrite1h: Int
    /// `message.id|requestId`, or nil when neither was present. Used for dedup.
    let dedupKey: String?

    var totalTokens: Int { input + output + cacheRead + cacheWrite5m + cacheWrite1h }

    var cost: Double {
        guard let p = pricing(for: model) else { return 0 }
        let d = 1_000_000.0
        return Double(input)        / d * p.input
             + Double(output)       / d * p.output
             + Double(cacheRead)    / d * p.cacheRead
             + Double(cacheWrite5m) / d * p.cacheWrite5m
             + Double(cacheWrite1h) / d * p.cacheWrite1h
    }
}

/// Drop duplicate entries that share a `dedupKey`, keeping the first seen.
/// Entries with no key (nil) are always kept. Claude Code can replay the same
/// assistant message across files (resumed/compacted sessions, sub-agents), so
/// dedup must be global — matching ccusage's message-id+request-id strategy.
func dedupeEntries(_ entries: [Entry]) -> [Entry] {
    var seen = Set<String>()
    var out: [Entry] = []
    out.reserveCapacity(entries.count)
    for e in entries {
        if let key = e.dedupKey {
            if seen.contains(key) { continue }
            seen.insert(key)
        }
        out.append(e)
    }
    return out
}

// MARK: - JSONL parsing with per-file mtime cache

final class UsageScanner {
    private let root: URL
    private var cache: [String: (mtime: Date, entries: [Entry])] = [:]

    private let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let isoNoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        root = home.appendingPathComponent(".claude/projects")
    }

    private func parseDate(_ s: String) -> Date? {
        iso.date(from: s) ?? isoNoFrac.date(from: s)
    }

    /// Re-scan the tree, reparsing only files whose mtime changed. Returns all
    /// entries from this month's transcripts, globally deduped.
    func scan() -> [Entry] {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: root,
                                     includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                                     options: [.skipsHiddenFiles]) else { return [] }

        // We report month-to-date, so parse files touched since the start of this
        // month (local). Anything older can't contain this month's / today's / the
        // active block's entries. Bounds work to the current month's transcripts.
        let cutoff = startOfMonth(Date())

        var livePaths = Set<String>()
        for case let url as URL in en {
            guard url.pathExtension == "jsonl" else { continue }
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
            guard mtime >= cutoff else { continue }
            let path = url.path
            livePaths.insert(path)
            if let cached = cache[path], cached.mtime == mtime { continue }
            cache[path] = (mtime, parseFile(url))
        }
        // Drop deleted files from cache.
        for key in cache.keys where !livePaths.contains(key) { cache[key] = nil }

        var out: [Entry] = []
        for (_, v) in cache { out.append(contentsOf: v.entries) }
        return dedupeEntries(out)
    }

    private func parseFile(_ url: URL) -> [Entry] {
        guard let data = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var entries: [Entry] = []
        data.enumerateLines { line, _ in
            guard !line.isEmpty,
                  let d = line.data(using: .utf8),
                  let obj = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any],
                  let msg = obj["message"] as? [String: Any],
                  let usage = msg["usage"] as? [String: Any] else { return }

            let model = (msg["model"] as? String) ?? ""
            guard pricing(for: model) != nil else { return }   // skip synthetic/unknown

            guard let ts = obj["timestamp"] as? String, let date = self.parseDate(ts) else { return }

            let mid = (msg["id"] as? String) ?? ""
            let rid = (obj["requestId"] as? String) ?? ""
            let key = (mid.isEmpty && rid.isEmpty) ? nil : mid + "|" + rid

            let input = (usage["input_tokens"] as? Int) ?? 0
            let output = (usage["output_tokens"] as? Int) ?? 0
            let cacheRead = (usage["cache_read_input_tokens"] as? Int) ?? 0

            var w5 = 0, w1 = 0
            if let cc = usage["cache_creation"] as? [String: Any] {
                w5 = (cc["ephemeral_5m_input_tokens"] as? Int) ?? 0
                w1 = (cc["ephemeral_1h_input_tokens"] as? Int) ?? 0
            } else {
                w5 = (usage["cache_creation_input_tokens"] as? Int) ?? 0
            }

            entries.append(Entry(date: date, model: model, input: input, output: output,
                                 cacheRead: cacheRead, cacheWrite5m: w5, cacheWrite1h: w1, dedupKey: key))
        }
        return entries
    }
}

// MARK: - Aggregation

struct Totals {
    var input = 0
    var output = 0
    var cacheWrite = 0      // 5m + 1h writes
    var cacheRead = 0
    var cost = 0.0
    var byModel: [String: (tokens: Int, cost: Double)] = [:]

    var tokens: Int { input + output + cacheWrite + cacheRead }

    mutating func add(_ e: Entry) {
        input += e.input
        output += e.output
        cacheWrite += e.cacheWrite5m + e.cacheWrite1h
        cacheRead += e.cacheRead
        cost += e.cost
        let label = shortModel(e.model)
        var cur = byModel[label] ?? (0, 0)
        cur.tokens += e.totalTokens
        cur.cost += e.cost
        byModel[label] = cur
    }
}

func floorHour(_ d: Date) -> Date {
    // Reference date is on a UTC hour boundary, so flooring the absolute time to a
    // 3600s grid yields UTC hour starts (matching ccusage).
    let t = d.timeIntervalSinceReferenceDate
    return Date(timeIntervalSinceReferenceDate: (t / K.secondsPerHour).rounded(.down) * K.secondsPerHour)
}

struct BlockResult {
    var totals = Totals()
    var startEntry: Date?
    var resetAt: Date?
    var isActive = false
}

/// ccusage-style 5-hour billing blocks: floor first activity to the hour; a new
/// block starts when an entry is >=5h past the block start OR >=5h after the
/// previous entry. Only the most recent block is materialised — that's all the UI
/// shows — so earlier blocks are discarded as we go.
func activeBlock(_ entries: [Entry], now: Date) -> BlockResult {
    let sorted = entries.sorted { $0.date < $1.date }
    var curStart: Date?
    var last: Date?
    var cur: [Entry] = []

    for e in sorted {
        if let cs = curStart, let lt = last,
           e.date.timeIntervalSince(cs) >= K.fiveHours || e.date.timeIntervalSince(lt) >= K.fiveHours {
            cur.removeAll(keepingCapacity: true)   // start a fresh block; drop the old one
            curStart = floorHour(e.date)
        } else if curStart == nil {
            curStart = floorHour(e.date)
        }
        cur.append(e)
        last = e.date
    }

    var result = BlockResult()
    guard let start = curStart else { return result }
    let reset = start.addingTimeInterval(K.fiveHours)
    result.startEntry = start
    result.resetAt = reset
    result.isActive = now < reset
    if result.isActive {
        for e in cur { result.totals.add(e) }
    }
    return result
}

func todayTotals(_ entries: [Entry], now: Date) -> Totals {
    let start = Calendar.current.startOfDay(for: now)
    var t = Totals()
    for e in entries where e.date >= start { t.add(e) }
    return t
}

func startOfMonth(_ d: Date) -> Date {
    let cal = Calendar.current
    return cal.date(from: cal.dateComponents([.year, .month], from: d)) ?? d
}

func monthTotals(_ entries: [Entry], now: Date) -> Totals {
    let start = startOfMonth(now)
    var t = Totals()
    for e in entries where e.date >= start { t.add(e) }
    return t
}

/// Linear projection of this month's API-equivalent cost from elapsed fraction.
func projectedMonthCost(_ monthCost: Double, now: Date) -> Double {
    let cal = Calendar.current
    let start = startOfMonth(now)
    guard let next = cal.date(byAdding: .month, value: 1, to: start) else { return monthCost }
    let elapsed = now.timeIntervalSince(start)
    let total = next.timeIntervalSince(start)
    guard elapsed > 0 else { return monthCost }
    return monthCost * (total / elapsed)
}

// MARK: - Formatting

func fmtTokens(_ n: Int) -> String {
    let d = Double(n)
    if d >= 1_000_000 { return String(format: "%.2fM", d / 1_000_000) }
    if d >= 1_000 { return String(format: "%.0fK", d / 1_000) }
    return "\(n)"
}

func fmtCost(_ c: Double) -> String { String(format: "$%.2f", c) }

func fmtRemaining(_ reset: Date, now: Date) -> String {
    let s = max(0, reset.timeIntervalSince(now))
    let h = Int(s) / 3600
    let m = (Int(s) % 3600) / 60
    return h > 0 ? "\(h)h \(m)m" : "\(m)m"
}
