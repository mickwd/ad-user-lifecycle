"""Autenticación por API key con dos roles: carga (intake) y aprobación (approver)."""

from __future__ import annotations

import secrets
from enum import StrEnum
from typing import Annotated

from fastapi import Depends, HTTPException, Request, status
from fastapi.security import APIKeyHeader

api_key_header = APIKeyHeader(name="X-API-Key", auto_error=False)


class Rol(StrEnum):
    INTAKE = "intake"
    APPROVER = "approver"


def get_rol(request: Request, api_key: Annotated[str | None, Depends(api_key_header)]) -> Rol:
    if not api_key:
        raise HTTPException(status.HTTP_401_UNAUTHORIZED, "Falta el header X-API-Key.")
    settings = request.app.state.settings
    # compare_digest evita filtrar información por diferencias de tiempo.
    if secrets.compare_digest(api_key, settings.approver_api_key):
        return Rol.APPROVER
    if secrets.compare_digest(api_key, settings.intake_api_key):
        return Rol.INTAKE
    raise HTTPException(status.HTTP_401_UNAUTHORIZED, "API key inválida.")


def require_approver(rol: Annotated[Rol, Depends(get_rol)]) -> Rol:
    if rol is not Rol.APPROVER:
        raise HTTPException(status.HTTP_403_FORBIDDEN, "Se requiere la API key de aprobación.")
    return rol
