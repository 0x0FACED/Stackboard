import AppKit
import Combine
import SwiftUI

@MainActor
final class HistoryWindowState: ObservableObject {
    @Published var searchText = ""
    @Published var selectedItemID: UUID?
    @Published private(set) var appliedSearchText = ""

    private var cancellables: Set<AnyCancellable> = []

    init() {
        $searchText
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .removeDuplicates()
            .debounce(for: .milliseconds(140), scheduler: RunLoop.main)
            .sink { [weak self] value in
                self?.appliedSearchText = value
            }
            .store(in: &cancellables)
    }
}

@MainActor
final class HistoryWindowController: NSWindowController, NSWindowDelegate {
    private let appController: AppController
    private let state = HistoryWindowState()

    init(appController: AppController) {
        self.appController = appController

        let hostingController = NSHostingController(
            rootView: HistoryListView(appController: appController, state: state)
        )

        let window = EscapeAwareWindow(
            contentRect: CGRect(x: 0, y: 0, width: 1040, height: 700),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Clipboard History"
        window.center()
        window.toolbarStyle = .unified
        window.collectionBehavior = [.managed, .moveToActiveSpace, .fullScreenAuxiliary]
        window.hidesOnDeactivate = false
        window.contentViewController = hostingController
        window.contentMinSize = NSSize(width: 860, height: 560)
        window.isReleasedWhenClosed = false

        super.init(window: window)

        window.delegate = self
        window.onEscape = { [weak window] in
            window?.close()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func windowWillClose(_ notification: Notification) {
        AppController.shared.closeHistoryPreview()
        appController.historyWindowDidClose()
    }

    func windowDidBecomeKey(_ notification: Notification) {
        appController.foregroundWindowDidBecomeKey()
        window?.orderFrontRegardless()
    }
}

private struct HistoryListView: View {
    @ObservedObject private var store: ClipboardHistoryStore
    @ObservedObject var state: HistoryWindowState
    @State private var collapsedSectionIDs: Set<String> = []

    let appController: AppController

    init(appController: AppController, state: HistoryWindowState) {
        self.appController = appController
        self.state = state
        _store = ObservedObject(wrappedValue: appController.historyStore)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()

            if store.items.isEmpty {
                emptyState(
                    icon: "clock.arrow.circlepath",
                    title: "History is empty",
                    detail: "Copied text, images, and files will appear here."
                )
            } else if filteredItems.isEmpty {
                VStack(spacing: 16) {
                    emptyStateContent(
                        icon: "magnifyingglass",
                        title: "No matching items",
                        detail: "Try another search."
                    )
                    Button("Clear Search") {
                        state.searchText = ""
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(32)
            } else {
                HStack(spacing: 0) {
                    historyColumn
                        .frame(width: 360)
                    Divider()
                    previewColumn
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 860, minHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: syncSelection)
        .onChange(of: visibleItemIDs) { _ in
            syncSelection()
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            HStack(spacing: 10) {
                Text("Clipboard History")
                    .font(.system(size: 20, weight: .semibold))

                Text(countLabel)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 16)

                autoCleanMenu

                Button("Clear History", role: .destructive) {
                    appController.clearHistory()
                }
                .disabled(store.items.isEmpty)
            }

            searchBar
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search text, images, files, or dates", text: $state.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .accessibilityLabel("Search clipboard history")

            if state.searchText.isEmpty == false {
                Button {
                    state.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
                .help("Clear search")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(ClipboardUIStyle.contentBackground, in: RoundedRectangle(cornerRadius: 7))
        .overlay(
            RoundedRectangle(cornerRadius: 7)
                .strokeBorder(Color(nsColor: .separatorColor), lineWidth: 0.5)
        )
    }

    private var autoCleanMenu: some View {
        Menu {
            ForEach(ClipboardRetentionPolicy.allCases) { policy in
                Button {
                    store.setRetentionPolicy(policy)
                } label: {
                    if store.retentionPolicy == policy {
                        Label(policy.menuTitle, systemImage: "checkmark")
                    } else {
                        Text(policy.menuTitle)
                    }
                }
            }

            Divider()

            if expiredItemCount > 0 {
                Button("Delete \(expiredItemCount) old items now") {
                    store.removeExpiredItems()
                }
            } else {
                Text(store.retentionPolicy == .forever ? "Automatic cleanup is off" : "Nothing old to delete")
            }

            Text("Pinned items are kept")
        } label: {
            Label(autoCleanLabel, systemImage: "clock.arrow.circlepath")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .accessibilityLabel("History retention")
        .help("Choose automatic cleanup or delete expired items")
    }

    private var historyColumn: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(sections) { section in
                    VStack(spacing: 2) {
                        HistorySectionHeader(
                            title: section.title,
                            count: section.items.count,
                            isPinnedSection: section.isPinnedSection,
                            isCollapsed: collapsedSectionIDs.contains(section.id)
                        ) {
                            toggleSection(section.id)
                        }

                        if collapsedSectionIDs.contains(section.id) == false {
                            ForEach(section.items) { item in
                                HistoryRow(
                                    item: item,
                                    image: store.thumbnail(for: item, maxDimension: 80),
                                    query: normalizedQuery,
                                    isPinned: store.isPinned(item),
                                    isSelected: state.selectedItemID == item.id,
                                    onSelect: {
                                        state.selectedItemID = item.id
                                    },
                                    onCopy: {
                                        state.selectedItemID = item.id
                                        appController.copyToClipboard(item)
                                    },
                                    onTogglePin: {
                                        togglePin(item)
                                    },
                                    onDelete: {
                                        delete(item)
                                    }
                                )
                            }
                        }
                    }
                }
            }
            .padding(8)
        }
        .frame(maxHeight: .infinity)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    @ViewBuilder
    private var previewColumn: some View {
        if let item = selectedItem {
            HistoryPreviewPane(
                item: item,
                image: item.kind == .image ? store.image(for: item) : nil,
                query: normalizedQuery,
                isPinned: store.isPinned(item),
                onCopy: {
                    appController.copyToClipboard(item)
                },
                onTogglePin: {
                    togglePin(item)
                },
                onDelete: {
                    delete(item)
                }
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var normalizedQuery: String {
        state.appliedSearchText
    }

    private var filteredItems: [ClipboardHistoryItem] {
        guard normalizedQuery.isEmpty == false else {
            return store.items
        }

        return store.items.filter { item in
            item.searchableText.localizedCaseInsensitiveContains(normalizedQuery)
        }
    }

    private var sections: [HistorySection] {
        let items = filteredItems
        let pinnedItems = items.filter(store.isPinned)
        let unpinnedItems = items.filter { store.isPinned($0) == false }
        var result: [HistorySection] = []

        if pinnedItems.isEmpty == false {
            result.append(
                HistorySection(
                    id: "pinned",
                    title: "Pinned",
                    items: pinnedItems,
                    isPinnedSection: true
                )
            )
        }

        let calendar = Calendar.current
        let grouped = Dictionary(grouping: unpinnedItems) { item in
            calendar.startOfDay(for: item.createdAt)
        }

        result.append(contentsOf: grouped.keys.sorted(by: >).map { day in
            HistorySection(
                id: daySectionID(for: day, calendar: calendar),
                title: sectionTitle(for: day, calendar: calendar),
                items: grouped[day] ?? [],
                isPinnedSection: false
            )
        })
        return result
    }

    private var visibleItemIDs: [UUID] {
        sections.flatMap { $0.items.map(\.id) }
    }

    private var selectedItem: ClipboardHistoryItem? {
        let items = filteredItems
        if let selectedItemID = state.selectedItemID,
           let selected = items.first(where: { $0.id == selectedItemID }) {
            return selected
        }

        return sections.first?.items.first
    }

    private var countLabel: String {
        let count = filteredItems.count
        if normalizedQuery.isEmpty {
            return "\(count) \(count == 1 ? "item" : "items")"
        }
        return "\(count) \(count == 1 ? "match" : "matches")"
    }

    private var autoCleanLabel: String {
        if store.retentionPolicy == .forever {
            return "Auto-Clean Off"
        }

        if expiredItemCount > 0 {
            return "Auto-Clean \(store.retentionPolicy.shortLabel) · \(expiredItemCount) old"
        }

        return "Auto-Clean \(store.retentionPolicy.shortLabel)"
    }

    private var expiredItemCount: Int {
        store.expiredItemCount()
    }

    private func syncSelection() {
        let ids = visibleItemIDs
        if let selectedItemID = state.selectedItemID, ids.contains(selectedItemID) {
            return
        }

        state.selectedItemID = ids.first
    }

    private func togglePin(_ item: ClipboardHistoryItem) {
        state.selectedItemID = item.id
        appController.togglePinnedHistoryItem(item)
        let sectionID = store.isPinned(item)
            ? "pinned"
            : daySectionID(for: item.createdAt, calendar: .current)
        collapsedSectionIDs.remove(sectionID)
    }

    private func delete(_ item: ClipboardHistoryItem) {
        if state.selectedItemID == item.id {
            state.selectedItemID = nil
        }
        appController.deleteHistoryItem(item)
        syncSelection()
    }

    private func toggleSection(_ sectionID: String) {
        if collapsedSectionIDs.contains(sectionID) {
            collapsedSectionIDs.remove(sectionID)
        } else {
            collapsedSectionIDs.insert(sectionID)
        }
    }

    private func daySectionID(for date: Date, calendar: Calendar) -> String {
        "day-\(calendar.startOfDay(for: date).timeIntervalSince1970)"
    }

    private func sectionTitle(for date: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(date) {
            return "Today"
        }

        if calendar.isDateInYesterday(date) {
            return "Yesterday"
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter.string(from: date)
    }

    private func emptyState(icon: String, title: String, detail: String) -> some View {
        emptyStateContent(icon: icon, title: title, detail: detail)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(32)
    }

    private func emptyStateContent(icon: String, title: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 18, weight: .semibold))
            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
    }
}

private struct HistorySection: Identifiable {
    let id: String
    let title: String
    let items: [ClipboardHistoryItem]
    let isPinnedSection: Bool
}

private struct HistorySectionHeader: View {
    let title: String
    let count: Int
    let isPinnedSection: Bool
    let isCollapsed: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .frame(width: 10)

                if isPinnedSection {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10))
                }

                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("\(count)")
                    .font(.system(size: 11))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(title), \(count) items")
        .accessibilityValue(isCollapsed ? "Collapsed" : "Expanded")
    }
}

private struct HistoryRow: View {
    let item: ClipboardHistoryItem
    let image: NSImage?
    let query: String
    let isPinned: Bool
    let isSelected: Bool
    let onSelect: () -> Void
    let onCopy: () -> Void
    let onTogglePin: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                ClipboardItemThumbnail(item: item, image: image, size: 38)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 4) {
                    HighlightedText(text: contentText, query: query)
                        .font(.system(size: 13))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HighlightedText(text: item.detailText, query: query)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                if isPinned {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Pinned")
                }
            }
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity)
            .frame(height: 72)
            .background(
                isSelected
                    ? ClipboardUIStyle.selectionFill
                    : Color.primary.opacity(isHovering ? 0.035 : 0),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityValue(isSelected ? "Selected" : "")
        .onHover { isHovering = $0 }
        .contextMenu {
            Button("Copy Again", action: onCopy)
                .disabled(item.kind == .file && item.fileExists == false)
            Button(isPinned ? "Unpin" : "Pin", action: onTogglePin)
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    private var contentText: String {
        if item.kind == .text {
            return item.textValue.flatMap { $0.isEmpty ? nil : $0 } ?? "Empty text clip"
        }
        if item.kind == .image {
            return "Screenshot"
        }
        return item.menuTitle
    }
}

private struct HistoryPreviewPane: View {
    let item: ClipboardHistoryItem
    let image: NSImage?
    let query: String
    let isPinned: Bool
    let onCopy: () -> Void
    let onTogglePin: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Button(action: onCopy) {
                    Label("Copy Again", systemImage: "doc.on.doc")
                }
                .buttonStyle(.borderedProminent)
                .tint(ClipboardUIStyle.accent)
                .disabled(item.kind == .file && item.fileExists == false)

                Button(action: onTogglePin) {
                    Label(isPinned ? "Unpin" : "Pin", systemImage: isPinned ? "pin.slash" : "pin")
                }
                .buttonStyle(.bordered)

                Spacer(minLength: 8)

                Button(role: .destructive, action: onDelete) {
                    Label("Delete", systemImage: "trash")
                }
                .buttonStyle(.borderless)
            }
            .controlSize(.regular)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)

            Divider()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .id(item.id)

            Divider()

            HStack(spacing: 6) {
                if item.kind == .text {
                    Text(item.kindTitle)
                    Text("·")
                }
                HighlightedText(text: item.detailText, query: query)
                Spacer(minLength: 0)
            }
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .background(ClipboardUIStyle.contentBackground)
    }

    @ViewBuilder
    private var content: some View {
        switch item.kind {
        case .text:
            ScrollView {
                Text(makeHighlightedAttributedString(item.textValue ?? "", query: query))
                    .font(.system(size: 14))
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
        case .image:
            GeometryReader { geometry in
                if let image {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else {
                    VStack(spacing: 10) {
                        Image(systemName: "photo")
                            .font(.system(size: 30))
                        Text("Image unavailable")
                            .font(.system(size: 13))
                    }
                    .foregroundStyle(.secondary)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
            .padding(20)
        case .file:
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(item.menuTitle)
                        .font(.system(size: 18, weight: .semibold))
                        .textSelection(.enabled)

                    Label(
                        item.fileExists ? "File is available" : "File is missing",
                        systemImage: item.fileExists ? "checkmark.circle" : "exclamationmark.triangle"
                    )
                    .font(.system(size: 13))
                    .foregroundStyle(item.fileExists ? Color.secondary : Color.orange)

                    VStack(alignment: .leading, spacing: 6) {
                        Text("File path")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                        Text(makeHighlightedAttributedString(item.filePath ?? "Path unavailable", query: query))
                            .font(.system(size: 13))
                            .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(20)
            }
        }
    }
}

private struct HighlightedText: View {
    let text: String
    let query: String

    var body: some View {
        Text(makeHighlightedAttributedString(text, query: query))
    }
}

private func makeHighlightedAttributedString(_ text: String, query: String) -> AttributedString {
    let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmedQuery.isEmpty == false else {
        return AttributedString(text)
    }

    let source = text as NSString
    let attributed = NSMutableAttributedString(string: text)
    let highlightColor = NSColor.systemYellow.withAlphaComponent(0.52)

    var searchRange = NSRange(location: 0, length: source.length)
    while searchRange.location < source.length {
        let foundRange = source.range(
            of: trimmedQuery,
            options: [.caseInsensitive, .diacriticInsensitive],
            range: searchRange
        )

        guard foundRange.location != NSNotFound else {
            break
        }

        attributed.addAttribute(.backgroundColor, value: highlightColor, range: foundRange)

        let nextLocation = foundRange.location + max(foundRange.length, 1)
        searchRange = NSRange(location: nextLocation, length: source.length - nextLocation)
    }

    return (try? AttributedString(attributed, including: \.appKit)) ?? AttributedString(text)
}
