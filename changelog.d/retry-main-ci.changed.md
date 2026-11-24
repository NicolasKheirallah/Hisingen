- **A failed main CI run is re-run once, and the release steps are written down.** A flaky job on
  a main push used to hold Auto Release until someone re-ran it by hand, usually after main had
  moved on. Retry Main CI now re-runs the failed jobs once and records the first failure in the
  run summary. The release documentation describes the order that avoids a stale release pull
  request and how to turn on the merge queue.
