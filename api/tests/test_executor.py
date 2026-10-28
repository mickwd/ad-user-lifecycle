from __future__ import annotations

import json
import subprocess
from pathlib import Path
from typing import Any

import pytest

from api.executor import PowerShellExecutor, parse_last_json_line
from api.settings import Settings

REQUEST: dict[str, Any] = {
    "id": 7,
    "tipo": "alta",
    "ticket": "RRHH-1001",
    "datos": {"nombre": "José", "apellido": 'O\'Neil "x" & | <>'},
}


def fake_run(stdout: str = "", stderr: str = "", returncode: int = 0):
    calls: list[list[str]] = []

    def _run(command: list[str], **kwargs: Any) -> subprocess.CompletedProcess[bytes]:
        calls.append(command)
        assert kwargs["capture_output"] is True
        assert "shell" not in kwargs
        return subprocess.CompletedProcess(command, returncode, stdout.encode(), stderr.encode())

    return _run, calls


def test_arma_el_comando_sin_shell_y_con_el_json_como_un_solo_argumento() -> None:
    executor = PowerShellExecutor(
        script_path=Path("scripts/run_request.ps1"), dry_run=True, config_path="c.json"
    )
    command = executor.build_command(REQUEST)

    assert command[:7] == [
        "powershell",
        "-NoProfile",
        "-NonInteractive",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        str(Path("scripts/run_request.ps1")),
    ]
    json_index = command.index("-RequestJson") + 1
    assert json.loads(command[json_index]) == REQUEST
    assert command[-3:] == ["-ConfigPath", "c.json", "-DryRun"]


def test_resultado_ok(monkeypatch: pytest.MonkeyPatch) -> None:
    salida = 'ADVERTENCIA: algo\n{"ok":true,"estado":"OK","usuario":"jperez"}\n'
    run, calls = fake_run(stdout=salida)
    monkeypatch.setattr(subprocess, "run", run)

    result = PowerShellExecutor().execute(REQUEST)

    assert result.ok is True
    assert result.output["usuario"] == "jperez"
    assert result.error is None
    assert len(calls) == 1


def test_resultado_con_error_del_script(monkeypatch: pytest.MonkeyPatch) -> None:
    run, _ = fake_run(stdout='{"ok":false,"error":"Ya existe una cuenta con el legajo 10234"}', returncode=1)
    monkeypatch.setattr(subprocess, "run", run)

    result = PowerShellExecutor().execute(REQUEST)

    assert result.ok is False
    assert result.error == "Ya existe una cuenta con el legajo 10234"


def test_salida_sin_json(monkeypatch: pytest.MonkeyPatch) -> None:
    run, _ = fake_run(stderr="No se puede cargar el archivo run_request.ps1", returncode=1)
    monkeypatch.setattr(subprocess, "run", run)

    result = PowerShellExecutor().execute(REQUEST)

    assert result.ok is False
    assert "No se puede cargar" in (result.error or "")


def test_codigo_distinto_de_cero_aunque_diga_ok(monkeypatch: pytest.MonkeyPatch) -> None:
    run, _ = fake_run(stdout='{"ok":true}', returncode=1)
    monkeypatch.setattr(subprocess, "run", run)
    assert PowerShellExecutor().execute(REQUEST).ok is False


def test_powershell_no_encontrado(monkeypatch: pytest.MonkeyPatch) -> None:
    def _run(*_args: Any, **_kwargs: Any) -> None:
        raise FileNotFoundError

    monkeypatch.setattr(subprocess, "run", _run)
    result = PowerShellExecutor(powershell_exe="pwsh-inexistente").execute(REQUEST)
    assert result.ok is False
    assert "pwsh-inexistente" in (result.error or "")


def test_timeout(monkeypatch: pytest.MonkeyPatch) -> None:
    def _run(command: list[str], **kwargs: Any) -> None:
        raise subprocess.TimeoutExpired(command, kwargs["timeout"])

    monkeypatch.setattr(subprocess, "run", _run)
    result = PowerShellExecutor(timeout_seconds=5).execute(REQUEST)
    assert result.ok is False
    assert "5 segundos" in (result.error or "")


def test_from_settings() -> None:
    settings = Settings(intake_api_key="a", approver_api_key="b", powershell_exe="pwsh", dry_run=True)
    executor = PowerShellExecutor.from_settings(settings)
    assert executor.powershell_exe == "pwsh"
    assert executor.dry_run is True
    assert executor.script_path.name == "run_request.ps1"


@pytest.mark.parametrize(
    ("stdout", "esperado"),
    [
        ('{"ok":true}', {"ok": True}),
        ('basura\n{"ok":true}\n\n', {"ok": True}),
        ('{"a":1}\n{"b":2}', {"b": 2}),
        ("{no es json", None),
        ("[1,2]", None),
        ("", None),
    ],
)
def test_parse_last_json_line(stdout: str, esperado: dict[str, Any] | None) -> None:
    assert parse_last_json_line(stdout) == esperado
