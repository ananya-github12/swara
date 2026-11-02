"""Authenticated HTTP surface for the RLS-backed personal Vault contract.

Document creation and object upload intentionally stay in the Supabase
``vault-upload-intent`` and ``vault-finalize-upload`` functions.  This server
never reads from or writes to a Storage bucket.
"""

from __future__ import annotations

from typing import Annotated, Any

from fastapi import APIRouter, Depends, HTTPException, Query, Request
from pydantic import BaseModel, ConfigDict

from api_auth import require_authenticated_context, vault_repository
from repositories.common import NotFoundError, RepositoryError
from repositories.vault import DEFAULT_LIMIT, VaultRepository
from request_context import RequestContext


router = APIRouter(
    prefix="/vault",
    tags=["vault"],
    dependencies=[Depends(require_authenticated_context)],
)


class CorrectionRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")
    value: str


def _repository(
    request: Request,
    context: Annotated[RequestContext, Depends(require_authenticated_context)],
) -> VaultRepository:
    return vault_repository(request, context)


def _run(operation: Any) -> Any:
    try:
        return operation()
    except NotFoundError as error:
        raise HTTPException(status_code=404, detail="Vault resource not found") from error
    except ValueError as error:
        raise HTTPException(status_code=422, detail=str(error)) from error
    except RepositoryError as error:
        raise HTTPException(status_code=502, detail="Vault persistence is unavailable") from error


@router.get("/documents")
def list_documents(
    repository: Annotated[VaultRepository, Depends(_repository)],
    limit: int = Query(DEFAULT_LIMIT, ge=1, le=200),
    include_deleted: bool = False,
) -> list[dict[str, Any]]:
    return _run(lambda: repository.list_documents(limit, include_deleted=include_deleted))


@router.get("/documents/{document_id}")
def get_document(
    document_id: str,
    repository: Annotated[VaultRepository, Depends(_repository)],
) -> dict[str, Any]:
    return _run(lambda: repository.get_document(document_id))


@router.get("/context")
def list_context(
    repository: Annotated[VaultRepository, Depends(_repository)],
    limit: int = Query(DEFAULT_LIMIT, ge=1, le=200),
    include_history: bool = False,
    scope: str | None = None,
) -> list[dict[str, Any]]:
    return _run(lambda: repository.list_context_items(limit, include_history=include_history, scope=scope))


@router.get("/context/search")
def search_context(
    repository: Annotated[VaultRepository, Depends(_repository)],
    search: str = Query(min_length=1, max_length=512),
    limit: int = Query(DEFAULT_LIMIT, ge=1, le=200),
    include_history: bool = False,
) -> list[dict[str, Any]]:
    return _run(lambda: repository.search_context_items(search, limit, include_history=include_history))


@router.post("/context", status_code=201)
def create_context(
    item: dict[str, Any],
    repository: Annotated[VaultRepository, Depends(_repository)],
) -> dict[str, Any]:
    return _run(lambda: repository.insert_first_context_item(item))


@router.post("/context/{prior_id}/corrections", status_code=201)
def append_correction(
    prior_id: str,
    correction: CorrectionRequest,
    repository: Annotated[VaultRepository, Depends(_repository)],
) -> dict[str, Any]:
    return _run(lambda: repository.append_correction(prior_id, correction.value))
