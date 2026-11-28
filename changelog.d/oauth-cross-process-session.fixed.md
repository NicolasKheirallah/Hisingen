- **CLI runs and app refreshes share OAuth sessions cleanly.** Valid access tokens and refresh
  generations are persisted alongside fresh Keychain reads and an advisory file lock so
  `Hisingen cli` reuses the active grant instead of rotating single-use refresh tokens out from
  under the running menu bar app.
