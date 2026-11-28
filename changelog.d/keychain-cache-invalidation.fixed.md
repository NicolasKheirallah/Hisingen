- **Clearing the in-memory Keychain cache no longer hides saved credentials.** Invalidating the
  cache previously overwrote known keys with negative `nil` entries and missed newer integration
  items such as Home Assistant, Electricity Maps and direct charger credentials. It now drops all
  cached entries so the next read queries the backing store cleanly.
