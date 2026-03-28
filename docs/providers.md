# Provider specifications

## Provider protocol

```swift
protocol UsageProvider: Sendable {
    var id: String { get }
    var displayName: String { get }
    var shortLabel: String { get }       // Single char for menu bar: "C", "Z"
    var brandColor: Color { get }
    func fetchUsage() async throws -> UsageData
    func isConfigured() -> Bool
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

1. Locate Chrome Cookies DB: `~/Library/Application Support/Google/Chrome/Default/Cookies`
2. Read "Chrome Safe Storage" key from Keychain:
   ```swift
   let query: [String: Any] = [
       kSecClass as String: kSecClassGenericPassword,
       kSecAttrService as String: "Chrome Safe Storage",
       kSecReturnData as String: true,
       kSecMatchLimit as String: kSecMatchLimitOne
   ]
   ```
3. Derive decryption key: PBKDF2 with the Keychain password, salt = `"saltysalt"`, 1003 iterations, 16-byte key length
4. Open SQLite DB (copy to temp first to avoid WAL lock), query for ZenMux cookies:
   ```sql
   SELECT name, encrypted_value FROM cookies
   WHERE host_key LIKE '%zenmux%'
   AND name IN ('ctoken', 'sessionId', 'sessionId.sig')
   ```
5. Decrypt: AES-128-CBC, IV = 16 bytes of 0x20 (space), strip PKCS7 padding
   - v10/v11 prefix: strip first 3 bytes before decryption
6. Attach all three decrypted cookies to HTTP requests

### Required cookies

| Cookie name     | Domain     | Purpose                     |
|-----------------|------------|-----------------------------|
| `ctoken`        | zenmux.ai  | Primary authentication token |
| `sessionId`     | zenmux.ai  | Session identifier           |
| `sessionId.sig` | zenmux.ai  | Session signature (HMAC)     |

### API endpoint

```
GET https://zenmux.ai/api/subscription/get_current_usage?ctoken=<CTOKEN_VALUE>

Headers:
  Cookie: ctoken=<value>; sessionId=<value>; sessionId.sig=<value>
  User-Agent: TokenPulse/1.0
```

### Response

```json
{
  "ts": 1774513459,
  "data": [
    {
      "tierCode": "max",
      "periodType": "hour_5",
      "periodDuration": "5",
      "cycleStartTime": "2026-03-26T10:47:05.000Z",
      "cycleEndTime": "2026-03-26T15:47:05.000Z",
      "usedRate": 0.376,
      "quotaStatus": 0,
      "status": 0,
      "ext": "{\"gammaRate\":0.23}"
    },
    {
      "tierCode": "max",
      "periodType": "week",
      "periodDuration": "168",
      "cycleStartTime": "2026-03-20T03:47:05.000Z",
      "cycleEndTime": "2026-03-27T03:47:05.000Z",
      "usedRate": 0.12,
      "quotaStatus": 0,
      "status": 0,
      "ext": "{}"
    }
  ]
}
```

**Response field notes:**
- `usedRate`: Float 0.0–1.0 (multiply by 100 for percentage)
- `periodType`: `"hour_5"` (5-hour window) or `"week"` (7-day)
- `quotaStatus`: 0 = normal, 1 = exhausted
- `cycleEndTime`: ISO 8601 — maps to `resetsAt`

### Notes

- Chrome DB must be copied to temp before reading (SQLite WAL lock with running Chrome)
- Cookie names and endpoint URL may change — manual cookie paste available in Settings as fallback
- Alternative: user can manually paste cookie values in Settings to bypass Chrome DB reading
