import Foundation

struct VehicleDiagnosticGroup: Identifiable {
    let service: VehicleChronosError.Service
    let code: VehicleChronosError.Code
    let action: Int?
    let records: [VehicleChronosError]
    var id: String { "\(service.rawValue)|\(code.rawValue)|\(action.map(String.init) ?? "none")" }

    static func grouped(_ errors: [VehicleChronosError], vin: String) -> [VehicleDiagnosticGroup] {
        var unique: [VehicleChronosError] = []
        for error in errors where error.vin == nil || error.vin == vin {
            if !unique.contains(error) { unique.append(error) }
        }
        let groups = Dictionary(grouping: unique) {
            "\($0.service.rawValue)|\($0.errorCode.rawValue)|\($0.actionCode.map(String.init) ?? "none")"
        }
        return groups.values.compactMap { records in
            guard let first = records.first else { return nil }
            return VehicleDiagnosticGroup(service: first.service, code: first.errorCode,
                                          action: first.actionCode, records: records)
        }.sorted { $0.id < $1.id }
    }
}
