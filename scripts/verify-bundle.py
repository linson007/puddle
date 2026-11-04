#!/usr/bin/env python3
"""Check a local release bundle without accounts, a model, or publication."""
import argparse
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile


def run(command, *, expected=0):
    result = subprocess.run(command, capture_output=True, text=True, timeout=30)
    if result.returncode != expected:
        raise RuntimeError(f"{Path(command[0]).name} exited {result.returncode}, expected {expected}: "
                           + (result.stderr or result.stdout)[-2000:])
    return result


def verify(app):
    app = app.resolve(strict=True)
    info_path = app / "Contents/Info.plist"
    info = plistlib.loads(info_path.read_bytes())
    if any(key.startswith("PuddleUITest") for key in info):
        raise RuntimeError("The release bundle contains a UI fixture marker.")
    executable = app / "Contents/MacOS/Puddle"
    run(["/usr/bin/plutil", "-lint", str(info_path)])
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
    if info.get("CFBundleLocalizations") != ["en", "tr"]:
        raise RuntimeError("The app must declare English and Turkish localizations.")
    for locale in ("en", "tr"):
        if not list((app / "Contents/Resources").glob(f"Puddle_*.bundle/**/{locale}.lproj/Localizable.strings")):
            raise RuntimeError(f"The app is missing the {locale} localization resource.")
    print("PASS: bundle plist, localizations and code signature", flush=True)
    with tempfile.TemporaryDirectory(prefix="puddle-bundle-check-") as disposable:
        root = Path(disposable)

        def refusal(binary, workspace, *arguments):
            result = run([str(binary), *arguments, "--data-dir", str(root / "fallback")], expected=64)
            if "UI fixture mode requires a debug build" not in result.stderr:
                raise RuntimeError("Release fixture refusal did not explain the restriction.")
            if workspace.exists() or (root / "fallback").exists():
                raise RuntimeError("The release fixture check created workspace data.")

        workspace = root / "argument-workspace"
        refusal(executable, workspace, "--ui-test-workspace", str(workspace))
        print("PASS: release rejects fixture arguments before opening a workspace", flush=True)
        marked = root / "Puddle Guard Check.app"
        shutil.copytree(app, marked, symlinks=True)
        workspace = root / "marker-workspace"
        info["PuddleUITestWorkspace"] = str(workspace)
        info["CFBundleIdentifier"] = "app.puddle.bundle-check"
        (marked / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        # Only the disposable copy is re-signed after changing its fixture marker.
        run(["/usr/bin/codesign", "--force", "--sign", "-", str(marked)])
        refusal(marked / "Contents/MacOS/Puddle", workspace)
        print("PASS: release rejects a marker-only fixture before opening a workspace", flush=True)
    print("Local bundle checks passed. Developer ID, notarization and clean-Mac acceptance remain separate.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("app", nargs="?", type=Path,
                        default=Path(__file__).resolve().parent.parent / "build/Puddle.app")
    args = parser.parse_args()
    try:
        verify(args.app)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError, plistlib.InvalidFileException) as error:
        parser.exit(1, f"Bundle verification failed: {error}\n")
