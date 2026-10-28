"""Configuración de la API leída desde variables de entorno."""

from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path

PROJECT_ROOT = Path(__file__).resolve().parent.parent


class SettingsError(RuntimeError):
    """La configuración está incompleta o es inválida."""


def _env_bool(name: str, default: bool) -> bool:
    value = os.environ.get(name)
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "si", "sí", "yes"}


@dataclass(frozen=True)
class Settings:
    """Parámetros de ejecución.

    Hay dos API keys con roles distintos (mínimo privilegio):
    - intake: la usa el sistema de RRHH o el webhook de mesa de ayuda para cargar solicitudes.
    - approver: la usan los aprobadores para aprobar y ejecutar.
    """

    intake_api_key: str
    approver_api_key: str
    database_url: str = "sqlite:///./adlc.db"
    powershell_exe: str = "powershell"
    script_path: Path = PROJECT_ROOT / "scripts" / "run_request.ps1"
    config_path: Path | None = None
    timeout_seconds: int = 300
    dry_run: bool = False

    def __post_init__(self) -> None:
        if not self.intake_api_key or not self.approver_api_key:
            raise SettingsError("Faltan las API keys (ADLC_INTAKE_API_KEY y ADLC_APPROVER_API_KEY).")
        if self.intake_api_key == self.approver_api_key:
            raise SettingsError("Las API keys de carga y de aprobación tienen que ser distintas.")

    @classmethod
    def from_env(cls) -> Settings:
        config_path = os.environ.get("ADLC_CONFIG")
        return cls(
            intake_api_key=os.environ.get("ADLC_INTAKE_API_KEY", ""),
            approver_api_key=os.environ.get("ADLC_APPROVER_API_KEY", ""),
            database_url=os.environ.get("ADLC_DATABASE_URL", "sqlite:///./adlc.db"),
            powershell_exe=os.environ.get("ADLC_POWERSHELL", "powershell"),
            script_path=Path(os.environ.get("ADLC_SCRIPT_PATH", str(cls.script_path))),
            config_path=Path(config_path) if config_path else None,
            timeout_seconds=int(os.environ.get("ADLC_TIMEOUT_SECONDS", "300")),
            dry_run=_env_bool("ADLC_DRY_RUN", default=False),
        )
