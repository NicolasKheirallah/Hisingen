# Changelog

All notable changes to Hisingen are documented in this file.

## [Unreleased]

### Added
- **Multi-Brand Volvo Support**: Integrated official Volvo Connected Vehicle API v2 & Energy API v2 via Volvo ID OAuth2 with PKCE, multi-vehicle discovery, token refresh, and independent Keychain storage.
- **Powertrain Intelligence & Flexible Units**: Added adaptive card rendering for Pure Electric (BEV), Plug-in Hybrid (PHEV), and Combustion (ICE) vehicles with configurable distance (`km`/`mi`), fuel volume (`L`/`gal`/`gal UK`), and fuel economy (`L/100km`/`mpg`/`mpg UK`/`km/L`) units.
- **Curated 9-Theme Design System**: Hisingen Glass, Polestar Minimal, Volvo Iron, Nordic Night, Aurora Borealis, Swedish Gold, Cyan Racing, Gothenburg Forest, and Sand Dune with Light, Dark, and System appearance modes.
- **Interactive SVG Outline Schematics**: Vector schematics for doors, windows, hood, tailgate, charge lid, and 4-wheel iTPMS tire status.
- **Remote Controls**: Climate start/stop, lock/unlock, tailgate release, flash lights, and honk horn for Polestar and Volvo vehicles.
- **Multilingual Localization**: Expanded localization across 16+ languages with localized string catalogs.
- **Build & Packaging**: Added universal binary packaging (`make all`) creating `Hisingen.app` and `Hisingen.dmg` with persistent self-signed developer certificate support.
