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

    func recentActivities(for vin: String, limit: Int = 100) -> [VehicleActivity] {
        (try? db.query(sql: "SELECT payload FROM vehicle_activity WHERE vin = ? ORDER BY timestamp DESC, id DESC LIMIT ?;") { statement in
            try statement.bindText(vin, at: 1)
            try statement.bindInt64(Int64(min(max(limit, 1), 1000)), at: 2)
        } process: { statement in
            var result: [VehicleActivity] = []
            while statement.step() {
                if let data = statement.columnBlob(at: 0),
                   let event = try? JSONDecoder().decode(VehicleActivity.self, from: data) { result.append(event) }
            }
            return result
        }) ?? []
    }
}
