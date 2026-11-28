- **Home Assistant works behind a reverse-proxy path.** REST and WebSocket requests retain
  the configured path, and sparse history does not mix readings between sensors. Remote
  addresses default to HTTPS, and Settings warns when an explicit HTTP connection is used.
