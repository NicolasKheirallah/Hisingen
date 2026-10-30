# Third-party notices

Hisingen is released under the [MIT License](LICENSE). Some functionality in it way adapted from other
projects as AI was used for some parts, and it bundles one library and calls a few outside services. This file says what,
where it came from, and under which terms.

## Functionality adapted from other projects

### Polaris

[simonbusborg/polaris](https://github.com/simonbusborg/polaris) by Simon Busborg, MIT
License, Copyright (c) 2026 Simon Busborg.

Parts of Hisingen's Polestar support were adapted from Polaris:

* the protobuf codec (`enum Protobuf`), the gRPC call transport (`firstMessage`) and the
  battery request and decoding (`fetchBattery`, `parseBattery`), all in
  [PolestarGRPC.swift](Sources/Hisingen/Services/API/PolestarGRPC.swift)
* C3 host discovery (`c3Host`), in the same file
* the sign-in resume-path patterns (`extractResumePath`) and the `GetCarImages` query
  (`fetchCarImage`), both in [PolestarAPI.swift](Sources/Hisingen/Services/API/PolestarAPI.swift)

Hisingen has since reworked these: strict protobuf decoding, one shared request builder and
frame reader, table-driven battery decoding, validated discovery with expiry, stricter
resume-path checks and typed image results. They started from Polaris, so the credit stays.
The rest of the Polestar gRPC code (remote commands,
read services, availability, target charge, amp limit, live stream) is Hisingen's own and has
no counterpart in Polaris. See [issue #33](https://github.com/NicolasKheirallah/Hisingen/issues/33).

### pypolestar and polestar_api

[pypolestar/pypolestar](https://github.com/pypolestar/pypolestar) and
[pypolestar/polestar_api](https://github.com/pypolestar/polestar_api), MIT License,
Copyright (c) 2023 Tuen Lee.

The public reference for Polestar's undocumented backend. Polaris says its gRPC message shapes
and its resume-path pattern come from pypolestar, so Hisingen inherits them through the
Polaris pieces above. The static key for the public vehicle-image endpoint in
[BuiltinPolestarSecrets.swift](Sources/Hisingen/Services/API/BuiltinPolestarSecrets.swift) is
the value pypolestar publishes in its `const.py`.

### License text for Polaris, pypolestar and polestar_api

All three use the same MIT text. Only the copyright line differs, and both lines are above.

```text
MIT License

Copyright (c) 2026 Simon Busborg
Copyright (c) 2023 Tuen Lee

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Software bundled with the app

### Sparkle

[sparkle-project/Sparkle](https://github.com/sparkle-project/Sparkle) 2.9.6, MIT License
with bundled components under their own terms (bsdiff, sais-lite, Ed25519,
SUSignatureVerifier). `Sparkle.framework` performs the signed in-app updates and is the only
third-party package in `Package.resolved`.

The full license is
[Sparkle's LICENSE at 2.9.6](https://github.com/sparkle-project/Sparkle/blob/2.9.6/LICENSE).
Built apps also carry a copy as `Sparkle-LICENSE.txt` in `Contents/Resources`.

## Data services

Called at runtime. No code from them ships in Hisingen.

* **[Open-Meteo](https://open-meteo.com/)** for Vehicle Weather. Weather data by Open-Meteo.com,
  licensed [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/). The free API is for
  non-commercial use. Vehicle coordinates are sent while the feature is on; see
  [PRIVACY.md](PRIVACY.md).
* **[Elpriset just nu.se](https://www.elprisetjustnu.se/)** for Swedish spot prices in the
  charging planner. Prices are provided by Elpriset just nu.se, which asks for a credit when
  its data is shown publicly.

## Vehicle provider interfaces

* **Volvo Cars.** The APIs are published for third-party developers and used under the Volvo
  Cars developer terms of the account that registers the application.
* **Polestar.** Data Portal credentials are issued under Polestar's terms. The sign-in,
  GraphQL and gRPC interfaces are not publicly documented. Hisingen's support for them comes
  from public community research and its own testing and research. Polestar can change them without
  notice, and its terms of service may restrict their use. See the
  [README disclaimer](README.md#disclaimer).

## Trademarks

Polestar is a trademark of Polestar Performance AB. Volvo is a trademark of its owner. Apple,
macOS and SF Symbols are trademarks of Apple Inc. Hisingen is independent software, not
affiliated with or endorsed by any of them. Names are used only to describe compatibility.

## Missing a credit?

Open an issue or a pull request with the project name, link, copyright holder, license, and
what Hisingen takes from it.
