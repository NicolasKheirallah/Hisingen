- **Retrying a Polestar session restore preserves a refresh already in progress.** A retry
  with the same credential can reuse the pending grant and its rotated token. A restore
  with a different credential cancels the earlier grant.
