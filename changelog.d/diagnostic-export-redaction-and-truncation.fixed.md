- **Close redaction gaps and preserve valid JSON in diagnostic exports.** Scrubbed `garageScan.lastError`
  and `vdmsDiscovery.reason` via `DiagnosticRedaction.redact`, fixed `bearerTokenExpression` to capture
  and preserve the `"Bearer "` prefix, and omitted over-budget (`>256 KB`) redacted API payloads cleanly
  with `"payloadOmissionReason": "tooLarge"` instead of byte-slicing JSON mid-syntax.
