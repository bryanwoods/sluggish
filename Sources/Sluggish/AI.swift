import Foundation
import FoundationModels

@available(macOS 26, *)
@Generable
struct Guess {
    @Guide(description: "What the process itself does, from the command and the file contents. A verb phrase in the present tense, at most 15 words, in plain English")
    var does: String
    @Guide(description: "True only when the command or the file contents clearly show what it does")
    var sure: Bool
}

func explain(_ evidence: String) async -> String? {
    guard #available(macOS 26, *) else { return nil }
    guard case .available = SystemLanguageModel.default.availability else { return nil }
    let session = LanguageModelSession(instructions: """
        You explain to a developer what a process on their Mac does. Use only the evidence.
        Do not mention sizes, ports, process IDs, ages, project names, or branch names.
        """)
    guard let g = try? await session.respond(to: "Evidence:\n\(evidence.prefix(3000))", generating: Guess.self, options: GenerationOptions(sampling: .greedy)).content else { return nil }
    let does = g.does.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
    return "It \(g.sure ? "" : "probably ")\(does.prefix(1).lowercased() + does.dropFirst())."
}
