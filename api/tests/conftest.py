from __future__ import annotations

from collections.abc import Iterator
from typing import Any

import pytest
from fastapi.testclient import TestClient

from api.executor import ExecutionResult
from api.main import create_app
from api.settings import Settings

INTAKE_KEY = "clave-rrhh-test"
APPROVER_KEY = "clave-aprobador-test"


class FakeExecutor:
    """Ejecutor falso: registra las solicitudes y devuelve un resultado configurable."""

    def __init__(self) -> None:
        self.calls: list[dict[str, Any]] = []
        self.result = ExecutionResult(ok=True, output={"ok": True, "estado": "OK", "usuario": "jperez"})
        self.raise_error: Exception | None = None

    def execute(self, request: dict[str, Any]) -> ExecutionResult:
        self.calls.append(request)
        if self.raise_error:
            raise self.raise_error
        return self.result


@pytest.fixture
def settings() -> Settings:
    return Settings(
        intake_api_key=INTAKE_KEY,
        approver_api_key=APPROVER_KEY,
        database_url="sqlite://",
    )


@pytest.fixture
def executor() -> FakeExecutor:
    return FakeExecutor()


@pytest.fixture
def client(settings: Settings, executor: FakeExecutor) -> Iterator[TestClient]:
    app = create_app(settings=settings, executor=executor)
    with TestClient(app) as test_client:
        yield test_client


@pytest.fixture
def intake() -> dict[str, str]:
    return {"X-API-Key": INTAKE_KEY}


@pytest.fixture
def approver() -> dict[str, str]:
    return {"X-API-Key": APPROVER_KEY}


@pytest.fixture
def alta_payload() -> dict[str, Any]:
    return {
        "nombre": "Juan",
        "apellido": "Pérez",
        "legajo": "10234",
        "area": "Sistemas",
        "puesto": "Analista de Soporte",
        "manager": "mgarcia",
        "fecha_ingreso": "2026-11-02",
        "ticket": "RRHH-1001",
    }
