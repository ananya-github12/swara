"""Push-to-talk speech endpoints backed by Sarvam."""

from __future__ import annotations

import base64
import binascii
import re
import struct
from typing import Any

from fastapi import APIRouter, File, Form, HTTPException, UploadFile

from config import require
from schemas import SarvamLanguage, SpeechRequest, SpeechResponse, TranscriptResponse


router = APIRouter(prefix="/voice", tags=["voice"])

STT_MODEL = "saarika:v2.5"
TTS_MODEL = "bulbul:v2"
TTS_MAX_CHARS = 1_400
WAV_HEADER_BYTES = 44

_SENTENCE_BOUNDARY = re.compile(r"(?<=[.!?।])\s+")


def _sarvam_client() -> Any:
    try:
        from sarvamai import SarvamAI
    except ImportError as exc:
        raise RuntimeError(
            "Sarvam SDK is unavailable. Install server/requirements.txt."
        ) from exc
    return SarvamAI(api_subscription_key=require("SARVAM_API_KEY"))


def _split_oversized_part(text: str) -> list[str]:
    """Split one long sentence without exceeding Sarvam's safe request size."""
    chunks: list[str] = []
    remaining = text.strip()
    while len(remaining) > TTS_MAX_CHARS:
        split_at = remaining.rfind(" ", 0, TTS_MAX_CHARS + 1)
        if split_at <= 0:
            split_at = TTS_MAX_CHARS
        chunks.append(remaining[:split_at].strip())
        remaining = remaining[split_at:].strip()
    if remaining:
        chunks.append(remaining)
    return chunks


def _split_for_tts(text: str) -> list[str]:
    """Group sentences into requests below Sarvam's per-request text limit."""
    parts = [
        part.strip()
        for part in _SENTENCE_BOUNDARY.split(text.strip())
        if part.strip()
    ]
    chunks: list[str] = []
    current = ""

    for part in parts:
        if len(part) > TTS_MAX_CHARS:
            if current:
                chunks.append(current)
                current = ""
            chunks.extend(_split_oversized_part(part))
            continue

        candidate = f"{current} {part}".strip()
        if current and len(candidate) > TTS_MAX_CHARS:
            chunks.append(current)
            current = part
        else:
            current = candidate

    if current:
        chunks.append(current)
    return chunks


def _audio_values(response: Any) -> list[str]:
    """Normalise Sarvam's audio field when an SDK returns a list or a string."""
    audios = (
        response.get("audios")
        if isinstance(response, dict)
        else getattr(response, "audios", None)
    )
    if isinstance(audios, str):
        values = [audios]
    elif isinstance(audios, (list, tuple)):
        values = list(audios)
    else:
        raise ValueError("Sarvam returned no audio data.")

    if not values or any(not isinstance(value, str) or not value.strip() for value in values):
        raise ValueError("Sarvam returned invalid audio data.")
    return values


def _decode_audio(value: str) -> bytes:
    encoded = value.strip()
    if encoded.startswith("data:") and "," in encoded:
        encoded = encoded.split(",", 1)[1]
    encoded = re.sub(r"\s+", "", encoded)
    encoded += "=" * (-len(encoded) % 4)
    try:
        audio = base64.b64decode(encoded, validate=True)
    except (binascii.Error, ValueError) as exc:
        raise ValueError("Sarvam returned malformed base64 audio.") from exc
    if not audio:
        raise ValueError("Sarvam returned empty audio data.")
    return audio


def _join_wav_chunks(chunks: list[bytes]) -> bytes:
    """Join standard WAV outputs and keep only the first 44-byte header."""
    if not chunks:
        raise ValueError("Sarvam returned no audio data.")
    if len(chunks) == 1:
        return chunks[0]

    for chunk in chunks:
        if (
            len(chunk) < WAV_HEADER_BYTES
            or chunk[:4] != b"RIFF"
            or chunk[8:12] != b"WAVE"
        ):
            raise ValueError("Sarvam returned an invalid WAV audio chunk.")

    combined = bytearray(chunks[0])
    for chunk in chunks[1:]:
        combined.extend(chunk[WAV_HEADER_BYTES:])

    # Sarvam emits standard 44-byte WAV headers. Update their RIFF and data
    # lengths after adding the later chunks' PCM payloads.
    struct.pack_into("<I", combined, 4, len(combined) - 8)
    struct.pack_into("<I", combined, 40, len(combined) - WAV_HEADER_BYTES)
    return bytes(combined)


def _sarvam_content_type(content_type: str | None) -> str:
    """Reduce a browser MIME type to the bare type Sarvam will accept.

    MediaRecorder reports `audio/webm;codecs=opus`, but Sarvam matches its
    allowlist against the exact string and rejects anything carrying
    parameters. The base type is on the list, so drop the parameters.
    """
    base = (content_type or "").split(";", 1)[0].strip().lower()
    return base or "application/octet-stream"


@router.post("/stt", response_model=TranscriptResponse)
async def speech_to_text(
    file: UploadFile = File(...),
    language: SarvamLanguage = Form("unknown"),
) -> TranscriptResponse:
    """Transcribe an uploaded browser recording with Saarika."""
    try:
        content = await file.read()
        if not content:
            raise HTTPException(status_code=400, detail="The uploaded audio is empty.")

        sarvam = _sarvam_client()
        upload = (
            file.filename or "audio",
            content,
            _sarvam_content_type(file.content_type),
        )
        try:
            response = sarvam.speech_to_text.transcribe(
                file=upload,
                model=STT_MODEL,
                language_code=language,
            )
        except Exception as exc:
            raise HTTPException(
                status_code=502, detail=f"Speech transcription failed: {exc}"
            ) from exc

        transcript = (
            response.get("transcript")
            if isinstance(response, dict)
            else getattr(response, "transcript", None)
        )
        detected_language = (
            response.get("language_code")
            if isinstance(response, dict)
            else getattr(response, "language_code", None)
        )
        if not isinstance(transcript, str):
            raise HTTPException(
                status_code=502,
                detail="Speech transcription failed: Sarvam returned no transcript.",
            )
        return TranscriptResponse(
            transcript=transcript,
            language=detected_language if isinstance(detected_language, str) else None,
        )
    finally:
        await file.close()


@router.post("/tts", response_model=SpeechResponse)
def text_to_speech(request: SpeechRequest) -> SpeechResponse:
    """Synthesise text with Bulbul and return one playable WAV."""
    text = request.text.strip()
    if not text:
        raise HTTPException(status_code=400, detail="Text must not be empty.")
    if request.language == "unknown":
        raise HTTPException(
            status_code=400,
            detail="Text-to-speech requires an explicit target language.",
        )

    sarvam = _sarvam_client()
    decoded_chunks: list[bytes] = []
    try:
        for chunk in _split_for_tts(text):
            response = sarvam.text_to_speech.convert(
                text=chunk,
                model=TTS_MODEL,
                target_language_code=request.language,
            )
            decoded_chunks.extend(
                _decode_audio(value) for value in _audio_values(response)
            )
        audio = _join_wav_chunks(decoded_chunks)
    except Exception as exc:
        raise HTTPException(
            status_code=502, detail=f"Speech synthesis failed: {exc}"
        ) from exc

    return SpeechResponse(
        audio_base64=base64.b64encode(audio).decode("ascii"),
        mime_type="audio/wav",
    )
