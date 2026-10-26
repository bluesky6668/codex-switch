// 安全检查页与设置页。
import SwiftUI

struct SecurityPage: View {
    @EnvironmentObject var model: AppModel

    private var fixable: Int { model.findings.filter { $0.fixable }.count }
    private var errors: Int { model.findings.filter { $0.level == .error && $0.fixed != true }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("安全检查").font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.ink)
                    Text("检查目录与文件权限、钥匙串条目是否齐全、Codex 凭据存储方式，以及可能含令牌的残留临时文件。")
                        .font(.system(size: 12)).foregroundStyle(Theme.subtle)
                }
                Spacer()
                Button("重新检查") { model.runDoctor(fix: false) }.buttonStyle(OutlineButtonStyle())
                Button(fixable > 0 ? "一键修复（\(fixable)）" : "一键修复") { model.runDoctor(fix: true) }
                    .buttonStyle(PrimaryButtonStyle())
                    .disabled(fixable == 0)
                    .opacity(fixable == 0 ? 0.5 : 1)
            }
            .padding(20)

            if !model.findings.isEmpty {
                summary.padding(.horizontal, 20).padding(.bottom, 12)
            }
            Divider().overlay(Theme.line)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(model.findings) { finding in
                        FindingRow(finding: finding)
                        Divider().overlay(Theme.line)
                    }
                }
            }
        }
        .onAppear { if model.findings.isEmpty { model.runDoctor(fix: false) } }
    }

    private var summary: some View {
        HStack(spacing: 8) {
            Image(systemName: errors > 0 ? "xmark.octagon.fill" : fixable > 0 ? "exclamationmark.triangle.fill" : "checkmark.seal.fill")
                .foregroundStyle(errors > 0 ? Theme.danger : fixable > 0 ? Theme.warning : Theme.ok)
            Text(errors > 0 ? "发现 \(errors) 个严重问题" : fixable > 0 ? "有 \(fixable) 项可以自动修复" : "未发现问题")
                .font(.system(size: 12, weight: .medium)).foregroundStyle(Theme.ink)
        }
    }
}

private struct FindingRow: View {
    let finding: Finding

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: symbol).foregroundStyle(tint).frame(width: 16)
            Text(finding.message).font(.system(size: 12)).foregroundStyle(Theme.ink)
                .textSelection(.enabled)
            Spacer()
            if let fixed = finding.fixed {
                Text(fixed ? "已修复" : "修复失败").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(fixed ? Theme.ok : Theme.danger)
            } else if finding.fixable {
                Text("可修复").font(.system(size: 11)).foregroundStyle(Theme.warning)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 11)
    }

    private var symbol: String {
        if finding.fixed == true { return "checkmark.circle.fill" }
        switch finding.level {
        case .ok: return "checkmark.circle.fill"
        case .info: return "info.circle"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private var tint: Color {
        if finding.fixed == true { return Theme.ok }
        switch finding.level {
        case .ok: return Theme.ok
        case .info: return Theme.subtle
        case .warning: return Theme.warning
        case .error: return Theme.danger
        }
    }
}

struct SettingsPage: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                section("账号切换") {
                    row("ChatGPT 正在运行时", "应用会在内存里持有旧令牌，重启后切换才会生效") {
                        Picker("", selection: $model.restartPreference) {
                            ForEach(RestartPreference.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden().frame(width: 140)
                    }
                }
                section("菜单栏") {
                    row("菜单栏显示", "5h 剩余为当前账号的数值；简称取邮箱 @ 前的部分，最多 8 个字符") {
                        Picker("", selection: $model.menuBarStyle) {
                            ForEach(MenuBarStyle.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden().frame(width: 160)
                    }
                }
                section("额度") {
                    row("自动刷新额度", "只读访问 chatgpt.com；未在使用的账号令牌过期时，会自动续期并存回钥匙串") {
                        Picker("", selection: $model.usageInterval) {
                            ForEach(UsageInterval.allCases) { Text($0.title).tag($0) }
                        }
                        .labelsHidden().frame(width: 160)
                    }
                }
                section("数据与安全") {
                    let paths = Paths.resolve()
                    row("令牌", "macOS 登录钥匙串，仅本机可用，不同步到 iCloud") { EmptyView() }
                    row("账号索引（不含令牌）", displayPath(paths.indexFile)) {
                        Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([paths.indexFile]) }
                            .buttonStyle(OutlineButtonStyle())
                    }
                    row("Codex 目录", displayPath(paths.codexDir)) { EmptyView() }
                    row("网络", "不监听端口；只在查询额度时访问 chatgpt.com 与 auth.openai.com，不跟随重定向") { EmptyView() }
                }
                section("关于") {
                    row("Codex Switch \(toolVersion)",
                        "独立开发，专注本机账号切换与钥匙串安全存储") {
                        Text("MIT License").font(.system(size: 12)).foregroundStyle(Theme.subtle)
                    }
                }
            }
            .padding(24)
            .frame(maxWidth: 720, alignment: .leading)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.subtle)
                .padding(.bottom, 8)
            VStack(spacing: 0) { content() }
                .background(Theme.bg0, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
        }
    }

    private func row<Accessory: View>(_ title: String, _ detail: String,
                                      @ViewBuilder accessory: () -> Accessory) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 13)).foregroundStyle(Theme.ink)
                Text(detail).font(.system(size: 11)).foregroundStyle(Theme.subtle).textSelection(.enabled)
            }
            Spacer()
            accessory()
        }
        .padding(.horizontal, 14).padding(.vertical, 11)
    }
}
