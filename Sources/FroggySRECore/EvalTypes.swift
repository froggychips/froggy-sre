import Foundation

// MARK: - Rubric

/// Критерии оценки для одного инцидента в датасете.
public struct EvalRubric: Codable, Sendable {
    /// Подстрока, которая должна появиться в hypothesis.rootCause.
    public let expectedRootCause: String?
    /// Все эти термины должны встретиться хоть где-нибудь в отчёте.
    public let mustMention: [String]
    /// Ни один из этих терминов не должен встречаться (false-positive маркеры).
    public let mustNotMention: [String]

    public init(
        expectedRootCause: String? = nil,
        mustMention: [String] = [],
        mustNotMention: [String] = []
    ) {
        self.expectedRootCause = expectedRootCause
        self.mustMention       = mustMention
        self.mustNotMention    = mustNotMention
    }
}

// MARK: - EvalCase

/// Один кейс датасета: инцидент + опциональные критерии оценки.
///
/// JSON-формат файла в datasets/:
/// ```json
/// {
///   "name": "CrashLoop payment-service",
///   "incident": { "labels": {…}, "annotations": {…}, "startsAt": "…" },
///   "rubric": {
///     "expectedRootCause": "OOM",
///     "mustMention": ["kubectl rollout restart"],
///     "mustNotMention": ["network timeout"]
///   }
/// }
/// ```
public struct EvalCase: Codable, Sendable {
    public let name: String?
    public let incident: Incident
    public let rubric: EvalRubric?

    public init(name: String? = nil, incident: Incident, rubric: EvalRubric? = nil) {
        self.name     = name
        self.incident = incident
        self.rubric   = rubric
    }
}

// MARK: - RubricResult

public struct RubricResult: Codable, Sendable {
    /// nil — если expectedRootCause не задан.
    public let rootCauseMatch: Bool?
    /// term → найден в отчёте (хотим true для всех).
    public let mustMentionHits: [String: Bool]
    /// term → найден в отчёте (хотим false для всех).
    public let mustNotMentionHits: [String: Bool]

    public var passed: Bool {
        (rootCauseMatch ?? true)
        && mustMentionHits.values.allSatisfy { $0 }
        && mustNotMentionHits.values.allSatisfy { !$0 }
    }
}

// MARK: - EvalResult

public struct EvalResult: Codable, Sendable {
    public let caseName: String
    /// nil — если рубрика не задана.
    public let rubric: RubricResult?
    /// 0–1: доля специфических токенов из отчёта, реально встречающихся в исходном контексте.
    /// -1 означает «контекст пустой, скоринг неприменим».
    public let hallucinationScore: Double
    public let durationSeconds: Double
    public let report: IncidentReport

    public var passed: Bool { rubric?.passed ?? true }
}
