"""Modelo de datos y sesión de SQLAlchemy."""

from __future__ import annotations

from datetime import UTC, datetime
from enum import StrEnum
from typing import Any

from sqlalchemy import JSON, DateTime, Engine, String, Text, create_engine
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column, sessionmaker
from sqlalchemy.pool import StaticPool


class Estado(StrEnum):
    PENDIENTE = "pendiente"
    APROBADO = "aprobado"
    EJECUTADO = "ejecutado"
    ERROR = "error"


class Tipo(StrEnum):
    ALTA = "alta"
    BAJA = "baja"
    CAMBIO = "cambio"


def utcnow() -> datetime:
    return datetime.now(UTC)


class Base(DeclarativeBase):
    pass


class Solicitud(Base):
    __tablename__ = "solicitudes"

    id: Mapped[int] = mapped_column(primary_key=True)
    tipo: Mapped[str] = mapped_column(String(10), index=True)
    estado: Mapped[str] = mapped_column(String(15), index=True, default=Estado.PENDIENTE)
    ticket: Mapped[str] = mapped_column(String(30))
    origen: Mapped[str] = mapped_column(String(50))
    # Clave para detectar duplicados: legajo en altas, usuario en bajas y cambios.
    clave: Mapped[str] = mapped_column(String(64), index=True)
    datos: Mapped[dict[str, Any]] = mapped_column(JSON)
    resultado: Mapped[dict[str, Any] | None] = mapped_column(JSON, nullable=True)
    error: Mapped[str | None] = mapped_column(Text, nullable=True)
    aprobado_por: Mapped[str | None] = mapped_column(String(64), nullable=True)
    creado_en: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow)
    actualizado_en: Mapped[datetime] = mapped_column(DateTime(timezone=True), default=utcnow, onupdate=utcnow)
    aprobado_en: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    ejecutado_en: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)


def create_db_engine(database_url: str) -> Engine:
    """Crea el engine. Para SQLite en memoria usa StaticPool (una sola conexión compartida)."""
    if database_url.startswith("sqlite"):
        connect_args = {"check_same_thread": False}
        if database_url in {"sqlite://", "sqlite:///:memory:"}:
            return create_engine(database_url, connect_args=connect_args, poolclass=StaticPool)
        return create_engine(database_url, connect_args=connect_args)
    return create_engine(database_url, pool_pre_ping=True)


def create_session_factory(engine: Engine) -> sessionmaker:
    Base.metadata.create_all(engine)
    return sessionmaker(bind=engine, expire_on_commit=False)
