- **Trip logs no longer double-count mixed counters or lose sleep-gap distance.** `TripSegmentation`
  now locks a single distance counter source per segment so fractional trip counters and
  whole-kilometre odometer steps cannot double-count distance, suppresses rolling multi-trip
  `averageConsumption` averages from individual trips, and reconciles positive odometer distance
  driven across `>45 min` sleep gaps when deriving persisted trip history.
