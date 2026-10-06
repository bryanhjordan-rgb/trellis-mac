#!/usr/bin/env bash
#
# Guided installer for trellis-mac on Apple Silicon.
#
# Wraps setup.sh with preflight checks (hardware, macOS, disk, toolchain),
# HuggingFace login + gated-model access checks, and post-install
# verification. Safe to re-run: every step checks state before acting.
#
# Usage:
#   bash scripts/install_mac.sh [--yes] [--skip-metal] [--smoke-test]
#
#   --yes         Never prompt. Fails instead of asking (for scripted/agent runs).
#   --skip-metal  Skip building the Metal backends (pure-Python fallbacks).
#   --smoke-test  After install, generate a mesh from assets/shoe_input.png.
#                 First run downloads ~15GB of weights and takes several minutes.
#
# Environment:
#   HF_TOKEN      HuggingFace access token. Used for non-interactive login.
#
# Exit status is 0 on success, 1 on any failed check. Every failure prints a
# "FIX:" line describing the next action.
#
# Must stay compatible with macOS's /bin/bash 3.2.

set -euo pipefail
cd "$(dirname "$0")/.."

ORIG_ARGS="${*:-}"
ASSUME_YES=0
SKIP_METAL="${SKIP_METAL:-0}"
SMOKE_TEST=0
for arg in "$@"; do
    case "$arg" in
        --yes) ASSUME_YES=1 ;;
        --skip-metal) SKIP_METAL=1 ;;
        --smoke-test) SMOKE_TEST=1 ;;
        -h|--help) sed -n '3,21p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) echo "Unknown option: $arg (see --help)"; exit 1 ;;
    esac
done

GATED_REPOS="facebook/dinov3-vitl16-pretrain-lvd1689m briaai/RMBG-2.0 microsoft/TRELLIS.2-4B"
WARNINGS=""

step() { echo; echo "==> [$1/7] $2"; }
ok()   { echo "    ok: $*"; }
warn() { echo "    WARN: $*"; WARNINGS="${WARNINGS}  - $*
"; }
fail() {
    echo "    FAIL: $1"
    [ -n "${2:-}" ] && echo "    FIX:  $2"
    exit 1
}
interactive() { [ "$ASSUME_YES" = "0" ] && [ -t 0 ]; }

# ---------------------------------------------------------------------------
step 1 "Hardware and OS"
# ---------------------------------------------------------------------------
[ "$(uname -s)" = "Darwin" ] || fail "Not macOS ($(uname -s))." "Run this on an Apple Silicon Mac."

if [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" != "1" ]; then
    fail "Intel Mac detected. This port needs Apple Silicon (M1 or later)." \
         "No workaround; MPS on Intel Macs is not supported by this project."
fi
if [ "$(uname -m)" != "arm64" ]; then
    fail "Shell is running under Rosetta (x86_64) on an Apple Silicon Mac." \
         "Re-run natively: arch -arm64 bash scripts/install_mac.sh $ORIG_ARGS"
fi
ok "chip: $(sysctl -n machdep.cpu.brand_string)"

MACOS_VER="$(sw_vers -productVersion)"
MACOS_MAJOR="${MACOS_VER%%.*}"
MACOS_MINOR="$(echo "$MACOS_VER" | cut -d. -f2)"
if [ "$MACOS_MAJOR" -lt 12 ] || { [ "$MACOS_MAJOR" -eq 12 ] && [ "${MACOS_MINOR:-0}" -lt 3 ]; }; then
    fail "macOS $MACOS_VER is too old; PyTorch MPS needs 12.3+." "Update macOS."
fi
ok "macOS $MACOS_VER"
if [ "$MACOS_MAJOR" -lt 26 ]; then
    warn "macOS < 26: the mtlgemm (flex_gemm) metallib will not load, so sparse conv uses the slower conv_none path. Generation still works."
fi

MEM_GB=$(( $(sysctl -n hw.memsize) / 1073741824 ))
if [ "$MEM_GB" -lt 16 ]; then
    fail "${MEM_GB}GB unified memory. Generation peaks around 18GB." "Use a Mac with 24GB+."
elif [ "$MEM_GB" -lt 24 ]; then
    warn "${MEM_GB}GB unified memory is below the recommended 24GB; expect heavy swapping or OOM."
else
    ok "memory: ${MEM_GB}GB"
fi

FREE_GB=$(df -Pk . | awk 'NR==2 { print int($4 / 1048576) }')
if [ "$FREE_GB" -lt 20 ]; then
    fail "${FREE_GB}GB free disk. Need ~25GB (15GB weights + venv + deps)." "Free up disk space."
elif [ "$FREE_GB" -lt 30 ]; then
    warn "${FREE_GB}GB free disk; ~25GB will be used."
else
    ok "free disk: ${FREE_GB}GB"
fi

# ---------------------------------------------------------------------------
step 2 "Developer tools"
# ---------------------------------------------------------------------------
xcode-select -p >/dev/null 2>&1 \
    || fail "Xcode Command Line Tools not installed (needed for git and compilers)." \
            "Run: xcode-select --install   then re-run this script."
ok "developer dir: $(xcode-select -p)"

if command -v uv >/dev/null 2>&1; then
    ok "uv $(uv --version | awk '{print $2}')"
elif command -v brew >/dev/null 2>&1; then
    echo "    installing uv via Homebrew..."
    brew install uv
    ok "uv installed"
elif python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' 2>/dev/null; then
    ok "uv not found; using python3 $(python3 -c 'import platform; print(platform.python_version())')"
else
    fail "Need uv or Python 3.11+ (macOS ships 3.9)." \
         "Install Homebrew (https://brew.sh) and re-run, or: brew install uv"
fi

# ---------------------------------------------------------------------------
step 3 "Metal toolchain"
# ---------------------------------------------------------------------------
metal_ok() { xcrun -sdk macosx metal --version >/dev/null 2>&1; }

if [ "$SKIP_METAL" = "1" ]; then
    warn "Metal backends skipped by request; using slower pure-Python fallbacks."
elif metal_ok; then
    ok "metal compiler available"
elif xcodebuild -version >/dev/null 2>&1; then
    echo "    downloading Metal Toolchain (one-time)..."
    if xcodebuild -downloadComponent MetalToolchain && metal_ok; then
        ok "Metal Toolchain installed"
    else
        warn "Metal Toolchain download failed; continuing without Metal backends."
        SKIP_METAL=1
    fi
else
    warn "Full Xcode not installed (only Command Line Tools); continuing without Metal backends. Install Xcode from the App Store and re-run to enable them."
    SKIP_METAL=1
fi

# ---------------------------------------------------------------------------
step 4 "Run setup.sh (venv, dependencies, TRELLIS.2 clone + patches)"
# ---------------------------------------------------------------------------
SKIP_METAL="$SKIP_METAL" bash setup.sh

PY=".venv/bin/python"
[ -x "$PY" ] || fail "setup.sh did not create .venv." "Check the setup.sh output above."

# ---------------------------------------------------------------------------
step 5 "Verify Python environment"
# ---------------------------------------------------------------------------
"$PY" -c 'import sys; sys.exit(0 if sys.version_info >= (3, 11) else 1)' \
    || fail "venv Python is $("$PY" -V 2>&1); need 3.11+." \
            "rm -rf .venv && brew install uv && re-run this script."
ok "$("$PY" -V 2>&1)"

"$PY" - <<'EOF' || fail "PyTorch MPS backend unavailable." "Confirm native arm64 Python: $PY -c 'import platform; print(platform.machine())'"
import torch, sys
print(f"    ok: torch {torch.__version__}")
sys.exit(0 if torch.backends.mps.is_available() else 1)
EOF
ok "MPS available"

[ -d TRELLIS.2 ] && [ -d stubs ] || fail "TRELLIS.2/ or stubs/ missing after setup." "rm -rf deps TRELLIS.2 && re-run."
ok "TRELLIS.2 cloned and patched"

if [ "$SKIP_METAL" != "1" ]; then
    "$PY" - <<'EOF' || true
import importlib
for mod in ("mtlbvh", "mtldiffrast", "cumesh", "o_voxel.postprocess", "flex_gemm"):
    try:
        importlib.import_module(mod)
        print(f"    ok: {mod}")
    except Exception as e:
        print(f"    WARN: {mod} unavailable ({type(e).__name__}: {str(e).splitlines()[0][:100]}); fallback will be used")
EOF
fi

# ---------------------------------------------------------------------------
step 6 "HuggingFace login and gated model access"
# ---------------------------------------------------------------------------
hf_logged_in() { "$PY" -c 'from huggingface_hub import get_token; import sys; sys.exit(0 if get_token() else 1)' 2>/dev/null; }

if hf_logged_in; then
    ok "already logged in"
elif [ -n "${HF_TOKEN:-}" ]; then
    "$PY" -c 'import os; from huggingface_hub import login; login(token=os.environ["HF_TOKEN"])' \
        || fail "HF_TOKEN was rejected." "Create a read token at https://huggingface.co/settings/tokens"
    ok "logged in with HF_TOKEN"
elif interactive; then
    echo "    Paste a read token from https://huggingface.co/settings/tokens"
    "$PY" -c 'from huggingface_hub import login; login()'
    hf_logged_in || fail "Login did not complete." "Re-run and paste a valid token."
    ok "logged in"
else
    fail "Not logged into HuggingFace." \
         "Re-run with HF_TOKEN=hf_xxx (token from https://huggingface.co/settings/tokens)."
fi

# shellcheck disable=SC2086
"$PY" - $GATED_REPOS <<'EOF' || fail "Missing access to one or more gated models (listed above)." \
    "Open each URL above while logged in, click 'Agree and access', wait for approval, then re-run."
import sys
try:
    from huggingface_hub.errors import GatedRepoError, RepositoryNotFoundError
except ImportError:
    from huggingface_hub.utils import GatedRepoError, RepositoryNotFoundError
try:
    from huggingface_hub import auth_check
except ImportError:
    auth_check = None
from huggingface_hub import hf_hub_download

missing = False
for repo in sys.argv[1:]:
    try:
        if auth_check:
            auth_check(repo)
        else:
            hf_hub_download(repo, "config.json")
        print(f"    ok: {repo}")
    except (GatedRepoError, RepositoryNotFoundError):
        print(f"    NO ACCESS: {repo} -> https://huggingface.co/{repo}")
        missing = True
    except Exception as e:
        print(f"    WARN: could not verify {repo} ({type(e).__name__}); continuing")
sys.exit(1 if missing else 0)
EOF

# ---------------------------------------------------------------------------
step 7 "Smoke test"
# ---------------------------------------------------------------------------
if [ "$SMOKE_TEST" = "1" ]; then
    echo "    generating from assets/shoe_input.png (first run downloads ~15GB)..."
    rm -f smoke_test.glb
    "$PY" generate.py assets/shoe_input.png --output smoke_test \
        || fail "generate.py failed." "See the error above; the README's Limitations section covers GPU-watchdog failures."
    [ -s smoke_test.glb ] || fail "smoke_test.glb was not written." "See the generate.py output above."
    ok "wrote $(pwd)/smoke_test.glb"
else
    echo "    skipped (pass --smoke-test to run one generation)"
fi

echo
echo "=== Install complete ==="
if [ -n "$WARNINGS" ]; then
    echo "Warnings:"
    printf "%s" "$WARNINGS"
fi
echo
echo "Run:"
echo "  cd $(pwd)"
echo "  source .venv/bin/activate"
echo "  python generate.py path/to/image.png --output my_model"
