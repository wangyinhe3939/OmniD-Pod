import SwiftUI

struct OffKeyNamingView: View {
    @ObservedObject var store: OffKeyNamingStore
    @ObservedObject private var cleaning = OffKeyCleaningController.shared
    @State private var showsRule = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                fileSection
                Divider()
                previewSection
                actionSection
                statusSection
                Divider()
                directorySection
                DisclosureGroup("编号规则与缺号", isExpanded: $showsRule) {
                    ruleSection.padding(.top, 12)
                }
            }
            .padding(18)
        }
        .font(.system(size: 12)).controlSize(.small)
        .frame(minWidth: 520, minHeight: 420)
        .textFieldStyle(.roundedBorder)
        .preferredColorScheme(.dark)
        .disabled(cleaning.isCleaning)
        .dropDestination(for: URL.self) { urls, _ in
            guard !store.isBusy else {
                store.presentedError = "请等待当前扫描或文件操作完成。"
                return false
            }
            guard urls.count == 1, let url = urls.first else {
                store.presentedError = "一次只处理一个文件。"
                return false
            }
            store.acceptFile(url)
            return true
        }
        .alert(
            OffKeyL10n.text("offkey.naming.errorTitle", fallback: "起个名"),
            isPresented: Binding(
                get: { store.presentedError != nil },
                set: { if !$0 { store.presentedError = nil } }
            )
        ) {
            Button(OffKeyL10n.text("offkey.common.ok", fallback: "好")) {
                store.presentedError = nil
            }
        } message: {
            Text(store.presentedError ?? "")
        }
    }

    private var fileSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button(OffKeyL10n.text("offkey.naming.chooseFile", fallback: "选择文件…")) {
                    store.chooseFile()
                }
                Text(store.sourceURL?.lastPathComponent
                    ?? "或拖入文件")
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            if let inspection = store.inspection {
                Text(inspectionDescription(inspection))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            } else {
                EmptyView()
            }
        }
        .disabled(store.isBusy)
    }

    private var directorySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(OffKeyL10n.text("offkey.naming.destination", fallback: "目标位置"))
                .font(.headline)
            HStack {
                Button(OffKeyL10n.text("offkey.naming.chooseFolder", fallback: "选择文件夹…")) {
                    store.chooseDirectory()
                }
                Button(OffKeyL10n.text("offkey.naming.rescan", fallback: "重新扫描")) {
                    store.rescan()
                }
                .disabled(store.directoryURL == nil || store.isBusy)
                Spacer()
                Button(store.currentLocationIsPinned
                    ? OffKeyL10n.text("offkey.naming.unpin", fallback: "取消固定")
                    : OffKeyL10n.text("offkey.naming.pin", fallback: "固定位置")) {
                    store.toggleCurrentLocationPin()
                }
                .disabled(store.directoryURL == nil)
            }
            Text(store.directoryURL?.path
                ?? OffKeyL10n.text("offkey.naming.noFolder", fallback: "尚未选择目标目录"))
                .lineLimit(2)
                .truncationMode(.middle)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if !store.locations.isEmpty {
                Menu(OffKeyL10n.text("offkey.naming.locations", fallback: "最近 / 固定位置")) {
                    ForEach(store.locations) { location in
                        Button((location.isPinned ? "★ " : "") + location.displayName) {
                            store.selectLocation(location)
                        }
                    }
                }
            }
        }
        .disabled(store.isBusy)
    }

    private var ruleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(OffKeyL10n.text("offkey.naming.rule", fallback: "编号规则"))
                .font(.headline)
            HStack {
                TextField(
                    OffKeyL10n.text("offkey.naming.prefix", fallback: "前缀"),
                    text: $store.prefix
                )
                .frame(width: 110)
                .onChange(of: store.prefix) { _, _ in store.ruleChanged() }
                .accessibilityLabel(OffKeyL10n.text("offkey.naming.prefix", fallback: "前缀"))
                Picker("", selection: $store.digits) {
                    Text("2 位 · 01").tag(2)
                    Text("3 位 · 001").tag(3)
                }
                .labelsHidden()
                .frame(width: 130)
                .onChange(of: store.digits) { _, _ in store.ruleChanged() }
                Spacer()
            }

            if let scan = store.scan {
                Text("已使用：\(numberList(scan.usedNumbers))")
                Text("最大编号：\(scan.maximum)　缺号：\(numberList(scan.gaps))")
                    .foregroundStyle(.secondary)
                Picker(
                    OffKeyL10n.text("offkey.naming.number", fallback: "使用编号"),
                    selection: $store.selectedNumber
                ) {
                    Text("默认下一个：\(formatted(scan.next))").tag(scan.next)
                    ForEach(scan.gaps, id: \.self) { gap in
                        Text("使用缺号 \(formatted(gap))").tag(gap)
                    }
                }
                .frame(maxWidth: 320)
            } else {
                Text(OffKeyL10n.text("offkey.naming.scanPrompt", fallback: "选择目录后扫描已有编号"))
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .disabled(store.isBusy)
    }

    private var previewSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField(
                "短名称",
                text: $store.shortName
            )
            .accessibilityLabel(OffKeyL10n.text("offkey.naming.shortNameLabel", fallback: "短名称"))

            Text(store.completedURL?.lastPathComponent ?? store.previewFilename
                ?? "命名预览")
                .font(.system(size: 14, weight: .medium))
                .textSelection(.enabled)

            if let duplicates = store.scan?.duplicateURLs, !duplicates.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    Label(
                        OffKeyL10n.text("offkey.naming.duplicate", fallback: "发现完全相同文件"),
                        systemImage: "exclamationmark.triangle"
                    )
                    .foregroundStyle(.orange)
                    Button(OffKeyL10n.text("offkey.naming.revealDuplicate", fallback: "定位相同文件")) {
                        store.revealFirstDuplicate()
                    }
                    Toggle(
                        OffKeyL10n.text("offkey.naming.keepDuplicate", fallback: "仍然保留副本"),
                        isOn: $store.allowDuplicate
                    )
                    .toggleStyle(.checkbox)
                }
            }
        }
    }

    private var actionSection: some View {
        HStack {
            Button(OffKeyL10n.text("offkey.naming.rename", fallback: "仅改名")) {
                store.execute(move: false)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(OmniDPodPrimaryButtonStyle())
            .disabled(!store.canExecute || cleaning.isCleaning)

            Button(OffKeyL10n.text("offkey.naming.move", fallback: "改名并移动")) {
                store.execute(move: true)
            }
            .disabled(!store.canExecute || cleaning.isCleaning)

            Spacer()

            Button(OffKeyL10n.text("offkey.naming.reveal", fallback: "在 Finder 中显示")) {
                store.revealSource()
            }
            .disabled(store.sourceURL == nil)
        }
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            if store.isBusy {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel(OffKeyL10n.text("offkey.naming.scanning", fallback: "正在扫描"))
            }
            if store.completedURL != nil || cleaning.isCleaning || !store.statusMessage.isEmpty {
                Text(store.completedURL.map { "已完成：\($0.lastPathComponent)" } ?? (cleaning.isCleaning
                ? OffKeyL10n.text("offkey.naming.cleaningDisabled", fallback: "清洁模式期间起个名暂时不可用。")
                : store.statusMessage))
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
        }
    }

    private func inspectionDescription(_ value: OffKeyFileInspection) -> String {
        let dimensions: String
        if let width = value.pixelWidth, let height = value.pixelHeight, width > 0, height > 0 {
            dimensions = "\(width) × \(height)"
        } else {
            dimensions = "—"
        }
        return "检测：\(value.typeName)　\(dimensions)　\(ByteCountFormatter.string(fromByteCount: Int64(value.byteCount), countStyle: .file)) · 最终扩展名：\(value.fileExtension)"
    }

    private func formatted(_ number: Int) -> String {
        store.prefix + String(format: "%0*d", store.digits, number)
    }

    private func numberList(_ numbers: [Int]) -> String {
        numbers.isEmpty ? "无" : numbers.map(formatted).joined(separator: "、")
    }
}
