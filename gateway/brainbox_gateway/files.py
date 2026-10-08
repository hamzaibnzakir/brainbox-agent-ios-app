"""Sandboxed file access. Every path is resolved (symlinks and `..`
included) and must stay inside an allow-listed root. Roots themselves can't be
renamed or deleted; read-only roots reject every write."""
from __future__ import annotations

import os
import shutil
import stat
import time
from pathlib import Path

from .config import FileRoot
from .protocol import ProtocolError, iso

MAX_READ_BYTES = 2 * 1024 * 1024
MAX_SEARCH_RESULTS = 200
MAX_SEARCH_VISITS = 20_000


class FileSandbox:
    def __init__(self, roots: list[FileRoot]):
        self.roots = [(Path(os.path.realpath(r.path)), r.read_only) for r in roots]

    # ---------------------------------------------------------------- policy

    def _root_for(self, real: Path) -> tuple[Path, bool] | None:
        for root, ro in self.roots:
            if real == root or root in real.parents:
                return root, ro
        return None

    def resolve(self, path: str, *, writing: bool = False, must_exist: bool = True) -> Path:
        if not isinstance(path, str) or not path.startswith("/") or "\x00" in path:
            raise ProtocolError("permission_denied", "Paths must be absolute")
        candidate = Path(os.path.normpath(path))
        if must_exist:
            real = Path(os.path.realpath(candidate))
        else:
            # New entries: the parent must exist and resolve inside a root.
            real = Path(os.path.realpath(candidate.parent)) / candidate.name
        hit = self._root_for(real)
        if hit is None:
            raise ProtocolError("permission_denied", f"{path} is outside the folders the gateway exposes")
        if writing and hit[1]:
            raise ProtocolError("permission_denied", f"{path} is read-only")
        if must_exist and not real.exists():
            raise ProtocolError("not_found", path)
        return real

    def is_root(self, real: Path) -> bool:
        return any(real == root for root, _ in self.roots)

    def _entry(self, real: Path, shown: str | None = None) -> dict:
        st = real.stat()
        hit = self._root_for(real)
        read_only = bool(hit and hit[1]) or not os.access(real, os.W_OK)
        return {
            "path": shown or str(real),
            "isDirectory": stat.S_ISDIR(st.st_mode),
            "size": 0 if stat.S_ISDIR(st.st_mode) else st.st_size,
            "modifiedAt": iso(st.st_mtime),
            "permissions": stat.filemode(st.st_mode),
            "isReadOnly": read_only,
        }

    @staticmethod
    def version(real: Path) -> str:
        st = real.stat()
        return f"{st.st_mtime_ns}-{st.st_size}"

    # ---------------------------------------------------------------- operations

    def list_roots(self) -> list[dict]:
        return [self._entry(root) for root, _ in self.roots if root.exists()]

    def list(self, path: str) -> list[dict]:
        real = self.resolve(path)
        if not real.is_dir():
            raise ProtocolError("not_found", path)
        out = []
        for child in sorted(real.iterdir(), key=lambda p: p.name.lower())[:2000]:
            try:
                resolved = Path(os.path.realpath(child))
                if self._root_for(resolved) is None:
                    continue  # symlink escaping the sandbox: hide it
                out.append(self._entry(resolved, shown=str(child)))
            except OSError:
                continue
        return out

    def read(self, path: str) -> dict:
        real = self.resolve(path)
        if real.is_dir():
            raise ProtocolError("not_found", path)
        if real.stat().st_size > MAX_READ_BYTES:
            raise ProtocolError("permission_denied", "File is larger than 2 MB")
        data = real.read_bytes()
        if b"\x00" in data[:8192]:
            raise ProtocolError("permission_denied", "Binary files can't be opened in the editor")
        return {"path": path, "text": data.decode("utf-8", "replace"), "version": self.version(real)}

    def write(self, path: str, text: str, expected_version: str | None) -> dict:
        real = self.resolve(path, writing=True)
        if real.is_dir():
            raise ProtocolError("not_found", path)
        if expected_version and self.version(real) != expected_version:
            raise ProtocolError("conflict", path)
        mode = real.stat().st_mode
        tmp = real.with_name(f".{real.name}.bbtmp-{os.getpid()}")
        tmp.write_text(text, encoding="utf-8")
        os.chmod(tmp, stat.S_IMODE(mode))
        os.replace(tmp, real)
        return {"path": path, "text": text, "version": self.version(real)}

    def create(self, path: str, directory: bool) -> dict:
        name = os.path.basename(path.rstrip("/"))
        if not name or name in (".", "..") or "/" in name:
            raise ProtocolError("permission_denied", f"Invalid name: {name!r}")
        real = self.resolve(path, writing=True, must_exist=False)
        if not real.parent.is_dir():
            raise ProtocolError("not_found", str(real.parent))
        if real.exists():
            raise ProtocolError("permission_denied", f"{name} already exists")
        if directory:
            real.mkdir(mode=0o755)
        else:
            real.touch(mode=0o644, exist_ok=False)
        return self._entry(real)

    def rename(self, path: str, new_name: str) -> dict:
        if not new_name or new_name in (".", "..") or "/" in new_name or "\x00" in new_name:
            raise ProtocolError("permission_denied", f"Invalid name: {new_name!r}")
        real = self.resolve(path, writing=True)
        if self.is_root(real):
            raise ProtocolError("permission_denied", "Roots can't be renamed")
        dest = real.with_name(new_name)
        self.resolve(str(dest), writing=True, must_exist=False)
        if dest.exists():
            raise ProtocolError("permission_denied", f"{new_name} already exists")
        real.rename(dest)
        return self._entry(dest)

    def delete(self, path: str) -> None:
        real = self.resolve(path, writing=True)
        if self.is_root(real):
            raise ProtocolError("permission_denied", "Roots can't be deleted")
        if real.is_dir() and not real.is_symlink():
            shutil.rmtree(real)
        else:
            real.unlink()

    def search(self, query: str, path: str) -> list[dict]:
        q = query.strip().lower()
        if not q:
            return []
        base = self.resolve(path)
        results, visits = [], 0
        deadline = time.monotonic() + 5
        for dirpath, dirnames, filenames in os.walk(base, followlinks=False):
            dirnames[:] = [d for d in dirnames if d not in (".git", "node_modules", "__pycache__", ".venv", "venv")]
            for name in dirnames + filenames:
                visits += 1
                if q in name.lower():
                    results.append(self._entry(Path(dirpath) / name))
                    if len(results) >= MAX_SEARCH_RESULTS:
                        return results
            if visits > MAX_SEARCH_VISITS or time.monotonic() > deadline:
                break
        return results
