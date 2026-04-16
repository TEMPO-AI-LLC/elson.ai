import Foundation

final class PromptConfig: @unchecked Sendable {
    static let shared = PromptConfig()

    private let prompts: [String: [String]]

    private init() {
        self.prompts = Self.loadPrompts()
    }

    func string(_ key: String, replacements: [String: String] = [:]) -> String {
        let lines = prompts[key] ?? []
        var value = lines.joined(separator: "\n")
        for (token, replacement) in replacements {
            value = value.replacingOccurrences(of: "{\(token)}", with: replacement)
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func loadPrompts() -> [String: [String]] {
        for candidate in promptConfigCandidates() {
            if let data = try? Data(contentsOf: candidate),
               let decoded = try? JSONDecoder().decode([String: [String]].self, from: data) {
                return decoded
            }
        }

        preconditionFailure("Missing prompt-config.json")
    }

    private static func promptConfigCandidates() -> [URL] {
        var candidates: [URL] = []
        let resourceFileName = "prompt-config.json"

        if let bundledURL = Bundle.main.url(forResource: "prompt-config", withExtension: "json") {
            candidates.append(bundledURL)
        }

        if let resourceURL = Bundle.main.resourceURL?.appendingPathComponent(resourceFileName) {
            candidates.append(resourceURL)
        }

        candidates.append(contentsOf: bundledResourceCandidates(fileName: resourceFileName))
        candidates.append(contentsOf: developmentResourceCandidates(fileName: resourceFileName))

        return candidates
    }

    private static func bundledResourceCandidates(fileName: String) -> [URL] {
        var candidates: [URL] = []
        var seenPaths = Set<String>()

        for resourceRoot in resourceRoots() + ancestorSearchRoots() {
            let directBundleURL = resourceRoot.appendingPathComponent("Elson_Elson.bundle", isDirectory: true)

            if FileManager.default.fileExists(atPath: directBundleURL.path) {
                let directCandidate = directBundleURL.appendingPathComponent(fileName)
                if seenPaths.insert(directCandidate.path).inserted {
                    candidates.append(directCandidate)
                }
            }

            if let bundleURLs = try? FileManager.default.contentsOfDirectory(
                at: resourceRoot,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) {
                for bundleURL in bundleURLs where bundleURL.pathExtension == "bundle" {
                    let candidate = bundleURL.appendingPathComponent(fileName)
                    if FileManager.default.fileExists(atPath: candidate.path),
                       seenPaths.insert(candidate.path).inserted {
                        candidates.append(candidate)
                    }
                }
            }
        }

        return candidates
    }

    private static func resourceRoots() -> [URL] {
        let bundles = [Bundle.main] + Bundle.allBundles + Bundle.allFrameworks
        var roots: [URL] = []
        var seenPaths = Set<String>()

        for bundle in bundles {
            guard let resourceURL = bundle.resourceURL else { continue }
            if seenPaths.insert(resourceURL.path).inserted {
                roots.append(resourceURL)
            }
        }

        return roots
    }

    private static func ancestorSearchRoots() -> [URL] {
        var roots: [URL] = []
        var seenPaths = Set<String>()
        var currentURL = Bundle.main.bundleURL.deletingLastPathComponent()
        var depth = 0

        while depth < 6 {
            if seenPaths.insert(currentURL.path).inserted {
                roots.append(currentURL)
            }

            let parentURL = currentURL.deletingLastPathComponent()
            if parentURL.path == currentURL.path {
                break
            }

            currentURL = parentURL
            depth += 1
        }

        return roots
    }

    private static func developmentResourceCandidates(fileName: String) -> [URL] {
        let fileManager = FileManager.default
        let currentDirectoryURL = URL(fileURLWithPath: fileManager.currentDirectoryPath, isDirectory: true)
        var candidates: [URL] = []

        let repoResourceURL = currentDirectoryURL
            .appendingPathComponent("Elson", isDirectory: true)
            .appendingPathComponent("Resources", isDirectory: true)
            .appendingPathComponent(fileName)

        if fileManager.fileExists(atPath: repoResourceURL.path) {
            candidates.append(repoResourceURL)
        }

        let buildRootURL = currentDirectoryURL.appendingPathComponent(".build", isDirectory: true)
        if let enumerator = fileManager.enumerator(
            at: buildRootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator where url.lastPathComponent == "Elson_Elson.bundle" {
                let candidate = url.appendingPathComponent(fileName)
                if fileManager.fileExists(atPath: candidate.path) {
                    candidates.append(candidate)
                    break
                }
            }
        }

        return candidates
    }
}
