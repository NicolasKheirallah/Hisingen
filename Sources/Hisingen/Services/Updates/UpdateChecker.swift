import Foundation

enum UpdateCheckResult: Equatable {
    case updateAvailable(String)
    case upToDate
    case failed
}

@MainActor
final class UpdateChecker {
    private static let latestReleaseAPI = URL(string: "https://api.github.com/repos/NicolasKheirallah/hisingen/releases/latest")!
    static let releasesPage = URL(string: "https://github.com/NicolasKheirallah/hisingen/releases/latest")!
    private let defaults: UserDefaults
    private let session: URLSession
    private let currentVersion: () -> String
    private var task: Task<Void, Never>?
    private var waitingCallbacks: [(UpdateCheckResult) -> Void] = []

    init(defaults: UserDefaults = .standard, session: URLSession = .shared,
         currentVersion: @escaping () -> String = {
             Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
         }) {
        self.defaults = defaults
        self.session = session
        self.currentVersion = currentVersion
    }

    func checkIfDue(onUpdateFound: @escaping (String) -> Void) {
        let current = currentVersion()
        let cached = defaults.string(forKey: "available_update_version")
        if let cached, Self.isVersion(cached, newerThan: current) { onUpdateFound(cached) }
        if let last = defaults.object(forKey: "last_successful_update_check") as? Date,
           Date().timeIntervalSince(last) < 86_400 { return }
        performCheck { result in
            if case .updateAvailable(let version) = result, version != cached {
                onUpdateFound(version)
            }
        }
    }

    func checkNow(completion: @escaping (UpdateCheckResult) -> Void) {
        performCheck(completion: completion)
    }

    private func performCheck(completion: @escaping (UpdateCheckResult) -> Void) {
        waitingCallbacks.append(completion)
        guard task == nil else { return }
        let current = currentVersion()
        task = Task { [session, defaults] in
            var result: UpdateCheckResult = .failed
            var request = URLRequest(url: Self.latestReleaseAPI)
            request.timeoutInterval = 10
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            request.setValue("Hisingen/\(current)", forHTTPHeaderField: "User-Agent")
            do {
                let (data, response) = try await HTTPBodyReader.data(
                    for: request, using: session, limit: 512_000, operation: "update check"
                )
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    finish(with: result)
                    return
                }
                result = try Self.evaluateRelease(data: data, currentVersion: current)
                defaults.set(Date(), forKey: "last_successful_update_check")
                if case .updateAvailable(let version) = result {
                    defaults.set(version, forKey: "available_update_version")
                } else {
                    defaults.removeObject(forKey: "available_update_version")
                }
            } catch {


            }
            finish(with: result)
        }
    }

    private func finish(with result: UpdateCheckResult) {
        task = nil
        let callbacks = waitingCallbacks
        waitingCallbacks.removeAll()
        callbacks.forEach { $0(result) }
    }

    static func evaluateRelease(data: Data, currentVersion: String) throws -> UpdateCheckResult {
        let release = try JSONDecoder().decode(Release.self, from: data)
        guard !release.draft, !release.prerelease else { return .upToDate }
        let latest = release.tagName.hasPrefix("v") ? String(release.tagName.dropFirst()) : release.tagName
        return isVersion(latest, newerThan: currentVersion) ? .updateAvailable(latest) : .upToDate
    }

    static func isVersion(_ candidate: String, newerThan current: String) -> Bool {
        guard let candidate = SemanticVersion(candidate), let current = SemanticVersion(current) else { return false }
        return candidate > current
    }

    private struct Release: Decodable {
        let tagName: String
        let draft: Bool
        let prerelease: Bool
        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case draft, prerelease
        }
    }
}

private struct SemanticVersion: Comparable {
    let numbers: [Int]
    let prerelease: [String]?

    init?(_ value: String) {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingPrefix("v")
            .split(separator: "+", maxSplits: 1).first.map(String.init) ?? value
        let parts = normalized.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        let rawNumbers = parts[0].split(separator: ".", omittingEmptySubsequences: false)
        guard !rawNumbers.isEmpty else { return nil }
        var parsed: [Int] = []
        for component in rawNumbers {
            guard let number = Int(component), number >= 0 else { return nil }
            parsed.append(number)
        }
        numbers = parsed
        prerelease = parts.count == 2 ? parts[1].split(separator: ".").map(String.init) : nil
    }

    static func < (lhs: Self, rhs: Self) -> Bool {
        for index in 0..<max(lhs.numbers.count, rhs.numbers.count) {
            let left = index < lhs.numbers.count ? lhs.numbers[index] : 0
            let right = index < rhs.numbers.count ? rhs.numbers[index] : 0
            if left != right { return left < right }
        }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil): return false
        case (.some, nil): return true
        case (nil, .some): return false
        case (.some(let left), .some(let right)):
            for index in 0..<max(left.count, right.count) {
                guard index < left.count else { return true }
                guard index < right.count else { return false }
                if left[index] == right[index] { continue }
                if let l = Int(left[index]), let r = Int(right[index]) { return l < r }
                if Int(left[index]) != nil { return true }
                if Int(right[index]) != nil { return false }
                return left[index] < right[index]
            }
            return false
        }
    }
}

private extension String {
    func trimmingPrefix(_ prefix: Character) -> String {
        first == prefix ? String(dropFirst()) : self
    }
}

