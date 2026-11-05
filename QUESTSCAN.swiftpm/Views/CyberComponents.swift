import SwiftUI

// MARK: - Visual system

enum CyberColor {
    static let ink = Color(red: 0.025, green: 0.040, blue: 0.080)
    static let panel = Color(red: 0.055, green: 0.075, blue: 0.125)
    static let raised = Color(red: 0.085, green: 0.110, blue: 0.175)
    static let cyan = Color(red: 0.27, green: 0.94, blue: 0.94)
    static let lilac = Color(red: 0.73, green: 0.66, blue: 1.0)
    static let text = Color(red: 0.93, green: 0.96, blue: 1.0)
    static let muted = Color(red: 0.64, green: 0.71, blue: 0.81)
    static let warning = Color(red: 1.0, green: 0.77, blue: 0.40)
    static let danger = Color(red: 1.0, green: 0.45, blue: 0.55)
    static let border = Color.white.opacity(0.11)
}

struct CyberBackground: View {
    var body: some View {
        ZStack {
            CyberColor.ink
            LinearGradient(colors: [CyberColor.lilac.opacity(0.07), .clear, CyberColor.cyan.opacity(0.04)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Canvas { context, size in
                var grid = Path()
                let spacing: CGFloat = 42
                for x in stride(from: CGFloat(0), through: size.width, by: spacing) {
                    grid.move(to: CGPoint(x: x, y: 0))
                    grid.addLine(to: CGPoint(x: x, y: size.height))
                }
                for y in stride(from: CGFloat(0), through: size.height, by: spacing) {
                    grid.move(to: CGPoint(x: 0, y: y))
                    grid.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(grid, with: .color(CyberColor.cyan.opacity(0.025)), lineWidth: 0.5)
            }
            .accessibilityHidden(true)
        }
        .ignoresSafeArea()
    }
}

struct CyberPanel<Content: View>: View {
    var accent: Color = CyberColor.cyan
    var padding: CGFloat = 18
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(CyberColor.panel.opacity(0.96))
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(CyberColor.border, lineWidth: 1))
            .overlay(alignment: .topLeading) {
                Capsule().fill(accent.opacity(0.8)).frame(width: 34, height: 2).padding(.leading, 22)
            }
    }
}

enum CyberButtonKind { case primary, secondary, quiet, danger }

struct CyberButtonStyle: ButtonStyle {
    var kind: CyberButtonKind = .primary
    @Environment(\.isEnabled) private var isEnabled

    private var foreground: Color {
        switch kind {
        case .primary: return CyberColor.ink
        case .secondary: return CyberColor.cyan
        case .quiet: return CyberColor.text
        case .danger: return CyberColor.danger
        }
    }

    private var background: Color {
        switch kind {
        case .primary: return CyberColor.cyan
        case .secondary: return CyberColor.cyan.opacity(0.09)
        case .quiet: return CyberColor.raised
        case .danger: return CyberColor.danger.opacity(0.10)
        }
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.subheadline, design: .rounded).weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .frame(minHeight: 48)
            .foregroundColor(foreground)
            .background(background)
            .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(kind == .primary ? Color.clear : foreground.opacity(0.2), lineWidth: 1))
            .opacity(isEnabled ? (configuration.isPressed ? 0.72 : 1) : 0.38)
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

struct CyberIconButton: View {
    let symbol: String
    let label: String
    var color: Color = CyberColor.text
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 18, weight: .medium))
                .foregroundColor(color)
                .frame(width: 46, height: 46)
                .background(CyberColor.raised.opacity(0.85))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(CyberColor.border, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}

struct CyberSectionHeading: View {
    let eyebrow: String
    let title: String
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(eyebrow).font(.system(size: 10, weight: .bold, design: .monospaced)).tracking(2.4).foregroundColor(CyberColor.cyan)
            Text(title).font(.system(.title3, design: .rounded).weight(.bold)).foregroundColor(CyberColor.text)
            if let detail = detail {
                Text(detail).font(.caption).foregroundColor(CyberColor.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

struct StatusPill: View {
    let text: String
    var symbol: String? = nil
    var color: Color = CyberColor.cyan

    var body: some View {
        HStack(spacing: 6) {
            if let symbol = symbol { Image(systemName: symbol).font(.system(size: 10, weight: .semibold)) }
            Text(text).font(.system(size: 11, weight: .semibold, design: .rounded))
        }
        .foregroundColor(color)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(color.opacity(0.10))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(color.opacity(0.20), lineWidth: 1))
        .accessibilityElement(children: .combine)
    }
}

struct MetricTile: View {
    let value: String
    let label: String
    var symbol: String? = nil
    var accent: Color = CyberColor.cyan

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                if let symbol = symbol { Image(systemName: symbol).font(.system(size: 10)).foregroundColor(accent) }
                Text(label).font(.caption2).foregroundColor(CyberColor.muted)
            }
            Text(value).font(.system(.title3, design: .monospaced).weight(.semibold)).foregroundColor(CyberColor.text).lineLimit(1).minimumScaleFactor(0.65)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct CoverageGauge: View {
    let progress: Double
    var diameter: CGFloat = 92

    private var fraction: Double { progress.isFinite ? min(max(progress, 0), 0.99) : 0 }

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.09), lineWidth: 5)
            Circle().trim(from: 0, to: CGFloat(fraction))
                .stroke(AngularGradient(colors: [CyberColor.lilac, CyberColor.cyan], center: .center, startAngle: .degrees(0), endAngle: .degrees(360)), style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text("\(Int(fraction * 100))").font(.system(size: diameter * 0.28, weight: .medium, design: .monospaced))
                Text("%").font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundColor(CyberColor.muted)
            }
            .foregroundColor(CyberColor.text)
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("観測面の写真カバー率")
        .accessibilityValue("\(Int(fraction * 100))パーセント")
    }
}

struct AdjustmentSlider: View {
    let title: String
    let symbol: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let neutral: Double
    var unit: String = ""

    private var formatted: String { String(format: "%+.0f%@", (value - neutral) * 100, unit) }

    var body: some View {
        VStack(spacing: 6) {
            HStack {
                Label(title, systemImage: symbol).font(.caption).foregroundColor(CyberColor.text)
                Spacer()
                Text(formatted).font(.system(.caption, design: .monospaced)).foregroundColor(CyberColor.cyan)
            }
            Slider(value: $value, in: range)
                .tint(CyberColor.cyan)
                .accessibilityLabel(title)
                .accessibilityValue(formatted)
        }
    }
}

// Entirely procedural illustration: no photos, assets, or fabricated scan data.
struct TechnicalRoomArt: View {
    var body: some View {
        Canvas { context, size in
            func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: x * size.width, y: y * size.height) }
            func line(_ coordinates: [(CGFloat, CGFloat)], color: Color, width: CGFloat = 1, dashed: Bool = false, closed: Bool = false) {
                guard let first = coordinates.first else { return }
                var path = Path()
                path.move(to: point(first.0, first.1))
                for coordinate in coordinates.dropFirst() { path.addLine(to: point(coordinate.0, coordinate.1)) }
                if closed { path.closeSubpath() }
                context.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round, dash: dashed ? [3, 5] : []))
            }
            func polygon(_ coordinates: [(CGFloat, CGFloat)], color: Color) {
                guard let first = coordinates.first else { return }
                var path = Path()
                path.move(to: point(first.0, first.1))
                for coordinate in coordinates.dropFirst() { path.addLine(to: point(coordinate.0, coordinate.1)) }
                path.closeSubpath()
                context.fill(path, with: .color(color))
            }
            let cyan = CyberColor.cyan
            let lilac = CyberColor.lilac
            // An open isometric room, with two walls and a translucent floor.
            polygon([(0.18, 0.30), (0.53, 0.14), (0.53, 0.49), (0.18, 0.65)], color: cyan.opacity(0.035))
            polygon([(0.53, 0.14), (0.88, 0.31), (0.88, 0.66), (0.53, 0.49)], color: lilac.opacity(0.05))
            polygon([(0.18, 0.65), (0.53, 0.49), (0.88, 0.66), (0.53, 0.84)], color: cyan.opacity(0.05))
            line([(0.18, 0.65), (0.18, 0.30), (0.53, 0.14), (0.88, 0.31), (0.88, 0.66), (0.53, 0.84), (0.18, 0.65), (0.53, 0.49), (0.88, 0.66)], color: cyan.opacity(0.7), width: 1.4)
            line([(0.53, 0.14), (0.53, 0.49)], color: lilac.opacity(0.75), width: 1.2)
            for index in 1...7 {
                let t = CGFloat(index) / 8
                line([(0.18 + 0.35 * t, 0.65 - 0.16 * t), (0.53 + 0.35 * t, 0.84 - 0.18 * t)], color: cyan.opacity(0.12))
                line([(0.53 + 0.35 * t, 0.49 + 0.17 * t), (0.18 + 0.35 * t, 0.65 + 0.19 * t)], color: cyan.opacity(0.12))
                line([(0.18, 0.30 + 0.35 * t), (0.53, 0.14 + 0.35 * t), (0.88, 0.31 + 0.35 * t)], color: lilac.opacity(0.08))
            }
            // Tall window in the right wall.
            line([(0.64, 0.23), (0.81, 0.312), (0.81, 0.49), (0.64, 0.408)], color: lilac, width: 1.4, closed: true)
            line([(0.725, 0.271), (0.725, 0.449)], color: lilac.opacity(0.55))
            line([(0.64, 0.319), (0.81, 0.401)], color: lilac.opacity(0.55))
            // Low sofa with layered seat, back and feet.
            polygon([(0.25, 0.51), (0.45, 0.42), (0.54, 0.465), (0.34, 0.555)], color: lilac.opacity(0.14))
            line([(0.25, 0.51), (0.25, 0.43), (0.45, 0.34), (0.45, 0.42), (0.54, 0.465), (0.54, 0.535), (0.34, 0.625), (0.25, 0.58), (0.25, 0.51), (0.34, 0.555), (0.54, 0.465)], color: lilac.opacity(0.85), width: 1.5)
            line([(0.25, 0.43), (0.29, 0.45), (0.49, 0.36), (0.45, 0.34)], color: lilac.opacity(0.7))
            line([(0.29, 0.45), (0.29, 0.49), (0.49, 0.40), (0.49, 0.36)], color: lilac.opacity(0.65))
            line([(0.34, 0.555), (0.34, 0.625)], color: lilac.opacity(0.7))
            line([(0.28, 0.60), (0.28, 0.635)], color: lilac.opacity(0.65))
            line([(0.50, 0.555), (0.50, 0.59)], color: lilac.opacity(0.65))
            // Coffee table with a visible wireframe top.
            polygon([(0.48, 0.61), (0.62, 0.546), (0.74, 0.605), (0.60, 0.674)], color: cyan.opacity(0.12))
            line([(0.48, 0.61), (0.62, 0.546), (0.74, 0.605), (0.60, 0.674)], color: cyan, width: 1.5, closed: true)
            line([(0.48, 0.61), (0.48, 0.697)], color: cyan.opacity(0.7))
            line([(0.60, 0.674), (0.60, 0.76)], color: cyan.opacity(0.7))
            line([(0.74, 0.605), (0.74, 0.692)], color: cyan.opacity(0.7))
            // Scan plane is illustration only, never a progress indicator.
            line([(0.14, 0.475), (0.53, 0.292), (0.92, 0.482)], color: cyan.opacity(0.42), dashed: true)
            line([(0.14, 0.70), (0.14, 0.27), (0.53, 0.09), (0.92, 0.275), (0.92, 0.71)], color: cyan.opacity(0.15), dashed: true)
            let nodes: [(CGFloat, CGFloat)] = [(0.18, 0.30), (0.53, 0.14), (0.88, 0.31), (0.18, 0.65), (0.53, 0.84), (0.88, 0.66)]
            for node in nodes {
                let center = point(node.0, node.1)
                context.fill(Path(ellipseIn: CGRect(x: center.x - 2, y: center.y - 2, width: 4, height: 4)), with: .color(cyan))
            }
            // Coordinate triad.
            line([(0.10, 0.87), (0.17, 0.90)], color: lilac, width: 1.5)
            line([(0.10, 0.87), (0.17, 0.835)], color: cyan, width: 1.5)
            line([(0.10, 0.87), (0.10, 0.79)], color: CyberColor.muted, width: 1.5)
        }
        .accessibilityHidden(true)
    }
}
