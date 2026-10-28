from __future__ import annotations

from typing import Any

import pytest
from fastapi.testclient import TestClient

from api.executor import ExecutionResult
from api.settings import Settings, SettingsError
from api.tests.conftest import FakeExecutor


def crear_y_aprobar(
    client: TestClient, intake: dict[str, str], approver: dict[str, str], payload: dict[str, Any]
) -> int:
    creada = client.post("/solicitudes/altas", json=payload, headers=intake)
    assert creada.status_code == 201, creada.text
    solicitud_id = creada.json()["id"]
    aprobada = client.post(
        f"/solicitudes/{solicitud_id}/aprobar", json={"aprobador": "mgarcia"}, headers=approver
    )
    assert aprobada.status_code == 200, aprobada.text
    return solicitud_id


class TestAutenticacion:
    def test_health_no_requiere_key(self, client: TestClient) -> None:
        assert client.get("/health").json()["status"] == "ok"

    def test_sin_key_devuelve_401(self, client: TestClient, alta_payload: dict[str, Any]) -> None:
        assert client.post("/solicitudes/altas", json=alta_payload).status_code == 401

    def test_key_invalida_devuelve_401(self, client: TestClient) -> None:
        assert client.get("/solicitudes", headers={"X-API-Key": "cualquiera"}).status_code == 401

    def test_key_de_carga_no_puede_aprobar(
        self, client: TestClient, intake: dict[str, str], alta_payload: dict[str, Any]
    ) -> None:
        solicitud_id = client.post("/solicitudes/altas", json=alta_payload, headers=intake).json()["id"]
        respuesta = client.post(
            f"/solicitudes/{solicitud_id}/aprobar", json={"aprobador": "x1"}, headers=intake
        )
        assert respuesta.status_code == 403

    def test_key_de_carga_no_puede_ejecutar(
        self,
        client: TestClient,
        intake: dict[str, str],
        approver: dict[str, str],
        alta_payload: dict[str, Any],
    ) -> None:
        solicitud_id = crear_y_aprobar(client, intake, approver, alta_payload)
        assert client.post(f"/solicitudes/{solicitud_id}/ejecutar", headers=intake).status_code == 403

    def test_settings_exige_keys_distintas(self) -> None:
        with pytest.raises(SettingsError):
            Settings(intake_api_key="igual", approver_api_key="igual")
        with pytest.raises(SettingsError):
            Settings(intake_api_key="", approver_api_key="otra")


class TestValidacion:
    @pytest.mark.parametrize(
        ("campo", "valor"),
        [
            ("legajo", "ABC"),
            ("nombre", "Juan<script>"),
            ("ticket", "x"),
            ("manager", "Mal Usuario"),
            ("fecha_ingreso", "02/11/2026"),
        ],
    )
    def test_alta_rechaza_datos_invalidos(
        self, client: TestClient, intake: dict[str, str], alta_payload: dict[str, Any], campo: str, valor: str
    ) -> None:
        alta_payload[campo] = valor
        assert client.post("/solicitudes/altas", json=alta_payload, headers=intake).status_code == 422

    def test_alta_rechaza_campos_extra(
        self, client: TestClient, intake: dict[str, str], alta_payload: dict[str, Any]
    ) -> None:
        alta_payload["es_admin"] = True
        assert client.post("/solicitudes/altas", json=alta_payload, headers=intake).status_code == 422

    def test_baja_rechaza_usuario_invalido(self, client: TestClient, intake: dict[str, str]) -> None:
        respuesta = client.post(
            "/solicitudes/bajas", json={"usuario": "jperez; Remove-ADUser", "ticket": "INC-1"}, headers=intake
        )
        assert respuesta.status_code == 422

    def test_alta_acepta_tildes_y_normaliza_espacios(
        self, client: TestClient, intake: dict[str, str], alta_payload: dict[str, Any]
    ) -> None:
        alta_payload["nombre"] = "  María José  "
        respuesta = client.post("/solicitudes/altas", json=alta_payload, headers=intake)
        assert respuesta.status_code == 201
        assert respuesta.json()["datos"]["nombre"] == "María José"


class TestFlujo:
    def test_alta_queda_pendiente(
        self, client: TestClient, intake: dict[str, str], alta_payload: dict[str, Any]
    ) -> None:
        respuesta = client.post("/solicitudes/altas", json=alta_payload, headers=intake)
        cuerpo = respuesta.json()
        assert cuerpo["estado"] == "pendiente"
        assert cuerpo["tipo"] == "alta"
        assert cuerpo["ticket"] == "RRHH-1001"
        assert "ticket" not in cuerpo["datos"]

    def test_flujo_completo_alta(
        self,
        client: TestClient,
        executor: FakeExecutor,
        intake: dict[str, str],
        approver: dict[str, str],
        alta_payload: dict[str, Any],
    ) -> None:
        solicitud_id = crear_y_aprobar(client, intake, approver, alta_payload)
        respuesta = client.post(f"/solicitudes/{solicitud_id}/ejecutar", headers=approver)

        assert respuesta.status_code == 200
        cuerpo = respuesta.json()
        assert cuerpo["estado"] == "ejecutado"
        assert cuerpo["aprobado_por"] == "mgarcia"
        assert cuerpo["resultado"]["usuario"] == "jperez"
        assert cuerpo["ejecutado_en"] is not None

        assert len(executor.calls) == 1
        enviado = executor.calls[0]
        assert enviado["tipo"] == "alta"
        assert enviado["ticket"] == "RRHH-1001"
        assert enviado["aprobado_por"] == "mgarcia"
        assert enviado["datos"]["legajo"] == "10234"
        assert enviado["datos"]["fecha_ingreso"] == "2026-11-02"

    def test_no_se_ejecuta_sin_aprobacion(
        self,
        client: TestClient,
        executor: FakeExecutor,
        intake: dict[str, str],
        approver: dict[str, str],
        alta_payload: dict[str, Any],
    ) -> None:
        solicitud_id = client.post("/solicitudes/altas", json=alta_payload, headers=intake).json()["id"]
        respuesta = client.post(f"/solicitudes/{solicitud_id}/ejecutar", headers=approver)
        assert respuesta.status_code == 409
        assert executor.calls == []

    def test_no_se_aprueba_dos_veces(
        self,
        client: TestClient,
        intake: dict[str, str],
        approver: dict[str, str],
        alta_payload: dict[str, Any],
    ) -> None:
        solicitud_id = crear_y_aprobar(client, intake, approver, alta_payload)
        respuesta = client.post(
            f"/solicitudes/{solicitud_id}/aprobar", json={"aprobador": "otro"}, headers=approver
        )
        assert respuesta.status_code == 409

    def test_no_se_ejecuta_dos_veces(
        self,
        client: TestClient,
        executor: FakeExecutor,
        intake: dict[str, str],
        approver: dict[str, str],
        alta_payload: dict[str, Any],
    ) -> None:
        solicitud_id = crear_y_aprobar(client, intake, approver, alta_payload)
        client.post(f"/solicitudes/{solicitud_id}/ejecutar", headers=approver)
        respuesta = client.post(f"/solicitudes/{solicitud_id}/ejecutar", headers=approver)
        assert respuesta.status_code == 409
        assert len(executor.calls) == 1

    def test_error_del_ejecutor_queda_registrado(
        self,
        client: TestClient,
        executor: FakeExecutor,
        intake: dict[str, str],
        approver: dict[str, str],
        alta_payload: dict[str, Any],
    ) -> None:
        executor.result = ExecutionResult(
            ok=False,
            output={"ok": False, "error": "Ya existe una cuenta con el legajo 10234"},
            error="Ya existe",
        )
        solicitud_id = crear_y_aprobar(client, intake, approver, alta_payload)
        cuerpo = client.post(f"/solicitudes/{solicitud_id}/ejecutar", headers=approver).json()
        assert cuerpo["estado"] == "error"
        assert cuerpo["error"] == "Ya existe"

    def test_excepcion_del_ejecutor_no_rompe_la_api(
        self,
        client: TestClient,
        executor: FakeExecutor,
        intake: dict[str, str],
        approver: dict[str, str],
        alta_payload: dict[str, Any],
    ) -> None:
        executor.raise_error = RuntimeError("se cayó el proceso")
        solicitud_id = crear_y_aprobar(client, intake, approver, alta_payload)
        cuerpo = client.post(f"/solicitudes/{solicitud_id}/ejecutar", headers=approver).json()
        assert cuerpo["estado"] == "error"
        assert "se cayó el proceso" in cuerpo["error"]

    def test_alta_duplicada_abierta_devuelve_409(
        self, client: TestClient, intake: dict[str, str], alta_payload: dict[str, Any]
    ) -> None:
        assert client.post("/solicitudes/altas", json=alta_payload, headers=intake).status_code == 201
        respuesta = client.post("/solicitudes/altas", json=alta_payload, headers=intake)
        assert respuesta.status_code == 409

    def test_se_puede_reintentar_una_alta_que_fallo(
        self,
        client: TestClient,
        executor: FakeExecutor,
        intake: dict[str, str],
        approver: dict[str, str],
        alta_payload: dict[str, Any],
    ) -> None:
        executor.result = ExecutionResult(ok=False, error="falla")
        solicitud_id = crear_y_aprobar(client, intake, approver, alta_payload)
        client.post(f"/solicitudes/{solicitud_id}/ejecutar", headers=approver)
        assert client.post("/solicitudes/altas", json=alta_payload, headers=intake).status_code == 201

    def test_baja_y_cambio(
        self, client: TestClient, executor: FakeExecutor, intake: dict[str, str], approver: dict[str, str]
    ) -> None:
        baja = client.post(
            "/solicitudes/bajas",
            json={"usuario": "acastro", "ticket": "INC-2045", "origen": "mesa-ayuda"},
            headers=intake,
        )
        cambio = client.post(
            "/solicitudes/cambios",
            json={
                "usuario": "lgomez",
                "area": "Finanzas",
                "puesto": "Analista Contable",
                "ticket": "RRHH-1004",
            },
            headers=intake,
        )
        assert baja.status_code == 201
        assert cambio.status_code == 201
        for solicitud in (baja.json(), cambio.json()):
            client.post(
                f"/solicitudes/{solicitud['id']}/aprobar", json={"aprobador": "mgarcia"}, headers=approver
            )
            client.post(f"/solicitudes/{solicitud['id']}/ejecutar", headers=approver)
        assert [call["tipo"] for call in executor.calls] == ["baja", "cambio"]
        assert executor.calls[0]["origen"] == "mesa-ayuda"
        assert executor.calls[1]["datos"] == {
            "usuario": "lgomez",
            "area": "Finanzas",
            "puesto": "Analista Contable",
        }


class TestConsultas:
    def test_listar_filtra_por_estado(
        self,
        client: TestClient,
        intake: dict[str, str],
        approver: dict[str, str],
        alta_payload: dict[str, Any],
    ) -> None:
        crear_y_aprobar(client, intake, approver, alta_payload)
        otra = dict(alta_payload, legajo="20000", nombre="Ana")
        client.post("/solicitudes/altas", json=otra, headers=intake)

        pendientes = client.get("/solicitudes", params={"estado": "pendiente"}, headers=intake).json()
        aprobadas = client.get("/solicitudes", params={"estado": "aprobado"}, headers=intake).json()
        todas = client.get("/solicitudes", headers=intake).json()

        assert [s["datos"]["legajo"] for s in pendientes] == ["20000"]
        assert [s["datos"]["legajo"] for s in aprobadas] == ["10234"]
        assert len(todas) == 2

    def test_estado_invalido_devuelve_422(self, client: TestClient, intake: dict[str, str]) -> None:
        assert client.get("/solicitudes", params={"estado": "borrado"}, headers=intake).status_code == 422

    def test_solicitud_inexistente_devuelve_404(self, client: TestClient, intake: dict[str, str]) -> None:
        assert client.get("/solicitudes/999", headers=intake).status_code == 404
