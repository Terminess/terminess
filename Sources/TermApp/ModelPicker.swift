import AppKit
import TermHost

extension TerminalWindowController {
    func switchModel(_ model: AgentModels.Model) async -> Bool {
        guard let pane = focused, let agentID = Agent.detect(pane.session.process?.foregroundCommand)?.id else { return false }
        switchingModel = true
        defer { switchingModel = false }
        let session = pane.session
        return await AgentModels.switchModel(model, agentID: agentID,
                                             screen: { session.terminal.screenText() },
                                             send: { session.send($0) })
    }
}
