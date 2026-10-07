//
//  ShelfItemView.swift
//  boringNotch
//
//  Created by Alexander on 2025-09-24.
//

import SwiftUI
import AppKit

struct ShelfView: View {
    @EnvironmentObject var vm: BoringViewModel
    @StateObject var tvm = ShelfStateViewModel.shared
    @StateObject var selection = ShelfSelectionModel.shared
    @StateObject private var quickLookService = QuickLookService()
    private let spacing: CGFloat = 8

    var body: some View {
        HStack(spacing: 10) {
            FileShareView()
                .aspectRatio(1, contentMode: .fit)
                .environmentObject(vm)
            panel
                .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], isTargeted: $vm.dragDetectorTargeting) { providers in
                    handleDrop(providers: providers)
                }
        }
        // Bind Quick Look to shelf selection
        .onChange(of: selection.selectedIDs) {
            updateQuickLookSelection()
        }
        .quickLookPresenter(using: quickLookService)
    }
    
    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard tvm.canModifyItems, !selection.isDragging else { return false }
        vm.dropEvent = true
        ShelfStateViewModel.shared.load(providers)
        return true
    }
    
    private func updateQuickLookSelection() {
        guard quickLookService.isQuickLookOpen && !selection.selectedIDs.isEmpty else { return }
        
        let selectedItems = selection.selectedItems(in: tvm.items)
        let urls: [URL] = selectedItems.compactMap { item in
            if let fileURL = item.fileURL {
                return fileURL
            }
            if case .link(let url) = item.kind {
                return url
            }
            return nil
        }
        
        if !urls.isEmpty {
            quickLookService.updateSelection(urls: urls)
        }
    }

    var panel: some View {
        RoundedRectangle(cornerRadius: 16)
            .stroke(
                vm.dragDetectorTargeting
                    ? Color.accentColor.opacity(0.9)
                    : Color.white.opacity(0.1),
                style: StrokeStyle(lineWidth: 3, lineCap: .round, dash: [10])
            )
            .overlay {
                content
                    .padding(8)
            }
            .transaction { transaction in
                transaction.animation = vm.animation
            }
            .contentShape(Rectangle())
            .onTapGesture { selection.clear() }
    }

    var content: some View {
        VStack(spacing: 6) {
            if let issue = tvm.persistenceIssue {
                persistenceNotice(issue)
            }

            Group {
                if tvm.isEmpty {
                    VStack(spacing: 8) {
                        Image(systemName: "tray.and.arrow.down")
                            .symbolVariant(.fill)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(.white, .gray)
                            .imageScale(.large)

                        Text(tvm.canModifyItems ? "拖入文件到这里" : "文件暂存改动已暂停")
                            .foregroundStyle(.gray)
                            .font(.system(size: 12, weight: .medium))
                            .fontWeight(.medium)
                    }
                } else {
                    ScrollView(.horizontal) {
                        HStack(spacing: spacing) {
                            ForEach(tvm.items) { item in
                                ShelfItemView(item: item)
                                    .environmentObject(quickLookService)
                            }
                        }
                    }
                    .padding(-spacing)
                    .scrollIndicators(.never)
                    .onDrop(of: [.fileURL, .url, .utf8PlainText, .plainText, .data], isTargeted: $vm.dragDetectorTargeting) { providers in
                        handleDrop(providers: providers)
                    }
                }
            }
        }
    }

    private func persistenceNotice(_ issue: ShelfPersistenceIssue) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.yellow)

            VStack(alignment: .leading, spacing: 2) {
                Text(issue.title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white)
                Text(issue.message)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .help(issue.message)
            }

            Spacer(minLength: 4)

            if issue.backupURL != nil || issue.sourceURL != nil {
                Button(issue.backupURL == nil ? "显示文件" : "显示备份") {
                    tvm.revealPersistenceIssue()
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10, weight: .medium))
            }

            if tvm.canRetryPersistence {
                Button("重试") {
                    tvm.retryPersistence()
                }
                .buttonStyle(.borderless)
                .font(.system(size: 10, weight: .medium))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .accessibilityElement(children: .combine)
    }
}
