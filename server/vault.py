"""Vault-management API and asynchronous document ingestion."""

from __future__ import annotations

from datetime import UTC, datetime
from pathlib import Path
from typing import Annotated, Any
from uuid import uuid4

from fastapi import APIRouter, BackgroundTasks, Form, HTTPException, Query, UploadFile
from pydantic import BaseModel

from context_store import _client, add_context, list_context
from documents import (
    ALLOWED_SUFFIXES,
    MAX_EXTRACTED_TEXT_BYTES,
    MAX_DOCUMENT_BYTES,
    OCR_CHUNK_SIZE,
    _markdown_sections,
    _run_sarvam_ocr,
    _set_document_status,
    _supabase_client,
)
from schemas import ContextItem


router = APIRouter(tags=["vault"])


class ContextValueUpdate(BaseModel):
    value: str


def _document_context_count(client: Any, document_id: str) -> int:
    response = client.table("context_items").select("id", count="exact").eq("document_id", document_id).execute()
    return int(getattr(response, "count", None) or len(response.data or []))


def _document_view(client: Any, row: dict[str, Any]) -> dict[str, Any]:
    document_id = str(row["id"])
    extraction = row.get("ocr_output")
    method = extraction.get("processing_method") if isinstance(extraction, dict) else None
    return {
        "id": document_id,
        "filename": row["filename"],
        "status": row.get("status", "pending"),
        "createdAt": row.get("created_at"),
        "contextItemsCreated": _document_context_count(client, document_id),
        "error": row.get("error"),
        "processingMethod": method,
    }


def _list_documents() -> list[dict[str, Any]]:
    client = _supabase_client()
    response = client.table("documents").select("*").order("created_at", desc=True).execute()
    return [_document_view(client, row) for row in (response.data or [])]


def _get_document(document_id: str) -> dict[str, Any]:
    client = _supabase_client()
    response = client.table("documents").select("*").eq("id", document_id).limit(1).execute()
    if not response.data:
        raise HTTPException(status_code=404, detail="Document not found.")
    return _document_view(client, response.data[0])


def _delete_document(document_id: str) -> None:
    client = _supabase_client()
    response = client.table("documents").select("*").eq("id", document_id).limit(1).execute()
    if not response.data:
        raise HTTPException(status_code=404, detail="Document not found.")
    # context_items.document_id has an FK cascade. Deleting the parent is the
    # single source of truth and prevents this endpoint from drifting from the
    # database's lifecycle rules.
    storage_path = response.data[0].get("storage_path")
    client.table("documents").delete().eq("id", document_id).execute()
    if storage_path:
        try:
            client.storage.from_("documents").remove([storage_path])
        except Exception:
            pass


def _update_context_value(context_id: str, value: str) -> ContextItem:
    response = _client().table("context_items").update({
        "value": value, "updated_at": datetime.now(UTC).isoformat(),
    }).eq("id", context_id).execute()
    if not response.data:
        raise HTTPException(status_code=404, detail="Context item not found.")
    return ContextItem.model_validate(response.data[0])


def _delete_context(context_id: str) -> None:
    client = _client()
    existing = client.table("context_items").select("id").eq("id", context_id).limit(1).execute()
    if not existing.data:
        raise HTTPException(status_code=404, detail="Context item not found.")
    client.table("context_items").delete().eq("id", context_id).execute()


def _recent_activity(limit: int) -> list[dict[str, Any]]:
    response = _client().table("context_items").select(
        "id,key,value,type,category,scope,created_at,updated_at,superseded_by"
    ).order("updated_at", desc=True).limit(limit).execute()
    events: list[dict[str, Any]] = []
    for row in response.data or []:
        updated_at = row.get("updated_at")
        event = "superseded" if row.get("superseded_by") else (
            "updated" if updated_at and updated_at != row.get("created_at") else "created"
        )
        events.append({
            "id": str(row["id"]), "event": event, "key": row["key"], "value": row["value"],
            "type": row["type"], "category": row.get("category"), "scope": row.get("scope"),
            "updatedAt": updated_at or row.get("created_at"),
        })
    return events


def _store_document_context(
    document_id: str,
    filename: str,
    markdown: str,
    processing_method: str,
) -> None:
    """Turn extracted Markdown into the persistent context rows Swara uses."""
    for heading, body in _markdown_sections(markdown):
        add_context(ContextItem(
            type="document", category=heading.lower(),
            key=f"document:{document_id}:{heading.lower().replace(' ', '_')}",
            value=body[:OCR_CHUNK_SIZE], source=filename,
            source_type=f"document_{processing_method}",
            scope="persistent", document_id=document_id,
        ))


def _process_document(document_id: str, filename: str, content: bytes) -> None:
    """Run paid OCR only when local extraction could not read the document."""
    client = _supabase_client()
    try:
        _set_document_status(client, document_id, "processing", error=None)
        job_metadata, markdown = _run_sarvam_ocr(content, filename)
        _set_document_status(
            client,
            document_id,
            "processing",
            ocr_output={**job_metadata, "processing_method": "ocr", "markdown": markdown},
            error=None,
        )
        _store_document_context(document_id, filename, markdown, "ocr")
        _set_document_status(client, document_id, "done", error=None)
    except Exception as exc:  # The status endpoint exposes OCR failures to callers.
        try:
            _set_document_status(client, document_id, "failed", error=str(exc)[:2_000])
        except Exception:
            pass


def _process_local_document(document_id: str, filename: str, markdown: str) -> None:
    """Persist browser-extracted Markdown without spending OCR quota."""
    client = _supabase_client()
    try:
        _set_document_status(
            client,
            document_id,
            "processing",
            ocr_output={"processing_method": "local", "format": "markdown", "markdown": markdown},
            error=None,
        )
        _store_document_context(document_id, filename, markdown, "local")
        _set_document_status(client, document_id, "done", error=None)
    except Exception as exc:
        try:
            _set_document_status(client, document_id, "failed", error=str(exc)[:2_000])
        except Exception:
            pass


@router.post("/documents/upload", operation_id="queue_document_upload")
async def upload_document(
    file: UploadFile,
    background_tasks: BackgroundTasks,
    extracted_text: Annotated[str | None, Form()] = None,
) -> dict[str, Any]:
    """Store a document, preferring free local extraction over paid OCR."""
    filename = Path(file.filename or "").name
    suffix = Path(filename).suffix.lower()
    if not filename or suffix not in ALLOWED_SUFFIXES:
        raise HTTPException(
            status_code=400,
            detail="This document type is not supported by Swara's local parser or OCR fallback.",
        )
    content = await file.read()
    await file.close()
    if not content:
        raise HTTPException(status_code=400, detail="The uploaded document is empty.")
    if len(content) > MAX_DOCUMENT_BYTES:
        raise HTTPException(status_code=413, detail="Documents must be 20 MB or smaller.")
    if extracted_text is not None:
        extracted_text = extracted_text.strip()
        if not extracted_text:
            raise HTTPException(status_code=400, detail="Extracted document text must not be empty.")
        if len(extracted_text.encode("utf-8")) > MAX_EXTRACTED_TEXT_BYTES:
            raise HTTPException(status_code=413, detail="Extracted document text is too large.")

    processing_method = "local" if extracted_text is not None else "ocr"
    client = _supabase_client()
    storage_path = f"{uuid4()}/{filename}"
    try:
        client.storage.from_("documents").upload(
            path=storage_path, file=content,
            file_options={"content-type": file.content_type or "application/octet-stream"},
        )
        response = client.table("documents").insert({
            "filename": filename,
            "storage_path": storage_path,
            "status": "pending",
            "ocr_output": {"processing_method": processing_method},
        }).execute()
        if not response.data:
            raise RuntimeError("Supabase did not return the created document row.")
    except RuntimeError:
        raise
    except Exception as exc:
        raise HTTPException(status_code=502, detail=f"Could not store document: {exc}") from exc

    document_id = str(response.data[0]["id"])
    if extracted_text is not None:
        background_tasks.add_task(_process_local_document, document_id, filename, extracted_text)
    else:
        background_tasks.add_task(_process_document, document_id, filename, content)
    return {
        "id": document_id,
        "filename": filename,
        "status": "pending",
        "contextItemsCreated": 0,
        "processingMethod": processing_method,
    }


@router.get("/documents")
def get_documents() -> list[dict[str, Any]]:
    return _list_documents()


@router.get("/documents/{document_id}")
def get_document(document_id: str) -> dict[str, Any]:
    return _get_document(document_id)


@router.delete("/documents/{document_id}", status_code=204)
def delete_document(document_id: str) -> None:
    _delete_document(document_id)


@router.post("/context", response_model=ContextItem)
def create_context(item: ContextItem) -> ContextItem:
    return add_context(item)


@router.patch("/context/{context_id}", response_model=ContextItem)
def update_context(context_id: str, update: ContextValueUpdate) -> ContextItem:
    return _update_context_value(context_id, update.value)


@router.delete("/context/{context_id}", status_code=204)
def delete_context(context_id: str) -> None:
    _delete_context(context_id)


@router.get("/context/history", response_model=list[ContextItem])
def context_history(key: str = Query(min_length=1)) -> list[ContextItem]:
    return [item for item in list_context(include_superseded=True) if item.key == key]


@router.get("/activity")
def activity(limit: int = Query(default=50, ge=1, le=200)) -> list[dict[str, Any]]:
    return _recent_activity(limit)
