import Foundation

/// A System One request: state plus typed questions, the same shape TypeSafe
/// Jev and local Laya speak on `/v1/systemone`.
struct SystemOneRequest: Equatable, Sendable {
    var state: [String: String]
    var questions: [String: SystemOneQuestion]
    var model: String?
}

/// One typed question. `choice` picks from a map of option ids; `noul` is
/// P(true); `score` is unused in the chrome residual but decoded so a
/// fixture can round-trip a real payload.
struct SystemOneQuestion: Equatable, Sendable {
    enum Kind: String, Equatable, Sendable {
        case choice, noul, score
    }

    var kind: Kind
    var instructions: String
    /// Choice options: id → short criterion. Score rubrics use the keys in
    /// display order and ignore the values.
    var criteria: [String: String]
}

struct SystemOneAnswer: Equatable, Sendable {
    var choice: String? = nil
    var noul: Double? = nil
    var score: Double? = nil
    var confidence: Double? = nil
    var probabilities: [String: Double]? = nil
}

struct SystemOneResponse: Equatable, Sendable {
    var answers: [String: SystemOneAnswer]
}

/// A local System One model. Implementations never send state off-device.
protocol DecisionEngine: Sendable {
    func decide(_ request: SystemOneRequest) async -> SystemOneResponse?
}

// MARK: - JSON wire format

extension SystemOneRequest {
    func jsonData() throws -> Data {
        try JSONSerialization.data(withJSONObject: jsonObject(), options: [])
    }

    func jsonObject() -> [String: Any] {
        var questions: [String: Any] = [:]
        for (name, question) in self.questions {
            var body: [String: Any] = [
                "type": question.kind.rawValue,
                "instructions": question.instructions,
            ]
            if !question.criteria.isEmpty {
                switch question.kind {
                case .choice:
                    body["criteria"] = question.criteria
                case .score:
                    body["criteria"] = Array(question.criteria.keys)
                case .noul:
                    break
                }
            }
            questions[name] = body
        }
        var object: [String: Any] = [
            "state": state,
            "questions": questions,
        ]
        if let model {
            object["model"] = model
        }
        return object
    }
}

extension SystemOneResponse {
    init(json data: Data) throws {
        let object = try JSONSerialization.jsonObject(with: data)
        guard let root = object as? [String: Any] else {
            throw DecodingError.dataCorrupted(
                .init(codingPath: [], debugDescription: "System One response is not an object")
            )
        }
        let rawAnswers = root["answers"] as? [String: Any] ?? [:]
        var parsed: [String: SystemOneAnswer] = [:]
        for (name, value) in rawAnswers {
            guard let body = value as? [String: Any] else { continue }
            parsed[name] = SystemOneAnswer(
                choice: body["choice"] as? String,
                noul: Self.number(body["noul"]),
                score: Self.number(body["score"]),
                confidence: Self.number(body["confidence"]),
                probabilities: Self.probabilityMap(body["probabilities"])
            )
        }
        self.init(answers: parsed)
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? Double { return number }
        if let number = value as? Int { return Double(number) }
        if let number = value as? NSNumber { return number.doubleValue }
        return nil
    }

    private static func probabilityMap(_ value: Any?) -> [String: Double]? {
        guard let raw = value as? [String: Any] else { return nil }
        var mapped: [String: Double] = [:]
        for (key, item) in raw {
            if let number = number(item) { mapped[key] = number }
        }
        return mapped.isEmpty ? nil : mapped
    }
}

/// Recorded answers for tests. Never talks to a model.
struct FixtureDecisionEngine: DecisionEngine {
    var response: SystemOneResponse?
    var onDecide: (@Sendable (SystemOneRequest) -> Void)? = nil

    func decide(_ request: SystemOneRequest) async -> SystemOneResponse? {
        onDecide?(request)
        return response
    }
}

/// Walks `LayaChromeTree` from a scripted hop path. Each pair is consumed
/// once so a ramble with two clauses can take different branches.
final class ScriptedTreeEngine: DecisionEngine, @unchecked Sendable {
    private var queue: [(hop: String, choice: String)]
    private(set) var requests: [SystemOneRequest] = []

    init(_ queue: [(String, String)]) {
        self.queue = queue.map { (hop: $0.0, choice: $0.1) }
    }

    func decide(_ request: SystemOneRequest) async -> SystemOneResponse? {
        requests.append(request)
        guard let hopID = request.questions.keys.first else { return nil }
        guard let idx = queue.firstIndex(where: { $0.hop == hopID }) else {
            return SystemOneResponse(answers: [
                hopID: SystemOneAnswer(choice: "none", confidence: 0.9)
            ])
        }
        let choice = queue.remove(at: idx).choice
        return SystemOneResponse(answers: [
            hopID: SystemOneAnswer(choice: choice, confidence: 0.95)
        ])
    }
}

/// Where a local System One daemon (Ollaya) listens. Loopback only.
enum LayaRuntime {
    static let loopbackURL = URL(string: "http://127.0.0.1:11435")!
    static let model = "laya:en"
}

/// Loopback TypeSafe-compatible daemon (Ollaya on 11435). Speech stays on
/// this Mac; the request never leaves 127.0.0.1.
struct SystemOneHTTPClient: DecisionEngine {
    var baseURL: URL
    var model: String
    var timeout: TimeInterval
    var authToken: String?

    init(
        baseURL: URL = LayaRuntime.loopbackURL,
        model: String = LayaRuntime.model,
        timeout: TimeInterval = 20,
        authToken: String? = nil
    ) {
        self.baseURL = baseURL
        self.model = model
        self.timeout = timeout
        self.authToken = authToken
    }

    func decide(_ request: SystemOneRequest) async -> SystemOneResponse? {
        var payload = request
        if payload.model == nil { payload.model = model }
        var urlRequest = URLRequest(url: baseURL.appending(path: "/v1/systemone"))
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        authorize(&urlRequest)
        urlRequest.timeoutInterval = timeout
        urlRequest.httpBody = try? payload.jsonData()
        do {
            let (data, response) = try await URLSession.shared.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode)
            else { return nil }
            return try SystemOneResponse(json: data)
        } catch {
            return nil
        }
    }

    /// Cheap liveness check used by Settings and prewarm. Does not download.
    func probe() async -> Bool {
        var request = URLRequest(url: baseURL.appending(path: "/v1/models"))
        authorize(&request)
        request.timeoutInterval = 0.2
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200..<300).contains(http.statusCode)
        } catch {
            return false
        }
    }

    /// `/v1/models` only proves the HTTP server is up. Settings Ready needs
    /// a real System One answer.
    func pingDecide() async -> Bool {
        var client = self
        client.timeout = 20
        let response = await client.decide(
            LayaChromeQuestions.request(
                transcript: "hide the sidebar",
                available: [.sidebarHide]
            )
        )
        return response != nil
    }

    static func probe(baseURL: URL = LayaRuntime.loopbackURL) async -> Bool {
        await SystemOneHTTPClient(baseURL: baseURL).probe()
    }

    static func pingDecide(baseURL: URL = LayaRuntime.loopbackURL) async -> Bool {
        await SystemOneHTTPClient(baseURL: baseURL, timeout: 20).pingDecide()
    }

    private func authorize(_ request: inout URLRequest) {
        guard let authToken, !authToken.isEmpty else { return }
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
    }
}
