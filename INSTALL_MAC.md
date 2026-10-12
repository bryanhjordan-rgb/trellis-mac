# Install guide (Apple Silicon)

This guide installs trellis-mac and runs TRELLIS.2 image-to-3D entirely on your Mac. After the one-time weight download, nothing goes to the cloud.

`scripts/install_mac.sh` does the work. It checks your hardware and tooling, runs `setup.sh`, logs into HuggingFace, checks access to the gated models, and verifies the result. You can re-run it as often as you like; each step checks what's already done before it acts.

## 1. Requirements

| | Minimum | Recommended |
|---|---|---|
| Chip | Apple Silicon (M1 or later) | M2 Pro / M3 Pro / M4 Pro or better |
| Unified memory | 16GB (expect swapping) | 24GB+ |
| macOS | 12.3 | 26+ (needed for the `mtlgemm` sparse-conv kernels; older versions fall back to `conv_none`) |
| Free disk | 20GB | 30GB+ |
| Tools | Xcode Command Line Tools, Homebrew | Full Xcode (for the Metal texture baker) |

To check your Mac, open Apple menu → About This Mac.

## 2. One-time manual steps (in a browser)

The installer can't do these for you:

1. Create a HuggingFace account at https://huggingface.co/join.
2. While logged in, open each gated model page and click **Agree and access**:
   - https://huggingface.co/facebook/dinov3-vitl16-pretrain-lvd1689m
   - https://huggingface.co/briaai/RMBG-2.0

   Approval is usually instant.
3. Create a **Read** token at https://huggingface.co/settings/tokens and copy it.

## 3. Prerequisites (Terminal)

```bash
xcode-select --install          # skip if already installed
# Homebrew, if missing: https://brew.sh
```

Optional, for the faster Metal texture baker: install **Xcode** from the App Store and open it once to accept the license. The installer downloads the Metal Toolchain itself. Without Xcode, the install still works and uses slower pure-Python fallbacks.

## 4. Install

```bash
git clone https://github.com/bryanhjordan-rgb/trellis-mac.git
cd trellis-mac
bash scripts/install_mac.sh --smoke-test
```

When asked, paste your HuggingFace token. `--smoke-test` generates `smoke_test.glb` from `assets/shoe_input.png` at the end. The first run downloads about 15GB of weights, so expect 15–30 minutes depending on your connection. Leave the flag off to skip the test.

To run without prompts:

```bash
HF_TOKEN=hf_xxx bash scripts/install_mac.sh --yes --smoke-test
```

### Flags

| Flag | Effect |
|---|---|
| `--yes` | Never prompts. Fails with a `FIX:` line instead of asking. |
| `--skip-metal` | Skips the Metal builds and uses pure-Python fallbacks. |
| `--smoke-test` | Runs one generation after install to confirm the whole pipeline works. |

## 5. Use

```bash
cd trellis-mac
source .venv/bin/activate
python generate.py path/to/image.png --output my_model
```

This writes `my_model.glb`, a textured mesh, and `my_model.obj`, the full-resolution geometry. Other options: `--seed`, `--pipeline-type 512|1024|1024_cascade`, `--texture-size 512|1024|2048`, `--no-texture`. Start with the defaults.

**Expected time:** about 5 minutes per image on an M4 Pro (24GB). Expect somewhat longer on M1/M2-generation chips. About 1m45s of each run is loading the model, which happens once per Python process. Runs slow down sharply when the Mac is hot, so let it cool between long sessions.

## 6. What the installer checks

| Step | Check | On failure |
|---|---|---|
| 1 | Apple Silicon, native arm64 shell (not Rosetta), macOS ≥ 12.3, RAM, free disk | Stops and prints a fix |
| 2 | Command Line Tools; installs `uv` via Homebrew so the venv gets Python 3.11 | Stops and prints a fix |
| 3 | Metal compiler; downloads the Metal Toolchain if Xcode is present | Warns, continues without Metal |
| 4 | Runs `setup.sh`: clones deps and TRELLIS.2, creates the venv, installs packages, applies MPS patches | Stops |
| 5 | Python ≥ 3.11, `torch.backends.mps.is_available()`, Metal package imports | Stops (Metal import failures only warn) |
| 6 | HuggingFace login; access to all three model repos | Stops and lists the URLs to request |
| 7 | Optional end-to-end generation | Stops |

## 7. Running the install with a local AI agent

The installer is built to be driven by a local coding agent (for example one backed by Ollama or LM Studio) as well as by hand:

- Exit code `0` means installed. `1` means a check failed.
- Every failure prints one `FAIL:` line and one `FIX:` line. The agent should apply the fix and re-run the same command.
- Re-running is safe. Finished steps are detected and skipped.
- `--yes` plus `HF_TOKEN` in the environment means nothing waits on keyboard input.

Prompt you can give the agent:

> In the `trellis-mac` directory, run `HF_TOKEN=$HF_TOKEN bash scripts/install_mac.sh --yes --smoke-test`. If it exits non-zero, read the `FAIL:` and `FIX:` lines, apply the fix if it only needs a terminal command, and re-run. If the fix needs a browser (HuggingFace model access) or the App Store (Xcode), stop and tell me. Report the final "Warnings:" block when it succeeds.

Don't paste your token into a prompt that a remote service will see. Export it in your shell (`export HF_TOKEN=...`) and let the agent reference `$HF_TOKEN`.

## 8. Troubleshooting

| Symptom | Fix |
|---|---|
| `Shell is running under Rosetta` | Open Terminal without "Open using Rosetta", or run `arch -arm64 bash scripts/install_mac.sh` |
| `NO ACCESS: facebook/...` or `briaai/...` | Request access in the browser (step 2), wait for approval, re-run |
| `xcodebuild: error: tool 'xcodebuild' requires Xcode` | Install full Xcode, or accept the fallback (`--skip-metal`) |
| Install looks inconsistent | `rm -rf deps TRELLIS.2 .venv` and re-run |
| `ERROR: The decoder produced an empty mesh` | The macOS GPU watchdog killed a Metal kernel. Disconnect external displays and close other GPU-heavy apps, or run with `SPARSE_CONV_BACKEND=none`. |
| Generation suddenly takes 30+ minutes | The Mac is throttling from heat. Let it cool and retry. |
| Memory pressure red in Activity Monitor | Close other apps; use `--pipeline-type 512` and `--texture-size 1024` |

## Licenses

RMBG-2.0 is CC BY-NC 4.0, which means non-commercial use only. DINOv3 has a custom Meta license. Review both before any commercial use. See the README for details.
