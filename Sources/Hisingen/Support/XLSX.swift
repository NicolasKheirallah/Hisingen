import Foundation

/// The spreadsheet half of an export: typed cells, a workbook of named sheets, and a writer that
/// emits the Office Open XML package Excel and its readers open. Keeping the cell type explicit is
/// what lets a number stay a number in the file instead of arriving as text a spreadsheet cannot
/// sum.
struct XLSXWorkbook: Sendable {
    struct Sheet: Sendable {
        var name: String
        var rows: [[XLSXCell]]
    }

    var sheets: [Sheet]

    func data() -> Data {
        let names = Self.uniqueSheetNames(sheets.map(\.name))
        var parts: [(name: String, data: Data)] = [
            ("[Content_Types].xml", Self.contentTypes(sheets: names)),
            ("_rels/.rels", Self.rootRelationships()),
            ("xl/workbook.xml", Self.workbook(sheets: names)),
            ("xl/_rels/workbook.xml.rels", Self.workbookRelationships(sheets: names)),
            ("xl/styles.xml", Self.styles())
        ]
        for (index, sheet) in sheets.enumerated() {
            parts.append(("xl/worksheets/sheet\(index + 1).xml", Self.sheetXML(sheet)))
        }
        return ZIPWriter.archive(parts)
    }

    private static func uniqueSheetNames(_ proposed: [String]) -> [String] {
        var used = Set<String>()
        return proposed.map { name in
            let base = sanitizedSheetName(name)
            var candidate = base
            var counter = 2
            while used.contains(candidate.lowercased()) {
                let suffix = " \(counter)"
                candidate = String(base.prefix(max(1, 31 - suffix.count))) + suffix
                counter += 1
            }
            used.insert(candidate.lowercased())
            return candidate
        }
    }

    /// Excel refuses a sheet name longer than 31 characters or one carrying `[]:*?/\`.
    private static func sanitizedSheetName(_ name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "[]:*?/\\")
        let cleaned = name.unicodeScalars
            .map { forbidden.contains($0) ? " " : String($0) }
            .joined()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let truncated = String(cleaned.prefix(31))
        return truncated.isEmpty ? "Sheet" : truncated
    }

    private static func sheetXML(_ sheet: Sheet) -> Data {
        let width = sheet.rows.map(\.count).max() ?? 0
        let height = sheet.rows.count
        var xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        <dimension ref="A1:\(columnName(max(0, width - 1)))\(max(1, height))"/>
        <sheetViews><sheetView workbookViewId="0"/></sheetViews>
        <sheetFormatPr defaultRowHeight="15"/>
        <sheetData>

        """
        for (rowIndex, row) in sheet.rows.enumerated() {
            let rowNumber = rowIndex + 1
            xml += "<row r=\"\(rowNumber)\">"
            for (columnIndex, cell) in row.enumerated() {
                let reference = "\(columnName(columnIndex))\(rowNumber)"
                switch cell {
                case .blank:
                    xml += "<c r=\"\(reference)\"/>"
                case .number(let value):
                    guard value.isFinite else {
                        xml += textCell(reference: reference, value: String(value))
                        continue
                    }
                    xml += "<c r=\"\(reference)\"><v>\(value)</v></c>"
                case .text(let value):
                    xml += textCell(reference: reference, value: value)
                }
            }
            xml += "</row>\n"
        }
        xml += "</sheetData></worksheet>\n"
        return Data(xml.utf8)
    }

    private static func textCell(reference: String, value: String) -> String {
        "<c r=\"\(reference)\" t=\"inlineStr\"><is><t xml:space=\"preserve\">\(XMLText.escape(value))</t></is></c>"
    }

    /// Spreadsheet column letters, one-based: A, B, ..., Z, AA.
    private static func columnName(_ index: Int) -> String {
        var value = index
        var name = ""
        repeat {
            name = String(Character(UnicodeScalar(UInt8(65 + value % 26)))) + name
            value = value / 26 - 1
        } while value >= 0
        return name
    }

    private static func contentTypes(sheets: [String]) -> Data {
        var overrides = """
        <Override PartName="/xl/workbook.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.sheet.main+xml"/>
        <Override PartName="/xl/styles.xml" ContentType="application/vnd.openxmlformats-officedocument.spreadsheetml.styles+xml"/>

        """
        for index in sheets.indices {
            overrides += "<Override PartName=\"/xl/worksheets/sheet\(index + 1).xml\" ContentType=\"application/vnd.openxmlformats-officedocument.spreadsheetml.worksheet+xml\"/>\n"
        }
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">
        <Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>
        <Default Extension="xml" ContentType="application/xml"/>
        \(overrides)</Types>

        """
        return Data(xml.utf8)
    }

    private static func rootRelationships() -> Data {
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        <Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="xl/workbook.xml"/>
        </Relationships>

        """
        return Data(xml.utf8)
    }

    private static func workbook(sheets: [String]) -> Data {
        var entries = ""
        for (index, name) in sheets.enumerated() {
            entries += "<sheet name=\"\(XMLText.escape(name))\" sheetId=\"\(index + 1)\" r:id=\"rId\(index + 1)\"/>\n"
        }
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">
        <sheets>
        \(entries)</sheets>
        </workbook>

        """
        return Data(xml.utf8)
    }

    private static func workbookRelationships(sheets: [String]) -> Data {
        var relationships = ""
        for index in sheets.indices {
            relationships += "<Relationship Id=\"rId\(index + 1)\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet\" Target=\"worksheets/sheet\(index + 1).xml\"/>\n"
        }
        relationships += "<Relationship Id=\"rIdStyles\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/styles\" Target=\"styles.xml\"/>\n"
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">
        \(relationships)</Relationships>

        """
        return Data(xml.utf8)
    }

    private static func styles() -> Data {
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
        <fonts count="1"><font><sz val="11"/><name val="Calibri"/><family val="2"/></font></fonts>
        <fills count="2"><fill><patternFill patternType="none"/></fill><fill><patternFill patternType="gray125"/></fill></fills>
        <borders count="1"><border><left/><right/><top/><bottom/><diagonal/></border></borders>
        <cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>
        <cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" xfId="0"/></cellXfs>
        <cellStyles count="1"><cellStyle name="Normal" xfId="0" builtinId="0"/></cellStyles>
        </styleSheet>

        """
        return Data(xml.utf8)
    }
}

enum XLSXCell: Equatable, Sendable {
    case text(String)
    case number(Double)
    case blank
}

enum XMLText {
    /// XML 1.0 text escaping. Control characters XML cannot carry are dropped rather than
    /// producing a package a reader would refuse.
    static func escape(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.count)
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x26: escaped += "&amp;"
            case 0x3C: escaped += "&lt;"
            case 0x3E: escaped += "&gt;"
            case 0x22: escaped += "&quot;"
            case 0x27: escaped += "&apos;"
            case 0x09, 0x0A, 0x0D:
                escaped.unicodeScalars.append(scalar)
            default:
                if scalar.value >= 0x20 { escaped.unicodeScalars.append(scalar) }
            }
        }
        return escaped
    }
}

/// A ZIP container of stored entries. Spreadsheet packages are ZIP archives; writing the entries
/// uncompressed avoids a compression dependency, and both Excel and openpyxl read stored entries.
/// The archive is deterministic: fixed DOS timestamp, entries in the order given.
enum ZIPWriter {
    static func archive(_ entries: [(name: String, data: Data)]) -> Data {
        var output = Data()
        var central: [(name: String, crc: UInt32, size: UInt32, offset: UInt32)] = []

        for entry in entries {
            let name = Data(entry.name.utf8)
            let crc = CRC32.checksum(entry.data)
            let size = UInt32(entry.data.count)
            let offset = UInt32(output.count)
            central.append((name: entry.name, crc: crc, size: size, offset: offset))

            output.appendLE(UInt32(0x0403_4B50))       // local file header
            output.appendLE(UInt16(20))               // version needed
            output.appendLE(UInt16(0))                // flags: no encryption, ASCII names
            output.appendLE(UInt16(0))                // method: stored
            output.appendLE(UInt16(0))                // DOS time 00:00
            output.appendLE(UInt16(0x0021))           // DOS date 1980-01-01
            output.appendLE(crc)
            output.appendLE(size)                     // compressed size
            output.appendLE(size)                     // uncompressed size
            output.appendLE(UInt16(name.count))
            output.appendLE(UInt16(0))                // extra length
            output.append(name)
            output.append(entry.data)
        }

        let centralStart = UInt32(output.count)
        for entry in central {
            let name = Data(entry.name.utf8)
            output.appendLE(UInt32(0x0201_4B50))       // central directory header
            output.appendLE(UInt16(20))               // version made by
            output.appendLE(UInt16(20))               // version needed
            output.appendLE(UInt16(0))
            output.appendLE(UInt16(0))                // method: stored
            output.appendLE(UInt16(0))
            output.appendLE(UInt16(0x0021))
            output.appendLE(entry.crc)
            output.appendLE(entry.size)
            output.appendLE(entry.size)
            output.appendLE(UInt16(name.count))
            output.appendLE(UInt16(0))                // extra
            output.appendLE(UInt16(0))                // comment
            output.appendLE(UInt16(0))                // disk
            output.appendLE(UInt16(0))                // internal attributes
            output.appendLE(UInt32(0))                // external attributes
            output.appendLE(entry.offset)
            output.append(name)
        }
        let centralSize = UInt32(output.count) - centralStart

        output.appendLE(UInt32(0x0605_4B50))           // end of central directory
        output.appendLE(UInt16(0))
        output.appendLE(UInt16(0))
        output.appendLE(UInt16(central.count))
        output.appendLE(UInt16(central.count))
        output.appendLE(centralSize)
        output.appendLE(centralStart)
        output.appendLE(UInt16(0))
        return output
    }
}

enum CRC32 {
    private static let table: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = value & 1 == 1 ? 0xEDB8_8320 ^ (value >> 1) : value >> 1
        }
        return value
    }

    static func checksum(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in data {
            crc = table[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }
}
