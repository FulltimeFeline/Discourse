import SwiftUI

/// Identifiable wrapper so a thread root can drive a sheet.
struct ThreadTarget: Identifiable {
    let id: String
    let viewModel: TimelineViewModel
}

/// A thread's own timeline + composer, shown as a sheet from the room timeline.
struct ThreadView: View {
    let viewModel: TimelineViewModel
    @Environment(\.dismiss) private var dismiss
    /// Gates tail-follow so a late reply/reaction doesn't yank a user who
    /// scrolled up.
    @State private var threadAtBottom = true
    #if os(iOS)
    /// Home-indicator inset, measured like TimelineView, for the composer's
    /// manual keyboard padding.
    @State private var bottomInset: CGFloat = 0
    #endif

    var body: some View {
        #if os(iOS)
        // Native sheet chrome: the fixed macOS frame would overflow an iPhone.
        NavigationStack {
            threadBody
                .navigationTitle("Thread")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .presentationDragIndicator(.visible)
        .task { await viewModel.start() }
        .onDisappear { viewModel.stop() }
        #else
        VStack(spacing: 0) {
            HStack {
                Label("Thread", systemImage: "bubble.left.and.text.bubble.right")
                    .font(.title3.weight(.semibold))
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                .keyboardShortcut(.cancelAction)
            }
            .padding(12)

            Divider()

            threadBody
        }
        .frame(width: 480, height: 560)
        .task { await viewModel.start() }
        .onDisappear { viewModel.stop() }
        #endif
    }

    private var threadBody: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        // Back-paginate older replies. Same visibility-driven
                        // poll the room timeline uses.
                        if !viewModel.reachedStart {
                            HStack {
                                Spacer()
                                ProgressView().controlSize(.small)
                                Spacer()
                            }
                            .padding(.vertical, 12)
                            .task {
                                while !Task.isCancelled && !viewModel.reachedStart {
                                    await viewModel.paginateBackwards()
                                    try? await Task.sleep(for: .seconds(1))
                                }
                            }
                        }
                        ForEach(viewModel.entries) { entry in
                            TimelineEntryRow(entry: entry, viewModel: viewModel) { _ in }
                                .equatable()
                                .id(entry.id)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                }
                .defaultScrollAnchor(.bottom)
                .onScrollGeometryChange(for: Bool.self) { geo in
                    geo.contentSize.height - geo.visibleRect.maxY <= 40
                } action: { _, atBottom in
                    threadAtBottom = atBottom
                }
                #if os(iOS)
                .scrollDismissesKeyboard(.interactively)
                #endif
                .onChange(of: viewModel.entries.last?.id) { _, newLast in
                    guard let newLast else { return }
                    // Follow the tail only when at the bottom, or for a reply we
                    // just sent (local echo has no event id yet).
                    let sentOwn: Bool = {
                        if case .message(let m) = viewModel.entries.last {
                            return m.isOwn && m.eventId == nil
                        }
                        return false
                    }()
                    guard threadAtBottom || sentOwn else { return }
                    proxy.scrollTo(newLast, anchor: .bottom)
                }
            }
            .overlay {
                if let error = viewModel.error {
                    ContentUnavailableView("Timeline Unavailable",
                                           systemImage: "exclamationmark.bubble",
                                           description: Text(error))
                } else if viewModel.entries.isEmpty {
                    // Only until the initial page lands (a thread always has its
                    // root, open failures land in `error`), so this never sticks.
                    ProgressView("Loading messages…")
                        .controlSize(.regular)
                }
            }

            #if os(iOS)
            ComposerView(viewModel: viewModel, bottomSafeInset: bottomInset)
            #else
            ComposerView(viewModel: viewModel)
            #endif
        }
        #if os(iOS)
        .onGeometryChange(for: CGFloat.self) { proxy in
            proxy.safeAreaInsets.bottom
        } action: { inset in
            // Keyboard lands here too; capture only home-indicator-scale
            // values (see TimelineView).
            if inset < 100 { bottomInset = inset }
        }
        // The composer manages its own keyboard lift; without this the sheet's
        // system keyboard avoidance double-lifts the bar.
        .ignoresSafeArea(.keyboard)
        #endif
    }
}
