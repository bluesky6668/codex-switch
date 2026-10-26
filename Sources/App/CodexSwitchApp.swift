// 应用入口：菜单栏常驻 + 主窗口。主窗口打开时显示 Dock 图标，关闭后回到纯菜单栏。
import SwiftUI

@main
struct CodexSwitchApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    init() {
        if let output = ProcessInfo.processInfo.environment["CODEX_SWITCH_SNAPSHOT"] {
            Snapshot.render(to: output)
        }
    }

    var body: some Scene {
        Window("Codex Switch", id: "main") {
            MainWindow()
                .environmentObject(model)
                .onAppear { NSApp.setActivationPolicy(.regular) }
        }
        .defaultSize(width: 980, height: 640)
        .windowStyle(.hiddenTitleBar)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("账号") {
                Button("撤销上次切换") { model.undo() }.disabled(!model.hasUndo)
                Button("安全检查") { model.page = .security }
            }
        }

        MenuBarExtra {
            MenuContent().environmentObject(model)
        } label: {
            MenuBarLabel().environmentObject(model)
        }
    }
}

private struct MenuBarLabel: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        // 切换进行中显示沙漏，其余时间只占一个小图标的宽度。
        let symbol = model.busy == nil ? "arrow.left.arrow.right.circle" : "hourglass.circle"
        if model.menuBarStyle == .shortName, let name = model.currentShortName {
            Label(name, systemImage: symbol).labelStyle(.titleAndIcon)
        } else if model.menuBarStyle == .remaining, let remaining = model.currentRemaining {
            Label(remaining, systemImage: symbol).labelStyle(.titleAndIcon)
        } else {
            Image(systemName: symbol)
        }
    }
}

private struct MenuContent: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let busy = model.busy {
            Text(busy)
            Divider()
        }
        if let current = model.currentAccount {
            Text("当前：\(current.label)\(describePlan(current.plan))")
        } else if let unsaved = model.unsavedCurrent {
            Text("当前：\(unsaved.email ?? unsaved.accountId)（未保存）")
        } else {
            Text("当前未登录")
        }
        Divider()

        ForEach(Array(model.accounts.enumerated()), id: \.element.id) { position, meta in
            // Toggle 在菜单里显示为系统原生的勾选标记。
            Toggle(isOn: Binding(get: { meta.key == model.currentKey }, set: { _ in model.switchTo(meta) })) {
                Text(menuTitle(meta))
            }
            .keyboardShortcut(position < 9 ? KeyboardShortcut(KeyEquivalent(Character("\(position + 1)"))) : nil)
            .disabled(model.busy != nil)
        }
        if model.accounts.isEmpty { Text("账号库为空").foregroundStyle(.secondary) }
        Divider()

        if model.unsavedCurrent != nil {
            Button("保存当前登录") { model.saveCurrent() }
        }
        Button("添加账号…") { open(.accounts) }
        Button("撤销上次切换") { model.undo() }.disabled(!model.hasUndo || model.busy != nil)
        Divider()
        Button("打开主窗口") { open(.accounts) }.keyboardShortcut("o")
        Button("安全检查…") { open(.security) }
        Button(model.refreshingUsage ? "正在刷新额度…" : "刷新额度") {
            model.reload()
            model.refreshUsage(manual: true)
        }
        .keyboardShortcut("r")
        .disabled(model.refreshingUsage)
        Divider()
        Button("退出 Codex Switch") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }

    /// 例如 “user@example.com · PLUS    5h 78% · 周 59%”。
    private func menuTitle(_ meta: AccountMeta) -> String {
        var title = meta.label + (meta.plan.map { "  ·  \($0.uppercased())" } ?? "")
        if let usage = meta.usage {
            let parts = [("5h", usage.fiveHour), ("周", usage.oneWeek)].compactMap { name, window in
                window.map { "\(name) \(Int($0.remainingPercent.rounded()))%" }
            }
            if !parts.isEmpty { title += "    " + parts.joined(separator: " · ") }
        }
        return title
    }

    private func open(_ page: AppModel.Page) {
        model.page = page
        NSApp.setActivationPolicy(.regular)
        openWindow(id: "main")
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first { $0.title == "Codex Switch" }?.makeKeyAndOrderFront(nil)
        }
    }
}
