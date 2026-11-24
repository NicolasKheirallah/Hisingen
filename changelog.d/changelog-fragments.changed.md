- **Changelog entries are one small file per change.** Every change used to edit the same
  section of `CHANGELOG.md`, so any two open pull requests conflicted. A change now adds a file
  under `changelog.d/`, and release preparation moves the fragments into the new version's
  section and removes them. No change to the app.
