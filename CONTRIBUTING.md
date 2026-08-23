# Contributing to Hisingen

Thank you for wanting to help! Bug reports, pull requests and — especially — real-world vehicle testing are all welcome.

## Ways to contribute

* **Test with your vehicle.** Different cars, model years, regions and software versions don't always behave the same way. Testing on vehicles that aren't already well covered is one of the most useful contributions there is. Use the [vehicle compatibility template](https://github.com/NicolasKheirallah/Hisingen/issues/new?template=vehicle_compatibility.md).
* **Report bugs** with the [bug report template](https://github.com/NicolasKheirallah/Hisingen/issues/new?template=bug_report.md).
* **Propose features** with the [feature request template](https://github.com/NicolasKheirallah/Hisingen/issues/new?template=feature_request.md).
* **Improve code or documentation** through pull requests.

Security vulnerabilities must be reported privately via [SECURITY.md](SECURITY.md) — never as a public issue.

## Development setup

Requirements: macOS 14+, Xcode 16 (or a compatible toolchain), Git.

```bash
git clone https://github.com/NicolasKheirallah/Hisingen.git
cd Hisingen
make doctor   # check your environment
make test     # run the test suite
make ci       # run the same validation CI performs
make app      # build Hisingen.app
```

Normal CI and the deterministic test suite never need access to a real Polestar or Volvo account. Without `.env.secrets`, build-time credential injection emits empty placeholders and the project compiles cleanly; live integration testing is kept separate and opt-in.

See [docs/development/getting-started.md](docs/development/getting-started.md) for full details.

## Pull-request checklist

Before submitting a change:

1. Read the [development guide](docs/development/getting-started.md).
2. Run `make ci` and make sure it passes.
3. Add or update tests where practical.
4. Keep vehicle behaviour tied to what the individual car supports (capability-aware, no model-wide guesses).
5. Don't commit real credentials, access tokens, secrets or full VINs.
6. Keep detailed implementation documentation under `/docs` rather than growing the root README indefinitely.
7. Run `Scripts/check-docs-links.py` if you changed documentation links, and `Scripts/check-localization.py` if you touched user-facing strings.

## Code style notes

* Follow the conventions of surrounding code; when adding UI, mirror existing SwiftUI patterns.
* Never render missing vehicle data as a positive state (e.g. "locked" or "closed") — keep it explicitly unknown/unavailable.
* Remote commands must go through the same capability and authentication gates as in-app controls.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
