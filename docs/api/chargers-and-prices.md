# Chargers and Prices API

The services Hisingen's home-charging subsystem calls. They are separate from the vehicle providers
in [Polestar](polestar.md) and [Volvo](volvo.md). The reader-facing setup and the limits of each
service are in [Home charging](../home-charging.md). The code is in
`Services/HomeCharging/` and `Services/Market/`, described in
[Home charging architecture](../architecture/home-charging.md).

All of these are HTTPS, and Tibber's live stream is `wss`. The one exception is a Home Assistant
address the reader entered as `http`. See [Security overview](../security/overview.md#network-transport).

## Services

| Service | Host | Sign-in | What Hisingen uses |
|---|---|---|---|
| Easee | `api.easee.com` | `POST /api/accounts/login` with the account and password; a one-hour token | `GET /api/chargers`, `GET /state/{id}/observations`, `POST /api/chargers/{id}/commands/{pause_charging, resume_charging, start_charging, override_schedule}`, `GET /api/sessions/charger/{id}/sessions/{from}/{to}` |
| Zaptec | `api.zaptec.com` | `POST /oauth/token` with the account and password; a one-hour token and no refresh token | `GET /api/chargers`, `GET /api/chargers/{id}/state`, `POST /api/chargers/{id}/sendCommand/{command}`, `GET /api/sessions/archived` |
| NexBlue | `api.nexblue.com` | A `login` grant under `/third_party/openapi/account/` with the account and password, then a `refresh_token` grant with the rotating refresh token | `GET /third_party/openapi/chargers`, then per-charger `status`, `schedule` and command paths under `/third_party/openapi` |
| Tibber | `api.tibber.com` | A personal access token | GraphQL: `priceInfoRange`, `priceInfo`, `consumption` and `production`. A websocket at `wss://api.tibber.com/v1-beta/gql/subscriptions` carries live house power when a Pulse is paired. |
| Perific (Enegic) | `api.enegic.com` | `PUT /createtoken` with the account and password; a token that lasts a year, sent in `X-Authorization` | `GET /getaccountoverview`, `PUT /getlatestpackets`, `PUT /getphasedata` |
| Elpriset just nu.se | `www.elprisetjustnu.se` | None | `GET /api/v1/prices/{YYYY}/{MM-DD}_{ZONE}.json`, one file per zone and day |
| Electricity Maps | `api.electricitymap.org` | An `auth-token` header with the reader's key | `GET /v3/carbon-intensity/latest?zone=SE-{ZONE}` |
| Home Assistant | The reader's own address | A long-lived token in an `Authorization: Bearer` header | The REST API, a websocket for live state, and the device registry template for discovery. See [Home charging](../home-charging.md#connect-through-home-assistant). |

## What is vendor-documented

Easee, Zaptec, NexBlue and Tibber publish developer documentation, and the provider code follows
it. The tests answer from a mock built from that documentation, and none of them touched a real
account or charger. [Home charging](../home-charging.md#live-checks-for-easee-and-zaptec) lists the
live checks a reader should run once.

**Perific has no public API and no local interface.** Hisingen reads the same cloud the Perific app
reads. The endpoints are not vendor-documented, the integration was checked against one live
account, and Enegic can change them without notice. If it stops working, Hisingen shows the meter
as unreachable and the rest of the app carries on.

## Limits to respect

- Easee limits session requests to 10 an hour, so repeated manual imports can be throttled.
- Easee and Zaptec tokens last an hour, so Hisingen keeps the login in the Keychain and signs in
  again.
- NexBlue's schedule reads and writes are owner-only. The vendor's role for an account is
  -1 installer, 0 owner, 1 user and 2 admin.
- Spot prices for tomorrow are published in the afternoon. `ElectricityPriceService` fetches once a
  day after 14:15 Stockholm time, and a request before publication returns a 404 that is expected
  and not a failure.
- Electricity Maps zone names exist in Hisingen for Sweden only.

## Errors

A direct charger's failures map to `DirectChargerError`: `unauthorized`, `forbidden`, `notFound`,
`rateLimited` (with the vendor's retry delay when it gives one), `rejected`, `unreachable`,
`chargerOffline` and `malformedResponse`. The messages never carry an account, a password, a token
or a request header.
