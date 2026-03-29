# Provider specifications

## Claude subscription provider

### Authentication

1. Read Keychain item: service = `"Claude Code-credentials"`, using `SecItemCopyMatching`
2. Parse JSON → extract `claudeAiOauth.accessToken` (prefix: `sk-ant-oat01-`)

The credential JSON also contains `refreshToken` and `expiresAt`. A possible future enhancement is to check expiry and refresh the token automatically via POST to the Anthropic OAuth endpoint.

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

The `/api/oauth/usage` endpoint itself has rate limits. Minimum poll interval: 60 seconds. A possible strategy for handling 429 responses is exponential backoff with jitter (e.g. base 60s, max 300s).

### Known issues

- Endpoint sometimes returns persistent 429 even at reasonable intervals (see anthropics/claude-code#30930)
- Anthropic is restricting third-party OAuth usage — monitor for policy changes
- `resets_at` values may vary by fractional seconds between consecutive polls (not indicative of an actual reset)

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
- `resets_at`: ISO 8601; absent on `quota_monthly`
- `account_status`: `"healthy"`, `"monitored"`, `"abusive"`, `"suspended"`, or `"banned"`

### Rate limiting

Independent rate limit per endpoint; exceeding returns HTTP `422`. No specific minimum interval documented.
