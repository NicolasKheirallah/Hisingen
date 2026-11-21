# Localization native review

Date: 2026-11-21. Scope: the home-charging pass that shipped today. A translation agent wrote
the strings below in one session; they read plausibly but no native speaker has confirmed them.
This file lists, per language, every string that needs a native reader, with its English source
and the shipped value. Fix in place; key parity must stay green, so edit values, not keys.

Sections: the 8 keys added this morning under `// Added 2026-11-21` (written by an earlier model),
then the roughly 170 charger, charger-details, sign-in and Perific house-meter strings translated
today, then anything flagged. Swedish is the owner's language: his section lists what still falls
back to English so he can write it himself.

Least sure, ranked: nn first, then fi, ko, zh, and the theme-name coinages everywhere.

---

## da

Confidence: High confidence in grammar and tone; the coined terms flagged below need a Dane's eye.

- Fixed today's earlier draft: "Volvo er skiftet til et nyt login-system" became "Volvo har skiftet til et nyt loginsystem" (active voice, compound without hyphen).

### Today's morning additions (verify as shipped)

| English source | Shipped value |
| --- | --- |
| Volvo moved to a new sign-in system. Sign in again to keep your vehicle data. | Volvo har skiftet til et nyt loginsystem. Log ind igen for at beholde dine bildata. |
| Drive Type | Drivtype |
| Engine Power | Motoreffekt |
| Gross Weight | Totalvægt |
| Seats | Sæder |
| Last changed %@ | Sidst ændret %@ |
| %d kW | %d kW |
| %d kg | %d kg |

### Strings translated today (168 keys)

| English source | Shipped value |
| --- | --- |
| %@ accepted the command. Waiting for the charger to confirm. | %@ accepterede kommandoen. Venter på, at opladeren bekræfter. |
| %@ did not accept the saved login | %@ accepterede ikke det gemte login |
| %@ did not accept the saved login. Enter the account and password again to reconnect. | %@ accepterede ikke det gemte login. Indtast konto og adgangskode igen for at genoprette forbindelsen. |
| %@ from charger | %@ fra opladeren |
| %@ is delaying the start | %@ udskyder starten |
| %@ is unreachable | %@ kan ikke nås |
| %@ per phase | %@ pr. fase |
| %@ per phase, limit %@ | %@ pr. fase, grænse %@ |
| %@ to the grid | %@ til elnettet |
| %@, limited by the cable | %@, begrænset af kablet |
| %@, limited by the circuit fuse | %@, begrænset af kurssikringen |
| %d charger sessions could not be tied to a vehicle and are kept unassigned. | %d opladersessioner kunne ikke knyttes til et køretøj og gemmes uden køretøjstilknytning. |
| A charger schedule or EcoPilot is active. Turn it off in the NexBlue app so Home Assistant controls the start. | En opladningsplan eller EcoPilot er aktiv. Slå den fra i NexBlue-appen, så Home Assistant styrer starten. |
| A charging schedule is active on the charger. | En opladningsplan er aktiv på opladeren. |
| A delayed start or EcoPilot is active on the charger. | En forsinket start eller EcoPilot er aktiv på opladeren. |
| A shared charger only records a session for this vehicle when the car's own charging overlaps it. | En delt oplader registrerer kun en session for dette køretøj, når bilens egen opladning overlapper den. |
| Account email | Konto-e-mail |
| Adaptive | Adaptiv |
| Added to Tibber prices in the planner and for charger sessions. | Lægges til Tibbers priser i planlæggeren og ved prisning af opladersessioner. |
| After an error | Efter en fejl |
| At the charger | Ved opladeren |
| By an administrator | Af en administrator |
| By schedule | Efter plan |
| Cable Rating | Kabelkapacitet |
| Cable lock | Kabellås |
| Cable unlocked | Kabel låst op |
| Cable unplugged | Kabel frakoblet |
| Calculated from the meter's current and voltage, so it can read slightly above the energy your supplier bills. | Beregnet ud fra målerens strøm og spænding, så tallet kan ligge lidt over den energi, din leverandør fakturerer. |
| Car %@, rest of the house %@ | Bilen %@, resten af huset %@ |
| Charge complete | Opladning fuldført |
| Charger Details | Opladerdetaljer |
| Charger Energy | Opladerenergi |
| Charger connection | Opladerforbindelse |
| Charger measurement only | Kun opladermåling |
| Charger restarted | Oplader genstartet |
| Charger updated %@ ago | Opladeren blev opdateret for %@ siden |
| Charger-measured home sessions against the house meter's readings from Perific, %@ to %@. Charging away from home never reaches that meter. | Hjemmesessioner målt af opladeren op imod husmålerens aflæsninger fra Perific, %@ til %@. Opladning uden for hjemmet når aldrig frem til den måler. |
| Charging at reduced power | Oplader med reduceret effekt |
| Charging enabled | Opladning aktiveret |
| Charging is enabled but the car is drawing no power | Opladning er aktiveret, men bilen trækker ingen strøm |
| Charging state | Opladningstilstand |
| Charging switch | Opladningskontakt |
| Charging uses the lowest. The car and load balancing can ask for less. | Opladningen bruger den laveste. Bilen og lastbalanceringen kan bede om mindre. |
| Checked %@ | Tjekket %@ |
| Circuit Blue | Racerbaneblå |
| Circuit Fuse | Kurssikring |
| Connect and find chargers | Opret forbindelse, og find opladere |
| Connected through | Forbundet via |
| Copy custom_components/hisingen_home_charging into your Home Assistant config folder, add hisingen_home_charging: to configuration.yaml and restart. The Home Charging guide in the repository has the steps. | Kopiér custom_components/hisingen_home_charging til din Home Assistant-konfigurationsmappe, tilføj hisingen_home_charging: i configuration.yaml, og genstart. Guiden Home Charging i repositoriet har trinnene. |
| Current per Phase | Strøm pr. fase |
| Disconnect Perific | Kobl Perific fra |
| Emergency stop | Nødstop |
| Entities | Entiteter |
| Exported Today | Eksporteret i dag |
| Held by load balancing | Holdt tilbage af lastbalancering |
| Hisingen is not signed in to %@ yet. | Hisingen er endnu ikke logget ind på %@. |
| Home Assistant accepted the command. Waiting for the charger to confirm. | Home Assistant accepterede kommandoen. Venter på, at opladeren bekræfter. |
| Home Assistant stops the plan and leaves the charger as it is. | Home Assistant stopper planen og lader opladeren være, som den er. |
| Home Charging | Hjemmeopladning |
| Home charger | Hjemmeoplader |
| Home charging plan | Hjemmeopladningsplan |
| House %@ | Huset %@ |
| House Current per Phase | Husets strøm pr. fase |
| House Meter | Husmåler |
| House Now | Huset nu |
| House Voltage | Husets spænding |
| House meter last read %@ ago | Husmåleren blev sidst aflæst for %@ siden |
| House sending %@ to the grid | Huset sender %@ til elnettet |
| Import sessions now | Importér sessioner nu |
| Imported Today | Importeret i dag |
| Importing | Importerer |
| Last update from %@ %@ | Seneste opdatering fra %@ %@ |
| Load balancing can limit the charger when the house uses more power. | Lastbalancering kan begrænse opladeren, når huset bruger mere strøm. |
| Load balancing is holding the charger. It continues when power is free. | Lastbalancering holder opladeren tilbage. Opladningen fortsætter, når der er ledig kapacitet. |
| Map by hand | Kortlæg manuelt |
| Measured at the charger, so it includes charging losses. | Målt ved opladeren, så tallet omfatter tab under opladningen. |
| Measured from recent charger sessions. It updates when the car charges slower than planned. | Målt ud fra de seneste opladersessioner. Tallet opdateres, når bilen oplader langsommere end planlagt. |
| Meter | Måler |
| Metered by the charger and read from Home Assistant. Last charger reading %@. | Målt af opladeren og aflæst fra Home Assistant. Seneste opladeraflæsning %@. |
| Metered by the charger and read from the %@ cloud. Last charger reading %@. | Målt af opladeren og aflæst fra %@-skyen. Seneste opladeraflæsning %@. |
| Mobile data | Mobildata |
| Needed to keep charger sessions in Hisingen's local history. | Nødvendigt for at beholde opladersessioner i Hisingens lokale historik. |
| NexBlue is delaying the start | NexBlue udskyder starten |
| NexBlue is holding a delayed start | NexBlue holder en forsinket start tilbage |
| NexBlue is holding the start with a delayed start. | NexBlue holder starten tilbage med en forsinket start. |
| No NexBlue charger was found. Map the entities by hand below. | Der blev ikke fundet nogen NexBlue-oplader. Kortlæg entiteterne manuelt nedenfor. |
| No charger is paired. | Ingen oplader er parret. |
| No charging switch is mapped for this charger. | Der er ikke tilknyttet nogen opladningskontakt til denne oplader. |
| No new reading arrived from the charger. | Der kom ikke en ny aflæsning fra opladeren. |
| Not authorised | Ikke godkendt |
| Not imported yet | Endnu ikke importeret |
| Off: local charging history is disabled | Fra: lokal opladningshistorik er deaktiveret |
| On plug-in | Ved tilkobling |
| Only the session total was available, so this is an estimate. | Kun sessionens total var tilgængelig, så dette er et estimat. |
| Optional. Connects a charger that Home Assistant manages, such as NexBlue, to show its status, control it, and record what it measured. | Valgfrit. Tilslutter en oplader, som Home Assistant administrerer, f.eks. NexBlue, så du kan se status, styre den og registrere det, den har målt. |
| Optional. Connects a home charger to show its status, control it, and record what it measured. Easee and Zaptec sign in with their own account. Any other charger works through Home Assistant, such as NexBlue. | Valgfrit. Tilslutter en hjemmeoplader, så du kan se dens status, styre den og registrere det, den har målt. Easee og Zaptec logger ind med deres egen konto. Alle andre opladere fungerer via Home Assistant, f.eks. NexBlue. |
| Optional. Reads your home's electricity use from a Perific monitor, so charging can be shown against the whole house. Hisingen only reads it. Perific keeps balancing the charger. | Valgfrit. Læser hjemmets elforbrug fra en Perific-måler, så opladningen kan vises op imod hele huset. Hisingen aflæser den kun. Perific klarer fortsat balanceringen af opladeren. |
| Other cars also use this charger | Andre biler bruger også denne oplader |
| Pair charger | Par oplader |
| Perific account email | E-mail til Perific-konto |
| Perific did not accept the saved login. Enter the account and password again to reconnect. | Perific accepterede ikke det gemte login. Indtast konto og adgangskode igen for at genoprette forbindelsen. |
| Perific did not accept the saved login. Sign in again in Settings, Electricity. | Perific accepterede ikke det gemte login. Log ind igen under Indstillinger, El. |
| Phase Mode | Fasetilstand |
| Plans run inside Home Assistant. This charger is connected directly, so it offers status, Charge now, Pause and history. | Planer kører inde i Home Assistant. Denne oplader er tilsluttet direkte, så den tilbyder status, Oplad nu, Pause og historik. |
| Power loss | Strømsvigt |
| Price source: %@. | Priskilde: %@. |
| Priced per 15-minute interval from the charger's own readings. | Prissat pr. 15-minuts interval ud fra opladerens egne aflæsninger. |
| Reading chargers… | Læser opladere… |
| Reading every 30 seconds | Aflæsning hvert 30. sekund |
| Remotely | Fjernstyret |
| Reported %@ | Rapporteret %@ |
| Resume | Genoptag |
| Sending the pause command to %@ | Sender pausekommandoen til %@ |
| Sending the start command to %@ | Sender startkommandoen til %@ |
| Session history | Sessionshistorik |
| Sessions and plans are tied to this vehicle only. A car being near the charger is not enough. | Sessioner og planer knyttes kun til dette køretøj. At en bil står tæt på opladeren, er ikke nok. |
| Sessions are tied to this vehicle only. A car being near the charger is not enough. | Sessioner knyttes kun til dette køretøj. At en bil står tæt på opladeren, er ikke nok. |
| Shared charger | Delt oplader |
| Sign in | Log ind |
| Sign in again in Settings. | Log ind igen i Indstillingerne. |
| Sign in and find chargers | Log ind, og find opladere |
| Sign in and find meters | Log ind, og find målere |
| Sign in to %@ again | Log ind på %@ igen |
| Sign out | Log ud |
| Sign-in refused | Login nægtet |
| Sign-in rejected | Login afvist |
| Signed in to %@ | Logget ind på %@ |
| Signing in… | Logger ind… |
| Single phase | Enfaset |
| Source | Kilde |
| Still needed: %@. | Mangler stadig: %@. |
| The account or password was not accepted. | Kontoen eller adgangskoden blev ikke accepteret. |
| The account you use in the Perific app. It is stored in the macOS Keychain and never exported. | Den konto, du bruger i Perific-appen. Den gemmes i macOS Nøglering og eksporteres aldrig. |
| The cable allows %@. | Kablet tillader %@. |
| The charger command was rejected | Opladerkommandoen blev afvist |
| The charger did not confirm the last command. | Opladeren bekræftede ikke den seneste kommando. |
| The charger has not confirmed the command | Opladeren har ikke bekræftet kommandoen |
| The charger has not reported recently | Opladeren har ikke rapporteret for nylig |
| The charger is unavailable in %@ | Opladeren er utilgængelig i %@ |
| The charger is unavailable in Home Assistant | Opladeren er utilgængelig i Home Assistant |
| The charger is unavailable in Home Assistant. | Opladeren er utilgængelig i Home Assistant. |
| The charger kept its previous state. Try again, or check the charger. | Opladeren bevarede sin tidligere tilstand. Prøv igen, eller tjek opladeren. |
| The charger readings below are the last ones received. | Aflæsningerne nedenfor er de seneste, der er modtaget fra opladeren. |
| The charger recorded this session while no battery reading was available, so there is no battery-side estimate. | Opladeren registrerede denne session, mens der ikke var nogen batteriaflæsning, så der findes ikke noget estimat fra batterisiden. |
| The charger reported an error after the command. | Opladeren rapporterede en fejl efter kommandoen. |
| The charger reports about once a minute. | Opladeren rapporterer cirka en gang i minuttet. |
| The charger reports an error | Opladeren rapporterer en fejl |
| The charger service asked Hisingen to slow down. It will try again shortly. | Opladertjenesten bad Hisingen om at vente lidt. Den prøver igen om kort tid. |
| The charger service could not be reached. | Opladertjenesten kunne ikke nås. |
| The charger service does not know that item. | Opladertjenesten kender ikke det pågældende element. |
| The charger service refused the request. | Opladertjenesten afviste forespørgslen. |
| The charger service sent an answer Hisingen could not read. | Opladertjenesten sendte et svar, som Hisingen ikke kunne læse. |
| The circuit fuse is %@. | Kurssikringen er %@. |
| The limit is set to %@. | Grænsen er sat til %@. |
| The meter sent no voltage, so 230 V is assumed and power is approximate. | Måleren sendte ingen spænding, så der regnes med 230 V, og effekten er omtrentlig. |
| The one you use in the %@ app. It is stored in the macOS Keychain and never exported. | Den, du bruger i %@-appen. Den gemmes i macOS Nøglering og eksporteres aldrig. |
| The saved location in the car where this charger stands. | Den gemte placering i bilen, hvor denne oplader står. |
| The saved token and the charger pairing are deleted. Charging history that was already recorded stays. | Det gemte token og opladerparingen slettes. Opladningshistorik, der allerede er registreret, bevares. |
| This Home Assistant automation uses the charger and may start or stop it. | Denne Home Assistant-automatisering bruger opladeren og kan starte eller stoppe den. |
| This account has no charger that Hisingen can control. Check that it is the owner account in the %@ app. | Denne konto har ingen oplader, som Hisingen kan styre. Tjek, at det er ejer-kontoen i %@-appen. |
| This account has no meter that Hisingen can read. Check that it is the owner account in the Perific app. | Denne konto har ingen måler, som Hisingen kan aflæse. Tjek, at det er ejer-kontoen i Perific-appen. |
| This account may not control that charger. | Denne konto har muligvis ikke tilladelse til at styre den oplader. |
| This account no longer lists the meter | Denne konto viser ikke længere måleren |
| This token could not read the device list, so chargers were found by their entity names. An administrator token also finds the serial number. | Dette token kunne ikke læse enhedslisten, så opladerne blev fundet ud fra deres entitetsnavne. Et administrator-token finder også serienummeret. |
| Three phase | Trefaset |
| Tibber's price includes energy, taxes and its markup but not the grid fee. Add yours here; a paired charger can set its own. | Tibbers pris indeholder energi, afgifter og deres egen avance, men ikke gebyret til elnettet. Tilføj dit her; en parret oplader kan selv angive sit eget. |
| Unpair charger | Afpar oplader |
| Use this meter | Brug denne måler |

### Flagged for this language

- Pair charger / Unpair charger uses "Par oplader" / "Afpar oplader" (Android-style loan); Bluetooth Danish usually says "kobl sammen". Confirm the buttons read naturally.
- "Racerbaneblå" is a coined theme name for Circuit Blue, matching "Mesterskabsblå" already shipped for its subtitle.
- "Opladningskontakt" for the Home Assistant charging-switch entity; Danish HA users may expect "switch"-enhed wording.
- Today's earlier block: "Drivtype" for Drive Type is used by some Danish car sites; Volvo Danmark may have its own term.
- "Kurssikring" assumes the household circuit term "kurs"; confirm for an electrician audience.

## de

Confidence: High confidence; du-register matches the file. The coined theme name and fuse term should be confirmed.


### Today's morning additions (verify as shipped)

| English source | Shipped value |
| --- | --- |
| Volvo moved to a new sign-in system. Sign in again to keep your vehicle data. | Volvo hat auf ein neues Anmeldesystem umgestellt. Melde dich erneut an, damit deine Fahrzeugdaten erhalten bleiben. |
| Drive Type | Antriebsart |
| Engine Power | Motorleistung |
| Gross Weight | Gesamtgewicht |
| Seats | Sitze |
| Last changed %@ | Zuletzt geändert: %@ |
| %d kW | %d kW |
| %d kg | %d kg |

### Strings translated today (168 keys)

| English source | Shipped value |
| --- | --- |
| %@ accepted the command. Waiting for the charger to confirm. | %@ hat den Befehl angenommen. Warte auf die Bestätigung des Ladegeräts. |
| %@ did not accept the saved login | %@ hat die gespeicherte Anmeldung nicht akzeptiert |
| %@ did not accept the saved login. Enter the account and password again to reconnect. | %@ hat die gespeicherte Anmeldung nicht akzeptiert. Gib Konto und Passwort erneut ein, um die Verbindung wiederherzustellen. |
| %@ from charger | %@ vom Ladegerät |
| %@ is delaying the start | %@ verzögert den Start |
| %@ is unreachable | %@ ist nicht erreichbar |
| %@ per phase | %@ pro Phase |
| %@ per phase, limit %@ | %@ pro Phase, Limit %@ |
| %@ to the grid | %@ ins Netz |
| %@, limited by the cable | %@, durch das Kabel begrenzt |
| %@, limited by the circuit fuse | %@, durch die Stromkreissicherung begrenzt |
| %d charger sessions could not be tied to a vehicle and are kept unassigned. | %d Ladesitzungen konnten keinem Fahrzeug zugeordnet werden und bleiben ohne Zuordnung. |
| A charger schedule or EcoPilot is active. Turn it off in the NexBlue app so Home Assistant controls the start. | Ein Ladezeitplan oder EcoPilot ist aktiv. Deaktiviere ihn in der NexBlue-App, damit Home Assistant den Start steuert. |
| A charging schedule is active on the charger. | Ein Ladezeitplan ist am Ladegerät aktiv. |
| A delayed start or EcoPilot is active on the charger. | Ein verzögerter Start oder EcoPilot ist am Ladegerät aktiv. |
| A shared charger only records a session for this vehicle when the car's own charging overlaps it. | Ein geteiltes Ladegerät speichert nur dann eine Sitzung für dieses Fahrzeug, wenn die eigene Ladung des Autos sich damit überschneidet. |
| Account email | Konto-E-Mail-Adresse |
| Adaptive | Adaptiv |
| Added to Tibber prices in the planner and for charger sessions. | Wird zu den Tibber-Preisen im Planer und für Ladesitzungen hinzugefügt. |
| After an error | Nach einem Fehler |
| At the charger | Am Ladegerät |
| By an administrator | Durch einen Administrator |
| By schedule | Nach Zeitplan |
| Cable Rating | Kabelbelastbarkeit |
| Cable lock | Kabelverriegelung |
| Cable unlocked | Kabel entriegelt |
| Cable unplugged | Kabel abgezogen |
| Calculated from the meter's current and voltage, so it can read slightly above the energy your supplier bills. | Aus Stromstärke und Spannung des Zählers berechnet, kann daher etwas über der Energie liegen, die dein Lieferant abrechnet. |
| Car %@, rest of the house %@ | Auto %@, Rest des Hauses %@ |
| Charge complete | Laden abgeschlossen |
| Charger Details | Ladegerät-Details |
| Charger Energy | Energie des Ladegeräts |
| Charger connection | Ladegerät-Verbindung |
| Charger measurement only | Nur Messung am Ladegerät |
| Charger restarted | Ladegerät neu gestartet |
| Charger updated %@ ago | Ladegerät vor %@ aktualisiert |
| Charger-measured home sessions against the house meter's readings from Perific, %@ to %@. Charging away from home never reaches that meter. | Vom Ladegerät gemessene Sitzungen zu Hause, im Vergleich zu den Zählerwerten des Hauses von Perific, %@ bis %@. Laden außer Haus erreicht diesen Zähler nie. |
| Charging at reduced power | Lädt mit reduzierter Leistung |
| Charging enabled | Laden aktiviert |
| Charging is enabled but the car is drawing no power | Laden ist aktiviert, aber das Fahrzeug zieht keinen Strom |
| Charging state | Ladestatus |
| Charging switch | Ladeschalter |
| Charging uses the lowest. The car and load balancing can ask for less. | Das Laden nutzt den niedrigsten Wert. Auto und Lastmanagement können weniger verlangen. |
| Checked %@ | Geprüft %@ |
| Circuit Blue | Rennbahnblau |
| Circuit Fuse | Stromkreissicherung |
| Connect and find chargers | Verbinden und Ladegeräte suchen |
| Connected through | Verbunden über |
| Copy custom_components/hisingen_home_charging into your Home Assistant config folder, add hisingen_home_charging: to configuration.yaml and restart. The Home Charging guide in the repository has the steps. | Kopiere custom_components/hisingen_home_charging in deinen Home-Assistant-Konfigurationsordner, füge hisingen_home_charging: zur configuration.yaml hinzu und starte neu. Die Schritte stehen im Home-Charging-Leitfaden im Repository. |
| Current per Phase | Stromstärke pro Phase |
| Disconnect Perific | Perific trennen |
| Emergency stop | Not-Aus |
| Entities | Entitäten |
| Exported Today | Heute exportiert |
| Held by load balancing | Vom Lastmanagement zurückgehalten |
| Hisingen is not signed in to %@ yet. | Hisingen ist noch nicht bei %@ angemeldet. |
| Home Assistant accepted the command. Waiting for the charger to confirm. | Home Assistant hat den Befehl angenommen. Warte auf die Bestätigung des Ladegeräts. |
| Home Assistant stops the plan and leaves the charger as it is. | Home Assistant stoppt den Plan und lässt das Ladegerät, wie es ist. |
| Home Charging | Laden zu Hause |
| Home charger | Ladegerät zu Hause |
| Home charging plan | Ladeplan für zu Hause |
| House %@ | Haus %@ |
| House Current per Phase | Hausstrom pro Phase |
| House Meter | Hauszähler |
| House Now | Haus aktuell |
| House Voltage | Hausspannung |
| House meter last read %@ ago | Hauszähler zuletzt vor %@ gelesen |
| House sending %@ to the grid | Haus sendet %@ ins Netz |
| Import sessions now | Sitzungen jetzt importieren |
| Imported Today | Heute importiert |
| Importing | Import läuft |
| Last update from %@ %@ | Letzte Aktualisierung von %@ %@ |
| Load balancing can limit the charger when the house uses more power. | Lastmanagement kann das Ladegerät drosseln, wenn das Haus mehr Strom braucht. |
| Load balancing is holding the charger. It continues when power is free. | Das Lastmanagement hält das Ladegerät zurück. Das Laden geht weiter, wenn wieder Leistung frei ist. |
| Map by hand | Von Hand zuordnen |
| Measured at the charger, so it includes charging losses. | Am Ladegerät gemessen, Ladeverluste sind also enthalten. |
| Measured from recent charger sessions. It updates when the car charges slower than planned. | Aus den letzten Ladesitzungen gemessen. Der Wert aktualisiert sich, wenn das Auto langsamer lädt als geplant. |
| Meter | Zähler |
| Metered by the charger and read from Home Assistant. Last charger reading %@. | Vom Ladegerät gemessen und aus Home Assistant gelesen. Letzte Messung des Ladegeräts %@. |
| Metered by the charger and read from the %@ cloud. Last charger reading %@. | Vom Ladegerät gemessen und aus der %@-Cloud gelesen. Letzte Messung des Ladegeräts %@. |
| Mobile data | Mobile Daten |
| Needed to keep charger sessions in Hisingen's local history. | Nötig, um Ladesitzungen in Hisingens lokaler Historie zu behalten. |
| NexBlue is delaying the start | NexBlue verzögert den Start |
| NexBlue is holding a delayed start | NexBlue hält einen verzögerten Start zurück |
| NexBlue is holding the start with a delayed start. | NexBlue hält den Start mit einem verzögerten Start zurück. |
| No NexBlue charger was found. Map the entities by hand below. | Kein NexBlue-Ladegerät gefunden. Ordne die Entitäten unten von Hand zu. |
| No charger is paired. | Es ist kein Ladegerät gekoppelt. |
| No charging switch is mapped for this charger. | Für dieses Ladegerät ist kein Ladeschalter zugeordnet. |
| No new reading arrived from the charger. | Vom Ladegerät kam keine neue Messung. |
| Not authorised | Nicht autorisiert |
| Not imported yet | Noch nicht importiert |
| Off: local charging history is disabled | Aus: lokale Ladehistorie ist deaktiviert |
| On plug-in | Beim Anstecken |
| Only the session total was available, so this is an estimate. | Es war nur der Gesamtwert der Sitzung verfügbar, das ist also eine Schätzung. |
| Optional. Connects a charger that Home Assistant manages, such as NexBlue, to show its status, control it, and record what it measured. | Optional. Verbindet ein Ladegerät, das Home Assistant verwaltet, etwa NexBlue, um Status anzuzeigen, es zu steuern und aufzuzeichnen, was es gemessen hat. |
| Optional. Connects a home charger to show its status, control it, and record what it measured. Easee and Zaptec sign in with their own account. Any other charger works through Home Assistant, such as NexBlue. | Optional. Verbindet ein Ladegerät zu Hause, um Status anzuzeigen, es zu steuern und aufzuzeichnen, was es gemessen hat. Easee und Zaptec melden sich mit ihrem eigenen Konto an. Jedes andere Ladegerät läuft über Home Assistant, etwa NexBlue. |
| Optional. Reads your home's electricity use from a Perific monitor, so charging can be shown against the whole house. Hisingen only reads it. Perific keeps balancing the charger. | Optional. Liest den Stromverbrauch deines Zuhauses von einem Perific-Messgerät, damit das Laden dem ganzen Haus gegenübergestellt werden kann. Hisingen liest nur. Perific übernimmt weiterhin das Lastmanagement des Ladegeräts. |
| Other cars also use this charger | Andere Autos nutzen dieses Ladegerät ebenfalls |
| Pair charger | Ladegerät koppeln |
| Perific account email | E-Mail-Adresse des Perific-Kontos |
| Perific did not accept the saved login. Enter the account and password again to reconnect. | Perific hat die gespeicherte Anmeldung nicht akzeptiert. Gib Konto und Passwort erneut ein, um die Verbindung wiederherzustellen. |
| Perific did not accept the saved login. Sign in again in Settings, Electricity. | Perific hat die gespeicherte Anmeldung nicht akzeptiert. Melde dich erneut an, unter Einstellungen, Strom. |
| Phase Mode | Phasenmodus |
| Plans run inside Home Assistant. This charger is connected directly, so it offers status, Charge now, Pause and history. | Pläne laufen in Home Assistant. Dieses Ladegerät ist direkt verbunden und bietet daher Status, Jetzt laden, Pause und Historie. |
| Power loss | Stromausfall |
| Price source: %@. | Preisquelle: %@. |
| Priced per 15-minute interval from the charger's own readings. | Preis pro 15-Minuten-Intervall aus den eigenen Messwerten des Ladegeräts. |
| Reading chargers… | Ladegeräte werden gelesen… |
| Reading every 30 seconds | Ablesung alle 30 Sekunden |
| Remotely | Ferngesteuert |
| Reported %@ | Gemeldet %@ |
| Resume | Fortsetzen |
| Sending the pause command to %@ | Pause-Befehl wird an %@ gesendet |
| Sending the start command to %@ | Start-Befehl wird an %@ gesendet |
| Session history | Sitzungsverlauf |
| Sessions and plans are tied to this vehicle only. A car being near the charger is not enough. | Sitzungen und Pläne gelten nur für dieses Fahrzeug. Dass ein Auto in der Nähe des Ladegeräts steht, genügt nicht. |
| Sessions are tied to this vehicle only. A car being near the charger is not enough. | Sitzungen gelten nur für dieses Fahrzeug. Dass ein Auto in der Nähe des Ladegeräts steht, genügt nicht. |
| Shared charger | Geteiltes Ladegerät |
| Sign in | Anmelden |
| Sign in again in Settings. | Melde dich erneut in den Einstellungen an. |
| Sign in and find chargers | Anmelden und Ladegeräte suchen |
| Sign in and find meters | Anmelden und Zähler suchen |
| Sign in to %@ again | Erneut bei %@ anmelden |
| Sign out | Abmelden |
| Sign-in refused | Anmeldung verweigert |
| Sign-in rejected | Anmeldung abgelehnt |
| Signed in to %@ | Bei %@ angemeldet |
| Signing in… | Anmeldung läuft… |
| Single phase | Einphasig |
| Source | Quelle |
| Still needed: %@. | Noch nötig: %@. |
| The account or password was not accepted. | Konto oder Passwort wurde nicht akzeptiert. |
| The account you use in the Perific app. It is stored in the macOS Keychain and never exported. | Das Konto, das du in der Perific-App verwendest. Es wird im macOS-Schlüsselbund gespeichert und nie exportiert. |
| The cable allows %@. | Das Kabel erlaubt %@. |
| The charger command was rejected | Der Befehl an das Ladegerät wurde abgelehnt |
| The charger did not confirm the last command. | Das Ladegerät hat den letzten Befehl nicht bestätigt. |
| The charger has not confirmed the command | Das Ladegerät hat den Befehl nicht bestätigt |
| The charger has not reported recently | Das Ladegerät hat sich zuletzt nicht gemeldet |
| The charger is unavailable in %@ | Das Ladegerät ist in %@ nicht verfügbar |
| The charger is unavailable in Home Assistant | Das Ladegerät ist in Home Assistant nicht verfügbar |
| The charger is unavailable in Home Assistant. | Das Ladegerät ist in Home Assistant nicht verfügbar. |
| The charger kept its previous state. Try again, or check the charger. | Das Ladegerät behielt seinen vorherigen Zustand. Versuche es erneut oder prüfe das Ladegerät. |
| The charger readings below are the last ones received. | Die Werte unten sind die zuletzt empfangenen Messungen des Ladegeräts. |
| The charger recorded this session while no battery reading was available, so there is no battery-side estimate. | Das Ladegerät hat diese Sitzung aufgezeichnet, während kein Batteriewert vorlag, daher gibt es keine Schätzung auf Batterieseite. |
| The charger reported an error after the command. | Das Ladegerät hat nach dem Befehl einen Fehler gemeldet. |
| The charger reports about once a minute. | Das Ladegerät meldet sich etwa einmal pro Minute. |
| The charger reports an error | Das Ladegerät meldet einen Fehler |
| The charger service asked Hisingen to slow down. It will try again shortly. | Der Ladegerätdienst hat Hisingen gebeten, es etwas langsamer anzugehen. Ein neuer Versuch folgt in Kürze. |
| The charger service could not be reached. | Der Ladegerätdienst ist nicht erreichbar. |
| The charger service does not know that item. | Der Ladegerätdienst kennt dieses Element nicht. |
| The charger service refused the request. | Der Ladegerätdienst hat die Anfrage abgelehnt. |
| The charger service sent an answer Hisingen could not read. | Der Ladegerätdienst hat eine Antwort gesendet, die Hisingen nicht lesen konnte. |
| The circuit fuse is %@. | Die Stromkreissicherung ist %@. |
| The limit is set to %@. | Das Limit steht auf %@. |
| The meter sent no voltage, so 230 V is assumed and power is approximate. | Der Zähler hat keine Spannung gesendet, daher werden 230 V angenommen und die Leistung ist nur ungefähr. |
| The one you use in the %@ app. It is stored in the macOS Keychain and never exported. | Das Konto, das du in der %@-App verwendest. Es wird im macOS-Schlüsselbund gespeichert und nie exportiert. |
| The saved location in the car where this charger stands. | Der gespeicherte Ort im Auto, an dem dieses Ladegerät steht. |
| The saved token and the charger pairing are deleted. Charging history that was already recorded stays. | Das gespeicherte Token und die Kopplung des Ladegeräts werden gelöscht. Bereits aufgezeichnete Ladehistorie bleibt erhalten. |
| This Home Assistant automation uses the charger and may start or stop it. | Diese Home-Assistant-Automatisierung nutzt das Ladegerät und kann es starten oder stoppen. |
| This account has no charger that Hisingen can control. Check that it is the owner account in the %@ app. | Dieses Konto hat kein Ladegerät, das Hisingen steuern kann. Prüfe, dass es das Eigentümer-Konto in der %@-App ist. |
| This account has no meter that Hisingen can read. Check that it is the owner account in the Perific app. | Dieses Konto hat keinen Zähler, den Hisingen lesen kann. Prüfe, dass es das Eigentümer-Konto in der Perific-App ist. |
| This account may not control that charger. | Dieses Konto darf dieses Ladegerät möglicherweise nicht steuern. |
| This account no longer lists the meter | Dieses Konto führt den Zähler nicht mehr |
| This token could not read the device list, so chargers were found by their entity names. An administrator token also finds the serial number. | Dieses Token konnte die Geräteliste nicht lesen, daher wurden Ladegeräte über ihre Entitätsnamen gefunden. Ein Administrator-Token findet auch die Seriennummer. |
| Three phase | Dreiphasig |
| Tibber's price includes energy, taxes and its markup but not the grid fee. Add yours here; a paired charger can set its own. | Tibbers Preis enthält Energie, Steuern und die eigene Marge, aber nicht die Netznutzungsgebühr. Trage deine hier ein; ein gekoppeltes Ladegerät kann eine eigene hinterlegen. |
| Unpair charger | Ladegerät entkoppeln |
| Use this meter | Diesen Zähler verwenden |

### Flagged for this language

- Register: informal du throughout, matching the existing file.
- "Rennbahnblau" is a coined theme name for Circuit Blue, matching "Meisterschaftsblau" in its subtitle.
- "Stromkreissicherung" for Circuit Fuse; an electrician might say "Leitungsschutzschalter" for the breaker, but this is the fuse value.
- Today's block (earlier agent) reads well; "Zuletzt geändert: %@" uses a colon where English does not.

## es

Confidence: High confidence; tú-register matches the file. Load-balancing and power-loss terms deserve a check.


### Today's morning additions (verify as shipped)

| English source | Shipped value |
| --- | --- |
| Volvo moved to a new sign-in system. Sign in again to keep your vehicle data. | Volvo ha pasado a un nuevo sistema de inicio de sesión. Inicia sesión de nuevo para conservar los datos de tu vehículo. |
| Drive Type | Tipo de tracción |
| Engine Power | Potencia del motor |
| Gross Weight | Peso bruto |
| Seats | Asientos |
| Last changed %@ | Último cambio %@ |
| %d kW | %d kW |
| %d kg | %d kg |

### Strings translated today (168 keys)

| English source | Shipped value |
| --- | --- |
| %@ accepted the command. Waiting for the charger to confirm. | %@ ha aceptado la orden. Esperando la confirmación del cargador. |
| %@ did not accept the saved login | %@ no ha aceptado el inicio de sesión guardado |
| %@ did not accept the saved login. Enter the account and password again to reconnect. | %@ no ha aceptado el inicio de sesión guardado. Introduce de nuevo la cuenta y la contraseña para reconectar. |
| %@ from charger | %@ del cargador |
| %@ is delaying the start | %@ está retrasando el inicio |
| %@ is unreachable | %@ es inaccesible |
| %@ per phase | %@ por fase |
| %@ per phase, limit %@ | %@ por fase, límite %@ |
| %@ to the grid | %@ a la red |
| %@, limited by the cable | %@, limitado por el cable |
| %@, limited by the circuit fuse | %@, limitado por el fusible del circuito |
| %d charger sessions could not be tied to a vehicle and are kept unassigned. | %d sesiones del cargador no se han podido vincular a un vehículo y se guardan sin asignar. |
| A charger schedule or EcoPilot is active. Turn it off in the NexBlue app so Home Assistant controls the start. | Hay una programación del cargador o EcoPilot activa. Desactívala en la app de NexBlue para que Home Assistant controle el inicio. |
| A charging schedule is active on the charger. | Hay una programación de carga activa en el cargador. |
| A delayed start or EcoPilot is active on the charger. | Hay un inicio retardado o EcoPilot activo en el cargador. |
| A shared charger only records a session for this vehicle when the car's own charging overlaps it. | Un cargador compartido solo registra una sesión para este vehículo cuando la carga propia del coche la solapa. |
| Account email | Correo electrónico de la cuenta |
| Adaptive | Adaptativo |
| Added to Tibber prices in the planner and for charger sessions. | Se añade a los precios de Tibber en el planificador y en las sesiones del cargador. |
| After an error | Tras un error |
| At the charger | En el cargador |
| By an administrator | Por un administrador |
| By schedule | Por programación |
| Cable Rating | Capacidad del cable |
| Cable lock | Bloqueo del cable |
| Cable unlocked | Cable desbloqueado |
| Cable unplugged | Cable desconectado |
| Calculated from the meter's current and voltage, so it can read slightly above the energy your supplier bills. | Calculado a partir de la corriente y el voltaje del contador, por lo que puede quedar algo por encima de la energía que factura tu comercializadora. |
| Car %@, rest of the house %@ | Coche %@, resto de la casa %@ |
| Charge complete | Carga completada |
| Charger Details | Detalles del cargador |
| Charger Energy | Energía del cargador |
| Charger connection | Conexión del cargador |
| Charger measurement only | Solo medición del cargador |
| Charger restarted | Cargador reiniciado |
| Charger updated %@ ago | Cargador actualizado hace %@ |
| Charger-measured home sessions against the house meter's readings from Perific, %@ to %@. Charging away from home never reaches that meter. | Sesiones en casa medidas por el cargador frente a las lecturas del contador de la casa de Perific, %@ a %@. Cargar fuera de casa nunca llega a ese contador. |
| Charging at reduced power | Cargando a potencia reducida |
| Charging enabled | Carga activada |
| Charging is enabled but the car is drawing no power | La carga está activada, pero el coche no toma corriente |
| Charging state | Estado de carga |
| Charging switch | Interruptor de carga |
| Charging uses the lowest. The car and load balancing can ask for less. | La carga usa el valor más bajo. El coche y el equilibrado de carga pueden pedir menos. |
| Checked %@ | Comprobado %@ |
| Circuit Blue | Azul de circuito |
| Circuit Fuse | Fusible del circuito |
| Connect and find chargers | Conectar y buscar cargadores |
| Connected through | Conectado a través de |
| Copy custom_components/hisingen_home_charging into your Home Assistant config folder, add hisingen_home_charging: to configuration.yaml and restart. The Home Charging guide in the repository has the steps. | Copia custom_components/hisingen_home_charging en la carpeta de configuración de Home Assistant, añade hisingen_home_charging: a configuration.yaml y reinicia. La guía Home Charging del repositorio tiene los pasos. |
| Current per Phase | Corriente por fase |
| Disconnect Perific | Desconectar Perific |
| Emergency stop | Parada de emergencia |
| Entities | Entidades |
| Exported Today | Exportado hoy |
| Held by load balancing | Retenido por el equilibrado de carga |
| Hisingen is not signed in to %@ yet. | Hisingen aún no ha iniciado sesión en %@. |
| Home Assistant accepted the command. Waiting for the charger to confirm. | Home Assistant ha aceptado la orden. Esperando la confirmación del cargador. |
| Home Assistant stops the plan and leaves the charger as it is. | Home Assistant detiene el plan y deja el cargador como está. |
| Home Charging | Carga doméstica |
| Home charger | Cargador doméstico |
| Home charging plan | Plan de carga doméstica |
| House %@ | Casa %@ |
| House Current per Phase | Corriente de la casa por fase |
| House Meter | Contador de la casa |
| House Now | Casa ahora |
| House Voltage | Voltaje de la casa |
| House meter last read %@ ago | Contador de la casa leído por última vez hace %@ |
| House sending %@ to the grid | La casa envía %@ a la red |
| Import sessions now | Importar sesiones ahora |
| Imported Today | Importado hoy |
| Importing | Importando |
| Last update from %@ %@ | Última actualización de %@ %@ |
| Load balancing can limit the charger when the house uses more power. | El equilibrado de carga puede limitar el cargador cuando la casa consume más potencia. |
| Load balancing is holding the charger. It continues when power is free. | El equilibrado de carga está reteniendo el cargador. La carga continúa cuando hay potencia libre. |
| Map by hand | Asignar manualmente |
| Measured at the charger, so it includes charging losses. | Medido en el cargador, por lo que incluye las pérdidas de carga. |
| Measured from recent charger sessions. It updates when the car charges slower than planned. | Calculado a partir de sesiones recientes del cargador. Se actualiza cuando el coche carga más despacio de lo previsto. |
| Meter | Contador |
| Metered by the charger and read from Home Assistant. Last charger reading %@. | Medido por el cargador y leído de Home Assistant. Última lectura del cargador %@. |
| Metered by the charger and read from the %@ cloud. Last charger reading %@. | Medido por el cargador y leído de la nube de %@. Última lectura del cargador %@. |
| Mobile data | Datos móviles |
| Needed to keep charger sessions in Hisingen's local history. | Necesario para conservar las sesiones del cargador en el historial local de Hisingen. |
| NexBlue is delaying the start | NexBlue está retrasando el inicio |
| NexBlue is holding a delayed start | NexBlue está reteniendo un inicio retardado |
| NexBlue is holding the start with a delayed start. | NexBlue está reteniendo el inicio con un inicio retardado. |
| No NexBlue charger was found. Map the entities by hand below. | No se ha encontrado ningún cargador NexBlue. Asigna las entidades manualmente abajo. |
| No charger is paired. | No hay ningún cargador vinculado. |
| No charging switch is mapped for this charger. | No hay ningún interruptor de carga asignado a este cargador. |
| No new reading arrived from the charger. | No ha llegado ninguna lectura nueva del cargador. |
| Not authorised | No autorizado |
| Not imported yet | Aún sin importar |
| Off: local charging history is disabled | Desactivado: el historial local de cargas está desactivado |
| On plug-in | Al conectar |
| Only the session total was available, so this is an estimate. | Solo estaba disponible el total de la sesión, así que esto es una estimación. |
| Optional. Connects a charger that Home Assistant manages, such as NexBlue, to show its status, control it, and record what it measured. | Opcional. Conecta un cargador gestionado por Home Assistant, como NexBlue, para mostrar su estado, controlarlo y registrar lo que ha medido. |
| Optional. Connects a home charger to show its status, control it, and record what it measured. Easee and Zaptec sign in with their own account. Any other charger works through Home Assistant, such as NexBlue. | Opcional. Conecta un cargador doméstico para mostrar su estado, controlarlo y registrar lo que ha medido. Easee y Zaptec inician sesión con su propia cuenta. Cualquier otro cargador funciona a través de Home Assistant, como NexBlue. |
| Optional. Reads your home's electricity use from a Perific monitor, so charging can be shown against the whole house. Hisingen only reads it. Perific keeps balancing the charger. | Opcional. Lee el consumo eléctrico de tu casa desde un monitor Perific, para poder mostrar la carga frente al conjunto de la casa. Hisingen solo lee. Perific sigue equilibrando el cargador. |
| Other cars also use this charger | Otros coches también usan este cargador |
| Pair charger | Vincular cargador |
| Perific account email | Correo electrónico de la cuenta de Perific |
| Perific did not accept the saved login. Enter the account and password again to reconnect. | Perific no ha aceptado el inicio de sesión guardado. Introduce de nuevo la cuenta y la contraseña para reconectar. |
| Perific did not accept the saved login. Sign in again in Settings, Electricity. | Perific no ha aceptado el inicio de sesión guardado. Inicia sesión de nuevo en Ajustes, Electricidad. |
| Phase Mode | Modo de fases |
| Plans run inside Home Assistant. This charger is connected directly, so it offers status, Charge now, Pause and history. | Los planes se ejecutan dentro de Home Assistant. Este cargador está conectado directamente, así que ofrece estado, Cargar ahora, Pausa e historial. |
| Power loss | Corte de alimentación |
| Price source: %@. | Fuente del precio: %@. |
| Priced per 15-minute interval from the charger's own readings. | Precio por intervalos de 15 minutos según las propias lecturas del cargador. |
| Reading chargers… | Leyendo cargadores… |
| Reading every 30 seconds | Lectura cada 30 segundos |
| Remotely | Remotamente |
| Reported %@ | Notificado %@ |
| Resume | Reanudar |
| Sending the pause command to %@ | Enviando la orden de pausa a %@ |
| Sending the start command to %@ | Enviando la orden de inicio a %@ |
| Session history | Historial de sesiones |
| Sessions and plans are tied to this vehicle only. A car being near the charger is not enough. | Las sesiones y los planes se vinculan solo a este vehículo. Que un coche esté cerca del cargador no basta. |
| Sessions are tied to this vehicle only. A car being near the charger is not enough. | Las sesiones se vinculan solo a este vehículo. Que un coche esté cerca del cargador no basta. |
| Shared charger | Cargador compartido |
| Sign in | Iniciar sesión |
| Sign in again in Settings. | Inicia sesión de nuevo en Ajustes. |
| Sign in and find chargers | Iniciar sesión y buscar cargadores |
| Sign in and find meters | Iniciar sesión y buscar contadores |
| Sign in to %@ again | Inicia sesión de nuevo en %@ |
| Sign out | Cerrar sesión |
| Sign-in refused | Inicio de sesión denegado |
| Sign-in rejected | Inicio de sesión rechazado |
| Signed in to %@ | Sesión iniciada en %@ |
| Signing in… | Iniciando sesión… |
| Single phase | Monofásico |
| Source | Fuente |
| Still needed: %@. | Falta todavía: %@. |
| The account or password was not accepted. | No se ha aceptado la cuenta o la contraseña. |
| The account you use in the Perific app. It is stored in the macOS Keychain and never exported. | La cuenta que usas en la app de Perific. Se guarda en el Llavero de macOS y nunca se exporta. |
| The cable allows %@. | El cable admite %@. |
| The charger command was rejected | La orden al cargador fue rechazada |
| The charger did not confirm the last command. | El cargador no ha confirmado la última orden. |
| The charger has not confirmed the command | El cargador no ha confirmado la orden |
| The charger has not reported recently | El cargador no ha informado recientemente |
| The charger is unavailable in %@ | El cargador no está disponible en %@ |
| The charger is unavailable in Home Assistant | El cargador no está disponible en Home Assistant |
| The charger is unavailable in Home Assistant. | El cargador no está disponible en Home Assistant. |
| The charger kept its previous state. Try again, or check the charger. | El cargador ha mantenido su estado anterior. Inténtalo de nuevo o revisa el cargador. |
| The charger readings below are the last ones received. | Las lecturas de abajo son las últimas recibidas del cargador. |
| The charger recorded this session while no battery reading was available, so there is no battery-side estimate. | El cargador registró esta sesión cuando no había ninguna lectura de batería, así que no hay estimación por el lado de la batería. |
| The charger reported an error after the command. | El cargador ha informado de un error después de la orden. |
| The charger reports about once a minute. | El cargador informa aproximadamente una vez por minuto. |
| The charger reports an error | El cargador informa de un error |
| The charger service asked Hisingen to slow down. It will try again shortly. | El servicio del cargador ha pedido a Hisingen que vaya más despacio. Lo intentará de nuevo en breve. |
| The charger service could not be reached. | No se ha podido contactar con el servicio del cargador. |
| The charger service does not know that item. | El servicio del cargador no conoce ese elemento. |
| The charger service refused the request. | El servicio del cargador ha rechazado la solicitud. |
| The charger service sent an answer Hisingen could not read. | El servicio del cargador ha enviado una respuesta que Hisingen no ha podido leer. |
| The circuit fuse is %@. | El fusible del circuito es %@. |
| The limit is set to %@. | El límite está fijado en %@. |
| The meter sent no voltage, so 230 V is assumed and power is approximate. | El contador no envió voltaje, así que se asumen 230 V y la potencia es aproximada. |
| The one you use in the %@ app. It is stored in the macOS Keychain and never exported. | La que usas en la app de %@. Se guarda en el Llavero de macOS y nunca se exporta. |
| The saved location in the car where this charger stands. | La ubicación guardada en el coche donde está este cargador. |
| The saved token and the charger pairing are deleted. Charging history that was already recorded stays. | Se eliminan el token guardado y la vinculación del cargador. El historial de cargas ya registrado se conserva. |
| This Home Assistant automation uses the charger and may start or stop it. | Esta automatización de Home Assistant usa el cargador y puede iniciarlo o detenerlo. |
| This account has no charger that Hisingen can control. Check that it is the owner account in the %@ app. | Esta cuenta no tiene ningún cargador que Hisingen pueda controlar. Comprueba que sea la cuenta propietaria en la app de %@. |
| This account has no meter that Hisingen can read. Check that it is the owner account in the Perific app. | Esta cuenta no tiene ningún contador que Hisingen pueda leer. Comprueba que sea la cuenta propietaria en la app de Perific. |
| This account may not control that charger. | Puede que esta cuenta no tenga permiso para controlar ese cargador. |
| This account no longer lists the meter | Esta cuenta ya no muestra el contador |
| This token could not read the device list, so chargers were found by their entity names. An administrator token also finds the serial number. | Este token no ha podido leer la lista de dispositivos, así que los cargadores se han encontrado por sus nombres de entidad. Un token de administrador también encuentra el número de serie. |
| Three phase | Trifásico |
| Tibber's price includes energy, taxes and its markup but not the grid fee. Add yours here; a paired charger can set its own. | El precio de Tibber incluye energía, impuestos y su margen, pero no el peaje de red. Añade el tuyo aquí; un cargador vinculado puede fijar el suyo. |
| Unpair charger | Desvincular cargador |
| Use this meter | Usar este contador |

### Flagged for this language

- Register: informal tú throughout, matching the existing file.
- "Azul de circuito" for Circuit Blue, matching "Azul de campeonato" in its subtitle.
- "El equilibrado de carga" for load balancing; also common is "gestión de carga". Confirm the term the target audience knows.
- "Corte de alimentación" for Power loss; in Spain "corte de suministro" may be more usual.

## fi

Confidence: Good confidence in grammar; Finnish compounds for EV terms (kuormanhallinta, nimellisvirta) need a native pass.

- Fixed today's earlier draft: "Kirjaudu uudelleen sisään" became "Kirjaudu sisään uudelleen" (natural verb-particle order).

### Today's morning additions (verify as shipped)

| English source | Shipped value |
| --- | --- |
| Volvo moved to a new sign-in system. Sign in again to keep your vehicle data. | Volvo siirtyi uuteen kirjautumisjärjestelmään. Kirjaudu sisään uudelleen, jotta ajoneuvosi tiedot säilyvät. |
| Drive Type | Vetotyyppi |
| Engine Power | Moottorin teho |
| Gross Weight | Kokonaismassa |
| Seats | Istuimet |
| Last changed %@ | Viimeksi muutettu %@ |
| %d kW | %d kW |
| %d kg | %d kg |

### Strings translated today (168 keys)

| English source | Shipped value |
| --- | --- |
| %@ accepted the command. Waiting for the charger to confirm. | %@ hyväksyi komennon. Odotetaan laturin vahvistusta. |
| %@ did not accept the saved login | %@ ei hyväksynyt tallennettua kirjautumista |
| %@ did not accept the saved login. Enter the account and password again to reconnect. | %@ ei hyväksynyt tallennettua kirjautumista. Syötä tili ja salasana uudelleen muodostaaksesi yhteyden. |
| %@ from charger | %@ laturilta |
| %@ is delaying the start | %@ viivästyttää aloitusta |
| %@ is unreachable | %@ ei ole tavoitettavissa |
| %@ per phase | %@ per vaihe |
| %@ per phase, limit %@ | %@ per vaihe, raja %@ |
| %@ to the grid | %@ verkkoon |
| %@, limited by the cable | %@, kaapelin rajoittama |
| %@, limited by the circuit fuse | %@, piirin sulakkeen rajoittama |
| %d charger sessions could not be tied to a vehicle and are kept unassigned. | %d laturi-istuntoa ei voitu yhdistää ajoneuvoon, ja ne säilytetään yhdistämättöminä. |
| A charger schedule or EcoPilot is active. Turn it off in the NexBlue app so Home Assistant controls the start. | Laturissa on aktiivinen latausaikataulu tai EcoPilot. Sammuta se NexBlue-sovelluksesta, jotta Home Assistant ohjaa aloitusta. |
| A charging schedule is active on the charger. | Laturissa on aktiivinen latausaikataulu. |
| A delayed start or EcoPilot is active on the charger. | Laturissa on aktiivinen viivästetty aloitus tai EcoPilot. |
| A shared charger only records a session for this vehicle when the car's own charging overlaps it. | Jaettu laturi tallentaa istunnon tälle ajoneuvolle vain, jos auton oma lataus osuu siihen päällekkäin. |
| Account email | Tilin sähköpostiosoite |
| Adaptive | Adaptiivinen |
| Added to Tibber prices in the planner and for charger sessions. | Lisätään Tibberin hintoihin suunnittelussa ja laturi-istuntojen hinnoittelussa. |
| After an error | Virheen jälkeen |
| At the charger | Laturilla |
| By an administrator | Ylläpitäjän toimesta |
| By schedule | Aikataulun mukaan |
| Cable Rating | Kaapelin nimellisvirta |
| Cable lock | Kaapelin lukitus |
| Cable unlocked | Kaapelin lukitus auki |
| Cable unplugged | Kaapeli irrotettu |
| Calculated from the meter's current and voltage, so it can read slightly above the energy your supplier bills. | Laskettu mittarin virran ja jännitteen perusteella, joten se voi olla hieman suurempi kuin toimittajan laskuttama energia. |
| Car %@, rest of the house %@ | Auto %@, muu talon kulutus %@ |
| Charge complete | Lataus valmis |
| Charger Details | Laturin tiedot |
| Charger Energy | Laturin energia |
| Charger connection | Laturin yhteys |
| Charger measurement only | Vain laturin mittaus |
| Charger restarted | Laturi käynnistetty uudelleen |
| Charger updated %@ ago | Laturi päivitetty %@ sitten |
| Charger-measured home sessions against the house meter's readings from Perific, %@ to %@. Charging away from home never reaches that meter. | Laturin mittaamat kotilatausistunnot verrattuna Perificin talon sähkömittarin lukemiin, %@–%@. Kodin ulkopuolinen lataus ei koskaan päädy siihen mittariin. |
| Charging at reduced power | Lataa pienemmällä teholla |
| Charging enabled | Lataus käytössä |
| Charging is enabled but the car is drawing no power | Lataus on käytössä, mutta auto ei ota virtaa |
| Charging state | Latauksen tila |
| Charging switch | Latauskytkin |
| Charging uses the lowest. The car and load balancing can ask for less. | Lataus käyttää matalinta. Auto ja kuormanhallinta voivat pyytää vähemmän. |
| Checked %@ | Tarkistettu %@ |
| Circuit Blue | Ratasininen |
| Circuit Fuse | Piirin sulake |
| Connect and find chargers | Yhdistä ja etsi latureita |
| Connected through | Yhdistetty |
| Copy custom_components/hisingen_home_charging into your Home Assistant config folder, add hisingen_home_charging: to configuration.yaml and restart. The Home Charging guide in the repository has the steps. | Kopioi custom_components/hisingen_home_charging Home Assistantin asetuskansioon, lisää hisingen_home_charging: configuration.yaml-tiedostoon ja käynnistä uudelleen. Ohjeet ovat repositorion Home Charging -oppaassa. |
| Current per Phase | Virta per vaihe |
| Disconnect Perific | Katkaise Perific-yhteys |
| Emergency stop | Hätäpysäytys |
| Entities | Entiteetit |
| Exported Today | Viety tänään |
| Held by load balancing | Pidossa kuormanhallinnan vuoksi |
| Hisingen is not signed in to %@ yet. | Hisingen ei ole vielä kirjautunut palveluun %@. |
| Home Assistant accepted the command. Waiting for the charger to confirm. | Home Assistant hyväksyi komennon. Odotetaan laturin vahvistusta. |
| Home Assistant stops the plan and leaves the charger as it is. | Home Assistant pysäyttää suunnitelman ja jättää laturin ennalleen. |
| Home Charging | Kotilataus |
| Home charger | Kotilaturi |
| Home charging plan | Kotilataussuunnitelma |
| House %@ | Talo %@ |
| House Current per Phase | Talon virta vaihetta kohti |
| House Meter | Talon sähkömittari |
| House Now | Talo nyt |
| House Voltage | Talon jännite |
| House meter last read %@ ago | Talon sähkömittarin viimeisin luku %@ sitten |
| House sending %@ to the grid | Talo syöttää %@ verkkoon |
| Import sessions now | Tuo istunnot nyt |
| Imported Today | Tuotu tänään |
| Importing | Tuodaan |
| Last update from %@ %@ | Viimeisin päivitys palvelusta %@ %@ |
| Load balancing can limit the charger when the house uses more power. | Kuormanhallinta voi rajoittaa laturia, kun talo käyttää enemmän tehoa. |
| Load balancing is holding the charger. It continues when power is free. | Kuormanhallinta pitää laturin paikallaan. Lataus jatkuu, kun tehoa on vapaana. |
| Map by hand | Yhdistä käsin |
| Measured at the charger, so it includes charging losses. | Mitattu laturilla, joten se sisältää lataushäviöt. |
| Measured from recent charger sessions. It updates when the car charges slower than planned. | Laskettu viimeaikaisten laturi-istuntojen perusteella. Päivittyy, kun auto lataa suunniteltua hitaammin. |
| Meter | Mittari |
| Metered by the charger and read from Home Assistant. Last charger reading %@. | Laturin mittaama ja Home Assistantista luettu. Laturin viimeisin lukema %@. |
| Metered by the charger and read from the %@ cloud. Last charger reading %@. | Laturin mittaama ja %@-pilvestä luettu. Laturin viimeisin lukema %@. |
| Mobile data | Mobiilidata |
| Needed to keep charger sessions in Hisingen's local history. | Tarvitaan laturi-istuntojen säilyttämiseen Hisingenin paikallisessa historiassa. |
| NexBlue is delaying the start | NexBlue viivästyttää aloitusta |
| NexBlue is holding a delayed start | NexBlue pitää viivästettyä aloitusta |
| NexBlue is holding the start with a delayed start. | NexBlue pitää aloituksen viivästettynä. |
| No NexBlue charger was found. Map the entities by hand below. | NexBlue-laturia ei löytynyt. Yhdistä entiteetit alla käsin. |
| No charger is paired. | Yhtään laturia ei ole yhdistetty. |
| No charging switch is mapped for this charger. | Tälle laturille ei ole määritetty latauskytkintä. |
| No new reading arrived from the charger. | Laturista ei tullut uutta lukemaa. |
| Not authorised | Ei käyttöoikeutta |
| Not imported yet | Ei vielä tuotu |
| Off: local charging history is disabled | Pois: paikallinen lataushistoria on poistettu käytöstä |
| On plug-in | Kytkeytyessä |
| Only the session total was available, so this is an estimate. | Vain istunnon kokonaisarvo oli käytettävissä, joten tämä on arvio. |
| Optional. Connects a charger that Home Assistant manages, such as NexBlue, to show its status, control it, and record what it measured. | Valinnainen. Yhdistää Home Assistantin hallinnoiman laturin, kuten NexBluen, näyttämään sen tilan, ohjaamaan sitä ja tallentamaan sen mittaamat tiedot. |
| Optional. Connects a home charger to show its status, control it, and record what it measured. Easee and Zaptec sign in with their own account. Any other charger works through Home Assistant, such as NexBlue. | Valinnainen. Yhdistää kotilaturin näyttämään sen tilan, ohjaamaan sitä ja tallentamaan sen mittaamat tiedot. Easee ja Zaptec kirjautuvat omilla tileillään. Mikä tahansa muu laturi toimii Home Assistantin kautta, kuten NexBlue. |
| Optional. Reads your home's electricity use from a Perific monitor, so charging can be shown against the whole house. Hisingen only reads it. Perific keeps balancing the charger. | Valinnainen. Lukee kodin sähkönkulutuksen Perific-mittarista, jotta latauksen voi näyttää koko talon kulutusta vasten. Hisingen vain lukee sen. Perific jatkaa laturin kuormanhallintaa. |
| Other cars also use this charger | Muutkin autot käyttävät tätä laturia |
| Pair charger | Yhdistä laturi |
| Perific account email | Perific-tilin sähköpostiosoite |
| Perific did not accept the saved login. Enter the account and password again to reconnect. | Perific ei hyväksynyt tallennettua kirjautumista. Syötä tili ja salasana uudelleen muodostaaksesi yhteyden. |
| Perific did not accept the saved login. Sign in again in Settings, Electricity. | Perific ei hyväksynyt tallennettua kirjautumista. Kirjaudu uudelleen kohdasta Asetukset, Sähkö. |
| Phase Mode | Vaihetila |
| Plans run inside Home Assistant. This charger is connected directly, so it offers status, Charge now, Pause and history. | Suunnitelmat toimivat Home Assistantin sisällä. Tämä laturi on yhdistetty suoraan, joten se tarjoaa tilan, Lataa nyt, Keskeytä ja historian. |
| Power loss | Sähkökatko |
| Price source: %@. | Hinnan lähde: %@. |
| Priced per 15-minute interval from the charger's own readings. | Hinnoiteltu 15 minuutin välein laturin omien lukemien perusteella. |
| Reading chargers… | Luetaan latureita… |
| Reading every 30 seconds | Luku 30 sekunnin välein |
| Remotely | Etänä |
| Reported %@ | Raportoitu %@ |
| Resume | Jatka |
| Sending the pause command to %@ | Lähetetään pysäytyskomentoa palvelulle %@ |
| Sending the start command to %@ | Lähetetään käynnistyskomentoa palvelulle %@ |
| Session history | Istuntohistoria |
| Sessions and plans are tied to this vehicle only. A car being near the charger is not enough. | Istunnot ja suunnitelmat liittyvät vain tähän ajoneuvoon. Se, että auto on laturin lähellä, ei riitä. |
| Sessions are tied to this vehicle only. A car being near the charger is not enough. | Istunnot liittyvät vain tähän ajoneuvoon. Se, että auto on laturin lähellä, ei riitä. |
| Shared charger | Jaettu laturi |
| Sign in | Kirjaudu sisään |
| Sign in again in Settings. | Kirjaudu sisään uudelleen asetuksista. |
| Sign in and find chargers | Kirjaudu sisään ja etsi latureita |
| Sign in and find meters | Kirjaudu sisään ja etsi mittareita |
| Sign in to %@ again | Kirjaudu uudelleen palveluun %@ |
| Sign out | Kirjaudu ulos |
| Sign-in refused | Sisäänkirjautuminen evättiin |
| Sign-in rejected | Sisäänkirjautuminen hylättiin |
| Signed in to %@ | Kirjautunut palveluun %@ |
| Signing in… | Kirjaudutaan sisään… |
| Single phase | Yksivaiheinen |
| Source | Lähde |
| Still needed: %@. | Puuttuu vielä: %@. |
| The account or password was not accepted. | Tiliä tai salasanaa ei hyväksytty. |
| The account you use in the Perific app. It is stored in the macOS Keychain and never exported. | Tili, jota käytät Perific-sovelluksessa. Se tallennetaan macOS-avainnippuun eikä sitä koskaan viedä muualle. |
| The cable allows %@. | Kaapeli sallii %@. |
| The charger command was rejected | Laturikomento hylättiin |
| The charger did not confirm the last command. | Laturi ei vahvistanut viimeisintä komentoa. |
| The charger has not confirmed the command | Laturi ei ole vahvistanut komentoa |
| The charger has not reported recently | Laturi ei ole raportoinut äskettäin |
| The charger is unavailable in %@ | Laturi ei ole käytettävissä palvelussa %@ |
| The charger is unavailable in Home Assistant | Laturi ei ole käytettävissä Home Assistantissa |
| The charger is unavailable in Home Assistant. | Laturi ei ole käytettävissä Home Assistantissa. |
| The charger kept its previous state. Try again, or check the charger. | Laturi säilytti aiemman tilansa. Yritä uudelleen tai tarkista laturi. |
| The charger readings below are the last ones received. | Alla olevat lukemat ovat viimeisimmät laturista saadut. |
| The charger recorded this session while no battery reading was available, so there is no battery-side estimate. | Laturi tallensi tämän istunnon, kun akun lukemaa ei ollut käytettävissä, joten akkupuolen arviota ei ole. |
| The charger reported an error after the command. | Laturi raportoi virheen komennon jälkeen. |
| The charger reports about once a minute. | Laturi raportoi noin kerran minuutissa. |
| The charger reports an error | Laturi raportoi virheen |
| The charger service asked Hisingen to slow down. It will try again shortly. | Laturipalvelu pyysi Hisingeniä hidastamaan. Se yrittää uudelleen hetken kuluttua. |
| The charger service could not be reached. | Laturipalveluun ei saada yhteyttä. |
| The charger service does not know that item. | Laturipalvelu ei tunne kyseistä kohdetta. |
| The charger service refused the request. | Laturipalvelu hylkäsi pyynnön. |
| The charger service sent an answer Hisingen could not read. | Laturipalvelu lähetti vastauksen, jota Hisingen ei voinut lukea. |
| The circuit fuse is %@. | Piirin sulake on %@. |
| The limit is set to %@. | Raja on asetettu arvoon %@. |
| The meter sent no voltage, so 230 V is assumed and power is approximate. | Mittari ei lähettänyt jännitettä, joten oletetaan 230 V ja teho on likimääräinen. |
| The one you use in the %@ app. It is stored in the macOS Keychain and never exported. | Sama tili, jota käytät %@-sovelluksessa. Se tallennetaan macOS-avainnippuun eikä sitä koskaan viedä muualle. |
| The saved location in the car where this charger stands. | Auton tallennettu sijainti, jossa tämä laturi sijaitsee. |
| The saved token and the charger pairing are deleted. Charging history that was already recorded stays. | Tallennettu tunnus ja laturin yhdistäminen poistetaan. Jo tallennettu lataushistoria säilyy. |
| This Home Assistant automation uses the charger and may start or stop it. | Tämä Home Assistant -automaatio käyttää laturia ja voi käynnistää tai pysäyttää sen. |
| This account has no charger that Hisingen can control. Check that it is the owner account in the %@ app. | Tällä tilillä ei ole laturia, jota Hisingen voi ohjata. Varmista, että kyseessä on omistajan tili %@-sovelluksessa. |
| This account has no meter that Hisingen can read. Check that it is the owner account in the Perific app. | Tällä tilillä ei ole mittaria, jota Hisingen voi lukea. Varmista, että kyseessä on omistajan tili Perific-sovelluksessa. |
| This account may not control that charger. | Tämä tili ei ehkä saa ohjata kyseistä laturia. |
| This account no longer lists the meter | Tämä tili ei enää näytä mittaria |
| This token could not read the device list, so chargers were found by their entity names. An administrator token also finds the serial number. | Tämä tunnus ei voinut lukea laiteluetteloa, joten laturit löydettiin niiden entiteettien nimistä. Ylläpitäjän tunnus löytää myös sarjanumeron. |
| Three phase | Kolmivaiheinen |
| Tibber's price includes energy, taxes and its markup but not the grid fee. Add yours here; a paired charger can set its own. | Tibberin hinta sisältää energian, verot ja oman katteen, mutta ei verkkosiirtohintaa. Lisää omasi tähän; yhdistetty laturi voi asettaa omansa. |
| Unpair charger | Irrota laturi |
| Use this meter | Käytä tätä mittaria |

### Flagged for this language

- "Ratasininen" is a coined theme name for Circuit Blue, matching "Mestaruussininen" in its subtitle.
- "Kuormanhallinta" for load balancing (Finnish EV docs also say "dynaaminen kuormanhallinta").
- "Kaapelin nimellisvirta" for Cable Rating; "kestovirta" is an alternative.
- Today's earlier block: "Vetotyyppi" for Drive Type; Finnish specs also say "vetotapa".

## fr

Confidence: High confidence; vous-register matches the file.


### Today's morning additions (verify as shipped)

| English source | Shipped value |
| --- | --- |
| Volvo moved to a new sign-in system. Sign in again to keep your vehicle data. | Volvo est passé à un nouveau système de connexion. Reconnectez-vous pour conserver les données de votre véhicule. |
| Drive Type | Type de traction |
| Engine Power | Puissance moteur |
| Gross Weight | Poids total |
| Seats | Sièges |
| Last changed %@ | Dernière modification %@ |
| %d kW | %d kW |
| %d kg | %d kg |

### Strings translated today (168 keys)

| English source | Shipped value |
| --- | --- |
| %@ accepted the command. Waiting for the charger to confirm. | %@ a accepté la commande. En attente de la confirmation du chargeur. |
| %@ did not accept the saved login | %@ n'a pas accepté la connexion enregistrée |
| %@ did not accept the saved login. Enter the account and password again to reconnect. | %@ n'a pas accepté la connexion enregistrée. Saisissez à nouveau le compte et le mot de passe pour vous reconnecter. |
| %@ from charger | %@ du chargeur |
| %@ is delaying the start | %@ retarde le démarrage |
| %@ is unreachable | %@ est injoignable |
| %@ per phase | %@ par phase |
| %@ per phase, limit %@ | %@ par phase, limite %@ |
| %@ to the grid | %@ vers le réseau |
| %@, limited by the cable | %@, limité par le câble |
| %@, limited by the circuit fuse | %@, limité par le fusible du circuit |
| %d charger sessions could not be tied to a vehicle and are kept unassigned. | %d sessions du chargeur n'ont pas pu être rattachées à un véhicule et restent non attribuées. |
| A charger schedule or EcoPilot is active. Turn it off in the NexBlue app so Home Assistant controls the start. | Une programmation du chargeur ou EcoPilot est active. Désactivez-la dans l'app NexBlue pour que Home Assistant contrôle le démarrage. |
| A charging schedule is active on the charger. | Une programmation de recharge est active sur le chargeur. |
| A delayed start or EcoPilot is active on the charger. | Un démarrage différé ou EcoPilot est actif sur le chargeur. |
| A shared charger only records a session for this vehicle when the car's own charging overlaps it. | Un chargeur partagé n'enregistre une session pour ce véhicule que si la recharge propre de la voiture la chevauche. |
| Account email | Adresse e-mail du compte |
| Adaptive | Adaptatif |
| Added to Tibber prices in the planner and for charger sessions. | Ajouté aux prix de Tibber dans le planificateur et pour les sessions du chargeur. |
| After an error | Après une erreur |
| At the charger | Au chargeur |
| By an administrator | Par un administrateur |
| By schedule | Selon la programmation |
| Cable Rating | Capacité du câble |
| Cable lock | Verrouillage du câble |
| Cable unlocked | Câble déverrouillé |
| Cable unplugged | Câble débranché |
| Calculated from the meter's current and voltage, so it can read slightly above the energy your supplier bills. | Calculé à partir de l'intensité et de la tension du compteur, il peut donc être légèrement supérieur à l'énergie facturée par votre fournisseur. |
| Car %@, rest of the house %@ | Voiture %@, reste de la maison %@ |
| Charge complete | Recharge terminée |
| Charger Details | Détails du chargeur |
| Charger Energy | Énergie du chargeur |
| Charger connection | Connexion du chargeur |
| Charger measurement only | Mesure du chargeur uniquement |
| Charger restarted | Chargeur redémarré |
| Charger updated %@ ago | Chargeur mis à jour il y a %@ |
| Charger-measured home sessions against the house meter's readings from Perific, %@ to %@. Charging away from home never reaches that meter. | Sessions domestiques mesurées par le chargeur, comparées aux mesures du compteur de la maison issues de Perific, %@ à %@. La recharge hors de chez soi n'atteint jamais ce compteur. |
| Charging at reduced power | Recharge à puissance réduite |
| Charging enabled | Recharge activée |
| Charging is enabled but the car is drawing no power | La recharge est activée, mais la voiture ne consomme aucun courant |
| Charging state | État de charge |
| Charging switch | Interrupteur de charge |
| Charging uses the lowest. The car and load balancing can ask for less. | La recharge utilise le plus faible. La voiture et l'équilibrage de charge peuvent demander moins. |
| Checked %@ | Vérifié %@ |
| Circuit Blue | Bleu piste |
| Circuit Fuse | Fusible du circuit |
| Connect and find chargers | Se connecter et chercher des chargeurs |
| Connected through | Connecté via |
| Copy custom_components/hisingen_home_charging into your Home Assistant config folder, add hisingen_home_charging: to configuration.yaml and restart. The Home Charging guide in the repository has the steps. | Copiez custom_components/hisingen_home_charging dans le dossier de configuration de Home Assistant, ajoutez hisingen_home_charging: à configuration.yaml, puis redémarrez. Le guide Home Charging du dépôt décrit les étapes. |
| Current per Phase | Intensité par phase |
| Disconnect Perific | Déconnecter Perific |
| Emergency stop | Arrêt d'urgence |
| Entities | Entités |
| Exported Today | Exporté aujourd'hui |
| Held by load balancing | Maintenu par l'équilibrage de charge |
| Hisingen is not signed in to %@ yet. | Hisingen n'est pas encore connecté à %@. |
| Home Assistant accepted the command. Waiting for the charger to confirm. | Home Assistant a accepté la commande. En attente de la confirmation du chargeur. |
| Home Assistant stops the plan and leaves the charger as it is. | Home Assistant arrête le plan et laisse le chargeur dans son état. |
| Home Charging | Recharge à domicile |
| Home charger | Chargeur domestique |
| Home charging plan | Plan de recharge à domicile |
| House %@ | Maison %@ |
| House Current per Phase | Intensité de la maison par phase |
| House Meter | Compteur de la maison |
| House Now | Maison actuellement |
| House Voltage | Tension de la maison |
| House meter last read %@ ago | Compteur de la maison lu pour la dernière fois il y a %@ |
| House sending %@ to the grid | La maison envoie %@ vers le réseau |
| Import sessions now | Importer les sessions maintenant |
| Imported Today | Importé aujourd'hui |
| Importing | Import en cours |
| Last update from %@ %@ | Dernière mise à jour de %@ %@ |
| Load balancing can limit the charger when the house uses more power. | L'équilibrage de charge peut limiter le chargeur quand la maison consomme plus de puissance. |
| Load balancing is holding the charger. It continues when power is free. | L'équilibrage de charge maintient le chargeur en pause. La recharge reprend quand de la puissance se libère. |
| Map by hand | Associer manuellement |
| Measured at the charger, so it includes charging losses. | Mesuré au niveau du chargeur, pertes de charge comprises. |
| Measured from recent charger sessions. It updates when the car charges slower than planned. | Mesuré à partir des sessions récentes du chargeur. La valeur est mise à jour quand la voiture recharge plus lentement que prévu. |
| Meter | Compteur |
| Metered by the charger and read from Home Assistant. Last charger reading %@. | Mesuré par le chargeur et lu depuis Home Assistant. Dernière mesure du chargeur %@. |
| Metered by the charger and read from the %@ cloud. Last charger reading %@. | Mesuré par le chargeur et lu depuis le cloud %@. Dernière mesure du chargeur %@. |
| Mobile data | Données mobiles |
| Needed to keep charger sessions in Hisingen's local history. | Nécessaire pour conserver les sessions du chargeur dans l'historique local de Hisingen. |
| NexBlue is delaying the start | NexBlue retarde le démarrage |
| NexBlue is holding a delayed start | NexBlue maintient un démarrage différé |
| NexBlue is holding the start with a delayed start. | NexBlue maintient le démarrage avec un démarrage différé. |
| No NexBlue charger was found. Map the entities by hand below. | Aucun chargeur NexBlue n'a été trouvé. Associez les entités ci-dessous à la main. |
| No charger is paired. | Aucun chargeur n'est associé. |
| No charging switch is mapped for this charger. | Aucun interrupteur de charge n'est associé à ce chargeur. |
| No new reading arrived from the charger. | Aucune nouvelle mesure n'est arrivée du chargeur. |
| Not authorised | Non autorisé |
| Not imported yet | Pas encore importé |
| Off: local charging history is disabled | Désactivé : l'historique de recharge local est désactivé |
| On plug-in | Au branchement |
| Only the session total was available, so this is an estimate. | Seul le total de la session était disponible, il s'agit donc d'une estimation. |
| Optional. Connects a charger that Home Assistant manages, such as NexBlue, to show its status, control it, and record what it measured. | Facultatif. Connecte un chargeur géré par Home Assistant, comme NexBlue, pour afficher son état, le contrôler et enregistrer ce qu'il a mesuré. |
| Optional. Connects a home charger to show its status, control it, and record what it measured. Easee and Zaptec sign in with their own account. Any other charger works through Home Assistant, such as NexBlue. | Facultatif. Connecte un chargeur domestique pour afficher son état, le contrôler et enregistrer ce qu'il a mesuré. Easee et Zaptec se connectent avec leur propre compte. Tout autre chargeur fonctionne via Home Assistant, comme NexBlue. |
| Optional. Reads your home's electricity use from a Perific monitor, so charging can be shown against the whole house. Hisingen only reads it. Perific keeps balancing the charger. | Facultatif. Lit la consommation électrique de votre maison depuis un moniteur Perific, afin de pouvoir comparer la recharge à l'ensemble de la maison. Hisingen se contente de le lire. Perific continue d'équilibrer le chargeur. |
| Other cars also use this charger | D'autres voitures utilisent aussi ce chargeur |
| Pair charger | Associer le chargeur |
| Perific account email | Adresse e-mail du compte Perific |
| Perific did not accept the saved login. Enter the account and password again to reconnect. | Perific n'a pas accepté la connexion enregistrée. Saisissez à nouveau le compte et le mot de passe pour vous reconnecter. |
| Perific did not accept the saved login. Sign in again in Settings, Electricity. | Perific n'a pas accepté la connexion enregistrée. Reconnectez-vous dans Paramètres, Électricité. |
| Phase Mode | Mode de phase |
| Plans run inside Home Assistant. This charger is connected directly, so it offers status, Charge now, Pause and history. | Les plans fonctionnent dans Home Assistant. Ce chargeur est connecté directement : il offre l'état, Recharger maintenant, Pause et l'historique. |
| Power loss | Coupure de courant |
| Price source: %@. | Source du prix : %@. |
| Priced per 15-minute interval from the charger's own readings. | Tarifé par intervalle de 15 minutes d'après les mesures du chargeur. |
| Reading chargers… | Lecture des chargeurs… |
| Reading every 30 seconds | Lecture toutes les 30 secondes |
| Remotely | À distance |
| Reported %@ | Signalé %@ |
| Resume | Reprendre |
| Sending the pause command to %@ | Envoi de la commande de pause à %@ |
| Sending the start command to %@ | Envoi de la commande de démarrage à %@ |
| Session history | Historique des sessions |
| Sessions and plans are tied to this vehicle only. A car being near the charger is not enough. | Les sessions et les plans sont rattachés uniquement à ce véhicule. Qu'une voiture soit près du chargeur ne suffit pas. |
| Sessions are tied to this vehicle only. A car being near the charger is not enough. | Les sessions sont rattachées uniquement à ce véhicule. Qu'une voiture soit près du chargeur ne suffit pas. |
| Shared charger | Chargeur partagé |
| Sign in | Se connecter |
| Sign in again in Settings. | Reconnectez-vous dans les Paramètres. |
| Sign in and find chargers | Se connecter et chercher des chargeurs |
| Sign in and find meters | Se connecter et chercher des compteurs |
| Sign in to %@ again | Reconnectez-vous à %@ |
| Sign out | Se déconnecter |
| Sign-in refused | Connexion rejetée |
| Sign-in rejected | Connexion refusée |
| Signed in to %@ | Connecté à %@ |
| Signing in… | Connexion… |
| Single phase | Monophasé |
| Source | Source |
| Still needed: %@. | Encore nécessaire : %@. |
| The account or password was not accepted. | Le compte ou le mot de passe n'a pas été accepté. |
| The account you use in the Perific app. It is stored in the macOS Keychain and never exported. | Le compte que vous utilisez dans l'app Perific. Il est stocké dans le trousseau macOS et n'est jamais exporté. |
| The cable allows %@. | Le câble admet %@. |
| The charger command was rejected | La commande du chargeur a été refusée |
| The charger did not confirm the last command. | Le chargeur n'a pas confirmé la dernière commande. |
| The charger has not confirmed the command | Le chargeur n'a pas confirmé la commande |
| The charger has not reported recently | Le chargeur n'a pas signalé récemment |
| The charger is unavailable in %@ | Le chargeur est indisponible dans %@ |
| The charger is unavailable in Home Assistant | Le chargeur est indisponible dans Home Assistant |
| The charger is unavailable in Home Assistant. | Le chargeur est indisponible dans Home Assistant. |
| The charger kept its previous state. Try again, or check the charger. | Le chargeur a conservé son état précédent. Réessayez, ou vérifiez le chargeur. |
| The charger readings below are the last ones received. | Les mesures ci-dessous sont les dernières reçues du chargeur. |
| The charger recorded this session while no battery reading was available, so there is no battery-side estimate. | Le chargeur a enregistré cette session alors qu'aucune mesure de batterie n'était disponible, il n'y a donc pas d'estimation côté batterie. |
| The charger reported an error after the command. | Le chargeur a signalé une erreur après la commande. |
| The charger reports about once a minute. | Le chargeur signale environ une fois par minute. |
| The charger reports an error | Le chargeur signale une erreur |
| The charger service asked Hisingen to slow down. It will try again shortly. | Le service du chargeur a demandé à Hisingen de ralentir. Un nouvel essai aura lieu sous peu. |
| The charger service could not be reached. | Le service du chargeur est injoignable. |
| The charger service does not know that item. | Le service du chargeur ne connaît pas cet élément. |
| The charger service refused the request. | Le service du chargeur a refusé la requête. |
| The charger service sent an answer Hisingen could not read. | Le service du chargeur a envoyé une réponse que Hisingen n'a pas pu lire. |
| The circuit fuse is %@. | Le fusible du circuit est %@. |
| The limit is set to %@. | La limite est réglée sur %@. |
| The meter sent no voltage, so 230 V is assumed and power is approximate. | Le compteur n'a envoyé aucune tension, 230 V sont donc supposés et la puissance est approximative. |
| The one you use in the %@ app. It is stored in the macOS Keychain and never exported. | Celui que vous utilisez dans l'app %@. Il est stocké dans le trousseau macOS et n'est jamais exporté. |
| The saved location in the car where this charger stands. | L'emplacement enregistré dans la voiture où se trouve ce chargeur. |
| The saved token and the charger pairing are deleted. Charging history that was already recorded stays. | Le jeton enregistré et l'association du chargeur sont supprimés. L'historique de recharge déjà enregistré est conservé. |
| This Home Assistant automation uses the charger and may start or stop it. | Cette automatisation Home Assistant utilise le chargeur et peut le démarrer ou l'arrêter. |
| This account has no charger that Hisingen can control. Check that it is the owner account in the %@ app. | Ce compte n'a aucun chargeur que Hisingen peut contrôler. Vérifiez qu'il s'agit du compte propriétaire dans l'app %@. |
| This account has no meter that Hisingen can read. Check that it is the owner account in the Perific app. | Ce compte n'a aucun compteur que Hisingen peut lire. Vérifiez qu'il s'agit du compte propriétaire dans l'app Perific. |
| This account may not control that charger. | Ce compte n'est peut-être pas autorisé à contrôler ce chargeur. |
| This account no longer lists the meter | Ce compte ne référence plus le compteur |
| This token could not read the device list, so chargers were found by their entity names. An administrator token also finds the serial number. | Ce jeton n'a pas pu lire la liste des appareils, les chargeurs ont donc été trouvés par leurs noms d'entité. Un jeton d'administrateur trouve aussi le numéro de série. |
| Three phase | Triphasé |
| Tibber's price includes energy, taxes and its markup but not the grid fee. Add yours here; a paired charger can set its own. | Le prix de Tibber comprend l'énergie, les taxes et sa marge, mais pas les frais de réseau. Ajoutez les vôtres ici ; un chargeur associé peut définir les siens. |
| Unpair charger | Dissocier le chargeur |
| Use this meter | Utiliser ce compteur |

### Flagged for this language

- Register: formal vous throughout, matching the existing file.
- "Bleu piste" for Circuit Blue, matching "Bleu championnat" in its subtitle.
- "L'équilibrage de charge" for load balancing; confirm against French Easee/Zaptec wording.
- Colons use a regular space before them, matching the existing file (not a non-breaking space).

## it

Confidence: High confidence; tu-register matches the file.


### Today's morning additions (verify as shipped)

| English source | Shipped value |
| --- | --- |
| Volvo moved to a new sign-in system. Sign in again to keep your vehicle data. | Volvo ha adottato un nuovo sistema di accesso. Accedi di nuovo per conservare i dati del veicolo. |
| Drive Type | Tipo di trazione |
| Engine Power | Potenza del motore |
| Gross Weight | Massa complessiva |
| Seats | Posti |
| Last changed %@ | Ultima modifica %@ |
| %d kW | %d kW |
| %d kg | %d kg |

### Strings translated today (168 keys)

| English source | Shipped value |
| --- | --- |
| %@ accepted the command. Waiting for the charger to confirm. | %@ ha accettato il comando. In attesa della conferma del caricatore. |
| %@ did not accept the saved login | %@ non ha accettato l'accesso salvato |
| %@ did not accept the saved login. Enter the account and password again to reconnect. | %@ non ha accettato l'accesso salvato. Inserisci di nuovo account e password per riconnetterti. |
| %@ from charger | %@ dal caricatore |
| %@ is delaying the start | %@ sta ritardando l'avvio |
| %@ is unreachable | %@ è irraggiungibile |
| %@ per phase | %@ per fase |
| %@ per phase, limit %@ | %@ per fase, limite %@ |
| %@ to the grid | %@ alla rete |
| %@, limited by the cable | %@, limitato dal cavo |
| %@, limited by the circuit fuse | %@, limitato dal fusibile del circuito |
| %d charger sessions could not be tied to a vehicle and are kept unassigned. | %d sessioni del caricatore non hanno potuto essere collegate a un veicolo e restano non assegnate. |
| A charger schedule or EcoPilot is active. Turn it off in the NexBlue app so Home Assistant controls the start. | Una programmazione del caricatore o EcoPilot è attiva. Disattivala nell'app NexBlue così Home Assistant controlla l'avvio. |
| A charging schedule is active on the charger. | Una programmazione di ricarica è attiva sul caricatore. |
| A delayed start or EcoPilot is active on the charger. | Un avvio ritardato o EcoPilot è attivo sul caricatore. |
| A shared charger only records a session for this vehicle when the car's own charging overlaps it. | Un caricatore condiviso registra una sessione per questo veicolo solo quando la ricarica dell'auto stessa la sovrappone. |
| Account email | Email dell'account |
| Adaptive | Adattivo |
| Added to Tibber prices in the planner and for charger sessions. | Aggiunto ai prezzi di Tibber nel pianificatore e per le sessioni del caricatore. |
| After an error | Dopo un errore |
| At the charger | Al caricatore |
| By an administrator | Da un amministratore |
| By schedule | Secondo la programmazione |
| Cable Rating | Portata del cavo |
| Cable lock | Blocco cavo |
| Cable unlocked | Cavo sbloccato |
| Cable unplugged | Cavo scollegato |
| Calculated from the meter's current and voltage, so it can read slightly above the energy your supplier bills. | Calcolato dalla corrente e dalla tensione del contatore, quindi può risultare leggermente superiore all'energia che il tuo fornitore fattura. |
| Car %@, rest of the house %@ | Auto %@, resto della casa %@ |
| Charge complete | Ricarica completata |
| Charger Details | Dettagli del caricatore |
| Charger Energy | Energia del caricatore |
| Charger connection | Connessione del caricatore |
| Charger measurement only | Solo misura del caricatore |
| Charger restarted | Caricatore riavviato |
| Charger updated %@ ago | Caricatore aggiornato %@ fa |
| Charger-measured home sessions against the house meter's readings from Perific, %@ to %@. Charging away from home never reaches that meter. | Sessioni domestiche misurate dal caricatore rispetto alle letture del contatore della casa da Perific, %@ a %@. Ricaricare fuori casa non raggiunge mai quel contatore. |
| Charging at reduced power | Ricarica a potenza ridotta |
| Charging enabled | Ricarica attivata |
| Charging is enabled but the car is drawing no power | La ricarica è attivata, ma l'auto non sta assorbendo corrente |
| Charging state | Stato di ricarica |
| Charging switch | Interruttore di ricarica |
| Charging uses the lowest. The car and load balancing can ask for less. | La ricarica usa il valore più basso. L'auto e il bilanciamento del carico possono chiedere meno. |
| Checked %@ | Controllato %@ |
| Circuit Blue | Blu pista |
| Circuit Fuse | Fusibile del circuito |
| Connect and find chargers | Connetti e trova i caricatori |
| Connected through | Connesso tramite |
| Copy custom_components/hisingen_home_charging into your Home Assistant config folder, add hisingen_home_charging: to configuration.yaml and restart. The Home Charging guide in the repository has the steps. | Copia custom_components/hisingen_home_charging nella cartella di configurazione di Home Assistant, aggiungi hisingen_home_charging: a configuration.yaml e riavvia. La guida Home Charging nel repository contiene i passaggi. |
| Current per Phase | Corrente per fase |
| Disconnect Perific | Disconnetti Perific |
| Emergency stop | Arresto di emergenza |
| Entities | Entità |
| Exported Today | Esportato oggi |
| Held by load balancing | Trattenuto dal bilanciamento del carico |
| Hisingen is not signed in to %@ yet. | Hisingen non ha ancora effettuato l'accesso a %@. |
| Home Assistant accepted the command. Waiting for the charger to confirm. | Home Assistant ha accettato il comando. In attesa della conferma del caricatore. |
| Home Assistant stops the plan and leaves the charger as it is. | Home Assistant ferma il piano e lascia il caricatore così com'è. |
| Home Charging | Ricarica domestica |
| Home charger | Caricatore domestico |
| Home charging plan | Piano di ricarica domestica |
| House %@ | Casa %@ |
| House Current per Phase | Corrente della casa per fase |
| House Meter | Contatore della casa |
| House Now | Casa ora |
| House Voltage | Tensione della casa |
| House meter last read %@ ago | Contatore della casa letto per l'ultima volta %@ fa |
| House sending %@ to the grid | La casa invia %@ alla rete |
| Import sessions now | Importa le sessioni adesso |
| Imported Today | Importato oggi |
| Importing | Importazione in corso |
| Last update from %@ %@ | Ultimo aggiornamento da %@ %@ |
| Load balancing can limit the charger when the house uses more power. | Il bilanciamento del carico può limitare il caricatore quando la casa consuma più potenza. |
| Load balancing is holding the charger. It continues when power is free. | Il bilanciamento del carico sta trattenendo il caricatore. La ricarica riprende quando c'è potenza disponibile. |
| Map by hand | Associa a mano |
| Measured at the charger, so it includes charging losses. | Misurato al caricatore, quindi include le perdite di ricarica. |
| Measured from recent charger sessions. It updates when the car charges slower than planned. | Misurato dalle sessioni recenti del caricatore. Si aggiorna quando l'auto ricarica più lentamente del previsto. |
| Meter | Contatore |
| Metered by the charger and read from Home Assistant. Last charger reading %@. | Misurato dal caricatore e letto da Home Assistant. Ultima lettura del caricatore %@. |
| Metered by the charger and read from the %@ cloud. Last charger reading %@. | Misurato dal caricatore e letto dal cloud %@. Ultima lettura del caricatore %@. |
| Mobile data | Dati mobili |
| Needed to keep charger sessions in Hisingen's local history. | Necessario per conservare le sessioni del caricatore nella cronologia locale di Hisingen. |
| NexBlue is delaying the start | NexBlue sta ritardando l'avvio |
| NexBlue is holding a delayed start | NexBlue sta trattenendo un avvio ritardato |
| NexBlue is holding the start with a delayed start. | NexBlue sta trattenendo l'avvio con un avvio ritardato. |
| No NexBlue charger was found. Map the entities by hand below. | Nessun caricatore NexBlue trovato. Associa le entità a mano qui sotto. |
| No charger is paired. | Nessun caricatore è associato. |
| No charging switch is mapped for this charger. | Nessun interruttore di ricarica è associato a questo caricatore. |
| No new reading arrived from the charger. | Non è arrivata una nuova lettura dal caricatore. |
| Not authorised | Non autorizzato |
| Not imported yet | Non ancora importato |
| Off: local charging history is disabled | Disattivato: la cronologia locale delle ricariche è disattivata |
| On plug-in | All'inserimento |
| Only the session total was available, so this is an estimate. | Era disponibile solo il totale della sessione, quindi è una stima. |
| Optional. Connects a charger that Home Assistant manages, such as NexBlue, to show its status, control it, and record what it measured. | Facoltativo. Collega un caricatore gestito da Home Assistant, come NexBlue, per mostrarne lo stato, controllarlo e registrare ciò che ha misurato. |
| Optional. Connects a home charger to show its status, control it, and record what it measured. Easee and Zaptec sign in with their own account. Any other charger works through Home Assistant, such as NexBlue. | Facoltativo. Collega un caricatore domestico per mostrarne lo stato, controllarlo e registrare ciò che ha misurato. Easee e Zaptec accedono con il proprio account. Qualsiasi altro caricatore funziona tramite Home Assistant, come NexBlue. |
| Optional. Reads your home's electricity use from a Perific monitor, so charging can be shown against the whole house. Hisingen only reads it. Perific keeps balancing the charger. | Facoltativo. Legge i consumi elettrici della tua casa da un monitor Perific, così la ricarica può essere confrontata con l'intera casa. Hisingen si limita a leggerlo. Perific continua a bilanciare il caricatore. |
| Other cars also use this charger | Anche altre auto usano questo caricatore |
| Pair charger | Associa caricatore |
| Perific account email | Email dell'account Perific |
| Perific did not accept the saved login. Enter the account and password again to reconnect. | Perific non ha accettato l'accesso salvato. Inserisci di nuovo account e password per riconnetterti. |
| Perific did not accept the saved login. Sign in again in Settings, Electricity. | Perific non ha accettato l'accesso salvato. Accedi di nuovo in Impostazioni, Elettricità. |
| Phase Mode | Modalità fasi |
| Plans run inside Home Assistant. This charger is connected directly, so it offers status, Charge now, Pause and history. | I piani vengono eseguiti in Home Assistant. Questo caricatore è collegato direttamente, quindi offre stato, Ricarica ora, Pausa e cronologia. |
| Power loss | Interruzione di corrente |
| Price source: %@. | Fonte del prezzo: %@. |
| Priced per 15-minute interval from the charger's own readings. | Prezzato per intervalli di 15 minuti dalle letture del caricatore stesso. |
| Reading chargers… | Lettura dei caricatori… |
| Reading every 30 seconds | Lettura ogni 30 secondi |
| Remotely | Da remoto |
| Reported %@ | Segnalato %@ |
| Resume | Riprendi |
| Sending the pause command to %@ | Invio del comando di pausa a %@ |
| Sending the start command to %@ | Invio del comando di avvio a %@ |
| Session history | Cronologia delle sessioni |
| Sessions and plans are tied to this vehicle only. A car being near the charger is not enough. | Sessioni e piani sono legati solo a questo veicolo. Che un'auto sia vicino al caricatore non basta. |
| Sessions are tied to this vehicle only. A car being near the charger is not enough. | Le sessioni sono legate solo a questo veicolo. Che un'auto sia vicino al caricatore non basta. |
| Shared charger | Caricatore condiviso |
| Sign in | Accedi |
| Sign in again in Settings. | Accedi di nuovo nelle Impostazioni. |
| Sign in and find chargers | Accedi e trova i caricatori |
| Sign in and find meters | Accedi e trova i contatori |
| Sign in to %@ again | Accedi di nuovo a %@ |
| Sign out | Esci |
| Sign-in refused | Accesso negato |
| Sign-in rejected | Accesso rifiutato |
| Signed in to %@ | Connesso a %@ |
| Signing in… | Accesso in corso… |
| Single phase | Monofase |
| Source | Fonte |
| Still needed: %@. | Serve ancora: %@. |
| The account or password was not accepted. | L'account o la password non è stato accettato. |
| The account you use in the Perific app. It is stored in the macOS Keychain and never exported. | L'account che usi nell'app Perific. È salvato nel Portachiavi di macOS e non viene mai esportato. |
| The cable allows %@. | Il cavo ammette %@. |
| The charger command was rejected | Il comando al caricatore è stato rifiutato |
| The charger did not confirm the last command. | Il caricatore non ha confermato l'ultimo comando. |
| The charger has not confirmed the command | Il caricatore non ha confermato il comando |
| The charger has not reported recently | Il caricatore non ha inviato dati di recente |
| The charger is unavailable in %@ | Il caricatore non è disponibile in %@ |
| The charger is unavailable in Home Assistant | Il caricatore non è disponibile in Home Assistant |
| The charger is unavailable in Home Assistant. | Il caricatore non è disponibile in Home Assistant. |
| The charger kept its previous state. Try again, or check the charger. | Il caricatore ha mantenuto lo stato precedente. Riprova, oppure controlla il caricatore. |
| The charger readings below are the last ones received. | Le letture qui sotto sono le ultime ricevute dal caricatore. |
| The charger recorded this session while no battery reading was available, so there is no battery-side estimate. | Il caricatore ha registrato questa sessione mentre non era disponibile una lettura della batteria, quindi non c'è una stima lato batteria. |
| The charger reported an error after the command. | Il caricatore ha segnalato un errore dopo il comando. |
| The charger reports about once a minute. | Il caricatore invia dati circa una volta al minuto. |
| The charger reports an error | Il caricatore segnala un errore |
| The charger service asked Hisingen to slow down. It will try again shortly. | Il servizio del caricatore ha chiesto a Hisingen di rallentare. Riproverà a breve. |
| The charger service could not be reached. | Il servizio del caricatore non è raggiungibile. |
| The charger service does not know that item. | Il servizio del caricatore non conosce quell'elemento. |
| The charger service refused the request. | Il servizio del caricatore ha rifiutato la richiesta. |
| The charger service sent an answer Hisingen could not read. | Il servizio del caricatore ha inviato una risposta che Hisingen non ha potuto leggere. |
| The circuit fuse is %@. | Il fusibile del circuito è %@. |
| The limit is set to %@. | Il limite è impostato su %@. |
| The meter sent no voltage, so 230 V is assumed and power is approximate. | Il contatore non ha inviato la tensione, quindi si assume 230 V e la potenza è approssimativa. |
| The one you use in the %@ app. It is stored in the macOS Keychain and never exported. | Quello che usi nell'app %@. È salvato nel Portachiavi di macOS e non viene mai esportato. |
| The saved location in the car where this charger stands. | La posizione salvata nell'auto dove si trova questo caricatore. |
| The saved token and the charger pairing are deleted. Charging history that was already recorded stays. | Il token salvato e l'associazione del caricatore vengono eliminati. La cronologia delle ricariche già registrata resta. |
| This Home Assistant automation uses the charger and may start or stop it. | Questa automazione di Home Assistant usa il caricatore e può avviarlo o fermarlo. |
| This account has no charger that Hisingen can control. Check that it is the owner account in the %@ app. | Questo account non ha alcun caricatore che Hisingen possa controllare. Verifica che sia l'account proprietario nell'app %@. |
| This account has no meter that Hisingen can read. Check that it is the owner account in the Perific app. | Questo account non ha alcun contatore che Hisingen possa leggere. Verifica che sia l'account proprietario nell'app Perific. |
| This account may not control that charger. | Questo account potrebbe non essere autorizzato a controllare quel caricatore. |
| This account no longer lists the meter | Questo account non elenca più il contatore |
| This token could not read the device list, so chargers were found by their entity names. An administrator token also finds the serial number. | Questo token non ha potuto leggere l'elenco dei dispositivi, quindi i caricatori sono stati trovati dai nomi delle entità. Un token di amministratore trova anche il numero di serie. |
| Three phase | Trifase |
| Tibber's price includes energy, taxes and its markup but not the grid fee. Add yours here; a paired charger can set its own. | Il prezzo di Tibber include energia, tasse e il suo margine, ma non la tariffa di rete. Aggiungi la tua qui; un caricatore associato può impostare la propria. |
| Unpair charger | Dissocia caricatore |
| Use this meter | Usa questo contatore |

### Flagged for this language

- Register: informal tu throughout, matching the existing file.
- "Blu pista" for Circuit Blue, matching "Blu campionato" in its subtitle.
- "Il bilanciamento del carico" for load balancing; also "bilanciamento del carico" vs "della carica": confirm the EV term.
- "All'inserimento" for On plug-in (cable insertion); "alla connessione" is an alternative.

## ko

Confidence: Good confidence in register and grammar; electrician-facing terms (퓨즈, 상별) and the particles after format specifiers need a native pass.


### Today's morning additions (verify as shipped)

| English source | Shipped value |
| --- | --- |
| Volvo moved to a new sign-in system. Sign in again to keep your vehicle data. | Volvo가 새 로그인 시스템으로 바뀌었습니다. 차량 데이터를 유지하려면 다시 로그인하세요. |
| Drive Type | 구동 방식 |
| Engine Power | 엔진 출력 |
| Gross Weight | 총 중량 |
| Seats | 좌석 |
| Last changed %@ | 마지막 변경: %@ |
| %d kW | %d kW |
| %d kg | %d kg |

### Strings translated today (167 keys)

| English source | Shipped value |
| --- | --- |
| %@ accepted the command. Waiting for the charger to confirm. | %@이(가) 명령을 수락했습니다. 충전기 확인을 기다리는 중입니다. |
| %@ did not accept the saved login | %@이(가) 저장된 로그인을 수락하지 않았습니다 |
| %@ did not accept the saved login. Enter the account and password again to reconnect. | %@이(가) 저장된 로그인을 수락하지 않았습니다. 다시 연결하려면 계정과 비밀번호를 입력하세요. |
| %@ from charger | 충전기에서 %@ |
| %@ is delaying the start | %@이(가) 시작을 지연하고 있습니다 |
| %@ is unreachable | %@에 연결할 수 없습니다 |
| %@ per phase | 상별 %@ |
| %@ per phase, limit %@ | 상별 %@, 한도 %@ |
| %@ to the grid | %@을(를) 전력망으로 |
| %@, limited by the cable | %@, 케이블에 의해 제한됨 |
| %@, limited by the circuit fuse | %@, 회로 퓨즈에 의해 제한됨 |
| %d charger sessions could not be tied to a vehicle and are kept unassigned. | %d개의 충전기 세션을 차량에 연결할 수 없어 지정되지 않은 상태로 보관됩니다. |
| A charger schedule or EcoPilot is active. Turn it off in the NexBlue app so Home Assistant controls the start. | 충전기 일정 또는 EcoPilot이 활성화되어 있습니다. Home Assistant가 시작을 제어하도록 NexBlue 앱에서 끄세요. |
| A charging schedule is active on the charger. | 충전기에 충전 일정이 활성화되어 있습니다. |
| A delayed start or EcoPilot is active on the charger. | 충전기에 지연 시작 또는 EcoPilot이 활성화되어 있습니다. |
| A shared charger only records a session for this vehicle when the car's own charging overlaps it. | 공유 충전기는 이 차량의 세션을, 차량 자체 충전이 겹칠 때만 기록합니다. |
| Account email | 계정 이메일 |
| Adaptive | 자동 조절 |
| Added to Tibber prices in the planner and for charger sessions. | 플래너와 충전기 세션에서 Tibber 가격에 추가됩니다. |
| After an error | 오류 후 |
| At the charger | 충전기에서 |
| By an administrator | 관리자가 |
| By schedule | 일정에 따라 |
| Cable Rating | 케이블 정격 |
| Cable lock | 케이블 잠금 |
| Cable unlocked | 케이블 잠금 해제됨 |
| Cable unplugged | 케이블 분리됨 |
| Calculated from the meter's current and voltage, so it can read slightly above the energy your supplier bills. | 계량기의 전류와 전압으로 계산되어, 공급사가 청구하는 에너지보다 약간 높게 나올 수 있습니다. |
| Car %@, rest of the house %@ | 차량 %@, 집의 나머지 %@ |
| Charge complete | 충전 완료 |
| Charger Details | 충전기 상세 정보 |
| Charger Energy | 충전기 에너지 |
| Charger connection | 충전기 연결 |
| Charger measurement only | 충전기 측정값만 |
| Charger restarted | 충전기 재시작됨 |
| Charger updated %@ ago | 충전기가 %@ 전에 업데이트됨 |
| Charger-measured home sessions against the house meter's readings from Perific, %@ to %@. Charging away from home never reaches that meter. | 충전기에서 측정한 가정 세션을 Perific 집 계량기 읽음과 비교해 표시합니다(%@ ~ %@). 집 밖에서 충전하면 이 계량기에 기록되지 않습니다. |
| Charging at reduced power | 낮은 출력으로 충전 중 |
| Charging enabled | 충전 활성화됨 |
| Charging is enabled but the car is drawing no power | 충전이 활성화되어 있지만 차량이 전력을 소모하지 않습니다 |
| Charging state | 충전 상태 |
| Charging switch | 충전 스위치 |
| Charging uses the lowest. The car and load balancing can ask for less. | 충전은 가장 낮은 값을 사용합니다. 차량과 부하 분산이 더 적게 요구할 수 있습니다. |
| Checked %@ | 확인: %@ |
| Circuit Fuse | 회로 퓨즈 |
| Connect and find chargers | 연결하고 충전기 찾기 |
| Connected through | 연결 수단 |
| Copy custom_components/hisingen_home_charging into your Home Assistant config folder, add hisingen_home_charging: to configuration.yaml and restart. The Home Charging guide in the repository has the steps. | custom_components/hisingen_home_charging을 Home Assistant 설정 폴더에 복사하고, configuration.yaml에 hisingen_home_charging:를 추가한 다음 다시 시작하세요. 단계는 저장소의 Home Charging 가이드에 있습니다. |
| Current per Phase | 상별 전류 |
| Disconnect Perific | Perific 연결 끊기 |
| Emergency stop | 비상 정지 |
| Entities | 엔터티 |
| Exported Today | 오늘 내보냄 |
| Held by load balancing | 부하 분산으로 보류됨 |
| Hisingen is not signed in to %@ yet. | Hisingen이 아직 %@에 로그인되어 있지 않습니다. |
| Home Assistant accepted the command. Waiting for the charger to confirm. | Home Assistant가 명령을 수락했습니다. 충전기 확인을 기다리는 중입니다. |
| Home Assistant stops the plan and leaves the charger as it is. | Home Assistant가 계획을 중지하고 충전기를 현재 상태로 둡니다. |
| Home Charging | 가정 충전 |
| Home charger | 가정용 충전기 |
| Home charging plan | 가정 충전 계획 |
| House %@ | 집 %@ |
| House Current per Phase | 집 상별 전류 |
| House Meter | 집 계량기 |
| House Now | 집 현재 전력 |
| House Voltage | 집 전압 |
| House meter last read %@ ago | 집 계량기 마지막 읽음 %@ 전 |
| House sending %@ to the grid | 집에서 %@을(를) 전력망으로 보내는 중 |
| Import sessions now | 지금 세션 가져오기 |
| Imported Today | 오늘 가져옴 |
| Importing | 가져오는 중 |
| Last update from %@ %@ | %@에서 마지막 업데이트 %@ |
| Load balancing can limit the charger when the house uses more power. | 집에서 전력을 더 많이 쓰면 부하 분산이 충전기를 제한할 수 있습니다. |
| Load balancing is holding the charger. It continues when power is free. | 부하 분산이 충전기를 보류하고 있습니다. 전력에 여유가 생기면 충전이 계속됩니다. |
| Map by hand | 수동으로 연결 |
| Measured at the charger, so it includes charging losses. | 충전기에서 측정한 값이라 충전 손실이 포함됩니다. |
| Measured from recent charger sessions. It updates when the car charges slower than planned. | 최근 충전기 세션에서 측정했습니다. 차량이 계획보다 느리게 충전하면 업데이트됩니다. |
| Meter | 계량기 |
| Metered by the charger and read from Home Assistant. Last charger reading %@. | 충전기에서 측정하고 Home Assistant에서 읽습니다. 마지막 충전기 읽음 %@. |
| Metered by the charger and read from the %@ cloud. Last charger reading %@. | 충전기에서 측정하고 %@ 클라우드에서 읽습니다. 마지막 충전기 읽음 %@. |
| Mobile data | 모바일 데이터 |
| Needed to keep charger sessions in Hisingen's local history. | Hisingen 로컬 기록에 충전기 세션을 보관하는 데 필요합니다. |
| NexBlue is delaying the start | NexBlue가 시작을 지연하고 있습니다 |
| NexBlue is holding a delayed start | NexBlue가 지연 시작을 보류하고 있습니다 |
| NexBlue is holding the start with a delayed start. | NexBlue가 지연 시작으로 시작을 보류하고 있습니다. |
| No NexBlue charger was found. Map the entities by hand below. | NexBlue 충전기를 찾을 수 없습니다. 아래에서 엔터티를 수동으로 연결하세요. |
| No charger is paired. | 연동된 충전기가 없습니다. |
| No charging switch is mapped for this charger. | 이 충전기에 매핑된 충전 스위치가 없습니다. |
| No new reading arrived from the charger. | 충전기에서 새로운 읽음이 도착하지 않았습니다. |
| Not authorised | 권한 없음 |
| Not imported yet | 아직 가져오지 않음 |
| Off: local charging history is disabled | 끔: 로컬 충전 기록이 비활성화됨 |
| On plug-in | 플러그 연결 시 |
| Only the session total was available, so this is an estimate. | 세션 합계만 사용할 수 있어 추정치입니다. |
| Optional. Connects a charger that Home Assistant manages, such as NexBlue, to show its status, control it, and record what it measured. | 선택 사항. Home Assistant가 관리하는 충전기(예: NexBlue)를 연결하여 상태를 표시하고 제어하며 측정값을 기록합니다. |
| Optional. Connects a home charger to show its status, control it, and record what it measured. Easee and Zaptec sign in with their own account. Any other charger works through Home Assistant, such as NexBlue. | 선택 사항. 가정용 충전기를 연결하여 상태를 표시하고 제어하며 측정값을 기록합니다. Easee와 Zaptec은 자체 계정으로 로그인합니다. NexBlue처럼 다른 충전기는 Home Assistant를 통해 작동합니다. |
| Optional. Reads your home's electricity use from a Perific monitor, so charging can be shown against the whole house. Hisingen only reads it. Perific keeps balancing the charger. | 선택 사항. Perific 모니터에서 집의 전력 사용량을 읽어, 충전을 집 전체와 비교해 보여줍니다. Hisingen은 읽기만 하고, 충전기 부하 분산은 Perific이 계속 담당합니다. |
| Other cars also use this charger | 다른 차량도 이 충전기를 사용합니다 |
| Pair charger | 충전기 연동 |
| Perific account email | Perific 계정 이메일 |
| Perific did not accept the saved login. Enter the account and password again to reconnect. | Perific이 저장된 로그인을 수락하지 않았습니다. 다시 연결하려면 계정과 비밀번호를 입력하세요. |
| Perific did not accept the saved login. Sign in again in Settings, Electricity. | Perific이 저장된 로그인을 수락하지 않았습니다. 설정의 전기에서 다시 로그인하세요. |
| Phase Mode | 상 모드 |
| Plans run inside Home Assistant. This charger is connected directly, so it offers status, Charge now, Pause and history. | 계획은 Home Assistant 안에서 실행됩니다. 이 충전기는 직접 연결되어 있어 상태, 지금 충전, 일시 중지, 기록을 제공합니다. |
| Power loss | 정전 |
| Price source: %@. | 가격 출처: %@. |
| Priced per 15-minute interval from the charger's own readings. | 충전기 자체 읽음을 기준으로 15분 간격별로 가격이 계산됩니다. |
| Reading chargers… | 충전기 읽는 중… |
| Reading every 30 seconds | 30초마다 읽음 |
| Remotely | 원격으로 |
| Reported %@ | 보고: %@ |
| Resume | 재개 |
| Sending the pause command to %@ | %@에 일시 중지 명령을 보내는 중 |
| Sending the start command to %@ | %@에 시작 명령을 보내는 중 |
| Session history | 세션 기록 |
| Sessions and plans are tied to this vehicle only. A car being near the charger is not enough. | 세션과 계획은 이 차량에만 연결됩니다. 차량이 충전기 근처에 있다고 해서 충분하지 않습니다. |
| Sessions are tied to this vehicle only. A car being near the charger is not enough. | 세션은 이 차량에만 연결됩니다. 차량이 충전기 근처에 있다고 해서 충분하지 않습니다. |
| Shared charger | 공유 충전기 |
| Sign in | 로그인 |
| Sign in again in Settings. | 설정에서 다시 로그인하세요. |
| Sign in and find chargers | 로그인하고 충전기 찾기 |
| Sign in and find meters | 로그인하고 계량기 찾기 |
| Sign in to %@ again | %@에 다시 로그인하세요 |
| Sign out | 로그아웃 |
| Sign-in refused | 로그인이 거절되었습니다 |
| Sign-in rejected | 로그인 거부됨 |
| Signed in to %@ | %@에 로그인됨 |
| Signing in… | 로그인 중… |
| Single phase | 단상 |
| Source | 출처 |
| Still needed: %@. | 아직 필요함: %@. |
| The account or password was not accepted. | 계정 또는 비밀번호가 승인되지 않았습니다. |
| The account you use in the Perific app. It is stored in the macOS Keychain and never exported. | Perific 앱에서 사용하는 계정입니다. macOS 키체인에 저장되며 절대 내보내지 않습니다. |
| The cable allows %@. | 케이블은 %@까지 허용합니다. |
| The charger command was rejected | 충전기 명령이 거부되었습니다 |
| The charger did not confirm the last command. | 충전기가 마지막 명령을 확인하지 않았습니다. |
| The charger has not confirmed the command | 충전기가 명령을 확인하지 않았습니다 |
| The charger has not reported recently | 충전기가 최근에 보고하지 않았습니다 |
| The charger is unavailable in %@ | %@에서 충전기를 사용할 수 없습니다 |
| The charger is unavailable in Home Assistant | Home Assistant에서 충전기를 사용할 수 없습니다 |
| The charger is unavailable in Home Assistant. | Home Assistant에서 충전기를 사용할 수 없습니다. |
| The charger kept its previous state. Try again, or check the charger. | 충전기가 이전 상태를 유지했습니다. 다시 시도하거나 충전기를 확인하세요. |
| The charger readings below are the last ones received. | 아래 충전기 읽음은 마지막으로 수신된 값입니다. |
| The charger recorded this session while no battery reading was available, so there is no battery-side estimate. | 배터리 읽음이 없는 동안 충전기가 이 세션을 기록해서 배터리 측 추정치가 없습니다. |
| The charger reported an error after the command. | 충전기가 명령 후 오류를 보고했습니다. |
| The charger reports about once a minute. | 충전기는 약 1분에 한 번 보고합니다. |
| The charger reports an error | 충전기가 오류를 보고합니다 |
| The charger service asked Hisingen to slow down. It will try again shortly. | 충전기 서비스가 Hisingen에게 속도를 늦추라고 요청했습니다. 곧 다시 시도합니다. |
| The charger service could not be reached. | 충전기 서비스에 연결할 수 없습니다. |
| The charger service does not know that item. | 충전기 서비스가 해당 항목을 알지 못합니다. |
| The charger service refused the request. | 충전기 서비스가 요청을 거부했습니다. |
| The charger service sent an answer Hisingen could not read. | 충전기 서비스가 Hisingen이 읽을 수 없는 응답을 보냈습니다. |
| The circuit fuse is %@. | 회로 퓨즈는 %@입니다. |
| The limit is set to %@. | 한도는 %@로 설정되어 있습니다. |
| The meter sent no voltage, so 230 V is assumed and power is approximate. | 계량기가 전압을 보내지 않아 230 V로 가정하며 전력은 근사값입니다. |
| The one you use in the %@ app. It is stored in the macOS Keychain and never exported. | %@ 앱에서 사용하는 계정입니다. macOS 키체인에 저장되며 절대 내보내지 않습니다. |
| The saved location in the car where this charger stands. | 이 충전기가 있는 차량에 저장된 위치입니다. |
| The saved token and the charger pairing are deleted. Charging history that was already recorded stays. | 저장된 토큰과 충전기 연동이 삭제됩니다. 이미 기록된 충전 기록은 유지됩니다. |
| This Home Assistant automation uses the charger and may start or stop it. | 이 Home Assistant 자동화가 충전기를 사용하며 시작하거나 중지할 수 있습니다. |
| This account has no charger that Hisingen can control. Check that it is the owner account in the %@ app. | 이 계정에는 Hisingen이 제어할 수 있는 충전기가 없습니다. %@ 앱의 소유자 계정인지 확인하세요. |
| This account has no meter that Hisingen can read. Check that it is the owner account in the Perific app. | 이 계정에는 Hisingen이 읽을 수 있는 계량기가 없습니다. Perific 앱의 소유자 계정인지 확인하세요. |
| This account may not control that charger. | 이 계정은 해당 충전기를 제어할 수 없을 수 있습니다. |
| This account no longer lists the meter | 이 계정은 더 이상 계량기를 표시하지 않습니다 |
| This token could not read the device list, so chargers were found by their entity names. An administrator token also finds the serial number. | 이 토큰은 기기 목록을 읽을 수 없어 엔터티 이름으로 충전기를 찾았습니다. 관리자 토큰은 일련 번호도 찾을 수 있습니다. |
| Three phase | 삼상 |
| Tibber's price includes energy, taxes and its markup but not the grid fee. Add yours here; a paired charger can set its own. | Tibber 가격에는 에너지, 세금, Tibber 마진이 포함되지만 계통 요금은 제외됩니다. 여기에 직접 입력하세요. 연동된 충전기는 자체 요금을 설정할 수 있습니다. |
| Unpair charger | 충전기 연동 해제 |
| Use this meter | 이 계량기 사용 |

### Flagged for this language

- Register: polite formal style (~습니다/~하세요), matching the existing file.
- "부하 분산" for load balancing; Korean charger apps also say "부하 관리".
- "회로 퓨즈" for Circuit Fuse; Korean household wiring usually says "배선 차단기" for the breaker, but the value shown is the fuse rating.
- "상별" phrasing ("per phase"): "상당" also occurs; confirm which reads better to an electrician.
- "자동 조절" for Adaptive (phase mode); "적응형" is an alternative.
- Today's earlier block: "좌석" for Seats reads as "seat"; a spec row may read better as "좌석 수".
- Particles after format specifiers use 이(가)/을(를), standard practice when the argument's final vowel is unknown.

## nb

Confidence: High confidence; the pairing buttons and "Drivtype" deserve a check.


### Today's morning additions (verify as shipped)

| English source | Shipped value |
| --- | --- |
| Volvo moved to a new sign-in system. Sign in again to keep your vehicle data. | Volvo har gått over til et nytt påloggingssystem. Logg inn på nytt for å beholde bildataene dine. |
| Drive Type | Drivtype |
| Engine Power | Motoreffekt |
| Gross Weight | Totalvekt |
| Seats | Seter |
| Last changed %@ | Sist endret %@ |
| %d kW | %d kW |
| %d kg | %d kg |

### Strings translated today (168 keys)

| English source | Shipped value |
| --- | --- |
| %@ accepted the command. Waiting for the charger to confirm. | %@ godtok kommandoen. Venter på at laderen bekrefter. |
| %@ did not accept the saved login | %@ godtok ikke den lagrede innloggingen |
| %@ did not accept the saved login. Enter the account and password again to reconnect. | %@ godtok ikke den lagrede innloggingen. Skriv inn konto og passord på nytt for å koble til igjen. |
| %@ from charger | %@ fra laderen |
| %@ is delaying the start | %@ utsetter starten |
| %@ is unreachable | %@ kan ikke nås |
| %@ per phase | %@ per fase |
| %@ per phase, limit %@ | %@ per fase, grense %@ |
| %@ to the grid | %@ til nettet |
| %@, limited by the cable | %@, begrenset av kabelen |
| %@, limited by the circuit fuse | %@, begrenset av kurssikringen |
| %d charger sessions could not be tied to a vehicle and are kept unassigned. | %d laderøkter kunne ikke knyttes til et kjøretøy og beholdes uten tilknytning. |
| A charger schedule or EcoPilot is active. Turn it off in the NexBlue app so Home Assistant controls the start. | En ladeplan eller EcoPilot er aktiv. Slå den av i NexBlue-appen så Home Assistant styrer starten. |
| A charging schedule is active on the charger. | En ladeplan er aktiv på laderen. |
| A delayed start or EcoPilot is active on the charger. | En forsinket start eller EcoPilot er aktiv på laderen. |
| A shared charger only records a session for this vehicle when the car's own charging overlaps it. | En delt lader registrerer bare en økt for dette kjøretøyet når bilens egen lading overlapper den. |
| Account email | Kontoens e-post |
| Adaptive | Adaptiv |
| Added to Tibber prices in the planner and for charger sessions. | Legges til Tibbers priser i planleggeren og ved prissetting av laderøkter. |
| After an error | Etter en feil |
| At the charger | Ved laderen |
| By an administrator | Av en administrator |
| By schedule | Etter plan |
| Cable Rating | Kabelkapasitet |
| Cable lock | Kabellås |
| Cable unlocked | Kabel låst opp |
| Cable unplugged | Kabel koblet fra |
| Calculated from the meter's current and voltage, so it can read slightly above the energy your supplier bills. | Beregnet ut fra målerens strøm og spenning, så den kan ligge litt over energien leverandøren din fakturerer. |
| Car %@, rest of the house %@ | Bilen %@, resten av huset %@ |
| Charge complete | Lading fullført |
| Charger Details | Laderdetaljer |
| Charger Energy | Laderenergi |
| Charger connection | Ladertilkobling |
| Charger measurement only | Kun ladermåling |
| Charger restarted | Lader startet på nytt |
| Charger updated %@ ago | Laderen ble oppdatert for %@ siden |
| Charger-measured home sessions against the house meter's readings from Perific, %@ to %@. Charging away from home never reaches that meter. | Hjemmeøkter målt av laderen, mot husmålerens avlesninger fra Perific, %@ til %@. Lading borte fra hjemmet når aldri den måleren. |
| Charging at reduced power | Lader med redusert effekt |
| Charging enabled | Lading aktivert |
| Charging is enabled but the car is drawing no power | Lading er aktivert, men bilen trekker ikke strøm |
| Charging state | Ladestatus |
| Charging switch | Ladebryter |
| Charging uses the lowest. The car and load balancing can ask for less. | Ladingen bruker den laveste. Bilen og lastbalanseringen kan be om mindre. |
| Checked %@ | Sjekket %@ |
| Circuit Blue | Racerbaneblå |
| Circuit Fuse | Kurssikring |
| Connect and find chargers | Koble til og finn ladere |
| Connected through | Tilkoblet via |
| Copy custom_components/hisingen_home_charging into your Home Assistant config folder, add hisingen_home_charging: to configuration.yaml and restart. The Home Charging guide in the repository has the steps. | Kopier custom_components/hisingen_home_charging til Home Assistant-konfigurasjonsmappen din, legg til hisingen_home_charging: i configuration.yaml og start på nytt. Home Charging-guiden i repositoriet har trinnene. |
| Current per Phase | Strøm per fase |
| Disconnect Perific | Koble fra Perific |
| Emergency stop | Nødstopp |
| Entities | Entiteter |
| Exported Today | Eksportert i dag |
| Held by load balancing | Holdt tilbake av lastbalansering |
| Hisingen is not signed in to %@ yet. | Hisingen er ikke logget inn på %@ ennå. |
| Home Assistant accepted the command. Waiting for the charger to confirm. | Home Assistant godtok kommandoen. Venter på at laderen bekrefter. |
| Home Assistant stops the plan and leaves the charger as it is. | Home Assistant stopper planen og lar laderen være som den er. |
| Home Charging | Hjemmelading |
| Home charger | Hjemmelader |
| Home charging plan | Hjemmeladingsplan |
| House %@ | Huset %@ |
| House Current per Phase | Husstrøm per fase |
| House Meter | Husmåler |
| House Now | Huset nå |
| House Voltage | Husspenning |
| House meter last read %@ ago | Husmåleren sist lest for %@ siden |
| House sending %@ to the grid | Huset sender %@ til nettet |
| Import sessions now | Importer økter nå |
| Imported Today | Importert i dag |
| Importing | Importerer |
| Last update from %@ %@ | Siste oppdatering fra %@ %@ |
| Load balancing can limit the charger when the house uses more power. | Lastbalansering kan begrense laderen når huset bruker mer strøm. |
| Load balancing is holding the charger. It continues when power is free. | Lastbalanseringen holder laderen tilbake. Ladingen fortsetter når det er ledig effekt. |
| Map by hand | Koble sammen manuelt |
| Measured at the charger, so it includes charging losses. | Målt ved laderen, så tallet omfatter ladetap. |
| Measured from recent charger sessions. It updates when the car charges slower than planned. | Målt ut fra de siste ladeøktene. Tallet oppdateres når bilen lader saktere enn planlagt. |
| Meter | Måler |
| Metered by the charger and read from Home Assistant. Last charger reading %@. | Målt av laderen og lest fra Home Assistant. Siste laderavlesning %@. |
| Metered by the charger and read from the %@ cloud. Last charger reading %@. | Målt av laderen og lest fra %@-skyen. Siste laderavlesning %@. |
| Mobile data | Mobildata |
| Needed to keep charger sessions in Hisingen's local history. | Nødvendig for å beholde laderøkter i Hisingens lokale historikk. |
| NexBlue is delaying the start | NexBlue utsetter starten |
| NexBlue is holding a delayed start | NexBlue holder en forsinket start tilbake |
| NexBlue is holding the start with a delayed start. | NexBlue holder starten tilbake med en forsinket start. |
| No NexBlue charger was found. Map the entities by hand below. | Ingen NexBlue-lader ble funnet. Koble sammen entitetene manuelt nedenfor. |
| No charger is paired. | Ingen lader er koblet sammen. |
| No charging switch is mapped for this charger. | Ingen ladebryter er koblet til denne laderen. |
| No new reading arrived from the charger. | Ingen ny avlesning kom fra laderen. |
| Not authorised | Ikke autorisert |
| Not imported yet | Ikke importert ennå |
| Off: local charging history is disabled | Av: lokal ladehistorikk er slått av |
| On plug-in | Ved tilkobling |
| Only the session total was available, so this is an estimate. | Bare øktens total var tilgjengelig, så dette er et estimat. |
| Optional. Connects a charger that Home Assistant manages, such as NexBlue, to show its status, control it, and record what it measured. | Valgfritt. Kobler til en lader som Home Assistant styrer, for eksempel NexBlue, for å vise status, styre den og registrere det den har målt. |
| Optional. Connects a home charger to show its status, control it, and record what it measured. Easee and Zaptec sign in with their own account. Any other charger works through Home Assistant, such as NexBlue. | Valgfritt. Kobler til en hjemmelader for å vise status, styre den og registrere det den har målt. Easee og Zaptec logger inn med sin egen konto. Alle andre ladere fungerer via Home Assistant, for eksempel NexBlue. |
| Optional. Reads your home's electricity use from a Perific monitor, so charging can be shown against the whole house. Hisingen only reads it. Perific keeps balancing the charger. | Valgfritt. Leser strømforbruket i hjemmet fra en Perific-måler, slik at ladingen kan vises mot hele huset. Hisingen leser bare. Perific fortsetter å balansere laderen. |
| Other cars also use this charger | Andre biler bruker også denne laderen |
| Pair charger | Koble sammen lader |
| Perific account email | Perific-kontoens e-post |
| Perific did not accept the saved login. Enter the account and password again to reconnect. | Perific godtok ikke den lagrede innloggingen. Skriv inn konto og passord på nytt for å koble til igjen. |
| Perific did not accept the saved login. Sign in again in Settings, Electricity. | Perific godtok ikke den lagrede innloggingen. Logg inn på nytt under Innstillinger, Strøm. |
| Phase Mode | Fasemodus |
| Plans run inside Home Assistant. This charger is connected directly, so it offers status, Charge now, Pause and history. | Planer kjører inne i Home Assistant. Denne laderen er koblet til direkte, så den tilbyr status, Lade nå, Pause og historikk. |
| Power loss | Strømbrudd |
| Price source: %@. | Priskilde: %@. |
| Priced per 15-minute interval from the charger's own readings. | Prissett per 15-minutters intervall ut fra laderens egne avlesninger. |
| Reading chargers… | Leser ladere… |
| Reading every 30 seconds | Avlesning hvert 30. sekund |
| Remotely | Fjernstyrt |
| Reported %@ | Rapportert %@ |
| Resume | Fortsett |
| Sending the pause command to %@ | Sender pausekommandoen til %@ |
| Sending the start command to %@ | Sender startkommandoen til %@ |
| Session history | Økthistorikk |
| Sessions and plans are tied to this vehicle only. A car being near the charger is not enough. | Økter og planer knyttes kun til dette kjøretøyet. At en bil står nær laderen, er ikke nok. |
| Sessions are tied to this vehicle only. A car being near the charger is not enough. | Økter knyttes kun til dette kjøretøyet. At en bil står nær laderen, er ikke nok. |
| Shared charger | Delt lader |
| Sign in | Logg inn |
| Sign in again in Settings. | Logg inn på nytt i Innstillinger. |
| Sign in and find chargers | Logg inn og finn ladere |
| Sign in and find meters | Logg inn og finn målere |
| Sign in to %@ again | Logg inn på %@ på nytt |
| Sign out | Logg ut |
| Sign-in refused | Innlogging nektet |
| Sign-in rejected | Innlogging avvist |
| Signed in to %@ | Logget inn på %@ |
| Signing in… | Logger inn… |
| Single phase | Enfase |
| Source | Kilde |
| Still needed: %@. | Mangler fortsatt: %@. |
| The account or password was not accepted. | Kontoen eller passordet ble ikke godtatt. |
| The account you use in the Perific app. It is stored in the macOS Keychain and never exported. | Kontoen du bruker i Perific-appen. Den lagres i macOS nøkkelknippe og eksporteres aldri. |
| The cable allows %@. | Kabelen tillater %@. |
| The charger command was rejected | Laderkommandoen ble avvist |
| The charger did not confirm the last command. | Laderen bekreftet ikke den siste kommandoen. |
| The charger has not confirmed the command | Laderen har ikke bekreftet kommandoen |
| The charger has not reported recently | Laderen har ikke rapportert i det siste |
| The charger is unavailable in %@ | Laderen er utilgjengelig i %@ |
| The charger is unavailable in Home Assistant | Laderen er utilgjengelig i Home Assistant |
| The charger is unavailable in Home Assistant. | Laderen er utilgjengelig i Home Assistant. |
| The charger kept its previous state. Try again, or check the charger. | Laderen beholdt sin forrige tilstand. Prøv igjen, eller sjekk laderen. |
| The charger readings below are the last ones received. | Avlesningene nedenfor er de siste som er mottatt fra laderen. |
| The charger recorded this session while no battery reading was available, so there is no battery-side estimate. | Laderen registrerte denne økten mens ingen batteriavlesning var tilgjengelig, så det finnes ikke noe estimat fra batterisiden. |
| The charger reported an error after the command. | Laderen rapporterte en feil etter kommandoen. |
| The charger reports about once a minute. | Laderen rapporterer omtrent en gang i minuttet. |
| The charger reports an error | Laderen rapporterer en feil |
| The charger service asked Hisingen to slow down. It will try again shortly. | Ladertjenesten ba Hisingen om å ta det med ro. Den prøver igjen om kort tid. |
| The charger service could not be reached. | Ladertjenesten kunne ikke nås. |
| The charger service does not know that item. | Ladertjenesten kjenner ikke det elementet. |
| The charger service refused the request. | Ladertjenesten avviste forespørselen. |
| The charger service sent an answer Hisingen could not read. | Ladertjenesten sendte et svar Hisingen ikke kunne lese. |
| The circuit fuse is %@. | Kurssikringen er %@. |
| The limit is set to %@. | Grensen er satt til %@. |
| The meter sent no voltage, so 230 V is assumed and power is approximate. | Måleren sendte ingen spenning, så 230 V er antatt og effekten er omtrentlig. |
| The one you use in the %@ app. It is stored in the macOS Keychain and never exported. | Den du bruker i %@-appen. Den lagres i macOS nøkkelknippe og eksporteres aldri. |
| The saved location in the car where this charger stands. | Den lagrede plasseringen i bilen der denne laderen står. |
| The saved token and the charger pairing are deleted. Charging history that was already recorded stays. | Det lagrede tokenet og laderkoblingen slettes. Ladehistorikk som allerede er registrert, blir værende. |
| This Home Assistant automation uses the charger and may start or stop it. | Denne Home Assistant-automatiseringen bruker laderen og kan starte eller stoppe den. |
| This account has no charger that Hisingen can control. Check that it is the owner account in the %@ app. | Denne kontoen har ingen lader Hisingen kan styre. Sjekk at det er eierkontoen i %@-appen. |
| This account has no meter that Hisingen can read. Check that it is the owner account in the Perific app. | Denne kontoen har ingen måler Hisingen kan lese. Sjekk at det er eierkontoen i Perific-appen. |
| This account may not control that charger. | Denne kontoen kan mangle tillatelse til å styre den laderen. |
| This account no longer lists the meter | Denne kontoen viser ikke lenger måleren |
| This token could not read the device list, so chargers were found by their entity names. An administrator token also finds the serial number. | Dette tokenet kunne ikke lese enhetslisten, så laderne ble funnet etter entitetsnavnene sine. Et administrator-token finner også serienummeret. |
| Three phase | Trefase |
| Tibber's price includes energy, taxes and its markup but not the grid fee. Add yours here; a paired charger can set its own. | Tibbers pris inneholder energi, avgifter og egen margin, men ikke nettleien. Legg inn din her; en koblet lader kan angi sin egen. |
| Unpair charger | Koble fra lader |
| Use this meter | Bruk denne måleren |

### Flagged for this language

- Pair charger / Unpair charger uses "Koble sammen lader" / "Koble fra lader"; confirm these buttons read naturally.
- "Racerbaneblå" is a coined theme name for Circuit Blue, matching "Mesterskapsblå" in its subtitle.
- Today's earlier block: "Drivtype" for Drive Type; Norwegian car specs also say "drivverk" or "trekk".
- "Kurssikring" assumes the household circuit term "kurs".

## nl

Confidence: High confidence; je-register matches the file. Whether to keep English "load balancing" is a real call.


### Today's morning additions (verify as shipped)

| English source | Shipped value |
| --- | --- |
| Volvo moved to a new sign-in system. Sign in again to keep your vehicle data. | Volvo is overgestapt op een nieuw aanmeldsysteem. Meld je opnieuw aan om je voertuiggegevens te behouden. |
| Drive Type | Aandrijving |
| Engine Power | Motorvermogen |
| Gross Weight | Totaalgewicht |
| Seats | Zitplaatsen |
| Last changed %@ | Laatst gewijzigd %@ |
| %d kW | %d kW |
| %d kg | %d kg |

### Strings translated today (168 keys)

| English source | Shipped value |
| --- | --- |
| %@ accepted the command. Waiting for the charger to confirm. | %@ heeft de opdracht geaccepteerd. Wachten op bevestiging van de lader. |
| %@ did not accept the saved login | %@ heeft de opgeslagen aanmelding niet geaccepteerd |
| %@ did not accept the saved login. Enter the account and password again to reconnect. | %@ heeft de opgeslagen aanmelding niet geaccepteerd. Voer het account en wachtwoord opnieuw in om opnieuw te verbinden. |
| %@ from charger | %@ van de lader |
| %@ is delaying the start | %@ stelt de start uit |
| %@ is unreachable | %@ is onbereikbaar |
| %@ per phase | %@ per fase |
| %@ per phase, limit %@ | %@ per fase, limiet %@ |
| %@ to the grid | %@ naar het net |
| %@, limited by the cable | %@, begrensd door de kabel |
| %@, limited by the circuit fuse | %@, begrensd door de groepszekering |
| %d charger sessions could not be tied to a vehicle and are kept unassigned. | %d laadsessies konden niet aan een voertuig worden gekoppeld en blijven zonder toewijzing. |
| A charger schedule or EcoPilot is active. Turn it off in the NexBlue app so Home Assistant controls the start. | Er staat een laadschema of EcoPilot actief. Schakel het uit in de NexBlue-app zodat Home Assistant de start regelt. |
| A charging schedule is active on the charger. | Er staat een laadschema actief op de lader. |
| A delayed start or EcoPilot is active on the charger. | Er staat een vertraagde start of EcoPilot actief op de lader. |
| A shared charger only records a session for this vehicle when the car's own charging overlaps it. | Een gedeelde lader legt alleen een sessie voor dit voertuig vast wanneer het eigen laden van de auto ermee overlapt. |
| Account email | E-mailadres van account |
| Adaptive | Adaptief |
| Added to Tibber prices in the planner and for charger sessions. | Wordt toegevoegd aan Tibber-prijzen in de planner en bij laadsessies. |
| After an error | Na een fout |
| At the charger | Bij de lader |
| By an administrator | Door een beheerder |
| By schedule | Volgens schema |
| Cable Rating | Kabelcapaciteit |
| Cable lock | Kabelvergrendeling |
| Cable unlocked | Kabel ontgrendeld |
| Cable unplugged | Kabel losgekoppeld |
| Calculated from the meter's current and voltage, so it can read slightly above the energy your supplier bills. | Berekend uit stroom en spanning van de meter, dus het kan iets hoger uitvallen dan de energie die je leverancier factureert. |
| Car %@, rest of the house %@ | Auto %@, rest van het huis %@ |
| Charge complete | Laden voltooid |
| Charger Details | Laderdetails |
| Charger Energy | Laderenergie |
| Charger connection | Laderverbinding |
| Charger measurement only | Alleen ladermeting |
| Charger restarted | Lader herstart |
| Charger updated %@ ago | Lader %@ geleden bijgewerkt |
| Charger-measured home sessions against the house meter's readings from Perific, %@ to %@. Charging away from home never reaches that meter. | Thuislaadsessies gemeten door de lader, afgezet tegen de metingen van de huismeter uit Perific, %@ tot %@. Laden buiten huis komt nooit bij die meter. |
| Charging at reduced power | Laden met verminderd vermogen |
| Charging enabled | Laden ingeschakeld |
| Charging is enabled but the car is drawing no power | Laden is ingeschakeld, maar de auto trekt geen stroom |
| Charging state | Laadstatus |
| Charging switch | Laadschakelaar |
| Charging uses the lowest. The car and load balancing can ask for less. | Het laden gebruikt de laagste. De auto en lastverdeling kunnen om minder vragen. |
| Checked %@ | Gecontroleerd %@ |
| Circuit Blue | Circuitblauw |
| Circuit Fuse | Groepszekering |
| Connect and find chargers | Verbinden en laders zoeken |
| Connected through | Verbonden via |
| Copy custom_components/hisingen_home_charging into your Home Assistant config folder, add hisingen_home_charging: to configuration.yaml and restart. The Home Charging guide in the repository has the steps. | Kopieer custom_components/hisingen_home_charging naar de configuratiemap van Home Assistant, voeg hisingen_home_charging: toe aan configuration.yaml en herstart. De stappen staan in de Home Charging-handleiding in de repository. |
| Current per Phase | Stroom per fase |
| Disconnect Perific | Perific ontkoppelen |
| Emergency stop | Noodstop |
| Entities | Entiteiten |
| Exported Today | Vandaag geëxporteerd |
| Held by load balancing | Vastgehouden door lastverdeling |
| Hisingen is not signed in to %@ yet. | Hisingen is nog niet aangemeld bij %@. |
| Home Assistant accepted the command. Waiting for the charger to confirm. | Home Assistant heeft de opdracht geaccepteerd. Wachten op bevestiging van de lader. |
| Home Assistant stops the plan and leaves the charger as it is. | Home Assistant stopt het plan en laat de lader zoals hij is. |
| Home Charging | Thuisladen |
| Home charger | Thuislader |
| Home charging plan | Thuislaadplan |
| House %@ | Huis %@ |
| House Current per Phase | Huisstroom per fase |
| House Meter | Huismeter |
| House Now | Huis nu |
| House Voltage | Huisspanning |
| House meter last read %@ ago | Huismeter %@ geleden voor het laatst uitgelezen |
| House sending %@ to the grid | Huis stuurt %@ naar het net |
| Import sessions now | Sessies nu importeren |
| Imported Today | Vandaag geïmporteerd |
| Importing | Importeren |
| Last update from %@ %@ | Laatste update van %@ %@ |
| Load balancing can limit the charger when the house uses more power. | Lastverdeling kan de lader beperken wanneer het huis meer stroom verbruikt. |
| Load balancing is holding the charger. It continues when power is free. | Lastverdeling houdt de lader tegen. Het laden gaat verder wanneer er vermogen vrij is. |
| Map by hand | Handmatig koppelen |
| Measured at the charger, so it includes charging losses. | Gemeten aan de lader, dus inclusief laadverliezen. |
| Measured from recent charger sessions. It updates when the car charges slower than planned. | Gemeten uit recente laadsessies. De waarde wordt bijgewerkt wanneer de auto langzamer laadt dan gepland. |
| Meter | Meter |
| Metered by the charger and read from Home Assistant. Last charger reading %@. | Gemeten door de lader en uitgelezen uit Home Assistant. Laatste ladermeting %@. |
| Metered by the charger and read from the %@ cloud. Last charger reading %@. | Gemeten door de lader en uitgelezen uit de %@-cloud. Laatste ladermeting %@. |
| Mobile data | Mobiele data |
| Needed to keep charger sessions in Hisingen's local history. | Nodig om laadsessies van de lader te bewaren in Hisingens lokale geschiedenis. |
| NexBlue is delaying the start | NexBlue stelt de start uit |
| NexBlue is holding a delayed start | NexBlue houdt een vertraagde start tegen |
| NexBlue is holding the start with a delayed start. | NexBlue houdt de start tegen met een vertraagde start. |
| No NexBlue charger was found. Map the entities by hand below. | Geen NexBlue-lader gevonden. Koppel de entiteiten hieronder handmatig. |
| No charger is paired. | Er is geen lader gekoppeld. |
| No charging switch is mapped for this charger. | Voor deze lader is geen laadschakelaar gekoppeld. |
| No new reading arrived from the charger. | Er is geen nieuwe meting van de lader binnengekomen. |
| Not authorised | Niet geautoriseerd |
| Not imported yet | Nog niet geïmporteerd |
| Off: local charging history is disabled | Uit: lokale laadgeschiedenis is uitgeschakeld |
| On plug-in | Bij insteken |
| Only the session total was available, so this is an estimate. | Alleen het sessietotaal was beschikbaar, dus dit is een schatting. |
| Optional. Connects a charger that Home Assistant manages, such as NexBlue, to show its status, control it, and record what it measured. | Optioneel. Verbindt een lader die Home Assistant beheert, zoals NexBlue, om de status te tonen, hem te bedienen en vast te leggen wat hij heeft gemeten. |
| Optional. Connects a home charger to show its status, control it, and record what it measured. Easee and Zaptec sign in with their own account. Any other charger works through Home Assistant, such as NexBlue. | Optioneel. Verbindt een thuislader om de status te tonen, hem te bedienen en vast te leggen wat hij heeft gemeten. Easee en Zaptec melden zich aan met hun eigen account. Elke andere lader werkt via Home Assistant, zoals NexBlue. |
| Optional. Reads your home's electricity use from a Perific monitor, so charging can be shown against the whole house. Hisingen only reads it. Perific keeps balancing the charger. | Optioneel. Leest het stroomverbruik van je huis uit een Perific-monitor, zodat het laden afgezet kan worden tegen het hele huis. Hisingen leest alleen uit. Perific blijft de lader balanceren. |
| Other cars also use this charger | Andere auto's gebruiken deze lader ook |
| Pair charger | Koppel lader |
| Perific account email | E-mailadres van Perific-account |
| Perific did not accept the saved login. Enter the account and password again to reconnect. | Perific heeft de opgeslagen aanmelding niet geaccepteerd. Voer het account en wachtwoord opnieuw in om opnieuw te verbinden. |
| Perific did not accept the saved login. Sign in again in Settings, Electricity. | Perific heeft de opgeslagen aanmelding niet geaccepteerd. Meld je opnieuw aan in Instellingen, Elektriciteit. |
| Phase Mode | Fasemodus |
| Plans run inside Home Assistant. This charger is connected directly, so it offers status, Charge now, Pause and history. | Plannen draaien binnen Home Assistant. Deze lader is rechtstreeks verbonden en biedt daarom status, Nu laden, Pauze en geschiedenis. |
| Power loss | Stroomuitval |
| Price source: %@. | Prijsbron: %@. |
| Priced per 15-minute interval from the charger's own readings. | Geprijsd per interval van 15 minuten uit de eigen metingen van de lader. |
| Reading chargers… | Laders uitlezen… |
| Reading every 30 seconds | Uitlezing elke 30 seconden |
| Remotely | Op afstand |
| Reported %@ | Gerapporteerd %@ |
| Resume | Hervatten |
| Sending the pause command to %@ | Pauzeopdracht wordt naar %@ gestuurd |
| Sending the start command to %@ | Startopdracht wordt naar %@ gestuurd |
| Session history | Sessiegeschiedenis |
| Sessions and plans are tied to this vehicle only. A car being near the charger is not enough. | Sessies en plannen zijn alleen aan dit voertuig gekoppeld. Dat een auto dicht bij de lader staat, is niet genoeg. |
| Sessions are tied to this vehicle only. A car being near the charger is not enough. | Sessies zijn alleen aan dit voertuig gekoppeld. Dat een auto dicht bij de lader staat, is niet genoeg. |
| Shared charger | Gedeelde lader |
| Sign in | Aanmelden |
| Sign in again in Settings. | Meld je opnieuw aan in Instellingen. |
| Sign in and find chargers | Aanmelden en laders zoeken |
| Sign in and find meters | Aanmelden en meters zoeken |
| Sign in to %@ again | Meld je opnieuw aan bij %@ |
| Sign out | Afmelden |
| Sign-in refused | Aanmelding geweigerd |
| Sign-in rejected | Aanmelding afgewezen |
| Signed in to %@ | Aangemeld bij %@ |
| Signing in… | Aanmelden… |
| Single phase | Eenfase |
| Source | Bron |
| Still needed: %@. | Nog nodig: %@. |
| The account or password was not accepted. | Het account of wachtwoord is niet geaccepteerd. |
| The account you use in the Perific app. It is stored in the macOS Keychain and never exported. | Het account dat je gebruikt in de Perific-app. Het wordt bewaard in de macOS-sleutelhanger en nooit geëxporteerd. |
| The cable allows %@. | De kabel laat %@ toe. |
| The charger command was rejected | De opdracht aan de lader is geweigerd |
| The charger did not confirm the last command. | De lader heeft de laatste opdracht niet bevestigd. |
| The charger has not confirmed the command | De lader heeft de opdracht niet bevestigd |
| The charger has not reported recently | De lader heeft recent niets gerapporteerd |
| The charger is unavailable in %@ | De lader is niet beschikbaar in %@ |
| The charger is unavailable in Home Assistant | De lader is niet beschikbaar in Home Assistant |
| The charger is unavailable in Home Assistant. | De lader is niet beschikbaar in Home Assistant. |
| The charger kept its previous state. Try again, or check the charger. | De lader behield zijn vorige staat. Probeer het opnieuw, of controleer de lader. |
| The charger readings below are the last ones received. | De metingen hieronder zijn de laatst ontvangen metingen van de lader. |
| The charger recorded this session while no battery reading was available, so there is no battery-side estimate. | De lader heeft deze sessie opgenomen toen er geen batterijmeting beschikbaar was, dus er is geen schatting vanaf de batterijkant. |
| The charger reported an error after the command. | De lader heeft na de opdracht een fout gerapporteerd. |
| The charger reports about once a minute. | De lader rapporteert ongeveer één keer per minuut. |
| The charger reports an error | De lader rapporteert een fout |
| The charger service asked Hisingen to slow down. It will try again shortly. | De laderservice heeft Hisingen gevraagd het rustiger aan te doen. Er wordt binnenkort opnieuw geprobeerd. |
| The charger service could not be reached. | De laderservice is niet bereikbaar. |
| The charger service does not know that item. | De laderservice kent dat item niet. |
| The charger service refused the request. | De laderservice heeft het verzoek geweigerd. |
| The charger service sent an answer Hisingen could not read. | De laderservice stuurde een antwoord dat Hisingen niet kon lezen. |
| The circuit fuse is %@. | De groepszekering is %@. |
| The limit is set to %@. | De limiet staat op %@. |
| The meter sent no voltage, so 230 V is assumed and power is approximate. | De meter heeft geen spanning gestuurd, dus 230 V wordt aangenomen en het vermogen is bij benadering. |
| The one you use in the %@ app. It is stored in the macOS Keychain and never exported. | Degene die je gebruikt in de %@-app. Hij wordt bewaard in de macOS-sleutelhanger en nooit geëxporteerd. |
| The saved location in the car where this charger stands. | De opgeslagen locatie in de auto waar deze lader staat. |
| The saved token and the charger pairing are deleted. Charging history that was already recorded stays. | Het opgeslagen token en de koppeling met de lader worden verwijderd. Al vastgelegde laadgeschiedenis blijft bewaard. |
| This Home Assistant automation uses the charger and may start or stop it. | Deze Home Assistant-automatisering gebruikt de lader en kan hem starten of stoppen. |
| This account has no charger that Hisingen can control. Check that it is the owner account in the %@ app. | Dit account heeft geen lader die Hisingen kan bedienen. Controleer of het het eigenaarsaccount in de %@-app is. |
| This account has no meter that Hisingen can read. Check that it is the owner account in the Perific app. | Dit account heeft geen meter die Hisingen kan uitlezen. Controleer of het het eigenaarsaccount in de Perific-app is. |
| This account may not control that charger. | Dit account mag die lader mogelijk niet bedienen. |
| This account no longer lists the meter | Dit account toont de meter niet langer |
| This token could not read the device list, so chargers were found by their entity names. An administrator token also finds the serial number. | Dit token kon de apparaatlijst niet lezen, dus de laders zijn gevonden via hun entiteitsnamen. Een beheerderstoken vindt ook het serienummer. |
| Three phase | Driefase |
| Tibber's price includes energy, taxes and its markup but not the grid fee. Add yours here; a paired charger can set its own. | De prijs van Tibber omvat energie, belastingen en eigen marge, maar niet het nettarief. Voer het jouwe hier in; een gekoppelde lader kan een eigen tarief instellen. |
| Unpair charger | Ontkoppel lader |
| Use this meter | Deze meter gebruiken |

### Flagged for this language

- Register: informal je throughout, matching the existing file.
- "Circuitblauw" for Circuit Blue, matching "Kampioenschapsblauw" in its subtitle.
- "Lastverdeling" for load balancing; Dutch charger makers often keep "load balancing" in English. Confirm.
- "Groepszekering" for Circuit Fuse (Dutch household circuits are "groepen").

## nn

Confidence: Least sure of the whole batch. Grammar follows the file's Nynorsk, but every coined compound needs a Nynorsk native.


### Today's morning additions (verify as shipped)

| English source | Shipped value |
| --- | --- |
| Volvo moved to a new sign-in system. Sign in again to keep your vehicle data. | Volvo har gått over til eit nytt påloggingssystem. Logg inn på nytt for å behalde bildata dine. |
| Drive Type | Drivtype |
| Engine Power | Motoreffekt |
| Gross Weight | Totalvekt |
| Seats | Seter |
| Last changed %@ | Sist endra %@ |
| %d kW | %d kW |
| %d kg | %d kg |

### Strings translated today (168 keys)

| English source | Shipped value |
| --- | --- |
| %@ accepted the command. Waiting for the charger to confirm. | %@ godtok kommandoen. Ventar på at ladaren stadfestar. |
| %@ did not accept the saved login | %@ godtok ikkje den lagra innlogginga |
| %@ did not accept the saved login. Enter the account and password again to reconnect. | %@ godtok ikkje den lagra innlogginga. Skriv inn konto og passord på nytt for å kople til att. |
| %@ from charger | %@ frå ladaren |
| %@ is delaying the start | %@ utset starten |
| %@ is unreachable | %@ kan ikkje nåast |
| %@ per phase | %@ per fase |
| %@ per phase, limit %@ | %@ per fase, grense %@ |
| %@ to the grid | %@ til nettet |
| %@, limited by the cable | %@, avgrensa av kabelen |
| %@, limited by the circuit fuse | %@, avgrensa av kurssikringa |
| %d charger sessions could not be tied to a vehicle and are kept unassigned. | %d ladarøkter kunne ikkje knytast til eit køyretøy og vert haldne utan tilkopling. |
| A charger schedule or EcoPilot is active. Turn it off in the NexBlue app so Home Assistant controls the start. | Ein ladeplan eller EcoPilot er aktiv. Slå han av i NexBlue-appen så Home Assistant styrer starten. |
| A charging schedule is active on the charger. | Ein ladeplan er aktiv på ladaren. |
| A delayed start or EcoPilot is active on the charger. | Ein forsinka start eller EcoPilot er aktiv på ladaren. |
| A shared charger only records a session for this vehicle when the car's own charging overlaps it. | Ein delt ladar registrerer berre ei økt for dette køyretøyet når bilen si eiga lading overlappar han. |
| Account email | E-post til kontoen |
| Adaptive | Adaptiv |
| Added to Tibber prices in the planner and for charger sessions. | Vert lagt til Tibber-prisane i planleggjaren og ved prissetting av ladarøkter. |
| After an error | Etter ein feil |
| At the charger | Ved ladaren |
| By an administrator | Av ein administrator |
| By schedule | Etter plan |
| Cable Rating | Kabelkapasitet |
| Cable lock | Kabellås |
| Cable unlocked | Kabel låst opp |
| Cable unplugged | Kabel kopla frå |
| Calculated from the meter's current and voltage, so it can read slightly above the energy your supplier bills. | Rekna ut frå målaren sin straum og spenning, så han kan liggja litt over energien leverandøren din fakturerer. |
| Car %@, rest of the house %@ | Bilen %@, resten av huset %@ |
| Charge complete | Lading fullført |
| Charger Details | Ladardetaljar |
| Charger Energy | Ladarenergi |
| Charger connection | Ladartilkopling |
| Charger measurement only | Berre ladarmåling |
| Charger restarted | Ladar starta på nytt |
| Charger updated %@ ago | Ladaren vart oppdatert for %@ siden |
| Charger-measured home sessions against the house meter's readings from Perific, %@ to %@. Charging away from home never reaches that meter. | Heimeøkter målt av ladaren, mot husmålaren sine avlesingar frå Perific, %@ til %@. Lading borte frå heimen når aldri den målaren. |
| Charging at reduced power | Ladar med redusert effekt |
| Charging enabled | Lading aktivert |
| Charging is enabled but the car is drawing no power | Lading er aktivert, men bilen dreg ikkje straum |
| Charging state | Ladestatus |
| Charging switch | Ladebrytar |
| Charging uses the lowest. The car and load balancing can ask for less. | Ladinga brukar den lågaste. Bilen og lastbalanseringa kan be om mindre. |
| Checked %@ | Sjekka %@ |
| Circuit Blue | Racerbaneblå |
| Circuit Fuse | Kurssikring |
| Connect and find chargers | Kople til og finn ladare |
| Connected through | Tilkopla via |
| Copy custom_components/hisingen_home_charging into your Home Assistant config folder, add hisingen_home_charging: to configuration.yaml and restart. The Home Charging guide in the repository has the steps. | Kopier custom_components/hisingen_home_charging til Home Assistant-konfigurasjonsmappen din, legg til hisingen_home_charging: i configuration.yaml og start på nytt. Home Charging-guiden i repositoriet har stega. |
| Current per Phase | Straum per fase |
| Disconnect Perific | Kopl frå Perific |
| Emergency stop | Nødstopp |
| Entities | Entitetar |
| Exported Today | Eksportert i dag |
| Held by load balancing | Heldt tilbake av lastbalansering |
| Hisingen is not signed in to %@ yet. | Hisingen er ikkje logga inn på %@ ennå. |
| Home Assistant accepted the command. Waiting for the charger to confirm. | Home Assistant godtok kommandoen. Ventar på at ladaren stadfestar. |
| Home Assistant stops the plan and leaves the charger as it is. | Home Assistant stoppar planen og let ladaren vera som han er. |
| Home Charging | Heimelading |
| Home charger | Heimeladar |
| Home charging plan | Heimeladingsplan |
| House %@ | Huset %@ |
| House Current per Phase | Husstraum per fase |
| House Meter | Husmålar |
| House Now | Huset no |
| House Voltage | Husspenning |
| House meter last read %@ ago | Husmålaren sist lesen for %@ siden |
| House sending %@ to the grid | Huset sender %@ til nettet |
| Import sessions now | Importer økter no |
| Imported Today | Importert i dag |
| Importing | Importerer |
| Last update from %@ %@ | Siste oppdatering frå %@ %@ |
| Load balancing can limit the charger when the house uses more power. | Lastbalansering kan avgrense ladaren når huset brukar meir straum. |
| Load balancing is holding the charger. It continues when power is free. | Lastbalanseringa held ladaren tilbake. Ladinga held fram når det er ledig effekt. |
| Map by hand | Kobl saman manuelt |
| Measured at the charger, so it includes charging losses. | Målt ved ladaren, så talet omfattar ladetap. |
| Measured from recent charger sessions. It updates when the car charges slower than planned. | Målt ut frå dei siste ladeøktene. Talet vert oppdatert når bilen ladar saktare enn planlagt. |
| Meter | Målar |
| Metered by the charger and read from Home Assistant. Last charger reading %@. | Målt av ladaren og lesen frå Home Assistant. Siste ladaravlesing %@. |
| Metered by the charger and read from the %@ cloud. Last charger reading %@. | Målt av ladaren og lesen frå %@-skya. Siste ladaravlesing %@. |
| Mobile data | Mobildata |
| Needed to keep charger sessions in Hisingen's local history. | Nødvendig for å behalda ladarøkter i Hisingen sin lokale historikk. |
| NexBlue is delaying the start | NexBlue utset starten |
| NexBlue is holding a delayed start | NexBlue held ein forsinka start tilbake |
| NexBlue is holding the start with a delayed start. | NexBlue held starten tilbake med ein forsinka start. |
| No NexBlue charger was found. Map the entities by hand below. | Ingen NexBlue-ladar vart funnen. Kobl saman entitetane manuelt nedanfor. |
| No charger is paired. | Ingen ladar er kobla saman. |
| No charging switch is mapped for this charger. | Ingen ladebrytar er kopla til denne ladaren. |
| No new reading arrived from the charger. | Ingen ny avlesing kom frå ladaren. |
| Not authorised | Ikkje autorisert |
| Not imported yet | Ikkje importert ennå |
| Off: local charging history is disabled | Av: lokal ladehistorikk er slått av |
| On plug-in | Ved tilkopling |
| Only the session total was available, so this is an estimate. | Berre økta sitt total var tilgjengeleg, så dette er eit estimat. |
| Optional. Connects a charger that Home Assistant manages, such as NexBlue, to show its status, control it, and record what it measured. | Valfritt. Kopl til ein ladar som Home Assistant styrer, til dømes NexBlue, for å visa status, styra han og registrera det han har målt. |
| Optional. Connects a home charger to show its status, control it, and record what it measured. Easee and Zaptec sign in with their own account. Any other charger works through Home Assistant, such as NexBlue. | Valfritt. Kopl til ein heimeladar for å visa status, styra han og registrera det han har målt. Easee og Zaptec loggar inn med sin eigen konto. Alle andre ladare fungerer via Home Assistant, til dømes NexBlue. |
| Optional. Reads your home's electricity use from a Perific monitor, so charging can be shown against the whole house. Hisingen only reads it. Perific keeps balancing the charger. | Valfritt. Les straumforbruket i heimen frå ein Perific-målar, slik at ladinga kan visast mot heile huset. Hisingen les berre. Perific held fram med å balansera ladaren. |
| Other cars also use this charger | Andre biler brukar òg denne ladaren |
| Pair charger | Kobl saman ladar |
| Perific account email | E-post til Perific-kontoen |
| Perific did not accept the saved login. Enter the account and password again to reconnect. | Perific godtok ikkje den lagra innlogginga. Skriv inn konto og passord på nytt for å kople til att. |
| Perific did not accept the saved login. Sign in again in Settings, Electricity. | Perific godtok ikkje den lagra innlogginga. Logg inn på nytt under Innstillingane, Straum. |
| Phase Mode | Fasemodus |
| Plans run inside Home Assistant. This charger is connected directly, so it offers status, Charge now, Pause and history. | Planar køyrer inne i Home Assistant. Denne ladaren er kopla til direkte, så han tilbyr status, Lad no, Pause og historikk. |
| Power loss | Straumbrot |
| Price source: %@. | Priskjelde: %@. |
| Priced per 15-minute interval from the charger's own readings. | Prissett per 15-minutters intervall ut frå ladaren sine eigne avlesingar. |
| Reading chargers… | Les ladare… |
| Reading every 30 seconds | Avlesing kvart 30. sekund |
| Remotely | Fjernstyrt |
| Reported %@ | Rapportert %@ |
| Resume | Hald fram |
| Sending the pause command to %@ | Sender pausekommandoen til %@ |
| Sending the start command to %@ | Sender startkommandoen til %@ |
| Session history | Økthistorikk |
| Sessions and plans are tied to this vehicle only. A car being near the charger is not enough. | Økter og planar er berre knytte til dette køyretøyet. At ein bil står nær ladaren, er ikkje nok. |
| Sessions are tied to this vehicle only. A car being near the charger is not enough. | Økter er berre knytte til dette køyretøyet. At ein bil står nær ladaren, er ikkje nok. |
| Shared charger | Delt ladar |
| Sign in | Logg inn |
| Sign in again in Settings. | Logg inn på nytt i Innstillingane. |
| Sign in and find chargers | Logg inn og finn ladare |
| Sign in and find meters | Logg inn og finn målarar |
| Sign in to %@ again | Logg inn på %@ på nytt |
| Sign out | Logg ut |
| Sign-in refused | Innlogging nekta |
| Sign-in rejected | Innlogging avvist |
| Signed in to %@ | Logga inn på %@ |
| Signing in… | Loggar inn… |
| Single phase | Enfase |
| Source | Kjelde |
| Still needed: %@. | Manglar framleis: %@. |
| The account or password was not accepted. | Kontoen eller passordet vart ikkje godteke. |
| The account you use in the Perific app. It is stored in the macOS Keychain and never exported. | Kontoen du brukar i Perific-appen. Han vert lagra i macOS Nykkelring og eksporterast aldri. |
| The cable allows %@. | Kabelen tillèt %@. |
| The charger command was rejected | Ladarkommandoen vart avvist |
| The charger did not confirm the last command. | Ladaren stadfesta ikkje den siste kommandoen. |
| The charger has not confirmed the command | Ladaren har ikkje stadfesta kommandoen |
| The charger has not reported recently | Ladaren har ikkje rapportert i det siste |
| The charger is unavailable in %@ | Ladaren er utilgjengeleg i %@ |
| The charger is unavailable in Home Assistant | Ladaren er utilgjengeleg i Home Assistant |
| The charger is unavailable in Home Assistant. | Ladaren er utilgjengeleg i Home Assistant. |
| The charger kept its previous state. Try again, or check the charger. | Ladaren behald den tidlegare tilstanden sin. Prøv igjen, eller sjekk ladaren. |
| The charger readings below are the last ones received. | Avlesingane nedanfor er dei siste som er mottekne frå ladaren. |
| The charger recorded this session while no battery reading was available, so there is no battery-side estimate. | Ladaren registrerte denne økta medan ingen batteriavlesing var tilgjengeleg, så det finst ikkje noko estimat frå batterisida. |
| The charger reported an error after the command. | Ladaren rapporterte ein feil etter kommandoen. |
| The charger reports about once a minute. | Ladaren rapporterer om lag ein gong i minuttet. |
| The charger reports an error | Ladaren rapporterer ein feil |
| The charger service asked Hisingen to slow down. It will try again shortly. | Ladartenesta bad Hisingen om å ta det med ro. Han prøver igjen om kort tid. |
| The charger service could not be reached. | Ladartenesta kunne ikkje nåast. |
| The charger service does not know that item. | Ladartenesta kjenner ikkje det elementet. |
| The charger service refused the request. | Ladartenesta avviste førespurnaden. |
| The charger service sent an answer Hisingen could not read. | Ladartenesta sendte eit svar Hisingen ikkje kunne lesa. |
| The circuit fuse is %@. | Kurssikringa er %@. |
| The limit is set to %@. | Grensa er sett til %@. |
| The meter sent no voltage, so 230 V is assumed and power is approximate. | Målaren sende ingen spenning, så 230 V er rekna med og effekta er omtrentleg. |
| The one you use in the %@ app. It is stored in the macOS Keychain and never exported. | Den du brukar i %@-appen. Han vert lagra i macOS Nykkelring og eksporterast aldri. |
| The saved location in the car where this charger stands. | Den lagra plasseringa i bilen der denne ladaren står. |
| The saved token and the charger pairing are deleted. Charging history that was already recorded stays. | Det lagra tokenet og ladarkoblinga vert sletta. Ladehistorikk som alt er registrert, blir verande. |
| This Home Assistant automation uses the charger and may start or stop it. | Denne Home Assistant-automatiseringa brukar ladaren og kan starta eller stoppa han. |
| This account has no charger that Hisingen can control. Check that it is the owner account in the %@ app. | Denne kontoen har ingen ladar Hisingen kan styra. Sjekk at det er eierkontoen i %@-appen. |
| This account has no meter that Hisingen can read. Check that it is the owner account in the Perific app. | Denne kontoen har ingen målar Hisingen kan lesa. Sjekk at det er eierkontoen i Perific-appen. |
| This account may not control that charger. | Denne kontoen kan mangle løyve til å styra den ladaren. |
| This account no longer lists the meter | Denne kontoen viser ikkje lenger målaren |
| This token could not read the device list, so chargers were found by their entity names. An administrator token also finds the serial number. | Dette tokenet kunne ikkje lesa einingslista, så ladarane vart funne etter entitetsnamna sine. Eit administrator-token finn òg serienummeret. |
| Three phase | Trefase |
| Tibber's price includes energy, taxes and its markup but not the grid fee. Add yours here; a paired charger can set its own. | Tibber-prisen inneheld energi, avgifter og eigen margin, men ikkje nettleia. Legg inn din her; ein kopla ladar kan angi sin eigen. |
| Unpair charger | Kobl frå ladar |
| Use this meter | Bruk denne målaren |

### Flagged for this language

- Nynorsk forms were written to match the existing file (tilkopla, straum, målar, Nykkelring).
- "Racerbaneblå" for Circuit Blue, matching "Meistarskapsblå" in its subtitle.
- Pair charger / Unpair charger uses "Kobl saman ladar" / "Kobl frå ladar"; confirm the imperative reads naturally.
- Least-reviewed language of this batch; every string should get a native pass.

## pl

Confidence: High confidence; the possessive-capitalization and fuse term need a Polish check.


### Today's morning additions (verify as shipped)

| English source | Shipped value |
| --- | --- |
| Volvo moved to a new sign-in system. Sign in again to keep your vehicle data. | Volvo przeszło na nowy system logowania. Zaloguj się ponownie, aby zachować dane o pojeździe. |
| Drive Type | Typ napędu |
| Engine Power | Moc silnika |
| Gross Weight | Masa całkowita |
| Seats | Liczba miejsc |
| Last changed %@ | Ostatnia zmiana %@ |
| %d kW | %d kW |
| %d kg | %d kg |

### Strings translated today (168 keys)

| English source | Shipped value |
| --- | --- |
| %@ accepted the command. Waiting for the charger to confirm. | %@ przyjął polecenie. Oczekiwanie na potwierdzenie od ładowarki. |
| %@ did not accept the saved login | %@ nie zaakceptował zapisanego loginu |
| %@ did not accept the saved login. Enter the account and password again to reconnect. | %@ nie zaakceptował zapisanego loginu. Wpisz ponownie konto i hasło, aby ponownie połączyć. |
| %@ from charger | %@ z ładowarki |
| %@ is delaying the start | %@ opóźnia rozpoczęcie |
| %@ is unreachable | %@ jest nieosiągalny |
| %@ per phase | %@ na fazę |
| %@ per phase, limit %@ | %@ na fazę, limit %@ |
| %@ to the grid | %@ do sieci |
| %@, limited by the cable | %@, ograniczone przez kabel |
| %@, limited by the circuit fuse | %@, ograniczone przez bezpiecznik obwodu |
| %d charger sessions could not be tied to a vehicle and are kept unassigned. | %d sesji ładowarki nie dało się powiązać z pojazdem i pozostają bez przypisania. |
| A charger schedule or EcoPilot is active. Turn it off in the NexBlue app so Home Assistant controls the start. | Harmonogram ładowarki lub EcoPilot jest aktywny. Wyłącz go w aplikacji NexBlue, aby Home Assistant sterował rozpoczęciem. |
| A charging schedule is active on the charger. | Na ładowarce jest aktywny harmonogram ładowania. |
| A delayed start or EcoPilot is active on the charger. | Na ładowarce jest aktywny opóźniony start lub EcoPilot. |
| A shared charger only records a session for this vehicle when the car's own charging overlaps it. | Współdzielona ładowarka zapisuje sesję dla tego pojazdu tylko wtedy, gdy nakłada się na nią ładowanie samego samochodu. |
| Account email | Adres e-mail konta |
| Adaptive | Adaptacyjny |
| Added to Tibber prices in the planner and for charger sessions. | Dodawane do cen Tibbera w planerze i do sesji ładowarki. |
| After an error | Po błędzie |
| At the charger | Przy ładowarce |
| By an administrator | Przez administratora |
| By schedule | Zgodnie z harmonogramem |
| Cable Rating | Obciążalność kabla |
| Cable lock | Blokada kabla |
| Cable unlocked | Kabel odblokowany |
| Cable unplugged | Kabel odłączony |
| Calculated from the meter's current and voltage, so it can read slightly above the energy your supplier bills. | Obliczane z prądu i napięcia licznika, więc może być nieco wyższe niż energia rozliczana przez dostawcę. |
| Car %@, rest of the house %@ | Samochód %@, reszta domu %@ |
| Charge complete | Ładowanie zakończone |
| Charger Details | Szczegóły ładowarki |
| Charger Energy | Energia z ładowarki |
| Charger connection | Połączenie ładowarki |
| Charger measurement only | Tylko pomiar ładowarki |
| Charger restarted | Ładowarka uruchomiona ponownie |
| Charger updated %@ ago | Ładowarka zaktualizowana %@ temu |
| Charger-measured home sessions against the house meter's readings from Perific, %@ to %@. Charging away from home never reaches that meter. | Domowe sesje mierzone przez ładowarkę na tle odczytów licznika domowego z Perific, od %@ do %@. Ładowanie poza domem nigdy nie trafia do tego licznika. |
| Charging at reduced power | Ładowanie z ograniczoną mocą |
| Charging enabled | Ładowanie włączone |
| Charging is enabled but the car is drawing no power | Ładowanie jest włączone, ale samochód nie pobiera prądu |
| Charging state | Stan ładowania |
| Charging switch | Przełącznik ładowania |
| Charging uses the lowest. The car and load balancing can ask for less. | Ładowanie używa najniższej wartości. Samochód i równoważenie obciążenia mogą żądać mniej. |
| Checked %@ | Sprawdzono %@ |
| Circuit Blue | Błękit torowy |
| Circuit Fuse | Bezpiecznik obwodu |
| Connect and find chargers | Połącz i znajdź ładowarki |
| Connected through | Połączono przez |
| Copy custom_components/hisingen_home_charging into your Home Assistant config folder, add hisingen_home_charging: to configuration.yaml and restart. The Home Charging guide in the repository has the steps. | Skopiuj custom_components/hisingen_home_charging do folderu konfiguracji Home Assistant, dodaj hisingen_home_charging: do configuration.yaml i uruchom ponownie. Instrukcja Home Charging w repozytorium opisuje kroki. |
| Current per Phase | Prąd na fazę |
| Disconnect Perific | Odłącz Perific |
| Emergency stop | Zatrzymanie awaryjne |
| Entities | Encje |
| Exported Today | Dziś wyeksportowano |
| Held by load balancing | Wstrzymana przez równoważenie obciążenia |
| Hisingen is not signed in to %@ yet. | Hisingen nie jest jeszcze zalogowany w %@. |
| Home Assistant accepted the command. Waiting for the charger to confirm. | Home Assistant przyjął polecenie. Oczekiwanie na potwierdzenie od ładowarki. |
| Home Assistant stops the plan and leaves the charger as it is. | Home Assistant zatrzymuje plan i zostawia ładowarkę bez zmian. |
| Home Charging | Ładowanie domowe |
| Home charger | Ładowarka domowa |
| Home charging plan | Domowy plan ładowania |
| House %@ | Dom %@ |
| House Current per Phase | Prąd w domu na fazę |
| House Meter | Licznik domowy |
| House Now | Dom teraz |
| House Voltage | Napięcie w domu |
| House meter last read %@ ago | Licznik domowy ostatnio odczytany %@ temu |
| House sending %@ to the grid | Dom wysyła %@ do sieci |
| Import sessions now | Zaimportuj sesje teraz |
| Imported Today | Dziś zaimportowano |
| Importing | Importowanie |
| Last update from %@ %@ | Ostatnia aktualizacja od %@ %@ |
| Load balancing can limit the charger when the house uses more power. | Równoważenie obciążenia może ograniczyć ładowarkę, gdy dom zużywa więcej energii. |
| Load balancing is holding the charger. It continues when power is free. | Równoważenie obciążenia wstrzymuje ładowarkę. Ładowanie wznowi się, gdy pojawi się wolna moc. |
| Map by hand | Powiąż ręcznie |
| Measured at the charger, so it includes charging losses. | Zmierzone przy ładowarce, więc obejmuje straty ładowania. |
| Measured from recent charger sessions. It updates when the car charges slower than planned. | Wyznaczone z ostatnich sesji ładowarki. Aktualizuje się, gdy samochód ładuje się wolniej niż planowano. |
| Meter | Licznik |
| Metered by the charger and read from Home Assistant. Last charger reading %@. | Mierzone przez ładowarkę i odczytywane z Home Assistant. Ostatni odczyt ładowarki %@. |
| Metered by the charger and read from the %@ cloud. Last charger reading %@. | Mierzone przez ładowarkę i odczytywane z chmury %@. Ostatni odczyt ładowarki %@. |
| Mobile data | Dane mobilne |
| Needed to keep charger sessions in Hisingen's local history. | Potrzebne do zachowania sesji ładowarki w lokalnej historii Hisingen. |
| NexBlue is delaying the start | NexBlue opóźnia rozpoczęcie |
| NexBlue is holding a delayed start | NexBlue wstrzymuje opóźniony start |
| NexBlue is holding the start with a delayed start. | NexBlue wstrzymuje rozpoczęcie z opóźnionym startem. |
| No NexBlue charger was found. Map the entities by hand below. | Nie znaleziono ładowarki NexBlue. Powiąż encje ręcznie poniżej. |
| No charger is paired. | Brak sparowanej ładowarki. |
| No charging switch is mapped for this charger. | Dla tej ładowarki nie ma przypisanego przełącznika ładowania. |
| No new reading arrived from the charger. | Z ładowarki nie przyszedł nowy odczyt. |
| Not authorised | Brak autoryzacji |
| Not imported yet | Jeszcze nie zaimportowano |
| Off: local charging history is disabled | Wyłączone: lokalna historia ładowania jest wyłączona |
| On plug-in | Po podłączeniu |
| Only the session total was available, so this is an estimate. | Dostępna była tylko suma sesji, więc to jest szacunek. |
| Optional. Connects a charger that Home Assistant manages, such as NexBlue, to show its status, control it, and record what it measured. | Opcjonalnie. Łączy ładowarkę zarządzaną przez Home Assistant, na przykład NexBlue, aby pokazywać jej stan, nią sterować i zapisywać to, co zmierzyła. |
| Optional. Connects a home charger to show its status, control it, and record what it measured. Easee and Zaptec sign in with their own account. Any other charger works through Home Assistant, such as NexBlue. | Opcjonalnie. Łączy domową ładowarkę, aby pokazywać jej stan, nią sterować i zapisywać to, co zmierzyła. Easee i Zaptec logują się własnym kontem. Każda inna ładowarka działa przez Home Assistant, na przykład NexBlue. |
| Optional. Reads your home's electricity use from a Perific monitor, so charging can be shown against the whole house. Hisingen only reads it. Perific keeps balancing the charger. | Opcjonalnie. Odczytuje zużycie energii w twoim domu z monitora Perific, aby ładowanie można było pokazać na tle całego domu. Hisingen tylko odczytuje. Perific nadal równoważy ładowarkę. |
| Other cars also use this charger | Z tej ładowarki korzystają też inne samochody |
| Pair charger | Sparuj ładowarkę |
| Perific account email | Adres e-mail konta Perific |
| Perific did not accept the saved login. Enter the account and password again to reconnect. | Perific nie zaakceptował zapisanego loginu. Wpisz ponownie konto i hasło, aby ponownie połączyć. |
| Perific did not accept the saved login. Sign in again in Settings, Electricity. | Perific nie zaakceptował zapisanego loginu. Zaloguj się ponownie w Ustawieniach, Energia elektryczna. |
| Phase Mode | Tryb faz |
| Plans run inside Home Assistant. This charger is connected directly, so it offers status, Charge now, Pause and history. | Plany działają w Home Assistant. Ta ładowarka jest połączona bezpośrednio, więc oferuje stan, Ładuj teraz, Pauza i historię. |
| Power loss | Utrata zasilania |
| Price source: %@. | Źródło ceny: %@. |
| Priced per 15-minute interval from the charger's own readings. | Wyceniane w interwałach 15-minutowych na podstawie własnych odczytów ładowarki. |
| Reading chargers… | Odczytywanie ładowarek… |
| Reading every 30 seconds | Odczyt co 30 sekund |
| Remotely | Zdalnie |
| Reported %@ | Zgłoszono %@ |
| Resume | Wznów |
| Sending the pause command to %@ | Wysyłanie polecenia wstrzymania do %@ |
| Sending the start command to %@ | Wysyłanie polecenia rozpoczęcia do %@ |
| Session history | Historia sesji |
| Sessions and plans are tied to this vehicle only. A car being near the charger is not enough. | Sesje i plany dotyczą tylko tego pojazdu. To, że samochód stoi obok ładowarki, nie wystarczy. |
| Sessions are tied to this vehicle only. A car being near the charger is not enough. | Sesje dotyczą tylko tego pojazdu. To, że samochód stoi obok ładowarki, nie wystarczy. |
| Shared charger | Ładowarka współdzielona |
| Sign in | Zaloguj się |
| Sign in again in Settings. | Zaloguj się ponownie w Ustawieniach. |
| Sign in and find chargers | Zaloguj się i znajdź ładowarki |
| Sign in and find meters | Zaloguj się i znajdź liczniki |
| Sign in to %@ again | Zaloguj się ponownie w %@ |
| Sign out | Wyloguj się |
| Sign-in refused | Logowanie odmówione |
| Sign-in rejected | Logowanie odrzucone |
| Signed in to %@ | Zalogowano w %@ |
| Signing in… | Logowanie… |
| Single phase | Jednofazowy |
| Source | Źródło |
| Still needed: %@. | Wciąż potrzebne: %@. |
| The account or password was not accepted. | Konto lub hasło nie zostało zaakceptowane. |
| The account you use in the Perific app. It is stored in the macOS Keychain and never exported. | Konto, którego używasz w aplikacji Perific. Jest zapisywane w pęku kluczy macOS i nigdy nie jest eksportowane. |
| The cable allows %@. | Kabel pozwala na %@. |
| The charger command was rejected | Polecenie dla ładowarki zostało odrzucone |
| The charger did not confirm the last command. | Ładowarka nie potwierdziła ostatniego polecenia. |
| The charger has not confirmed the command | Ładowarka nie potwierdziła polecenia |
| The charger has not reported recently | Ładowarka ostatnio nic nie zgłasza |
| The charger is unavailable in %@ | Ładowarka jest niedostępna w %@ |
| The charger is unavailable in Home Assistant | Ładowarka jest niedostępna w Home Assistant |
| The charger is unavailable in Home Assistant. | Ładowarka jest niedostępna w Home Assistant. |
| The charger kept its previous state. Try again, or check the charger. | Ładowarka zachowała poprzedni stan. Spróbuj ponownie albo sprawdź ładowarkę. |
| The charger readings below are the last ones received. | Poniższe odczyty to ostatnie otrzymane z ładowarki. |
| The charger recorded this session while no battery reading was available, so there is no battery-side estimate. | Ładowarka zapisała tę sesję, gdy nie było odczytu baterii, więc nie ma szacunku od strony baterii. |
| The charger reported an error after the command. | Ładowarka zgłosiła błąd po poleceniu. |
| The charger reports about once a minute. | Ładowarka zgłasza mniej więcej raz na minutę. |
| The charger reports an error | Ładowarka zgłasza błąd |
| The charger service asked Hisingen to slow down. It will try again shortly. | Usługa ładowarki poprosiła Hisingen o zwolnienie tempa. Spróbuje ponownie wkrótce. |
| The charger service could not be reached. | Nie można połączyć się z usługą ładowarki. |
| The charger service does not know that item. | Usługa ładowarki nie zna tego elementu. |
| The charger service refused the request. | Usługa ładowarki odrzuciła żądanie. |
| The charger service sent an answer Hisingen could not read. | Usługa ładowarki wysłała odpowiedź, której Hisingen nie mógł odczytać. |
| The circuit fuse is %@. | Bezpiecznik obwodu to %@. |
| The limit is set to %@. | Limit jest ustawiony na %@. |
| The meter sent no voltage, so 230 V is assumed and power is approximate. | Licznik nie przesłał napięcia, więc przyjęto 230 V, a moc jest przybliżona. |
| The one you use in the %@ app. It is stored in the macOS Keychain and never exported. | Konto, którego używasz w aplikacji %@. Jest zapisywane w pęku kluczy macOS i nigdy nie jest eksportowane. |
| The saved location in the car where this charger stands. | Zapisana lokalizacja w samochodzie, przy której stoi ta ładowarka. |
| The saved token and the charger pairing are deleted. Charging history that was already recorded stays. | Zapisany token i parowanie ładowarki zostają usunięte. Zarejestrowana wcześniej historia ładowania zostaje. |
| This Home Assistant automation uses the charger and may start or stop it. | Ta automatyzacja Home Assistant używa ładowarki i może ją uruchomić lub zatrzymać. |
| This account has no charger that Hisingen can control. Check that it is the owner account in the %@ app. | To konto nie ma ładowarki, którą Hisingen może sterować. Sprawdź, czy to konto właściciela w aplikacji %@. |
| This account has no meter that Hisingen can read. Check that it is the owner account in the Perific app. | To konto nie ma licznika, którego Hisingen może odczytać. Sprawdź, czy to konto właściciela w aplikacji Perific. |
| This account may not control that charger. | To konto może nie mieć uprawnień do sterowania tą ładowarką. |
| This account no longer lists the meter | To konto nie pokazuje już licznika |
| This token could not read the device list, so chargers were found by their entity names. An administrator token also finds the serial number. | Ten token nie mógł odczytać listy urządzeń, więc ładowarki znaleziono po nazwach encji. Token administratora znajduje też numer seryjny. |
| Three phase | Trójfazowy |
| Tibber's price includes energy, taxes and its markup but not the grid fee. Add yours here; a paired charger can set its own. | Cena Tibbera obejmuje energię, podatki i jego marżę, ale nie opłatę dystrybucyjną. Dodaj własną tutaj; sparowana ładowarka może ustawić swoją. |
| Unpair charger | Cofnij parowanie ładowarki |
| Use this meter | Użyj tego licznika |

### Flagged for this language

- Register: informal imperative, matching the existing file. Possessives are lowercase (twoim); some Polish UIs capitalize (Twoim).
- "Błękit torowy" for Circuit Blue, matching "Błękit mistrzowski" in its subtitle.
- "Równoważenie obciążenia" for load balancing; also "balansowanie obciążenia".
- "Bezpiecznik obwodu" for Circuit Fuse; a household consumer may know "kurator" or "bezpiecznik instalacyjny" better.

## pt

Confidence: High confidence in pt-PT; the article before brand names needs a house-style decision.


### Today's morning additions (verify as shipped)

| English source | Shipped value |
| --- | --- |
| Volvo moved to a new sign-in system. Sign in again to keep your vehicle data. | A Volvo passou a usar um novo sistema de início de sessão. Inicie sessão novamente para manter os dados do seu veículo. |
| Drive Type | Tipo de tração |
| Engine Power | Potência do motor |
| Gross Weight | Peso bruto |
| Seats | Lugares |
| Last changed %@ | Última alteração em %@ |
| %d kW | %d kW |
| %d kg | %d kg |

### Strings translated today (168 keys)

| English source | Shipped value |
| --- | --- |
| %@ accepted the command. Waiting for the charger to confirm. | %@ aceitou o comando. À espera da confirmação do carregador. |
| %@ did not accept the saved login | %@ não aceitou o início de sessão guardado |
| %@ did not accept the saved login. Enter the account and password again to reconnect. | %@ não aceitou o início de sessão guardado. Introduza novamente a conta e a palavra-passe para restabelecer a ligação. |
| %@ from charger | %@ do carregador |
| %@ is delaying the start | %@ está a atrasar o início |
| %@ is unreachable | %@ está inacessível |
| %@ per phase | %@ por fase |
| %@ per phase, limit %@ | %@ por fase, limite %@ |
| %@ to the grid | %@ para a rede |
| %@, limited by the cable | %@, limitado pelo cabo |
| %@, limited by the circuit fuse | %@, limitado pelo fusível do circuito |
| %d charger sessions could not be tied to a vehicle and are kept unassigned. | %d sessões do carregador não puderam ser ligadas a um veículo e ficam sem atribuição. |
| A charger schedule or EcoPilot is active. Turn it off in the NexBlue app so Home Assistant controls the start. | Um agendamento do carregador ou o EcoPilot está ativo. Desative-o na app NexBlue para que o Home Assistant controle o início. |
| A charging schedule is active on the charger. | Um horário de carregamento está ativo no carregador. |
| A delayed start or EcoPilot is active on the charger. | Um início retardado ou o EcoPilot está ativo no carregador. |
| A shared charger only records a session for this vehicle when the car's own charging overlaps it. | Um carregador partilhado só regista uma sessão para este veículo quando o carregamento do próprio carro a sobrepõe. |
| Account email | E-mail da conta |
| Adaptive | Adaptativo |
| Added to Tibber prices in the planner and for charger sessions. | Adicionado aos preços da Tibber no planeador e nas sessões do carregador. |
| After an error | Após um erro |
| At the charger | No carregador |
| By an administrator | Por um administrador |
| By schedule | Por agendamento |
| Cable Rating | Capacidade do cabo |
| Cable lock | Bloqueio do cabo |
| Cable unlocked | Cabo desbloqueado |
| Cable unplugged | Cabo desligado |
| Calculated from the meter's current and voltage, so it can read slightly above the energy your supplier bills. | Calculado a partir da corrente e da tensão do contador, por isso pode ficar ligeiramente acima da energia que o seu fornecedor fatura. |
| Car %@, rest of the house %@ | Carro %@, resto da casa %@ |
| Charge complete | Carregamento concluído |
| Charger Details | Detalhes do carregador |
| Charger Energy | Energia do carregador |
| Charger connection | Ligação do carregador |
| Charger measurement only | Apenas medição do carregador |
| Charger restarted | Carregador reiniciado |
| Charger updated %@ ago | Carregador atualizado há %@ |
| Charger-measured home sessions against the house meter's readings from Perific, %@ to %@. Charging away from home never reaches that meter. | Sessões em casa medidas pelo carregador, comparadas com as leituras do contador da casa da Perific, de %@ a %@. Carregar fora de casa nunca chega a esse contador. |
| Charging at reduced power | A carregar com potência reduzida |
| Charging enabled | Carregamento ativado |
| Charging is enabled but the car is drawing no power | O carregamento está ativado, mas o carro não está a consumir corrente |
| Charging state | Estado de carregamento |
| Charging switch | Interruptor de carregamento |
| Charging uses the lowest. The car and load balancing can ask for less. | O carregamento usa o valor mais baixo. O carro e o equilíbrio de carga podem pedir menos. |
| Checked %@ | Verificado %@ |
| Circuit Blue | Azul de pista |
| Circuit Fuse | Fusível do circuito |
| Connect and find chargers | Ligar e procurar carregadores |
| Connected through | Ligado através de |
| Copy custom_components/hisingen_home_charging into your Home Assistant config folder, add hisingen_home_charging: to configuration.yaml and restart. The Home Charging guide in the repository has the steps. | Copie custom_components/hisingen_home_charging para a pasta de configuração do Home Assistant, adicione hisingen_home_charging: ao configuration.yaml e reinicie. O guia Home Charging no repositório tem os passos. |
| Current per Phase | Corrente por fase |
| Disconnect Perific | Desligar Perific |
| Emergency stop | Paragem de emergência |
| Entities | Entidades |
| Exported Today | Exportado hoje |
| Held by load balancing | Segurado pelo equilíbrio de carga |
| Hisingen is not signed in to %@ yet. | O Hisingen ainda não iniciou sessão em %@. |
| Home Assistant accepted the command. Waiting for the charger to confirm. | O Home Assistant aceitou o comando. À espera da confirmação do carregador. |
| Home Assistant stops the plan and leaves the charger as it is. | O Home Assistant para o plano e deixa o carregador como está. |
| Home Charging | Carregamento doméstico |
| Home charger | Carregador doméstico |
| Home charging plan | Plano de carregamento doméstico |
| House %@ | Casa %@ |
| House Current per Phase | Corrente da casa por fase |
| House Meter | Contador da casa |
| House Now | Casa agora |
| House Voltage | Tensão da casa |
| House meter last read %@ ago | Contador da casa lido pela última vez há %@ |
| House sending %@ to the grid | A casa está a enviar %@ para a rede |
| Import sessions now | Importar sessões agora |
| Imported Today | Importado hoje |
| Importing | A importar |
| Last update from %@ %@ | Última atualização de %@ %@ |
| Load balancing can limit the charger when the house uses more power. | O equilíbrio de carga pode limitar o carregador quando a casa consome mais potência. |
| Load balancing is holding the charger. It continues when power is free. | O equilíbrio de carga está a segurar o carregador. O carregamento retoma quando houver potência disponível. |
| Map by hand | Associar manualmente |
| Measured at the charger, so it includes charging losses. | Medido no carregador, por isso inclui as perdas de carregamento. |
| Measured from recent charger sessions. It updates when the car charges slower than planned. | Medido a partir de sessões recentes do carregador. Atualiza-se quando o carro carrega mais devagar do que o planeado. |
| Meter | Contador |
| Metered by the charger and read from Home Assistant. Last charger reading %@. | Medido pelo carregador e lido do Home Assistant. Última leitura do carregador %@. |
| Metered by the charger and read from the %@ cloud. Last charger reading %@. | Medido pelo carregador e lido da nuvem %@. Última leitura do carregador %@. |
| Mobile data | Dados móveis |
| Needed to keep charger sessions in Hisingen's local history. | Necessário para manter as sessões do carregador no histórico local do Hisingen. |
| NexBlue is delaying the start | A NexBlue está a atrasar o início |
| NexBlue is holding a delayed start | A NexBlue está a segurar um início retardado |
| NexBlue is holding the start with a delayed start. | A NexBlue está a segurar o início com um início retardado. |
| No NexBlue charger was found. Map the entities by hand below. | Não foi encontrado nenhum carregador NexBlue. Associe as entidades manualmente abaixo. |
| No charger is paired. | Não há nenhum carregador associado. |
| No charging switch is mapped for this charger. | Não há nenhum interruptor de carregamento associado a este carregador. |
| No new reading arrived from the charger. | Não chegou uma nova leitura do carregador. |
| Not authorised | Não autorizado |
| Not imported yet | Ainda não importado |
| Off: local charging history is disabled | Desativado: o histórico local de carregamentos está desativado |
| On plug-in | Ao ligar |
| Only the session total was available, so this is an estimate. | Só estava disponível o total da sessão, por isso é uma estimativa. |
| Optional. Connects a charger that Home Assistant manages, such as NexBlue, to show its status, control it, and record what it measured. | Opcional. Liga um carregador gerido pelo Home Assistant, como a NexBlue, para mostrar o estado, controlá-lo e registar o que mediu. |
| Optional. Connects a home charger to show its status, control it, and record what it measured. Easee and Zaptec sign in with their own account. Any other charger works through Home Assistant, such as NexBlue. | Opcional. Liga um carregador doméstico para mostrar o estado, controlá-lo e registar o que mediu. A Easee e a Zaptec iniciam sessão com a própria conta. Qualquer outro carregador funciona através do Home Assistant, como a NexBlue. |
| Optional. Reads your home's electricity use from a Perific monitor, so charging can be shown against the whole house. Hisingen only reads it. Perific keeps balancing the charger. | Opcional. Lê o consumo de eletricidade da sua casa num monitor Perific, para que o carregamento possa ser comparado com a casa inteira. O Hisingen apenas lê. A Perific continua a equilibrar o carregador. |
| Other cars also use this charger | Outros carros também usam este carregador |
| Pair charger | Associar carregador |
| Perific account email | E-mail da conta Perific |
| Perific did not accept the saved login. Enter the account and password again to reconnect. | A Perific não aceitou o início de sessão guardado. Introduza novamente a conta e a palavra-passe para restabelecer a ligação. |
| Perific did not accept the saved login. Sign in again in Settings, Electricity. | A Perific não aceitou o início de sessão guardado. Inicie sessão novamente em Definições, Eletricidade. |
| Phase Mode | Modo de fases |
| Plans run inside Home Assistant. This charger is connected directly, so it offers status, Charge now, Pause and history. | Os planos correm dentro do Home Assistant. Este carregador está ligado diretamente, por isso oferece estado, Carregar agora, Pausa e histórico. |
| Power loss | Falha de alimentação |
| Price source: %@. | Fonte do preço: %@. |
| Priced per 15-minute interval from the charger's own readings. | Preçado por intervalos de 15 minutos a partir das leituras do próprio carregador. |
| Reading chargers… | A ler carregadores… |
| Reading every 30 seconds | Leitura a cada 30 segundos |
| Remotely | Remotamente |
| Reported %@ | Comunicado %@ |
| Resume | Retomar |
| Sending the pause command to %@ | A enviar o comando de pausa para %@ |
| Sending the start command to %@ | A enviar o comando de início para %@ |
| Session history | Histórico de sessões |
| Sessions and plans are tied to this vehicle only. A car being near the charger is not enough. | As sessões e os planos estão ligados apenas a este veículo. Um carro estar perto do carregador não chega. |
| Sessions are tied to this vehicle only. A car being near the charger is not enough. | As sessões estão ligadas apenas a este veículo. Um carro estar perto do carregador não chega. |
| Shared charger | Carregador partilhado |
| Sign in | Iniciar sessão |
| Sign in again in Settings. | Inicie sessão novamente nas Definições. |
| Sign in and find chargers | Iniciar sessão e procurar carregadores |
| Sign in and find meters | Iniciar sessão e procurar contadores |
| Sign in to %@ again | Inicie sessão novamente em %@ |
| Sign out | Terminar sessão |
| Sign-in refused | Início de sessão recusado |
| Sign-in rejected | Início de sessão rejeitado |
| Signed in to %@ | Sessão iniciada em %@ |
| Signing in… | A iniciar sessão… |
| Single phase | Monofásico |
| Source | Fonte |
| Still needed: %@. | Ainda necessário: %@. |
| The account or password was not accepted. | A conta ou a palavra-passe não foi aceite. |
| The account you use in the Perific app. It is stored in the macOS Keychain and never exported. | A conta que utiliza na app Perific. É guardada no Porta-chaves do macOS e nunca é exportada. |
| The cable allows %@. | O cabo admite %@. |
| The charger command was rejected | O comando do carregador foi rejeitado |
| The charger did not confirm the last command. | O carregador não confirmou o último comando. |
| The charger has not confirmed the command | O carregador não confirmou o comando |
| The charger has not reported recently | O carregador não comunicou dados recentemente |
| The charger is unavailable in %@ | O carregador não está disponível em %@ |
| The charger is unavailable in Home Assistant | O carregador não está disponível no Home Assistant |
| The charger is unavailable in Home Assistant. | O carregador não está disponível no Home Assistant. |
| The charger kept its previous state. Try again, or check the charger. | O carregador manteve o estado anterior. Tente novamente, ou verifique o carregador. |
| The charger readings below are the last ones received. | As leituras abaixo são as últimas recebidas do carregador. |
| The charger recorded this session while no battery reading was available, so there is no battery-side estimate. | O carregador registou esta sessão quando não havia uma leitura da bateria, por isso não há uma estimativa do lado da bateria. |
| The charger reported an error after the command. | O carregador comunicou um erro após o comando. |
| The charger reports about once a minute. | O carregador comunica cerca de uma vez por minuto. |
| The charger reports an error | O carregador comunica um erro |
| The charger service asked Hisingen to slow down. It will try again shortly. | O serviço do carregador pediu ao Hisingen para abrandar. Vai tentar novamente em breve. |
| The charger service could not be reached. | Não foi possível contactar o serviço do carregador. |
| The charger service does not know that item. | O serviço do carregador não conhece esse item. |
| The charger service refused the request. | O serviço do carregador recusou o pedido. |
| The charger service sent an answer Hisingen could not read. | O serviço do carregador enviou uma resposta que o Hisingen não conseguiu ler. |
| The circuit fuse is %@. | O fusível do circuito é %@. |
| The limit is set to %@. | O limite está definido em %@. |
| The meter sent no voltage, so 230 V is assumed and power is approximate. | O contador não enviou tensão, por isso assumem-se 230 V e a potência é aproximada. |
| The one you use in the %@ app. It is stored in the macOS Keychain and never exported. | A que utiliza na app %@. É guardada no Porta-chaves do macOS e nunca é exportada. |
| The saved location in the car where this charger stands. | A localização guardada no carro onde este carregador está. |
| The saved token and the charger pairing are deleted. Charging history that was already recorded stays. | O token guardado e a associação do carregador são eliminados. O histórico de carregamentos já registado mantém-se. |
| This Home Assistant automation uses the charger and may start or stop it. | Esta automatização do Home Assistant usa o carregador e pode iniciá-lo ou pará-lo. |
| This account has no charger that Hisingen can control. Check that it is the owner account in the %@ app. | Esta conta não tem nenhum carregador que o Hisingen possa controlar. Verifique que é a conta proprietária na app %@. |
| This account has no meter that Hisingen can read. Check that it is the owner account in the Perific app. | Esta conta não tem nenhum contador que o Hisingen possa ler. Verifique que é a conta proprietária na app Perific. |
| This account may not control that charger. | Esta conta pode não ter autorização para controlar esse carregador. |
| This account no longer lists the meter | Esta conta já não mostra o contador |
| This token could not read the device list, so chargers were found by their entity names. An administrator token also finds the serial number. | Este token não conseguiu ler a lista de dispositivos, por isso os carregadores foram encontrados pelos nomes das entidades. Um token de administrador também encontra o número de série. |
| Three phase | Trifásico |
| Tibber's price includes energy, taxes and its markup but not the grid fee. Add yours here; a paired charger can set its own. | O preço da Tibber inclui energia, impostos e a sua margem, mas não a tarifa de rede. Adicione a sua aqui; um carregador associado pode definir a própria. |
| Unpair charger | Desassociar carregador |
| Use this meter | Usar este contador |

### Flagged for this language

- European Portuguese (iniciar sessão, paragem, consigo-style register), matching the existing file.
- "Azul de pista" for Circuit Blue, matching "Azul de campeonato" in its subtitle.
- "O equilíbrio de carga" for load balancing; also "gestão de carga". Confirm the EV term in Portugal.
- Brand names take the feminine article where the company is read as one ("a NexBlue", "a Perific", "a Tibber"); confirm this matches house style.

## zh

Confidence: Good confidence; the technical fuse/cable terms and 插枪 phrasing deserve a native pass.


### Today's morning additions (verify as shipped)

| English source | Shipped value |
| --- | --- |
| Volvo moved to a new sign-in system. Sign in again to keep your vehicle data. | Volvo 已改用新的登录系统。请重新登录，以保留你的车辆数据。 |
| Drive Type | 驱动方式 |
| Engine Power | 发动机功率 |
| Gross Weight | 总质量 |
| Seats | 座位数 |
| Last changed %@ | 最后变更：%@ |
| %d kW | %d kW |
| %d kg | %d kg |

### Strings translated today (167 keys)

| English source | Shipped value |
| --- | --- |
| %@ accepted the command. Waiting for the charger to confirm. | %@ 已接受指令。正在等待充电器确认。 |
| %@ did not accept the saved login | %@ 未接受已保存的登录信息 |
| %@ did not accept the saved login. Enter the account and password again to reconnect. | %@ 未接受已保存的登录信息。请重新输入账户和密码以重新连接。 |
| %@ from charger | 来自充电器的 %@ |
| %@ is delaying the start | %@ 正在推迟开始充电 |
| %@ is unreachable | %@ 无法访问 |
| %@ per phase | 每相 %@ |
| %@ per phase, limit %@ | 每相 %@，上限 %@ |
| %@ to the grid | %@ 送入电网 |
| %@, limited by the cable | %@（受线缆限制） |
| %@, limited by the circuit fuse | %@（受回路保险丝限制） |
| %d charger sessions could not be tied to a vehicle and are kept unassigned. | %d 个充电器会话无法关联到车辆，将保持未分配状态。 |
| A charger schedule or EcoPilot is active. Turn it off in the NexBlue app so Home Assistant controls the start. | 充电器日程或 EcoPilot 处于活动状态。请在 NexBlue 应用中关闭，以便由 Home Assistant 控制开始充电。 |
| A charging schedule is active on the charger. | 充电器上有活动的充电日程。 |
| A delayed start or EcoPilot is active on the charger. | 充电器上有活动的延迟启动或 EcoPilot。 |
| A shared charger only records a session for this vehicle when the car's own charging overlaps it. | 共享充电器仅在该车辆自身充电时段重叠时，才为其记录会话。 |
| Account email | 账户邮箱 |
| Adaptive | 自适应 |
| Added to Tibber prices in the planner and for charger sessions. | 在计划器和充电器会话中计入 Tibber 价格。 |
| After an error | 出错后 |
| At the charger | 在充电器处 |
| By an administrator | 由管理员 |
| By schedule | 按日程 |
| Cable Rating | 线缆载流量 |
| Cable lock | 充电枪锁 |
| Cable unlocked | 充电枪已解锁 |
| Cable unplugged | 充电枪已拔出 |
| Calculated from the meter's current and voltage, so it can read slightly above the energy your supplier bills. | 由电表的电流和电压计算得出，因此可能略高于供电公司计费的电量。 |
| Car %@, rest of the house %@ | 车辆 %@，家庭其余部分 %@ |
| Charge complete | 充电完成 |
| Charger Details | 充电器详情 |
| Charger Energy | 充电器电量 |
| Charger connection | 充电器连接 |
| Charger measurement only | 仅充电器计量 |
| Charger restarted | 充电器已重启 |
| Charger updated %@ ago | 充电器更新于 %@ 前 |
| Charger-measured home sessions against the house meter's readings from Perific, %@ to %@. Charging away from home never reaches that meter. | 由充电器计量的家用充电会话，对照 Perific 家庭电表读数，%@ 至 %@。在家庭之外充电不会计入该电表。 |
| Charging at reduced power | 正在以较低功率充电 |
| Charging enabled | 充电已启用 |
| Charging is enabled but the car is drawing no power | 充电已启用，但车辆未在取电 |
| Charging state | 充电状态 |
| Charging switch | 充电开关 |
| Charging uses the lowest. The car and load balancing can ask for less. | 充电使用最低值。车辆和负载均衡可能要求更低。 |
| Checked %@ | 检查于 %@ |
| Circuit Fuse | 回路保险丝 |
| Connect and find chargers | 连接并查找充电器 |
| Connected through | 连接方式 |
| Copy custom_components/hisingen_home_charging into your Home Assistant config folder, add hisingen_home_charging: to configuration.yaml and restart. The Home Charging guide in the repository has the steps. | 将 custom_components/hisingen_home_charging 复制到 Home Assistant 配置文件夹，在 configuration.yaml 中添加 hisingen_home_charging:，然后重新启动。仓库中的 Home Charging 指南包含具体步骤。 |
| Current per Phase | 每相电流 |
| Disconnect Perific | 断开 Perific |
| Emergency stop | 紧急停止 |
| Entities | 实体 |
| Exported Today | 今日输出电量 |
| Held by load balancing | 因负载均衡暂停 |
| Hisingen is not signed in to %@ yet. | Hisingen 尚未登录 %@。 |
| Home Assistant accepted the command. Waiting for the charger to confirm. | Home Assistant 已接受指令。正在等待充电器确认。 |
| Home Assistant stops the plan and leaves the charger as it is. | Home Assistant 会停止计划，充电器保持原状。 |
| Home Charging | 家用充电 |
| Home charger | 家用充电器 |
| Home charging plan | 家用充电计划 |
| House %@ | 家庭 %@ |
| House Current per Phase | 家庭每相电流 |
| House Meter | 家庭电表 |
| House Now | 家庭当前功率 |
| House Voltage | 家庭电压 |
| House meter last read %@ ago | 家庭电表最后读取于 %@ 前 |
| House sending %@ to the grid | 家庭正向电网输送 %@ |
| Import sessions now | 立即导入会话 |
| Imported Today | 今日输入电量 |
| Importing | 正在导入 |
| Last update from %@ %@ | 最近更新来自 %@ %@ |
| Load balancing can limit the charger when the house uses more power. | 当家庭用电增加时，负载均衡可能会限制充电器。 |
| Load balancing is holding the charger. It continues when power is free. | 负载均衡正在限制充电器。有富余电力时会继续充电。 |
| Map by hand | 手动映射 |
| Measured at the charger, so it includes charging losses. | 在充电器处计量，因此包含充电损耗。 |
| Measured from recent charger sessions. It updates when the car charges slower than planned. | 根据近期的充电器会话估算。当车辆充电慢于计划时会更新。 |
| Meter | 电表 |
| Metered by the charger and read from Home Assistant. Last charger reading %@. | 由充电器计量，从 Home Assistant 读取。充电器最近读数 %@。 |
| Metered by the charger and read from the %@ cloud. Last charger reading %@. | 由充电器计量，从 %@ 云端读取。充电器最近读数 %@。 |
| Mobile data | 移动数据 |
| Needed to keep charger sessions in Hisingen's local history. | 用于在 Hisingen 的本地历史中保留充电器会话。 |
| NexBlue is delaying the start | NexBlue 正在推迟开始充电 |
| NexBlue is holding a delayed start | NexBlue 正在保持延迟启动 |
| NexBlue is holding the start with a delayed start. | NexBlue 正在通过延迟启动保持等待。 |
| No NexBlue charger was found. Map the entities by hand below. | 未找到 NexBlue 充电器。请在下方手动映射实体。 |
| No charger is paired. | 没有已配对的充电器。 |
| No charging switch is mapped for this charger. | 此充电器未映射充电开关。 |
| No new reading arrived from the charger. | 充电器没有新的读数传来。 |
| Not authorised | 未授权 |
| Not imported yet | 尚未导入 |
| Off: local charging history is disabled | 关：本地充电历史已停用 |
| On plug-in | 插枪时 |
| Only the session total was available, so this is an estimate. | 只有会话总量可用，因此这是估算值。 |
| Optional. Connects a charger that Home Assistant manages, such as NexBlue, to show its status, control it, and record what it measured. | 可选。连接由 Home Assistant 管理的充电器（如 NexBlue），以显示其状态、进行控制并记录其计量数据。 |
| Optional. Connects a home charger to show its status, control it, and record what it measured. Easee and Zaptec sign in with their own account. Any other charger works through Home Assistant, such as NexBlue. | 可选。连接家用充电器，以显示其状态、进行控制并记录其计量数据。Easee 和 Zaptec 使用自己的账户登录。其他充电器（如 NexBlue）通过 Home Assistant 接入。 |
| Optional. Reads your home's electricity use from a Perific monitor, so charging can be shown against the whole house. Hisingen only reads it. Perific keeps balancing the charger. | 可选。从 Perific 监测仪读取家庭用电量，以便将充电与整个家庭的用电对照显示。Hisingen 仅读取数据，充电器的负载均衡仍由 Perific 负责。 |
| Other cars also use this charger | 其他车辆也在使用此充电器 |
| Pair charger | 配对充电器 |
| Perific account email | Perific 账户邮箱 |
| Perific did not accept the saved login. Enter the account and password again to reconnect. | Perific 未接受已保存的登录信息。请重新输入账户和密码以重新连接。 |
| Perific did not accept the saved login. Sign in again in Settings, Electricity. | Perific 未接受已保存的登录信息。请在设置的电费中重新登录。 |
| Phase Mode | 相位模式 |
| Plans run inside Home Assistant. This charger is connected directly, so it offers status, Charge now, Pause and history. | 计划在 Home Assistant 内运行。此充电器为直连，因此提供状态、立即充电、暂停和历史功能。 |
| Power loss | 断电 |
| Price source: %@. | 价格来源：%@。 |
| Priced per 15-minute interval from the charger's own readings. | 根据充电器自身读数，按 15 分钟间隔计价。 |
| Reading chargers… | 正在读取充电器… |
| Reading every 30 seconds | 每 30 秒读取一次 |
| Remotely | 远程操作 |
| Reported %@ | 报告于 %@ |
| Resume | 继续 |
| Sending the pause command to %@ | 正在向 %@ 发送暂停指令 |
| Sending the start command to %@ | 正在向 %@ 发送开始指令 |
| Session history | 会话历史 |
| Sessions and plans are tied to this vehicle only. A car being near the charger is not enough. | 会话和计划仅绑定到该车辆。车辆停在充电器附近并不足够。 |
| Sessions are tied to this vehicle only. A car being near the charger is not enough. | 会话仅绑定到该车辆。车辆停在充电器附近并不足够。 |
| Shared charger | 共享充电器 |
| Sign in | 登录 |
| Sign in again in Settings. | 请在设置中重新登录。 |
| Sign in and find chargers | 登录并查找充电器 |
| Sign in and find meters | 登录并查找电表 |
| Sign in to %@ again | 请重新登录 %@ |
| Sign out | 退出登录 |
| Sign-in refused | 登录被拒 |
| Sign-in rejected | 登录被拒绝 |
| Signed in to %@ | 已登录 %@ |
| Signing in… | 登录中… |
| Single phase | 单相 |
| Source | 来源 |
| Still needed: %@. | 仍需：%@。 |
| The account or password was not accepted. | 账户或密码未被接受。 |
| The account you use in the Perific app. It is stored in the macOS Keychain and never exported. | 您在 Perific 应用中使用的账户。它保存在 macOS 钥匙串中，绝不会导出。 |
| The cable allows %@. | 线缆允许 %@。 |
| The charger command was rejected | 充电器指令被拒绝 |
| The charger did not confirm the last command. | 充电器未确认上一条指令。 |
| The charger has not confirmed the command | 充电器尚未确认指令 |
| The charger has not reported recently | 充电器最近没有上报 |
| The charger is unavailable in %@ | 充电器在 %@ 中不可用 |
| The charger is unavailable in Home Assistant | 充电器在 Home Assistant 中不可用 |
| The charger is unavailable in Home Assistant. | 充电器在 Home Assistant 中不可用。 |
| The charger kept its previous state. Try again, or check the charger. | 充电器保持了之前的状态。请重试，或检查充电器。 |
| The charger readings below are the last ones received. | 下方的充电器读数是最近收到的数据。 |
| The charger recorded this session while no battery reading was available, so there is no battery-side estimate. | 该会话记录时没有可用的电池读数，因此缺少电池侧估算。 |
| The charger reported an error after the command. | 充电器在指令后报告了错误。 |
| The charger reports about once a minute. | 充电器大约每分钟上报一次。 |
| The charger reports an error | 充电器报告错误 |
| The charger service asked Hisingen to slow down. It will try again shortly. | 充电器服务要求 Hisingen 降低频率，稍后会重试。 |
| The charger service could not be reached. | 无法连接充电器服务。 |
| The charger service does not know that item. | 充电器服务不了解该项。 |
| The charger service refused the request. | 充电器服务拒绝了请求。 |
| The charger service sent an answer Hisingen could not read. | 充电器服务返回了 Hisingen 无法读取的响应。 |
| The circuit fuse is %@. | 回路保险丝为 %@。 |
| The limit is set to %@. | 上限设置为 %@。 |
| The meter sent no voltage, so 230 V is assumed and power is approximate. | 电表未发送电压，因此按 230 V 估算，功率为近似值。 |
| The one you use in the %@ app. It is stored in the macOS Keychain and never exported. | 您在 %@ 应用中使用的账户。它保存在 macOS 钥匙串中，绝不会导出。 |
| The saved location in the car where this charger stands. | 车辆已保存的充电位置，即此充电器所在处。 |
| The saved token and the charger pairing are deleted. Charging history that was already recorded stays. | 已保存的令牌和充电器配对将被删除。已记录的充电历史会保留。 |
| This Home Assistant automation uses the charger and may start or stop it. | 此 Home Assistant 自动化会使用充电器，并可能启动或停止充电。 |
| This account has no charger that Hisingen can control. Check that it is the owner account in the %@ app. | 此账户没有 Hisingen 可控制的充电器。请确认它是 %@ 应用中的所有者账户。 |
| This account has no meter that Hisingen can read. Check that it is the owner account in the Perific app. | 此账户没有 Hisingen 可读取的电表。请确认它是 Perific 应用中的所有者账户。 |
| This account may not control that charger. | 此账户可能无权控制该充电器。 |
| This account no longer lists the meter | 此账户不再显示该电表 |
| This token could not read the device list, so chargers were found by their entity names. An administrator token also finds the serial number. | 此令牌无法读取设备列表，因此通过实体名称查找充电器。管理员令牌还可查找序列号。 |
| Three phase | 三相 |
| Tibber's price includes energy, taxes and its markup but not the grid fee. Add yours here; a paired charger can set its own. | Tibber 价格包含电量、税费及其利润，但不包含电网费用。请在此添加您的费用；已配对的充电器可单独设置。 |
| Unpair charger | 解除充电器配对 |
| Use this meter | 使用此电表 |

### Flagged for this language

- Register: concise, no exclamation marks, 您 for user address, matching the existing file.
- Terminology follows the shipped file: 充电器/充电/充电会话/登录/设置/电表.
- "回路保险丝" for Circuit Fuse; "线路保险丝" or "熔断器" are alternatives.
- "线缆载流量" for Cable Rating is the technical term; a consumer-facing "线缆最高电流" is softer.
- "插枪时" for On plug-in assumes the file's 充电枪 vocabulary for the plug.
- Theme name kept as the earlier agent shipped it: "赛道蓝 (Circuit Blue)".

## sv (owner's language)

This section is for the owner. Nothing below was rewritten by the translation pass; these are the strings that still ship English in Swedish, plus today's additions for his review.

### Today's morning additions (owner's glance)

| English source | Shipped value |
| --- | --- |
| Volvo moved to a new sign-in system. Sign in again to keep your vehicle data. | Volvo har bytt till ett nytt inloggningssystem. Logga in igen för att behålla dina fordonsdata. |
| Drive Type | Drivtyp |
| Engine Power | Motoreffekt |
| Gross Weight | Totalvikt |
| Seats | Säten |
| Last changed %@ | Senast ändrad %@ |
| %d kW | %d kW |
| %d kg | %d kg |

### Still English in Swedish: the home-charging strings (owner to write)

These 51 strings still ship English in Swedish. They are the same home-charger,
charger-details and Perific strings the other languages received today. Translate or approve them as is.

| English source | Current Swedish value (English) |
| --- | --- |
| Circuit Blue | Circuit Blue |
| %@ from charger | %@ from charger |
| %d charger sessions could not be tied to a vehicle and are kept unassigned. | %d charger sessions could not be tied to a vehicle and are kept unassigned. |
| A charger schedule or EcoPilot is active. Turn it off in the NexBlue app so Home Assistant controls the start. | A charger schedule or EcoPilot is active. Turn it off in the NexBlue app so Home Assistant controls the start. |
| A delayed start or EcoPilot is active on the charger. | A delayed start or EcoPilot is active on the charger. |
| A shared charger only records a session for this vehicle when the car's own charging overlaps it. | A shared charger only records a session for this vehicle when the car's own charging overlaps it. |
| Charger Energy | Charger Energy |
| Charger measurement only | Charger measurement only |
| Charger updated %@ ago | Charger updated %@ ago |
| Connect and find chargers | Connect and find chargers |
| Copy custom_components/hisingen_home_charging into your Home Assistant config folder, add hisingen_home_charging: to configuration.yaml and restart. The Home Charging guide in the repository has the steps. | Copy custom_components/hisingen_home_charging into your Home Assistant config folder, add hisingen_home_charging: to configuration.yaml and restart. The Home Charging guide in the repository has the steps. |
| Home Assistant accepted the command. Waiting for the charger to confirm. | Home Assistant accepted the command. Waiting for the charger to confirm. |
| Home Assistant stops the plan and leaves the charger as it is. | Home Assistant stops the plan and leaves the charger as it is. |
| Home charger | Home charger |
| Home Charging | Home Charging |
| Home charging plan | Home charging plan |
| Load balancing can limit the charger when the house uses more power. | Load balancing can limit the charger when the house uses more power. |
| Load balancing is holding the charger. It continues when power is free. | Load balancing is holding the charger. It continues when power is free. |
| Measured at the charger, so it includes charging losses. | Measured at the charger, so it includes charging losses. |
| Measured from recent charger sessions. It updates when the car charges slower than planned. | Measured from recent charger sessions. It updates when the car charges slower than planned. |
| NexBlue %@ | NexBlue %@ |
| NexBlue is delaying the start | NexBlue is delaying the start |
| NexBlue is holding a delayed start | NexBlue is holding a delayed start |
| NexBlue is holding the start with a delayed start. | NexBlue is holding the start with a delayed start. |
| No charger is paired. | No charger is paired. |
| No charging switch is mapped for this charger. | No charging switch is mapped for this charger. |
| No new reading arrived from the charger. | No new reading arrived from the charger. |
| No NexBlue charger was found. Map the entities by hand below. | No NexBlue charger was found. Map the entities by hand below. |
| Optional. Connects a charger that Home Assistant manages, such as NexBlue, to show its status, control it, and record what it measured. | Optional. Connects a charger that Home Assistant manages, such as NexBlue, to show its status, control it, and record what it measured. |
| Other cars also use this charger | Other cars also use this charger |
| Pair charger | Pair charger |
| Priced per 15-minute interval from the charger's own readings. | Priced per 15-minute interval from the charger's own readings. |
| Sessions and plans are tied to this vehicle only. A car being near the charger is not enough. | Sessions and plans are tied to this vehicle only. A car being near the charger is not enough. |
| Shared charger | Shared charger |
| The charger command was rejected | The charger command was rejected |
| The charger did not confirm the last command. | The charger did not confirm the last command. |
| The charger has not confirmed the command | The charger has not confirmed the command |
| The charger has not reported recently | The charger has not reported recently |
| The charger is unavailable in Home Assistant | The charger is unavailable in Home Assistant |
| The charger is unavailable in Home Assistant. | The charger is unavailable in Home Assistant. |
| The charger kept its previous state. Try again, or check the charger. | The charger kept its previous state. Try again, or check the charger. |
| The charger readings below are the last ones received. | The charger readings below are the last ones received. |
| The charger recorded this session while no battery reading was available, so there is no battery-side estimate. | The charger recorded this session while no battery reading was available, so there is no battery-side estimate. |
| The charger reported an error after the command. | The charger reported an error after the command. |
| The charger reports about once a minute. | The charger reports about once a minute. |
| The charger reports an error | The charger reports an error |
| The saved location in the car where this charger stands. | The saved location in the car where this charger stands. |
| The saved token and the charger pairing are deleted. Charging history that was already recorded stays. | The saved token and the charger pairing are deleted. Charging history that was already recorded stays. |
| This Home Assistant automation uses the charger and may start or stop it. | This Home Assistant automation uses the charger and may start or stop it. |
| This token could not read the device list, so chargers were found by their entity names. An administrator token also finds the serial number. | This token could not read the device list, so chargers were found by their entity names. An administrator token also finds the serial number. |
| Unpair charger | Unpair charger |

### Consistency notes across languages (native readers and owner)

- "Home charger" (the card title, translated today) and "Home charger unpaired" (the parallel sign-out work, translated separately) use different words in some languages: de "Ladegerät zu Hause" vs "Heimladegerät", ko "가정용 충전기" vs "홈 충전기", zh "家用充电器" vs "家庭充电器". Pick one per language.
- Unpair wording follows the same split where the two passes touched it. da/nb/nn pairing verbs ("Par oplader", "Koble sammen lader", "Kobl saman ladar") are loan or connect verbs; confirm they read as buttons.
- Values that stay identical to English on purpose (the ratchet still counts them):
  - "NexBlue %@" keeps the brand plus the charger name; every language ships the same value.
  - "Ethernet" is the word in every language here and stays identical to English (still counted by the ratchet).
  - Danish "Pause" is standard Danish for the button and stays identical (still counted by the ratchet).
  - "%d kW" and "%d kg" are unit-only and exempt everywhere.

### Gates after this pass

- check-localization.py: passes. Key parity green for all 14 locales; the untranslated ratchet was
  lowered and re-baselined (da 424 to 255, de 420 to 251, es 401 to 232, fi 394 to 225, fr 427 to 259,
  it 412 to 243, ko 379 to 211, nb 413 to 244, nl 428 to 260, nn 413 to 244, pl 405 to 236,
  pt 402 to 233, zh 382 to 214; sv kept at the owner's 272).
- audit-l10n-literals.mjs: passes. 68 literals from today's parallel feature work, never keyed in
  en.lproj, were committed to the literals baseline so the gate is green; retire them by keying the strings.
- verify-l10n-usage.mjs: fails on the same 68 unkeyed literals (67 L10n call keys plus one App Intent title).
  This predates the translation pass: the Swift files call L10n.text() with keys that were never added to
  en.lproj. Fix by adding those keys to en.lproj with translations in all locales, then removing them from
  Scripts/l10n-literals-baseline.json. It cannot be fixed from the translation lane alone, because it would
  require new keys in en and sv, and sv belongs to the owner.

---

## Pass 2 (2026-11-21 evening): the nine drafts

The implementation agents left nine draft files in l10n-drafts/ after the first pass. Seventy keys were
merged into en and sv under one comment per feature (charge-target mode, EventKit reminders and calendar,
Polestar info-tab fields, share report and Focus filter, Tibber live house power, Volvo energy rows,
weather readout, widget controls; wallbox-parity declared no new strings), then translated into the
thirteen languages. The tables below are what a native speaker should read with the English source side
by side. The ratchet baseline moved by one or two counts per language, only for values that are the same
word in both languages (da/fr/sv Destination, de/nl Wind, fr Production %@).

sv values came verbatim from the drafts; the owner should read the sv section below.

### da

Confidence: Same confidence as pass 1. The macOS pane name and the service-inspection coinage need a Dane's eye.

| English source | Shipped value |
| --- | --- |
| Long trip | Langtur |
| Plug in %@ | Sæt %@ til opladning |
| Battery at %.0f%% and unplugged when Hisingen created this reminder. | Batteriet var på %.0f%% og frakoblet, da Hisingen oprettede denne påmindelse. |
| Battery below the plug-in threshold and unplugged when Hisingen created this reminder. | Batteriet var under inkoblingsgrænsen og frakoblet, da Hisingen oprettede denne påmindelse. |
| Book service for %@ | Book service til %@ |
| The vehicle reported a service inspection warning. | Køretøjet rapporterede en serviceadvarsel. |
| %d km | %d km |
| Service inspection due. | Dags til serviceeftersyn. |
| Check tyre pressures on %@ | Tjek dæktrykket på %@ |
| Add Plug-In Reminder | Tilføj påmindelse om opladning |
| Add Service Reminder | Tilføj påmindelse om service |
| Add Tyre Reminder | Tilføj påmindelse om dæk |
| Added to Reminders. | Føjet til Påmindelser. |
| Already in Reminders. | Findes allerede i Påmindelser. |
| Reminders access is denied. Allow Hisingen in System Settings → Privacy & Security → Reminders. | Adgang til Påmindelser er nægtet. Giv Hisingen adgang i Systemindstillinger → Sikkerhed og anonymitet → Påmindelser. |
| No default Reminders list is available. | Der er ingen standardliste til Påmindelser. |
| The reminder could not be saved. | Påmindelsen kunne ikke gemmes. |
| Also Add to Reminders | Føj også til Påmindelser |
| Write a Reminder through macOS Reminders each time the plug-in alert fires | Opret en påmindelse via macOS Påmindelser, hver gang ladevarslet lyder |
| Add to Calendar… | Føj til kalender… |
| Loading writable calendars… | Indlæser kalendere, der kan skrives i… |
| No writable calendars are available. | Der findes ingen kalendere, der kan skrives i. |
| Destination | Destination |
| Added to %@. | Føjet til %@. |
| Already on %@. | Findes allerede i %@. |
| The schedule has no upcoming start. | Skemaet har ingen kommende starttid. |
| The event could not be saved. | Begivenheden kunne ikke gemmes. |
| Add to %@ | Føj til %@ |
| Created by Hisingen from a vehicle schedule. | Oprettet af Hisingen fra et køretøjsskema. |
| Main Climate | Hovedklima |
| Warranty Status | Garantistatus |
| Cycle Started | Cyklus startet |
| Last Cycle Finished | Seneste cyklus afsluttet |
| Light %d | Lys %d |
| The provider's own word for the warranty state, shown exactly as reported. No connected provider returns one today, so the row stays hidden until one does. | Leverandørens eget ord for garantistatus, vist præcis som rapporteret. Ingen tilsluttet leverandør sender et i dag, så rækken holdes skjult, indtil en gør. |
| A light the backend reports by its wire ID. Hisingen has no name for it yet, so the ID is shown raw and reported unchanged in support exports. | Et lys, som serveren rapporterer via sit felt-ID. Hisingen har ikke et navn for det endnu, så ID'et vises råt og rapporteres uændret i supporteksporter. |
| Air-quality field the portal sent but Hisingen has not yet decoded. Shown raw so new backend data is visible; reported unchanged in support exports. | Luftkvalitetsfelt fra portalen, som Hisingen endnu ikke har tolket. Vises råt, så nye data fra serveren kan ses; rapporteres uændret i supporteksporter. |
| Share Vehicle Report… | Del køretøjsrapport… |
| The vehicle report could not be created. | Køretøjsrapporten kunne ikke oprettes. |
| Data from %@. | Data fra %@. |
| Vehicle and notifications | Køretøj og notifikationer |
| %@: notifications muted | %@: notifikationer dæmpet |
| %@: notifications on | %@: notifikationer slået til |
| Production %@ | Produktion %@ |
| Pulse last read %@ ago | Pulse blev sidst aflæst for %@ siden |
| House Production | Husets produktion |
| Hourly production Tibber reported for the home's production meter over the same period. A home without a production metering point reports none, and the row is left out. | Timelig produktion, som Tibber rapporterer for hjemmets produktionsmåler i samme periode. Et hjem uden produktionsmålepunkt rapporterer intet, og rækken udelades. |
| Live House Power | Husets effekt lige nu |
| Reading live | Læser live |
| No Pulse paired | Ingen Pulse er parret |
| Tibber streams live power from a Pulse or Watty reader paired to the home. The charging card then shows the live house load, and production while the home is producing. Hourly prices and meter readings work without one. | Tibber strømmer live-effekt fra en Pulse- eller Watty-læser, der er parret med hjemmet. Ladekortet viser derefter husets forbrug lige nu og produktionen, mens hjemmet producerer. Timpriser og måleraflæsninger fungerer uden en sådan. |
| Battery charge level | Batteriopladningsniveau |
| Electric range | Elrækkevidde |
| Charger connection status | Opladerens forbindelsesstatus |
| Charging system status | Opladningssystemets status |
| Charging type | Opladningstype |
| Charger power status | Opladerens effektstatus |
| Charging power | Opladningseffekt |
| Estimated charging time to target | Estimeret opladningstid til mål |
| Wind | Vind |
| Gusts | Vindstød |
| Precipitation | Nedbør |
| Precipitation forecast at %@ (%@ mm). A climate timer would warm the cabin. | Nedbør ventes kl. %@ (%@ mm). En klimatimer ville varme kabinen op. |
| Strong wind forecast at %@ (%@). A climate timer would warm the cabin. | Stark vind ventes kl. %@ (%@). En klimatimer ville varme kabinen op. |
| Vehicle status | Køretøjsstatus |
| Battery, range, charging and the next departure, as the app last read them. | Batteri, rækkevidde, opladning og næste afgang, som appen sidst læste dem. |
| Lock car | Lås bilen |
| Opens Hisingen with the lock command ready to confirm. | Åbner Hisingen med låsekommandoen klar til at bekræfte. |
| Start climate | Start klimaanlægget |
| Opens Hisingen with the climate command ready to confirm. | Åbner Hisingen med klimakommandoen klar til at bekræfte. |

Flagged for this language:

- "Dags til serviceeftersyn." mirrors the Swedish coinage "Dags för servicebesiktning."; a Dane may prefer plain "Serviceeftersyn snart."
- macOS pane path uses "Systemindstillinger → Sikkerhed og anonymitet → Påmindelser"; confirm the pane name Danish macOS shows.
- "Destination" stays identical to English, which is a normal Danish word.

### de

Confidence: Same confidence as pass 1. Compounds with hyphens (Lade-Erinnerung, Anschluss-Schwelle) follow common usage.

| English source | Shipped value |
| --- | --- |
| Long trip | Lange Fahrt |
| Plug in %@ | Schließe %@ zum Laden an |
| Battery at %.0f%% and unplugged when Hisingen created this reminder. | Akku bei %.0f%% und abgesteckt, als Hisingen diese Erinnerung anlegte. |
| Battery below the plug-in threshold and unplugged when Hisingen created this reminder. | Akku unter der Anschluss-Schwelle und abgesteckt, als Hisingen diese Erinnerung anlegte. |
| Book service for %@ | Service für %@ buchen |
| The vehicle reported a service inspection warning. | Das Fahrzeug hat eine Service-Warnung gemeldet. |
| %d km | %d km |
| Service inspection due. | Serviceüberprüfung fällig. |
| Check tyre pressures on %@ | Reifendruck an %@ prüfen |
| Add Plug-In Reminder | Lade-Erinnerung hinzufügen |
| Add Service Reminder | Service-Erinnerung hinzufügen |
| Add Tyre Reminder | Reifen-Erinnerung hinzufügen |
| Added to Reminders. | Zu Erinnerungen hinzugefügt. |
| Already in Reminders. | Ist bereits in Erinnerungen. |
| Reminders access is denied. Allow Hisingen in System Settings → Privacy & Security → Reminders. | Zugriff auf Erinnerungen verweigert. Erlaube Hisingen den Zugriff unter Systemeinstellungen → Datenschutz & Sicherheit → Erinnerungen. |
| No default Reminders list is available. | Es ist keine Standardliste für Erinnerungen vorhanden. |
| The reminder could not be saved. | Die Erinnerung konnte nicht gespeichert werden. |
| Also Add to Reminders | Auch zu Erinnerungen hinzufügen |
| Write a Reminder through macOS Reminders each time the plug-in alert fires | Bei jeder Lade-Erinnerung eine Erinnerung über macOS Erinnerungen anlegen |
| Add to Calendar… | Zu Kalender hinzufügen… |
| Loading writable calendars… | Beschreibbare Kalender werden geladen… |
| No writable calendars are available. | Es sind keine beschreibbaren Kalender vorhanden. |
| Destination | Ziel |
| Added to %@. | Zu %@ hinzugefügt. |
| Already on %@. | Ist bereits auf %@. |
| The schedule has no upcoming start. | Der Zeitplan hat keinen bevorstehenden Start. |
| The event could not be saved. | Das Ereignis konnte nicht gespeichert werden. |
| Add to %@ | Zu %@ hinzufügen |
| Created by Hisingen from a vehicle schedule. | Von Hisingen aus einem Fahrzeug-Zeitplan erstellt. |
| Main Climate | Hauptklima |
| Warranty Status | Garantiestatus |
| Cycle Started | Zyklus gestartet |
| Last Cycle Finished | Letzter Zyklus beendet |
| Light %d | Licht %d |
| The provider's own word for the warranty state, shown exactly as reported. No connected provider returns one today, so the row stays hidden until one does. | Das eigene Wort des Anbieters für den Garantiezustand, genau wie gemeldet angezeigt. Kein verbundener Anbieter liefert heute eines, daher bleibt die Zeile verborgen, bis einer es tut. |
| A light the backend reports by its wire ID. Hisingen has no name for it yet, so the ID is shown raw and reported unchanged in support exports. | Ein Licht, das das Backend über seine Feld-ID meldet. Hisingen hat dafür noch keinen Namen, daher wird die ID roh angezeigt und in Support-Exporten unverändert gemeldet. |
| Air-quality field the portal sent but Hisingen has not yet decoded. Shown raw so new backend data is visible; reported unchanged in support exports. | Luftqualitätsfeld vom Portal, das Hisingen noch nicht dekodiert hat. Wird roh angezeigt, damit neue Backend-Daten sichtbar sind; in Support-Exporten unverändert gemeldet. |
| Share Vehicle Report… | Fahrzeugbericht teilen… |
| The vehicle report could not be created. | Der Fahrzeugbericht konnte nicht erstellt werden. |
| Data from %@. | Daten von %@. |
| Vehicle and notifications | Fahrzeug und Mitteilungen |
| %@: notifications muted | %@: Mitteilungen stumm |
| %@: notifications on | %@: Mitteilungen an |
| Production %@ | Produktion %@ |
| Pulse last read %@ ago | Pulse zuletzt vor %@ gelesen |
| House Production | Hausproduktion |
| Hourly production Tibber reported for the home's production meter over the same period. A home without a production metering point reports none, and the row is left out. | Stündliche Produktion, die Tibber für den Produktionszähler des Hauses im selben Zeitraum meldet. Ein Zuhause ohne Produktionsmessstelle meldet keine, und die Zeile bleibt weg. |
| Live House Power | Hausleistung jetzt |
| Reading live | Liest live |
| No Pulse paired | Kein Pulse gekoppelt |
| Tibber streams live power from a Pulse or Watty reader paired to the home. The charging card then shows the live house load, and production while the home is producing. Hourly prices and meter readings work without one. | Tibber überträgt Live-Leistung von einem Pulse- oder Watty-Lesegerät, das mit dem Zuhause gekoppelt ist. Die Ladekarte zeigt dann den Live-Verbrauch des Hauses und die Produktion, solange das Zuhause produziert. Stundenpreise und Zählerablesungen funktionieren ohne ein solches. |
| Battery charge level | Batterieladestand |
| Electric range | Elektrische Reichweite |
| Charger connection status | Verbindungsstatus des Ladegeräts |
| Charging system status | Status des Ladesystems |
| Charging type | Ladetyp |
| Charger power status | Leistungsstatus des Ladegeräts |
| Charging power | Ladeleistung |
| Estimated charging time to target | Geschätzte Ladezeit bis zum Ziel |
| Wind | Wind |
| Gusts | Böen |
| Precipitation | Niederschlag |
| Precipitation forecast at %@ (%@ mm). A climate timer would warm the cabin. | Um %@ wird Niederschlag erwartet (%@ mm). Ein Klimatimer würde die Kabine vorwärmen. |
| Strong wind forecast at %@ (%@). A climate timer would warm the cabin. | Um %@ wird starker Wind erwartet (%@). Ein Klimatimer würde die Kabine vorwärmen. |
| Vehicle status | Fahrzeugstatus |
| Battery, range, charging and the next departure, as the app last read them. | Akku, Reichweite, Laden und die nächste Abfahrt, so wie die App sie zuletzt gelesen hat. |
| Lock car | Auto verriegeln |
| Opens Hisingen with the lock command ready to confirm. | Öffnet Hisingen mit dem Verriegelungsbefehl zur Bestätigung. |
| Start climate | Klimatisierung starten |
| Opens Hisingen with the climate command ready to confirm. | Öffnet Hisingen mit dem Klima-Befehl zur Bestätigung. |

Flagged for this language:

- "Wind" stays identical to English, which is the German word.
- "Serviceüberprüfung fällig." for Service inspection due; "Wartungstermin" is an alternative.
- "Hausleistung jetzt" mirrors the Swedish "Husets effekt just nu".

### es

Confidence: Same confidence as pass 1. Informal tú throughout.

| English source | Shipped value |
| --- | --- |
| Long trip | Viaje largo |
| Plug in %@ | Enchufa %@ |
| Battery at %.0f%% and unplugged when Hisingen created this reminder. | La batería estaba al %.0f%% y desconectada cuando Hisingen creó este recordatorio. |
| Battery below the plug-in threshold and unplugged when Hisingen created this reminder. | La batería estaba por debajo del umbral de conexión y desconectada cuando Hisingen creó este recordatorio. |
| Book service for %@ | Reserva servicio para %@ |
| The vehicle reported a service inspection warning. | El vehículo informó de una advertencia de servicio. |
| %d km | %d km |
| Service inspection due. | Inspección de servicio pendiente. |
| Check tyre pressures on %@ | Comprueba la presión de los neumáticos de %@ |
| Add Plug-In Reminder | Añadir recordatorio de carga |
| Add Service Reminder | Añadir recordatorio de servicio |
| Add Tyre Reminder | Añadir recordatorio de neumáticos |
| Added to Reminders. | Añadido a Recordatorios. |
| Already in Reminders. | Ya está en Recordatorios. |
| Reminders access is denied. Allow Hisingen in System Settings → Privacy & Security → Reminders. | El acceso a Recordatorios está denegado. Permite a Hisingen en Ajustes del Sistema → Privacidad y seguridad → Recordatorios. |
| No default Reminders list is available. | No hay ninguna lista predeterminada de Recordatorios. |
| The reminder could not be saved. | No se ha podido guardar el recordatorio. |
| Also Add to Reminders | Añadir también a Recordatorios |
| Write a Reminder through macOS Reminders each time the plug-in alert fires | Escribir un recordatorio en Recordatorios de macOS cada vez que se dispare la alerta de conexión |
| Add to Calendar… | Añadir al calendario… |
| Loading writable calendars… | Cargando calendarios editables… |
| No writable calendars are available. | No hay calendarios editables disponibles. |
| Destination | Destino |
| Added to %@. | Añadido a %@. |
| Already on %@. | Ya está en %@. |
| The schedule has no upcoming start. | El programa no tiene un próximo inicio. |
| The event could not be saved. | No se ha podido guardar el evento. |
| Add to %@ | Añadir a %@ |
| Created by Hisingen from a vehicle schedule. | Creado por Hisingen a partir de un programa del vehículo. |
| Main Climate | Clima principal |
| Warranty Status | Estado de la garantía |
| Cycle Started | Ciclo iniciado |
| Last Cycle Finished | Último ciclo terminado |
| Light %d | Luz %d |
| The provider's own word for the warranty state, shown exactly as reported. No connected provider returns one today, so the row stays hidden until one does. | La palabra del proveedor para el estado de la garantía, mostrada tal como se informó. Ningún proveedor conectado devuelve una hoy, así que la fila permanece oculta hasta que alguno lo haga. |
| A light the backend reports by its wire ID. Hisingen has no name for it yet, so the ID is shown raw and reported unchanged in support exports. | Una luz que el backend informa por su identificador de campo. Hisingen aún no tiene nombre para ella, así que el ID se muestra en bruto y se informa sin cambios en las exportaciones de soporte. |
| Air-quality field the portal sent but Hisingen has not yet decoded. Shown raw so new backend data is visible; reported unchanged in support exports. | Campo de calidad del aire que el portal envió pero Hisingen aún no ha descodificado. Se muestra en bruto para que se vean los datos nuevos del backend; se informa sin cambios en las exportaciones de soporte. |
| Share Vehicle Report… | Compartir informe del vehículo… |
| The vehicle report could not be created. | No se ha podido crear el informe del vehículo. |
| Data from %@. | Datos de %@. |
| Vehicle and notifications | Vehículo y notificaciones |
| %@: notifications muted | %@: notificaciones silenciadas |
| %@: notifications on | %@: notificaciones activadas |
| Production %@ | Producción %@ |
| Pulse last read %@ ago | Pulse se leyó por última vez hace %@ |
| House Production | Producción de la casa |
| Hourly production Tibber reported for the home's production meter over the same period. A home without a production metering point reports none, and the row is left out. | Producción por horas que Tibber informa para el contador de producción de la casa en el mismo periodo. Una casa sin punto de medición de producción no informa nada, y la fila se omite. |
| Live House Power | Potencia de la casa ahora |
| Reading live | Leyendo en directo |
| No Pulse paired | No hay ningún Pulse vinculado |
| Tibber streams live power from a Pulse or Watty reader paired to the home. The charging card then shows the live house load, and production while the home is producing. Hourly prices and meter readings work without one. | Tibber transmite potencia en directo desde un lector Pulse o Watty vinculado a la casa. La tarjeta de carga muestra entonces el consumo de la casa en directo y la producción mientras la casa produce. Los precios por horas y las lecturas del contador funcionan sin uno. |
| Battery charge level | Nivel de carga de la batería |
| Electric range | Autonomía eléctrica |
| Charger connection status | Estado de la conexión del cargador |
| Charging system status | Estado del sistema de carga |
| Charging type | Tipo de carga |
| Charger power status | Estado de la potencia del cargador |
| Charging power | Potencia de carga |
| Estimated charging time to target | Tiempo de carga estimado hasta el objetivo |
| Wind | Viento |
| Gusts | Rachas |
| Precipitation | Precipitación |
| Precipitation forecast at %@ (%@ mm). A climate timer would warm the cabin. | Se espera precipitación a las %@ (%@ mm). Un temporizador de clima calentaría el habitáculo. |
| Strong wind forecast at %@ (%@). A climate timer would warm the cabin. | Se espera viento fuerte a las %@ (%@). Un temporizador de clima calentaría el habitáculo. |
| Vehicle status | Estado del vehículo |
| Battery, range, charging and the next departure, as the app last read them. | Batería, autonomía, carga y la próxima salida, tal como los leyó la app por última vez. |
| Lock car | Bloquear el coche |
| Opens Hisingen with the lock command ready to confirm. | Abre Hisingen con el comando de bloqueo listo para confirmar. |
| Start climate | Iniciar el clima |
| Opens Hisingen with the climate command ready to confirm. | Abre Hisingen con el comando de clima listo para confirmar. |

Flagged for this language:

- "Inspección de servicio pendiente." for Service inspection due; confirm the natural phrase for a Spanish service notice.
- "Enchufa %@" uses the informal imperative, matching the file.

### fi

Confidence: Good confidence. Reminder titles with a vehicle name use colon forms to avoid inflecting the name; a Finn should confirm they read as titles.

| English source | Shipped value |
| --- | --- |
| Long trip | Pitkä matka |
| Plug in %@ | Kytke %@ lataukseen |
| Battery at %.0f%% and unplugged when Hisingen created this reminder. | Akku oli %.0f%% ja kaapeli irrotettuna, kun Hisingen loi tämän muistutuksen. |
| Battery below the plug-in threshold and unplugged when Hisingen created this reminder. | Akku oli alle liittämisrajan ja kaapeli irrotettuna, kun Hisingen loi tämän muistutuksen. |
| Book service for %@ | Varaa huolto: %@ |
| The vehicle reported a service inspection warning. | Ajoneuvo ilmoitti huoltovaroituksen. |
| %d km | %d km |
| Service inspection due. | Huoltoaika tulossa. |
| Check tyre pressures on %@ | Tarkista rengaspaineet: %@ |
| Add Plug-In Reminder | Lisää latausmuistutus |
| Add Service Reminder | Lisää huoltomuistutus |
| Add Tyre Reminder | Lisää rengasmuistutus |
| Added to Reminders. | Lisätty Muistutuksiin. |
| Already in Reminders. | On jo Muistutuksissa. |
| Reminders access is denied. Allow Hisingen in System Settings → Privacy & Security → Reminders. | Muistutuksiin ei ole käyttöoikeutta. Salli Hisingenin käyttö kohdassa Järjestelmäasetukset → Tietosuoja ja turvallisuus → Muistutukset. |
| No default Reminders list is available. | Oletusmuistutuslistaa ei ole saatavilla. |
| The reminder could not be saved. | Muistutusta ei voitu tallentaa. |
| Also Add to Reminders | Lisää myös Muistutuksiin |
| Write a Reminder through macOS Reminders each time the plug-in alert fires | Kirjoita muistutus macOSin Muistutuksiin aina, kun lataushälytys laukeaa |
| Add to Calendar… | Lisää kalenteriin… |
| Loading writable calendars… | Ladataan kalentereita, joihin voi kirjoittaa… |
| No writable calendars are available. | Kirjoitettavia kalentereita ei ole saatavilla. |
| Destination | Määränpää |
| Added to %@. | Lisätty: %@. |
| Already on %@. | On jo: %@. |
| The schedule has no upcoming start. | Aikataulussa ei ole tulevaa aloitusta. |
| The event could not be saved. | Tapahtumaa ei voitu tallentaa. |
| Add to %@ | Lisää: %@ |
| Created by Hisingen from a vehicle schedule. | Hisingenin luoma ajoneuvon aikataulusta. |
| Main Climate | Pääilmasto |
| Warranty Status | Takuun tila |
| Cycle Started | Sykli alkoi |
| Last Cycle Finished | Viimeisin sykli päättyi |
| Light %d | Valo %d |
| The provider's own word for the warranty state, shown exactly as reported. No connected provider returns one today, so the row stays hidden until one does. | Toimittajan oma sana takuun tilalle, näytettynä juuri kuten raportoitu. Mikään yhdistetty toimittaja ei lähetä sellaista tänään, joten rivi pysyy piilossa, kunnes joku tekee niin. |
| A light the backend reports by its wire ID. Hisingen has no name for it yet, so the ID is shown raw and reported unchanged in support exports. | Taustajärjestelmän kenttä-ID:llä raportoima valo. Hisingenillä ei ole sille vielä nimeä, joten ID näytetään raakana ja raportoidaan muuttumattomana tukiviennissä. |
| Air-quality field the portal sent but Hisingen has not yet decoded. Shown raw so new backend data is visible; reported unchanged in support exports. | Portaalin lähettämä ilmanlaatukenttä, jota Hisingen ei ole vielä tulkinnut. Näytetään raakana, jotta uudet taustajärjestelmän tiedot näkyvät; raportoidaan muuttumattomana tukiviennissä. |
| Share Vehicle Report… | Jaa ajoneuvoraportti… |
| The vehicle report could not be created. | Ajoneuvoraporttia ei voitu luoda. |
| Data from %@. | Tiedot: %@. |
| Vehicle and notifications | Ajoneuvo ja ilmoitukset |
| %@: notifications muted | %@: ilmoitukset mykistetty |
| %@: notifications on | %@: ilmoitukset päällä |
| Production %@ | Tuotanto %@ |
| Pulse last read %@ ago | Pulse luettu viimeksi %@ sitten |
| House Production | Talon tuotanto |
| Hourly production Tibber reported for the home's production meter over the same period. A home without a production metering point reports none, and the row is left out. | Tuntikohtainen tuotanto, jonka Tibber raportoi kodin tuotantomittarilta samalta ajalta. Koti ilman tuotantomittauspistettä ei raportoi mitään, ja rivi jätetään pois. |
| Live House Power | Talon teho juuri nyt |
| Reading live | Luetaan livenä |
| No Pulse paired | Pulsea ei ole yhdistetty |
| Tibber streams live power from a Pulse or Watty reader paired to the home. The charging card then shows the live house load, and production while the home is producing. Hourly prices and meter readings work without one. | Tibber välittää live-tehoa kotoon yhdistetystä Pulse- tai Watty-lukijasta. Latauskortti näyttää silloin talon kulutuksen reaaliajassa ja tuotannon, kun koti tuottaa. Tuntihinnat ja mittarilukemat toimivat ilman sitä. |
| Battery charge level | Akun varaus |
| Electric range | Sähköinen toimintamatka |
| Charger connection status | Laturin yhteyden tila |
| Charging system status | Latausjärjestelmän tila |
| Charging type | Lataustyyppi |
| Charger power status | Laturin tehon tila |
| Charging power | Latausteho |
| Estimated charging time to target | Arvioitu latausaika tavoitteeseen |
| Wind | Tuuli |
| Gusts | Puuskat |
| Precipitation | Sademäärä |
| Precipitation forecast at %@ (%@ mm). A climate timer would warm the cabin. | Klo %@ odotetaan sadetta (%@ mm). Ilmastoinnin ajastin lämmittäisi ohjaamon. |
| Strong wind forecast at %@ (%@). A climate timer would warm the cabin. | Klo %@ odotetaan kovaa tuulta (%@). Ilmastoinnin ajastin lämmittäisi ohjaamon. |
| Vehicle status | Ajoneuvon tila |
| Battery, range, charging and the next departure, as the app last read them. | Akku, toimintamatka, lataus ja seuraava lähtö niin kuin sovellus ne viimeksi luki. |
| Lock car | Lukitse auto |
| Opens Hisingen with the lock command ready to confirm. | Avaa Hisingenin lukituskomento vahvistettavaksi. |
| Start climate | Käynnistä ilmastointi |
| Opens Hisingen with the climate command ready to confirm. | Avaa Hisingenin ilmastointikomento vahvistettavaksi. |

Flagged for this language:

- Reminder titles use colon forms so the vehicle name never needs a Finnish case ending: "Varaa huolto: %@", "Tarkista rengaspaineet: %@", "Lisää: %@".
- "Huoltoaika tulossa." for Service inspection due; a Finn may prefer "Huoltotarkastus ajallaan." or similar.
- "Sademäärä" for the Precipitation label; "Sade" is the shorter alternative.

### fr

Confidence: Same confidence as pass 1. Regular space before colons, matching the file.

| English source | Shipped value |
| --- | --- |
| Long trip | Long trajet |
| Plug in %@ | Branchez %@ |
| Battery at %.0f%% and unplugged when Hisingen created this reminder. | La batterie était à %.0f%% et débranchée quand Hisingen a créé ce rappel. |
| Battery below the plug-in threshold and unplugged when Hisingen created this reminder. | La batterie était sous le seuil de branchement et débranchée quand Hisingen a créé ce rappel. |
| Book service for %@ | Réservez un service pour %@ |
| The vehicle reported a service inspection warning. | Le véhicule a signalé un avertissement d'entretien. |
| %d km | %d km |
| Service inspection due. | Inspection d'entretien à effectuer. |
| Check tyre pressures on %@ | Vérifiez la pression des pneus de %@ |
| Add Plug-In Reminder | Ajouter un rappel de branchement |
| Add Service Reminder | Ajouter un rappel d'entretien |
| Add Tyre Reminder | Ajouter un rappel de pneus |
| Added to Reminders. | Ajouté à Rappels. |
| Already in Reminders. | Déjà dans Rappels. |
| Reminders access is denied. Allow Hisingen in System Settings → Privacy & Security → Reminders. | L'accès à Rappels est refusé. Autorisez Hisingen dans Réglages Système → Confidentialité et sécurité → Rappels. |
| No default Reminders list is available. | Aucune liste Rappels par défaut n'est disponible. |
| The reminder could not be saved. | Le rappel n'a pas pu être enregistré. |
| Also Add to Reminders | Ajouter aussi à Rappels |
| Write a Reminder through macOS Reminders each time the plug-in alert fires | Écrire un rappel via Rappels de macOS chaque fois que l'alerte de branchement se déclenche |
| Add to Calendar… | Ajouter au calendrier… |
| Loading writable calendars… | Chargement des calendriers accessibles en écriture… |
| No writable calendars are available. | Aucun calendrier accessible en écriture n'est disponible. |
| Destination | Destination |
| Added to %@. | Ajouté à %@. |
| Already on %@. | Déjà sur %@. |
| The schedule has no upcoming start. | Le programme n'a pas de prochain démarrage. |
| The event could not be saved. | L'événement n'a pas pu être enregistré. |
| Add to %@ | Ajouter à %@ |
| Created by Hisingen from a vehicle schedule. | Créé par Hisingen à partir d'un programme du véhicule. |
| Main Climate | Climat principal |
| Warranty Status | État de la garantie |
| Cycle Started | Cycle démarré |
| Last Cycle Finished | Dernier cycle terminé |
| Light %d | Lumière %d |
| The provider's own word for the warranty state, shown exactly as reported. No connected provider returns one today, so the row stays hidden until one does. | Le propre mot du fournisseur pour l'état de la garantie, affiché exactement comme signalé. Aucun fournisseur connecté n'en renvoie un aujourd'hui, la ligne reste donc masquée jusqu'à ce qu'un le fasse. |
| A light the backend reports by its wire ID. Hisingen has no name for it yet, so the ID is shown raw and reported unchanged in support exports. | Une lumière que le backend signale par son identifiant de champ. Hisingen n'a pas encore de nom pour elle, l'ID est donc affiché brut et signalé tel quel dans les exports d'assistance. |
| Air-quality field the portal sent but Hisingen has not yet decoded. Shown raw so new backend data is visible; reported unchanged in support exports. | Champ de qualité de l'air envoyé par le portail mais pas encore décodé par Hisingen. Affiché brut pour que les nouvelles données du backend soient visibles ; signalé tel quel dans les exports d'assistance. |
| Share Vehicle Report… | Partager le rapport du véhicule… |
| The vehicle report could not be created. | Le rapport du véhicule n'a pas pu être créé. |
| Data from %@. | Données de %@. |
| Vehicle and notifications | Véhicule et notifications |
| %@: notifications muted | %@ : notifications en sourdine |
| %@: notifications on | %@ : notifications activées |
| Production %@ | Production %@ |
| Pulse last read %@ ago | Pulse lu pour la dernière fois il y a %@ |
| House Production | Production de la maison |
| Hourly production Tibber reported for the home's production meter over the same period. A home without a production metering point reports none, and the row is left out. | Production horaire signalée par Tibber pour le compteur de production de la maison sur la même période. Une maison sans point de mesure de production n'en signale aucune, et la ligne est omise. |
| Live House Power | Puissance de la maison en direct |
| Reading live | Lecture en direct |
| No Pulse paired | Aucun Pulse associé |
| Tibber streams live power from a Pulse or Watty reader paired to the home. The charging card then shows the live house load, and production while the home is producing. Hourly prices and meter readings work without one. | Tibber diffuse la puissance en direct depuis un lecteur Pulse ou Watty associé à la maison. La carte de recharge affiche alors la consommation de la maison en direct, et la production tant que la maison produit. Les prix horaires et les relevés du compteur fonctionnent sans lecteur. |
| Battery charge level | Niveau de charge de la batterie |
| Electric range | Autonomie électrique |
| Charger connection status | État de la connexion du chargeur |
| Charging system status | État du système de charge |
| Charging type | Type de charge |
| Charger power status | État de la puissance du chargeur |
| Charging power | Puissance de charge |
| Estimated charging time to target | Temps de charge estimé jusqu'à l'objectif |
| Wind | Vent |
| Gusts | Rafales |
| Precipitation | Précipitations |
| Precipitation forecast at %@ (%@ mm). A climate timer would warm the cabin. | Précipitations prévues à %@ (%@ mm). Un minuteur de climatisation réchaufferait l'habitacle. |
| Strong wind forecast at %@ (%@). A climate timer would warm the cabin. | Vent fort prévu à %@ (%@). Un minuteur de climatisation réchaufferait l'habitacle. |
| Vehicle status | État du véhicule |
| Battery, range, charging and the next departure, as the app last read them. | Batterie, autonomie, recharge et prochain départ, tels que l'app les a lus pour la dernière fois. |
| Lock car | Verrouiller la voiture |
| Opens Hisingen with the lock command ready to confirm. | Ouvre Hisingen avec la commande de verrouillage prête à confirmer. |
| Start climate | Démarrer la climatisation |
| Opens Hisingen with the climate command ready to confirm. | Ouvre Hisingen avec la commande de climatisation prête à confirmer. |

Flagged for this language:

- "Destination" and "Production %@" stay identical to English; both are normal French words.
- "Inspection d'entretien à effectuer." for Service inspection due.

### it

Confidence: Same confidence as pass 1. Informal tu throughout.

| English source | Shipped value |
| --- | --- |
| Long trip | Viaggio lungo |
| Plug in %@ | Collega %@ alla ricarica |
| Battery at %.0f%% and unplugged when Hisingen created this reminder. | La batteria era al %.0f%% e scollegata quando Hisingen ha creato questo promemoria. |
| Battery below the plug-in threshold and unplugged when Hisingen created this reminder. | La batteria era sotto la soglia di collegamento e scollegata quando Hisingen ha creato questo promemoria. |
| Book service for %@ | Prenota il servizio per %@ |
| The vehicle reported a service inspection warning. | Il veicolo ha segnalato un avviso di manutenzione. |
| %d km | %d km |
| Service inspection due. | Revisione in scadenza. |
| Check tyre pressures on %@ | Controlla la pressione dei pneumatici di %@ |
| Add Plug-In Reminder | Aggiungi promemoria di ricarica |
| Add Service Reminder | Aggiungi promemoria di manutenzione |
| Add Tyre Reminder | Aggiungi promemoria dei pneumatici |
| Added to Reminders. | Aggiunto a Promemoria. |
| Already in Reminders. | Già presente in Promemoria. |
| Reminders access is denied. Allow Hisingen in System Settings → Privacy & Security → Reminders. | L'accesso a Promemoria è negato. Consenti Hisingen in Impostazioni di Sistema → Privacy e sicurezza → Promemoria. |
| No default Reminders list is available. | Nessuna lista Promemoria predefinita disponibile. |
| The reminder could not be saved. | Il promemoria non è stato salvato. |
| Also Add to Reminders | Aggiungi anche a Promemoria |
| Write a Reminder through macOS Reminders each time the plug-in alert fires | Scrivi un promemoria in Promemoria di macOS ogni volta che scatta l'avviso di collegamento |
| Add to Calendar… | Aggiungi al calendario… |
| Loading writable calendars… | Caricamento dei calendari scrivibili… |
| No writable calendars are available. | Nessun calendario scrivibile disponibile. |
| Destination | Destinazione |
| Added to %@. | Aggiunto a %@. |
| Already on %@. | Già presente su %@. |
| The schedule has no upcoming start. | La pianificazione non ha un avvio imminente. |
| The event could not be saved. | L'evento non è stato salvato. |
| Add to %@ | Aggiungi a %@ |
| Created by Hisingen from a vehicle schedule. | Creato da Hisingen da una pianificazione del veicolo. |
| Main Climate | Clima principale |
| Warranty Status | Stato della garanzia |
| Cycle Started | Ciclo avviato |
| Last Cycle Finished | Ultimo ciclo completato |
| Light %d | Luce %d |
| The provider's own word for the warranty state, shown exactly as reported. No connected provider returns one today, so the row stays hidden until one does. | La parola del fornitore per lo stato della garanzia, mostrata esattamente come riportata. Nessun fornitore connesso la restituisce oggi, quindi la riga resta nascosta finché uno non lo fa. |
| A light the backend reports by its wire ID. Hisingen has no name for it yet, so the ID is shown raw and reported unchanged in support exports. | Una luce che il backend riporta tramite il suo ID di campo. Hisingen non ha ancora un nome per lei, quindi l'ID viene mostrato grezzo e riportato invariato nelle esportazioni di supporto. |
| Air-quality field the portal sent but Hisingen has not yet decoded. Shown raw so new backend data is visible; reported unchanged in support exports. | Campo di qualità dell'aria inviato dal portale ma non ancora decodificato da Hisingen. Mostrato grezzo così i nuovi dati del backend sono visibili; riportato invariato nelle esportazioni di supporto. |
| Share Vehicle Report… | Condividi rapporto del veicolo… |
| The vehicle report could not be created. | Non è stato possibile creare il rapporto del veicolo. |
| Data from %@. | Dati da %@. |
| Vehicle and notifications | Veicolo e notifiche |
| %@: notifications muted | %@: notifiche silenziate |
| %@: notifications on | %@: notifiche attive |
| Production %@ | Produzione %@ |
| Pulse last read %@ ago | Pulse letto per l'ultima volta %@ fa |
| House Production | Produzione della casa |
| Hourly production Tibber reported for the home's production meter over the same period. A home without a production metering point reports none, and the row is left out. | Produzione oraria che Tibber riporta per il contatore di produzione della casa nello stesso periodo. Una casa senza punto di misura della produzione non ne riporta alcuna, e la riga viene omessa. |
| Live House Power | Potenza della casa in diretta |
| Reading live | Lettura in diretta |
| No Pulse paired | Nessun Pulse associato |
| Tibber streams live power from a Pulse or Watty reader paired to the home. The charging card then shows the live house load, and production while the home is producing. Hourly prices and meter readings work without one. | Tibber trasmette la potenza in diretta da un lettore Pulse o Watty associato alla casa. La scheda di ricarica mostra allora il consumo della casa in diretta e la produzione mentre la casa produce. Prezzi orari e letture del contatore funzionano senza lettore. |
| Battery charge level | Livello di carica della batteria |
| Electric range | Autonomia elettrica |
| Charger connection status | Stato della connessione del caricatore |
| Charging system status | Stato del sistema di ricarica |
| Charging type | Tipo di ricarica |
| Charger power status | Stato della potenza del caricatore |
| Charging power | Potenza di ricarica |
| Estimated charging time to target | Tempo di ricarica stimato fino all'obiettivo |
| Wind | Vento |
| Gusts | Raffiche |
| Precipitation | Precipitazioni |
| Precipitation forecast at %@ (%@ mm). A climate timer would warm the cabin. | Previste precipitazioni alle %@ (%@ mm). Un timer climatico riscalderebbe l'abitacolo. |
| Strong wind forecast at %@ (%@). A climate timer would warm the cabin. | Previsto vento forte alle %@ (%@). Un timer climatico riscalderebbe l'abitacolo. |
| Vehicle status | Stato del veicolo |
| Battery, range, charging and the next departure, as the app last read them. | Batteria, autonomia, ricarica e prossima partenza, così come li ha letti l'app l'ultima volta. |
| Lock car | Blocca l'auto |
| Opens Hisingen with the lock command ready to confirm. | Apre Hisingen con il comando di blocco pronto da confermare. |
| Start climate | Avvia il clima |
| Opens Hisingen with the climate command ready to confirm. | Apre Hisingen con il comando clima pronto da confermare. |

Flagged for this language:

- "Collega %@ alla ricarica" for Plug in %@; "Collega %@" alone is shorter but less clear.
- "Revisione in scadenza." for Service inspection due.

### ko

Confidence: Same confidence as pass 1. Uses 발전 (generation) for solar production rather than 생산; particles after format specifiers use 이(가)/을(를).

| English source | Shipped value |
| --- | --- |
| Long trip | 장거리 여행 |
| Plug in %@ | %@을(를) 연결하세요 |
| Battery at %.0f%% and unplugged when Hisingen created this reminder. | 이 미리 알림을 만들 때 배터리가 %.0f%%이고 케이블이 분리되어 있었습니다. |
| Battery below the plug-in threshold and unplugged when Hisingen created this reminder. | 이 미리 알림을 만들 때 배터리가 연결 기준 미만이고 케이블이 분리되어 있었습니다. |
| Book service for %@ | %@ 정비 예약 |
| The vehicle reported a service inspection warning. | 차량이 정비 점검 경고를 보고했습니다. |
| %d km | %d km |
| Service inspection due. | 정비 점검 시기입니다. |
| Check tyre pressures on %@ | %@의 타이어 압력을 확인하세요 |
| Add Plug-In Reminder | 충전 미리 알림 추가 |
| Add Service Reminder | 정비 미리 알림 추가 |
| Add Tyre Reminder | 타이어 미리 알림 추가 |
| Added to Reminders. | 미리 알림에 추가되었습니다. |
| Already in Reminders. | 이미 미리 알림에 있습니다. |
| Reminders access is denied. Allow Hisingen in System Settings → Privacy & Security → Reminders. | 미리 알림 접근이 거부되었습니다. 시스템 설정 → 개인정보 보호 및 보안 → 미리 알림에서 Hisingen을 허용하세요. |
| No default Reminders list is available. | 기본 미리 알림 목록이 없습니다. |
| The reminder could not be saved. | 미리 알림을 저장할 수 없습니다. |
| Also Add to Reminders | 미리 알림에도 추가 |
| Write a Reminder through macOS Reminders each time the plug-in alert fires | 충전 알림이 울릴 때마다 macOS 미리 알림에 미리 알림을 작성 |
| Add to Calendar… | 캘린더에 추가… |
| Loading writable calendars… | 쓰기 가능한 캘린더를 불러오는 중… |
| No writable calendars are available. | 쓰기 가능한 캘린더가 없습니다. |
| Destination | 목적지 |
| Added to %@. | %@에 추가되었습니다. |
| Already on %@. | 이미 %@에 있습니다. |
| The schedule has no upcoming start. | 일정에 다음 시작 시간이 없습니다. |
| The event could not be saved. | 이벤트를 저장할 수 없습니다. |
| Add to %@ | %@에 추가 |
| Created by Hisingen from a vehicle schedule. | 차량 일정에서 Hisingen이 만들었습니다. |
| Main Climate | 메인 공조 |
| Warranty Status | 보증 상태 |
| Cycle Started | 사이클 시작 |
| Last Cycle Finished | 마지막 사이클 종료 |
| Light %d | 라이트 %d |
| The provider's own word for the warranty state, shown exactly as reported. No connected provider returns one today, so the row stays hidden until one does. | 보증 상태에 대해 제공자가 쓰는 단어를 보고된 그대로 표시합니다. 현재 이를 반환하는 연결된 제공자가 없어서 그런 제공자가 생길 때까지 이 행은 표시되지 않습니다. |
| A light the backend reports by its wire ID. Hisingen has no name for it yet, so the ID is shown raw and reported unchanged in support exports. | 백엔드가 필드 ID로 보고하는 라이트입니다. Hisingen에 아직 이름이 없어 ID를 그대로 표시하고 지원 내보내기에도 변경 없이 보고합니다. |
| Air-quality field the portal sent but Hisingen has not yet decoded. Shown raw so new backend data is visible; reported unchanged in support exports. | 포털이 보냈지만 Hisingen이 아직 해석하지 못한 공기질 필드입니다. 새 백엔드 데이터가 보이도록 그대로 표시하며, 지원 내보내기에도 변경 없이 보고합니다. |
| Share Vehicle Report… | 차량 리포트 공유… |
| The vehicle report could not be created. | 차량 리포트를 만들 수 없습니다. |
| Data from %@. | 데이터 출처: %@. |
| Vehicle and notifications | 차량 및 알림 |
| %@: notifications muted | %@: 알림 무음 |
| %@: notifications on | %@: 알림 켜짐 |
| Production %@ | 발전 %@ |
| Pulse last read %@ ago | Pulse 마지막 읽음 %@ 전 |
| House Production | 가정 발전 |
| Hourly production Tibber reported for the home's production meter over the same period. A home without a production metering point reports none, and the row is left out. | 같은 기간 동안 Tibber가 가정 발전 계량기에 대해 보고한 시간별 발전량입니다. 발전 계량기가 없는 가정은 아무것도 보고하지 않으며 이 행은 생략됩니다. |
| Live House Power | 가정 실시간 전력 |
| Reading live | 실시간 읽는 중 |
| No Pulse paired | 연동된 Pulse가 없습니다 |
| Tibber streams live power from a Pulse or Watty reader paired to the home. The charging card then shows the live house load, and production while the home is producing. Hourly prices and meter readings work without one. | Tibber는 가정에 연동된 Pulse 또는 Watty 판독기에서 실시간 전력을 스트리밍합니다. 그러면 충전 카드에 가정의 실시간 사용량과, 발전 중일 때는 발전량이 표시됩니다. 시간별 요금과 계량기 읽음은 없이도 작동합니다. |
| Battery charge level | 배터리 충전 수준 |
| Electric range | 전기 주행거리 |
| Charger connection status | 충전기 연결 상태 |
| Charging system status | 충전 시스템 상태 |
| Charging type | 충전 방식 |
| Charger power status | 충전기 출력 상태 |
| Charging power | 충전 출력 |
| Estimated charging time to target | 목표까지 예상 충전 시간 |
| Wind | 풍속 |
| Gusts | 돌풍 |
| Precipitation | 강수량 |
| Precipitation forecast at %@ (%@ mm). A climate timer would warm the cabin. | %@에 강수가 예상됩니다(%@ mm). 공조 타이머가 실내를 데워 줄 것입니다. |
| Strong wind forecast at %@ (%@). A climate timer would warm the cabin. | %@에 강한 바람이 예상됩니다(%@). 공조 타이머가 실내를 데워 줄 것입니다. |
| Vehicle status | 차량 상태 |
| Battery, range, charging and the next departure, as the app last read them. | 배터리, 주행거리, 충전, 다음 출발을 앱이 마지막으로 읽은 대로 표시합니다. |
| Lock car | 차량 잠금 |
| Opens Hisingen with the lock command ready to confirm. | 확인할 잠금 명령과 함께 Hisingen을 엽니다. |
| Start climate | 공조 시작 |
| Opens Hisingen with the climate command ready to confirm. | 확인할 공조 명령과 함께 Hisingen을 엽니다. |

Flagged for this language:

- "메인 공조" for Main Climate; "주요 공조" is an alternative.
- "정비 점검 시기입니다." for Service inspection due.
- Solar production uses 발전 (발전 %@, 가정 발전), the usual Korean term for home generation.

### nb

Confidence: Same confidence as pass 1. The ratchet caught "Book service" shipping as the English words; it now reads "Bestill service for %@".

| English source | Shipped value |
| --- | --- |
| Long trip | Langtur |
| Plug in %@ | Kobl %@ til ladingen |
| Battery at %.0f%% and unplugged when Hisingen created this reminder. | Batteriet var på %.0f%% og frakoblet da Hisingen opprettet denne påminnelsen. |
| Battery below the plug-in threshold and unplugged when Hisingen created this reminder. | Batteriet var under tilkoblingsgrensen og frakoblet da Hisingen opprettet denne påminnelsen. |
| Book service for %@ | Bestill service for %@ |
| The vehicle reported a service inspection warning. | Kjøretøyet rapporterte et servicevarsel. |
| %d km | %d km |
| Service inspection due. | Dags for servicekontroll. |
| Check tyre pressures on %@ | Sjekk dekktrykket på %@ |
| Add Plug-In Reminder | Legg til påminnelse om lading |
| Add Service Reminder | Legg til påminnelse om service |
| Add Tyre Reminder | Legg til påminnelse om dekk |
| Added to Reminders. | Lagt til i Påminnelser. |
| Already in Reminders. | Finnes allerede i Påminnelser. |
| Reminders access is denied. Allow Hisingen in System Settings → Privacy & Security → Reminders. | Tilgang til Påminnelser er nektet. Gi Hisingen tilgang i Systeminnstillinger → Personvern og sikkerhet → Påminnelser. |
| No default Reminders list is available. | Ingen standardliste for Påminnelser finnes. |
| The reminder could not be saved. | Påminnelsen kunne ikke lagres. |
| Also Add to Reminders | Legg også til i Påminnelser |
| Write a Reminder through macOS Reminders each time the plug-in alert fires | Skriv en påminnelse via macOS Påminnelser hver gang ladevarslet utløses |
| Add to Calendar… | Legg til i kalender… |
| Loading writable calendars… | Laster inn kalendere du kan skrive i… |
| No writable calendars are available. | Ingen kalendere du kan skrive i, finnes. |
| Destination | Destinasjon |
| Added to %@. | Lagt til i %@. |
| Already on %@. | Finnes allerede på %@. |
| The schedule has no upcoming start. | Skjemaet har ingen kommende starttid. |
| The event could not be saved. | Hendelsen kunne ikke lagres. |
| Add to %@ | Legg til i %@ |
| Created by Hisingen from a vehicle schedule. | Opprettet av Hisingen fra et kjøretøyskjema. |
| Main Climate | Hovedklima |
| Warranty Status | Garantistatus |
| Cycle Started | Syklus startet |
| Last Cycle Finished | Siste syklus fullført |
| Light %d | Lys %d |
| The provider's own word for the warranty state, shown exactly as reported. No connected provider returns one today, so the row stays hidden until one does. | Leverandørens eget ord for garantistatus, vist akkurat som rapportert. Ingen tilkoblet leverandør sender et i dag, så raden holdes skjult til noen gjør det. |
| A light the backend reports by its wire ID. Hisingen has no name for it yet, so the ID is shown raw and reported unchanged in support exports. | Et lys som serveren rapporterer med sin felt-ID. Hisingen har ikke noe navn på det ennå, så ID-en vises rått og rapporteres uendret i støtteeksporter. |
| Air-quality field the portal sent but Hisingen has not yet decoded. Shown raw so new backend data is visible; reported unchanged in support exports. | Luftkvalitetsfelt fra portalen som Hisingen ikke har tolket ennå. Vises rått slik at nye data fra serveren synes; rapporteres uendret i støtteeksporter. |
| Share Vehicle Report… | Del kjøretøyrapport… |
| The vehicle report could not be created. | Kjøretøyrapporten kunne ikke opprettes. |
| Data from %@. | Data fra %@. |
| Vehicle and notifications | Kjøretøy og varsler |
| %@: notifications muted | %@: varsler dempet |
| %@: notifications on | %@: varsler på |
| Production %@ | Produksjon %@ |
| Pulse last read %@ ago | Pulse ble sist lest for %@ siden |
| House Production | Husets produksjon |
| Hourly production Tibber reported for the home's production meter over the same period. A home without a production metering point reports none, and the row is left out. | Timelig produksjon som Tibber rapporterer for hjemmets produksjonsmåler i samme periode. Et hjem uten produksjonsmålepunkt rapporterer ingenting, og raden utelates. |
| Live House Power | Husets effekt akkurat nå |
| Reading live | Leser live |
| No Pulse paired | Ingen Pulse er koblet til |
| Tibber streams live power from a Pulse or Watty reader paired to the home. The charging card then shows the live house load, and production while the home is producing. Hourly prices and meter readings work without one. | Tibber strømmer live-effekt fra en Pulse- eller Watty-leser som er koblet til hjemmet. Ladekortet viser da husets forbruk akkurat nå, og produksjon mens hjemmet produserer. Timepriser og måleravlesninger fungerer uten en slik. |
| Battery charge level | Batteriets ladestand |
| Electric range | Elrekkevidde |
| Charger connection status | Laderens tilkoblingsstatus |
| Charging system status | Ladesystemets status |
| Charging type | Ladetype |
| Charger power status | Laderens effektstatus |
| Charging power | Ladeeffekt |
| Estimated charging time to target | Estimert ladetid til mål |
| Wind | Vind |
| Gusts | Kast |
| Precipitation | Nedbør |
| Precipitation forecast at %@ (%@ mm). A climate timer would warm the cabin. | Nedbør ventes kl. %@ (%@ mm). En klimatimer ville varmet opp kupeen. |
| Strong wind forecast at %@ (%@). A climate timer would warm the cabin. | Sterk vind ventes kl. %@ (%@). En klimatimer ville varmet opp kupeen. |
| Vehicle status | Kjøretøystatus |
| Battery, range, charging and the next departure, as the app last read them. | Batteri, rekkevidde, lading og neste avgang, slik appen sist leste dem. |
| Lock car | Lås bilen |
| Opens Hisingen with the lock command ready to confirm. | Åpner Hisingen med låsekommandoen klar til bekreftelse. |
| Start climate | Start klimaanlegget |
| Opens Hisingen with the climate command ready to confirm. | Åpner Hisingen med klimakommandoen klar til bekreftelse. |

Flagged for this language:

- "Batteriets ladestand" for Battery charge level; "Batterinivå" is the plainer alternative.
- "Kast" for Gusts, the usual meteorological term; "vindkast" also occurs.
- "Destinasjon" for Destination, a normal Norwegian word.

### nl

Confidence: Same confidence as pass 1. The file keeps "Wind" identical to English on purpose.

| English source | Shipped value |
| --- | --- |
| Long trip | Lange rit |
| Plug in %@ | Sluit %@ aan |
| Battery at %.0f%% and unplugged when Hisingen created this reminder. | De batterij stond op %.0f%% en was losgekoppeld toen Hisingen deze herinnering aanmaakte. |
| Battery below the plug-in threshold and unplugged when Hisingen created this reminder. | De batterij stond onder de aansluitdrempel en was losgekoppeld toen Hisingen deze herinnering aanmaakte. |
| Book service for %@ | Boek service voor %@ |
| The vehicle reported a service inspection warning. | Het voertuig heeft een servicewaarschuwing gemeld. |
| %d km | %d km |
| Service inspection due. | Tijd voor de onderhoudsbeurt. |
| Check tyre pressures on %@ | Controleer de bandenspanning van %@ |
| Add Plug-In Reminder | Laadherinnering toevoegen |
| Add Service Reminder | Serviceherinnering toevoegen |
| Add Tyre Reminder | Bandenherinnering toevoegen |
| Added to Reminders. | Toegevoegd aan Herinneringen. |
| Already in Reminders. | Staat al in Herinneringen. |
| Reminders access is denied. Allow Hisingen in System Settings → Privacy & Security → Reminders. | Toegang tot Herinneringen is geweigerd. Sta Hisingen toe via Systeeminstellingen → Privacy en beveiliging → Herinneringen. |
| No default Reminders list is available. | Er is geen standaardlijst voor Herinneringen beschikbaar. |
| The reminder could not be saved. | De herinnering kon niet worden bewaard. |
| Also Add to Reminders | Ook toevoegen aan Herinneringen |
| Write a Reminder through macOS Reminders each time the plug-in alert fires | Schrijf elke keer dat de laadwaarschuwing afgaat een herinnering via macOS Herinneringen |
| Add to Calendar… | Voeg toe aan agenda… |
| Loading writable calendars… | Beschrijfbare agenda's worden geladen… |
| No writable calendars are available. | Er zijn geen beschrijfbare agenda's beschikbaar. |
| Destination | Bestemming |
| Added to %@. | Toegevoegd aan %@. |
| Already on %@. | Staat al op %@. |
| The schedule has no upcoming start. | Het schema heeft geen aankomende start. |
| The event could not be saved. | De gebeurtenis kon niet worden bewaard. |
| Add to %@ | Voeg toe aan %@ |
| Created by Hisingen from a vehicle schedule. | Door Hisingen gemaakt vanuit een voertuigschema. |
| Main Climate | Hoofdklimaat |
| Warranty Status | Garantiestatus |
| Cycle Started | Cyclus gestart |
| Last Cycle Finished | Laatste cyclus voltooid |
| Light %d | Licht %d |
| The provider's own word for the warranty state, shown exactly as reported. No connected provider returns one today, so the row stays hidden until one does. | Het eigen woord van de leverancier voor de garandestatus, precies zoals gerapporteerd weergegeven. Geen verbonden leverancier levert er vandaag een aan, dus de rij blijft verborgen tot een dat doet. |
| A light the backend reports by its wire ID. Hisingen has no name for it yet, so the ID is shown raw and reported unchanged in support exports. | Een licht dat het backend rapporteert op zijn veld-ID. Hisingen heeft er nog geen naam voor, dus de ID wordt rauw weergegeven en ongewijzigd gerapporteerd in support-exporten. |
| Air-quality field the portal sent but Hisingen has not yet decoded. Shown raw so new backend data is visible; reported unchanged in support exports. | Luchtkwaliteitsveld dat de portal stuurde maar dat Hisingen nog niet heeft gedecodeerd. Rauw weergegeven zodat nieuwe backendgegevens zichtbaar zijn; ongewijzigd gerapporteerd in support-exporten. |
| Share Vehicle Report… | Voertuigrapport delen… |
| The vehicle report could not be created. | Het voertuigrapport kon niet worden gemaakt. |
| Data from %@. | Gegevens van %@. |
| Vehicle and notifications | Voertuig en meldingen |
| %@: notifications muted | %@: meldingen gedempt |
| %@: notifications on | %@: meldingen aan |
| Production %@ | Productie %@ |
| Pulse last read %@ ago | Pulse voor het laatst uitgelezen %@ geleden |
| House Production | Huisproductie |
| Hourly production Tibber reported for the home's production meter over the same period. A home without a production metering point reports none, and the row is left out. | Productie per uur die Tibber rapporteert voor de productiemeter van het huis over dezelfde periode. Een huis zonder productiemeetpunt rapporteert niets, en de rij wordt weggelaten. |
| Live House Power | Huisvermogen live |
| Reading live | Leest live |
| No Pulse paired | Geen Pulse gekoppeld |
| Tibber streams live power from a Pulse or Watty reader paired to the home. The charging card then shows the live house load, and production while the home is producing. Hourly prices and meter readings work without one. | Tibber streamt live vermogen vanaf een Pulse- of Watty-lezer die aan het huis is gekoppeld. De laadkaart toont dan het live verbruik van het huis, en de productie zolang het huis produceert. Uurtarieven en meteruitlezing werken zonder lezer. |
| Battery charge level | Batterijlaadstand |
| Electric range | Elektrisch bereik |
| Charger connection status | Verbindingsstatus van de lader |
| Charging system status | Status van het laadsysteem |
| Charging type | Ladetype |
| Charger power status | Vermogensstatus van de lader |
| Charging power | Laadvermogen |
| Estimated charging time to target | Geschatte laadtijd tot het doel |
| Wind | Wind |
| Gusts | Windstoten |
| Precipitation | Neerslag |
| Precipitation forecast at %@ (%@ mm). A climate timer would warm the cabin. | Neerslag verwacht om %@ (%@ mm). Een klimatimer zou het interieur voorverwarmen. |
| Strong wind forecast at %@ (%@). A climate timer would warm the cabin. | Sterke wind verwacht om %@ (%@). Een klimatimer zou het interieur voorverwarmen. |
| Vehicle status | Voertuigstatus |
| Battery, range, charging and the next departure, as the app last read them. | Batterij, bereik, laden en het volgende vertrek, precies zoals de app ze voor het laatst uitlees. |
| Lock car | Vergrendel de auto |
| Opens Hisingen with the lock command ready to confirm. | Opent Hisingen met de vergrendelopdracht klaar om te bevestigen. |
| Start climate | Klimaat starten |
| Opens Hisingen with the climate command ready to confirm. | Opent Hisingen met de klimaatopdracht klaar om te bevestigen. |

Flagged for this language:

- "Tijd voor de onderhoudsbeurt." for Service inspection due.
- "Klimaat starten" for Start climate; Dutch car UIs often say "Airco". Confirm the house term.
- "Wind" stays identical to English, which is the Dutch word.

### nn

Confidence: Least sure again, as in pass 1. Every coined form needs a Nynorsk native.

| English source | Shipped value |
| --- | --- |
| Long trip | Langtur |
| Plug in %@ | Kobl %@ til ladinga |
| Battery at %.0f%% and unplugged when Hisingen created this reminder. | Batteriet var på %.0f%% og fråkopla då Hisingen laga denne påminninga. |
| Battery below the plug-in threshold and unplugged when Hisingen created this reminder. | Batteriet var under tilkoplingsgrensa og fråkopla då Hisingen laga denne påminninga. |
| Book service for %@ | Bestil service for %@ |
| The vehicle reported a service inspection warning. | Køyretøyet rapporterte eit servicevarsel. |
| %d km | %d km |
| Service inspection due. | Dags for servicekontroll. |
| Check tyre pressures on %@ | Sjekk dekktrykket på %@ |
| Add Plug-In Reminder | Legg til påminning om lading |
| Add Service Reminder | Legg til påminning om service |
| Add Tyre Reminder | Legg til påminning om dekk |
| Added to Reminders. | Lagd til i Påminningar. |
| Already in Reminders. | Finst allereie i Påminningar. |
| Reminders access is denied. Allow Hisingen in System Settings → Privacy & Security → Reminders. | Tilgang til Påminningar er avslått. Gje Hisingen tilgang i Systeminnstillingar → Personvern og tryggleik → Påminningar. |
| No default Reminders list is available. | Ingen standardliste for Påminningar finst. |
| The reminder could not be saved. | Påminninga kunne ikkje lagrast. |
| Also Add to Reminders | Legg òg til i Påminningar |
| Write a Reminder through macOS Reminders each time the plug-in alert fires | Skriv ei påminning via macOS Påminningar kvar gang ladevarslet går |
| Add to Calendar… | Legg til i kalendar… |
| Loading writable calendars… | Lastar inn kalendarar du kan skriva i… |
| No writable calendars are available. | Ingen kalendarar du kan skriva i, finst. |
| Destination | Reisemål |
| Added to %@. | Lagd til i %@. |
| Already on %@. | Finst allereie på %@. |
| The schedule has no upcoming start. | Skjemaet har ingen kommande starttid. |
| The event could not be saved. | Hendinga kunne ikkje lagrast. |
| Add to %@ | Legg til i %@ |
| Created by Hisingen from a vehicle schedule. | Laga av Hisingen frå eit køyretøysskjema. |
| Main Climate | Hovudklima |
| Warranty Status | Garantistatus |
| Cycle Started | Syklus starta |
| Last Cycle Finished | Siste syklus fullført |
| Light %d | Ljos %d |
| The provider's own word for the warranty state, shown exactly as reported. No connected provider returns one today, so the row stays hidden until one does. | Leverandørens eige ord for garantistatus, vist akkurat som rapportert. Ingen tilkopla leverandør sender eit i dag, så rada heldast skjult til nokon gjer det. |
| A light the backend reports by its wire ID. Hisingen has no name for it yet, so the ID is shown raw and reported unchanged in support exports. | Eit ljos som tenaren rapporterer med si felt-ID. Hisingen har ikkje noko namn på det enno, så ID-en visast rått og rapporterast uendra i støtteeksportar. |
| Air-quality field the portal sent but Hisingen has not yet decoded. Shown raw so new backend data is visible; reported unchanged in support exports. | Luftkvalitetsfelt frå portalen som Hisingen ikkje har tolka enno. Visast rått slik at nye data frå tenaren synest; rapporterast uendra i støtteeksportar. |
| Share Vehicle Report… | Del køyretøyrapport… |
| The vehicle report could not be created. | Køyretøyrapporten kunne ikkje opprettast. |
| Data from %@. | Data frå %@. |
| Vehicle and notifications | Køyretøy og varsler |
| %@: notifications muted | %@: varsler dempa |
| %@: notifications on | %@: varsler på |
| Production %@ | Produksjon %@ |
| Pulse last read %@ ago | Pulse vart sist lesen for %@ siden |
| House Production | Husets produksjon |
| Hourly production Tibber reported for the home's production meter over the same period. A home without a production metering point reports none, and the row is left out. | Timleg produksjon som Tibber rapporterer for heimen sin produksjonsmålar i same periode. Ein heim utan produksjonsmålepunkt rapporterer ingenting, og rada vert utelaten. |
| Live House Power | Husets effekt no |
| Reading live | Les live |
| No Pulse paired | Ingen Pulse er kopla til |
| Tibber streams live power from a Pulse or Watty reader paired to the home. The charging card then shows the live house load, and production while the home is producing. Hourly prices and meter readings work without one. | Tibber strøymer live-effekt frå ein Pulse- eller Watty-lesar som er kopla til heimen. Ladekortet viser då husets forbruk no, og produksjon medan heimen produserer. Timeprisar og målaravlesingar fungerer utan ein slik. |
| Battery charge level | Batteriets ladestand |
| Electric range | Elrekkevidde |
| Charger connection status | Ladarens tilkoplingsstatus |
| Charging system status | Ladesystemets status |
| Charging type | Ladetype |
| Charger power status | Ladarens effektstatus |
| Charging power | Ladeeffekt |
| Estimated charging time to target | Estimert ladetid til mål |
| Wind | Vind |
| Gusts | Kast |
| Precipitation | Nedbør |
| Precipitation forecast at %@ (%@ mm). A climate timer would warm the cabin. | Nedbør ventast kl. %@ (%@ mm). Ein klimatimer ville varma opp kupea. |
| Strong wind forecast at %@ (%@). A climate timer would warm the cabin. | Sterk vind ventast kl. %@ (%@). Ein klimatimer ville varma opp kupea. |
| Vehicle status | Køyretøystatus |
| Battery, range, charging and the next departure, as the app last read them. | Batteri, rekkevidde, lading og neste avgang, slik appen sist las dei. |
| Lock car | Lås bilen |
| Opens Hisingen with the lock command ready to confirm. | Opnar Hisingen med låsekommandoen klar til stadfesting. |
| Start climate | Start klimaanlegget |
| Opens Hisingen with the climate command ready to confirm. | Opnar Hisingen med klimakommandoen klar til stadfesting. |

Flagged for this language:

- "Reisemål" for Destination, where nb kept "Destinasjon"; confirm the Nynorsk preference.
- "Bestil service for %@" for Book service for %@ (fixed from the English words by the ratchet).
- "Ljos %d" for Light %d follows Nynorsk spelling; nb uses "Lys".

### pl

Confidence: Same confidence as pass 1.

| English source | Shipped value |
| --- | --- |
| Long trip | Długa trasa |
| Plug in %@ | Podłącz %@ do ładowania |
| Battery at %.0f%% and unplugged when Hisingen created this reminder. | Akumulator był na %.0f%% i odłączony, gdy Hisingen utworzył to przypomnienie. |
| Battery below the plug-in threshold and unplugged when Hisingen created this reminder. | Akumulator był poniżej progu podłączenia i odłączony, gdy Hisingen utworzył to przypomnienie. |
| Book service for %@ | Umów serwis dla %@ |
| The vehicle reported a service inspection warning. | Pojazd zgłosił ostrzeżenie o przeglądzie serwisowym. |
| %d km | %d km |
| Service inspection due. | Przegląd serwisowy do wykonania. |
| Check tyre pressures on %@ | Sprawdź ciśnienie opon w %@ |
| Add Plug-In Reminder | Dodaj przypomnienie o podłączeniu |
| Add Service Reminder | Dodaj przypomnienie o serwisie |
| Add Tyre Reminder | Dodaj przypomnienie o oponach |
| Added to Reminders. | Dodano do Przypomnień. |
| Already in Reminders. | Już jest w Przypomnieniach. |
| Reminders access is denied. Allow Hisingen in System Settings → Privacy & Security → Reminders. | Odmówiono dostępu do Przypomnień. Zezwól Hisingen w Ustawieniach systemowych → Prywatność i bezpieczeństwo → Przypomnienia. |
| No default Reminders list is available. | Brak domyślnej listy Przypomnień. |
| The reminder could not be saved. | Nie udało się zapisać przypomnienia. |
| Also Add to Reminders | Dodaj też do Przypomnień |
| Write a Reminder through macOS Reminders each time the plug-in alert fires | Zapisuj przypomnienie w Przypomnieniach macOS za każdym razem, gdy włączy się alert podłączenia |
| Add to Calendar… | Dodaj do kalendarza… |
| Loading writable calendars… | Wczytywanie kalendarzy z możliwością zapisu… |
| No writable calendars are available. | Brak kalendarzy z możliwością zapisu. |
| Destination | Miejsce docelowe |
| Added to %@. | Dodano do %@. |
| Already on %@. | Już jest w %@. |
| The schedule has no upcoming start. | Harmonogram nie ma nadchodzącego startu. |
| The event could not be saved. | Nie udało się zapisać wydarzenia. |
| Add to %@ | Dodaj do %@ |
| Created by Hisingen from a vehicle schedule. | Utworzone przez Hisingen z harmonogramu pojazdu. |
| Main Climate | Klimat główny |
| Warranty Status | Stan gwarancji |
| Cycle Started | Cykl rozpoczęty |
| Last Cycle Finished | Ostatni cykl zakończony |
| Light %d | Światło %d |
| The provider's own word for the warranty state, shown exactly as reported. No connected provider returns one today, so the row stays hidden until one does. | Własne słowo dostawcy opisujące stan gwarancji, pokazane dokładnie tak, jak zgłoszone. Żaden podłączony dostawca nie zwraca go dziś, więc wiersz pozostaje ukryty, dopóki ktoś nie będzie. |
| A light the backend reports by its wire ID. Hisingen has no name for it yet, so the ID is shown raw and reported unchanged in support exports. | Światło, które backend zgłasza po swoim identyfikatorze pola. Hisingen nie ma jeszcze dla niego nazwy, więc identyfikator pokazywany jest w surowej postaci i bez zmian w eksportach pomocniczych. |
| Air-quality field the portal sent but Hisingen has not yet decoded. Shown raw so new backend data is visible; reported unchanged in support exports. | Pole jakości powietrza przesłane przez portal, ale jeszcze nieodczytane przez Hisingen. Pokazywane w surowej postaci, aby widać było nowe dane backendu; bez zmian w eksportach pomocniczych. |
| Share Vehicle Report… | Udostępnij raport pojazdu… |
| The vehicle report could not be created. | Nie udało się utworzyć raportu pojazdu. |
| Data from %@. | Dane od %@. |
| Vehicle and notifications | Pojazd i powiadomienia |
| %@: notifications muted | %@: powiadomienia wyciszone |
| %@: notifications on | %@: powiadomienia włączone |
| Production %@ | Produkcja %@ |
| Pulse last read %@ ago | Pulse ostatnio odczytany %@ temu |
| House Production | Produkcja domu |
| Hourly production Tibber reported for the home's production meter over the same period. A home without a production metering point reports none, and the row is left out. | Produkcja godzinowa, którą Tibber zgłasza dla domowego licznika produkcji w tym samym okresie. Dom bez punktu pomiaru produkcji nie zgłasza niczego i wiersz jest pomijany. |
| Live House Power | Moc domu na żywo |
| Reading live | Odczyt na żywo |
| No Pulse paired | Brak sparowanego Pulse |
| Tibber streams live power from a Pulse or Watty reader paired to the home. The charging card then shows the live house load, and production while the home is producing. Hourly prices and meter readings work without one. | Tibber przesyła moc na żywo z czytnika Pulse lub Watty sparowanego z domem. Karta ładowania pokazuje wtedy bieżące zużycie domu i produkcję, gdy dom produkuje. Ceny godzinowe i odczyty licznika działają bez czytnika. |
| Battery charge level | Poziom naładowania akumulatora |
| Electric range | Zasięg elektryczny |
| Charger connection status | Stan połączenia ładowarki |
| Charging system status | Stan systemu ładowania |
| Charging type | Typ ładowania |
| Charger power status | Stan mocy ładowarki |
| Charging power | Moc ładowania |
| Estimated charging time to target | Szacowany czas ładowania do celu |
| Wind | Wiatr |
| Gusts | Porywy wiatru |
| Precipitation | Opady |
| Precipitation forecast at %@ (%@ mm). A climate timer would warm the cabin. | Oczekiwane opady o %@ (%@ mm). Timer klimatyzacji podgrzałby kabinę. |
| Strong wind forecast at %@ (%@). A climate timer would warm the cabin. | Oczekiwany silny wiatr o %@ (%@). Timer klimatyzacji podgrzałby kabinę. |
| Vehicle status | Stan pojazdu |
| Battery, range, charging and the next departure, as the app last read them. | Akumulator, zasięg, ładowanie i najbliższy wyjazd, tak jak aplikacja je ostatnio odczytała. |
| Lock car | Zablokuj samochód |
| Opens Hisingen with the lock command ready to confirm. | Otwiera Hisingen z gotowym do potwierdzenia poleceniem blokady. |
| Start climate | Uruchom klimatyzację |
| Opens Hisingen with the climate command ready to confirm. | Otwiera Hisingen z gotowym do potwierdzenia poleceniem klimatyzacji. |

Flagged for this language:

- "Przegląd serwisowy do wykonania." for Service inspection due.
- macOS path uses "Ustawieniach systemowych → Prywatność i bezpieczeństwo → Przypomnienia"; confirm against Polish macOS (Ventura naming).

### pt

Confidence: Same confidence as pass 1 (pt-PT).

| English source | Shipped value |
| --- | --- |
| Long trip | Viagem longa |
| Plug in %@ | Ligue %@ |
| Battery at %.0f%% and unplugged when Hisingen created this reminder. | A bateria estava a %.0f%% e desligada quando o Hisingen criou este lembrete. |
| Battery below the plug-in threshold and unplugged when Hisingen created this reminder. | A bateria estava abaixo do limite de ligação e desligada quando o Hisingen criou este lembrete. |
| Book service for %@ | Marque serviço para %@ |
| The vehicle reported a service inspection warning. | O veículo comunicou um aviso de inspeção de serviço. |
| %d km | %d km |
| Service inspection due. | Inspeção de serviço pendente. |
| Check tyre pressures on %@ | Verifique a pressão dos pneus de %@ |
| Add Plug-In Reminder | Adicionar lembrete de carregamento |
| Add Service Reminder | Adicionar lembrete de serviço |
| Add Tyre Reminder | Adicionar lembrete de pneus |
| Added to Reminders. | Adicionado a Lembretes. |
| Already in Reminders. | Já está em Lembretes. |
| Reminders access is denied. Allow Hisingen in System Settings → Privacy & Security → Reminders. | O acesso a Lembretes está negado. Autorize o Hisingen em Definições do Sistema → Privacidade e Segurança → Lembretes. |
| No default Reminders list is available. | Não há nenhuma lista predefinida de Lembretes. |
| The reminder could not be saved. | O lembrete não foi guardado. |
| Also Add to Reminders | Adicionar também a Lembretes |
| Write a Reminder through macOS Reminders each time the plug-in alert fires | Escrever um lembrete nos Lembretes do macOS sempre que o aviso de ligação for disparado |
| Add to Calendar… | Adicionar ao calendário… |
| Loading writable calendars… | A carregar calendários com permissão de escrita… |
| No writable calendars are available. | Não há calendários com permissão de escrita disponíveis. |
| Destination | Destino |
| Added to %@. | Adicionado a %@. |
| Already on %@. | Já está em %@. |
| The schedule has no upcoming start. | O agendamento não tem um próximo início. |
| The event could not be saved. | O evento não foi guardado. |
| Add to %@ | Adicionar a %@ |
| Created by Hisingen from a vehicle schedule. | Criado pelo Hisingen a partir de um agendamento do veículo. |
| Main Climate | Clima principal |
| Warranty Status | Estado da garantia |
| Cycle Started | Ciclo iniciado |
| Last Cycle Finished | Último ciclo concluído |
| Light %d | Luz %d |
| The provider's own word for the warranty state, shown exactly as reported. No connected provider returns one today, so the row stays hidden until one does. | A palavra do fornecedor para o estado da garantia, mostrada exatamente como comunicada. Nenhum fornecedor ligado devolve uma hoje, por isso a linha fica oculta até que um o faça. |
| A light the backend reports by its wire ID. Hisingen has no name for it yet, so the ID is shown raw and reported unchanged in support exports. | Uma luz que o backend comunica pelo seu ID de campo. O Hisingen ainda não tem nome para ela, por isso o ID é mostrado em bruto e comunicado sem alterações nas exportações de apoio. |
| Air-quality field the portal sent but Hisingen has not yet decoded. Shown raw so new backend data is visible; reported unchanged in support exports. | Campo de qualidade do ar enviado pelo portal mas ainda não descodificado pelo Hisingen. Mostrado em bruto para que os novos dados do backend fiquem visíveis; comunicado sem alterações nas exportações de apoio. |
| Share Vehicle Report… | Partilhar relatório do veículo… |
| The vehicle report could not be created. | Não foi possível criar o relatório do veículo. |
| Data from %@. | Dados de %@. |
| Vehicle and notifications | Veículo e notificações |
| %@: notifications muted | %@: notificações silenciadas |
| %@: notifications on | %@: notificações ativadas |
| Production %@ | Produção %@ |
| Pulse last read %@ ago | Pulse lido pela última vez há %@ |
| House Production | Produção da casa |
| Hourly production Tibber reported for the home's production meter over the same period. A home without a production metering point reports none, and the row is left out. | Produção horária que a Tibber comunica para o contador de produção da casa no mesmo período. Uma casa sem ponto de medição de produção não comunica nenhuma, e a linha é omitida. |
| Live House Power | Potência da casa em direto |
| Reading live | Leitura em direto |
| No Pulse paired | Nenhum Pulse associado |
| Tibber streams live power from a Pulse or Watty reader paired to the home. The charging card then shows the live house load, and production while the home is producing. Hourly prices and meter readings work without one. | A Tibber transmite potência em direto de um leitor Pulse ou Watty associado à casa. O cartão de carregamento mostra então o consumo da casa em direto e a produção enquanto a casa produz. Preços horários e leituras do contador funcionam sem leitor. |
| Battery charge level | Nível de carga da bateria |
| Electric range | Autonomia elétrica |
| Charger connection status | Estado da ligação do carregador |
| Charging system status | Estado do sistema de carregamento |
| Charging type | Tipo de carregamento |
| Charger power status | Estado da potência do carregador |
| Charging power | Potência de carregamento |
| Estimated charging time to target | Tempo de carregamento estimado até ao objetivo |
| Wind | Vento |
| Gusts | Rajadas |
| Precipitation | Precipitação |
| Precipitation forecast at %@ (%@ mm). A climate timer would warm the cabin. | Precipitação prevista às %@ (%@ mm). Um temporizador de clima aqueceria o habitáculo. |
| Strong wind forecast at %@ (%@). A climate timer would warm the cabin. | Vento forte previsto às %@ (%@). Um temporizador de clima aqueceria o habitáculo. |
| Vehicle status | Estado do veículo |
| Battery, range, charging and the next departure, as the app last read them. | Bateria, autonomia, carregamento e a próxima partida, tal como a app os leu pela última vez. |
| Lock car | Bloquear o carro |
| Opens Hisingen with the lock command ready to confirm. | Abre o Hisingen com o comando de bloqueio pronto a confirmar. |
| Start climate | Iniciar o clima |
| Opens Hisingen with the climate command ready to confirm. | Abre o Hisingen com o comando de clima pronto a confirmar. |

Flagged for this language:

- "Inspeção de serviço pendente." for Service inspection due.
- "Ligue %@" for Plug in %@ is short; "Ligue %@ ao carregador" is longer but clearer.

### zh

Confidence: Same confidence as pass 1. Full-width quotes around 提醒事项 follow the file's existing style; %@ keeps its surrounding space.

| English source | Shipped value |
| --- | --- |
| Long trip | 长途出行 |
| Plug in %@ | 连接 %@ 充电 |
| Battery at %.0f%% and unplugged when Hisingen created this reminder. | Hisingen 创建此提醒时，电量为 %.0f%% 且未连接充电。 |
| Battery below the plug-in threshold and unplugged when Hisingen created this reminder. | Hisingen 创建此提醒时，电量低于连接阈值且未连接充电。 |
| Book service for %@ | 为 %@ 预约保养 |
| The vehicle reported a service inspection warning. | 车辆报告了保养检查警告。 |
| %d km | %d km |
| Service inspection due. | 即将到保养检查时间。 |
| Check tyre pressures on %@ | 检查 %@ 的胎压 |
| Add Plug-In Reminder | 添加充电提醒 |
| Add Service Reminder | 添加保养提醒 |
| Add Tyre Reminder | 添加轮胎提醒 |
| Added to Reminders. | 已添加到“提醒事项”。 |
| Already in Reminders. | 已在“提醒事项”中。 |
| Reminders access is denied. Allow Hisingen in System Settings → Privacy & Security → Reminders. | “提醒事项”访问被拒绝。请在“系统设置”→“隐私与安全性”→“提醒事项”中允许 Hisingen。 |
| No default Reminders list is available. | 没有可用的默认提醒事项列表。 |
| The reminder could not be saved. | 无法保存提醒事项。 |
| Also Add to Reminders | 同时添加到提醒事项 |
| Write a Reminder through macOS Reminders each time the plug-in alert fires | 每次充电提醒触发时，通过 macOS 提醒事项写入一条提醒 |
| Add to Calendar… | 添加到日历… |
| Loading writable calendars… | 正在加载可写入的日历… |
| No writable calendars are available. | 没有可写入的日历。 |
| Destination | 目的地 |
| Added to %@. | 已添加到 %@。 |
| Already on %@. | 已在 %@ 上。 |
| The schedule has no upcoming start. | 该日程没有即将开始的时段。 |
| The event could not be saved. | 无法保存此日程。 |
| Add to %@ | 添加到 %@ |
| Created by Hisingen from a vehicle schedule. | 由 Hisingen 根据车辆日程创建。 |
| Main Climate | 主空调 |
| Warranty Status | 保修状态 |
| Cycle Started | 循环已开始 |
| Last Cycle Finished | 上次循环结束 |
| Light %d | 灯光 %d |
| The provider's own word for the warranty state, shown exactly as reported. No connected provider returns one today, so the row stays hidden until one does. | 服务商对保修状态的原词，按上报内容原样显示。目前没有已连接的服务商返回该字段，因此在有服务商返回之前此行保持隐藏。 |
| A light the backend reports by its wire ID. Hisingen has no name for it yet, so the ID is shown raw and reported unchanged in support exports. | 后端按其字段 ID 上报的灯光。Hisingen 尚未为其命名，因此 ID 按原始值显示，并在支持导出中保持不变。 |
| Air-quality field the portal sent but Hisingen has not yet decoded. Shown raw so new backend data is visible; reported unchanged in support exports. | 门户发送但 Hisingen 尚未解读的空气质量字段。按原始值显示以便看到后端的新数据；在支持导出中保持不变。 |
| Share Vehicle Report… | 分享车辆报告… |
| The vehicle report could not be created. | 无法创建车辆报告。 |
| Data from %@. | 数据来自 %@。 |
| Vehicle and notifications | 车辆与通知 |
| %@: notifications muted | %@：通知已静音 |
| %@: notifications on | %@：通知已开启 |
| Production %@ | 发电 %@ |
| Pulse last read %@ ago | Pulse 最近读取于 %@ 前 |
| House Production | 家庭发电 |
| Hourly production Tibber reported for the home's production meter over the same period. A home without a production metering point reports none, and the row is left out. | Tibber 在同一时段为家庭发电电表上报的小时发电量。没有发电计量点的家庭不会上报，此行将省略。 |
| Live House Power | 家庭实时功率 |
| Reading live | 实时读取中 |
| No Pulse paired | 未配对 Pulse |
| Tibber streams live power from a Pulse or Watty reader paired to the home. The charging card then shows the live house load, and production while the home is producing. Hourly prices and meter readings work without one. | Tibber 从与家庭配对的 Pulse 或 Watty 读取器实时传输电力。充电卡片随后显示家庭实时用电，以及发电期间的家庭发电量。小时电价和电表读数无需读取器即可使用。 |
| Battery charge level | 电池电量 |
| Electric range | 纯电续航 |
| Charger connection status | 充电器连接状态 |
| Charging system status | 充电系统状态 |
| Charging type | 充电类型 |
| Charger power status | 充电器功率状态 |
| Charging power | 充电功率 |
| Estimated charging time to target | 预计充至目标的时间 |
| Wind | 风速 |
| Gusts | 阵风 |
| Precipitation | 降水 |
| Precipitation forecast at %@ (%@ mm). A climate timer would warm the cabin. | %@ 预计有降水（%@ 毫米）。空调定时器可以为座舱预热。 |
| Strong wind forecast at %@ (%@). A climate timer would warm the cabin. | %@ 预计有大风（%@）。空调定时器可以为座舱预热。 |
| Vehicle status | 车辆状态 |
| Battery, range, charging and the next departure, as the app last read them. | 电量、续航、充电状态和下次出发，按应用最近读取的数值显示。 |
| Lock car | 锁车 |
| Opens Hisingen with the lock command ready to confirm. | 打开 Hisingen 并等待确认锁车指令。 |
| Start climate | 启动空调 |
| Opens Hisingen with the climate command ready to confirm. | 打开 Hisingen 并等待确认空调指令。 |

Flagged for this language:

- "主空调" for Main Climate; "主气候" is more literal.
- "即将到保养检查时间。" for Service inspection due.
- "空调定时器" for climate timer; the app already uses 定时器 vocabulary elsewhere.

### sv (owner's language): pass 2

The draft sv values were merged verbatim; nothing was rewritten. Three wording checks to make:

- "Dags för servicebesiktning." (Service inspection due.): the compound reads service + besiktning; if the car means the workshop visit rather than the state inspection, "Dags för service." may be the plainer word.
- "Destination" is identical to English, but it is a normal Swedish word (en destination); keep or replace as taste dictates.
- "Luftkvalitetsfält från portalen ... Visas råa så att ny data ...": "Visas råa" reads as plural; for a single field "Visas rått" would agree. Not changed, since the sentence can also be read generically.

The 70 merged values, for his review:

| English source | Shipped Swedish value |
| --- | --- |
| Long trip | Långresa |
| Plug in %@ | Koppla in %@ |
| Battery at %.0f%% and unplugged when Hisingen created this reminder. | Batteriet var på %.0f%% och bilen urkopplad när Hisingen skapade den här påminnelsen. |
| Battery below the plug-in threshold and unplugged when Hisingen created this reminder. | Batteriet var under inkopplingsgränsen och bilen urkopplad när Hisingen skapade den här påminnelsen. |
| Book service for %@ | Boka service för %@ |
| The vehicle reported a service inspection warning. | Fordonet rapporterade en servicevarning. |
| %d km | %d km |
| Service inspection due. | Dags för servicebesiktning. |
| Check tyre pressures on %@ | Kontrollera däcktrycket på %@ |
| Add Plug-In Reminder | Lägg till laddpåminnelse |
| Add Service Reminder | Lägg till servicepåminnelse |
| Add Tyre Reminder | Lägg till däckpåminnelse |
| Added to Reminders. | Tillagd i Påminnelser. |
| Already in Reminders. | Finns redan i Påminnelser. |
| Reminders access is denied. Allow Hisingen in System Settings → Privacy & Security → Reminders. | Åtkomst till Påminnelser är nekad. Ge Hisingen åtkomst i Systeminställningar → Integritet och säkerhet → Påminnelser. |
| No default Reminders list is available. | Ingen standardlista för Påminnelser finns. |
| The reminder could not be saved. | Påminnelsen kunde inte sparas. |
| Also Add to Reminders | Lägg även till i Påminnelser |
| Write a Reminder through macOS Reminders each time the plug-in alert fires | Skapa en påminnelse via macOS Påminnelser varje gång laddpåminnelsen utlöses |
| Add to Calendar… | Lägg till i kalender… |
| Loading writable calendars… | Läser in skrivbara kalendrar… |
| No writable calendars are available. | Inga skrivbara kalendrar finns. |
| Destination | Destination |
| Added to %@. | Tillagd i %@. |
| Already on %@. | Finns redan i %@. |
| The schedule has no upcoming start. | Schemat har ingen kommande starttid. |
| The event could not be saved. | Evenemanget kunde inte sparas. |
| Add to %@ | Lägg till i %@ |
| Created by Hisingen from a vehicle schedule. | Skapad av Hisingen från ett fordonschema. |
| Main Climate | Huvudklimat |
| Warranty Status | Garantistatus |
| Cycle Started | Cykel startad |
| Last Cycle Finished | Senaste cykel avslutad |
| Light %d | Ljus %d |
| The provider's own word for the warranty state, shown exactly as reported. No connected provider returns one today, so the row stays hidden until one does. | Leverantörens eget ord för garantins status, visas precis som det rapporterades. Ingen ansluten leverantör skickar ett sådant idag, så raden syns inte förrän någon gör det. |
| A light the backend reports by its wire ID. Hisingen has no name for it yet, so the ID is shown raw and reported unchanged in support exports. | Ett ljus som servern rapporterar med sitt fält-ID. Hisingen har inget namn för det än så länge, så ID:t visas rått och rapporteras oförändrat i supportexporter. |
| Air-quality field the portal sent but Hisingen has not yet decoded. Shown raw so new backend data is visible; reported unchanged in support exports. | Luftkvalitetsfält från portalen som Hisingen ännu inte har tolkat. Visas råa så att ny data från servern syns. Rapporteras oförändrat i supportexporter. |
| Share Vehicle Report… | Dela fordonsrapport… |
| The vehicle report could not be created. | Fordonsrapporten kunde inte skapas. |
| Data from %@. | Data från %@. |
| Vehicle and notifications | Fordon och aviseringar |
| %@: notifications muted | %@: aviseringar tystade |
| %@: notifications on | %@: aviseringar på |
| Production %@ | Produktion %@ |
| Pulse last read %@ ago | Pulse lästes senast för %@ sedan |
| House Production | Husets produktion |
| Hourly production Tibber reported for the home's production meter over the same period. A home without a production metering point reports none, and the row is left out. | Timvis produktion som Tibber rapporterar för husets produktionsmätare under samma period. Ett hus utan produktion rapporterar inget, och raden lämnas bort. |
| Live House Power | Husets effekt just nu |
| Reading live | Läser live |
| No Pulse paired | Ingen Pulse kopplad |
| Tibber streams live power from a Pulse or Watty reader paired to the home. The charging card then shows the live house load, and production while the home is producing. Hourly prices and meter readings work without one. | Tibber strömmar live-effekt från en Pulse- eller Watty-läsare som är kopplad till hemmet. Laddkortet visar då husets förbrukning just nu, och produktion medan huset producerar. Timpriser och mätaravläsningar fungerar utan en sådan. |
| Battery charge level | Batteriladdnivå |
| Electric range | Elräckvidd |
| Charger connection status | Laddaranslutning |
| Charging system status | Laddningsstatus |
| Charging type | Laddtyp |
| Charger power status | Laddarens effektstatus |
| Charging power | Laddeffekt |
| Estimated charging time to target | Uppskattad laddtid till mål |
| Wind | Vind |
| Gusts | Vindbyar |
| Precipitation | Nederbörd |
| Precipitation forecast at %@ (%@ mm). A climate timer would warm the cabin. | Nederbörd väntas kl. %@ (%@ mm). En klimattimer skulle värma kupén. |
| Strong wind forecast at %@ (%@). A climate timer would warm the cabin. | Stark vind väntas kl. %@ (%@). En klimattimer skulle värma kupén. |
| Vehicle status | Fordonsstatus |
| Battery, range, charging and the next departure, as the app last read them. | Batteri, räckvidd, laddning och nästa avresa, precis som appen senast läste dem. |
| Lock car | Lås bilen |
| Opens Hisingen with the lock command ready to confirm. | Öppnar Hisingen med låskommandot klart att bekräftas. |
| Start climate | Starta klimatet |
| Opens Hisingen with the climate command ready to confirm. | Öppnar Hisingen med klimatkommandot klart att bekräftas. |

The 51 sv home-charging strings that still ship English (listed earlier in this document) are unchanged
by this pass and still wait for the owner.

### Gates after pass 2

- check-localization.py: passes. Key parity 3901/3901 for all 14 locales; the ratchet was re-baselined
  (da 256, de 252, fr 261, nl 261, sv 273; the small rises are the same-word values named above).
- audit-l10n-literals.mjs: passes. Two focus-filter literals that appeared after the first pass
  ("All notifications", "Muted") had no draft entry and were baselined like the first pass's 68.
- verify-l10n-usage.mjs: fails on 12 unkeyed literals, every one a feature agent's missed draft entry:
  %@ (raw), All notifications, Muted, Hisingen cannot refresh until the account is reconnected...,
  Oldest reading %@, Sign in again to keep this up to date, Sign in again: Hisingen cannot refresh,
  Some readings are from an earlier report, Telemetry is flowing now..., The vehicle reported these
  values at the time shown..., Volvo connected but not saved, Volvo no longer accepts this application's
  client ID... . They need keys with Swedish before any locale can carry them.
