import Foundation

/// Discovers a self-hosted Element Call from the homeserver's client
/// well-known (`io.element.call.widget_url`), so calls run on the user's own
/// MatrixRTC stack when one is advertised.
@MainActor
enum WellKnownDiscovery {
    private static var cache: [String: String?] = [:]

    /// The Element Call widget URL for the user's homeserver, or nil when the
    /// server advertises none (caller falls back to the call.element.io default).
    static func elementCallWidgetURL(userId: String) async -> String? {
        guard let server = userId.split(separator: ":").dropFirst().first.map(String.init)
        else { return nil }
        if let cached = cache[server] { return cached }

        guard let url = URL(string: "https://\(server)/.well-known/matrix/client"),
              let (data, response) = try? await URLSession.shared.data(from: url),
              let http = response as? HTTPURLResponse
        // No response (offline, timeout): don't cache a verdict; retry next call.
        else { return nil }

        switch http.statusCode {
        case 200:
            var discovered: String?
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let call = json["io.element.call"] as? [String: Any],
               let widgetUrl = call["widget_url"] as? String,
               let parsed = URL(string: widgetUrl), parsed.scheme == "https" {
                // EC's widget entrypoint is /room; a bare origin loads the
                // standalone SPA, which can't authenticate as a widget.
                discovered = parsed.path.isEmpty || parsed.path == "/"
                    ? widgetUrl.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/room"
                    : widgetUrl
            }
            // Definitive answer (URL, or 200 without the key): cache it.
            cache[server] = discovered
            return discovered
        case 404:
            // Definitively no self-hosted EC.
            cache[server] = String?.none
            return nil
        default:
            // 5xx / 429 / redirects: transient, retry next time.
            return nil
        }
    }
}
