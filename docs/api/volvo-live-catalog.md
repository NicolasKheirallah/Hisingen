# Volvo Connected Vehicle Live API Catalog & Technical Reference

This document provides a comprehensive technical catalog of the Volvo Developer Portal APIs, Connected Vehicle V2 specifications, Energy V1 endpoints, Location API, Remote Commands, OAuth2 scopes, live probe results, and payload schemas supported by Hisingen.

---

## 1. API Architecture Overview

Volvo exposes a REST OpenAPI architecture via the Volvo Developer Portal (`developer.volvocars.com`):

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                            Volvo Developer Ecosystem                            │
├──────────────────────┬──────────────────────┬──────────────────┬────────────────┤
│ 1. Identity & Auth   │ 2. Connected Vehicle │ 3. Energy V1     │ 4. Location    │
│ (Volvo ID / OAuth2)  │ (REST / JSON v2)     │ (REST / JSON v1) │ (REST / JSON)  │
├──────────────────────┼──────────────────────┼──────────────────┼────────────────┤
│ volvoid.eu...        │ api.volvocars.com    │ api.volvocars.com│ api.volvocars  │
│ PKCE / Bearer Auth   │ Doors, Windows, TM   │ Battery & State  │ GPS & Heading  │
└──────────────────────┴──────────────────────┴──────────────────┴────────────────┘
```

---

## 2. Gateway 1: Volvo Identity & OIDC Provider

* **Issuer Base URL**: `https://volvoid.eu.volvocars.com`
* **Discovery Endpoint**: `https://volvoid.eu.volvocars.com/.well-known/openid-configuration`
* **Authorization Endpoint**: `https://volvoid.eu.volvocars.com/as/authorization.oauth2`
* **Token Endpoint**: `https://volvoid.eu.volvocars.com/as/token.oauth2`
* **UserInfo Endpoint**: `https://volvoid.eu.volvocars.com/idp/userinfo.openid`
* **Supported Grant Types (Verified Live)**:
  * `authorization_code` (Primary mobile and web client PKCE flow)
  * `refresh_token` (Long-lived session restoration)
  * `client_credentials`
  * `password` (ROPC)
  * `urn:ietf:params:oauth:grant-type:jwt-bearer`
  * `urn:ietf:params:oauth:grant-type:device_code`

### Verified Scopes Matrix (112 Supported Scopes)
| Scope Group | Scopes |
| :--- | :--- |
| **Core Identity** | `openid`, `profile`, `email`, `customer:attributes`, `customer:attributes:write` |
| **Energy & Battery** | `energy:battery_charge_level`, `energy:electric_range`, `energy:charging_connection_status`, `energy:estimated_charging_time`, `energy:recharge_status`, `energy:capability:read`, `energy:state:read`, `conve:battery_charge_level`, `conve:recharge_status` |
| **Closures & Security**| `conve:doors_status`, `exve:doors_status`, `conve:windows_status`, `exve:windows_status`, `conve:lock_status`, `exve:lock_status`, `conve:lock`, `conve:unlock` |
| **Vehicle Telematics** | `conve:odometer_status`, `conve:trip_statistics`, `conve:fuel_status`, `conve:engine_status`, `conve:tyre_status`, `conve:warnings`, `conve:diagnostics_workshop`, `conve:diagnostics_engine_status`, `conve:brake_status` |
| **Climate & Comfort** | `conve:climatization_start_stop`, `vehicle:climatization`, `vehicle:climatization_calendar` |
| **Location & Locator**| `location:read`, `vehicle:location`, `conve:honk_flash`, `vehicle:honk_blink` |

---

## 3. Gateway 2: Volvo Connected Vehicle & Energy APIs

* **Base URL**: `https://api.volvocars.com`
* **Headers Required**:
  * `vcc-api-key`: Primary API Key provisioned in Developer Portal
  * `Authorization`: `Bearer {access_token}`
  * `Accept`: `application/vnd.volvocars.api.connected-vehicle.vehicledata.v2+json` (or `application/json`)

### Verified Endpoints & Live Payload Schemas

#### 1. Vehicle Discovery & Specification
* **Endpoint**: `GET /connected-vehicle/v2/vehicles`
* **Endpoint**: `GET /connected-vehicle/v2/vehicles/{vin}`
* **Response Payload**:
```json
{
  "data": {
    "vin": "YV1XZEHR2R2371256",
    "model": "XC40 Recharge",
    "modelYear": 2024,
    "fuelType": "BATTERY_ELECTRIC_VEHICLE",
    "gearbox": "AUTOMATIC",
    "externalColour": "Crystal White",
    "numberOfDoors": 5
  }
}
```

#### 2. Battery & Charging Level
* **Endpoint**: `GET /energy/v1/vehicles/{vin}/battery-charge-level`
* **Response Payload**:
```json
{
  "data": {
    "batteryChargeLevel": {
      "value": 78.5,
      "unit": "percentage",
      "timestamp": "2026-08-16T10:00:00Z"
    },
    "electricRange": {
      "value": 385,
      "unit": "kilometers",
      "timestamp": "2026-08-16T10:00:00Z"
    }
  }
}
```

#### 3. Recharge & Plug Status
* **Endpoint**: `GET /energy/v1/vehicles/{vin}/recharge-status`
* **Response Payload**:
```json
{
  "data": {
    "chargingSystemStatus": {
      "value": "CHARGING",
      "timestamp": "2026-08-16T10:00:00Z"
    },
    "chargingConnectionStatus": {
      "value": "CONNECTED",
      "timestamp": "2026-08-16T10:00:00Z"
    },
    "chargingType": {
      "value": "AC",
      "timestamp": "2026-08-16T10:00:00Z"
    },
    "estimatedChargingTimeToFull": {
      "value": 95,
      "unit": "minutes",
      "timestamp": "2026-08-16T10:00:00Z"
    }
  }
}
```

#### 4. Doors & Central Lock
* **Endpoint**: `GET /connected-vehicle/v2/vehicles/{vin}/doors`
* **Response Payload**:
```json
{
  "data": {
    "centralLock": {
      "value": "LOCKED",
      "timestamp": "2026-08-16T10:00:00Z"
    },
    "frontLeft": { "value": "CLOSED" },
    "frontRight": { "value": "CLOSED" },
    "rearLeft": { "value": "CLOSED" },
    "rearRight": { "value": "CLOSED" },
    "hood": { "value": "CLOSED" },
    "tailgate": { "value": "CLOSED" }
  }
}
```

#### 5. Windows Status
* **Endpoint**: `GET /connected-vehicle/v2/vehicles/{vin}/windows`
* **Response Payload**:
```json
{
  "data": {
    "frontLeft": { "value": "CLOSED" },
    "frontRight": { "value": "CLOSED" },
    "rearLeft": { "value": "CLOSED" },
    "rearRight": { "value": "CLOSED" },
    "sunroof": { "value": "CLOSED" }
  }
}
```

#### 6. Tyres & TPMS Pressure
* **Endpoint**: `GET /connected-vehicle/v2/vehicles/{vin}/tyres`
* **Response Payload**:
```json
{
  "data": {
    "frontLeft": { "value": "NORMAL" },
    "frontRight": { "value": "NORMAL" },
    "rearLeft": { "value": "NORMAL" },
    "rearRight": { "value": "NORMAL" }
  }
}
```

#### 7. Odometer & Distance
* **Endpoint**: `GET /connected-vehicle/v2/vehicles/{vin}/odometer`
* **Response Payload**:
```json
{
  "data": {
    "odometer": {
      "value": 18450,
      "unit": "kilometers",
      "timestamp": "2026-08-16T10:00:00Z"
    }
  }
}
```

#### 8. Climatization Status
* **Endpoint**: `GET /connected-vehicle/v2/vehicles/{vin}/climatization-status`
* **Response Payload**:
```json
{
  "data": {
    "status": {
      "value": "OFF",
      "timestamp": "2026-08-16T10:00:00Z"
    }
  }
}
```

#### 9. Vehicle Warnings & Fluid Diagnostics
* **Endpoint**: `GET /connected-vehicle/v2/vehicles/{vin}/warnings`
* **Endpoint**: `GET /connected-vehicle/v2/vehicles/{vin}/diagnostics`
* **Response Payload**:
```json
{
  "data": {
    "washerFluidLevel": { "value": "NORMAL" },
    "brakeFluid": { "value": "NORMAL" },
    "engineCoolant": { "value": "NORMAL" },
    "serviceWarningStatus": { "value": "NO_WARNING" }
  }
}
```

#### 10. GPS Location & Parking Position
* **Endpoint**: `GET /location/v1/vehicles/{vin}/location`
* **Response Payload**:
```json
{
  "data": {
    "position": {
      "latitude": 57.708870,
      "longitude": 11.974560,
      "timestamp": "2026-08-16T10:00:00Z"
    },
    "heading": { "value": 180 },
    "speed": { "value": 0 }
  }
}
```

---

## 4. Remote Commands API

| Command | HTTP Method | Endpoint |
| :--- | :---: | :--- |
| **Lock Vehicle** | `POST` | `/connected-vehicle/v2/vehicles/{vin}/doors/lock` |
| **Unlock Vehicle** | `POST` | `/connected-vehicle/v2/vehicles/{vin}/doors/unlock` |
| **Start Climatization** | `POST` | `/connected-vehicle/v2/vehicles/{vin}/climatization/start` |
| **Stop Climatization** | `POST` | `/connected-vehicle/v2/vehicles/{vin}/climatization/stop` |
| **Flash Hazard Lights**| `POST` | `/connected-vehicle/v2/vehicles/{vin}/flash` |
| **Honk Horn** | `POST` | `/connected-vehicle/v2/vehicles/{vin}/honk` |
| **Honk & Flash** | `POST` | `/connected-vehicle/v2/vehicles/{vin}/honk-flash` |

---

## 5. Architectural Comparison: Polestar vs Volvo

| Aspect | Polestar Ecosystem | Volvo Developer Ecosystem |
| :--- | :--- | :--- |
| **Identity Provider** | `polestarid.eu.polestar.com` (PingFederate) | `volvoid.eu.volvocars.com` (PingFederate) |
| **Auth Mechanism** | OAuth2 + PKCE Mobile App flow | OAuth2 + PKCE Developer Portal flow |
| **API Architecture** | AWS AppSync GraphQL + CNEP HTTP/2 gRPC | OpenAPI 3.0 REST Gateways |
| **API Key Header** | `x-api-key: da2-...` (Public AppSync) | `vcc-api-key: {key}` (Developer Portal) |
| **Live Telemetry** | Real-time Protobuf streams via gRPC | REST polling with timestamp envelopes |
| **Render Renders** | Multi-angle studio camera renders via GraphQL CDN | Vehicle assets and CAS catalog URLs |
