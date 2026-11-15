import Foundation

/// The run's answers once its questions are settled.
struct RunAnswers: Sendable {
    /// Variables for the run's items: built-ins, `vars:` and the answers (in a dry run, defaults and placeholders too).
    let vars: TemplateVars
    /// Questions the enabled items need that still have no answer, by variable name. Always empty in a dry run.
    let unanswered: Set<String>
}

/// Asking the config's questions (`ask:` in `installer.yaml`) at the start of a run.
extension InstallEngine {
    /// How many times one question is put to the person when the replies do not pass its format.
    public static let maxAnswerAttempts = 3
    /// How long a question's `default_command` may run before it counts as giving no default.
    public static let defaultCommandTimeout: TimeInterval = 5

    /// For each question the enabled items need, in config order: a saved answer is used as it is (unless
    /// `askAgain`); otherwise a real run asks through `interaction` and saves the answer at once, and a dry run
    /// uses the default, or a placeholder, without asking or saving.
    func settleQuestions(for items: [PlannedItem], emit: @escaping @Sendable (InstallEvent) -> Void) async -> RunAnswers {
        let store = AnswerStore(environment: environment)
        let saved = store.answers(for: plan.config.meta.ask)
        let needed = plan.questions(for: items)
        var values = saved
        for question in needed {
            if Task.isCancelled { break }
            let savedAnswer = saved[question.name]
            if savedAnswer != nil && !options.askAgain { continue }
            var offered = savedAnswer
            if offered == nil {
                offered = await defaultAnswer(for: question, vars: ActionContext.makeVars(config: plan.config, environment: environment, answers: values))
            }
            if options.dryRun {
                if savedAnswer == nil { values[question.name] = offered ?? question.dryRunPlaceholder }
                emit(.log(LogLine(Self.dryRunNote(question, offered: offered, saved: savedAnswer != nil), style: .info)))
                continue
            }
            // Declining keeps a saved answer, because `values` still holds it.
            guard let answer = await ask(question, offering: offered, saved: savedAnswer != nil, emit: emit) else { continue }
            values[question.name] = answer
            if answer != savedAnswer { save(answer, for: question, in: store, emit: emit) }
        }
        if options.dryRun {
            // A dry run holds nothing back, so every question it needs has a value, also after a stop.
            for question in needed where values[question.name] == nil { values[question.name] = question.dryRunPlaceholder }
        }
        let unanswered = Set(needed.filter { values[$0.name] == nil }.map(\.name))
        return RunAnswers(vars: ActionContext.makeVars(config: plan.config, environment: environment, answers: values), unanswered: unanswered)
    }

    /// The answer offered when the person just presses Return: the first line `default_command` prints, else
    /// `default` with its variables filled in. Each counts only when it passes the question's format, so a command
    /// that prints something else gives way to `default`. Nil when neither passes.
    func defaultAnswer(for question: VariableQuestion, vars: TemplateVars) async -> String? {
        if let command = question.defaultCommand {
            // Read-only and never as root: it runs in dry runs too, and nothing here can use the password.
            let runner = CommandRunner(environment: environment, dryRun: options.dryRun)
            let probe = Command("/bin/sh", ["-c", command]).readOnly().timeout(Self.defaultCommandTimeout)
            if let result = try? await runner.run(probe), result.succeeded {
                let firstLine = result.output.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespaces) ?? ""
                if question.format.problem(with: firstLine) == nil { return firstLine }
            }
        }
        if let literal = question.defaultValue, vars.unknownVariables(in: literal).isEmpty, vars.pendingVariables(in: literal).isEmpty {
            let expanded = vars.expand(literal).trimmingCharacters(in: .whitespacesAndNewlines)
            if question.format.problem(with: expanded) == nil { return expanded }
        }
        return nil
    }

    /// Puts one question to the person, up to `maxAnswerAttempts` times while the reply does not pass its format.
    /// Nil when they decline, nobody can answer, or the run was stopped. `saved` says `offered` is the answer saved
    /// on this Mac (asking again), which nil keeps; otherwise nil leaves the question unanswered.
    private func ask(_ question: VariableQuestion, offering offered: String?, saved: Bool,
                     emit: @escaping @Sendable (InstallEvent) -> Void) async -> String? {
        var lastError: String?
        for attempt in 1...Self.maxAnswerAttempts {
            let request = TextRequest(id: question.name, prompt: question.prompt, defaultValue: offered, format: question.format,
                                      attempt: attempt, lastError: lastError, defaultIsSaved: saved)
            let reply = await interaction.askText(request)
            // Stopping answers an open prompt with nothing; a reply that raced the stop is not kept either.
            if Task.isCancelled { return nil }
            guard let reply else {
                emit(.log(saved ? LogLine("Kept the saved answer to \"\(question.prompt)\".", style: .info)
                                : LogLine("No answer to \"\(question.prompt)\". The items that need it wait for the next run.", style: .warning)))
                return nil
            }
            let trimmed = reply.trimmingCharacters(in: .whitespacesAndNewlines)
            let answer = trimmed.isEmpty ? (offered ?? "") : trimmed
            guard let problem = question.format.problem(with: answer) else { return answer }
            lastError = problem
        }
        let tries = "after \(Self.maxAnswerAttempts) tries. \(lastError ?? "")"
        emit(.log(LogLine(saved ? "No new answer to \"\(question.prompt)\" \(tries) Kept the saved answer."
                                : "No answer to \"\(question.prompt)\" \(tries) The items that need it wait for the next run.", style: .warning)))
        return nil
    }

    private func save(_ answer: String, for question: VariableQuestion, in store: AnswerStore, emit: @escaping @Sendable (InstallEvent) -> Void) {
        let file = PathExpansion.abbreviate(store.url.path, home: environment.home)
        do {
            if let backup = try store.save(answer, for: question.name) {
                emit(.log(LogLine("\(file) was not a JSON object of text values, so it was started again. "
                                  + "The old copy is in \(PathExpansion.abbreviate(backup.path, home: environment.home)).", style: .warning)))
            }
            emit(.log(LogLine("Saved \(question.spokenName) in \(file).", style: .info)))
        } catch {
            emit(.log(LogLine("Could not save \(question.spokenName) in \(file): \(Self.describe(error)). "
                              + "This run uses the answer, and the next run asks again.", style: .warning)))
        }
    }

    static func dryRunNote(_ question: VariableQuestion, offered: String?, saved: Bool) -> String {
        if saved { return "Would ask \"\(question.prompt)\" again, offering the saved answer." }
        if let offered { return "Would ask \"\(question.prompt)\". This dry run uses the default, \(offered)." }
        return "Would ask \"\(question.prompt)\". It has no default, so this dry run shows \(question.dryRunPlaceholder)."
    }

    /// One checklist entry per question that held items back, in config order, saying how to answer it.
    func answerFollowUps(heldBack: [(item: PlannedItem, step: StepConfig, questions: [VariableQuestion])]) -> [FollowUp] {
        var waitingItems: [String: [String]] = [:]
        var firstStep: [String: String] = [:]
        for entry in heldBack {
            for question in entry.questions {
                if firstStep[question.name] == nil { firstStep[question.name] = entry.step.id }
                waitingItems[question.name, default: []].append(entry.item.title)
            }
        }
        let file = PathExpansion.abbreviate(AnswerStore(environment: environment).url.path, home: environment.home)
        return plan.config.meta.ask.compactMap { question in
            guard let titles = waitingItems[question.name] else { return nil }
            let waiting = titles.count == 1 ? "1 item waits for it" : "\(titles.count) items wait for it"
            let detail = "\(waiting): \(titles.joined(separator: ", ")). Run the installer again and answer it, "
                + "run 'shawn install --ask', or set \"\(question.name)\" in \(file)."
            return FollowUp(id: "answer-\(question.name)", title: "Answer \"\(question.prompt)\"", detail: detail, stepID: firstStep[question.name])
        }
    }
}
