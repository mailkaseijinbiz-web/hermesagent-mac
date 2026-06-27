import Foundation

// GitHub ワークスペース管理を AppState 本体から分離（#3 god object 分割の継続）。
// @Published githubRepos / githubAccount / githubCloneBase 等は stored property のため
// AppState 本体に残し、gh 実行/リポジトリ取得/クローン/作業フォルダ設定のロジックを集約。
// runGH(private) はこのファイル内のみで使用。
extension AppState {
    // MARK: - GitHub workspace

    /// Run `gh ...` via the login-shell environment (resolves /opt/homebrew/bin/gh).
    private func runGH(_ args: [String]) async -> (success: Bool, stdout: String, stderr: String) {
        await HermesCLI.shared.execCommand("/usr/bin/env", ["gh"] + args)
    }

    /// Fetch the signed-in account + the user's repositories via the gh CLI.
    func fetchGitHubRepos() async {
        isFetchingRepos = true
        defer { isFetchingRepos = false }

        let acc = await runGH(["api", "user", "--jq", ".login"])
        if acc.success {
            let login = acc.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            if !login.isEmpty { self.githubAccount = login }
        }

        let res = await runGH(["repo", "list", "--json", "nameWithOwner,description,isPrivate,updatedAt,primaryLanguage", "--limit", "100"])
        guard res.success,
              let data = res.stdout.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            if !res.success { triggerToast(message: "GitHubリポジトリの取得に失敗しました") }
            return
        }
        self.githubRepos = arr.compactMap { item in
            guard let slug = item["nameWithOwner"] as? String, !slug.isEmpty else { return nil }
            let lang = (item["primaryLanguage"] as? [String: Any])?["name"] as? String ?? ""
            return GitHubRepo(
                nameWithOwner: slug,
                description: item["description"] as? String ?? "",
                isPrivate: item["isPrivate"] as? Bool ?? false,
                updatedAt: item["updatedAt"] as? String ?? "",
                language: lang
            )
        }
    }

    /// Local path under the clone base if the repo is already cloned, else nil.
    func localPath(for repo: GitHubRepo) -> String? {
        let p = (githubCloneBase as NSString).appendingPathComponent(repo.name)
        return FileManager.default.fileExists(atPath: p) ? p : nil
    }

    /// Clone a repo under the clone base, then set it as the working folder.
    func cloneRepo(_ repo: GitHubRepo) async {
        cloningRepo = repo.nameWithOwner
        defer { cloningRepo = nil }
        do {
            try FileManager.default.createDirectory(atPath: githubCloneBase, withIntermediateDirectories: true)
        } catch {
            reportFailure("クローン先ディレクトリの作成に失敗 (\(githubCloneBase))", error: error,
                          toast: "クローン先フォルダを作成できませんでした。設定でクローン先を確認してください。")
            return
        }
        let target = (githubCloneBase as NSString).appendingPathComponent(repo.name)
        if FileManager.default.fileExists(atPath: target) {
            setWorkspace(path: target, slug: repo.nameWithOwner)
            return
        }
        let res = await runGH(["repo", "clone", repo.nameWithOwner, target])
        if res.success {
            setWorkspace(path: target, slug: repo.nameWithOwner)
        } else {
            triggerToast(message: "cloneに失敗しました: \(repo.name)")
        }
    }

    /// Point the agent at a local repo (cwd) and start a fresh chat scoped to it.
    func setWorkspace(path: String, slug: String) {
        selectedRepoPath = path
        selectedRepoSlug = slug
        handleNewChat()        // resets the ACP session → next prompt uses the new cwd
        view = "chat"
        showSettings = false
        triggerToast(message: "作業フォルダ: \(slug)")
    }

    /// Clear the workspace → back to the home directory.
    func clearWorkspace() {
        selectedRepoPath = nil
        selectedRepoSlug = nil
        handleNewChat()
        triggerToast(message: "作業フォルダを解除しました（ホーム）")
    }

}
