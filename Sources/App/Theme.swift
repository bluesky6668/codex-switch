// 配色与通用小组件。
import SwiftUI

enum Theme {
    static let brand = Color(light: 0x2563EB, dark: 0x60A5FA)
    static let ink = Color(light: 0x0F172A, dark: 0xE5EDF7)
    static let subtle = Color(light: 0x64748B, dark: 0x94A3B8)
    static let muted = Color(light: 0x94A3B8, dark: 0x64748B)
    static let bg0 = Color(light: 0xFFFFFF, dark: 0x0B1120)
    static let bg1 = Color(light: 0xF8FAFC, dark: 0x111827)
    static let bg2 = Color(light: 0xEEF2F7, dark: 0x1E293B)
    static let line = Color(light: 0x0F172A, dark: 0xE2E8F0).opacity(0.12)
    static let ok = Color(hex: 0x22C55E)
    static let warning = Color(hex: 0xF59E0B)
    static let danger = Color(hex: 0xEF4444)
    static let selected = Color(light: 0x2563EB, dark: 0x60A5FA).opacity(0.08)
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }

    init(light: UInt32, dark: UInt32) {
        self.init(nsColor: NSColor(name: nil) { appearance in
            let hex = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        })
    }
}

/// 计划标签：PLUS / PRO / TEAM / FREE 等，配色对应原版的 planChip。
struct PlanChip: View {
    let plan: String?

    var body: some View {
        if let plan, !plan.isEmpty {
            let (fg, bg, border) = colors(plan.lowercased())
            Text(plan.uppercased())
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(fg)
                .padding(.horizontal, 6)
                .frame(height: 18)
                .background(bg, in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(border))
        }
    }

    private func colors(_ plan: String) -> (Color, Color, Color) {
        switch plan {
        case "pro", "promax":
            return (Color(hex: 0x2563EB), Color(hex: 0x2563EB).opacity(0.08), Color(hex: 0x2563EB).opacity(0.3))
        case "plus":
            return (Color(hex: 0x6D5BD0), Color(hex: 0x6D5BD0).opacity(0.08), Color(hex: 0x6D5BD0).opacity(0.3))
        case "team", "business", "enterprise", "edu":
            return (Color(hex: 0x0E7490), Color(hex: 0x0E7490).opacity(0.08), Color(hex: 0x0E7490).opacity(0.45))
        default:
            return (Theme.subtle, Theme.bg2, Theme.line)
        }
    }
}

/// 原版的白底细边框按钮（“切换”等）。
struct OutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 10)
            .frame(height: 26)
            .background(configuration.isPressed ? Theme.bg2 : Theme.bg0, in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.line.opacity(1.5)))
            .shadow(color: .black.opacity(0.05), radius: 1, y: 1)
    }
}

/// 原版右上角的蓝色主按钮（“添加账号”）。
struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(
                LinearGradient(colors: [Color(hex: 0x3B82F6), Color(hex: 0x2563EB)], startPoint: .top, endPoint: .bottom)
                    .opacity(configuration.isPressed ? 0.85 : 1),
                in: RoundedRectangle(cornerRadius: 7))
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14))
                .foregroundStyle(Theme.subtle)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(help)
    }
}

let dateTimeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy/MM/dd  HH:mm"
    return formatter
}()

let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm"
    return formatter
}()
