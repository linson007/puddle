#!/usr/bin/env python3
"""Verify local roadmap gates using an already running Splash and configured Cua Driver.

Uses synthetic data only. Does not install models, sign in, grant permissions,
record live audio, stop the user's model server, or publish a release.
"""
import argparse
import hashlib
import http.client
import json
import os
from pathlib import Path
import selectors
import subprocess
import sys
import time
from urllib.parse import urlparse


def local_get(port, path):
    connection = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
    try:
        connection.request("GET", path)
        response = connection.getresponse()
        if response.status != 200:
            raise RuntimeError(f"Loopback {path} returned HTTP {response.status}")
        return response.read(2 * 1024 * 1024)
    finally:
        connection.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--driver", type=Path, default=Path("/Applications/CuaDriver.app/Contents/MacOS/cua-driver"))
    args = parser.parse_args()
    repo = Path(__file__).resolve().parent.parent
    driver = args.driver.resolve(strict=True)
    if not driver.is_file() or not os.access(driver, os.X_OK):
        raise RuntimeError("Choose an installed, already configured Cua Driver executable.")
    local_get(8000, "/ready")  # Fail before running suites if the owner's server is unavailable.
    os.umask(0o077)
    output = (args.output or repo / "build" / (time.strftime("local-%Y%m%dT%H%M%SZ", time.gmtime()) + f"-{os.getpid()}")).resolve()
    output.mkdir(parents=True, exist_ok=False)
    environment = os.environ.copy()
    for key in ["PUDDLE_LOAD_PROFILE", "PUDDLE_LOAD_ITERATIONS", "PUDDLE_LOAD_EXPORT_FIXTURE", "PUDDLE_LOAD_SAVE_BUDGET_MS",
                "PUDDLE_GOOGLE_CLIENT_FILE", "PUDDLE_SIGNING_IDENTITY", "PUDDLE_BUILD_CONFIGURATION", "PUDDLE_ACCEPTANCE_OUTPUT_DIRECTORY",
                "PUDDLE_VERSION", "PUDDLE_BUILD_NUMBER", "PUDDLE_UPDATE_MANIFEST_URL", "PUDDLE_UPDATE_PUBLIC_KEY", "PUDDLE_MICROSOFT_CLIENT_ID"]:
        environment.pop(key, None)
    environment.update(PUDDLE_LIVE_SPLASH="1", PUDDLE_FILESYSTEM_TESTS="1", PUDDLE_LOAD_TESTS="1",
                       PUDDLE_CUA_DRIVER=str(driver), PUDDLE_CUA_LIVE="1", PUDDLE_LOAD_OUTPUT_DIRECTORY=str(output))
    results = []

    def run(name, command, extra=None):
        print(f"Checking {name}…", flush=True)
        with (output / f"{name}.log").open("wb") as log:
            result = subprocess.run(command, cwd=repo, env={**environment, **(extra or {})}, stdout=log, stderr=subprocess.STDOUT)
        results.append({"check": name, "exit_code": result.returncode})
        (output / "results.json").write_text(json.dumps(results, indent=2) + "\n")
        if result.returncode:
            raise RuntimeError(f"{name} failed; see {output / (name + '.log')}")
        print(f"PASS {name}", flush=True)

    print(f"Evidence: {output}", flush=True)
    for route, name in [("/status", "runtime-start.json"), ("/v1/models", "runtime-models.json")]:
        (output / name).write_bytes(local_get(8000, route))
    (output / "base-commit.txt").write_bytes(subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo))
    paths = ["Sources", "Tests", "scripts", "app", ".github", "docs", "README.md", "Makefile", "Package.swift"]
    files = subprocess.check_output(["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z", "--", *paths], cwd=repo).split(b"\0")
    (output / "source-sha256.txt").write_text("".join(hashlib.sha256((repo / item.decode()).read_bytes()).hexdigest() + "  " + item.decode() + "\n" for item in sorted(set(files)) if item and (repo / item.decode()).is_file()))
    patch = subprocess.check_output(["git", "diff", "--binary"], cwd=repo)
    for item in subprocess.check_output(["git", "ls-files", "--others", "--exclude-standard", "-z", "--", *paths], cwd=repo).split(b"\0"):
        if item:
            diff = subprocess.run(["git", "diff", "--binary", "--no-index", "--", "/dev/null", item.decode()], cwd=repo, capture_output=True)
            if diff.returncode not in (0, 1):
                raise RuntimeError("Could not preserve an untracked source file.")
            patch += diff.stdout
    (output / "working-tree.patch").write_bytes(patch)

    audio = output / "synthetic-speech.aiff"
    run("speech-fixture", ["/usr/bin/say", "-o", str(audio), "The orange folder is ready. The orange folder is ready."])
    environment["PUDDLE_LIVE_AUDIO_FILE"] = str(audio)
    fixture = subprocess.Popen([sys.executable, str(repo / "scripts/browser-acceptance.py")], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
    try:
        with selectors.DefaultSelector() as selector:
            selector.register(fixture.stdout, selectors.EVENT_READ)
            if not selector.select(timeout=10):
                raise RuntimeError("The disposable browser page did not start.")
            address = fixture.stdout.readline().strip()
        url = urlparse(address)
        if url.scheme != "http" or url.hostname != "127.0.0.1" or not url.port:
            raise RuntimeError("The disposable browser page returned an invalid loopback address.")
        environment["PUDDLE_CUA_LIVE_URL"] = address
        for build in ["debug", "release"]:
            run(build, ["sh", "scripts/swift.sh", "test"] + (["-c", "release"] if build == "release" else []),
                {"PUDDLE_LOAD_RUN": build, "PUDDLE_ACCEPTANCE_OUTPUT_DIRECTORY": str(output / (build + "-workflows"))})
        for name, extra in [("heavy", {"PUDDLE_LOAD_PROFILE": "heavy"}),
                            ("endurance", {"PUDDLE_LOAD_PROFILE": "long", "PUDDLE_LOAD_ITERATIONS": "1000"})]:
            run(name, ["sh", "scripts/swift.sh", "test", "-c", "release", "--filter", "WorkspaceLoadTests"], {"PUDDLE_LOAD_RUN": "release", **extra})
        browser = local_get(url.port, "/state")
        (output / "browser-state.json").write_bytes(browser)
        if json.loads(browser).get("events"):
            raise RuntimeError("The read/navigation browser check unexpectedly recorded input events.")
        run("build", ["sh", "scripts/build.sh"], {"PUDDLE_BUILD_CONFIGURATION": "release"})
        run("bundle", [sys.executable, "scripts/verify-bundle.py"])
        run("whitespace", ["git", "diff", "--check"])
        (output / "runtime-end.json").write_bytes(local_get(8000, "/status"))
        print("Local roadmap checks passed. Native permissions/devices, accounts, advertised model/hardware coverage and public signing remain separate.", flush=True)
    finally:
        fixture.terminate()
        try:
            fixture.wait(timeout=5)
        except subprocess.TimeoutExpired:
            fixture.kill(); fixture.wait(timeout=5)
        fixture.stdout.close()


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as error:
        sys.exit(f"Local verification failed: {error}")
