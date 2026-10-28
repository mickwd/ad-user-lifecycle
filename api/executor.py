"""Ejecutores de solicitudes.

El ejecutor es intercambiable: la API recibe cualquier objeto que cumpla el protocolo
``Executor``. En producción se usa ``PowerShellExecutor`` (invoca scripts/run_request.ps1)
y en los tests un ejecutor falso que no toca Active Directory.
"""

from __future__ import annotations

import json
import subprocess
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Protocol

from api.settings import Settings


@dataclass
class ExecutionResult:
    ok: bool
    output: dict[str, Any] = field(default_factory=dict)
    error: str | None = None


class Executor(Protocol):
    def execute(self, request: dict[str, Any]) -> ExecutionResult: ...


def parse_last_json_line(stdout: str) -> dict[str, Any] | None:
    """Devuelve la última línea de stdout que sea un objeto JSON válido."""
    for line in reversed(stdout.splitlines()):
        line = line.strip()
        if not line.startswith("{"):
            continue
        try:
            data = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(data, dict):
            return data
    return None


class PowerShellExecutor:
    """Ejecuta ``powershell -NoProfile -File scripts/run_request.ps1 -RequestJson <json>``.

    Se pasa una lista de argumentos (sin shell), así que el JSON no se interpreta como
    comando. El script devuelve una línea JSON con el resultado y código de salida 0/1.
    """

    def __init__(
        self,
        powershell_exe: str = "powershell",
        script_path: Path | str = Path("scripts/run_request.ps1"),
        config_path: Path | str | None = None,
        timeout_seconds: int = 300,
        dry_run: bool = False,
    ) -> None:
        self.powershell_exe = powershell_exe
        self.script_path = Path(script_path)
        self.config_path = Path(config_path) if config_path else None
        self.timeout_seconds = timeout_seconds
        self.dry_run = dry_run

    @classmethod
    def from_settings(cls, settings: Settings) -> PowerShellExecutor:
        return cls(
            powershell_exe=settings.powershell_exe,
            script_path=settings.script_path,
            config_path=settings.config_path,
            timeout_seconds=settings.timeout_seconds,
            dry_run=settings.dry_run,
        )

    def build_command(self, request: dict[str, Any]) -> list[str]:
        command = [
            self.powershell_exe,
            "-NoProfile",
            "-NonInteractive",
            "-ExecutionPolicy",
            "Bypass",
            "-File",
            str(self.script_path),
            "-RequestJson",
            json.dumps(request, ensure_ascii=False, separators=(",", ":")),
        ]
        if self.config_path:
            command += ["-ConfigPath", str(self.config_path)]
        if self.dry_run:
            command.append("-DryRun")
        return command

    def execute(self, request: dict[str, Any]) -> ExecutionResult:
        command = self.build_command(request)
        try:
            completed = subprocess.run(  # noqa: S603 - argumentos fijos, sin shell
                command,
                capture_output=True,
                timeout=self.timeout_seconds,
                check=False,
            )
        except FileNotFoundError:
            return ExecutionResult(ok=False, error=f"No se encontró '{self.powershell_exe}'.")
        except subprocess.TimeoutExpired:
            return ExecutionResult(
                ok=False, error=f"La ejecución superó el límite de {self.timeout_seconds} segundos."
            )

        stdout = completed.stdout.decode("utf-8", errors="replace")
        stderr = completed.stderr.decode("utf-8", errors="replace").strip()
        data = parse_last_json_line(stdout)

        if data is None:
            detail = stderr or stdout.strip() or "sin salida"
            return ExecutionResult(
                ok=False,
                error=f"Salida inesperada del script (código {completed.returncode}): {detail[:500]}",
            )
        if completed.returncode != 0 or not data.get("ok", False):
            return ExecutionResult(ok=False, output=data, error=str(data.get("error") or stderr))
        return ExecutionResult(ok=True, output=data)
