#!/usr/bin/env python3
"""Build and security contract verification script for TeleportDrive."""

import argparse
import os
from pathlib import Path
import subprocess
import sys


def verify_gitignore(repo_path: Path) -> tuple[bool, str]:
    """Verify that .gitignore contains necessary pairing exclusion rules."""
    gitignore_path = repo_path / ".gitignore"
    if not gitignore_path.is_file():
        return False, "Missing .gitignore file"

    content = gitignore_path.read_text(encoding="utf-8")
    lines = [line.strip() for line in content.splitlines()]

    required_patterns = ["*Pairing*.plist", "DefaultPairing.plist"]
    missing = [pat for pat in required_patterns if pat not in lines]

    if missing:
        return False, f".gitignore is missing required rules: {missing}"

    return True, "Gitignore rules verified"


def verify_no_pairing_credentials_tracked(repo_path: Path) -> tuple[bool, list[str]]:
    """Verify that zero pairing credential files are tracked by Git."""
    try:
        proc = subprocess.run(
            ["git", "ls-files"],
            cwd=str(repo_path),
            capture_output=True,
            text=True,
            check=True,
            timeout=30,
        )
    except subprocess.TimeoutExpired:
        return False, ["git ls-files timed out after 30s"]
    except subprocess.CalledProcessError as exc:
        return False, [f"Failed to run git ls-files: {exc}"]
    except FileNotFoundError:
        return False, ["git executable not found in PATH"]

    tracked_files = [line.strip() for line in proc.stdout.splitlines() if line.strip()]
    offending_files: list[str] = []

    for file_path in tracked_files:
        lower_path = file_path.lower()
        # Exclude standard application plists and entitlements
        if (
            file_path.endswith("Info.plist")
            or "entitlements" in lower_path
            or "launchscreen" in lower_path
        ):
            continue

        if file_path.endswith(".mobiledevicepairing") or file_path.endswith(".mobiledevicepair"):
            offending_files.append(file_path)
        elif file_path.endswith(".plist"):
            # Any plist containing pairing or credential tokens
            if "pairing" in lower_path or file_path.endswith("DefaultPairing.plist"):
                offending_files.append(file_path)

    if offending_files:
        return False, offending_files

    return True, []


def verify_code_contracts(repo_path: Path) -> tuple[bool, list[str]]:
    """Verify Swift code architecture invariants."""
    failures: list[str] = []

    # 1. PairingFileStore references DefaultPairing and implements resetToBundledDefault
    pairing_store = repo_path / "StikDebug" / "Tunnel" / "PairingFileStore.swift"
    if not pairing_store.is_file():
        failures.append(f"Missing file: {pairing_store}")
    else:
        text = pairing_store.read_text(encoding="utf-8")
        if "DefaultPairing" not in text:
            failures.append("StikDebug/Tunnel/PairingFileStore.swift does not reference DefaultPairing")
        if "resetToBundledDefault" not in text:
            failures.append("StikDebug/Tunnel/PairingFileStore.swift does not implement resetToBundledDefault")

    # 2. LocationSimulator uses DispatchSourceTimer and implements 1 Hz hold
    loc_sim = repo_path / "StikDebug" / "Simulation" / "LocationSimulator.swift"
    if not loc_sim.is_file():
        failures.append(f"Missing file: {loc_sim}")
    else:
        text = loc_sim.read_text(encoding="utf-8")
        if "DispatchSourceTimer" not in text:
            failures.append("StikDebug/Simulation/LocationSimulator.swift does not use DispatchSourceTimer")
        if "holdIntervalSeconds" not in text and "1.0" not in text:
            failures.append("StikDebug/Simulation/LocationSimulator.swift does not specify 1 Hz hold cadence")

    # 3. RoutePlayer implements isAutoParking and 1 Hz playback
    route_player = repo_path / "StikDebug" / "Simulation" / "RoutePlayer.swift"
    if not route_player.is_file():
        failures.append(f"Missing file: {route_player}")
    else:
        text = route_player.read_text(encoding="utf-8")
        if "isAutoParking" not in text:
            failures.append("StikDebug/Simulation/RoutePlayer.swift does not implement isAutoParking")
        if "1.0" not in text and "1 Hz" not in text:
            failures.append("StikDebug/Simulation/RoutePlayer.swift does not implement 1 Hz playback")

    # 4. GoogleMapView implements MKTileOverlay
    google_map = repo_path / "StikDebug" / "Features" / "Simulate" / "GoogleMapView.swift"
    if not google_map.is_file():
        failures.append(f"Missing file: {google_map}")
    else:
        text = google_map.read_text(encoding="utf-8")
        if "MKTileOverlay" not in text:
            failures.append("StikDebug/Features/Simulate/GoogleMapView.swift does not implement MKTileOverlay")

    # 5. PlaceSearchService exists
    place_search = repo_path / "StikDebug" / "Features" / "Simulate" / "PlaceSearchService.swift"
    if not place_search.is_file():
        failures.append("StikDebug/Features/Simulate/PlaceSearchService.swift does not exist")

    # 6. 3-tab RootView with DriveView and TeleportView
    root_view = repo_path / "StikDebug" / "App" / "RootView.swift"
    if not root_view.is_file():
        failures.append(f"Missing file: {root_view}")
    else:
        text = root_view.read_text(encoding="utf-8")
        if "DriveView" not in text:
            failures.append("StikDebug/App/RootView.swift does not reference DriveView")
        if "TeleportView" not in text:
            failures.append("StikDebug/App/RootView.swift does not reference TeleportView")
        if "RouteSimSettingsView" not in text:
            failures.append("StikDebug/App/RootView.swift does not reference RouteSimSettingsView")

    # 7. SpoofKeepAliveManager exists and implements isActive
    keep_alive = repo_path / "StikDebug" / "Services" / "SpoofKeepAliveManager.swift"
    if not keep_alive.is_file():
        failures.append(f"Missing file: {keep_alive}")
    else:
        text = keep_alive.read_text(encoding="utf-8")
        if "isActive" not in text:
            failures.append("StikDebug/Services/SpoofKeepAliveManager.swift does not implement isActive")

    # 8. DriveView exists
    drive_view = repo_path / "StikDebug" / "Features" / "Drive" / "DriveView.swift"
    if not drive_view.is_file():
        failures.append(f"Missing file: {drive_view}")

    # 9. TeleportView exists
    teleport_view = repo_path / "StikDebug" / "Features" / "Teleport" / "TeleportView.swift"
    if not teleport_view.is_file():
        failures.append(f"Missing file: {teleport_view}")

    if failures:
        return False, failures

    return True, []


def verify_all(repo_path: Path, security_only: bool = False) -> tuple[bool, list[str]]:
    """Run all verification checks."""
    all_failures: list[str] = []

    gitignore_ok, msg = verify_gitignore(repo_path)
    if not gitignore_ok:
        all_failures.append(msg)

    no_keys_ok, offending = verify_no_pairing_credentials_tracked(repo_path)
    if not no_keys_ok:
        all_failures.append(f"Pairing credential files tracked by Git: {offending}")

    if not security_only:
        code_ok, code_failures = verify_code_contracts(repo_path)
        if not code_ok:
            all_failures.extend(code_failures)

    return (len(all_failures) == 0), all_failures


def main() -> int:
    parser = argparse.ArgumentParser(description="Verify build contracts and security invariants.")
    parser.add_argument(
        "--repo-root",
        type=str,
        default=str(Path(__file__).resolve().parent.parent),
        help="Path to repository root (defaults to TeleportDrive root)",
    )
    parser.add_argument(
        "--check-security",
        action="store_true",
        help="Check security invariants (gitignore & no tracked pairing keys) and print SECURITY_CONTRACT_OK",
    )

    args = parser.parse_args()
    repo_path = Path(args.repo_root).resolve()

    if args.check_security:
        success, failures = verify_all(repo_path, security_only=True)
        if success:
            print("SECURITY_CONTRACT_OK")
            return 0
        else:
            print(f"SECURITY_CONTRACT_FAIL: {failures}", file=sys.stderr)
            return 1

    success, failures = verify_all(repo_path, security_only=False)
    if success:
        print("SECURITY_CONTRACT_OK")
        print("ALL_BUILD_CONTRACTS_OK")
        return 0
    else:
        for failure in failures:
            print(f"CONTRACT_FAILURE: {failure}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
