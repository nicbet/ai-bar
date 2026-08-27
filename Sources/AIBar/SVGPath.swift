import SwiftUI

struct SVGPathShape: Shape {
    let pathData: String
    let viewBox: CGSize

    func path(in rect: CGRect) -> Path {
        let raw = Self.parse(pathData)
        let scale = min(rect.width / viewBox.width, rect.height / viewBox.height)
        let ox = (rect.width - viewBox.width * scale) / 2
        let oy = (rect.height - viewBox.height * scale) / 2
        let t = CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: rect.minX + ox, y: rect.minY + oy))
        return Path(raw).applying(t)
    }

    static func parse(_ data: String) -> CGPath {
        let path = CGMutablePath()
        let tokens = tokenize(data)
        var i = 0
        var cp = CGPoint.zero
        var sp = CGPoint.zero
        var cmd: Character = "M"

        func num() -> CGFloat {
            guard i < tokens.count, let v = Double(tokens[i]) else { return 0 }
            i += 1
            return CGFloat(v)
        }

        while i < tokens.count {
            let tok = tokens[i]
            if tok.count == 1, let c = tok.first, c.isLetter {
                cmd = c
                i += 1
                if cmd == "Z" || cmd == "z" {
                    path.closeSubpath()
                    cp = sp
                    continue
                }
            }

            switch cmd {
            case "M":
                let x = num(), y = num()
                cp = CGPoint(x: x, y: y); sp = cp
                path.move(to: cp)
                cmd = "L"
            case "m":
                let dx = num(), dy = num()
                cp.x += dx; cp.y += dy; sp = cp
                path.move(to: cp)
                cmd = "l"
            case "L":
                let x = num(), y = num()
                cp = CGPoint(x: x, y: y)
                path.addLine(to: cp)
            case "l":
                let dx = num(), dy = num()
                cp.x += dx; cp.y += dy
                path.addLine(to: cp)
            case "H":
                cp.x = num()
                path.addLine(to: cp)
            case "h":
                cp.x += num()
                path.addLine(to: cp)
            case "V":
                cp.y = num()
                path.addLine(to: cp)
            case "v":
                cp.y += num()
                path.addLine(to: cp)
            case "C":
                let x1 = num(), y1 = num(), x2 = num(), y2 = num(), x = num(), y = num()
                path.addCurve(to: CGPoint(x: x, y: y),
                              control1: CGPoint(x: x1, y: y1),
                              control2: CGPoint(x: x2, y: y2))
                cp = CGPoint(x: x, y: y)
            case "c":
                let dx1 = num(), dy1 = num(), dx2 = num(), dy2 = num(), dx = num(), dy = num()
                let c1 = CGPoint(x: cp.x + dx1, y: cp.y + dy1)
                let c2 = CGPoint(x: cp.x + dx2, y: cp.y + dy2)
                let end = CGPoint(x: cp.x + dx, y: cp.y + dy)
                path.addCurve(to: end, control1: c1, control2: c2)
                cp = end
            default:
                i += 1
            }
        }
        return path
    }

    private static func tokenize(_ data: String) -> [String] {
        var tokens: [String] = []
        var cur = ""

        func flush() { if !cur.isEmpty { tokens.append(cur); cur = "" } }

        for ch in data {
            if ch.isLetter {
                flush()
                tokens.append(String(ch))
            } else if ch == "," || ch == " " || ch == "\t" || ch == "\n" || ch == "\r" {
                flush()
            } else if ch == "-" && !cur.isEmpty && cur.last != "e" && cur.last != "E" {
                flush()
                cur.append(ch)
            } else if ch == "." && cur.contains(".") {
                flush()
                cur.append(ch)
            } else {
                cur.append(ch)
            }
        }
        flush()
        return tokens
    }
}
