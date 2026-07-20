import SwiftUI

struct LoginView: View {
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss
    /// Add-account sheet; the full-window logged-out login shows no Cancel.
    var isSheet = false
    @State private var viewModel = LoginViewModel()
    @FocusState private var focusedField: Field?

    private enum Field {
        case homeserver, username, password
    }

    @ViewBuilder
    private var appIcon: some View {
        #if os(macOS)
        Image(nsImage: NSApp.applicationIconImage)
            .resizable()
            .aspectRatio(contentMode: .fit)
        #else
        Image(systemName: "bubble.left.and.bubble.right.fill")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .foregroundStyle(.tint)
            .padding(12)
        #endif
    }

    var body: some View {
        #if os(macOS)
        macBody
        #else
        iosBody
        #endif
    }

    private var subtitle: String {
        switch viewModel.stage {
        case .server: String(localized: "Sign in to Matrix")
        case .methods: viewModel.homeserverDisplayName
        }
    }

    private func submitPassword() {
        Task {
            if let result = await viewModel.passwordLogin() {
                complete(result)
            }
        }
    }

    private func complete(_ result: (MatrixService, RestorationToken)) {
        do {
            try appState.completeLogin(service: result.0, token: result.1)
        } catch {
            viewModel.errorMessage = String(localized: "Couldn't save the session: \(error.localizedDescription)")
        }
    }

    // MARK: - macOS card

    #if os(macOS)
    private var macBody: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                appIcon
                    .frame(width: 96, height: 96)
                Text("Discourse")
                    .font(.largeTitle.weight(.semibold))
                Text(subtitle)
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }

            switch viewModel.stage {
            case .server:
                serverStage
            case .methods:
                methodsStage
            }

            if let error = viewModel.errorMessage {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .frame(maxWidth: 360)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(40)
        .frame(minWidth: 480, minHeight: 480)
        .overlay(alignment: .topLeading) {
            if isSheet {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .padding(16)
            }
        }
        .onAppear { focusedField = .homeserver }
    }

    // MARK: Stage 1 — homeserver

    private var serverStage: some View {
        VStack(spacing: 16) {
            TextField("Homeserver", text: $viewModel.homeserver, prompt: Text("matrix.org"))
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .frame(width: 300)
                .focused($focusedField, equals: .homeserver)
                .onSubmit { Task { await viewModel.discoverMethods() } }
                .disabled(viewModel.isBusy)

            Button {
                Task { await viewModel.discoverMethods() }
            } label: {
                if viewModel.isBusy {
                    ProgressView().controlSize(.small).frame(width: 80)
                } else {
                    Text("Continue").frame(width: 80)
                }
            }
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
            .disabled(viewModel.isBusy)
        }
    }

    // MARK: Stage 2 — auth methods

    @ViewBuilder
    private var methodsStage: some View {
        VStack(spacing: 14) {
            if viewModel.supportsOAuth {
                browserButton("Sign In with Browser", prominent: true) {
                    await viewModel.browserLogin(kind: .oauth)
                }
            } else if viewModel.supportsSso {
                browserButton("Sign In with SSO", prominent: !viewModel.supportsPassword) {
                    await viewModel.browserLogin(kind: .sso)
                }
            }

            if viewModel.supportsPassword {
                if viewModel.supportsOAuth || viewModel.supportsSso {
                    HStack {
                        Rectangle().fill(.separator).frame(height: 1)
                        Text("or").font(.caption).foregroundStyle(.tertiary)
                        Rectangle().fill(.separator).frame(height: 1)
                    }
                    .frame(width: 300)
                }
                VStack(spacing: 8) {
                    TextField("Username", text: $viewModel.username, prompt: Text("@user:server"))
                        .textFieldStyle(.roundedBorder)
                        .autocorrectionDisabled()
                        .textContentType(.username)
                        .focused($focusedField, equals: .username)
                    SecureField("Password", text: $viewModel.password)
                        .textFieldStyle(.roundedBorder)
                        .textContentType(.password)
                        .focused($focusedField, equals: .password)
                        .onSubmit { submitPassword() }
                }
                .frame(width: 300)
                .disabled(viewModel.isBusy)

                Button {
                    submitPassword()
                } label: {
                    if viewModel.isBusy {
                        ProgressView().controlSize(.small).frame(width: 80)
                    } else {
                        Text("Sign In").frame(width: 80)
                    }
                }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
                .disabled(!viewModel.canSubmitPassword || viewModel.isBusy)
            }

            if !viewModel.supportsPassword && !viewModel.supportsOAuth && !viewModel.supportsSso {
                Text("This homeserver offers no supported sign-in method.")
                    .foregroundStyle(.secondary)
            }

            Button("Use a different homeserver") {
                viewModel.backToServerEntry()
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .font(.callout)
        }
        .onAppear { focusedField = viewModel.supportsPassword ? .username : nil }
    }

    private func browserButton(_ title: String, prominent: Bool,
                               action: @escaping () async -> (MatrixService, RestorationToken)?) -> some View {
        Button {
            Task {
                if let result = await action() {
                    complete(result)
                }
            }
        } label: {
            Label(title, systemImage: "globe")
                .labelStyle(.titleAndIcon)
                .frame(maxWidth: .infinity)
        }
        .frame(width: 280)
        .controlSize(.large)
        .buttonStyle(prominent ? AnyButtonStyle(.borderedProminent) : AnyButtonStyle(.bordered))
        .disabled(viewModel.isBusy)
    }
    #endif

    // MARK: - iOS form

    #if os(iOS)
    private var iosBody: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                Form {
                    heroSection

                    switch viewModel.stage {
                    case .server:
                        serverSections
                    case .methods:
                        methodsSections
                    }

                    if let error = viewModel.errorMessage {
                        Section {
                            Text(error)
                                .foregroundStyle(.red)
                                .id("loginError")
                        }
                    }
                }
                // Error lands off-screen under the keyboard; scroll it in.
                .onChange(of: viewModel.errorMessage) { _, message in
                    guard message != nil else { return }
                    withAnimation { proxy.scrollTo("loginError", anchor: .bottom) }
                }
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if isSheet {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
        }
        .onAppear { focusedField = .homeserver }
        // Drive focus from the container; a row-level onAppear in a lazy Form
        // re-fires on scroll and yanks focus mid-typing.
        .onChange(of: viewModel.stage) { _, stage in
            switch stage {
            case .server: focusedField = .homeserver
            case .methods: focusedField = viewModel.supportsPassword ? .username : nil
            }
        }
    }

    private var heroSection: some View {
        Section {
            VStack(spacing: 6) {
                appIcon
                    .frame(width: 88, height: 88)
                Text("Discourse")
                    .font(.largeTitle.weight(.semibold))
                Text(subtitle)
                    .font(.headline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 12)
            .listRowBackground(Color.clear)
            .listRowInsets(EdgeInsets())
        }
    }

    // MARK: Stage 1 — homeserver

    @ViewBuilder
    private var serverSections: some View {
        Section {
            TextField("Homeserver", text: $viewModel.homeserver, prompt: Text("matrix.org"))
                .keyboardType(.URL)
                .textContentType(.URL)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.continue)
                .focused($focusedField, equals: .homeserver)
                .onSubmit { Task { await viewModel.discoverMethods() } }
                .disabled(viewModel.isBusy)
        } header: {
            Text("Homeserver")
        } footer: {
            Text("The Matrix server your account lives on.")
        }

        Section {
            prominentActionButton(viewModel.isBusy ? nil : String(localized: "Continue")) {
                Task { await viewModel.discoverMethods() }
            }
            .disabled(viewModel.isBusy)
        }
    }

    // MARK: Stage 2 — auth methods

    @ViewBuilder
    private var methodsSections: some View {
        if viewModel.supportsOAuth {
            Section {
                browserButton("Sign In with Browser", prominent: true) {
                    await viewModel.browserLogin(kind: .oauth)
                }
            }
        } else if viewModel.supportsSso {
            Section {
                browserButton("Sign In with SSO", prominent: !viewModel.supportsPassword) {
                    await viewModel.browserLogin(kind: .sso)
                }
            }
        }

        if viewModel.supportsPassword {
            Section {
                TextField("Username", text: $viewModel.username, prompt: Text("@user:server"))
                    // Autocapitalize/autocorrect would corrupt the user ID.
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .textContentType(.username)
                    .submitLabel(.next)
                    .focused($focusedField, equals: .username)
                    .onSubmit { focusedField = .password }
                SecureField("Password", text: $viewModel.password)
                    .textContentType(.password)
                    .submitLabel(.go)
                    .focused($focusedField, equals: .password)
                    .onSubmit { submitPassword() }
            } header: {
                if viewModel.supportsOAuth || viewModel.supportsSso {
                    Text("Or sign in with a password")
                }
            }
            .disabled(viewModel.isBusy)

            Section {
                prominentActionButton(viewModel.isBusy ? nil : String(localized: "Sign In")) {
                    submitPassword()
                }
                .disabled(!viewModel.canSubmitPassword || viewModel.isBusy)
            }
        }

        if !viewModel.supportsPassword && !viewModel.supportsOAuth && !viewModel.supportsSso {
            Section {
                Text("This homeserver offers no supported sign-in method.")
                    .foregroundStyle(.secondary)
            }
        }

        Section {
            Button("Use a different homeserver") {
                viewModel.backToServerEntry()
            }
            .font(.subheadline)
            .frame(maxWidth: .infinity)
            .listRowBackground(Color.clear)
        }
    }

    /// Full-width prominent button on a clear Form row; nil title shows a spinner.
    private func prominentActionButton(_ title: String?,
                                       action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Group {
                if let title {
                    Text(title).fontWeight(.semibold)
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, minHeight: 28)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
    }

    private func browserButton(_ title: String, prominent: Bool,
                               action: @escaping () async -> (MatrixService, RestorationToken)?) -> some View {
        Button {
            Task {
                if let result = await action() {
                    complete(result)
                }
            }
        } label: {
            Label(title, systemImage: "globe")
                .labelStyle(.titleAndIcon)
                .fontWeight(prominent ? .semibold : .regular)
                .frame(maxWidth: .infinity, minHeight: 28)
        }
        .buttonStyle(prominent ? AnyButtonStyle(.borderedProminent) : AnyButtonStyle(.bordered))
        .controlSize(.large)
        .disabled(viewModel.isBusy)
        .listRowBackground(Color.clear)
        .listRowInsets(EdgeInsets())
    }
    #endif
}

/// Type-erased button style, chosen at runtime.
private struct AnyButtonStyle: PrimitiveButtonStyle {
    private let makeBodyClosure: (Configuration) -> AnyView

    init(_ style: some PrimitiveButtonStyle) {
        makeBodyClosure = { AnyView(style.makeBody(configuration: $0)) }
    }

    func makeBody(configuration: Configuration) -> some View {
        makeBodyClosure(configuration)
    }
}
