"""The Brainbox workspace: the only part of the server's filesystem the app can see.

    <root>/inbox/    files sent from the phone (attachments, uploads)
    <root>/outbox/   files the agent leaves for the phone to download

Every path the app sends is relative to ``<root>`` and must start with one of those two
areas. Absolute paths, ``..``, backslashes, NUL/control characters, hidden names and
symlinks (anywhere along the path) are refused, and the resolved real path must stay inside
the root. Uploads stream to a temporary file with a hard byte limit and an extension
allow-list, then get a sanitized, non-clobbering name. Nothing here executes anything.
"""
from __future__ import annotations

import mimetypes
import os
import re
import secrets
import stat
import time
import unicodedata
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

AREAS = ("inbox", "outbox")
DEFAULT_EXTENSIONS = (
    # images
    "png", "jpg", "jpeg", "gif", "webp", "heic", "heif",
    # documents / data
    "pdf", "txt", "md", "csv", "tsv", "json", "yaml", "yml", "toml", "xml", "html", "log",
    "docx", "xlsx", "pptx", "rtf", "odt", "ods",
    # code (as text; never executed by the gateway)
    "py", "js", "ts", "swift", "go", "rs", "java", "kt", "c", "h", "cpp", "rb", "php", "sh", "sql", "css",
    # archives / media
    "zip", "tar", "gz", "mp3", "m4a", "wav", "mp4", "mov",
)
MAX_NAME = 120
_UNSAFE_CHARS = re.compile(r"[^\w .()+,@-]", re.UNICODE)


class WorkspaceError(Exception):
    def __init__(self, status: int, code: str, message: str) -> None:
        super().__init__(message)
        self.status = status
        self.code = code
        self.message = message


@dataclass
class WorkspaceConfig:
    enabled: bool = True
    root: str = "/var/lib/brainbox-gateway/workspace"
    max_upload_bytes: int = 25_000_000
    allowed_extensions: tuple[str, ...] = field(default=DEFAULT_EXTENSIONS)

    @staticmethod
    def from_dict(raw: dict[str, Any], state_dir: str) -> "WorkspaceConfig":
        exts = raw.get("allowed_extensions", list(DEFAULT_EXTENSIONS))
        if not isinstance(exts, list) or not all(isinstance(e, str) and re.fullmatch(r"[a-z0-9]{1,10}", e) for e in exts):
            raise ValueError("files.allowed_extensions must be a list of lowercase extensions without dots")
        size = int(raw.get("max_upload_bytes", 25_000_000))
        if not 1 <= size <= 2_000_000_000:
            raise ValueError("files.max_upload_bytes must be between 1 and 2000000000")
        return WorkspaceConfig(enabled=bool(raw.get("enabled", True)),
                               root=str(raw.get("root", str(Path(state_dir) / "workspace"))),
                               max_upload_bytes=size, allowed_extensions=tuple(exts))


def safe_name(name: str) -> str:
    """A plain file name: last path component only, NFC, no control or shell-special
    characters, no leading dots, at most MAX_NAME characters (extension kept)."""
    name = unicodedata.normalize("NFC", str(name or ""))
    name = name.replace("\\", "/").split("/")[-1]
    name = "".join(ch for ch in name if unicodedata.category(ch)[0] != "C")
    name = _UNSAFE_CHARS.sub("_", name).strip().lstrip(".").strip()
    name = re.sub(r"_{2,}", "_", name)
    if len(name) > MAX_NAME:
        stem, dot, ext = name.rpartition(".")
        if dot and 0 < len(ext) <= 10:
            name = stem[: MAX_NAME - len(ext) - 1] + "." + ext
        else:
            name = name[:MAX_NAME]
    if name in ("", ".", ".."):
        raise WorkspaceError(400, "invalid_name", "That file name can't be used.")
    return name


def extension(name: str) -> str:
    stem, dot, ext = name.rpartition(".")
    return ext.lower() if dot and stem else ""


class Workspace:
    def __init__(self, cfg: WorkspaceConfig) -> None:
        self.cfg = cfg
        self.root = Path(cfg.root)

    # -- setup -------------------------------------------------------------------

    def ensure(self) -> None:
        self.root.mkdir(parents=True, exist_ok=True, mode=0o750)
        for area in AREAS:
            (self.root / area).mkdir(exist_ok=True, mode=0o750)

    def _real_root(self) -> Path:
        try:
            self.ensure()
            real = self.root.resolve(strict=True)
        except OSError as exc:
            raise WorkspaceError(503, "workspace_unavailable", "The Brainbox workspace folder isn't available.") from exc
        if self.root.is_symlink():
            raise WorkspaceError(503, "workspace_unavailable", "The workspace root must not be a symlink.")
        return real

    # -- path validation -----------------------------------------------------------

    def resolve(self, rel: str, *, must_exist: bool = True) -> tuple[Path, list[str]]:
        """Validated absolute path for ``rel`` (e.g. ``inbox/report.pdf``)."""
        if not isinstance(rel, str) or len(rel) > 1024 or "\x00" in rel or "\\" in rel or rel.startswith("/"):
            raise WorkspaceError(400, "invalid_path", "Invalid path.")
        parts = [p for p in rel.split("/") if p not in ("",)]
        if not parts or parts[0] not in AREAS:
            raise WorkspaceError(400, "invalid_path", "Paths must start with inbox/ or outbox/.")
        for part in parts:
            if part in (".", "..") or part.startswith(".") or any(unicodedata.category(c)[0] == "C" for c in part):
                raise WorkspaceError(400, "invalid_path", "Invalid path.")
        root = self._real_root()
        current = root
        for i, part in enumerate(parts):
            current = current / part
            try:
                st = os.lstat(current)
            except FileNotFoundError:
                if must_exist or i < len(parts) - 1:
                    raise WorkspaceError(404, "not_found", "No such file in the workspace.")
                break
            if stat.S_ISLNK(st.st_mode):
                raise WorkspaceError(403, "symlink_refused", "Links aren't followed in the workspace.")
        real = current.resolve(strict=False)
        if real != root and root not in real.parents:
            raise WorkspaceError(403, "outside_workspace", "That path is outside the Brainbox workspace.")
        return current, parts

    # -- operations ------------------------------------------------------------------

    def _entry(self, path: Path, rel: str) -> dict[str, Any] | None:
        try:
            st = os.lstat(path)
        except OSError:
            return None
        if stat.S_ISLNK(st.st_mode) or path.name.startswith("."):
            return None
        is_dir = stat.S_ISDIR(st.st_mode)
        if not is_dir and not stat.S_ISREG(st.st_mode):
            return None
        return {"name": path.name, "path": rel, "kind": "directory" if is_dir else "file",
                "size": None if is_dir else st.st_size, "modified": round(st.st_mtime, 3),
                "mime": None if is_dir else (mimetypes.guess_type(path.name)[0] or "application/octet-stream")}

    def list(self, rel: str) -> list[dict[str, Any]]:
        if rel.strip("/") == "":
            self._real_root()
            return [e for a in AREAS if (e := self._entry(self.root / a, a))]
        path, parts = self.resolve(rel)
        if not path.is_dir():
            raise WorkspaceError(400, "not_a_directory", "That path is a file.")
        prefix = "/".join(parts)
        entries = [e for child in path.iterdir() if (e := self._entry(child, f"{prefix}/{child.name}"))]
        return sorted(entries, key=lambda e: (e["kind"] != "directory", e["name"].lower()))

    def file_for_download(self, rel: str) -> tuple[Path, int]:
        path, _ = self.resolve(rel)
        st = os.lstat(path)
        if not stat.S_ISREG(st.st_mode):
            raise WorkspaceError(400, "not_a_file", "Only files can be downloaded.")
        return path, st.st_size

    def delete(self, rel: str) -> None:
        path, parts = self.resolve(rel)
        if len(parts) < 2:
            raise WorkspaceError(400, "invalid_path", "The inbox and outbox folders themselves can't be deleted.")
        if not stat.S_ISREG(os.lstat(path).st_mode):
            raise WorkspaceError(400, "not_a_file", "Only files can be deleted here.")
        path.unlink()

    def check_upload(self, area: str, name: str, declared_size: int | None) -> tuple[Path, str]:
        if area not in AREAS or area != "inbox":
            raise WorkspaceError(400, "invalid_area", "Uploads go to the inbox.")
        clean = safe_name(name)
        ext = extension(clean)
        if ext not in self.cfg.allowed_extensions:
            raise WorkspaceError(415, "type_not_allowed", f"“.{ext or '?'}” files aren't accepted. Allowed: {', '.join(self.cfg.allowed_extensions)}.")
        if declared_size is not None and declared_size > self.cfg.max_upload_bytes:
            raise WorkspaceError(413, "too_large", f"Files can be at most {self.cfg.max_upload_bytes // 1_000_000} MB.")
        directory, _ = self.resolve(area)
        return directory, clean

    def temp_upload(self, directory: Path) -> tuple[Path, int]:
        tmp = directory / f".upload-{secrets.token_hex(8)}"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_NOFOLLOW", 0), 0o640)
        return tmp, fd

    def finish_upload(self, tmp: Path, directory: Path, clean: str) -> dict[str, Any]:
        stem, dot, ext = clean.rpartition(".")
        if not dot:
            stem, ext = clean, ""
        for n in range(1, 1000):
            candidate = clean if n == 1 else f"{stem} ({n}){'.' + ext if ext else ''}"
            target = directory / candidate
            try:
                os.link(tmp, target)  # atomic, never overwrites an existing file
            except FileExistsError:
                continue
            os.unlink(tmp)
            entry = self._entry(target, f"{directory.name}/{candidate}")
            assert entry is not None
            return entry
        os.unlink(tmp)
        raise WorkspaceError(409, "name_conflict", "Too many files with that name.")

    def sweep_temp(self, max_age: float = 3600) -> None:
        now = time.time()
        for area in AREAS:
            try:
                for child in (self.root / area).iterdir():
                    if child.name.startswith(".upload-") and now - child.lstat().st_mtime > max_age:
                        child.unlink(missing_ok=True)
            except OSError:
                continue
