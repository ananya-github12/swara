from __future__ import annotations

import asyncio
import io
import unittest
from unittest.mock import Mock, patch

from fastapi import BackgroundTasks, HTTPException, UploadFile
from starlette.datastructures import Headers

import vault


class _Result:
    def __init__(self, data: list[dict[str, object]]) -> None:
        self.data = data


class _DocumentsTable:
    def __init__(self, document_id: str = "doc-1") -> None:
        self.document_id = document_id
        self.inserted: dict[str, object] | None = None

    def insert(self, payload: dict[str, object]) -> _DocumentsTable:
        self.inserted = payload
        return self

    def execute(self) -> _Result:
        return _Result([{"id": self.document_id}])


class _StorageBucket:
    def __init__(self) -> None:
        self.uploads: list[dict[str, object]] = []

    def upload(self, **kwargs: object) -> None:
        self.uploads.append(kwargs)


class _Storage:
    def __init__(self, bucket: _StorageBucket) -> None:
        self.bucket = bucket

    def from_(self, name: str) -> _StorageBucket:
        if name != "documents":
            raise AssertionError(f"Unexpected bucket: {name}")
        return self.bucket


class _Client:
    def __init__(self) -> None:
        self.bucket = _StorageBucket()
        self.storage = _Storage(self.bucket)
        self.documents = _DocumentsTable()

    def table(self, name: str) -> _DocumentsTable:
        if name != "documents":
            raise AssertionError(f"Unexpected table: {name}")
        return self.documents


def _upload(filename: str, content: bytes, content_type: str) -> UploadFile:
    return UploadFile(
        file=io.BytesIO(content),
        filename=filename,
        headers=Headers({"content-type": content_type}),
    )


class UploadDocumentTests(unittest.TestCase):
    def test_valid_upload_returns_pending_and_queues_ocr(self) -> None:
        client = _Client()
        tasks = BackgroundTasks()

        with patch.object(vault, "_supabase_client", return_value=client):
            response = asyncio.run(
                vault.upload_document(
                    _upload("resume.pdf", b"%PDF-1.7", "application/pdf"),
                    tasks,
                )
            )

        self.assertEqual(
            response,
            {
                "id": "doc-1",
                "filename": "resume.pdf",
                "status": "pending",
                "contextItemsCreated": 0,
                "processingMethod": "ocr",
            },
        )
        self.assertEqual(client.documents.inserted["status"], "pending")
        self.assertEqual(client.documents.inserted["ocr_output"], {"processing_method": "ocr"})
        self.assertEqual(len(client.bucket.uploads), 1)
        self.assertEqual(len(tasks.tasks), 1)
        self.assertIs(tasks.tasks[0].func, vault._process_document)

    def test_zip_upload_uses_the_same_ingestion_path(self) -> None:
        client = _Client()

        with patch.object(vault, "_supabase_client", return_value=client):
            response = asyncio.run(
                vault.upload_document(
                    _upload("documents.zip", b"PK\x03\x04", "application/zip"),
                    BackgroundTasks(),
                )
            )

        self.assertEqual(response["status"], "pending")
        self.assertEqual(response["filename"], "documents.zip")

    def test_browser_extracted_document_skips_ocr(self) -> None:
        client = _Client()
        tasks = BackgroundTasks()

        with patch.object(vault, "_supabase_client", return_value=client):
            response = asyncio.run(
                vault.upload_document(
                    _upload("resume.docx", b"PK\x03\x04", "application/vnd.openxmlformats-officedocument.wordprocessingml.document"),
                    tasks,
                    extracted_text="# Experience\nBuilt Swara",
                )
            )

        self.assertEqual(response["processingMethod"], "local")
        self.assertEqual(client.documents.inserted["ocr_output"], {"processing_method": "local"})
        self.assertEqual(len(tasks.tasks), 1)
        self.assertIs(tasks.tasks[0].func, vault._process_local_document)
        self.assertEqual(tasks.tasks[0].args[-1], "# Experience\nBuilt Swara")

    def test_rejects_an_unsupported_file_before_storage(self) -> None:
        with patch.object(vault, "_supabase_client") as client:
            with self.assertRaises(HTTPException) as raised:
                asyncio.run(
                    vault.upload_document(
                        _upload("malware.exe", b"hello", "application/octet-stream"),
                        BackgroundTasks(),
                    )
                )

        self.assertEqual(raised.exception.status_code, 400)
        client.assert_not_called()


class ProcessDocumentTests(unittest.TestCase):
    def test_ocr_sections_become_document_context(self) -> None:
        client = Mock()
        created = []

        with (
            patch.object(vault, "_supabase_client", return_value=client),
            patch.object(
                vault,
                "_run_sarvam_ocr",
                return_value=({"job_id": "job-1"}, "# Experience\nBuilt Swara"),
            ),
            patch.object(
                vault,
                "_markdown_sections",
                return_value=[("Experience", "Built Swara")],
            ),
            patch.object(vault, "_set_document_status") as set_status,
            patch.object(vault, "add_context", side_effect=created.append),
        ):
            vault._process_document("doc-1", "resume.pdf", b"%PDF-1.7")

        self.assertEqual(set_status.call_args_list[0].args[2], "processing")
        self.assertEqual(set_status.call_args_list[-1].args[2], "done")
        self.assertEqual(len(created), 1)
        self.assertEqual(created[0].document_id, "doc-1")
        self.assertEqual(created[0].source, "resume.pdf")
        self.assertEqual(created[0].value, "Built Swara")

    def test_ocr_failure_is_persisted_without_crashing_the_worker(self) -> None:
        client = Mock()

        with (
            patch.object(vault, "_supabase_client", return_value=client),
            patch.object(vault, "_run_sarvam_ocr", side_effect=RuntimeError("OCR unavailable")),
            patch.object(vault, "_set_document_status") as set_status,
        ):
            vault._process_document("doc-1", "resume.pdf", b"%PDF-1.7")

        failed = set_status.call_args_list[-1]
        self.assertEqual(failed.args[2], "failed")
        self.assertEqual(failed.kwargs["error"], "OCR unavailable")

    def test_local_markdown_creates_context_without_calling_ocr(self) -> None:
        client = Mock()
        created = []

        with (
            patch.object(vault, "_supabase_client", return_value=client),
            patch.object(vault, "_run_sarvam_ocr") as run_ocr,
            patch.object(vault, "_set_document_status") as set_status,
            patch.object(vault, "add_context", side_effect=created.append),
        ):
            vault._process_local_document(
                "doc-1",
                "resume.docx",
                "# Experience\nBuilt Swara",
            )

        run_ocr.assert_not_called()
        self.assertEqual(set_status.call_args_list[-1].args[2], "done")
        self.assertEqual(len(created), 1)
        self.assertEqual(created[0].source_type, "document_local")


class DocumentViewTests(unittest.TestCase):
    def test_exposes_the_recorded_processing_method(self) -> None:
        with patch.object(vault, "_document_context_count", return_value=3):
            result = vault._document_view(Mock(), {
                "id": "doc-1",
                "filename": "resume.docx",
                "status": "done",
                "ocr_output": {"processing_method": "local"},
            })

        self.assertEqual(result["processingMethod"], "local")
        self.assertEqual(result["contextItemsCreated"], 3)


if __name__ == "__main__":
    unittest.main(verbosity=2)
