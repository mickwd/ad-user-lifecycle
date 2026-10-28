"""Esquemas Pydantic de entrada y salida."""

from __future__ import annotations

from datetime import date, datetime
from typing import Any

from pydantic import BaseModel, ConfigDict, Field

from api.db import Estado, Tipo

# Letras (incluidas tildes y ñ), espacios, apóstrofo y guion.
NAME_PATTERN = r"^[A-Za-zÁÉÍÓÚÜÑáéíóúüñ' -]+$"
SAM_PATTERN = r"^[a-z0-9][a-z0-9._-]{0,19}$"
TICKET_PATTERN = r"^[A-Za-z0-9-]{3,30}$"


class _Entrada(BaseModel):
    model_config = ConfigDict(str_strip_whitespace=True, extra="forbid")

    ticket: str = Field(pattern=TICKET_PATTERN, examples=["RRHH-1001"])
    origen: str = Field(default="rrhh", min_length=1, max_length=50, examples=["rrhh", "mesa-ayuda"])

    def datos(self) -> dict[str, Any]:
        """Campos que viajan al módulo de PowerShell (sin ticket ni origen)."""
        return self.model_dump(mode="json", exclude={"ticket", "origen"}, exclude_none=True)


class AltaIn(_Entrada):
    nombre: str = Field(min_length=1, max_length=64, pattern=NAME_PATTERN, examples=["Juan"])
    apellido: str = Field(min_length=1, max_length=64, pattern=NAME_PATTERN, examples=["Pérez"])
    legajo: str = Field(pattern=r"^\d{1,10}$", examples=["10234"])
    area: str = Field(min_length=1, max_length=64, examples=["Sistemas"])
    puesto: str = Field(min_length=1, max_length=64, examples=["Analista de Soporte"])
    manager: str | None = Field(default=None, pattern=SAM_PATTERN, examples=["mgarcia"])
    fecha_ingreso: date


class BajaIn(_Entrada):
    usuario: str = Field(pattern=SAM_PATTERN, examples=["jperez"])
    motivo: str | None = Field(default=None, max_length=200)


class CambioIn(_Entrada):
    usuario: str = Field(pattern=SAM_PATTERN, examples=["lgomez"])
    area: str = Field(min_length=1, max_length=64, examples=["Finanzas"])
    puesto: str = Field(min_length=1, max_length=64, examples=["Analista Contable"])


class AprobacionIn(BaseModel):
    model_config = ConfigDict(str_strip_whitespace=True, extra="forbid")

    aprobador: str = Field(min_length=2, max_length=64, examples=["mgarcia"])


class SolicitudOut(BaseModel):
    model_config = ConfigDict(from_attributes=True)

    id: int
    tipo: Tipo
    estado: Estado
    ticket: str
    origen: str
    datos: dict[str, Any]
    resultado: dict[str, Any] | None
    error: str | None
    aprobado_por: str | None
    creado_en: datetime
    actualizado_en: datetime
    aprobado_en: datetime | None
    ejecutado_en: datetime | None
