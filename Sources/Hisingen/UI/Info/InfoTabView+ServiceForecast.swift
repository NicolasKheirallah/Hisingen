import Foundation

extension InfoTabView {
    /// Present only when the car reports a distance to service and the local store holds at
    /// least a week of odometer samples from the last 30 days.
    var serviceForecast: ServiceForecast? {
        ServiceForecast.estimate(
            distanceToServiceKm: state.maintenance.service.distanceToServiceKm,
            daysToService: state.maintenance.service.daysToService,
            odometerSamples: asyncData.serviceOdometerPoints
        )
    }

    /// Day and month only. A service date is a planning hint, not a timestamp.
    func serviceForecastDayText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = L10n.displayLocale
        formatter.setLocalizedDateFormatFromTemplate("d MMM")
        return formatter.string(from: date)
    }
}
