import Foundation
import TermTranscript

enum PairSkill {
    enum Agent: String, CaseIterable { case claude, codex }
    enum Status: Equatable { case installed, missing, theirs }

    static let marker = "<!-- installed by Terminess -->"

    private static func root(_ a: Agent) -> String {
        let env = ProcessInfo.processInfo.environment
        switch a {
        case .claude: return (env["CLAUDE_CONFIG_DIR"] ?? Transcript.home + "/.claude") + "/skills"
        case .codex: return (env["CODEX_HOME"] ?? Transcript.home + "/.codex") + "/skills"
        }
    }
    private static func file(_ a: Agent) -> String { root(a) + "/terminess-pair/SKILL.md" }

    static func status(_ a: Agent) -> Status {
        if let text = try? String(contentsOfFile: file(a), encoding: .utf8) {
            return text.contains(marker) ? .installed : .theirs
        }
        if FileManager.default.fileExists(atPath: root(a) + "/pair/SKILL.md") { return .theirs }
        return .missing
    }

    static func install(_ a: Agent) throws {
        guard status(a) != .theirs else { return }
        let dir = root(a) + "/terminess-pair"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        try text(for: a).write(toFile: dir + "/SKILL.md", atomically: true, encoding: .utf8)
    }

    static func uninstall(_ a: Agent) {
        guard status(a) == .installed else { return }
        try? FileManager.default.removeItem(atPath: root(a) + "/terminess-pair")
    }

    static func text(for a: Agent) -> String {
        let me = a.rawValue, other = a == .claude ? "codex" : "claude"
        let Other = a == .claude ? "Codex" : "Claude"
        return """
        ---
        name: terminess-pair
        description: Hand work to, or get a second opinion from, \(Other) (the other coding agent) with the `pair` tool that comes with Terminess. Use when the user mentions \(Other) in natural language, such as "ask \(other)", "what does \(other) think", "have \(other) review this", "let \(other) do it", "hand this to \(other)", "second opinion", "cross-check with the other model", asks for work to be done and then checked by the other agent, or wants \(other) to work in parallel or in the background while you carry on.
        ---
        \(marker)

        # pair: working with \(Other)

        You are the main session. `pair` (on PATH in Terminess shells) runs \(Other) headless in the same repo, signed in with the user's own plan, and returns its final report. The user can watch the run live in Terminess. Ledger: `pair log`.

        ## Pick the mode from what the user said

        | User intent | Command | Access |
        |---|---|---|
        | A question, an opinion, a design check | `pair ask` | read-only |
        | "Have \(other) review/check this" | `pair review` (add `--base main` for a branch) | read-only |
        | "...and fix it" after a review | `pair review --fix` | write |
        | "Hand this to \(other)", "let \(other) do it" | `pair handoff` | write |
        | A follow-up on the last exchange | add `--continue` | same |
        | "\(Other) does Y in parallel / in the background" | `pair parallel` | write, in its own worktree |
        | "Do X and have \(other) check it" | do X yourself, then `pair review`; at most two rounds | |

        Always pass `--from \(me)`. The target then defaults to \(other).

        The user can choose which model \(Other) uses for reviews, for work and for questions (Terminess Settings, or `pair models`), and pair applies it by itself. Pass `--model NAME` only when the user names a model for this one run.

        ## Parallel work

        `pair parallel --from \(me) "task"` copies the repo (with uncommitted changes) into a separate git worktree, starts \(Other) there in the background and returns a job id. Carry on in the main copy meanwhile; pick tasks that touch different files.

        - `pair status` lists jobs; `pair wait <id>` blocks until one finishes and prints its report and a diffstat; `pair diff <id>` shows the patch.
        - Review it, then `pair apply <id>` (lands as uncommitted changes) or `pair discard <id>`. If apply exits 3, resolve the `<<<<<<< yours` / `>>>>>>> \(other)` markers yourself.

        ## Write a real brief

        \(Other) can read the repo but has not seen this conversation. Give it the goal, the decisions made so far, the relevant files and what "done" looks like. For anything longer than a line, pass it on stdin:

        ```bash
        pair handoff --from \(me) --brief-file - <<'BRIEF'
        Goal: ...
        Agreed so far: ...
        Files: ...
        Done when: ...
        BRIEF
        ```

        ## Running it

        - Write modes and reviews can take several minutes: run them in the background where you can, and wait for them to finish.
        - Don't edit files in the repo while a write-mode run is going.

        ## After it returns

        Read the report; for write modes, check the diff and run the tests yourself. Tell the user what \(Other) said or changed, briefly, and say so if you disagree. \(Other) never commits, pushes or deploys; that stays with you and the user.

        If pair says it needs jq (macOS 14 and older), tell the user to run `brew install jq`.
        """
    }
}

import SwiftUI

struct PairSkillToggle: View {
    let agent: PairSkill.Agent
    @State private var status = PairSkill.Status.missing

    var body: some View {
        let other = agent == .claude ? "Codex" : "Claude"
        Toggle((agent == .claude ? "Let Claude Code" : "Let Codex") + " hand work to \(other)"
               + (status == .theirs ? " (you have your own pair skill)" : ""),
               isOn: Binding(get: { status != .missing }, set: { on in
                   do { if on { try PairSkill.install(agent) } else { PairSkill.uninstall(agent) } }
                   catch { AgentEvents.report(error) }
                   status = PairSkill.status(agent)
               }))
            .disabled(status == .theirs)
            .help("Adds a terminess-pair skill to \(agent == .claude ? "~/.claude" : "~/.codex")/skills so the agent knows it can ask \(other) with the pair tool that comes with Terminess.")
            .onAppear { status = PairSkill.status(agent) }
    }
}
