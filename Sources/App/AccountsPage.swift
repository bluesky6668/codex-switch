// 账号列表：表头、账号行与底栏。
import SwiftUI

private enum Column {
    static let usage: CGFloat = 200
    static let gap: CGFloat = 28
    static let actions: CGFloat = 104
}

struct AccountsPage: View {
    @EnvironmentObject var model: AppModel
    let query: String
    @Binding var showAdd: Bool

    private var rows: [(Int, AccountMeta)] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        return model.accounts.enumerated().filter { _, meta in
            q.isEmpty || meta.label.lowercased().contains(q) || (meta.email?.lowercased().contains(q) ?? false)
        }.map { ($0.offset, $0.element) }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let error = model.loadError {
                banner("exclamationmark.triangle.fill", Theme.danger, error, action: ("安全检查", { model.page = .security }))
            } else if let unsaved = model.unsavedCurrent {
                banner("info.circle.fill", Theme.brand,
                       "ChatGPT 当前登录的 \(unsaved.email ?? unsaved.accountId) 尚未保存，切换前会自动保存",
                       action: ("立即保存", model.saveCurrent))
            }

            header
            Divider().overlay(Theme.line)

            if model.accounts.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(rows, id: \.1.id) { position, meta in
                            AccountRow(position: position, meta: meta, isCurrent: meta.key == model.currentKey)
                            Divider().overlay(Theme.line)
                        }
                    }
                }
            }

            Divider().overlay(Theme.line)
            footer
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            Text("账号").frame(maxWidth: .infinity, alignment: .leading)
            headerCell("5h 剩余")
            headerCell("每周剩余")
            Spacer().frame(width: Column.actions)
        }
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Theme.subtle)
        .padding(.horizontal, 20)
        .frame(height: 44)
    }

    private func headerCell(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
            Text("重置时间").font(.system(size: 10)).foregroundStyle(Theme.muted)
        }
        .frame(width: Column.usage, alignment: .leading)
        .padding(.trailing, Column.gap)
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Text("\(model.accounts.count) 个账号")
            if model.refreshingUsage {
                HStack(spacing: 6) { ProgressView().controlSize(.mini); Text("正在刷新额度…") }
            } else if let fetched = model.lastUsageFetch {
                Text("额度更新于 \(timeFormatter.string(from: fetched))")
            }
            Spacer()
            Label("令牌仅存于本机钥匙串", systemImage: "lock.shield").foregroundStyle(Theme.muted)
            Button("撤销上次切换", action: model.undo)
                .buttonStyle(.plain)
                .foregroundStyle(model.hasUndo ? Theme.brand : Theme.muted)
                .disabled(!model.hasUndo || model.busy != nil)
        }
        .font(.system(size: 12))
        .foregroundStyle(Theme.subtle)
        .padding(.horizontal, 20)
        .frame(height: 40)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.2.slash").font(.system(size: 32)).foregroundStyle(Theme.muted)
            Text("账号库为空").font(.system(size: 14, weight: .medium)).foregroundStyle(Theme.ink)
            Text("先保存 ChatGPT 当前登录的账号，或通过浏览器登录新账号。")
                .font(.system(size: 12)).foregroundStyle(Theme.subtle)
            Button("添加账号") { showAdd = true }.buttonStyle(PrimaryButtonStyle())
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func banner(_ symbol: String, _ tint: Color, _ text: String,
                        action: (String, () -> Void)) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(text).font(.system(size: 12)).foregroundStyle(Theme.ink).lineLimit(2)
            Spacer()
            Button(action.0, action: action.1).buttonStyle(OutlineButtonStyle())
        }
        .padding(.horizontal, 20).padding(.vertical, 8)
        .background(tint.opacity(0.07))
    }
}

struct AccountRow: View {
    @EnvironmentObject var model: AppModel
    let position: Int
    let meta: AccountMeta
    let isCurrent: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Text(meta.label).font(.system(size: 13)).foregroundStyle(Theme.ink).lineLimit(1)
                    PlanChip(plan: meta.plan)
                }
                HStack(spacing: 6) {
                    if isCurrent {
                        Circle().fill(Theme.ok).frame(width: 5, height: 5)
                        Text("正在使用").foregroundStyle(Theme.ok)
                    }
                    if let error = meta.usageError {
                        Circle().fill(Theme.danger).frame(width: 5, height: 5)
                        Text("额度查询失败").foregroundStyle(Theme.danger).help(error)
                    }
                    if let email = meta.email, email != meta.label { Text(email) }
                    Text("#\(position + 1)").foregroundStyle(Theme.muted)
                }
                .font(.system(size: 11))
                .foregroundStyle(Theme.subtle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            UsageCell(window: meta.usage?.fiveHour, fetched: meta.usage != nil)
                .frame(width: Column.usage).padding(.trailing, Column.gap)
            UsageCell(window: meta.usage?.oneWeek, fetched: meta.usage != nil)
                .frame(width: Column.usage).padding(.trailing, Column.gap)

            HStack(spacing: 8) {
                if isCurrent {
                    Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Theme.brand).frame(width: 52)
                } else {
                    Button("切换") { model.switchTo(meta) }
                        .buttonStyle(OutlineButtonStyle())
                        .disabled(model.busy != nil)
                }
                moreMenu
            }
            .frame(width: Column.actions, alignment: .trailing)
        }
        .font(.system(size: 12).monospacedDigit())
        .foregroundStyle(Theme.subtle)
        .padding(.horizontal, 20)
        .frame(height: 58)
        .background(isCurrent ? Theme.bg1 : hovering ? Theme.bg1.opacity(0.6) : .clear)
        .overlay(alignment: .leading) {
            if isCurrent { Rectangle().fill(Theme.brand).frame(width: 3) }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .contextMenu { menuItems }
    }

    private var moreMenu: some View {
        Menu { menuItems } label: {
            Image(systemName: "ellipsis").foregroundStyle(Theme.muted).frame(width: 24, height: 24)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }

    @ViewBuilder private var menuItems: some View {
        if !isCurrent { Button("切换到此账号") { model.switchTo(meta) } }
        Button("重命名…") { rename() }
        if let email = meta.email {
            Button("复制邮箱") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(email, forType: .string)
            }
        }
        Divider()
        Button("删除…", role: .destructive) { confirmRemove() }
    }

    private func rename() {
        let alert = NSAlert()
        alert.messageText = "重命名账号"
        let field = NSTextField(string: meta.label)
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = field
        if alert.runModal() == .alertFirstButtonReturn { model.rename(meta, to: field.stringValue) }
    }

    private func confirmRemove() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "删除 \(meta.label)？"
        alert.informativeText = isCurrent
            ? "钥匙串中的令牌会一并删除。auth.json 仍保留该账号的登录态，如需退出请在 ChatGPT 中登出。"
            : "钥匙串中的令牌会一并删除，之后需要重新登录才能再次添加。"
        alert.addButton(withTitle: "删除").hasDestructiveAction = true
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn { model.remove(meta) }
    }
}

/// 额度单元格：进度条 + 剩余百分比，下方是重置时间。余量低时变黄，耗尽变红。
struct UsageCell: View {
    let window: UsageWindow?
    let fetched: Bool

    var body: some View {
        let remaining = window?.remainingPercent
        let tint = remaining.map { $0 <= 0 ? Theme.danger : $0 < 15 ? Theme.warning : Theme.brand } ?? Theme.muted
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                GeometryReader { geo in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.bg2)
                        Capsule().fill(tint).frame(width: geo.size.width * CGFloat((remaining ?? 0) / 100))
                    }
                }
                .frame(height: 4)
                Text(remaining.map { "\(Int($0.rounded()))%" } ?? "--")
                    .font(.system(size: 13, weight: .semibold).monospacedDigit())
                    .foregroundStyle(remaining.map { $0 < 15 ? tint : Theme.ink } ?? Theme.muted)
                    .frame(width: 42, alignment: .trailing)
            }
            Text(window?.resetAt.map(dateTimeFormatter.string) ?? (fetched ? "无此窗口" : "额度未获取"))
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(Theme.subtle)
        }
    }
}
