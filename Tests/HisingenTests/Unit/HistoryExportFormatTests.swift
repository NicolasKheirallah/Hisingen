import Foundation
import Testing
@testable import Hisingen

private let exportDay: Date = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Europe/Stockholm") ?? .current
    return calendar.date(from: DateComponents(year: 2026, month: 2, day: 10, hour: 8))!
}()

private func trip(id: String = "t1", startLatitude: Double? = 57.7089, startLongitude: Double? = 11.9746,
                  endLatitude: Double? = 57.7000, endLongitude: Double? = 11.9800,
                  distanceKm: Double = 42.25) -> TripHistoryEntry {
    TripHistoryEntry(
        id: id, vin: "VIN123", startedAt: exportDay,
        endedAt: exportDay.addingTimeInterval(95.5 * 60), distanceKm: distanceKm,
        averageConsumption: nil, ambientTemperatureCelsius: 12.5,
        startLatitude: startLatitude, startLongitude: startLongitude,
        endLatitude: endLatitude, endLongitude: endLongitude
    )
}

private func csvCell(_ value: String) -> String {
    let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
    return "\"" + escaped + "\""
}

struct GPXExportTests {
    @Test
    func aTripWithCoordinatesBecomesATrack() throws {
        let document = try XMLDocument(data: GPXExport.data(trips: [trip()], vehicleName: "VIN123"))
        let tracks = try document.nodes(forXPath: "//*[local-name()='trk']")
        #expect(tracks.count == 1)
        let points = try document.nodes(forXPath: "//*[local-name()='trkpt']")
        #expect(points.count == 2)

        let first = try #require(points.first as? XMLElement)
        let latitude = try #require(first.attribute(forName: "lat")?.stringValue)
        let longitude = try #require(first.attribute(forName: "lon")?.stringValue)
        #expect(abs((Double(latitude) ?? 0) - 57.7089) < 0.00001)
        #expect(abs((Double(longitude) ?? 0) - 11.9746) < 0.00001)
        let time = try #require(try first.nodes(forXPath: "./*[local-name()='time']").first?.stringValue)
        #expect(time == Format.iso8601.string(from: exportDay))
    }

    @Test
    func aTracklessTripLeavesNoTrackAndNoZeroCoordinate() throws {
        let document = try XMLDocument(data: GPXExport.data(
            trips: [trip(), trip(id: "t2", startLatitude: nil, startLongitude: nil,
                                 endLatitude: nil, endLongitude: nil)],
            vehicleName: "VIN123"
        ))
        let tracks = try document.nodes(forXPath: "//*[local-name()='trk']")
        let points = try document.nodes(forXPath: "//*[local-name()='trkpt']")
        #expect(tracks.count == 1)
        #expect(points.count == 2)
        let text = String(decoding: GPXExport.data(trips: [trip(id: "t2", startLatitude: nil,
                                                               startLongitude: nil,
                                                               endLatitude: nil, endLongitude: nil)],
                                                   vehicleName: "VIN123"), as: UTF8.self)
        #expect(!text.contains("<trk"))
        #expect(!text.contains("lat=\"0"))
    }

    @Test
    func aTripWithOnlyTheEndPositionKeepsThePointItHas() throws {
        let document = try XMLDocument(data: GPXExport.data(
            trips: [trip(startLatitude: nil, startLongitude: nil)],
            vehicleName: "VIN123"
        ))
        let points = try document.nodes(forXPath: "//*[local-name()='trkpt']")
        #expect(points.count == 1)
        let point = try #require(points.first as? XMLElement)
        #expect(point.attribute(forName: "lat")?.stringValue == "57.7000000")
    }

    @Test
    func coordinatesOutsideTheValidRangeAreSkippedRatherThanWritten() throws {
        let invalid = trip(startLatitude: 999, startLongitude: 11.9, endLatitude: .nan, endLongitude: 11.9)
        let document = try XMLDocument(data: GPXExport.data(trips: [invalid], vehicleName: "VIN123"))
        let points = try document.nodes(forXPath: "//*[local-name()='trkpt']")
        #expect(points.isEmpty)
        let tracks = try document.nodes(forXPath: "//*[local-name()='trk']")
        #expect(tracks.isEmpty)
    }
}

struct XLSXWorkbookTests {
    @Test
    func theWorkbookIsAValidZipWithDataAndSummaryParts() throws {
        let data = try #require(HistoryWorkbook.workbook(
            csv: HistoryExport.tripsCSV([trip(), trip(id: "t2", startLatitude: nil, startLongitude: nil,
                                                      endLatitude: nil, endLongitude: nil, distanceKm: 10)]),
            title: "Trips", vehicle: "VIN123", scope: "Full history", generatedAt: exportDay
        )?.data())
        let entries = try TestZIP.entries(data)
        #expect(entries["[Content_Types].xml"] != nil)
        #expect(entries["_rels/.rels"] != nil)
        #expect(entries["xl/workbook.xml"] != nil)
        #expect(entries["xl/styles.xml"] != nil)
        #expect(entries["xl/worksheets/sheet1.xml"] != nil)
        #expect(entries["xl/worksheets/sheet2.xml"] != nil)

        let workbook = try XMLDocument(data: try #require(entries["xl/workbook.xml"]))
        let names = try workbook.nodes(forXPath: "//*[local-name()='sheet']")
            .compactMap { ($0 as? XMLElement)?.attribute(forName: "name")?.stringValue }
        #expect(names == ["Trips", L10n.text("Summary")])
    }

    @Test
    func theDataSheetCarriesTheCsvValuesWithNumbersAsNumbers() throws {
        let csv = HistoryExport.tripsCSV([
            TripHistoryEntry(
                id: "t1", vin: "VIN123", startedAt: exportDay,
                endedAt: exportDay.addingTimeInterval(95.5 * 60), distanceKm: 42.25,
                averageConsumption: nil, ambientTemperatureCelsius: 12.5,
                startLatitude: 57.7089, startLongitude: 11.9746,
                endLatitude: 57.7, endLongitude: 11.98
            )
        ])
        let data = try #require(HistoryWorkbook.workbook(
            csv: csv, title: "Trips", vehicle: "VIN123", scope: "Full history", generatedAt: exportDay
        )?.data())
        let entries = try TestZIP.entries(data)
        let cells = try sheetCells(try #require(entries["xl/worksheets/sheet1.xml"]))

        let columns = CSV.tripHistoryHeader.components(separatedBy: ",")
        let durationCell = try #require(cells["\(columnLetter(columns.firstIndex(of: "Duration (min)")!))2"])
        #expect(durationCell.number == 95.5)
        let distanceCell = try #require(cells["\(columnLetter(columns.firstIndex(of: "Distance (km)")!))2"])
        #expect(distanceCell.number == 42.25)
        let vinCell = try #require(cells["B2"])
        #expect(vinCell.text == "VIN123")
        let startedCell = try #require(cells["C2"])
        #expect(startedCell.text == Format.iso8601.string(from: exportDay))
        let consumptionCell = try #require(cells["G2"])
        #expect(consumptionCell.text == nil)
        #expect(consumptionCell.number == nil)

        let latitudeCell = try #require(cells["I2"])
        #expect(latitudeCell.number == 57.7089)
    }

    @Test
    func quotedCommasAndQuotesRoundTripThroughTheWorkbook() throws {
        let header = "Trip ID,VIN,Note"
        let csv = header + "\n" + csvCell("t1") + ",VIN123," + csvCell("Home, Garage") + "\n"
            + csvCell("t2") + ",VIN123," + csvCell("He said \"hi\"") + "\n"
        let table = try #require(HistoryWorkbook.table(csv: csv, title: "Trips"))
        #expect(table.rows[0][2] == "Home, Garage")
        #expect(table.rows[1][2] == "He said \"hi\"")

        // The parser must also accept the unquoted CSV the ledger exporters produce.
        let plain = HistoryWorkbook.parseCSV("a,b\n1,2\n")
        #expect(plain == [["a", "b"], ["1", "2"]])
    }

    @Test
    func theSummarySheetTotalsOnlyColumnsEveryRowCarries() throws {
        let csv = HistoryExport.tripsCSV([
            trip(id: "t1", distanceKm: 42.25),
            trip(id: "t2", startLatitude: nil, startLongitude: nil,
                 endLatitude: nil, endLongitude: nil, distanceKm: 10)
        ])
        let data = try #require(HistoryWorkbook.workbook(
            csv: csv, title: "Trips", vehicle: "VIN123", scope: "Full history", generatedAt: exportDay
        )?.data())
        let entries = try TestZIP.entries(data)
        let rows = try sheetRows(try #require(entries["xl/worksheets/sheet2.xml"]))

        let rowCount = try #require(rows.first { $0[0].text == L10n.text("Rows") })
        #expect(rowCount[1].number == 2)

        let distance = try #require(rows.first { $0[0].text == "Distance (km)" })
        #expect(distance[1].number == 52.25)

        let duration = try #require(rows.first { $0[0].text == "Duration (min)" })
        #expect(duration[1].number == 191.0)

        let coordinates = try #require(rows.first { $0[0].text == L10n.text("Rows with coordinates") })
        #expect(coordinates[1].number == 1)
    }

    @Test
    func aNumericHeaderWithANonNumberStaysText() {
        #expect(HistoryWorkbook.typedCell("not a number", header: "Distance (km)") == .text("not a number"))
        #expect(HistoryWorkbook.typedCell("2,07", header: "Distance (km)") == .number(2.07))
        #expect(HistoryWorkbook.typedCell("", header: "Distance (km)") == .blank)
        #expect(HistoryWorkbook.typedCell("0042", header: "VIN") == .text("0042"))
    }

    @Test
    func aLongOrInvalidSheetNameIsMadeAcceptable() throws {
        let workbook = XLSXWorkbook(sheets: [
            XLSXWorkbook.Sheet(name: String(repeating: "a", count: 40) + ":bad/name", rows: [[.text("x")]]),
            XLSXWorkbook.Sheet(name: "Summary", rows: [[.text("y")]])
        ])
        guard let entries = try? TestZIP.entries(workbook.data()),
              let workbookPart = entries["xl/workbook.xml"],
              let workbookXML = try? XMLDocument(data: workbookPart) else {
            Issue.record("the workbook did not contain a readable workbook part")
            return
        }
        let names = try workbookXML.nodes(forXPath: "//*[local-name()='sheet']")
            .compactMap { ($0 as? XMLElement)?.attribute(forName: "name")?.stringValue }
        #expect(names.count == 2)
        #expect(names.allSatisfy { $0.count <= 31 })
        #expect(names[1] == "Summary")
    }
}

struct ExportFileWriterTests {
    @Test
    func bothFormatsWriteAndReadBackInsideATemporaryDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HisingenExportTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let gpx = GPXExport.data(trips: [trip()], vehicleName: "VIN123", generatedAt: exportDay)
        let book = try #require(HistoryWorkbook.workbook(
            csv: HistoryExport.tripsCSV([trip()]), title: "Trips", vehicle: "VIN123",
            scope: "Full history", generatedAt: exportDay
        )?.data())

        let gpxURL = directory.appendingPathComponent("Trips.gpx")
        let xlsxURL = directory.appendingPathComponent("Trips.xlsx")
        try ExportFileWriter.write(gpx, to: gpxURL)
        try ExportFileWriter.write(book, to: xlsxURL)

        let gpxReadBack = try Data(contentsOf: gpxURL)
        #expect(gpxReadBack == gpx)
        let xlsxReadBack = try Data(contentsOf: xlsxURL)
        #expect(xlsxReadBack == book)
        #expect(FileManager.default.fileExists(atPath: xlsxURL.path))
        // The writer wrote only the two files it was given, both under the temporary directory.
        let contents = try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
        #expect(contents == ["Trips.gpx", "Trips.xlsx"])
    }
}

private struct SheetCell {
    var text: String?
    var number: Double?
}

private func sheetRows(_ data: Data) throws -> [[SheetCell]] {
    let document = try XMLDocument(data: data)
    var rows: [[SheetCell]] = []
    for row in try document.nodes(forXPath: "//*[local-name()='row']") {
        guard let element = row as? XMLElement else { continue }
        var cells: [SheetCell] = []
        for node in try element.nodes(forXPath: "./*[local-name()='c']") {
            guard let cell = node as? XMLElement else { continue }
            let text = try cell.nodes(forXPath: ".//*[local-name()='t']").first?.stringValue
            let number = try cell.nodes(forXPath: "./*[local-name()='v']").first?.stringValue.flatMap(Double.init)
            cells.append(SheetCell(text: text, number: number))
        }
        rows.append(cells)
    }
    return rows
}

private func sheetCells(_ data: Data) throws -> [String: SheetCell] {
    let document = try XMLDocument(data: data)
    var cells: [String: SheetCell] = [:]
    for node in try document.nodes(forXPath: "//*[local-name()='c']") {
        guard let element = node as? XMLElement,
              let reference = element.attribute(forName: "r")?.stringValue else { continue }
        let text = try element.nodes(forXPath: ".//*[local-name()='t']").first?.stringValue
        let number = try element.nodes(forXPath: "./*[local-name()='v']").first?.stringValue.flatMap(Double.init)
        cells[reference] = SheetCell(text: text, number: number)
    }
    return cells
}

private func columnLetter(_ index: Int) -> String {
    var value = index
    var name = ""
    repeat {
        name = String(Character(UnicodeScalar(UInt8(65 + value % 26)))) + name
        value = value / 26 - 1
    } while value >= 0
    return name
}

/// Minimal reader for the stored ZIP entries the workbook writer produces. It walks the central
/// directory, so a wrong CRC, size or offset in the writer surfaces as a mismatch here too.
private enum TestZIP {
    static func entries(_ data: Data) throws -> [String: Data] {
        let bytes = [UInt8](data)
        guard let eocd = lastIndex(of: [0x50, 0x4B, 0x05, 0x06], in: bytes) else {
            throw ZIPError.missingEndOfCentralDirectory
        }
        let count = Int(readUInt16(bytes, eocd + 10))
        let centralStart = Int(readUInt32(bytes, eocd + 16))
        var index = centralStart
        var result: [String: Data] = [:]
        for _ in 0..<count {
            guard readUInt32(bytes, index) == 0x0201_4B50 else { throw ZIPError.badCentralHeader }
            let crc = readUInt32(bytes, index + 16)
            let size = Int(readUInt32(bytes, index + 20))
            let nameLength = Int(readUInt16(bytes, index + 28))
            let extraLength = Int(readUInt16(bytes, index + 30))
            let commentLength = Int(readUInt16(bytes, index + 32))
            let localOffset = Int(readUInt32(bytes, index + 42))
            let name = String(decoding: bytes[(index + 46)..<(index + 46 + nameLength)], as: UTF8.self)
            guard readUInt32(bytes, localOffset) == 0x0403_4B50 else { throw ZIPError.badLocalHeader }
            let localNameLength = Int(readUInt16(bytes, localOffset + 26))
            let localExtraLength = Int(readUInt16(bytes, localOffset + 28))
            let dataStart = localOffset + 30 + localNameLength + localExtraLength
            guard dataStart + size <= bytes.count else { throw ZIPError.truncatedEntry }
            let payload = Data(bytes[dataStart..<(dataStart + size)])
            guard CRC32.checksum(payload) == crc else { throw ZIPError.crcMismatch(name) }
            result[name] = payload
            index += 46 + nameLength + extraLength + commentLength
        }
        return result
    }

    enum ZIPError: Error, Equatable {
        case missingEndOfCentralDirectory
        case badCentralHeader
        case badLocalHeader
        case truncatedEntry
        case crcMismatch(String)
    }

    private static func lastIndex(of pattern: [UInt8], in bytes: [UInt8]) -> Int? {
        guard bytes.count >= pattern.count else { return nil }
        for index in stride(from: bytes.count - pattern.count, through: 0, by: -1)
        where Array(bytes[index..<(index + pattern.count)]) == pattern {
            return index
        }
        return nil
    }

    private static func readUInt16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private static func readUInt32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset]) | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16) | (UInt32(bytes[offset + 3]) << 24)
    }
}
