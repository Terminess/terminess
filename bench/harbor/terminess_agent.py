"""Terminess's own agent (terminessd agent) as a Harbor installed agent.

Runs Terminal-Bench (or any Harbor dataset) with terminessd agent inside each
task container, headless, against an OpenAI chat completions endpoint:

    TERMINESSD_BINARY=/path/to/static/terminessd \\
    TERMINESS_BENCH_BASE_URL=https://router.huggingface.co/v1 \\
    TERMINESS_BENCH_API_KEY=$HF_TOKEN \\
    harbor run -d terminal-bench@2.0 -a terminess_agent:TerminessAgent \\
        -m zai-org/GLM-5.3-Flash -n 2 -k 1 -l 10

The binary must be a static Linux build (swift build --swift-sdk
x86_64-swift-linux-musl), since task images have their own libraries.
TERMINESS_CA_BUNDLE (default /etc/ssl/certs/ca-certificates.crt on the host)
is copied in for images with no certificates, which its HTTPS needs.
Context limits come from TERMINESS_BENCH_CONTEXT_WINDOW and
TERMINESS_BENCH_MAX_OUTPUT; the turn limit from TERMINESS_BENCH_MAX_TURNS;
a per-task token cap from TERMINESS_BENCH_TOKEN_BUDGET, and the reasoning
effort (low or high, as the board runs) from TERMINESS_BENCH_EFFORT.
"""

import os
import shlex
from pathlib import Path

from harbor.agents.installed.base import BaseInstalledAgent, with_prompt_template
from harbor.environments.base import BaseEnvironment
from harbor.models.agent.context import AgentContext


class TerminessAgent(BaseInstalledAgent):
    REMOTE_BINARY = "/usr/local/bin/terminessd"
    REMOTE_CA = "/opt/terminess/ca-certificates.crt"

    @staticmethod
    def name() -> str:
        return "terminess"

    async def install(self, environment: BaseEnvironment) -> None:
        pass

    async def configure(self, environment: BaseEnvironment) -> None:
        binary = Path(os.environ["TERMINESSD_BINARY"])
        await self.exec_as_root(environment, command="mkdir -p /opt/terminess /logs/agent")
        await environment.upload_file(binary, self.REMOTE_BINARY)
        ca = Path(os.environ.get("TERMINESS_CA_BUNDLE", "/etc/ssl/certs/ca-certificates.crt"))
        await environment.upload_file(ca, self.REMOTE_CA)
        await self.exec_as_root(
            environment,
            command=(
                f"chmod 755 {self.REMOTE_BINARY} && "
                "if [ ! -s /etc/ssl/certs/ca-certificates.crt ] && [ ! -s /etc/pki/tls/certs/ca-bundle.crt ] "
                "&& [ ! -s /etc/ssl/cert.pem ]; then mkdir -p /etc/ssl/certs && "
                f"cp {self.REMOTE_CA} /etc/ssl/certs/ca-certificates.crt; fi"
            ),
        )

    @with_prompt_template
    async def run(self, instruction: str, environment: BaseEnvironment, context: AgentContext) -> None:
        model = self.model_name or ""
        flags = [
            "--once", "--auto", "all",
            "--model", f"openai:{model}",
            "--max-turns", os.environ.get("TERMINESS_BENCH_MAX_TURNS", "300"),
        ]
        if os.environ.get("TERMINESS_BENCH_CONTEXT_WINDOW"):
            flags += ["--context-window", os.environ["TERMINESS_BENCH_CONTEXT_WINDOW"]]
        if os.environ.get("TERMINESS_BENCH_MAX_OUTPUT"):
            flags += ["--max-output", os.environ["TERMINESS_BENCH_MAX_OUTPUT"]]
        if os.environ.get("TERMINESS_BENCH_TOKEN_BUDGET"):
            flags += ["--token-budget", os.environ["TERMINESS_BENCH_TOKEN_BUDGET"]]
        if os.environ.get("TERMINESS_BENCH_EFFORT"):
            flags += ["--effort", os.environ["TERMINESS_BENCH_EFFORT"]]
        command = (
            f"{self.REMOTE_BINARY} agent {' '.join(shlex.quote(f) for f in flags)} {shlex.quote(instruction)}"
            " </dev/null 2>&1 | tee /logs/agent/terminess.txt"
        )
        env = {
            "OPENAI_BASE_URL": os.environ["TERMINESS_BENCH_BASE_URL"],
            "OPENAI_API_KEY": os.environ.get("TERMINESS_BENCH_API_KEY", ""),
            "HOME": "/tmp/terminess-home",
            "TERM": "dumb",
        }
        await self.exec_as_agent(environment, command=command, env=env)
