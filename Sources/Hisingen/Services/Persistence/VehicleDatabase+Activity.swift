import Foundation
import OSLog

extension VehicleDatabase {
    func recordActivities(_ events: [VehicleActivity]) {
        guard !events.isEmpty else { return }
        do {
            try db.withTransaction {
                for event in events {
                    let payload = try JSONEncoder().encode(event)
                    try db.query(sql: "INSERT OR IGNORE INTO vehicle_activity(id, vin, timestamp, payload) VALUES (?, ?, ?, ?);") { statement in
                        try statement.bindText(event.id, at: 1)
                        try statement.bindText(event.vin, at: 2)
                        try statement.bindDate(event.timestamp, at: 3)
                        try statement.bindBlob(payload, at: 4)
                        try statement.executeUpdate()
                    } process: { _ in }
                }
            }
        } catch {
            AppLog.logger("database").error("Could not save vehicle activity: \(error, privacy: .public)")
        }
    }
}
