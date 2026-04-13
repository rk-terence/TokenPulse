---
title: Provider Specifications
description: Authentication flows, endpoints, observed response shapes, and known issues for the Codex, Claude, and ZenMux usage providers.
---

# Codex subscription provider

## Authentication

TokenPulse reads the local Codex CLI auth file:

1. Resolve `$CODEX_HOME/auth.json` if `CODEX_HOME` is set (authoritative — no fallback)
2. Otherwise check `~/.codex/auth.json`
3. Require `auth_mode == "chatgpt"`
4. Parse `tokens.access_token` and `tokens.account_id`

Observed auth file shape:

```json
{
  "auth_mode": "chatgpt",
  "last_refresh": "2026-04-04T15:41:07.445471Z",
  "tokens": {
    "access_token": "...",
    "refresh_token": "...",
    "id_token": "...",
    "account_id": "..."
  }
}
```

Notes:
- TokenPulse currently uses the existing access token as-is
- If the file is missing, unreadable, in API key mode, or missing token data, the provider is treated as unconfigured/auth-stale
- A future enhancement is to replicate Codex CLI token refresh against `https://auth.openai.com/oauth/token`

## API endpoint

```
GET https://chatgpt.com/backend-api/wham/usage

Headers:
  Authorization: Bearer <access_token>
  ChatGPT-Account-Id: <account_id>   # when available
  Accept: application/json
  User-Agent: TokenPulse/1.0
```

## Response

Observed response family:

```json
{
  "plan_type": "plus",
  "rate_limit": {
    "primary_window": {
      "used_percent": 12.5,
      "reset_after_seconds": 5400
    },
    "secondary_window": {
      "used_percent": 4.2,
      "reset_after_seconds": 68400
    }
  }
}
```

Field notes:
- `primary_window` is mapped to TokenPulse's primary slot and shown as **5h**
- `secondary_window` is mapped to TokenPulse's secondary slot and shown as **7d** / weekly
- `used_percent` is a 0–100 percentage and used as-is (no normalization)
- A 200 response missing both rate-limit windows is treated as an invalid response
- `reset_after_seconds` is converted to an absolute reset date relative to fetch time
- `plan_type` is surfaced in the popover as a tag when present

## Known issues

- This is not a public API surface; response fields may drift without notice
- TokenPulse does not currently refresh expired Codex tokens itself

---

# Claude subscription provider

## Authentication

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

## API endpoint

```
GET https://api.anthropic.com/api/oauth/usage

Headers:
  Authorization: Bearer <accessToken>
  anthropic-beta: oauth-2025-04-20
  User-Agent: TokenPulse/1.0
  Content-Type: application/json
```

## Response

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

## Rate limiting

The `/api/oauth/usage` endpoint itself has rate limits. Minimum poll interval: 60 seconds. A possible strategy for handling 429 responses is exponential backoff with jitter (e.g. base 60s, max 300s).

## Known issues

- Endpoint sometimes returns persistent 429 even at reasonable intervals (see anthropics/claude-code#30930)
- Anthropic is restricting third-party OAuth usage — monitor for policy changes
- `resets_at` values may vary by fractional seconds between consecutive polls (not indicative of an actual reset)

---

# ZenMux provider

## Authentication

Two authentication methods are used:

1. **Management API key** (primary) — stored in macOS Keychain (service: `"TokenPulse-ZenMuxAPIKey"`). Obtained from the ZenMux dashboard and entered in **Settings > Providers > ZenMux**. Note: this is a **Management API Key**, not a standard API key. The ZenMux dashboard labels these separately.

2. **Chrome session cookies** (supplementary) — extracted automatically from Chrome's encrypted cookie store via `ChromeCookieService`. Requires `ctoken`, `sessionId`, and `sessionId.sig` cookies for `zenmux.ai`. Used for the subscription summary endpoint which has no management API equivalent.

## Endpoints

### 1. Subscription detail (Management API) — primary

Official documented endpoint. Provides 5h/7d real-time usage and monthly caps.

```
GET https://zenmux.ai/api/v1/management/subscription/detail

Headers:
  Authorization: Bearer <ZENMUX_MANAGEMENT_API_KEY>
  User-Agent: TokenPulse/1.0
```

Response:

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

Field notes:
- `usage_percentage`: Float 0.0–1.0 (multiply by 100 for display percentage)
- `quota_5_hour` / `quota_7_day`: Rolling windows with full usage fields
- `quota_monthly`: Fixed cycle — only contains `max_flows` and `max_value_usd` (no `usage_percentage`, `used_flows`, or `resets_at`)
- `resets_at`: ISO 8601; absent on `quota_monthly`
- `account_status`: `"healthy"`, `"monitored"`, `"abusive"`, `"suspended"`, or `"banned"`
- `plan.expires_at`: End of current billing cycle; used as monthly quota reset date

### 2. Subscription summary (Cookie API) — supplementary

Discovered via Chrome DevTools inspection. Provides current billing cycle cost breakdown. Used to derive monthly utilization since the management API's `quota_monthly` lacks usage data.

```
GET https://zenmux.ai/api/dashboard/cost/query/subscription_summary?ctoken=<CTOKEN>

Headers:
  Cookie: ctoken=<CTOKEN>; sessionId=<SESSION_ID>; sessionId.sig=<SESSION_SIG>
  User-Agent: TokenPulse/1.0
```

Response:

```json
{
  "success": true,
  "data": {
    "totalCost": "37.7353571",
    "inputCost": "27.4005191",
    "outputCost": "8.382838",
    "otherCost": "1.952",
    "requestCounts": "615",
    "requestAvgCost": "0.0613583042",
    "totalTokens": "34818918",
    "millionTokenAvgCost": "1.0837601875"
  }
}
```

Field notes:
- All numeric values are returned as **strings**, not numbers
- `totalCost`: Total USD spent in the current billing cycle
- Monthly utilization is derived as: `totalCost / quota_monthly.max_value_usd × 100`
- Date query parameters (`startDate`, `endDate`) are accepted but **ignored** — the endpoint always returns data for the current billing cycle
- **Unverified assumption**: data resets at billing cycle boundary. To be confirmed after 2026-04-20

### 3. Current usage (Cookie API) — not used

Legacy endpoint used in earlier versions of TokenPulse. Provides 5h and 7d window usage via cookies. Superseded by the management API which provides the same data with simpler authentication.

```
GET https://zenmux.ai/api/subscription/get_current_usage?ctoken=<CTOKEN>

Headers:
  Cookie: ctoken=<CTOKEN>; sessionId=<SESSION_ID>; sessionId.sig=<SESSION_SIG>
```

Response:

```json
{
  "success": true,
  "data": [
    {
      "tierCode": "max",
      "periodType": "week",
      "periodDuration": "168",
      "cycleStartTime": "2026-03-27T07:58:07.000Z",
      "cycleEndTime": "2026-04-03T07:58:07.000Z",
      "usedRate": 0.1036,
      "quotaStatus": 0,
      "status": 0,
      "ext": "{\"gammaRate\":0.23,\"subscriptionAccountGammaRate\":1.0,\"subscriptionPlanGammaRate\":0.23}"
    },
    {
      "tierCode": "max",
      "periodType": "hour_5",
      "periodDuration": "5",
      "cycleStartTime": "2026-03-29T06:44:04.000Z",
      "cycleEndTime": "2026-03-29T11:44:04.000Z",
      "usedRate": 0.1755,
      "quotaStatus": 0,
      "status": 0,
      "ext": "{}"
    }
  ]
}
```

Field notes:
- `usedRate`: Float 0.0–1.0 (equivalent to `usage_percentage` in management API)
- Only `hour_5` and `week` period types are returned — **no monthly period**
- `ext.gammaRate` on the `week` entry may relate to rate limiting weights

### 4. Current subscription (Cookie API) — not used

Plan metadata endpoint. All information is available through the management API.

```
GET https://zenmux.ai/api/subscription/get_current?ctoken=<CTOKEN>

Headers:
  Cookie: ctoken=<CTOKEN>; sessionId=<SESSION_ID>; sessionId.sig=<SESSION_SIG>
```

Response:

```json
{
  "success": true,
  "data": {
    "price": 100,
    "startedAt": "2026-03-20T03:30:29.000Z",
    "expiredAt": "2026-04-20T03:30:29.000Z",
    "status": "ACTIVE",
    "planKey": "max",
    "alpha": 1,
    "gamma": 1,
    "period_quota": 300,
    "leverage": 3.2624,
    "flowPrice": 0.03283,
    "weekMaxFlows": 2318.4,
    "monthMaxFlows": 9936,
    "nextBillingPlanKey": null,
    "enable_extra_usage": 0,
    "extra_api_key": null,
    "name": "Max Plan",
    "desc": "300 Flows/5h"
  }
}
```

Field notes:
- `leverage`: Static plan value multiplier = `monthMaxFlows × flowPrice / price` (not usage-related)
- `alpha`, `gamma`: Internal tuning parameters
- `period_quota`: Same as `quota_5_hour.max_flows` in management API
- Redundant with management API `plan.*` fields plus `quota_*.max_flows` fields

## Rate limiting

Independent rate limit per endpoint; exceeding returns HTTP `422`. No specific minimum interval documented.
