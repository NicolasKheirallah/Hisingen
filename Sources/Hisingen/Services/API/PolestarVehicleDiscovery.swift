import Foundation

struct PolestarVehicleDiscovery: Sendable {
    let client: PolestarGraphQLClient

    func primary(token: String, isolation: isolated (any Actor)? = #isolation) async throws -> [ConsumerCarDTO] {
        let query = """
        query GetConsumerCarsV2 {
          getConsumerCarsV2 { vin internalVehicleIdentifier modelName modelYear registrationNo pno34 structureWeek }
        }
        """
        let response: GraphQLResponse<ConsumerCarsPayloadDTO> = try await client.query(
            query, variables: NoVariables?.none, token: token, operation: "vehicle discovery")
        return response.data?.getConsumerCarsV2 ?? []
    }

    static func merge(
        primary: [ConsumerCarDTO],
        vdms: [ConsumerCarDTO]
    ) -> [ConsumerCarDTO] {
        guard !vdms.isEmpty else { return primary }
        let merged = vdms.map { vdmsCar in
            guard let matching = primary.first(where: { $0.vin == vdmsCar.vin }) else {
                return vdmsCar
            }
            return ConsumerCarDTO(
                vin: vdmsCar.vin,
                internalVehicleIdentifier: vdmsCar.internalVehicleIdentifier ?? matching.internalVehicleIdentifier,
                modelName: vdmsCar.modelName ?? matching.modelName,
                modelYear: vdmsCar.modelYear ?? matching.modelYear,
                registrationNo: vdmsCar.registrationNo ?? matching.registrationNo,
                pno34: matching.pno34,
                structureWeek: matching.structureWeek
            )
        }
        // VDMS only enriches the primary discovery, so a partial VDMS list must not evict
        // vehicles the primary source still reports.
        return merged + primary.filter { car in !vdms.contains(where: { $0.vin == car.vin }) }
    }

}
