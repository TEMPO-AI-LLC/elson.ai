import Foundation

struct ModelStageConfig: Codable {
    let model: String
    let temperature: Double?
    let topP: Double?
    let topK: Int?
    let thinkingLevel: String?

    enum CodingKeys: String, CodingKey {
        case model
        case temperature
        case topP = "top_p"
        case topK = "top_k"
        case thinkingLevel = "thinking_level"
    }
}

struct ProviderModelSet: Codable {
    let validation: String
    let transcription: String
    let enhancement: String
    let vision: String
}

struct CerebrasModelSet: Codable {
    let classification: String
    let enhancement: String
    let working: String
}

struct GroqLocalRuntimeModelSet: Codable {
    let transcription: ModelStageConfig
    let ocr: ModelStageConfig
    let validation: ModelStageConfig
}

struct GoogleLocalRuntimeModelSet: Codable {
    let validation: ModelStageConfig
    let intentAgent: ModelStageConfig
    let transcriptAgent: ModelStageConfig
    let workingAgent: ModelStageConfig

    enum CodingKeys: String, CodingKey {
        case validation
        case intentAgent = "intent_agent"
        case transcriptAgent = "transcript_agent"
        case workingAgent = "working_agent"
    }
}

struct CerebrasLocalRuntimeModelSet: Codable {
    let validation: ModelStageConfig
    let intentAgent: ModelStageConfig
    let transcriptAgent: ModelStageConfig
    let workingAgent: ModelStageConfig

    enum CodingKeys: String, CodingKey {
        case validation
        case intentAgent = "intent_agent"
        case transcriptAgent = "transcript_agent"
        case workingAgent = "working_agent"
    }
}

struct LocalRuntimeModelConfig: Codable {
    let groq: GroqLocalRuntimeModelSet
    let google: GoogleLocalRuntimeModelSet
    let cerebras: CerebrasLocalRuntimeModelSet
}

struct ModelConfigFile: Codable {
    let openai: ProviderModelSet
    let groq: ProviderModelSet
    let google: ProviderModelSet
    let cerebras: CerebrasModelSet
    let localRuntime: LocalRuntimeModelConfig

    enum CodingKeys: String, CodingKey {
        case openai
        case groq
        case google
        case cerebras
        case localRuntime = "local_runtime"
    }

    init(
        openai: ProviderModelSet,
        groq: ProviderModelSet,
        google: ProviderModelSet,
        cerebras: CerebrasModelSet,
        localRuntime: LocalRuntimeModelConfig
    ) {
        self.openai = openai
        self.groq = groq
        self.google = google
        self.cerebras = cerebras
        self.localRuntime = localRuntime
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        openai = try container.decodeIfPresent(ProviderModelSet.self, forKey: .openai) ?? ModelConfig.defaultOpenAIProvider
        groq = try container.decode(ProviderModelSet.self, forKey: .groq)
        google = try container.decode(ProviderModelSet.self, forKey: .google)
        cerebras = try container.decode(CerebrasModelSet.self, forKey: .cerebras)
        localRuntime = try container.decode(LocalRuntimeModelConfig.self, forKey: .localRuntime)
    }
}

final class ModelConfig: @unchecked Sendable {
    static let shared = ModelConfig()
    
    let config: ModelConfigFile
    let localRuntime: LocalRuntimeModelConfig
    
    private init() {
        let loaded = Self.loadFromBundle() ?? Self.defaultConfig
        self.config = loaded
        self.localRuntime = loaded.localRuntime
    }
    
    private static func loadFromBundle() -> ModelConfigFile? {
        for url in modelConfigCandidates() {
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do {
                let data = try Data(contentsOf: url)
                return try JSONDecoder().decode(ModelConfigFile.self, from: data)
            } catch {
                preconditionFailure("Invalid model-config.json at \(url.path): \(error)")
            }
        }
        return nil
    }

    private static func modelConfigCandidates() -> [URL] {
        var candidates: [URL] = []
        let resourceFileName = "model-config.json"

        if let bundledURL = Bundle.main.url(forResource: "model-config", withExtension: "json") {
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
    
    static let defaultOpenAIProvider = ProviderModelSet(
        validation: "gpt-5-nano-2025-08-07",
        transcription: "gpt-4o-transcribe",
        enhancement: "gpt-5-mini",
        vision: "gpt-5-nano-2025-08-07"
    )

    private static let defaultConfig = ModelConfigFile(
        openai: defaultOpenAIProvider,
        groq: ProviderModelSet(
            validation: "openai/gpt-oss-20b",
            transcription: "whisper-large-v3-turbo",
            enhancement: "openai/gpt-oss-120b",
            vision: "meta-llama/llama-4-scout-17b-16e-instruct"
        ),
        google: ProviderModelSet(
            validation: "gemini-3.1-flash-lite-preview",
            transcription: "gemini-3.1-flash-lite-preview",
            enhancement: "gemini-3.1-flash-lite-preview",
            vision: "gemini-3.1-flash-lite-preview"
        ),
        cerebras: CerebrasModelSet(
            classification: "zai-glm-4.7",
            enhancement: "gpt-oss-120b",
            working: "zai-glm-4.7"
        ),
        localRuntime: LocalRuntimeModelConfig(
            groq: GroqLocalRuntimeModelSet(
                transcription: ModelStageConfig(
                    model: "whisper-large-v3-turbo",
                    temperature: nil,
                    topP: nil,
                    topK: nil,
                    thinkingLevel: nil
                ),
                ocr: ModelStageConfig(
                    model: "meta-llama/llama-4-scout-17b-16e-instruct",
                    temperature: 0.1,
                    topP: 1,
                    topK: nil,
                    thinkingLevel: nil
                ),
                validation: ModelStageConfig(
                    model: "openai/gpt-oss-20b",
                    temperature: 0,
                    topP: 1,
                    topK: nil,
                    thinkingLevel: nil
                )
            ),
            google: GoogleLocalRuntimeModelSet(
                validation: ModelStageConfig(
                    model: "gemini-3.1-flash-lite-preview",
                    temperature: nil,
                    topP: nil,
                    topK: nil,
                    thinkingLevel: nil
                ),
                intentAgent: ModelStageConfig(
                    model: "gemini-3.1-flash-lite-preview",
                    temperature: 0,
                    topP: 0.95,
                    topK: 40,
                    thinkingLevel: "low"
                ),
                transcriptAgent: ModelStageConfig(
                    model: "gemini-3.1-flash-lite-preview",
                    temperature: 0.2,
                    topP: 0.95,
                    topK: 40,
                    thinkingLevel: "low"
                ),
                workingAgent: ModelStageConfig(
                    model: "gemini-3.1-flash-lite-preview",
                    temperature: 0.1,
                    topP: 0.95,
                    topK: 40,
                    thinkingLevel: "medium"
                )
            ),
            cerebras: CerebrasLocalRuntimeModelSet(
                validation: ModelStageConfig(
                    model: "zai-glm-4.7",
                    temperature: 0,
                    topP: 1,
                    topK: nil,
                    thinkingLevel: nil
                ),
                intentAgent: ModelStageConfig(
                    model: "zai-glm-4.7",
                    temperature: 0,
                    topP: nil,
                    topK: nil,
                    thinkingLevel: "none"
                ),
                transcriptAgent: ModelStageConfig(
                    model: "gpt-oss-120b",
                    temperature: 0.5,
                    topP: nil,
                    topK: nil,
                    thinkingLevel: nil
                ),
                workingAgent: ModelStageConfig(
                    model: "zai-glm-4.7",
                    temperature: 0.1,
                    topP: nil,
                    topK: nil,
                    thinkingLevel: nil
                )
            )
        )
    )

}
