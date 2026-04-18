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
            contentRect: CGRect(x: 0, y: 0, width: 1120, height: 780),
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
            topChrome

            HStack(alignment: .top, spacing: 18) {
                historyColumn
                previewColumn
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .frame(minWidth: 1020, minHeight: 720)
        .background(windowBackground)
        .onAppear(perform: syncSelection)
        .onChange(of: visibleItemIDs) { _ in
            syncSelection()
        }
        .animation(.spring(response: 0.24, dampingFraction: 0.9), value: state.selectedItemID)
        .animation(.easeInOut(duration: 0.18), value: normalizedQuery)
        .animation(.spring(response: 0.34, dampingFraction: 0.86), value: collapsedSectionIDs)
    }

    private var topChrome: some View {
        VStack(spacing: 16) {
            HStack(alignment: .bottom, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Clipboard History")
                        .font(.system(size: 30, weight: .semibold, design: .rounded))

                    Text(subtitleText)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                autoCleanMenu

                Button("Clear") {
                    appController.clearHistory()
                }
                .disabled(store.items.isEmpty)
            }

            HStack(spacing: 12) {
                searchBar

                statsPill(title: "Pinned", value: pinnedItems.count, tint: .blue, isAccent: true)
                statsPill(title: "Visible", value: filteredItems.count, tint: .primary, isAccent: false)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 18)
    }

    private var searchBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("Search text, screenshots, dates…", text: $state.searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 14))

            if state.searchText.isEmpty == false {
                Button {
                    state.searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(.regularMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .stroke(Color.white.opacity(0.18), lineWidth: 1)
                )
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
            Label(autoCleanLabel, systemImage: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.white.opacity(0.08))
                )
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private func statsPill(title: String, value: Int, tint: Color, isAccent: Bool) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(isAccent ? tint.opacity(0.9) : .secondary)

            Text("\(value)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isAccent ? tint : .primary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            Capsule(style: .continuous)
                .fill(isAccent ? tint.opacity(0.12) : Color.white.opacity(0.08))
        )
        .overlay(
            Capsule(style: .continuous)
                .strokeBorder(isAccent ? tint.opacity(0.18) : Color.white.opacity(0.08), lineWidth: 1)
        )
    }

    private var historyColumn: some View {
        PanelSurface {
            if store.items.isEmpty {
                emptyState(
                    icon: "clock.arrow.circlepath",
                    title: "History is empty",
                    detail: "Everything you copy in Stackboard will appear here."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filteredItems.isEmpty {
                emptyState(
                    icon: "magnifyingglass",
                    title: "Nothing matched your search",
                    detail: "Try another word or clear the search field."
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        ForEach(sections) { section in
                            VStack(alignment: .leading, spacing: 10) {
                                HistorySectionHeader(
                                    title: section.title,
                                    count: section.items.count,
                                    isPinnedSection: section.isPinnedSection,
                                    isCollapsed: collapsedSectionIDs.contains(section.id)
                                ) {
                                    toggleSection(section.id)
                                }

                                if collapsedSectionIDs.contains(section.id) == false {
                                    VStack(spacing: 12) {
                                        ForEach(section.items) { item in
                                            HistoryRow(
                                                item: item,
                                                image: store.thumbnail(for: item, maxDimension: 96),
                                                query: normalizedQuery,
                                                isPinned: store.isPinned(item),
                                                isSelected: state.selectedItemID == item.id,
                                                canCopy: item.kind != .file || item.fileExists,
                                                onSelect: {
                                                    state.selectedItemID = item.id
                                                },
                                                onCopy: {
                                                    state.selectedItemID = item.id
                                                    appController.copyToClipboard(item)
                                                },
                                                onTogglePin: {
                                                    state.selectedItemID = item.id
                                                    appController.togglePinnedHistoryItem(item)
                                                },
                                                onDelete: {
                                                    if state.selectedItemID == item.id {
                                                        state.selectedItemID = nil
                                                    }
                                                    appController.deleteHistoryItem(item)
                                                }
                                            )
                                        }
                                    }
                                    .transition(
                                        .asymmetric(
                                            insertion: .opacity.combined(with: .scale(scale: 0.985, anchor: .top)),
                                            removal: .opacity.combined(with: .scale(scale: 0.98, anchor: .top))
                                        )
                                    )
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.vertical, 20)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var previewColumn: some View {
        HistoryPreviewPane(
            item: selectedItem,
            image: selectedItem.flatMap { store.image(for: $0) },
            query: normalizedQuery,
            isPinned: selectedItem.map(store.isPinned) ?? false,
            hasItems: store.items.isEmpty == false
        )
        .frame(width: 336)
    }

    private var windowBackground: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color(nsColor: .underPageBackgroundColor),
                    Color(nsColor: .controlBackgroundColor).opacity(0.7)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(Color.white.opacity(0.11))
                .frame(width: 340, height: 340)
                .blur(radius: 80)
                .offset(x: -220, y: -180)

            Circle()
                .fill(Color.blue.opacity(0.10))
                .frame(width: 320, height: 320)
                .blur(radius: 72)
                .offset(x: 260, y: 120)
        }
        .ignoresSafeArea()
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

    private var pinnedItems: [ClipboardHistoryItem] {
        filteredItems.filter(store.isPinned)
    }

    private var unpinnedItems: [ClipboardHistoryItem] {
        filteredItems.filter { store.isPinned($0) == false }
    }

    private var sections: [HistorySection] {
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

        let daySections = grouped
            .keys
            .sorted(by: >)
            .map { day in
                HistorySection(
                    id: "day-\(day.timeIntervalSince1970)",
                    title: sectionTitle(for: day, calendar: calendar),
                    items: grouped[day] ?? [],
                    isPinnedSection: false
                )
            }

        result.append(contentsOf: daySections)
        return result
    }

    private var visibleItemIDs: [UUID] {
        filteredItems.map(\.id)
    }

    private var selectedItem: ClipboardHistoryItem? {
        guard let selectedItemID = state.selectedItemID else {
            return nil
        }

        return store.item(for: selectedItemID)
    }

    private var subtitleText: String {
        let total = filteredItems.count
        let pinned = pinnedItems.count

        if normalizedQuery.isEmpty {
            return pinned > 0
                ? "\(total) items, \(pinned) pinned and ready to browse"
                : "\(total) items ready to browse"
        }

        return pinned > 0
            ? "\(total) matches, including \(pinned) pinned"
            : "\(total) matches"
    }

    private var autoCleanLabel: String {
        if store.retentionPolicy == .forever {
            return "Auto-Clean Off"
        }

        if expiredItemCount > 0 {
            return "Auto-Clean \(store.retentionPolicy.shortLabel) • \(expiredItemCount) old"
        }

        return "Auto-Clean \(store.retentionPolicy.shortLabel)"
    }

    private var expiredItemCount: Int {
        store.expiredItemCount()
    }

    private func syncSelection() {
        if let selectedItemID = state.selectedItemID, visibleItemIDs.contains(selectedItemID) {
            return
        }

        state.selectedItemID = visibleItemIDs.first
    }

    private func toggleSection(_ sectionID: String) {
        withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
            if collapsedSectionIDs.contains(sectionID) {
                collapsedSectionIDs.remove(sectionID)
            } else {
                collapsedSectionIDs.insert(sectionID)
            }
        }
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
        VStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 42))
                .foregroundStyle(.secondary)

            Text(title)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.primary)

            Text(detail)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(40)
    }
}

private struct HistorySection: Identifiable {
    let id: String
    let title: String
    let items: [ClipboardHistoryItem]
    let isPinnedSection: Bool
}

private struct PanelSurface<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.14), lineWidth: 1)
                )
                .shadow(color: .black.opacity(0.12), radius: 22, y: 12)

            content()
                .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
        }
    }
}

private struct HistorySectionHeader: View {
    let title: String
    let count: Int
    let isPinnedSection: Bool
    let isCollapsed: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(isPinnedSection ? Color.blue : .secondary)

                if isPinnedSection {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.blue)
                }

                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(isPinnedSection ? Color.blue : .secondary)

                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(isPinnedSection ? Color.blue : .secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(
                        Capsule(style: .continuous)
                            .fill(isPinnedSection ? Color.blue.opacity(0.14) : Color.white.opacity(0.08))
                    )

                Spacer()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(isPinnedSection ? Color.blue.opacity(0.10) : Color.white.opacity(0.05))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(isPinnedSection ? Color.blue.opacity(0.20) : Color.white.opacity(0.06), lineWidth: 1)
                    )
            )
        }
        .buttonStyle(.plain)
    }
}

private struct HistoryRow: View {
    let item: ClipboardHistoryItem
    let image: NSImage?
    let query: String
    let isPinned: Bool
    let isSelected: Bool
    let canCopy: Bool
    let onSelect: () -> Void
    let onCopy: () -> Void
    let onTogglePin: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            preview

            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .center, spacing: 8) {
                    HighlightedText(text: item.menuTitle, query: query)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(2)

                    if isPinned {
                        Image(systemName: "pin.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Color.blue)
                    }

                    Spacer(minLength: 0)

                    kindBadge
                }

                HighlightedText(text: item.detailText, query: query)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if item.kind == .text, let textValue = item.textValue {
                    HighlightedText(text: textValue, query: query)
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                } else if item.kind == .file {
                    HighlightedText(
                        text: item.filePath ?? "File path is unavailable.",
                        query: query
                    )
                    .font(.system(size: 13))
                    .foregroundStyle(item.fileExists ? Color.secondary : Color.orange)
                    .lineLimit(2)
                } else {
                    HighlightedText(
                        text: isSelected ? "Selected. Preview is shown on the right." : "Click to select and preview on the right.",
                        query: query
                    )
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                }
            }

            Spacer(minLength: 0)

            HistoryRowActions(
                canCopy: canCopy,
                isPinned: isPinned,
                onCopy: onCopy,
                onTogglePin: onTogglePin,
                onDelete: onDelete
            )
            .frame(width: 114, alignment: .trailing)
            .opacity(isHovering || isSelected ? 1 : 0.001)
            .allowsHitTesting(isHovering || isSelected)
        }
        .padding(16)
        .background(cardBackground)
        .overlay(cardOutline)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .onTapGesture(perform: onSelect)
        .onHover { hovering in
            isHovering = hovering
        }
        .animation(.easeOut(duration: 0.18), value: isHovering || isSelected)
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .fill(cardFillColor)
            .shadow(color: .black.opacity(isSelected ? 0.12 : 0.06), radius: isSelected ? 18 : 10, y: 8)
    }

    private var cardOutline: some View {
        RoundedRectangle(cornerRadius: 22, style: .continuous)
            .strokeBorder(cardStrokeColor, lineWidth: isSelected ? 1.2 : 1)
    }

    private var cardFillColor: Color {
        if isSelected {
            return Color.accentColor.opacity(0.11)
        }

        if isPinned {
            return Color.blue.opacity(0.08)
        }

        return Color.white.opacity(0.06)
    }

    private var cardStrokeColor: Color {
        if isSelected {
            return Color.accentColor.opacity(0.35)
        }

        if isPinned {
            return Color.blue.opacity(0.22)
        }

        return Color.white.opacity(0.12)
    }

    @ViewBuilder
    private var preview: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 92, height: 92)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(Color.white.opacity(0.12), lineWidth: 1)
                )
        } else {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color.secondary.opacity(0.12))
                .overlay(
                    Image(systemName: previewSystemImage)
                        .font(.system(size: 28))
                        .foregroundStyle(previewTint)
                )
                .frame(width: 92, height: 92)
        }
    }

    private var kindBadge: some View {
        Text(item.kindTitle)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(item.kind == .file && item.fileExists == false ? Color.orange : Color.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.primary.opacity(0.07))
            )
    }

    private var previewSystemImage: String {
        switch item.kind {
        case .text:
            return "doc.text"
        case .image:
            return "photo"
        case .file:
            return item.fileExists ? "doc" : "exclamationmark.triangle"
        }
    }

    private var previewTint: Color {
        if item.kind == .file && item.fileExists == false {
            return .orange
        }

        return .secondary
    }
}

private struct HistoryRowActions: View {
    let canCopy: Bool
    let isPinned: Bool
    let onCopy: () -> Void
    let onTogglePin: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            HistoryRowActionButton(
                systemImage: "doc.on.doc",
                label: "Copy Again",
                isEnabled: canCopy,
                action: onCopy
            )

            HistoryRowActionButton(
                systemImage: isPinned ? "pin.slash" : "pin",
                label: isPinned ? "Unpin" : "Pin",
                tint: isPinned ? .blue : .primary,
                action: onTogglePin
            )

            HistoryRowActionButton(
                systemImage: "trash",
                label: "Delete",
                tint: .red,
                action: onDelete
            )
        }
    }
}

private struct HistoryRowActionButton: View {
    let systemImage: String
    let label: String
    var tint: Color = .primary
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(isEnabled ? tint : .secondary)
                .frame(width: 30, height: 30)
                .background(
                    Circle()
                        .fill(Color.white.opacity(isEnabled ? 0.13 : 0.07))
                )
        }
        .buttonStyle(.plain)
        .disabled(isEnabled == false)
        .help(label)
    }
}

private struct HistoryPreviewPane: View {
    let item: ClipboardHistoryItem?
    let image: NSImage?
    let query: String
    let isPinned: Bool
    let hasItems: Bool

    var body: some View {
        PanelSurface {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Preview")
                        .font(.system(size: 18, weight: .semibold))
                    Spacer()
                }

                if let item {
                    previewBody(for: item)
                } else {
                    emptyPreview
                }

                Spacer(minLength: 0)
            }
            .padding(20)
        }
        .animation(.easeInOut(duration: 0.2), value: item?.id)
    }

    @ViewBuilder
    private func previewBody(for item: ClipboardHistoryItem) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                Text(item.kindTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(item.kind == .file && item.fileExists == false ? Color.orange : Color.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(
                        Capsule(style: .continuous)
                            .fill(Color.white.opacity(0.08))
                    )

                if isPinned {
                    Text("Pinned")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.blue)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            Capsule(style: .continuous)
                                .fill(Color.blue.opacity(0.12))
                        )
                }
            }

            Text(item.menuTitle)
                .font(.system(size: 20, weight: .semibold))
                .lineLimit(3)

            Text(item.detailText)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            if item.kind == .image, let image {
                ZStack {
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(
                            LinearGradient(
                                colors: [
                                    Color.black.opacity(0.94),
                                    Color.black.opacity(0.82)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: 280)
                        .padding(18)
                }
                .frame(maxWidth: .infinity, minHeight: 280, maxHeight: 300)
                .overlay(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
                )
            } else if item.kind == .file {
                VStack(alignment: .leading, spacing: 14) {
                    HStack(spacing: 12) {
                        Image(systemName: item.fileExists ? "doc" : "exclamationmark.triangle")
                            .font(.system(size: 28, weight: .semibold))
                            .foregroundStyle(item.fileExists ? Color.secondary : Color.orange)
                            .frame(width: 44, height: 44)
                            .background(
                                RoundedRectangle(cornerRadius: 14, style: .continuous)
                                    .fill(Color.white.opacity(0.08))
                            )

                        VStack(alignment: .leading, spacing: 4) {
                            Text(item.fileExists ? "File is available" : "File was removed")
                                .font(.system(size: 15, weight: .semibold))
                                .foregroundStyle(item.fileExists ? Color.primary : Color.orange)

                            Text(
                                item.fileExists
                                    ? "Stackboard keeps only the original path and sends that file back to the clipboard."
                                    : "Stackboard stored only the path. The file no longer exists there, so it can't be copied back."
                            )
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    ScrollView {
                        Text(makeHighlightedAttributedString(item.filePath ?? "Path unavailable", query: query))
                            .font(.system(size: 13))
                            .foregroundStyle(.primary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    }
                    .frame(maxWidth: .infinity, minHeight: 160, maxHeight: 220)
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(Color.white.opacity(0.06))
                            .overlay(
                                RoundedRectangle(cornerRadius: 22, style: .continuous)
                                    .strokeBorder(
                                        item.fileExists ? Color.white.opacity(0.08) : Color.orange.opacity(0.22),
                                        lineWidth: 1
                                    )
                            )
                    )
                }
            } else if let textValue = item.textValue {
                ScrollView {
                    Text(makeHighlightedAttributedString(textValue, query: query))
                        .font(.system(size: 14))
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
                .frame(maxWidth: .infinity, minHeight: 280, maxHeight: 340)
                .background(
                    RoundedRectangle(cornerRadius: 22, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                        .overlay(
                            RoundedRectangle(cornerRadius: 22, style: .continuous)
                                .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                        )
                )
            }

            Text("Selecting a card only updates this preview. Use the copy button on the row to send it back to the clipboard.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var emptyPreview: some View {
        VStack(alignment: .leading, spacing: 14) {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.white.opacity(0.06))
                .overlay(
                    VStack(spacing: 12) {
                        Image(systemName: hasItems ? "sidebar.right" : "rectangle.on.rectangle.slash")
                            .font(.system(size: 34))
                            .foregroundStyle(.secondary)

                        Text(hasItems ? "Choose any item" : "No preview yet")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.primary)

                        Text(
                            hasItems
                                ? "Click a card on the left to render its preview here."
                                : "Copy something or take a screenshot, then it will appear here."
                        )
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    }
                    .padding(24)
                )
                .frame(maxWidth: .infinity, minHeight: 300)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
