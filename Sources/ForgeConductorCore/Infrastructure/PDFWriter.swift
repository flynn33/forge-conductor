// PDFWriter.swift
// What: Generates simple PDF documents using only native Swift/Foundation primitives.
// How: It lays out wrapped text into pages and emits a valid object/xref/trailer graph
// directly to Data before an atomic file write.
// Why: Document tools remain dependency-free and available in restricted installations.

import Foundation

/// Minimal multi-page PDF writer (Helvetica, markdown-ish headings) — stdlib only.
public enum PDFWriter {
    public static func write(path: URL, content: String, title: String = "") throws -> [String: Any] {
        let parent = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let pageW = 612
        let pageH = 792
        let marginX = 50
        let topY = pageH - 50
        let bottomY = 50
        let lineH = 14

        let rows = layoutLines(content)
        var pages: [String] = []
        var y = topY
        var stream: [String] = []

        func emit(_ yy: Int, _ size: Int, _ text: String) {
            stream.append("BT")
            stream.append("/F1 \(size) Tf")
            stream.append("\(marginX) \(yy) Td")
            stream.append("(\(escape(text))) Tj")
            stream.append("ET")
        }
        func flush() {
            let body = stream.isEmpty ? "BT /F1 11 Tf 50 750 Td ( ) Tj ET" : stream.joined(separator: "\n")
            pages.append(body)
            stream = []
            y = topY
        }

        if !title.isEmpty {
            emit(y, 18, String(title.prefix(120)))
            y -= 22
            emit(y, 9, "Forge-Conductor docs export")
            y -= 20
        }

        for (style, text) in rows {
            if style == "blank" {
                y -= lineH / 2
                if y < bottomY { flush() }
                continue
            }
            var size = 11
            var extra = 0
            switch style {
            case "h1": size = 16; extra = 6
            case "h2": size = 13; extra = 4
            case "h3": size = 12; extra = 2
            case "code": size = 9
            default: break
            }
            if y - lineH - extra < bottomY {
                flush()
                if !title.isEmpty {
                    emit(pageH - 36, 8, String(title.prefix(80)))
                    y = topY - 10
                }
            }
            y -= extra
            emit(y, size, text)
            y -= lineH + (style == "h1" ? 4 : 0)
        }
        if !stream.isEmpty || pages.isEmpty { flush() }

        // Build PDF objects
        var objects: [Data] = []
        func add(_ s: String) -> Int {
            objects.append(Data(s.utf8))
            return objects.count
        }
        func addData(_ d: Data) -> Int {
            objects.append(d)
            return objects.count
        }

        _ = add("<< /Type /Catalog /Pages 2 0 R >>")
        objects.append(Data()) // placeholder pages obj index 1
        let fontID = add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")

        var pageIDs: [Int] = []
        for streamBody in pages {
            let raw = Data(streamBody.utf8)
            var content = Data()
            content.append(contentsOf: "<< /Length \(raw.count) >>\nstream\n".utf8)
            content.append(raw)
            content.append(contentsOf: "\nendstream".utf8)
            let contentID = addData(content)
            let pageID = add(
                "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 \(pageW) \(pageH)] "
                    + "/Contents \(contentID) 0 R /Resources << /Font << /F1 \(fontID) 0 R >> >> >>"
            )
            pageIDs.append(pageID)
        }
        let kids = pageIDs.map { "\($0) 0 R" }.joined(separator: " ")
        objects[1] = Data("<< /Type /Pages /Kids [ \(kids) ] /Count \(pageIDs.count) >>".utf8)

        var buf = Data("%PDF-1.4\n".utf8)
        buf.append(contentsOf: [0x25, 0xE2, 0xE3, 0xCF, 0xD3, 0x0A])
        var offsets: [Int] = [0]
        for (i, obj) in objects.enumerated() {
            offsets.append(buf.count)
            buf.append(contentsOf: "\(i + 1) 0 obj\n".utf8)
            buf.append(obj)
            buf.append(contentsOf: "\nendobj\n".utf8)
        }
        let xref = buf.count
        buf.append(contentsOf: "xref\n0 \(objects.count + 1)\n".utf8)
        buf.append(contentsOf: "0000000000 65535 f \n".utf8)
        for off in offsets.dropFirst() {
            buf.append(contentsOf: String(format: "%010d 00000 n \n", off).utf8)
        }
        buf.append(contentsOf: """
        trailer
        << /Size \(objects.count + 1) /Root 1 0 R >>
        startxref
        \(xref)
        %%EOF

        """.utf8)

        try buf.write(to: path, options: .atomic)
        return [
            "ok": true,
            "path": path.path,
            "bytes_written": buf.count,
            "pages": pageIDs.count,
            "engine": "swift-pdf-writer",
            "title": title,
        ]
    }

    private static func escape(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "(", with: "\\(")
            .replacingOccurrences(of: ")", with: "\\)")
            .replacingOccurrences(of: "\r", with: "")
    }

    private static func layoutLines(_ content: String) -> [(String, String)] {
        var rows: [(String, String)] = []
        var inCode = false
        for raw in content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) {
            let line = raw
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                inCode.toggle()
                rows.append(("blank", ""))
                continue
            }
            if inCode {
                var t = line.replacingOccurrences(of: "\t", with: "    ")
                while t.count > 92 {
                    rows.append(("code", String(t.prefix(92))))
                    t = String(t.dropFirst(92))
                }
                rows.append(("code", t))
                continue
            }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty {
                rows.append(("blank", ""))
                continue
            }
            var style = "normal"
            var text = trimmed
            if trimmed.hasPrefix("### ") { style = "h3"; text = String(trimmed.dropFirst(4)) }
            else if trimmed.hasPrefix("## ") { style = "h2"; text = String(trimmed.dropFirst(3)) }
            else if trimmed.hasPrefix("# ") { style = "h1"; text = String(trimmed.dropFirst(2)).uppercased() }
            else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
                style = "bullet"
                text = "• " + String(trimmed.dropFirst(2))
            }
            text = text.replacingOccurrences(of: "*", with: "")
                .replacingOccurrences(of: "_", with: "")
                .replacingOccurrences(of: "`", with: "")
            let width = (style == "h1" || style == "h2" || style == "h3") ? 88 : 92
            for part in wrap(text, width: width) {
                rows.append((style, part))
            }
        }
        if rows.isEmpty { rows.append(("normal", "(empty document)")) }
        return rows
    }

    private static func wrap(_ text: String, width: Int) -> [String] {
        let words = text.split(separator: " ").map(String.init)
        guard !words.isEmpty else { return [""] }
        var lines: [String] = []
        var cur: [String] = []
        var n = 0
        for w in words {
            let add = w.count + (cur.isEmpty ? 0 : 1)
            if n + add > width, !cur.isEmpty {
                lines.append(cur.joined(separator: " "))
                cur = [w]
                n = w.count
            } else {
                cur.append(w)
                n += add
            }
        }
        if !cur.isEmpty { lines.append(cur.joined(separator: " ")) }
        return lines
    }
}
