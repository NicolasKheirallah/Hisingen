# Changelog fragments

Every change that a user or a developer would notice adds one file here instead of editing
`CHANGELOG.md`, so two open pull requests never fight over the same lines. Release preparation
moves the fragments into the new version's section and removes them.

Name the file `<slug>.<type>.md`, where the slug is lowercase words joined by hyphens and the
type is `added`, `changed`, `fixed`, `removed` or `security`:

```text
changelog.d/stream-replacement-waits.fixed.md
```

The file holds one bullet in the style of `CHANGELOG.md`: a bold sentence that ends with a full
stop, then the explanation. Indent continuation lines by two spaces. One entry is one
paragraph, with no headings and no blank lines.

```markdown
- **A stopped live stream could still be open when its replacement connected.** Stopping the
  stream only cancels its task, so ...
```

`python3 Scripts/changelog.py check` validates the folder and runs in the portable checks.
Entries for a release that is already prepared still go straight into its section of
`CHANGELOG.md`.
