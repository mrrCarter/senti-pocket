import Foundation
import PocketContracts

public struct GroundedAnswerDecoder: Sendable {
    public static let noEvidenceAnswer = "I do not have evidence for that."

    public init() {}

    public func decode(
        _ data: Data,
        checkpointId: String,
        question: String,
        allowedEvidenceIds: Set<String>,
        answerId: String = UUID().uuidString,
        createdAt: Date = Date()
    ) throws -> QuestionAnswer {
        guard !checkpointId.isEmpty,
              !question.isEmpty,
              !answerId.isEmpty,
              !allowedEvidenceIds.contains("") else {
            throw InferenceError.invalidRequest("answer metadata is invalid")
        }

        let object = try JSONSerialization.jsonObject(with: data)
        guard let dictionary = object as? [String: Any] else {
            throw InferenceError.malformedModelOutput
        }

        let allowedFields: Set<String> = ["answer", "citations"]
        if let unsupported = Set(dictionary.keys).subtracting(allowedFields).sorted().first {
            throw InferenceError.unsupportedModelOutputField(unsupported)
        }

        let payload: ModelAnswer
        do {
            payload = try JSONDecoder().decode(ModelAnswer.self, from: data)
        } catch {
            throw InferenceError.malformedModelOutput
        }

        let answer = payload.answer.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !answer.isEmpty, answer.count <= 4_000, payload.citations.count <= 16 else {
            throw InferenceError.malformedModelOutput
        }

        var seen = Set<String>()
        for citation in payload.citations {
            guard allowedEvidenceIds.contains(citation) else {
                throw InferenceError.unknownCitation(citation)
            }
            guard seen.insert(citation).inserted else {
                throw InferenceError.duplicateCitation(citation)
            }
        }

        if payload.citations.isEmpty {
            guard answer == Self.noEvidenceAnswer else {
                throw InferenceError.ungroundedAnswer
            }
        } else if answer == Self.noEvidenceAnswer {
            throw InferenceError.ungroundedAnswer
        }

        return QuestionAnswer(
            id: answerId,
            checkpointId: checkpointId,
            question: question,
            answer: answer,
            citations: payload.citations,
            answeredOffline: true,
            createdAt: createdAt
        )
    }
}

private struct ModelAnswer: Decodable {
    let answer: String
    let citations: [String]
}
