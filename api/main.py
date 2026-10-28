"""Aplicación FastAPI.

Ejecutar en desarrollo:
    uvicorn --factory api.main:create_app --reload
"""

from __future__ import annotations

from collections.abc import Iterator
from typing import Annotated, Any

from fastapi import APIRouter, Depends, FastAPI, HTTPException, Query, Request, status
from sqlalchemy import select
from sqlalchemy.orm import Session

from api import __version__
from api.db import Estado, Solicitud, Tipo, create_db_engine, create_session_factory, utcnow
from api.executor import Executor, PowerShellExecutor
from api.schemas import AltaIn, AprobacionIn, BajaIn, CambioIn, SolicitudOut
from api.security import Rol, get_rol, require_approver
from api.settings import Settings

ESTADOS_ABIERTOS = (Estado.PENDIENTE, Estado.APROBADO)


def get_session(request: Request) -> Iterator[Session]:
    with request.app.state.session_factory() as session:
        yield session


def get_executor(request: Request) -> Executor:
    return request.app.state.executor


SessionDep = Annotated[Session, Depends(get_session)]
ExecutorDep = Annotated[Executor, Depends(get_executor)]
AnyRol = Annotated[Rol, Depends(get_rol)]
Approver = Annotated[Rol, Depends(require_approver)]

router = APIRouter(prefix="/solicitudes", tags=["solicitudes"])


def _crear(session: Session, tipo: Tipo, entrada: AltaIn | BajaIn | CambioIn, clave: str) -> Solicitud:
    duplicada = session.scalar(
        select(Solicitud).where(
            Solicitud.tipo == tipo,
            Solicitud.clave == clave,
            Solicitud.estado.in_(ESTADOS_ABIERTOS),
        )
    )
    if duplicada is not None:
        raise HTTPException(
            status.HTTP_409_CONFLICT,
            f"Ya existe la solicitud {duplicada.id} ({duplicada.estado}) de {tipo} para '{clave}'.",
        )
    solicitud = Solicitud(
        tipo=tipo,
        estado=Estado.PENDIENTE,
        ticket=entrada.ticket,
        origen=entrada.origen,
        clave=clave,
        datos=entrada.datos(),
    )
    session.add(solicitud)
    session.commit()
    session.refresh(solicitud)
    return solicitud


def _obtener(session: Session, solicitud_id: int) -> Solicitud:
    solicitud = session.get(Solicitud, solicitud_id)
    if solicitud is None:
        raise HTTPException(status.HTTP_404_NOT_FOUND, f"No existe la solicitud {solicitud_id}.")
    return solicitud


@router.post("/altas", response_model=SolicitudOut, status_code=status.HTTP_201_CREATED)
def crear_alta(entrada: AltaIn, session: SessionDep, _rol: AnyRol) -> Solicitud:
    return _crear(session, Tipo.ALTA, entrada, clave=entrada.legajo)


@router.post("/bajas", response_model=SolicitudOut, status_code=status.HTTP_201_CREATED)
def crear_baja(entrada: BajaIn, session: SessionDep, _rol: AnyRol) -> Solicitud:
    return _crear(session, Tipo.BAJA, entrada, clave=entrada.usuario)


@router.post("/cambios", response_model=SolicitudOut, status_code=status.HTTP_201_CREATED)
def crear_cambio(entrada: CambioIn, session: SessionDep, _rol: AnyRol) -> Solicitud:
    return _crear(session, Tipo.CAMBIO, entrada, clave=entrada.usuario)


@router.get("", response_model=list[SolicitudOut])
def listar(
    session: SessionDep,
    _rol: AnyRol,
    estado: Annotated[Estado | None, Query()] = None,
    limit: Annotated[int, Query(ge=1, le=500)] = 100,
) -> list[Solicitud]:
    query = select(Solicitud).order_by(Solicitud.id.desc()).limit(limit)
    if estado is not None:
        query = query.where(Solicitud.estado == estado)
    return list(session.scalars(query))


@router.get("/{solicitud_id}", response_model=SolicitudOut)
def obtener(solicitud_id: int, session: SessionDep, _rol: AnyRol) -> Solicitud:
    return _obtener(session, solicitud_id)


@router.post("/{solicitud_id}/aprobar", response_model=SolicitudOut)
def aprobar(solicitud_id: int, entrada: AprobacionIn, session: SessionDep, _rol: Approver) -> Solicitud:
    solicitud = _obtener(session, solicitud_id)
    if solicitud.estado != Estado.PENDIENTE:
        raise HTTPException(
            status.HTTP_409_CONFLICT,
            f"Solo se aprueban solicitudes pendientes (estado actual: {solicitud.estado}).",
        )
    solicitud.estado = Estado.APROBADO
    solicitud.aprobado_por = entrada.aprobador
    solicitud.aprobado_en = utcnow()
    session.commit()
    session.refresh(solicitud)
    return solicitud


@router.post("/{solicitud_id}/ejecutar", response_model=SolicitudOut)
def ejecutar(solicitud_id: int, session: SessionDep, executor: ExecutorDep, _rol: Approver) -> Solicitud:
    solicitud = _obtener(session, solicitud_id)
    if solicitud.estado != Estado.APROBADO:
        raise HTTPException(
            status.HTTP_409_CONFLICT,
            f"Solo se ejecutan solicitudes aprobadas (estado actual: {solicitud.estado}).",
        )

    payload: dict[str, Any] = {
        "id": solicitud.id,
        "tipo": solicitud.tipo,
        "ticket": solicitud.ticket,
        "origen": solicitud.origen,
        "aprobado_por": solicitud.aprobado_por,
        "datos": solicitud.datos,
    }
    try:
        result = executor.execute(payload)
    except Exception as exc:  # el ejecutor no debería romper la API: se registra como error
        solicitud.estado = Estado.ERROR
        solicitud.error = f"Fallo inesperado del ejecutor: {exc}"
    else:
        solicitud.resultado = result.output or None
        solicitud.error = result.error
        solicitud.estado = Estado.EJECUTADO if result.ok else Estado.ERROR
    solicitud.ejecutado_en = utcnow()
    session.commit()
    session.refresh(solicitud)
    return solicitud


def create_app(settings: Settings | None = None, executor: Executor | None = None) -> FastAPI:
    settings = settings or Settings.from_env()
    engine = create_db_engine(settings.database_url)

    app = FastAPI(
        title="AD User Lifecycle API",
        version=__version__,
        description="Recepción, aprobación y ejecución de solicitudes de altas, bajas y cambios.",
    )
    app.state.settings = settings
    app.state.session_factory = create_session_factory(engine)
    app.state.executor = executor or PowerShellExecutor.from_settings(settings)

    @app.get("/health", tags=["salud"])
    def health() -> dict[str, str]:
        return {"status": "ok", "version": __version__}

    app.include_router(router)
    return app
