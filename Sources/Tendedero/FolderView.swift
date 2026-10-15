import AppKit
import SwiftUI

struct FolderView: View {
    @ObservedObject var folders: FolderShelf
    @ObservedObject var line: Line

    var body: some View {
        GeometryReader { geo in
            if folders.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: folders.isUnavailable ? "folder.badge.questionmark" : "folder")
                        .font(.system(size: 24, weight: .light))
                    if folders.isLoading {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(folders.isUnavailable
                             ? C("This folder is unavailable", "此文件夹暂时无法读取", "此資料夾暫時無法讀取")
                             : C("This folder is empty", "这个文件夹里还没有文件", "這個資料夾裡還沒有檔案"))
                            .font(.system(size: 12))
                        if folders.isUnavailable {
                            Button(C("Refresh", "刷新", "重新整理")) { folders.refresh() }
                                .buttonStyle(.plain)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: Layout.spacing - Layout.cardWidth) {
                        ForEach(folders.items) { item in
                            HangingCard(screenWidth: geo.size.width) {
                                FolderCard(item: item, folders: folders, line: line)
                            }
                            .onAppear { folders.requestThumbnail(item.id) }
                            .onChange(of: item.needsThumbnail) { _, needed in
                                if needed { folders.requestThumbnail(item.id) }
                            }
                        }
                        if folders.hasMoreItems {
                            Button { folders.loadMore() } label: {
                                VStack(spacing: 8) {
                                    Image(systemName: "plus.circle").font(.system(size: 24))
                                    Text(C("Show more files", "显示更多文件", "顯示更多檔案"))
                                        .font(.system(size: 11))
                                }
                                .frame(width: Layout.cardWidth, height: 116)
                                .glassFrame(cornerRadius: Frame.radius)
                            }
                            .buttonStyle(.plain)
                            .disabled(folders.isLoading)
                            .padding(.top, 20)
                        }
                    }
                    .padding(.horizontal, 28)
                    .padding(.top, Layout.ropeTop - Layout.pinAbove)
                    .frame(minWidth: geo.size.width, alignment: .center)
                }
                .scrollIndicators(.hidden)
            }
        }
        .background(GeometryReader { g in
            Color.clear.preference(key: FolderViewportKey.self, value: g.frame(in: .named("line")))
        })
        .onPreferenceChange(FolderViewportKey.self) { rect in
            MainActor.assumeIsolated { folders.interactionRect = rect }
        }
    }
}

private struct FolderCard: View {
    let item: FolderShelf.Item
    @ObservedObject var folders: FolderShelf
    @ObservedObject var line: Line
    @State private var hovering = false
    @State private var arrived = false
    private var copied: Bool { folders.copiedID == item.id }

    var body: some View {
        VStack(spacing: -12) {
            Clothespin().zIndex(1)
            VStack(spacing: 6) {
                Image(nsImage: item.thumbnail)
                    .resizable().scaledToFit()
                    .frame(width: 126, height: 82)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                Text(item.url.lastPathComponent)
                    .font(.system(size: 11, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
                    .frame(width: 126)
            }
            .padding(10)
            .glassFrame(cornerRadius: Frame.radius)
            .overlay(FolderGrabArea(item: item, folders: folders, line: line))
            .overlay(alignment: .bottom) {
                if copied {
                    Label(C("Copied", "已复制", "已複製"), systemImage: "checkmark")
                        .font(.system(size: 10, weight: .medium))
                        .padding(5).glassFrame(capsule: true)
                        .allowsHitTesting(false)
                }
            }
            .shadow(color: .black.opacity(0.18), radius: hovering ? 14 : 10, y: 5)
            .scaleEffect(hovering ? 1.025 : 1, anchor: .top)
            .opacity(line.draggingID == item.id ? 0.45 : 1)
            .onHover { hovering = $0 }
            .help(item.url.path)
            .accessibilityLabel(item.url.lastPathComponent)
        }
        .rotationEffect(.degrees(arrived ? 0 : 12), anchor: .top)
        .offset(y: arrived ? 0 : -28)
        .opacity(arrived ? 1 : 0)
        .animation(.spring(response: 0.4, dampingFraction: 0.75), value: arrived)
        .animation(.spring(response: 0.3, dampingFraction: 0.7), value: hovering)
        .onAppear { arrived = true }
    }
}

private struct FolderGrabArea: NSViewRepresentable {
    let item: FolderShelf.Item
    let folders: FolderShelf
    let line: Line
    func makeNSView(context: Context) -> GrabView {
        let view = GrabView()
        configure(view)
        return view
    }
    func updateNSView(_ view: GrabView, context: Context) { configure(view) }
    static func dismantleNSView(_ view: GrabView, coordinator: ()) { view.cancelPress() }
    private func configure(_ view: GrabView) {
        view.url = item.url
        view.dragImage = item.thumbnail
        view.showsDiscardControl = false
        view.onClick = { folders.copy(item) }
        view.onDoubleClick = { NSWorkspace.shared.open(item.url) }
        view.onLongPress = { NSWorkspace.shared.open(item.url) }
        view.onPressChange = { pressed in line.pressedID = pressed ? item.id : nil }
        view.onMenuWillOpen = { line.beginInteraction() }
        view.onMenuDidClose = { line.endInteraction() }
        view.onDragStart = { line.draggingID = item.id }
        view.onDragEnd = { line.draggingID = nil; folders.refresh() }
        view.onSuccessfulDrop = { if line.retractAfterDrag { line.onRequestRetract?() } }
        view.onTrash = { folders.trash(item) }
        view.menuProvider = {
            let menu = NSMenu()
            menu.addItem(ClosureMenuItem(C("Open", "打开", "開啟")) { NSWorkspace.shared.open(item.url) })
            menu.addItem(ClosureMenuItem(C("Copy", "复制", "複製")) { folders.copy(item) })
            menu.addItem(ClosureMenuItem(C("Show in Finder", "在访达中显示", "在 Finder 中顯示")) {
                NSWorkspace.shared.activateFileViewerSelecting([item.url])
            })
            return menu
        }
    }
}

private struct FolderViewportKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if !next.isEmpty { value = next }
    }
}
