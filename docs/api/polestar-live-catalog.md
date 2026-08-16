# Polestar Live API Catalog & Technical Reference

This document provides a comprehensive, field-tested technical catalog of all Polestar cloud APIs, microservices, protocol formats, live payloads, and feature opportunities for Hisingen.

---

## 1. API Architecture Overview

Polestar uses a multi-tier hybrid architecture across 4 distinct gateways:

```
┌─────────────────────────────────────────────────────────────────────────────────┐
│                           Polestar Cloud Ecosystem                              │
├──────────────────────┬──────────────────────┬──────────────────┬────────────────┤
│ 1. Identity & Auth   │ 2. Vehicle Config    │ 3. Studio Renders│ 4. Telemetrics │
│ (PingFederate OIDC)  │ (App Backend Apollo) │ (AppSync Public) │ (CNEP/C3 gRPC) │
├──────────────────────┼──────────────────────┼──────────────────┼────────────────┤
│ polestarid.eu...     │ pc-api.polestar.com  │ pc-api.polestar  │ cnepmob.volvo  │
│ OAuth 2.0 + PKCE     │ GraphQL (VDMS)       │ GraphQL (AWS)    │ HTTP/2 Protobuf│
└──────────────────────┴──────────────────────┴──────────────────┴────────────────┘
```

---

## 2. Gateway 1: Polestar Identity & OIDC Provider

* **Issuer Base URL**: `https://polestarid.eu.polestar.com`
* **Discovery Endpoint**: `https://polestarid.eu.polestar.com/.well-known/openid-configuration`
* **Authorization Endpoint**: `https://polestarid.eu.polestar.com/as/authorization.oauth2`
* **Token Endpoint**: `https://polestarid.eu.polestar.com/as/token.oauth2`
* **UserInfo Endpoint**: `https://polestarid.eu.polestar.com/idp/userinfo.openid`
* **Client ID**: `lp8dyrd_10` (Polestar Mobile App Client)
* **Redirect URI**: `polestar-explore://explore.polestar.com`
* **Supported OAuth Scopes (Verified Live)**:
  * Identity: `openid`, `profile`, `email`, `address`, `phone`, `customer:attributes`, `customer:attributes:write`
  * Telematics: `energy:battery_charge_level`, `energy:electric_range`, `energy:charging_connection_status`, `energy:estimated_charging_time`, `energy:recharge_status`, `conve:battery_charge_level`, `conve:recharge_status`
  * Closures & Locks: `exve:doors_status`, `conve:doors_status`, `vehicle:doors_status`, `exve:windows_status`, `conve:windows_status`, `exve:lock_status`, `conve:lock_status`, `vehicle:lock`, `vehicle:unlock`
  * Health & Maintenance: `exve:odometer_status`, `conve:odometer_status`, `vehicle:odometer_status`, `conve:trip_statistics`, `vehicle:trips`, `vehicle:trip_status`, `conve:tyre_status`, `exve:tyre_status`, `vehicle:tyre_status`, `conve:warnings`, `exve:warnings`, `vehicle:maintenance_status`, `vehicle:service_status`, `vehicle:bulb_status`, `vehicle:brake_status`, `vehicle:oil_status`, `vehicle:coolant_status`, `vehicle:washer_status`
  * Climate & HVAC: `vehicle:climatization`, `conve:climatization_start_stop`, `vehicle:climatization_calendar`, `vehicle:climatization_calendar_status`
  * Remote Commands: `conve:honk_flash`, `conve:command_honk_flash`, `vehicle:honk_blink`, `vehicle:location`, `conve:navigation`

---

## 3. Gateway 2: Public Vehicle Studio & Render CDN

* **Base URL**: `https://pc-api.polestar.com/eu-north-1/mystar-public/`
* **Authentication**: Static API Key Header (`x-api-key: da2-js63uvc7c5hwpdudt657d5lyou`)
* **Protocol**: GraphQL POST

### Query Format
```graphql
query GetCarImages($pno34: String!, $structureWeek: String!, $modelYear: String!, $locale: String) {
  getCarImages(pno34: $pno34, structureWeek: $structureWeek, modelYear: $modelYear, locale: $locale) {
    transparent {
      angle
      url
    }
    opaque {
      angle
      url
    }
    interior {
      angle
      url
    }
  }
}
```

### Camera Angles Available:
* **Angle 0**: Front 3/4 Studio View (Exterior)
* **Angle 1**: Rear 3/4 Studio View (Exterior)
* **Angle 2**: Pure Side Profile (Exterior)
* **Angle 3**: Direct Overhead / Top Down (Exterior)
* **Angle 4**: Front Cockpit Dashboard & Steering Wheel (Interior)

---

## 4. Gateway 3: App Backend GraphQL API (VDMS)

* **Base URL**: `https://pc-api.polestar.com/eu-north-1/app-backend/api/graphql`
* **Authentication**: Header `X-PolestarId-Authorization: Bearer <token>`
* **Protocol**: GraphQL over HTTP POST with Apollo client extensions

### Query Format
```graphql
query GetVDMSCars {
  vdms {
    getVehiclesInformation {
      vin
      internalVehicleIdentifier
      registrationNo
      modelYear
      content {
        model { name }
        exterior { name }
        exteriorColor { name }
        interior { name }
        upholstery { name }
        wheels { name }
        packages { name }
      }
    }
  }
}
```

---

## 5. Gateway 4: CNEP / C3 Real-Time Telematics & gRPC Microservices

* **Primary Host**: `https://cnepmob.volvocars.com`
* **Secondary / Backup Host**: `https://api.pccs-prod.plstr.io:443`
* **Protocol**: HTTP/2 gRPC with 5-byte framed Protobuf payloads
* **Authentication**: `Authorization: Bearer <access_token>`

### Microservice Endpoints & Live Data Feeds

| Service Path | RPC Method | Live Data Returned |
| :--- | :--- | :--- |
| `services.vehiclestates.battery.BatteryService` | `GetLatestBattery` | Battery SoC % (e.g. `75.0%`), Estimated Range (`270 km`), Charging Status (`IDLE`, `CHARGING`, `DONE`), Charger Connection (`UNCONNECTED`, `CONNECTED`), Power kW, Voltage V, Amps A, Time to full. |
| `services.vehiclestates.exterior.ExteriorService` | `GetLatestExterior` | Central lock state (`LOCKED` / `UNLOCKED`), Alarm status, 4 doors (`CLOSED` / `OPEN` / `AJAR`), 4 windows, tailgate, hood, charge lid, sunroof. |
| `services.vehiclestates.health.HealthService` | `GetHealth` | Total odometer km (`121,376 km`), Service due countdown (`347 days`, `5,726 km`), Service warning boolean, Brake fluid, Washer fluid, Engine coolant, 4 tyre pressure statuses (`OK` / `LOW` / `VERY_LOW`) & kPa values, 22 exterior bulb warning indicators, 12V battery warning. |
| `services.vehiclestates.odometer.OdometerService` | `GetOdometer` | High-precision trip meters: Manual trip (`1,287.4 km`), Automatic trip (`1.9 km`), Average speed km/h. |
| `services.vehiclestates.parkingclimatization.ParkingClimatizationService` | `GetLatestParkingClimatization` | HVAC running state, Timer triggered flag, Driver seat heat level (0–3), Front passenger seat heat level (0–3), Steering wheel heat level (0–3), Defrost active, Target setpoint °C, Cabin temp °C. |
| `services.vehiclestates.precleaning.PreCleaningService` | `GetPreCleaning` | CleanZone purifier state (`ON` / `OFF`), Cabin PM2.5 (`µg/m³`), Outdoor PM2.5, Cabin AQI (0–500), CleanZone filter remaining life %. |
| `ota_mobcache.OtaDiscoveryService` | `GetSoftwareInfo` | Current running OS version, Target OTA update version (e.g. `5.0.10`), Rollout state (`AVAILABLE`, `DOWNLOADING`, `INSTALLING`, `COMPLETED`), Release changelog title. |
| `dtlinternet.DtlInternetService` | `GetLastKnownLocation` | GPS coordinates (Latitude, Longitude), Altitude meters, Heading degrees, Accuracy meters, Parking brake (`ENGAGED` / `RELEASED`), Gear selector (`P`, `D`, `R`, `N`). |
| `weather.WeatherService` | `GetWeatherReport` | Hyper-local weather at vehicle location, Ambient temperature °C, Precipitation / Rain detection. |
| `pccs.chronos.services.v2.GlobalChargeTimerService` | `GetGlobalChargeTimer` | Pre-conditioning departure timers (Mon–Sun, Hour:Min) and smart charging windows. |
| `pccs.chronos.services.v1.TargetSocService` | `GetTargetSoc` / `SetTargetSoc` | Charging limit SoC target (50% – 100%). |
| `pccs.chronos.services.v1.AmpLimitService` | `GetAmpLimit` / `SetAmpLimit` | AC charging current limiter (6A – 32A). |
| `pccs.chronos.services.v1.ChargeNowService` | `StartOverrideChargeTimer` | Immediate charging override bypassing scheduled timers. |
| `pccs.chronos.services.v1.ParkingClimateTimerService` | `GetTimers` / `SetTimers` | Climate preconditioning schedules. |

---

## 6. Full Live Telemetry Dump (Captured Sample)

```json
{
  "vehicle": {
    "vin": "YSMVSEDE6PL147228",
    "model": "Polestar 2",
    "modelYear": "2023",
    "powertrain": "BEV",
    "market": "SE"
  },
  "battery": {
    "batteryPercentage": 75.0,
    "rangeKm": 270,
    "chargingState": "IDLE",
    "chargerConnection": "DISCONNECTED",
    "reportedBatteryCapacityKwh": 78.0
  },
  "odometerAndHealth": {
    "odometerKm": 121376,
    "tripMeterManualKm": 1287.4,
    "tripMeterAutomaticKm": 1.9,
    "daysToService": 347,
    "distanceToServiceKm": 5726,
    "serviceWarning": false,
    "fluidWarnings": [],
    "tyres": [
      { "position": "frontLeft", "status": "OK" },
      { "position": "frontRight", "status": "OK" },
      { "position": "rearLeft", "status": "OK" },
      { "position": "rearRight", "status": "OK" }
    ]
  },
  "closures": {
    "centralLock": "LOCKED",
    "frontLeftDoor": "CLOSED",
    "frontRightDoor": "CLOSED",
    "rearLeftDoor": "CLOSED",
    "rearRightDoor": "CLOSED",
    "frontLeftWindow": "CLOSED",
    "frontRightWindow": "CLOSED",
    "rearLeftWindow": "CLOSED",
    "rearRightWindow": "CLOSED",
    "hood": "CLOSED",
    "tailgate": "CLOSED",
    "chargeLid": "CLOSED"
  },
  "climate": {
    "activity": "IDLE",
    "driverSeatHeating": 0,
    "passengerSeatHeating": 0,
    "steeringWheelHeating": 0,
    "cleanZone": "OFF"
  },
  "software": {
    "availableVersion": "5.0.10",
    "state": "AVAILABLE"
  },
  "timestamp": "2026-08-16T02:31:57Z"
}
```

---

## 7. What We Can Build (Feature Opportunities)

With this complete suite of verified APIs, here are all the capabilities we can build into Hisingen:

### 1. 🪟 Monroney / Window Sticker & Factory Passport Exporter
* Export high-resolution PDF or printable vector passport of the vehicle containing:
  * Full factory spec (Paint code, interior trim, rim size, packages)
  * Manufacturing metadata (Luqiao build plant, build week `structureWeek`, PNO34 spec code)
  * Nominal vs live battery capacity and WLTP range retention index

### 2. 🗺 Live Interactive Blueprint & Closure Security Matrix
* Interactive 2D schematic of the vehicle exterior showing live status:
  * 4 Frameless doors, 4 power windows, panoramic glass roof, front hood, powered tailgate, motorized charge port flap
  * Live status indicator: Central Lock state + perimeter alarm armed status

### 3. 💨 CleanZone Air Purification & AQI Dashboard
* Live cabin environment card:
  * Real-time cabin PM2.5 vs outdoor ambient air PM2.5
  * Air Quality Index (AQI) dial with CleanZone HEPA filter remaining lifespan %
  * 1-click "Pre-Clean Cabin Air" remote action

### 4. 💺 2D Cabin Thermal Matrix
* Top-down cabin view showing live heating & climatization:
  * Driver & passenger seats with 3-stage amber glow per heating level
  * Steering wheel placement (LHD/RHD) with heating ring glow
  * Defrost flow visualization and comfort setpoint target

### 5. ⚡️ Smart Charging & Energy Optimizer
* Live charging curve with peak kW, instantaneous current (Amps), and voltage (Volts)
* Sliders for Target SoC % (50% – 100%) and AC Current Limit (6A – 32A)
* Electricity cost calculation based on trip computer statistics (Manual & Auto trip meters)

### 6. 💿 OTA Upgrade Center & Software Changelog Inspector
* Displays installed P2.x / P3.x OS version vs incoming OTA update (e.g. `5.0.10`)
* Update status tracking: `Downloading` → `Downloaded` → `Installation Scheduled` → `Completed`
* Countdown timer for scheduled overnight installations
