import Foundation

final class GithubPoller: @unchecked Sendable {
    static let shared = GithubPoller()
    private var timer: DispatchSourceTimer?
    private init() {}

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .background))
        t.schedule(deadline: .now() + 2, repeating: 300)  // every 5 minutes
        t.setEventHandler { [weak self] in
            guard PollGate.shared.allow("integration_github", every: 300) else { return }
            self?.poll()
        }
        t.resume()
        timer = t
    }

    private func poll() {
        // Prefer the user's signed-in GitHub CLI; fall back to a saved token.
        if pollWithCLI() { return }
        let ghStatus = GitHubCLI.status()
        guard let token = KeychainStore.shared.get("github-token"), !token.isEmpty else {
            let state: GitHubConnection
            switch ghStatus {
            case .signedOut: state = .ghSignedOut
            case .missing:   state = .notConfigured
            case .signedIn:  state = .failed(L("GitHub CLI request failed · check your connection"))
            }
            publish(state, stats: nil)
            return
        }
        fetchUser(token: token)
    }

    private func publish(_ connection: GitHubConnection, stats: GitHubStats?) {
        DispatchQueue.main.async {
            AppState.shared.githubConnection = connection
            if connection.isConnected, let stats { AppState.shared.githubStats = stats }
            if !connection.isConnected { AppState.shared.githubStats = nil }
        }
    }

    /// Fetches the stats through `gh api`. Returns false when gh is missing,
    /// signed out or the request failed, so the token path can take over.
    private func pollWithCLI() -> Bool {
        guard let user = GitHubCLI.apiCached("user") as? [String: Any] else { return false }
        let login = user["login"] as? String
        let publicRepos  = (user["public_repos"] as? Int) ?? 0
        let privateOwned = (user["owned_private_repos"] as? Int)
                        ?? (user["total_private_repos"] as? Int)
                        ?? 0
        guard let repos = GitHubCLI.apiCached("user/repos?per_page=100&affiliation=owner&sort=pushed") as? [[String: Any]]
        else { return false }
        let totalStars = repos.reduce(0) { $0 + (($1["stargazers_count"] as? Int) ?? 0) }

        publish(.cli(login: login),
                stats: GitHubStats(totalRepos: publicRepos + privateOwned, totalStars: totalStars))
        return true
    }

    /// Re-polls now (e.g. right after the user signs in to gh or saves a token).
    func pollNow() { refresh() }

    func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.poll() }
    }

    private func fetchUser(token: String) {
        guard let url = URL(string: "https://api.github.com/user") else { return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        Self.conditional(&req)

        URLSession.shared.dataTask(with: req) { [weak self] data, response, _ in
            guard let self else { return }
            PollGate.shared.record("integration_github", response)
            let (data, code) = Self.resolve(url, data: data, response: response)
            guard let data, code == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                self.publish(.failed(code == 401 ? L("Token rejected · check it in Settings")
                                     : code == 0 ? L("Can't reach GitHub")
                                     : L("GitHub error \(code)")), stats: nil)
                return
            }

            let publicRepos  = (json["public_repos"]       as? Int) ?? 0
            let privateOwned = (json["owned_private_repos"] as? Int)
                            ?? (json["total_private_repos"] as? Int)
                            ?? 0
            let totalRepos = publicRepos + privateOwned

            self.fetchStars(token: token, totalRepos: totalRepos)
        }.resume()
    }

    private func fetchStars(token: String, totalRepos: Int) {
        guard let url = URL(string: "https://api.github.com/user/repos?per_page=100&affiliation=owner&sort=pushed") else { return }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        Self.conditional(&req)

        URLSession.shared.dataTask(with: req) { [weak self] data, response, _ in
            guard let self else { return }
            PollGate.shared.record("integration_github", response)
            let (data, code) = Self.resolve(url, data: data, response: response)
            guard let data, code == 200,
                  let repos = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }

            let totalStars = repos.reduce(0) { $0 + ((($1["stargazers_count"] as? Int) ?? 0)) }

            self.publish(.token, stats: GitHubStats(totalRepos: totalRepos, totalStars: totalStars))
        }.resume()
    }

    // MARK: ETag (#8): 304 Not Modified doesn't count against the rate limit

    private static let etagLock = NSLock()
    nonisolated(unsafe) private static var etags: [URL: (etag: String, body: Data)] = [:]

    private static func conditional(_ req: inout URLRequest) {
        req.cachePolicy = .reloadIgnoringLocalCacheData  // we handle caching ourselves
        guard let url = req.url else { return }
        etagLock.lock(); let cached = etags[url]; etagLock.unlock()
        if let cached { req.setValue(cached.etag, forHTTPHeaderField: "If-None-Match") }
    }

    /// 304 → the cached body as a 200; 200 → remember its ETag.
    private static func resolve(_ url: URL, data: Data?, response: URLResponse?) -> (Data?, Int) {
        let http = response as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        etagLock.lock(); defer { etagLock.unlock() }
        if code == 304, let cached = etags[url] { return (cached.body, 200) }
        if code == 200, let data, let etag = http?.value(forHTTPHeaderField: "ETag") {
            etags[url] = (etag, data)
        }
        return (data, code)
    }
}
