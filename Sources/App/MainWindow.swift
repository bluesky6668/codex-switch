// 主窗口：顶部分段导航 + 右侧操作。
import SwiftUI
import UniformTypeIdentifiers

struct MainWindow: View {
    @EnvironmentObject var model: AppModel
    @State private var searching = false
    @State private var query = ""
    @State private var showAdd = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().overlay(Theme.line)
            Group {
                switch model.page {
                case .accounts: AccountsPage(query: query, showAdd: $showAdd)
                case .security: SecurityPage()
                case .settings: SettingsPage()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.bg0)
        .overlay(alignment: .bottom) { ToastView() }
        .sheet(isPresented: $showAdd) { AddAccountSheet(isPresented: $showAdd) }
        .frame(minWidth: 760, minHeight: 480)
    }

    private var topBar: some View {
        HStack(spacing: 6) {
            HStack(spacing: 2) {
                tab("账号", "person.2", .accounts)
                tab("安全检查", "checkmark.shield", .security)
                tab("设置", "gearshape", .settings)
            }
            .padding(3)
            .background(Theme.bg1, in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.line))
            .padding(.leading, 72)

            Spacer()

            if let busy = model.busy {
                ProgressView().controlSize(.small)
                Text(busy).font(.system(size: 12)).foregroundStyle(Theme.subtle)
            }
            if model.page == .accounts {
                if searching {
                    TextField("搜索标签 / 邮箱", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 180)
                        .onExitCommand { searching = false; query = "" }
                }
                IconButton(symbol: "magnifyingglass", help: "搜索（⌘F）") {
                    searching.toggle()
                    if !searching { query = "" }
                }
                .keyboardShortcut("f", modifiers: .command)
            }
            IconButton(symbol: "arrow.clockwise", help: "刷新额度（⌘R）") {
                if model.page == .security {
                    model.runDoctor(fix: false)
                } else {
                    model.reload()
                    model.refreshUsage(manual: true)
                }
            }
            .disabled(model.refreshingUsage)
            .keyboardShortcut("r", modifiers: .command)
            Button { showAdd = true } label: {
                Label("添加账号", systemImage: "plus").labelStyle(.titleAndIcon)
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut("n", modifiers: .command)
            .padding(.leading, 4)
        }
        .padding(.horizontal, 16)
        .frame(height: 52)
    }

    private func tab(_ title: String, _ symbol: String, _ page: AppModel.Page) -> some View {
        let active = model.page == page
        return Button { model.page = page } label: {
            Label(title, systemImage: symbol)
                .font(.system(size: 12, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? Theme.ink : Theme.subtle)
                .padding(.horizontal, 10)
                .frame(height: 26)
                .background(active ? Theme.bg0 : .clear, in: RoundedRectangle(cornerRadius: 6))
                .shadow(color: .black.opacity(active ? 0.08 : 0), radius: 1, y: 1)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

struct ToastView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let toast = model.toast {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: toast.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(toast.isError ? Theme.danger : Theme.ok)
                Text(toast.message).font(.system(size: 12)).foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Button { model.toast = nil } label: { Image(systemName: "xmark").font(.system(size: 10)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.subtle)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .frame(maxWidth: 460)
            .background(Theme.bg0, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.line))
            .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
            .padding(.bottom, 44)
            .transition(.move(edge: .bottom).combined(with: .opacity))
        }
    }
}

// MARK: - 添加账号

struct AddAccountSheet: View {
    @EnvironmentObject var model: AppModel
    @Binding var isPresented: Bool
    @State private var label = ""
    @State private var deleteSource = true
    @State private var loginStarted = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("添加账号").font(.system(size: 16, weight: .semibold))

            if loginStarted {
                loginProgress
            } else {
                option(
                    symbol: "person.crop.circle.badge.checkmark", title: "保存当前登录",
                    detail: model.unsavedCurrent.map { "ChatGPT 当前登录的 \($0.email ?? $0.accountId) 还没保存" }
                        ?? "当前登录已在账号库中，或尚未登录",
                    enabled: model.unsavedCurrent != nil
                ) {
                    model.saveCurrent()
                    isPresented = false
                }
                option(symbol: "safari", title: "通过浏览器登录新账号",
                       detail: "调用官方 codex login，在独立环境登录，不影响当前登录", enabled: true) {
                    loginStarted = true
                    model.startLogin(label: label.isEmpty ? nil : label)
                }
                option(symbol: "doc.badge.plus", title: "从 auth.json 文件导入",
                       detail: "导入其他设备导出的登录文件", enabled: true) { pickFile() }

                HStack {
                    TextField("账号名称（可选，用于浏览器登录）", text: $label).textFieldStyle(.roundedBorder)
                    Toggle("导入后删除源文件", isOn: $deleteSource).toggleStyle(.checkbox).font(.system(size: 12))
                }
                HStack {
                    Spacer()
                    Button("取消") { isPresented = false }.keyboardShortcut(.cancelAction)
                }
            }
        }
        .padding(20)
        .frame(width: 480)
        .onChange(of: model.loginRunning) { _, running in
            if loginStarted && !running { isPresented = false }
        }
    }

    private var loginProgress: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("请在浏览器中完成登录…").font(.system(size: 13))
            }
            if let url = model.loginURL {
                Text("浏览器没有自动打开？").font(.system(size: 12)).foregroundStyle(Theme.subtle)
                Link("点击这里打开登录页面", destination: url).font(.system(size: 12))
            }
            Text("登录在独立的临时目录中进行，完成后令牌直接存入钥匙串，临时文件随即删除。")
                .font(.system(size: 11)).foregroundStyle(Theme.subtle)
            HStack {
                Spacer()
                Button("取消登录") { model.cancelLogin() }.keyboardShortcut(.cancelAction)
            }
        }
    }

    private func option(symbol: String, title: String, detail: String, enabled: Bool,
                        action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).font(.system(size: 20)).foregroundStyle(Theme.brand).frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(Theme.ink)
                    Text(detail).font(.system(size: 11)).foregroundStyle(Theme.subtle)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.system(size: 11)).foregroundStyle(Theme.muted)
            }
            .padding(12)
            .background(Theme.bg1, in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.line))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.5)
    }

    private func pickFile() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "选择要导入的 auth.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.importFile(url, deleteSource: deleteSource)
        isPresented = false
    }
}
