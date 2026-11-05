#!/usr/bin/env python3
"""Check a local release bundle without accounts, a model, or publication."""
import argparse
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
from bundle_tools import read_plist
from localization_config import supported_locales


def run(command, *, expected=0):
    result = subprocess.run(command, capture_output=True, text=True, timeout=30)
    if result.returncode != expected:
        raise RuntimeError(f"{Path(command[0]).name} exited {result.returncode}, expected {expected}: "
                           + (result.stderr or result.stdout)[-2000:])
    return result


def verify_resource_inventory(resources, locales):
    allowed = {'Puddle.icns', 'Puddle_PuddleCore.bundle', 'GoogleClient.json'} | {f'{locale}.lproj' for locale in locales}
    unexpected = {path.name for path in resources.iterdir()} - allowed
    if unexpected:
        raise RuntimeError(f'Unexpected stale bundle resources: {sorted(unexpected)}')
    for path in resources.rglob('*.lproj'):
        if path.stem not in locales:
            raise RuntimeError(f'Unexpected stale locale: {path.name}')


def verify(app):
    app = app.resolve(strict=True)
    info_path = app / "Contents/Info.plist"
    info = read_plist(info_path.read_bytes())
    read_plist((Path(__file__).resolve().parent.parent / 'app/Info.plist').read_bytes())
    if any(key.startswith("PuddleUITest") for key in info):
        raise RuntimeError("The release bundle contains a UI fixture marker.")
    executable = app / "Contents/MacOS/Puddle"
    run(["/usr/bin/plutil", "-lint", str(info_path)])
    run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(app)])
    locales = supported_locales()
    if info.get("CFBundleLocalizations") != locales:
        raise RuntimeError("The app localizations must match Localization/locales.json.")
    resources = app / "Contents/Resources"
    verify_resource_inventory(resources, locales)
    for locale in locales:
        resources = app / "Contents/Resources"
        package_strings = list(resources.glob(f"Puddle_*.bundle/**/{locale}.lproj/Localizable.strings"))
        if not package_strings:
            raise RuntimeError(f"The app is missing the {locale} localization resource.")
        main_strings = resources / f"{locale}.lproj/Localizable.strings"
        expected = (Path(__file__).resolve().parent.parent /
                    f"Sources/PuddleCore/Resources/{locale}.lproj/Localizable.strings").read_bytes()
        if not main_strings.exists() or main_strings.read_bytes() != expected or any(path.read_bytes() != expected for path in package_strings):
            raise RuntimeError(f"The main and package {locale} localization resources must match the catalog export.")
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
