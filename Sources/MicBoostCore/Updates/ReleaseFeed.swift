import Foundation

/// The latest published release, as far as the app needs it
/// (docs/architecture.md "Verificação de atualizações").
public struct Release: Equatable, Sendable {
    /// GitHub's `tag_name`, in the `vX.Y.Z` form.
    public var tag: String
    /// GitHub's `html_url`: the release page the app opens in the browser.
    public var pageURL: URL

    public init(tag: String, pageURL: URL) {
        self.tag = tag
        self.pageURL = pageURL
    }
}

public enum ReleaseFeedError: Error, Equatable {
    /// The server answered with a status other than 200; 0 when it was not HTTP.
    case badStatus(Int)
    /// The payload has no usable `tag_name`/`html_url`.
    case invalidPayload
}

/// Where the app asks for the latest release. Tests and the screenshot renderer use a fake;
/// nothing but the shipping app talks to GitHub (docs/architecture.md "Verificação de atualizações").
public protocol ReleaseFeed: Sendable {
    func latestRelease() async throws -> Release
}

/// `GET /repos/vittau/MicBoost/releases/latest`, which already ignores drafts and
/// pre-releases.
public struct GitHubReleaseFeed: ReleaseFeed {
    public static let endpoint = URL(string: "https://api.github.com/repos/vittau/MicBoost/releases/latest")!

    private let session: URLSession
    private let appVersion: String
    private let endpoint: URL

    public init(
        appVersion: String,
        session: URLSession = .shared,
        endpoint: URL = GitHubReleaseFeed.endpoint
    ) {
        self.appVersion = appVersion
        self.session = session
        self.endpoint = endpoint
    }

    public func latestRelease() async throws -> Release {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 15
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("MicBoost/\(appVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            throw ReleaseFeedError.badStatus((response as? HTTPURLResponse)?.statusCode ?? 0)
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
            let pageURL = URL(string: payload.pageURL)
        else {
            throw ReleaseFeedError.invalidPayload
        }
        return Release(tag: payload.tagName, pageURL: pageURL)
    }

    private struct Payload: Decodable {
        let tagName: String
        let pageURL: String

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case pageURL = "html_url"
        }
    }
}
