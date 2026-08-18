# Volvo backend — internal notes

`volvo.md` documents everything Hisingen actually implements against Volvo's official,
documented Connected Vehicle API v2 / Energy API v2 / Location API v1 — that's the file to read
first, and it's safe to publish since Volvo's own docs already cover the same ground. This file
holds the leftovers that aren't: real captured payloads and the full IdP scope/grant catalog
(broader than what Hisingen requests). Kept local for the same reason as
[polestar-backend-map.md](polestar-backend-map.md) — not sensitive in the "secret" sense, just
not something that belongs committed.

## OAuth grant types observed at the Volvo ID token endpoint

Beyond the `authorization_code` + PKCE flow Hisingen actually uses (see
[authentication.md](authentication.md#volvo-oauth2-pkce-with-a-redirect-uri-bridge)), the IdP
also answers: `refresh_token`, `client_credentials`, `password` (ROPC),
`urn:ietf:params:oauth:grant-type:jwt-bearer`, `urn:ietf:params:oauth:grant-type:device_code`.
Unused by Hisingen — recorded because probing the IdP established it, not because there's a plan
to use them.

## Full scope catalog observed at the Volvo ID IdP

Hisingen requests `openid` + 18 `conve:*`/`energy:*` read scopes (see
[volvo.md](volvo.md#authentication) and the `restrictedScopes` gap noted in
[architecture/technical-debt.md](../architecture/technical-debt.md)). The IdP itself recognises
a much larger set:

| Scope group | Scopes |
| :--- | :--- |
| Core identity | `openid`, `profile`, `email`, `customer:attributes`, `customer:attributes:write` |
| Energy & battery | `energy:battery_charge_level`, `energy:electric_range`, `energy:charging_connection_status`, `energy:estimated_charging_time`, `energy:recharge_status`, `energy:capability:read`, `energy:state:read`, `conve:battery_charge_level`, `conve:recharge_status` |
| Closures & security | `conve:doors_status`, `exve:doors_status`, `conve:windows_status`, `exve:windows_status`, `conve:lock_status`, `exve:lock_status`, `conve:lock`, `conve:unlock` |
| Vehicle telematics | `conve:odometer_status`, `conve:trip_statistics`, `conve:fuel_status`, `conve:engine_status`, `conve:tyre_status`, `conve:warnings`, `conve:diagnostics_workshop`, `conve:diagnostics_engine_status`, `conve:brake_status` |
| Climate & comfort | `conve:climatization_start_stop`, `vehicle:climatization`, `vehicle:climatization_calendar` |
| Location & locator | `location:read`, `vehicle:location`, `conve:honk_flash`, `vehicle:honk_blink` |

## Live payload captures (real vehicle, VIN `YV1…256`)

Real response shapes from the reference vehicle, GPS rounded to ~1km resolution (home location,
not for publishing at full precision even here):

```json
// GET /connected-vehicle/v2/vehicles/{vin}
{ "data": { "vin": "YV1…256", "model": "XC40 Recharge", "modelYear": 2024, "fuelType": "BATTERY_ELECTRIC_VEHICLE", "gearbox": "AUTOMATIC", "externalColour": "Crystal White", "numberOfDoors": 5 } }

// GET /energy/v1/vehicles/{vin}/battery-charge-level
{ "data": { "batteryChargeLevel": { "value": 78.5, "unit": "percentage" }, "electricRange": { "value": 385, "unit": "kilometers" } } }

// GET /energy/v1/vehicles/{vin}/recharge-status
{ "data": { "chargingSystemStatus": { "value": "CHARGING" }, "chargingConnectionStatus": { "value": "CONNECTED" }, "chargingType": { "value": "AC" }, "estimatedChargingTimeToFull": { "value": 95, "unit": "minutes" } } }

// GET /connected-vehicle/v2/vehicles/{vin}/doors
{ "data": { "centralLock": { "value": "LOCKED" }, "frontLeft": { "value": "CLOSED" }, "frontRight": { "value": "CLOSED" }, "rearLeft": { "value": "CLOSED" }, "rearRight": { "value": "CLOSED" }, "hood": { "value": "CLOSED" }, "tailgate": { "value": "CLOSED" } } }

// GET /connected-vehicle/v2/vehicles/{vin}/odometer
{ "data": { "odometer": { "value": 18450, "unit": "kilometers" } } }

// GET /location/v1/vehicles/{vin}/location
{ "data": { "position": { "latitude": 57.71, "longitude": 11.97 }, "heading": { "value": 180 }, "speed": { "value": 0 } } }
```

## Remote command endpoint shapes observed

| Command | Method | Endpoint |
| :--- | :---: | :--- |
| Lock | `POST` | `/connected-vehicle/v2/vehicles/{vin}/doors/lock` |
| Unlock | `POST` | `/connected-vehicle/v2/vehicles/{vin}/doors/unlock` |
| Start climatization | `POST` | `/connected-vehicle/v2/vehicles/{vin}/climatization/start` |
| Stop climatization | `POST` | `/connected-vehicle/v2/vehicles/{vin}/climatization/stop` |
| Flash | `POST` | `/connected-vehicle/v2/vehicles/{vin}/flash` |
| Honk | `POST` | `/connected-vehicle/v2/vehicles/{vin}/honk` |
| Honk & flash | `POST` | `/connected-vehicle/v2/vehicles/{vin}/honk-flash` |

These are the raw per-action REST paths observed; `VolvoAPI.dispatchCommand` (see
[volvo.md](volvo.md#remote-commands)) actually goes through the generic
`POST /connected-vehicle/v2/vehicles/{vin}/commands/{action}` shape for the 6 commands it
implements, not these dedicated paths.
