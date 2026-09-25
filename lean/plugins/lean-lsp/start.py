"""The lean-lsp plugin's MCP server: lean-lsp-mcp on the project Claude Code was
started in. When that project runs on the Lean image's Mathlib, lean_loogle
searches with the image's prebuilt Loogle and index (see lean/Dockerfile)
rather than loogle.lean-lang.org and its 3 queries per 30 s.

lean-lsp-mcp looks for Loogle under names of its own: the checkout under its
pinned Loogle commit and a hash of the project's toolchain, the index under a
hash of the project's path. Rather than copy that scheme, this asks its own
LoogleManager for both paths and links them to the image's, then runs
lean-lsp-mcp in this process so that two of LoogleManager's methods can be
replaced. Local Loogle is only turned on once all of that has worked.
Otherwise lean-lsp-mcp would clone and build Loogle, and index Mathlib, before
answering anything.

stdout is the MCP channel, so nothing here may print to it.
"""
import os
import sys
from pathlib import Path

LOOGLE = Path("/opt/lean/loogle")
IMAGE = Path("/opt/lean/project")


def use_image_loogle(proj: Path) -> None:
    binary = LOOGLE / ".lake/build/bin/loogle"
    index = LOOGLE / "mathlib.idx"
    if not (binary.is_file() and index.is_file()):
        return
    # The index is of the image's Mathlib, so the project has to run on it.
    packages = proj / ".lake/packages"
    if not packages.is_symlink() or os.readlink(packages) != str(IMAGE / ".lake/packages"):
        return
    if (proj / "lean-toolchain").read_text() != (IMAGE / "lean-toolchain").read_text():
        return

    from lean_lsp_mcp.file_utils import require_lean_project_path
    from lean_lsp_mcp.loogle import LoogleManager

    # lean-lsp-mcp only uses a Loogle checkout that is a git clone at its
    # pinned commit, and it runs `git checkout` in it first. The image's copy
    # has no .git and is read-only, and nothing needs cloning. If a newer
    # lean-lsp-mcp lacks either method replaced here, it keeps remote Loogle.
    if not all(callable(getattr(LoogleManager, f, None)) for f in ("_clone_repo", "start")):
        return
    cache = Path(os.environ.get("TMPDIR", "/tmp")) / f"lean-loogle-{os.getuid()}"
    m = LoogleManager(cache_dir=cache, project_path=require_lean_project_path(proj))
    for link, target in ((m.repo_dir, LOOGLE), (m.index_path, index)):
        link.parent.mkdir(parents=True, exist_ok=True)
        # Replaced atomically, so two sessions starting at once cannot trip
        # over each other.
        tmp = link.with_name(f"{link.name}.{os.getpid()}")
        tmp.symlink_to(target)
        os.replace(tmp, link)
    LoogleManager._clone_repo = lambda self: True

    # lean-lsp-mcp also starts Loogle before it answers Claude Code at all.
    # Loading Mathlib and the index takes 5 s warm and 30 s cold, which is
    # close to where Claude Code gives up on a server. The process then holds
    # 7 GB whether the session searches or not. query() starts Loogle when it
    # is not running, so the start at launch is skipped and the first
    # lean_loogle call pays for it instead.
    start = LoogleManager.start

    async def start_on_first_query(self):
        if not getattr(self, "_start_skipped", False):
            self._start_skipped = True
            return True
        return await start(self)

    LoogleManager.start = start_on_first_query
    os.environ.update(LEAN_LOOGLE_LOCAL="true", LEAN_LOOGLE_CACHE_DIR=str(cache))


proj = Path(os.environ.get("CLAUDE_PROJECT_DIR") or os.getcwd())
if (proj / "lean-toolchain").is_file():
    os.environ["LEAN_PROJECT_PATH"] = str(proj)
    try:
        use_image_loogle(proj)
    except Exception as e:
        print(f"lean-lsp: not using the image's Loogle: {e!r}", file=sys.stderr)

from lean_lsp_mcp import main  # noqa: E402  (after the patch above)

sys.exit(main())
