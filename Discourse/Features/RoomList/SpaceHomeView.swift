import SwiftUI
#if os(iOS)
import PhotosUI
#endif
import UniformTypeIdentifiers

/// A space's "home page": banner, name/avatar, and the space bio (topic). Opened
/// from the sidebar banner. Space admins can change the banner here.
struct SpaceHomeView: View {
    let space: RoomListViewModel.SpaceItem
    let bannerURL: String?
    let scope: SessionScope
    @Environment(\.dismiss) private var dismiss

    @State private var localBanner: String?
    @State private var showsBannerPicker = false
    @State private var isSaving = false
    @State private var editStatus: (message: String, isError: Bool)?
    /// nil until the permission check lands; controls stay hidden until then.
    @State private var canEditBanner = false
    #if os(iOS)
    @State private var bannerItem: PhotosPickerItem?
    #endif

    /// The banner to display: a just-set one wins over the passed-in value.
    private var effectiveBanner: String? { localBanner ?? bannerURL }

    var body: some View {
        #if os(iOS)
        NavigationStack {
            content
                .navigationTitle(space.name)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        #else
        content
            .frame(width: 460, height: 480)
            .overlay(alignment: .topTrailing) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Close")
                .keyboardShortcut(.cancelAction)
                .padding(10)
            }
        #endif
    }

    private var content: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let banner = effectiveBanner {
                    BannerImageView(mxcUrl: banner)
                        .frame(height: 150)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                HStack(spacing: 12) {
                    RoomAvatarView(name: space.name, isDirect: false, size: 56,
                                   avatarURL: space.avatarURL)
                    Text(space.name)
                        .font(.title2.weight(.bold))
                        .lineLimit(2)
                }
                if let topic = space.topic, !topic.isEmpty {
                    Text(RenderedBodyCache.rendered(topic))
                        .font(.body)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                } else {
                    Text("No description.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }

                if canEditBanner {
                    Divider()
                    bannerControls
                }
            }
            .padding(20)
        }
        .task {
            canEditBanner = await scope.canEditSpaceBanner(spaceId: space.id)
        }
    }

    @ViewBuilder
    private var bannerControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Button(effectiveBanner == nil ? "Add Banner…" : "Change Banner…") {
                    showsBannerPicker = true
                }
                .disabled(isSaving)
                if effectiveBanner != nil {
                    Button("Remove") { removeBanner() }
                        .disabled(isSaving)
                }
                if isSaving { ProgressView().controlSize(.small) }
            }
            if let editStatus {
                Text(editStatus.message)
                    .font(.caption)
                    .foregroundStyle(editStatus.isError ? .red : .green)
            }
        }
        #if os(iOS)
        .photosPicker(isPresented: $showsBannerPicker, selection: $bannerItem, matching: .images)
        .onChange(of: bannerItem) { _, item in
            guard let item else { return }
            bannerItem = nil
            let mime = item.supportedContentTypes.first?.preferredMIMEType ?? "image/png"
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else {
                    editStatus = (String(localized: "Couldn't read that image."), true)
                    return
                }
                setBanner(data: data, mime: mime)
            }
        }
        #else
        .fileImporter(isPresented: $showsBannerPicker, allowedContentTypes: [.image]) { result in
            guard case .success(let url) = result else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else { return }
            let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "image/png"
            setBanner(data: data, mime: mime)
        }
        #endif
    }

    private func setBanner(data: Data, mime: String) {
        isSaving = true
        editStatus = nil
        Task {
            defer { isSaving = false }
            do {
                if let mxc = try await scope.setSpaceBanner(spaceId: space.id, data: data, mimeType: mime) {
                    localBanner = mxc
                    editStatus = (String(localized: "Banner updated."), false)
                } else {
                    editStatus = (String(localized: "You don't have permission to change this banner."), true)
                }
            } catch {
                editStatus = (error.localizedDescription, true)
            }
        }
    }

    private func removeBanner() {
        isSaving = true
        editStatus = nil
        Task {
            defer { isSaving = false }
            let ok = await scope.removeSpaceBanner(spaceId: space.id)
            if ok {
                localBanner = nil
                editStatus = (String(localized: "Banner removed."), false)
            } else {
                editStatus = (String(localized: "You don't have permission to change this banner."), true)
            }
        }
    }
}
