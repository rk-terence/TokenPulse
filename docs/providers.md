# Provider specifications

## Provider protocol

```swift
/// Describes how a fetch failure should be treated by the system.
enum FailureDisposition: Sendable {
    case unconfigured       // Provider not configured — don't retry
    case transient(String)  // Temporary problem — show stale data, retry on next poll
    case auth(String)       // Auth/credential issue — show stale data, surface guidance
    case persistent(String) // Permanent error — show error state
}

protocol UsageProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    var shortLabel: String { get }       // Single char for menu bar: "C", "Z"
    var brandColor: Color { get }
    func fetchUsage() async throws -> UsageData
    func isConfigured() -> Bool
    func classifyError(_ error: Error) -> FailureDisposition
}

struct UsageData: Codable, Sendable {
    let fiveHour: WindowUsage?           // 5-hour rolling window
    let sevenDay: WindowUsage?           // Weekly quota
    let extras: [String: String]         // Provider-specific (Opus quota, Flows, etc.)
    let fetchedAt: Date
}

struct WindowUsage: Codable, Sendable {
    let utilization: Double              // 0.0–100.0 percentage
    let resetsAt: Date?                  // ISO 8601, nil if unknown
}
```

## Claude subscription provider

### Authentication

1. Read Keychain item: service = `"Claude Code-credentials"`, using `SecItemCopyMatching`
2. Parse JSON → extract `claudeAiOauth.accessToken` (prefix: `sk-ant-oat01-`)
3. Check `expiresAt`; if expired, use `refreshToken` to refresh (POST to Anthropic OAuth endpoint)

Keychain query:
```swift
let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "Claude Code-credentials",
    kSecReturnData as String: true,
    kSecMatchLimit as String: kSecMatchLimitOne
]
```

Credential JSON structure:
```json
{
  "claudeAiOauth": {
    "accessToken": "sk-ant-oat01-...",
    "refreshToken": "...",
    "expiresAt": 1234567890,
    "scopes": ["..."],
    "subscriptionType": "pro"
  }
}
```

### API endpoint

```
GET https://api.anthropic.com/api/oauth/usage

Headers:
  Authorization: Bearer <accessToken>
  anthropic-beta: oauth-2025-04-20
  User-Agent: TokenPulse/1.0
  Content-Type: application/json
```

### Response

```json
{
  "five_hour": {
    "utilization": 35.0,
    "resets_at": "2026-03-26T14:59:59.943648+00:00"
  },
  "seven_day": {
    "utilization": 12.0,
    "resets_at": "2026-03-30T03:59:59.943679+00:00"
  },
  "seven_day_opus": {
    "utilization": 0.0,
    "resets_at": null
  }
}
```

### Rate limiting

The `/api/oauth/usage` endpoint itself has rate limits. Minimum poll interval: 60 seconds. On 429, use exponential backoff with jitter (base 60s, max 300s).

### Known issues

- Endpoint sometimes returns persistent 429 even at reasonable intervals (see anthropics/claude-code#30930)
- Anthropic is restricting third-party OAuth usage — monitor for policy changes

---

## ZenMux provider

### Authentication

Management API key stored in macOS Keychain (service: `"TokenPulse-ZenMuxAPIKey"`). The key is obtained from the ZenMux dashboard and entered in **Settings > Providers > ZenMux**.

Note: this is a **Management API Key**, not a standard API key. The ZenMux dashboard labels these separately.

### API endpoint

```
GET https://zenmux.ai/api/v1/management/subscription/detail

Headers:
  Authorization: Bearer <ZENMUX_MANAGEMENT_API_KEY>
  User-Agent: TokenPulse/1.0
```

### Response

```json
{
  "success": true,
  "data": {
    "plan": {
      "tier": "max",
      "amount_usd": 100,
      "interval": "month",
      "expires_at": "2026-04-20T03:30:29.000Z"
    },
    "currency": "usd",
    "base_usd_per_flow": 0.03283,
    "effective_usd_per_flow": 0.03283,
    "account_status": "healthy",
    "quota_5_hour": {
      "usage_percentage": 0.4204,
      "resets_at": "2026-03-29T06:43:05.000Z",
      "max_flows": 300,
      "used_flows": 126.11,
      "remaining_flows": 173.89,
      "used_value_usd": 4.14,
      "max_value_usd": 9.85
    },
    "quota_7_day": {
      "usage_percentage": 0.0544,
      "resets_at": "2026-04-03T07:58:07.000Z",
      "max_flows": 2318,
      "used_flows": 126.17,
      "remaining_flows": 2191.83,
      "used_value_usd": 4.14,
      "max_value_usd": 76.11
    },
    "quota_monthly": {
      "max_flows": 9936,
      "max_value_usd": 326.24
    }
  }
}
```

**Response field notes:**
- `usage_percentage`: Float 0.0–1.0 (multiply by 100 for display percentage)
- `quota_5_hour` / `quota_7_day`: Rolling windows with full usage fields
- `quota_monthly`: Fixed cycle — may only contain `max_flows` and `max_value_usd` (no `usage_percentage` or `resets_at`)
- `resets_at`: ISO 8601 — maps to `WindowUsage.resetsAt`; absent on `quota_monthly`
- `account_status`: `"healthy"`, `"monitored"`, `"abusive"`, `"suspended"`, or `"banned"`

### Mapping to UsageData

| API field | UsageData field |
|---|---|
| `quota_5_hour.usage_percentage * 100` | `fiveHour.utilization` |
| `quota_5_hour.resets_at` | `fiveHour.resetsAt` |
| `quota_7_day.usage_percentage * 100` | `sevenDay.utilization` |
| `quota_7_day.resets_at` | `sevenDay.resetsAt` |
| `plan.tier` | `extras["tier"]` |
| `account_status` | `extras["accountStatus"]` |
| `quota_5_hour.used_value_usd` | `extras["5hUsedUsd"]` |
| `quota_5_hour.max_value_usd` | `extras["5hMaxUsd"]` |
| `quota_5_hour.used_flows` | `extras["5hUsedFlows"]` |
| `quota_5_hour.remaining_flows` | `extras["5hRemainingFlows"]` |
| `quota_5_hour.max_flows` | `extras["5hMaxFlows"]` |
| `quota_7_day.used_value_usd` | `extras["7dUsedUsd"]` |
| `quota_7_day.max_value_usd` | `extras["7dMaxUsd"]` |
| `quota_7_day.used_flows` | `extras["7dUsedFlows"]` |
| `quota_7_day.remaining_flows` | `extras["7dRemainingFlows"]` |
| `quota_7_day.max_flows` | `extras["7dMaxFlows"]` |
| `quota_monthly.max_value_usd` | `extras["moMaxUsd"]` |
| `quota_monthly.max_flows` | `extras["moMaxFlows"]` |
| `effective_usd_per_flow` | `extras["effectiveUsdPerFlow"]` |

### Rate limiting

Independent rate limit per endpoint; exceeding returns HTTP `422`. No specific minimum interval documented — we use the same configurable polling interval as other providers.
