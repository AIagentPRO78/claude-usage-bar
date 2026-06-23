# Claude Enterprise Analytics API Contract

**Status:** VERIFIED-FROM-DOC  
**Source URLs fetched:**
- `https://platform.claude.com/docs/en/manage-claude/analytics-api` (overview, key types, data freshness, amount encoding)
- `https://platform.claude.com/docs/en/api/admin/analytics` (endpoint reference — full schema)

**Keychain check:** `security find-generic-password -s com.ellerywee.claudeusagebar.analytics -a read-analytics -w` returned NO_KEY. No live curl captures were attempted; all field names below are VERIFIED-FROM-DOC.

**Base URL:** `https://api.anthropic.com`  
**Auth header:** `x-api-key: <Analytics API key>` (created in claude.ai > Organization settings > API by primary owner)  
**Required scope:** `read:analytics`  
**anthropic-version header required:** `2023-06-01`  
**Data availability:** on or after 2026-01-01. Engagement/adoption endpoints: 3-day lag. Cost/usage endpoints: typically 4h but may take up to 24h; values revisable for 30 days.

---

## Critical encoding note: amount fields

> Doc verbatim: "Amount fields are decimal strings in cents. Currency amounts are returned as decimal strings such as `"41280.000000"` (which represents $412.80). To convert to dollars, parse as a decimal and divide by 100."

- `amount` and `list_amount` are **`String` type** (not `Double`, not `Int`).
- The value is in **fractional cents** (minor units), not dollars.
- Example: `"41280.000000"` = $412.80 USD.
- **No `credits` field exists anywhere in the API schema.** The doc makes no mention of a credits field for seat-based plans. The doc says: "The cost and usage endpoints apply to usage-based Enterprise plans; for seat-based Enterprise plans, they reflect usage credits only." This means the same `amount` field is populated for seat plans but reflects credit usage — there is NO separate `credits` field.

---

## Endpoint 1: GET /v1/organizations/analytics/summaries

Returns one entry per day in `[starting_date, ending_date)`.

### Query parameters

| Parameter | Type | Required | Notes |
|-----------|------|----------|-------|
| `starting_date` | string | YES | YYYY-MM-DD UTC; must be >= 3 days in past; no earlier than 2026-01-01 |
| `ending_date` | string | NO | YYYY-MM-DD UTC, exclusive; defaults to 2 days before today; range max 366 days |

### Response: `ActivitySummary`

Top-level wrapper field: `summaries` (array).

Each element of `summaries`:

| Field | Type | Description |
|-------|------|-------------|
| `starting_at` | string | Start of aggregation period (RFC 3339, e.g. `2026-01-15T00:00:00Z`) |
| `ending_at` | string | End of aggregation period (RFC 3339, e.g. `2026-01-16T00:00:00Z`) |
| `assigned_seat_count` | number | Seats currently assigned to members |
| `pending_invite_count` | number | Pending invitations |
| `daily_active_user_count` | number | Users with token consumption on the requested day |
| `weekly_active_user_count` | number | Users with token consumption in 7-day rolling window |
| `monthly_active_user_count` | number | Users with token consumption in 30-day rolling window |
| `daily_adoption_rate` | number | DAU / assigned_seat_count * 100 |
| `weekly_adoption_rate` | number | WAU / assigned_seat_count * 100 |
| `monthly_adoption_rate` | number | MAU / assigned_seat_count * 100 |
| `cowork_daily_active_user_count` | number | Users with Cowork activity on the day |
| `cowork_weekly_active_user_count` | number | Users with Cowork activity in 7-day window |
| `cowork_monthly_active_user_count` | number | Users with Cowork activity in 30-day window |

No pagination on this endpoint (date range returns all days).

---

## Endpoint 2: GET /v1/organizations/analytics/usage_report

Token usage bucketed by time, optionally grouped by dimension.

### Query parameters

| Parameter | Type | Required | Notes |
|-----------|------|----------|-------|
| `starting_at` | string | YES | RFC 3339 tz-aware; within last 365 days; no earlier than 2026-01-01T00:00:00Z |
| `ending_at` | string | NO | RFC 3339, exclusive; defaults to min(now, starting_at + 31 days); range max 31 days |
| `bucket_width` | string | NO | `"1m"`, `"1h"`, or `"1d"` |
| `group_by` | array of string | NO | `"product"`, `"model"`, `"context_window"`, `"inference_geo"`, `"speed"` |
| `products` | array of string | NO | Filter by product surface |
| `models` | array of string | NO | Filter by model |
| `context_windows` | array of string | NO | `"0-200k"`, `"200k-1M"` |
| `inference_geos` | array of string | NO | `"global"`, `"us"`, `"not_available"` |
| `speeds` | array of string | NO | `"fast"`, `"standard"` |
| `user_ids` | array of string | NO | Filter by tagged user ID |
| `limit` | number | NO | Per-page bucket count; 1d: default 7 max 31; 1h: default 24 max 168; 1m: default 60 max 256 |
| `page` | string | NO | Opaque cursor from `next_page` |

Array params use bracket notation: `products[]=chat&products[]=claude_code`

### Response: `UsageBucket`

Top-level fields:

| Field | Type |
|-------|------|
| `data` | array of time-bucket objects |
| `data_refreshed_at` | string (RFC 3339) |
| `has_more` | boolean |
| `next_page` | string |
| `organization_id` | string |

Each element of `data`:

| Field | Type |
|-------|------|
| `starting_at` | string |
| `ending_at` | string |
| `results` | array of result objects |

Each element of `results`:

| Field | Type | Notes |
|-------|------|-------|
| `uncached_input_tokens` | number | Uncached input tokens |
| `cache_read_input_tokens` | number | Input tokens read from cache |
| `cache_creation` | object | See sub-fields below |
| `cache_creation.ephemeral_1h_input_tokens` | number | Tokens to create 1h cache entry |
| `cache_creation.ephemeral_5m_input_tokens` | number | Tokens to create 5m cache entry |
| `output_tokens` | number | Output tokens generated |
| `requests` | number | API requests (or execution spans for sandbox) |
| `server_tool_use` | object | See sub-fields below |
| `server_tool_use.web_search_requests` | number | Web search requests |
| `model` | string | Null unless `model` in `group_by[]` |
| `product` | string | Null unless `product` in `group_by[]` |
| `context_window` | string | `"0-200k"` or `"200k-1M"`; null unless in `group_by[]` |
| `inference_geo` | string | `"global"` or `"us"`; null unless in `group_by[]` |
| `speed` | string | `"fast"` or `"standard"`; null unless in `group_by[]` |

**Note: there is NO `input_tokens` field.** Input tokens are split into `uncached_input_tokens` and `cache_read_input_tokens`. There is NO `messages` field. There is NO `cache_creation_input_tokens` flat field — it is the nested object `cache_creation` with sub-fields.

---

## Endpoint 3: GET /v1/organizations/analytics/cost_report

Cost in USD bucketed by time, optionally grouped by dimension.

### Query parameters

Same as `usage_report` plus:

| Parameter | Type | Notes |
|-----------|------|-------|
| `group_by` | array | All usage_report values plus `"cost_type"` and `"token_type"` |

### Response: `CostBucket`

Top-level fields: same structure as `UsageBucket` (`data`, `data_refreshed_at`, `has_more`, `next_page`, `organization_id`).

Each element of `results` inside `data[].results`:

| Field | Type | Notes |
|-------|------|-------|
| `amount` | **string** | Post-discount, pre-credit, in fractional cents (e.g. `"41280.000000"` = $412.80) |
| `list_amount` | **string** | Pre-discount, in fractional cents |
| `currency` | string | Always `"USD"` |
| `cost_type` | string | `"tokens"`, `"web_search"`, `"code_execution"`, or null (combined total when not in group_by) |
| `token_type` | string | When `group_by[]=token_type` and `cost_type=tokens`; values: `"uncached_input_tokens"`, `"output_tokens"`, `"cache_read_input_tokens"`, `"cache_creation.ephemeral_1h_input_tokens"`, `"cache_creation.ephemeral_5m_input_tokens"`; null otherwise |
| `requests` | number | Null when group_by includes cost_type or token_type |
| `model` | string | Null unless in group_by |
| `product` | string | Null unless in group_by |
| `context_window` | string | Null unless in group_by |
| `inference_geo` | string | Null unless in group_by |
| `speed` | string | Null unless in group_by |

**Amount encoding:** `amount` is a **decimal `String`** representing fractional cents. Parse with `Decimal` (not `Double`) and divide by 100 to get USD. There is no `credits` field at the API level.

---

## Endpoint 4: GET /v1/organizations/analytics/user_usage_report

Per-user token usage across a date range, one row per user (or per user x time-bucket x dimension).

### Query parameters

| Parameter | Type | Required | Notes |
|-----------|------|----------|-------|
| `starting_at` | string | YES | RFC 3339 |
| `ending_at` | string | NO | Required when `bucket_width` is set; range max 31 days (max 24h when bucket_width=1m) |
| `bucket_width` | string | NO | `"1m"`, `"1h"`, `"1d"` |
| `group_by` | array | NO | `"product"`, `"model"`, `"context_window"`, `"inference_geo"`, `"speed"` |
| `order_by` | string | NO | `"output_tokens"`, `"uncached_input_tokens"`, `"total_tokens"` (default), `"requests"` |
| `order` | string | NO | `"desc"` (default), `"asc"` |
| `limit` | number | NO | 1-1000, default 20 |
| `page` | string | NO | Opaque cursor |
| `exclude_deleted_users` | boolean | NO | Omit deleted-account rows |
| `products` | array | NO | Filter |
| `models` | array | NO | Filter |
| `context_windows` | array | NO | Filter |
| `inference_geos` | array | NO | Filter |
| `speeds` | array | NO | Filter |
| `user_ids` | array | NO | Filter |

### Response: `UserUsage`

Top-level fields: `data`, `data_refreshed_at`, `has_more`, `next_page`, `organization_id`.

Each element of `data`:

| Field | Type | Notes |
|-------|------|-------|
| `actor` | object (`AnalyticsUserActor`) | See below |
| `uncached_input_tokens` | number | |
| `cache_read_input_tokens` | number | |
| `cache_creation` | object | `ephemeral_1h_input_tokens`, `ephemeral_5m_input_tokens` |
| `output_tokens` | number | |
| `total_tokens` | number | Sum across all token types; sort key for default order_by |
| `requests` | number | |
| `server_tool_use` | object | `web_search_requests` |
| `starting_at` | string | Populated when bucket_width is set |
| `ending_at` | string | Populated when bucket_width is set |
| `model` | string | Null unless in group_by |
| `product` | string | Null unless in group_by |
| `context_window` | string | Null unless in group_by |
| `inference_geo` | string | Null unless in group_by |
| `speed` | string | Null unless in group_by |

### AnalyticsUserActor sub-object (used by user_usage_report and user_cost_report)

| Field | Type | Notes |
|-------|------|-------|
| `user_id` | string | Tagged user ID (e.g. `user_01AbCd...`); always populated even for deleted accounts |
| `email` | string? | Null when account is deleted or unavailable |
| `name` | string? | Returns `"Deleted User"` when deleted; null when unavailable |
| `deleted` | boolean? | `true` if account has been deleted |
| `type` | string? | Fixed value `"user_actor"` |

**`email` and `name` are OPTIONAL on `AnalyticsUserActor`.** The name is the correct source for user display names. Do NOT use the `…/analytics/users` endpoint for names (see note below).

---

## Endpoint 5: GET /v1/organizations/analytics/user_cost_report

Per-user cost across a date range, ranked by spend.

### Query parameters

Same as `user_usage_report`, except:
- `order_by`: `"amount"` (default) or `"list_amount"` (not the token metrics from usage_report)
- `group_by` additionally accepts `"cost_type"` and `"token_type"`

### Response: `UserCost`

Top-level fields: `data`, `data_refreshed_at`, `has_more`, `next_page`, `organization_id`.

Each element of `data`:

| Field | Type | Notes |
|-------|------|-------|
| `actor` | object (`AnalyticsUserActor`) | Same structure as user_usage_report |
| `amount` | **string** | Post-discount, pre-credit, fractional cents |
| `list_amount` | **string** | Pre-discount, fractional cents |
| `currency` | string | Always `"USD"` |
| `cost_type` | string? | `"tokens"`, `"web_search"`, `"code_execution"`, or null |
| `token_type` | string? | Populated when cost_type=tokens and group_by includes token_type |
| `requests` | number | Null when group_by includes cost_type or token_type |
| `starting_at` | string | Populated when bucket_width set |
| `ending_at` | string | Populated when bucket_width set |
| `model` | string | Null unless in group_by |
| `product` | string | Null unless in group_by |
| `context_window` | string | Null unless in group_by |
| `inference_geo` | string | Null unless in group_by |
| `speed` | string | Null unless in group_by |

---

## Supplementary endpoint: GET /v1/organizations/analytics/users

**WARNING: email-only, must NOT be used for user display names.**

Returns per-user daily activity metrics for a single day. The user object on each row is `AnalyticsUser`, not `AnalyticsUserActor`:

```
AnalyticsUser {
  id: string          // tagged user ID, e.g. user_...
  email_address: string
}
```

`AnalyticsUser` has **only `id` and `email_address`** — there is no `name` field. This endpoint must not be used to populate named-seat lists. Use `actor.name` from `user_usage_report` or `user_cost_report` for display names.

Query params: `date` (YYYY-MM-DD, required), `limit` (1-1000, default 100), `page` (cursor).  
Response wrapper: `UserActivity { data, next_page }`.

---

## Pagination

All paginated endpoints use an opaque string cursor:
- Request: `page=<cursor>`
- Response includes `next_page` (string or null) and `has_more` (boolean, on usage/cost endpoints)
- **Cursors are bound to the query that issued them.** Changing any filter or group_by parameter with an old cursor returns HTTP 400. Restart from the first page if parameters change.
- Array filter params use bracket notation: `products[]=chat&products[]=claude_code`

---

## Discrepancies vs plan assumptions

The plan brief listed these assumed field names. Findings per the live doc:

### summaries endpoint

| Assumed field | Actual field | Status |
|--------------|--------------|--------|
| `assigned_seat_count` | `assigned_seat_count` | MATCH |
| `daily_active_users` | `daily_active_user_count` | MISMATCH — actual has `_count` suffix |
| `weekly_active_users` | `weekly_active_user_count` | MISMATCH — actual has `_count` suffix |
| `monthly_active_users` | `monthly_active_user_count` | MISMATCH — actual has `_count` suffix |

### usage_report endpoint

| Assumed field | Actual field | Status |
|--------------|--------------|--------|
| `input_tokens` | DOES NOT EXIST | MISMATCH — split into `uncached_input_tokens` + `cache_read_input_tokens` + `cache_creation` object |
| `output_tokens` | `output_tokens` | MATCH |
| `cache_read_input_tokens` | `cache_read_input_tokens` | MATCH |
| `cache_creation_input_tokens` | DOES NOT EXIST (flat) | MISMATCH — actual is nested object `cache_creation.ephemeral_1h_input_tokens` and `cache_creation.ephemeral_5m_input_tokens` |
| `messages` | DOES NOT EXIST | MISMATCH — the field is `requests` (API requests count) |

### cost_report endpoint

| Assumed field | Actual field | Status |
|--------------|--------------|--------|
| `amount` | `amount` | MATCH (but type is `String` not `Double`; value in fractional cents not dollars) |
| `currency` | `currency` | MATCH |
| `credits` | DOES NOT EXIST | MISMATCH — no `credits` field; seat-plan usage still reported via `amount` |

### per-user actor (user_usage_report / user_cost_report)

| Assumed field | Actual field | Status |
|--------------|--------------|--------|
| `actor.user_id` | `actor.user_id` | MATCH |
| `actor.email` | `actor.email` | MATCH (optional, null for deleted accounts) |
| `actor.name` | `actor.name` | MATCH (optional, `"Deleted User"` when deleted) |
| `actor.deleted` | `actor.deleted` | MATCH (optional boolean) |

**Summary of discrepancies:**
1. Three active-user fields on `summaries` are suffixed `_count` (not bare `_users`).
2. `input_tokens` does not exist; use `uncached_input_tokens` for uncached input.
3. `cache_creation_input_tokens` does not exist as a flat field; it is `cache_creation.ephemeral_1h_input_tokens` and `cache_creation.ephemeral_5m_input_tokens`.
4. `messages` does not exist; the count field is `requests`.
5. `credits` does not exist; cost amounts use `amount` (String, fractional cents) for both usage-based and seat-based plans.
6. `amount` is a **`String`** (decimal fractional cents), not a numeric type.
