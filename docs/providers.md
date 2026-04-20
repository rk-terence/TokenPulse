---
title: Provider Specifications
description: Authentication flows, endpoints, observed response shapes, and known issues for the Codex and ZenMux usage providers.
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
- If `CODEX_HOME` is set, `auth.json` must exist there; TokenPulse does not fall back to `~/.codex/auth.json`
- If the auth file is missing, `auth_mode` is API key mode, or required token data is missing, the provider is treated as unconfigured
- If auth data exists but cannot be read or parsed cleanly, the provider reports an unreadable login configuration state and prompts the user to run `codex login` again
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
- TokenPulse accepts either `used_percent` or `utilization` for window usage percentage; values are treated as 0–100 percentages
- A 200 response missing both rate-limit windows is treated as an invalid response
- TokenPulse accepts either `reset_after_seconds` or `resets_at` for window reset timing
- `reset_after_seconds` is converted to an absolute reset date relative to fetch time; `resets_at` is parsed directly using flexible ISO 8601 date handling
- `plan_type` is surfaced in the popover as a tag when present

## Known issues

- This is not a public API surface; response fields may drift without notice
- TokenPulse does not currently refresh expired Codex tokens itself

---

# ZenMux provider

## Authentication

ZenMux uses one authentication method:

1. **Management API key** — stored in macOS Keychain (service: `"TokenPulse-ZenMuxAPIKey"`). Obtained from the ZenMux dashboard and entered in **Settings > Providers > ZenMux**. Note: this is a **Management API Key**, not a standard API key. The ZenMux dashboard labels these separately.

## Endpoints

### 1. Subscription detail (Management API) — primary

Official documented endpoint. Provides 5h/7d real-time usage, monthly caps, and the billing-cycle end date.

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

TokenPulse does not use ZenMux's cookie-backed endpoints. We previously explored them to estimate monthly utilization, but verification showed the summary endpoint's `totalCost` is accumulated across months rather than scoped to the active billing cycle, so it is not suitable for current-cycle utilization.

## Rate limiting

Independent rate limit per endpoint; exceeding returns HTTP `422`. No specific minimum interval documented.
