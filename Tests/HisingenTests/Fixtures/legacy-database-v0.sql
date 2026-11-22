-- The schema of a Hisingen install that predates `PRAGMA user_version`, i.e. the store
-- `VehicleDatabase.runMigrations(from: 0)` promises to upgrade. It is the current baseline
-- DDL with every object a migration adds stripped back out, so opening it runs the same
-- path a real old install takes on launch.
--
-- This file is a frozen historical artifact. Do not add columns or tables from new
-- migrations to it: migrations run forward from version 0, and
-- `VehicleDatabaseSchemaParityTests` compares the result with a fresh install. Adding a
-- column only to the baseline (forgetting its migration) must keep failing that test,
-- which is why the old schema stays old.

CREATE TABLE IF NOT EXISTS vehicle_snapshots (
    vin TEXT PRIMARY KEY NOT NULL,
    brand TEXT NOT NULL,
    model_name TEXT,
    fetched_at REAL NOT NULL,
    vehicle_reported_at REAL,
    is_cached_snapshot INTEGER NOT NULL DEFAULT 1,
    payload BLOB NOT NULL
);

CREATE TABLE IF NOT EXISTS charging_baselines (
    vin TEXT PRIMARY KEY NOT NULL,
    sampled_at REAL,
    vehicle_reported_at REAL,
    payload BLOB NOT NULL
);

CREATE TABLE IF NOT EXISTS provider_backoff (
    subject TEXT PRIMARY KEY NOT NULL,
    vin TEXT,
    blocked_until REAL NOT NULL,
    reason TEXT
);
CREATE INDEX IF NOT EXISTS idx_provider_backoff_vin ON provider_backoff(vin);

CREATE TABLE IF NOT EXISTS command_receipts (
    vin TEXT PRIMARY KEY NOT NULL,
    payload BLOB NOT NULL
);

CREATE TABLE IF NOT EXISTS charging_sessions (
    id TEXT PRIMARY KEY NOT NULL,
    vin TEXT NOT NULL,
    started_at REAL NOT NULL,
    ended_at REAL,
    start_soc REAL NOT NULL,
    end_soc REAL,
    energy_delivered_kwh REAL DEFAULT 0.0,
    peak_power_kw REAL DEFAULT 0.0,
    average_power_kw REAL DEFAULT 0.0,
    location_name TEXT,
    created_at REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_charging_sessions_vin ON charging_sessions(vin, started_at DESC);

CREATE TABLE IF NOT EXISTS charging_samples (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    session_id TEXT NOT NULL,
    vin TEXT NOT NULL,
    timestamp REAL NOT NULL,
    soc REAL NOT NULL,
    power_kw REAL,
    voltage_volts REAL,
    current_amps REAL
);
CREATE INDEX IF NOT EXISTS idx_charging_samples_session ON charging_samples(session_id, timestamp ASC);

CREATE TABLE IF NOT EXISTS battery_health_history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    vin TEXT NOT NULL,
    timestamp REAL NOT NULL,
    odometer_km REAL NOT NULL,
    state_of_health_pct REAL NOT NULL,
    degradation_pct REAL NOT NULL,
    effective_usable_kwh REAL NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_battery_health_vin ON battery_health_history(vin, timestamp DESC);

CREATE TABLE IF NOT EXISTS telemetry_logs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    vin TEXT NOT NULL,
    timestamp REAL NOT NULL,
    odometer_km REAL,
    trip_manual_km REAL,
    trip_auto_km REAL,
    avg_consumption REAL,
    ambient_temp_c REAL,
    latitude REAL,
    longitude REAL
);
CREATE INDEX IF NOT EXISTS idx_telemetry_vin ON telemetry_logs(vin, timestamp DESC);

CREATE TABLE IF NOT EXISTS remote_commands_log (
    id TEXT PRIMARY KEY NOT NULL,
    vin TEXT NOT NULL,
    command_name TEXT NOT NULL,
    status TEXT NOT NULL,
    executed_at REAL NOT NULL,
    duration_ms INTEGER,
    error_message TEXT
);
CREATE INDEX IF NOT EXISTS idx_remote_commands_vin ON remote_commands_log(vin, executed_at DESC);

CREATE TABLE IF NOT EXISTS connectivity_history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    vin TEXT NOT NULL,
    timestamp REAL NOT NULL,
    network_type TEXT,
    signal_bars INTEGER,
    wake_reason TEXT
);
CREATE INDEX IF NOT EXISTS idx_connectivity_vin ON connectivity_history(vin, timestamp DESC);

CREATE TABLE IF NOT EXISTS vehicle_metric_log (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    vin TEXT NOT NULL,
    timestamp REAL NOT NULL,
    metric TEXT NOT NULL,
    value REAL,
    text TEXT,
    ref TEXT
);
CREATE INDEX IF NOT EXISTS idx_metric_log ON vehicle_metric_log(vin, metric, timestamp DESC);

CREATE TABLE IF NOT EXISTS cabin_climate_history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    vin TEXT NOT NULL,
    timestamp REAL NOT NULL,
    interior_c REAL,
    requested_c REAL
);
CREATE INDEX IF NOT EXISTS idx_cabin_climate_vin ON cabin_climate_history(vin, timestamp DESC);

CREATE TABLE IF NOT EXISTS fuel_entries (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    vin TEXT NOT NULL,
    date REAL NOT NULL,
    liters REAL NOT NULL,
    price_per_liter REAL NOT NULL,
    odometer_km REAL
);
CREATE INDEX IF NOT EXISTS idx_fuel_vin ON fuel_entries(vin, date DESC);

CREATE TABLE IF NOT EXISTS maintenance_entries (
    id TEXT PRIMARY KEY NOT NULL,
    vin TEXT NOT NULL,
    date REAL NOT NULL,
    odometer_km INTEGER,
    kind TEXT NOT NULL,
    title TEXT NOT NULL,
    notes TEXT,
    cost REAL
);
CREATE INDEX IF NOT EXISTS idx_maintenance_vin ON maintenance_entries(vin, date DESC);

CREATE TABLE IF NOT EXISTS vehicle_ownership (
    vin TEXT PRIMARY KEY NOT NULL,
    purchase_price REAL NOT NULL,
    purchase_date REAL NOT NULL,
    annual_decline_percent REAL NOT NULL
);

CREATE TABLE IF NOT EXISTS air_quality_history (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    vin TEXT NOT NULL,
    timestamp REAL NOT NULL,
    air_quality_index REAL,
    particulate_matter_25 REAL,
    particulate_matter_10 REAL,
    filter_remaining_percent REAL
);
CREATE INDEX IF NOT EXISTS idx_air_quality_vin ON air_quality_history(vin, timestamp DESC);

CREATE TABLE IF NOT EXISTS vehicle_images (
    vin TEXT NOT NULL,
    angle INTEGER NOT NULL,
    image_data BLOB NOT NULL,
    thumbnail_data BLOB,
    pixel_budget INTEGER,
    updated_at REAL NOT NULL,
    PRIMARY KEY (vin, angle)
);
CREATE INDEX IF NOT EXISTS idx_vehicle_images_vin ON vehicle_images(vin);

CREATE TABLE IF NOT EXISTS electricity_prices (
    zone TEXT NOT NULL,
    start_at REAL NOT NULL,
    end_at REAL NOT NULL,
    sek_per_kwh REAL NOT NULL,
    PRIMARY KEY (zone, start_at)
);
CREATE INDEX IF NOT EXISTS idx_electricity_prices_zone ON electricity_prices(zone, start_at ASC);

CREATE TABLE IF NOT EXISTS electricity_price_fetches (
    zone TEXT PRIMARY KEY NOT NULL,
    fetched_at REAL NOT NULL
);
