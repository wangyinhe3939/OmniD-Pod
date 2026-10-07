import AppKit

// Compile with the unmodified OmniDWorkspaceNotice declaration extracted from
// OmniDWorkspaceViews.swift into .build_tmp/WorkspaceNotice.swift.
// Requires foreground fixture permission; touches no user files or preferences.
@main
struct CheckWorkspaceConfirmations {
    @MainActor static func main() {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 390, height: 300),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.title = "确认提示检查"
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        var mutations = 0
        func buttons(_ view: NSView) -> [NSButton] {
            (view as? NSButton).map { [$0] } ?? view.subviews.flatMap(buttons)
        }
        for (title, expected) in [("取消", 0), ("确认", 1)] {
            OmniDWorkspaceNotice.confirm("夹具", message: "不操作用户资料", confirmTitle: "确认", window: window) { mutations += 1 }
            guard let sheet = window.attachedSheet, let content = sheet.contentView,
                  let button = buttons(content).first(where: { $0.title == title }) else {
                preconditionFailure("原生提示或按钮未出现")
            }
            OmniDWorkspaceNotice.confirm("重复请求", message: "", confirmTitle: "确认", window: window) { mutations += 100 }
            precondition(window.attachedSheet === sheet, "重复请求不得覆盖当前提示")
            precondition(buttons(content).first(where: { $0.title == "取消" })?.keyEquivalent == "\u{1b}")
            button.performClick(nil)
            let deadline = Date().addingTimeInterval(1)
            while window.attachedSheet != nil && Date() < deadline {
                RunLoop.current.run(until: Date().addingTimeInterval(0.01))
            }
            precondition(window.attachedSheet == nil && mutations == expected, "取消不得修改数据；确认只执行一次")
        }
        print("PASS: 原生确认执行一次；取消零修改；Escape 取消；重复请求不覆盖")
    }
}
