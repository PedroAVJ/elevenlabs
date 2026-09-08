#!/usr/bin/env python3
"""Transcribe audio or video using ElevenLabs Scribe."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import sys
from typing import Any, Dict, List, Optional

import requests

from credential_store import resolve_api_key

DEFAULT_MODEL = "scribe_v2"
DEFAULT_RESPONSE_FORMAT = "text"
DEFAULT_TIMEOUT = 1800
API_URL = "https://api.elevenlabs.io/v1/speech-to-text"
ALLOWED_RESPONSE_FORMATS = {"text", "json", "diarized_text", "segments_json"}


def _die(message: str, code: int = 1) -> None:
    print(f"Error: {message}", file=sys.stderr)
    raise SystemExit(code)


def _warn(message: str) -> None:
    print(f"Warning: {message}", file=sys.stderr)


def _normalize_response_format(value: Optional[str]) -> str:
    if not value:
        return DEFAULT_RESPONSE_FORMAT
    fmt = value.strip().lower()
    if fmt not in ALLOWED_RESPONSE_FORMATS:
        _die(
            "response-format must be one of: "
            + ", ".join(sorted(ALLOWED_RESPONSE_FORMATS))
        )
    return fmt


def _output_extension(response_format: str) -> str:
    return "txt" if response_format in {"text", "diarized_text"} else "json"


def _build_output_path(
    input_name: str,
    response_format: str,
    out: Optional[str],
    out_dir: Optional[str],
) -> Path:
    ext = "." + _output_extension(response_format)
    if out:
        path = Path(out)
        if path.exists() and path.is_dir():
            return path / f"{input_name}.transcript{ext}"
        if path.suffix == "":
            return path.with_suffix(ext)
        return path
    if out_dir:
        base = Path(out_dir)
        base.mkdir(parents=True, exist_ok=True)
        return base / f"{input_name}.transcript{ext}"
    return Path(f"{input_name}.transcript{ext}")


def _validate_audio(path: Path) -> None:
    if not path.exists():
        _die(f"Audio file not found: {path}")
    if not path.is_file():
        _die(f"Audio path is not a file: {path}")


def _format_timestamp(value: Optional[float]) -> str:
    if value is None:
        return "--:--:--.---"
    total_ms = int(round(value * 1000))
    hours, rem = divmod(total_ms, 3600 * 1000)
    minutes, rem = divmod(rem, 60 * 1000)
    seconds, millis = divmod(rem, 1000)
    return f"{hours:02d}:{minutes:02d}:{seconds:02d}.{millis:03d}"


def _speaker_label(word: Dict[str, Any]) -> str:
    speaker_id = word.get("speaker_id")
    if speaker_id:
        return str(speaker_id)
    channel_index = word.get("channel_index")
    if channel_index is not None:
        return f"channel_{channel_index}"
    return "speaker_unknown"


def _group_words_into_segments(words: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    segments: List[Dict[str, Any]] = []
    current: Optional[Dict[str, Any]] = None

    for word in words:
        text = str(word.get("text", ""))
        if not text:
            continue

        speaker = _speaker_label(word)
        start = word.get("start")
        end = word.get("end")
        gap_break = False

        if current and start is not None and current.get("end") is not None:
            gap_break = float(start) - float(current["end"]) > 1.2

        if (
            current is None
            or current["speaker_id"] != speaker
            or gap_break
        ):
            if current:
                current["text"] = "".join(current["parts"]).strip()
                current.pop("parts", None)
                segments.append(current)
            current = {
                "speaker_id": speaker,
                "start": start,
                "end": end,
                "parts": [text],
            }
        else:
            current["parts"].append(text)
            if end is not None:
                current["end"] = end

    if current:
        current["text"] = "".join(current["parts"]).strip()
        current.pop("parts", None)
        segments.append(current)

    return [segment for segment in segments if segment.get("text")]


def _format_text_output(result: Dict[str, Any]) -> str:
    if "text" in result and isinstance(result["text"], str):
        return result["text"].strip() + "\n"

    transcripts = result.get("transcripts")
    if isinstance(transcripts, list):
        blocks: List[str] = []
        for idx, item in enumerate(transcripts):
            if not isinstance(item, dict):
                continue
            text = str(item.get("text", "")).strip()
            if not text:
                continue
            blocks.append(f"[channel_{idx}]\n{text}")
        if blocks:
            return "\n\n".join(blocks) + "\n"

    return json.dumps(result, indent=2) + "\n"


def _format_diarized_text(result: Dict[str, Any]) -> str:
    segments = _group_words_into_segments(result.get("words", []))
    if not segments:
        return _format_text_output(result)
    lines = [
        f"[{_format_timestamp(segment.get('start'))}] {segment['speaker_id']}: {segment['text']}"
        for segment in segments
    ]
    return "\n".join(lines) + "\n"


def _format_segments_json(result: Dict[str, Any]) -> str:
    segments = _group_words_into_segments(result.get("words", []))
    return json.dumps(segments, indent=2) + "\n"


def _build_data(args: argparse.Namespace) -> List[tuple[str, str]]:
    data: List[tuple[str, str]] = [("model_id", args.model)]

    if args.language:
        data.append(("language_code", args.language))
    if args.timestamps_granularity:
        data.append(("timestamps_granularity", args.timestamps_granularity))
    if args.diarize:
        data.append(("diarize", "true"))
    if args.num_speakers is not None:
        data.append(("num_speakers", str(args.num_speakers)))
    if args.diarization_threshold is not None:
        data.append(("diarization_threshold", str(args.diarization_threshold)))
    if args.no_verbatim:
        data.append(("no_verbatim", "true"))
    if args.use_multi_channel:
        data.append(("use_multi_channel", "true"))
    if args.tag_audio_events is False:
        data.append(("tag_audio_events", "false"))
    if args.temperature is not None:
        data.append(("temperature", str(args.temperature)))
    if args.seed is not None:
        data.append(("seed", str(args.seed)))
    if args.file_format:
        data.append(("file_format", args.file_format))
    if args.source_url:
        data.append(("source_url", args.source_url))
    for keyterm in args.keyterm:
        data.append(("keyterms", keyterm))
    return data


def _cache_dir() -> Path:
    xdg = os.environ.get("XDG_CACHE_HOME")
    root = Path(xdg) if xdg else Path.home() / ".cache"
    return root / "elevenlabs-transcripts"


def _cache_key(
    path: Optional[Path],
    source_url: Optional[str],
    data: List[tuple[str, str]],
) -> str:
    # Key = request params + audio content, so a model/option change or a
    # re-recorded file misses; response_format is rendered locally and is
    # deliberately excluded — one API result serves every output format.
    hasher = hashlib.sha256()
    for key, value in sorted(data):
        hasher.update(f"{key}={value}\n".encode("utf-8"))
    if source_url:
        hasher.update(f"source_url={source_url}".encode("utf-8"))
    else:
        assert path is not None
        with path.open("rb") as handle:
            for chunk in iter(lambda: handle.read(1 << 20), b""):
                hasher.update(chunk)
    return hasher.hexdigest()


def _cache_read(key: str) -> Optional[Dict[str, Any]]:
    cache_path = _cache_dir() / f"{key}.json"
    if not cache_path.exists():
        return None
    try:
        return json.loads(cache_path.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        _warn(f"Ignoring unreadable cache entry: {cache_path}")
        return None


def _cache_write(key: str, result: Dict[str, Any]) -> None:
    try:
        cache_dir = _cache_dir()
        cache_dir.mkdir(parents=True, exist_ok=True)
        cache_path = cache_dir / f"{key}.json"
        cache_path.write_text(
            json.dumps(result, indent=2) + "\n", encoding="utf-8"
        )
    except OSError as exc:
        _warn(f"Could not write transcript cache: {exc}")


def _request_transcript(
    api_key: str,
    path: Optional[Path],
    data: List[tuple[str, str]],
    timeout_seconds: int,
) -> Dict[str, Any]:
    headers = {"xi-api-key": api_key}
    files = None

    if path is not None:
        file_handle = path.open("rb")
        files = {"file": (path.name, file_handle)}
    else:
        file_handle = None

    try:
        response = requests.post(
            API_URL,
            headers=headers,
            data=data,
            files=files,
            timeout=timeout_seconds,
        )
    finally:
        if file_handle is not None:
            file_handle.close()

    if response.status_code >= 400:
        detail = response.text.strip() or f"HTTP {response.status_code}"
        _die(f"ElevenLabs request failed: {detail}", code=2)

    try:
        return response.json()
    except json.JSONDecodeError as exc:
        _die(f"Response was not valid JSON: {exc}", code=2)
    return {}


def _get_transcript(
    path: Optional[Path],
    source_url: Optional[str],
    data: List[tuple[str, str]],
    timeout_seconds: int,
    use_cache: bool,
) -> Dict[str, Any]:
    key = _cache_key(path, source_url, data) if use_cache else None
    if key is not None:
        cached = _cache_read(key)
        if cached is not None:
            label = source_url or (path.name if path else "input")
            print(f"Cache hit for {label} (no API call).", file=sys.stderr)
            return cached
    api_key, _credential_source = resolve_api_key()
    if not api_key:
        _die(
            "ElevenLabs is not configured. Import an existing environment key "
            "with `elevenlabs auth import-environment`."
        )
    result = _request_transcript(api_key, path, data, timeout_seconds)
    if key is not None:
        _cache_write(key, result)
    return result


def _render_output(result: Dict[str, Any], response_format: str) -> str:
    if response_format == "text":
        return _format_text_output(result)
    if response_format == "diarized_text":
        return _format_diarized_text(result)
    if response_format == "segments_json":
        return _format_segments_json(result)
    return json.dumps(result, indent=2) + "\n"


def main() -> None:
    parser = argparse.ArgumentParser(
        description="Transcribe audio or video using ElevenLabs Scribe."
    )
    parser.add_argument("audio", nargs="*", help="Audio or video file(s) to transcribe")
    parser.add_argument(
        "--model",
        default=DEFAULT_MODEL,
        help=f"Model to use (default: {DEFAULT_MODEL})",
    )
    parser.add_argument(
        "--response-format",
        default=DEFAULT_RESPONSE_FORMAT,
        help="Output format: text, json, diarized_text, or segments_json",
    )
    parser.add_argument("--language", help="Optional language hint such as 'es'")
    parser.add_argument(
        "--diarize",
        action="store_true",
        help="Request speaker diarization",
    )
    parser.add_argument(
        "--num-speakers",
        type=int,
        help="Known maximum speaker count (1-32)",
    )
    parser.add_argument(
        "--diarization-threshold",
        type=float,
        help="Optional diarization threshold (only useful when num-speakers is omitted)",
    )
    parser.add_argument(
        "--timestamps-granularity",
        default="word",
        choices=["none", "word", "character"],
        help="Timestamp granularity in the API response",
    )
    parser.add_argument(
        "--keyterm",
        action="append",
        default=[],
        help="Bias transcription toward a domain term or phrase (repeatable)",
    )
    parser.add_argument(
        "--no-verbatim",
        action="store_true",
        help="Remove filler words and false starts (Scribe v2 only)",
    )
    parser.add_argument(
        "--use-multi-channel",
        action="store_true",
        help="Transcribe multi-channel audio per channel",
    )
    parser.add_argument(
        "--tag-audio-events",
        action=argparse.BooleanOptionalAction,
        default=True,
        help="Whether to include tagged non-speech audio events",
    )
    parser.add_argument(
        "--temperature",
        type=float,
        help="Optional transcription temperature",
    )
    parser.add_argument(
        "--seed",
        type=int,
        help="Optional deterministic sampling seed",
    )
    parser.add_argument(
        "--file-format",
        choices=["pcm_s16le_16", "other"],
        help="Explicitly declare the input audio encoding",
    )
    parser.add_argument(
        "--source-url",
        help="Hosted audio/video URL to transcribe instead of a local file",
    )
    parser.add_argument("--out", help="Output file path (single input only)")
    parser.add_argument("--out-dir", help="Output directory for transcripts")
    parser.add_argument(
        "--stdout",
        action="store_true",
        help="Also print transcript output to stdout",
    )
    parser.add_argument(
        "--no-cache",
        action="store_true",
        help="Bypass the local transcript cache (always call the API)",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print the request shape without sending it",
    )
    parser.add_argument(
        "--timeout-seconds",
        type=int,
        default=DEFAULT_TIMEOUT,
        help=f"Request timeout in seconds (default: {DEFAULT_TIMEOUT})",
    )

    args = parser.parse_args()
    args.response_format = _normalize_response_format(args.response_format)

    if args.num_speakers is not None and not 1 <= args.num_speakers <= 32:
        _die("--num-speakers must be between 1 and 32")
    if args.diarization_threshold is not None and args.num_speakers is not None:
        _warn("--diarization-threshold is only useful when --num-speakers is omitted")
    if args.source_url and args.audio:
        _die("Pass either local audio files or --source-url, not both")
    if not args.source_url and not args.audio:
        _die("Provide at least one audio/video file or --source-url")
    if args.out and (len(args.audio) > 1 or args.source_url):
        _die("--out supports a single input only")

    inputs = [Path(item) for item in args.audio]
    for path in inputs:
        _validate_audio(path)

    data = _build_data(args)

    if args.dry_run:
        preview = {
            "url": API_URL,
            "model_id": args.model,
            "inputs": [str(path) for path in inputs] or [args.source_url],
            "data": data,
        }
        print(json.dumps(preview, indent=2))
        return

    if args.source_url:
        result = _get_transcript(
            None, args.source_url, data, args.timeout_seconds, not args.no_cache
        )
        rendered = _render_output(result, args.response_format)
        output_path = _build_output_path("source-url", args.response_format, args.out, args.out_dir)
        output_path.write_text(rendered, encoding="utf-8")
        print(f"Wrote {output_path}", file=sys.stderr)
        if args.stdout:
            sys.stdout.write(rendered)
        return

    for path in inputs:
        result = _get_transcript(
            path, None, data, args.timeout_seconds, not args.no_cache
        )
        rendered = _render_output(result, args.response_format)
        output_path = _build_output_path(path.stem, args.response_format, args.out, args.out_dir)
        output_path.write_text(rendered, encoding="utf-8")
        print(f"Wrote {output_path}", file=sys.stderr)
        if args.stdout:
            sys.stdout.write(rendered)


if __name__ == "__main__":
    main()
