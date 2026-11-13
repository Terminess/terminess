import Foundation

@MainActor
enum ShellIntegration {
    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("terminal-dev/shell-integration/zsh", isDirectory: true)
    }()

    static let zshenv = """
    # Shell integration for the terminal app. Restores your ZDOTDIR, loads your
    # own .zshenv, then adds prompt and command marks. Your other zsh files load
    # as usual afterwards.
    if [[ -n "${TERMDEV_USER_ZDOTDIR+x}" ]]; then
      if [[ -n "$TERMDEV_USER_ZDOTDIR" ]]; then ZDOTDIR="$TERMDEV_USER_ZDOTDIR"; else unset ZDOTDIR; fi
      unset TERMDEV_USER_ZDOTDIR
    fi
    _tdev_integration="${TERMDEV_INTEGRATION_DIR}/integration.zsh"
    [[ -f "${ZDOTDIR:-$HOME}/.zshenv" ]] && source "${ZDOTDIR:-$HOME}/.zshenv"
    [[ -o interactive && -f "$_tdev_integration" ]] && source "$_tdev_integration"
    unset _tdev_integration

    """

    static let integration = """
    # Prompt and command marks (OSC 133) and current folder (OSC 7).
    [[ -o interactive ]] || return 0
    [[ -n "$_tdev_loaded" ]] && return 0
    _tdev_loaded=1
    autoload -Uz add-zsh-hook

    _tdev_precmd() {
      local ret=$?
      if [[ -n "$_tdev_running" ]]; then
        printf '\\e]133;D;%s\\a' "$ret"
        unset _tdev_running
      fi
      printf '\\e]7;file://%s%s\\a' "${HOST}" "${PWD// /%20}"
      printf '\\e]133;A\\a'
    }

    _tdev_preexec() {
      printf '\\e]133;C\\a'
      _tdev_running=1
    }

    add-zsh-hook precmd _tdev_precmd
    add-zsh-hook preexec _tdev_preexec

    """

    static func install() {
        let fm = FileManager.default
        try? fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try? zshenv.write(to: directory.appendingPathComponent(".zshenv"), atomically: true, encoding: .utf8)
        try? integration.write(to: directory.appendingPathComponent("integration.zsh"), atomically: true, encoding: .utf8)
    }

    static func environment(for shell: String, base: [String: String]) -> [String: String] {
        var env = base
        guard shell.hasSuffix("/zsh") || shell == "zsh", Settings.shared.shellIntegration else { return env }
        env["TERMDEV_USER_ZDOTDIR"] = base["ZDOTDIR"] ?? ""
        env["TERMDEV_INTEGRATION_DIR"] = directory.path
        env["ZDOTDIR"] = directory.path
        return env
    }
}
