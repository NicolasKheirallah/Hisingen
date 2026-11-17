# About Hisingen

## Project history

Hisingen started from a pretty simple frustration: I was sitting at my Mac and wanted to check or control something on the car without having to reach for my phone.

The name **Hisingen** comes from Gothenburg, where both Volvo and Polestar have strong roots, and reflects where the project itself comes from as well.

## Credits

Hisingen is maintained by [Nicolas Kheirallah](https://github.com/NicolasKheirallah).

Thanks as well to everyone testing the app on different cars and configurations. Real-world feedback is one of the most useful ways to improve Hisingen, especially when vehicle behaviour differs between models in ways that aren't obvious from documentation alone.

### Functionality adapted from other projects

* **[Polaris](https://github.com/simonbusborg/polaris)** by Simon Busborg. Early Polestar code
  came from Polaris through an AI coding assistant, and the small protobuf helper set is still
  identical to it. Thank you to Simon for raising it in
  [#33](https://github.com/NicolasKheirallah/Hisingen/issues/33).
* **[pypolestar](https://github.com/pypolestar/pypolestar)** and
  **[polestar_api](https://github.com/pypolestar/polestar_api/)** by Tuen Lee and
  contributors. Their reverse engineering of the Polestar backend made much of this possible.
* **[unofficial-polestar-api](https://github.com/kildahldev/unofficial-polestar-api)** is an
  independent Polestar client. Hisingen cross-checked gRPC field meanings against it and uses the
  same app-version values.
* **[Sparkle](https://github.com/sparkle-project/Sparkle)** handles signed in-app updates.
* **[Open-Meteo](https://open-meteo.com/)** supplies the weather data (CC BY 4.0) and
  **[Elpriset just nu.se](https://www.elprisetjustnu.se/)** the Swedish spot prices.

Copyright notices and license texts are in [THIRD_PARTY_NOTICES.md](../THIRD_PARTY_NOTICES.md),
which also ships inside the app bundle.

## Roadmap & non-goals

Development direction is driven by real-world testing feedback; see [open issues](https://github.com/NicolasKheirallah/Hisingen/issues) and propose features with the [feature request template](https://github.com/NicolasKheirallah/Hisingen/issues/new?template=feature_request.md).

Things Hisingen deliberately will not do:

* run any Hisingen cloud service, account or middleman server
* include analytics or advertising SDKs
* provide live tracking; location is the latest reported position only
* ship iOS or Android companions; this is a macOS menu bar app
* present controls a vehicle cannot actually perform
