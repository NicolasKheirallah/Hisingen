# Hisingen product tour

These screenshots show the macOS app with sample Polestar and Volvo vehicles, charging history, and home charger data. Readings and controls vary by vehicle and connection.

[Now](#now) · [Plan](#plan) · [Home charging](#home-charging) · [Log](#log) · [Car](#car) · [Settings](#settings) · [Documentation](README.md)

## Now

<img src="../assets/screenshots/now.png" width="560" alt="Hisingen Now tab showing a sample Polestar 2 at 72% battery with 308 km of estimated range, outside temperature, and controls for locks, climate and charging">

Check battery, estimated range, weather and locks. Use the cards below the car to start climate, charge or operate supported controls. Amber shows when heating or charging is active in the Monochrome Precision theme.

<img src="../assets/screenshots/now-charging-dark.png" width="620" loading="lazy" alt="Now tab in dark mode with amber cards for active cabin heating and charging">

<details>
<summary>Volvo hybrid and petrol views, quick controls, offline readings and the floating panel</summary>

**Volvo plug-in hybrid and petrol.** The XC40 Recharge shows combined range. The petrol V60 shows fuel and distance to empty.

<img src="../assets/screenshots/tour/now-volvo-hybrid.png" width="560" loading="lazy" alt="Volvo XC40 Recharge in Now with 61% battery and 396 km of combined estimated range">

<img src="../assets/screenshots/tour/now-volvo-combustion.png" width="560" loading="lazy" alt="Petrol Volvo V60 in Now with 55% fuel and 368 km of estimated range">

**Quick controls.** Put charge and current limits alongside the climate control.

<img src="../assets/screenshots/tour/now-limits.png" width="560" loading="lazy" alt="Now quick controls for active cabin climate, charge limit and current limit">

**Offline.** The panel labels readings from the last available copy.

<img src="../assets/screenshots/tour/now-offline.png" width="560" loading="lazy" alt="Now tab showing battery, range and controls with a Showing an offline copy notice">

**Floating charging panel.** Keep charge level, power and remaining time visible over other apps.

<img src="../assets/screenshots/tour/mini-panel.png" width="200" loading="lazy" alt="Floating charging panel showing 72% battery, a 90% target, 7.2 kW and 1 hour 57 minutes remaining">

</details>

## Plan

Check charging before departure, see timers on a 24-hour ruler, and adjust the charge target or current limit.

<img src="../assets/screenshots/plan.png" width="620" loading="lazy" alt="Plan tab with the departure check, a 24-hour timeline, a weekday climate timer, an overnight charging window, and battery and current limits">

<details>
<summary>Schedule editor, charging and climate controls, spot prices and command routines</summary>

**Schedules.** Edit a cabin preconditioning timer and pick the days it repeats.

<img src="../assets/screenshots/tour/schedule-editor.png" width="380" loading="lazy" alt="Manage Schedules editor with a 7:30 AM cabin timer set to repeat on weekdays">

**Charging and comfort.** Adjust limits, override a charging schedule, manage charge locations or use the climate controls supported by the car.

<img src="../assets/screenshots/tour/plan-charging.png" width="560" loading="lazy" alt="Plan charging controls with charge target, current presets, Charge Now, Resume Schedule and saved charge locations">

<img src="../assets/screenshots/tour/plan-comfort.png" width="560" loading="lazy" alt="Plan showing timers, climate and conditioning controls, and the Routines section">

**Charging Planner.** Use Swedish spot prices to compare the cheapest charging window with the cost of starting now.

<img src="../assets/screenshots/tour/plan-price-planner.png" width="560" loading="lazy" alt="Charging Planner with the cheapest sample charging window, estimated savings and an hourly price chart">

**Command routines and receipts.** Save a sequence of actions and see whether the vehicle has confirmed a command.

<img src="../assets/screenshots/tour/plan-routine-editor.png" width="380" loading="lazy" alt="Leave work routine with steps to start climate, set the charge target to 80% and lock the vehicle">

<img src="../assets/screenshots/tour/plan-command-status.png" width="560" loading="lazy" alt="Two lock command receipts, one waiting for the vehicle and one confirmed by a matching reading">

</details>

## Home charging

Pair a home charger to see wall power, delivered energy and charger actions. [Home charging setup](home-charging.md)

<details>
<summary>Home Assistant plans, Easee and Zaptec pairing, and Tibber pricing</summary>

**Home Assistant.** Connect the integration and review a scheduled home charge.

<img src="../assets/screenshots/tour/home-assistant-setup.png" width="560" loading="lazy" alt="Home Charging settings with Home Assistant connection fields and provider choices">

<img src="../assets/screenshots/tour/home-assistant-plan.png" width="464" loading="lazy" alt="NexBlue wallbox connected through Home Assistant, with a scheduled charging window and Edit plan action">

**Direct pairing.** Choose an Easee or Zaptec charger and vehicle, then see charging progress and pause the session.

<img src="../assets/screenshots/tour/easee-pairing.png" width="560" loading="lazy" alt="Easee setup showing a sample Garage charger and a vehicle picker">

<img src="../assets/screenshots/tour/zaptec-pairing.png" width="560" loading="lazy" alt="Zaptec setup showing a sample Driveway charger, a vehicle picker and a Pair charger button">

<img src="../assets/screenshots/tour/easee-charging.png" width="464" loading="lazy" alt="Easee charging card showing 7.3 kW of power, 12.4 kWh delivered and a Pause button">

**Tibber.** Use the selected home's electricity prices when costing charging sessions.

<img src="../assets/screenshots/tour/tibber-pricing.png" width="560" loading="lazy" alt="Electricity Supplier settings showing Tibber connected to a sample home and used for charging sessions">

</details>

<details>
<summary>NexBlue controls, overnight timer and session import</summary>

The charger card shows when NexBlue has accepted a start or pause request and is waiting for the charger to confirm it.

<img src="../assets/screenshots/3.0.0/nexblue-charger-controls.png" width="464" loading="lazy" alt="NexBlue charger card waiting for the charger to confirm a start command">

**Cheapest overnight charge** previews a timer using Swedish spot prices and the charger's time zone.

<img src="../assets/screenshots/3.0.0/nexblue-overnight-timer.png" width="432" loading="lazy" alt="Three-hour timer preview showing 01:00 to 04:00 in Europe/Stockholm and a Save timer button">

**Import earlier sessions** lets you choose a date range. Settings shows the range checked by the last successful import.

<img src="../assets/screenshots/3.0.0/nexblue-import-range.png" width="432" loading="lazy" alt="Import earlier sessions sheet with start and end date fields">

<img src="../assets/screenshots/3.0.0/nexblue-import-summary.png" width="560" loading="lazy" alt="Home Charging settings showing a successful NexBlue session import and the date range checked">

</details>

<details>
<summary>Grid tariff and house meter</summary>

**Grid tariff.** Pick the country and the tariff your grid company charges per kWh on top of the electricity price. Sweden, Norway, Denmark, Germany and the Netherlands are offered, with presets for Vattenfall and Elvia. [Grid tariff](home-charging.md#grid-tariff)

<img src="../assets/screenshots/live/settings/grid-tariff.png" width="560" loading="lazy" alt="Grid Tariff settings with the country set to Sweden and the tariff set to No grid fee">

**House meter.** Read a Perific monitor to see the whole house next to the charger. Hisingen only reads it, and Perific keeps balancing the charger. [Perific house meter](home-charging.md#connect-a-perific-house-meter)

<img src="../assets/screenshots/live/settings/house-meter.png" width="560" loading="lazy" alt="House Meter settings showing a Perific meter read every 30 seconds, with house power, voltage and current per phase, and energy imported today">

</details>

## Log

Pick a period to review charging, driving, climate and vehicle status. The charge-level chart shows where each session started and ended.

<img src="../assets/screenshots/log.png" width="620" loading="lazy" alt="Log tab showing 30 days of estimated charging energy, four charge-level ranges and a month-to-month comparison">

<details>
<summary>Charging sessions and costs, trips and mileage, fuel, and vehicle trends</summary>

**Charging sessions and costs.** Open a session to see the observed charge curve and the estimate's source. Compare costs by month or location.

<img src="../assets/screenshots/tour/log-sessions.png" width="620" loading="lazy" alt="Charging session list and selected session curve for battery percentage, power, voltage and current">

<img src="../assets/screenshots/tour/log-costs.png" width="620" loading="lazy" alt="Charging by Month chart and Charge by Location table with energy and cost for Home and Work">

**Driving.** Review detected trips, business and private mileage, distance, efficiency and odometer trends.

<img src="../assets/screenshots/tour/log-trips.png" width="620" loading="lazy" alt="Detected Trips list above the Monthly Mileage Report with an Export report action">

<img src="../assets/screenshots/tour/log-driving-trends.png" width="620" loading="lazy" alt="Log charts for distance over time, consumption and odometer history">

**Fuel.** Record fill-ups and review fuel economy and cost per distance for a compatible Volvo.

<img src="../assets/screenshots/tour/log-fuel.png" width="620" loading="lazy" alt="Volvo fuel economy chart and recent fill-ups with litres, cost and odometer readings">

**Vehicle trends.** Follow estimated battery health, tyre pressure, cabin temperature and air quality. Review warning events and the command log.

<img src="../assets/screenshots/tour/log-battery-health.png" width="620" loading="lazy" alt="Calculated battery health trend with estimated usable capacity and recorded mileage">

<img src="../assets/screenshots/tour/log-tyres.png" width="620" loading="lazy" alt="Four-tyre pressure history with a possible slow leak marked at the rear-left tyre">

<img src="../assets/screenshots/tour/log-cabin.png" width="620" loading="lazy" alt="Cabin temperature and air quality trends with a filter remaining reading">

<img src="../assets/screenshots/tour/log-warning-timeline.png" width="620" loading="lazy" alt="Warning Timeline showing when the tyre warning appeared and the exterior light warning cleared">

<img src="../assets/screenshots/tour/log-commands.png" width="620" loading="lazy" alt="Automations and Commands log with result and timing for recent remote commands">

</details>

## Car

Find the model year, odometer, battery capacity and charge port type. The other cards show what the car reports about openings, service, software, and its last parking location.

<img src="../assets/screenshots/car.png" width="620" loading="lazy" alt="Car tab showing the Polestar 2 profile and specifications above timestamps for battery and range readings">

<details>
<summary>Diagnostics, parking, remote access, charge locations and vehicle capabilities</summary>

**Openings and health.** Check doors, windows and tyre pressures against the car's reported reference.

<img src="../assets/screenshots/tour/car-openings-and-tyres.png" width="620" loading="lazy" alt="Doors and Openings diagram, a low rear-left tyre reading and fluids and lighting diagnostics">

**Remote access and parking.** Lock or unlock, close windows or locate the car where supported. Open the last reported parking location in Maps.

<img src="../assets/screenshots/tour/car-controls.png" width="620" loading="lazy" alt="Car controls for locks, tailgate, windows, lights and horn">

<img src="../assets/screenshots/tour/car-parking.png" width="620" loading="lazy" alt="Sample parking location in Gothenburg with heading, gear, parking brake and an Open in Maps menu">

**Software, service and powertrain.** Review update availability, the service countdown, specifications and reading timestamps.

<img src="../assets/screenshots/tour/car-software-and-service.png" width="620" loading="lazy" alt="Software and Updates card above the Service Schedule countdown">

<img src="../assets/screenshots/tour/car-specs.png" width="620" loading="lazy" alt="Powertrain specifications, trip computer readings and freshness timestamps">

<img src="../assets/screenshots/tour/car-battery-diagnostics.png" width="620" loading="lazy" alt="Calculated battery health, battery diagnostics and Polestar CleanZone readings">

**Saved locations and capabilities.** Review charging limits for each saved place and see which features the selected car reports.

<img src="../assets/screenshots/tour/car-charge-locations.png" width="620" loading="lazy" alt="Saved Charge Locations showing Home and Work current limits and minimum charge levels">

<img src="../assets/screenshots/tour/saved-location-editor.png" width="380" loading="lazy" alt="Save Charge Location form with a name, current limit, minimum charge and optimised charging setting">

<img src="../assets/screenshots/tour/car-capabilities.png" width="620" loading="lazy" alt="Vehicle Capabilities list showing supported and unavailable features for the sample Polestar 2">

</details>

## Settings

Open **Appearance → Create Theme** to preview your accent and background colours in light and dark mode.

<img src="../assets/screenshots/create-theme.png" width="400" loading="lazy" alt="Create Theme editor with colour pickers and side-by-side battery and heating previews in light and dark mode">

<details>
<summary>Accounts and garage, appearance, features, notifications, privacy and data</summary>

**Accounts and garage.** Start with Polestar or Volvo, then manage both brands from the garage.

<img src="../assets/screenshots/tour/sign-in-polestar.png" width="440" loading="lazy" alt="Polestar sign-in screen showing Polestar ID and Developer Portal options">

<img src="../assets/screenshots/tour/sign-in-volvo.png" width="440" loading="lazy" alt="Volvo sign-in screen with a Sign In with Volvo ID button">

<img src="../assets/screenshots/tour/settings-garage.png" width="620" loading="lazy" alt="Garage and Fleet settings for a Polestar 2 and a Volvo XC40 Recharge">

**Appearance and layout.** Choose quick controls, themes, and the tabs and cards that appear in the panel.

<img src="../assets/screenshots/tour/settings-appearance.png" width="560" loading="lazy" alt="Appearance settings with Controls on Now tiles, theme choices and panel sizing">

<img src="../assets/screenshots/tour/settings-tabs.png" width="560" loading="lazy" alt="Tabs and Cards settings with visibility and ordering controls">

**General, electricity and features.** Set display units and energy options, choose an electricity rate, and control which data and remote actions the app uses.

<img src="../assets/screenshots/tour/settings-general.png" width="560" loading="lazy" alt="Display, Units and Energy settings with refresh and unit controls">

<img src="../assets/screenshots/tour/settings-electricity.png" width="560" loading="lazy" alt="Electricity settings showing country, rate mode and fixed price">

<img src="../assets/screenshots/tour/settings-features.png" width="560" loading="lazy" alt="Vehicle data settings with battery, location, software and diagnostics switches">

<img src="../assets/screenshots/tour/settings-remote-commands.png" width="560" loading="lazy" alt="Remote Controls settings with command authorization and per-command switches">

**Notifications and calendar.** Choose the alerts you want and set up preconditioning around calendar events.

<img src="../assets/screenshots/tour/settings-notifications.png" width="560" loading="lazy" alt="Settings for charging, health, doors, software and other macOS notifications">

<img src="../assets/screenshots/tour/settings-calendar.png" width="560" loading="lazy" alt="Calendar Preconditioning switch in Features settings">

**Privacy, local data and updates.** See what stays on the Mac, manage imports and exports, and choose when the app checks for updates.

<img src="../assets/screenshots/tour/settings-privacy.png" width="560" loading="lazy" alt="Privacy Dashboard showing location retention, screenshot redaction and command authentication">

<img src="../assets/screenshots/tour/settings-data.png" width="560" loading="lazy" alt="SQLite Storage and Data settings with history exports, JSON backup and storage maintenance">

<img src="../assets/screenshots/tour/settings-updates.png" width="560" loading="lazy" alt="Hisingen Updates settings with manual update check and automatic update options">

</details>

For features that run outside the panel, see [macOS integration](using-hisingen.md#macos-integration) for menu bar states, keyboard shortcuts, Spotlight, Shortcuts and URL actions.
