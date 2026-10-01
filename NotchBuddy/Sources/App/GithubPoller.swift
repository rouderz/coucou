import Foundation

final class GithubPoller: @unchecked Sendable {
    static let shared = GithubPoller()
    private var timer: DispatchSourceTimer?
    private init() {}

    func start() {
        guard timer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .global(qos: .background))
        t.schedule(deadline: .now() + 2, repeating: 300)  // every 5 minutes
        t.setEventHandler { [weak self] in self?.poll() }
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
            case .signedIn:  state = .failed("GitHub CLI request failed · check your connection")
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
        guard let user = GitHubCLI.api("user") as? [String: Any] else { return false }
        let login = user["login"] as? String
        let publicRepos  = (user["public_repos"] as? Int) ?? 0
        let privateOwned = (user["owned_private_repos"] as? Int)
                        ?? (user["total_private_repos"] as? Int)
                        ?? 0
        guard let repos = GitHubCLI.api("user/repos?per_page=100&affiliation=owner&sort=pushed") as? [[String: Any]]
        else { return false }
        let totalStars = repos.reduce(0) { $0 + (($1["stargazers_count"] as? Int) ?? 0) }

        publish(.cli(login: login),
                stats: GitHubStats(totalRepos: publicRepos + privateOwned, totalStars: totalStars))
        return true
    }

    /// Re-polls now (e.g. right after the user signs in to gh or saves a token).
    func refresh() {
        DispatchQueue.global(qos: .utility).async { [weak self] in self?.poll() }
    }

    private func fetchUser(token: String) {
        guard let url = URL(string: "https://api.github.com/user") else { return }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        URLSession.shared.dataTask(with: req) { [weak self] data, response, _ in
            guard let self else { return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data, code == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                self.publish(.failed(code == 401 ? "Token rejected · check it in Settings"
                                     : code == 0 ? "Can't reach GitHub"
                                     : "GitHub error \(code)"), stats: nil)
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

        URLSession.shared.dataTask(with: req) { [weak self] data, response, _ in
            guard let self else { return }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data, code == 200,
                  let repos = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return }

            let totalStars = repos.reduce(0) { $0 + ((($1["stargazers_count"] as? Int) ?? 0)) }

            self.publish(.token, stats: GitHubStats(totalRepos: totalRepos, totalStars: totalStars))
        }.resume()
    }
}
