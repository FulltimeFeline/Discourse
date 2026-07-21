import SwiftUI
import WebKit

struct CallView: View {
    let viewModel: CallViewModel
    @Environment(\.dismiss) private var dismiss
    #if os(iOS)
    /// The close button hangs up rather than closing a window; confirm first.
    @State private var showsLeaveConfirm = false
    #endif

    var body: some View {
        VStack(spacing: 0) {
            header

            Divider()

            Group {
                if let error = viewModel.error {
                    ContentUnavailableView("Call Unavailable", systemImage: "phone.down",
                                           description: Text(error))
                } else if let url = viewModel.webViewURL {
                    CallWebView(url: url, viewModel: viewModel)
                        #if os(iOS)
                        .ignoresSafeArea(edges: .bottom)
                        #endif
                } else {
                    ProgressView("Connecting…")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        #if os(macOS)
        .frame(minWidth: 800, minHeight: 560)
        #else
        .background(Color.platformWindowBackground)
        #endif
        .task { await viewModel.start() }
        .onDisappear { viewModel.stop() }
        // Element Call reported a hangup/leave: close the call window.
        .onChange(of: viewModel.didHangUp) { _, hungUp in
            if hungUp { dismiss() }
        }
    }

    private var header: some View {
        HStack {
            Label("Call — \(viewModel.roomName)", systemImage: "phone.fill")
                .font(.headline)
                .lineLimit(1)
            Spacer()
            Button {
                #if os(iOS)
                showsLeaveConfirm = true
                #else
                dismiss()
                #endif
            } label: {
                #if os(iOS)
                // Hang-up glyph: this button ends the call, not closes a window.
                Image(systemName: "phone.down.fill")
                    .foregroundStyle(.red)
                    .font(.title3)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
                #else
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
                #endif
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .accessibilityLabel("Leave Call")
            #if os(iOS)
            .confirmationDialog("Leave the call?",
                                isPresented: $showsLeaveConfirm,
                                titleVisibility: .visible) {
                Button("Leave Call", role: .destructive) {
                    dismiss()
                }
            }
            #endif
        }
        #if os(iOS)
        .padding(.horizontal, 12)
        .padding(.vertical, 2)
        #else
        .padding(10)
        #endif
    }
}

#if os(macOS)
private typealias PlatformViewRepresentable = NSViewRepresentable
#else
private typealias PlatformViewRepresentable = UIViewRepresentable
#endif

/// WKWebView hosting Element Call, bridging its widget postMessage API to the
/// SDK's widget driver.
struct CallWebView: PlatformViewRepresentable {
    let url: URL
    let viewModel: CallViewModel

    func makeCoordinator() -> Coordinator {
        Coordinator(viewModel: viewModel, allowedHost: url.host)
    }

    #if os(macOS)
    func makeNSView(context: Context) -> WKWebView { makeWebView(context: context) }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
    #else
    func makeUIView(context: Context) -> WKWebView { makeWebView(context: context) }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
    #endif

    private func makeWebView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.mediaTypesRequiringUserActionForPlayback = []

        // Element Call posts widget-API messages to its "parent" (itself, per
        // our parentUrl); capture and forward them natively.
        let bridgeScript = """
        window.addEventListener('message', (event) => {
            let message = { data: event.data, origin: event.origin };
            if (message.data.response && message.data.api == 'toWidget'
                || !message.data.response && message.data.api == 'fromWidget') {
                window.webkit.messageHandlers.widgetBridge.postMessage(JSON.stringify(message.data));
            }
        });
        """
        configuration.userContentController.addUserScript(
            WKUserScript(source: bridgeScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        configuration.userContentController.add(context.coordinator, name: "widgetBridge")

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.uiDelegate = context.coordinator
        webView.underPageBackgroundColor = .black
        context.coordinator.webView = webView

        viewModel.postToWebView = { [weak webView] message in
            webView?.evaluateJavaScript("window.postMessage(\(message), '*')")
        }

        webView.load(URLRequest(url: url))
        return webView
    }

    final class Coordinator: NSObject, WKScriptMessageHandler, WKUIDelegate {
        private let viewModel: CallViewModel
        /// Only this origin (the validated Element Call URL) may capture camera/mic.
        private let allowedHost: String?
        weak var webView: WKWebView?

        init(viewModel: CallViewModel, allowedHost: String?) {
            self.viewModel = viewModel
            self.allowedHost = allowedHost
        }

        func userContentController(_ userContentController: WKUserContentController,
                                   didReceive message: WKScriptMessage) {
            guard message.name == "widgetBridge", let body = message.body as? String else { return }
            Task { @MainActor in
                viewModel.receiveFromWebView(body)
            }
        }

        func webView(_ webView: WKWebView,
                     requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                     initiatedByFrame frame: WKFrameInfo,
                     type: WKMediaCaptureType,
                     decisionHandler: @escaping (WKPermissionDecision) -> Void) {
            // Grant capture only to the validated origin; the call URL can come
            // from a homeserver's `.well-known`, so a rogue URL must not.
            if let allowedHost, !allowedHost.isEmpty, origin.host == allowedHost {
                decisionHandler(.grant)
            } else {
                decisionHandler(.deny)
            }
        }
    }
}
