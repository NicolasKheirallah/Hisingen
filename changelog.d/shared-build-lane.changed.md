- **The shared build lane clears itself.** `Scripts/build-lane.sh run` claims the lane
  for one command. It records the running processes and uses a lock so two callers
  cannot claim the lane at once while recovering from a crash.
