# Using Hisingen

Use the garage to switch vehicles, then set up notifications, shortcuts and the panel for how you use each car. The [product tour](product-tour.md) shows these settings with sample data.

[Garage](#multiple-vehicles) · [Notifications](#notifications) · [macOS integration](#macos-integration) · [Customisation](#make-it-yours) · [Local data](#your-data) · [Privacy](#privacy)

## Multiple vehicles

Hisingen supports accounts with more than one vehicle.

Each vehicle keeps its own:

* current cached state
* charging history
* charging baselines
* capability observations
* local nickname
* vehicle-specific settings

Polestar and Volvo authentication are also kept separate.

Switching cars doesn't mean mixing their histories or cached information together.

## Notifications

Hisingen can let you know about useful vehicle events without requiring the app to stay open in front of you.

Depending on the vehicle and the features you've enabled, notifications can include:

* charging started
* charging completed
* charging interrupted
* low battery
* tyre warnings
* service or vehicle-health warnings
* software-update information
* authentication issues
* an unlocked parked vehicle
* weather-related warnings when openings are detected
* unusually slow charging vs a location's own history
* service due soon, when the car shows a service warning or reports 30 days or 1,000 km or less
  to the next service
* a car left in convenience mode for 30 minutes (opt-in), since convenience mode keeps systems on
  and can drain the 12 V battery
* a daily summary (opt-in)
* a climate session whose run time is nearly used up, or whose battery is too low
* interactive banners: Lock and Mute This Vehicle on vehicle alerts, Resume Schedule
  from an interrupted-charging alert

Charging anomaly alerts are deduplicated per vehicle and respect the mute setting, notification
permission and quiet hours. Sustained alerts keep their elapsed warning time across an app restart. A dead session is shown as
signed out and asks you to sign in again even when notifications are off.

Notification behaviour can be configured in Settings.

## macOS integration

Hisingen is built as a native Mac application rather than a wrapped web app.

### Menu bar

The menu bar can show useful information without even opening the Hisingen window.

Depending on your preferences this can include:

* battery level
* range
* charging time
* charging power
* lock state
* compact status
* icon-only status

**Quick Controls** in the menu bar panel include windows, Charge Now / Resume Schedule and
pre-cleaning, where the car supports them. The menu bar item has VoiceOver actions,
custom tab icons have descriptive labels in every language, and the price curve reads out the hour
and price.

### Launch at Login

Hisingen can start automatically using the normal macOS Login Items system.

### Keyboard shortcuts

Keyboard shortcuts are available for common actions such as navigating the app or switching between vehicles.

Global shortcuts can require macOS Accessibility permission.

### System Spotlight

Search your car's nickname and see battery, range and charging state right in Spotlight
results. Entirely local, and the VIN is kept out of the index.

### Screenshot Privacy Mode

One toggle blurs VIN, registration plate, coordinates and addresses across the app so shared
screenshots stay safe.

### Floating charging panel

Optional tiny always-on-top panel with SoC→target, power and ETA while charging. It never
steals focus; drag it anywhere and the position is remembered.

### Calendar preconditioning

Hisingen can start cabin climate a set number of minutes before timed events in the calendars
you choose (Settings → Features). It reads events through macOS Calendar (EventKit); the
events stay on your Mac and are never sent anywhere. It schedules a single timer for the next one,
and re-checks after sleep and when the calendar changes. The climate command targets the active
vehicle and passes the same capability and feature checks as the manual control; because it is a
preconfigured automation with nobody at the Mac to answer a prompt, it does not raise the
device-owner confirmation even when that is required for the manual controls.

### Apple Shortcuts

Hisingen exposes cached vehicle information and command handoffs to Apple Shortcuts using
App Intents. The actions are:

| Group | Actions |
| --- | --- |
| Status | Get Vehicle Battery, Get Vehicle Status, Get Garage Status, Get Charging Status, Get Recent Trip Summary, Get Energy Breakdown, Get Tire Pressures, Where Is My Car, Refresh Vehicle Data |
| Charging | Set Charge Target, Set Charging Current, Charge Now, Resume Charging Schedule |
| Climate | Start Cabin Climate, Stop Cabin Climate, Start Cabin Pre-Cleaning, Stop Cabin Pre-Cleaning, Start Engine, Stop Engine |
| Security | Lock Vehicle, Unlock Vehicle (authenticated), Flash Vehicle Lights, Honk and Flash Vehicle |

That makes it possible to use this information and these commands inside your own macOS
automations.

Command intents never announce that the car changed state merely because the shortcut ran.
They hand the request to Hisingen, apply the same capability and authentication gates as the
normal controls, and let the app report the provider result. Volvo lock/location permissions
must first be approved for the developer application and enabled in Hisingen Settings.

### URL scheme

Hisingen also registers:

```text
hisingen://
```

for local application navigation and automation. Recognized routes:

| Route | Action | Brand |
| --- | --- | --- |
| `hisingen://lock` | Lock vehicle | Volvo, Polestar |
| `hisingen://unlock` | Unlock vehicle (confirmation first) | Volvo, Polestar |
| `hisingen://climate/start?temp=21` | Start climate (temp optional, clamped to 16–30 °C) | Volvo, Polestar |
| `hisingen://climate/stop` | Stop climate | Volvo, Polestar |
| `hisingen://flash` | Flash lights | Volvo, Polestar |
| `hisingen://honk-flash` | Honk + flash | Volvo, Polestar |
| `hisingen://engine/start?minutes=15` | Start engine (`5`, `10` or `15` minutes, confirmation first) | Volvo |
| `hisingen://engine/stop` | Stop engine | Volvo |
| `hisingen://precleaning/start` | Start cabin pre-cleaning | Polestar |
| `hisingen://precleaning/stop` | Stop cabin pre-cleaning | Polestar |
| `hisingen://windows/open` | Open all windows (confirmation first) | Polestar |
| `hisingen://windows/close` | Close all windows | Polestar |
| `hisingen://tailgate/open` | Open tailgate (confirmation first) | Polestar |
| `hisingen://tailgate/close` | Close tailgate | Polestar |
| `hisingen://trunk/unlock` | Unlock trunk (confirmation first) | Polestar |
| `hisingen://charge-target?percent=80` | Set charge target (clamped to 40–100%) | Polestar |
| `hisingen://charge-limit?amps=16` | Set charging current (clamped to 6–32 A) | Polestar |
| `hisingen://charging/override-start` | Charge now, overriding the schedule | Polestar |
| `hisingen://charging/override-stop` | Resume the charging schedule | Polestar |
| `hisingen://ota/schedule?delay=120` | Schedule software installation (`120`, `480` or `720` minutes) | Polestar |
| `hisingen://ota/install` | Install vehicle software now (confirmation first) | Polestar |
| `hisingen://ota/cancel` | Cancel software installation | Polestar |

Links accept an optional `vin=` query to target a vehicle other than the selected one.

Commands follow the same capability gates and confirmations as the in-app controls. A link
never sends a command the active brand or the vehicle does not offer: it gets a local notice
instead. Polestar commands also need a Polestar ID or Augmented connection; the Developer Portal
connection is read-only. Engine runtime and schedule delay must be one of the listed options,
or the link is refused with a notice. Temperature, charge target and charging current are
clamped to their ranges instead.

## Make it yours

Hisingen doesn't need to look identical on every Mac.

Settings has a **Search settings** field that finds sections by what you type, for example
"authorize" or "remote command" finds the Polestar authorization step. **Export Settings** and
**Import Settings** move your presentation, feature, update and notification preferences to
another Mac as one archive of up to 1 MB. Accounts, sessions, vehicles and history are not part of
it. **Reset Preferences** returns those preferences to defaults and keeps accounts, sessions,
vehicles and history.

### Themes

Nine themes are currently included:

* Hisingen
* Monochrome Precision
* Heritage Blue
* Nordic Night
* Aurora Borealis
* Charcoal Gold
* Circuit Blue
* Gothenburg Forest
* Sand Dune

Monochrome Precision and Heritage Blue are independent themes based on publicly documented
design principles from Polestar and Volvo Cars. They don't imply affiliation or endorsement.

**Your own theme.** *Create Theme* beside the theme grid asks for a name, an accent colour,
and a light and a dark background. Hisingen keeps the backgrounds as backgrounds and moves the
picked colours only as far as they need to go for text to clear a 4.5:1 contrast floor, then
previews the result in both appearances before you save. The theme joins the grid and can be
chosen per brand and per vehicle like any shipped one. *Delete* on an existing theme returns
anything that pointed at it to the default palette.

### Controls on Now

The cards under the car on Now are yours to choose. **Settings → Appearance → Controls on
Now** switches each one on or off: Locks, Climate, Charging, Air Cleaning, Windows, Honk &
Flash, and Tailgate. Locks, Climate and Charging are on by default. A chosen card draws only
when its remote feature is switched on and the car reports the capability, except that Locks
and Climate keep showing their state with remote commands off, and Charging shows its state on
any car with electric range. The grid closes up around whatever draws: three cards sit across,
four arrange as two by two, and accessibility text sizes stack them in one column.


### Tabs & Cards

Every card, section and banner in Hisingen is yours to place. **Settings → Tabs &
Cards** lists them per tab, and each one can be switched off, moved up or down, dragged
into a new position, or removed. The layout is stored once and read by the tabs
themselves, so what that pane shows is what the panel draws.

Hiding a card also stops Hisingen asking the vehicle for the data behind it — the
provider request is gated on the same setting. Switching the card back on resumes the
fetch. An install that predates this pane reads its existing feature toggles once as a
starting layout, so a card that was already off does not reappear.

**Tabs of your own.** *New tab* in the same pane creates a tab, names it and gives it an
icon; *Add Cards…* places anything you want on it, from any of the shipped tabs. Cards
are drawn by the same views the shipped tabs use, so the charging card behaves the same
whether it is on Now or on a tab you built. Cards that own a tab's own state — the
Log charts and the Car section bars — stay on the tab that gives them that state,
and the pane names them rather than leaving them out silently.

Any of Now, Plan, Log and Car can also be hidden from the tab bar.
Settings is always there: it is where the list is managed.

**Tab order.** The tab bar draws your tabs in your order, not the order they were
built in. Drag a tab along the strip in **Settings → Tabs & Cards**, or use Move to
First, Move Left and Move Right from its context menu or from the arrows beside the
selected tab's name, so a tab you just created can sit first. Hidden tabs keep their
place, so showing one again puts it back where it was, and *Restore Tab Order* returns
the shipped order without touching the cards on each tab.

### Panel size & content density

The menu bar dropdown adapts to how you use it. In
**Settings → General → Panel Size** you can pick one of five presets:
Compact, Standard, Large (tall), Wide, and Grand (wide & tall). **Custom Size**
enables independent width and height sliders. On Wide and Grand panels, mid-size
cards flow two per row and the vehicle render grows to use the extra room.

**Content Density** changes type size and spacing independently of the window size:
Compact tightens both so more content fits before scrolling, and Relaxed enlarges
both. It is a layout setting, not a zoom, so a text size chosen in System Settings
still applies on top of it. The right-click menu on the status icon offers both
settings for quick switching, every change applies live to an open panel, and
the panel never grows taller than the screen it opens on. The floating charging
panel follows the same density choice.

### Units

Units are selectable in **Settings → General**. Choosing miles as the distance
unit pre-selects the matching North American defaults for the other units, and
each can still be overridden individually.

Hisingen supports:

* kilometers / miles
* Celsius (°C) / Fahrenheit (°F)
* kilopascals (kPa) / PSI
* liters / US gallons / Imperial gallons
* L/100 km / US MPG / Imperial MPG / km/L
* kWh/100 km / kWh/100 mi / mi/kWh

### Languages

Hisingen currently includes:

* English
* Swedish
* German
* Norwegian (Bokmål)
* Danish
* Dutch
* French
* Spanish
* Italian
* Finnish
* Portuguese
* Polish
* Simplified Chinese
* Korean

You can also let Hisingen follow the system language automatically.

## Your data

Everything Hisingen keeps lives on your Mac, in a local SQLite database plus the macOS Keychain
for credentials.

* **Exports.** Charging sessions, detected trips and the Monthly Mileage Report export to CSV.
  The export menu on the Log tab also offers a **Full Backup (JSON)**, and Settings can export
  your settings (see [Make it yours](#make-it-yours)).
* **Handover pack.** **Car → Export Handover Pack…** writes a folder for a sale or trade: a
  summary, charging and trip CSVs without locations, an optional VIN (a checkbox in the save
  panel) and a checklist of the steps that still happen in the manufacturer app or in the car.
* **Erase.** **Settings → Privacy & Data → Erase This Vehicle’s Local Data** and **Erase All Local Vehicle Data**
  remove history, snapshots, activity and cached car artwork from memory, disk and SQLite.
  Recording stays paused for the affected vehicles until the cleanup finishes, so queued writes
  cannot bring erased data back. A failure in local erasure is reported separately from a
  failure to clear credential storage.
* **Sign out stays signed out.** Signing out clears the email, portal IDs, Volvo custom app, VIN
  and Keychain items for that brand and the memory cache. An explicit per-brand flag stops
  Hisingen from signing back in on relaunch from built-in developer credentials plus a lingering
  server-side grant. Saving credentials or signing in again lifts it. A cancelled or failed
  sign-in keeps your previous session.
* **Damaged or old data.** If a database migration fails, Hisingen keeps the legacy snapshots,
  charging baselines and command receipts and rolls back the partial write before retrying.

## Privacy

Hisingen doesn't operate a vehicle-data backend.

Your Mac communicates directly with the services needed for the features you use.

In practical terms:

|                                  |                                                           |
| -------------------------------- | --------------------------------------------------------- |
| **Hisingen account required**    | No                                                        |
| **Hisingen vehicle-data server** | No                                                        |
| **Analytics**                    | No                                                        |
| **Advertising**                  | No                                                        |
| **Credentials**                  | Stored using macOS Keychain where persistence is required |
| **Vehicle cache**                | Stored locally                                            |
| **Current vehicle coordinates**  | Not stored in the normal persistent vehicle-state cache   |
| **Vehicle weather**              | Coordinates are sent to Open-Meteo when enabled           |
| **Calendar events**              | Read locally from calendars you select; never sent anywhere |
| **Map integration**              | Uses Apple services where applicable                      |
| **Update checks**                | Uses Hisingen's signed Sparkle update feed                |

Your vehicle account, VIN, location and remote-control access are sensitive information, so Hisingen treats them accordingly.

For the full breakdown, see [Privacy](security/privacy.md), [Data retention](data-retention.md) and [Security](security/overview.md).
