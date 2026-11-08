#!/usr/bin/env python3
"""Verify local roadmap gates using a chosen local model server and configured Cua Driver.

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


def inference_models(address, api_key):
    url = urlparse(address)
    if (url.scheme not in ("http", "https") or url.hostname not in ("127.0.0.1", "localhost", "::1")
            or url.username is not None or url.password is not None or url.query or url.fragment
            or url.path not in ("", "/", "/v1", "/v1/")):
        raise ValueError("Choose a loopback HTTP(S) server address, optionally ending in /v1.")
    connection_type = http.client.HTTPSConnection if url.scheme == "https" else http.client.HTTPConnection
    connection = connection_type("127.0.0.1" if url.hostname == "localhost" else url.hostname, url.port, timeout=10)
    try:
        headers = {"Authorization": f"Bearer {api_key}"} if api_key else {}
        connection.request("GET", "/v1/models", headers=headers)
        response = connection.getresponse()
        if response.status != 200:
            raise RuntimeError(f"Local model discovery returned HTTP {response.status}")
        data = response.read(2 * 1024 * 1024)
        if not json.loads(data).get("data"):
            raise RuntimeError("The local server lists no models. Load a chat model first.")
        return data
    finally:
        connection.close()


def validate_driver(driver, requirement):
    if not requirement or not requirement.strip():
        raise ValueError('Set --driver-requirement or PUDDLE_CUA_DRIVER_REQUIREMENT to the accepted helper identity.')
    driver = driver.resolve(strict=True)
    if not driver.is_file() or not os.access(driver, os.X_OK):
        raise ValueError('Choose an installed, executable Cua Driver.')
    result = subprocess.run(['/usr/bin/codesign', '--verify', '--strict', '-R', requirement, str(driver)],
                            capture_output=True, timeout=30)
    if result.returncode:
        raise ValueError('The driver does not satisfy its accepted code-signing identity.')
    return driver


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--driver", type=Path, default=Path("/Applications/CuaDriver.app/Contents/MacOS/cua-driver"))
    parser.add_argument("--driver-requirement", default=os.environ.get("PUDDLE_CUA_DRIVER_REQUIREMENT"), help="Accepted designated helper signing requirement")
    parser.add_argument("--server", default=os.environ.get("PUDDLE_LIVE_INFERENCE_ADDRESS"), help="Local OpenAI-compatible server address")
    parser.add_argument("--model", default=os.environ.get("PUDDLE_LIVE_INFERENCE_MODEL", ""), help="Optional exact model ID")
    args = parser.parse_args()
    if not args.server:
        parser.error("Pass --server or set PUDDLE_LIVE_INFERENCE_ADDRESS to your running local server.")
    repo = Path(__file__).resolve().parent.parent
    driver = validate_driver(args.driver, args.driver_requirement)
    api_key = os.environ.get("PUDDLE_LIVE_INFERENCE_KEY", "")
    models = inference_models(args.server, api_key)
    if args.model and not any(model.get("id") == args.model for model in json.loads(models)["data"]):
        raise RuntimeError("The selected model is not listed by the local server.")
    os.umask(0o077)
    output = (args.output or repo / "build" / (time.strftime("local-%Y%m%dT%H%M%SZ", time.gmtime()) + f"-{os.getpid()}")).resolve()
    output.mkdir(parents=True, exist_ok=False)
    environment = os.environ.copy()
    for key in ["PUDDLE_LOAD_PROFILE", "PUDDLE_LOAD_ITERATIONS", "PUDDLE_LOAD_EXPORT_FIXTURE", "PUDDLE_LOAD_SAVE_BUDGET_MS",
                "PUDDLE_GOOGLE_CLIENT_FILE", "PUDDLE_SIGNING_IDENTITY", "PUDDLE_BUILD_CONFIGURATION", "PUDDLE_ACCEPTANCE_OUTPUT_DIRECTORY",
                "PUDDLE_VERSION", "PUDDLE_BUILD_NUMBER", "PUDDLE_UPDATE_MANIFEST_URL", "PUDDLE_UPDATE_PUBLIC_KEY", "PUDDLE_MICROSOFT_CLIENT_ID", "PUDDLE_RUN_CAPACITY_TESTS"]:
        environment.pop(key, None)
    environment.update(PUDDLE_LIVE_INFERENCE_ADDRESS=args.server, PUDDLE_LIVE_INFERENCE_MODEL=args.model,
                       PUDDLE_FILESYSTEM_TESTS="1", PUDDLE_LOAD_TESTS="1",
                       PUDDLE_CUA_DRIVER=str(driver), PUDDLE_CUA_DRIVER_REQUIREMENT=args.driver_requirement,
                       PUDDLE_CUA_LIVE="1", PUDDLE_LOAD_OUTPUT_DIRECTORY=str(output))
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
    (output / "runtime-models.json").write_bytes(models)
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
        (output / "runtime-end.json").write_bytes(inference_models(args.server, api_key))
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
