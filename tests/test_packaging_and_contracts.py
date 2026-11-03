"""Comprehensive unit tests for verification and packaging scripts."""

import os
from pathlib import Path
import stat
import subprocess
import sys
import tempfile
import zipfile

import pytest

# Ensure scripts directory is on sys.path
SCRIPTS_DIR = Path(__file__).resolve().parent.parent / "scripts"
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from package_and_sideload import inject_pairing_into_ipa, verify_ipa_bundle  # noqa: E402
from verify_build_contract import (  # noqa: E402
    verify_all,
    verify_code_contracts,
    verify_gitignore,
    verify_no_pairing_credentials_tracked,
)


def _init_git_repo(path: Path) -> None:
    """Helper to initialize a real git repository in a temp directory."""
    subprocess.run(["git", "init"], cwd=str(path), check=True, capture_output=True, timeout=30)
    subprocess.run(["git", "config", "user.name", "Test User"], cwd=str(path), check=True, capture_output=True, timeout=30)
    subprocess.run(["git", "config", "user.email", "test@example.com"], cwd=str(path), check=True, capture_output=True, timeout=30)


def _create_dummy_source_ipa(path: Path, app_name: str = "StikDebug") -> None:
    """Helper to create a valid dummy iOS IPA file."""
    with zipfile.ZipFile(path, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        zf.writestr(f"Payload/{app_name}.app/{app_name}", b"\xca\xfe\xba\xbeDummyMachOBinary")
        zf.writestr(f"Payload/{app_name}.app/Info.plist", b"<plist><dict></dict></plist>")


class TestVerifyGitignore:
    def test_verify_gitignore_truthy(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            gitignore = repo / ".gitignore"
            gitignore.write_text("*Pairing*.plist\nDefaultPairing.plist\n*.mobiledevicepairing\n", encoding="utf-8")
            ok, msg = verify_gitignore(repo)
            assert ok is True
            assert "verified" in msg.lower()

    def test_verify_gitignore_falsy_missing_file(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            ok, msg = verify_gitignore(repo)
            assert ok is False
            assert "missing .gitignore" in msg.lower()

    def test_verify_gitignore_falsy_missing_rules(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            gitignore = repo / ".gitignore"
            gitignore.write_text("build/\nDerivedData/\n", encoding="utf-8")
            ok, msg = verify_gitignore(repo)
            assert ok is False
            assert "missing required rules" in msg.lower()


class TestVerifyNoPairingCredentialsTracked:
    def test_no_pairing_credentials_truthy(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            _init_git_repo(repo)

            app_dir = repo / "StikDebug"
            app_dir.mkdir(parents=True)
            info_plist = app_dir / "Info.plist"
            info_plist.write_text("<plist></plist>", encoding="utf-8")

            subprocess.run(["git", "add", "."], cwd=str(repo), check=True, capture_output=True, timeout=30)
            subprocess.run(["git", "commit", "-m", "Initial commit"], cwd=str(repo), check=True, capture_output=True, timeout=30)

            ok, offending = verify_no_pairing_credentials_tracked(repo)
            assert ok is True
            assert len(offending) == 0

    def test_pairing_plist_tracked_falsy(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            _init_git_repo(repo)

            leaked = repo / "RPPairing-secret.plist"
            leaked.write_text("<secret></secret>", encoding="utf-8")

            subprocess.run(["git", "add", "."], cwd=str(repo), check=True, capture_output=True, timeout=30)
            subprocess.run(["git", "commit", "-m", "Leak commit"], cwd=str(repo), check=True, capture_output=True, timeout=30)

            ok, offending = verify_no_pairing_credentials_tracked(repo)
            assert ok is False
            assert any("RPPairing-secret.plist" in f for f in offending)

    def test_mobiledevicepairing_tracked_falsy(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            _init_git_repo(repo)

            leaked = repo / "device.mobiledevicepairing"
            leaked.write_text("token", encoding="utf-8")

            subprocess.run(["git", "add", "."], cwd=str(repo), check=True, capture_output=True, timeout=30)
            subprocess.run(["git", "commit", "-m", "Leak pairing"], cwd=str(repo), check=True, capture_output=True, timeout=30)

            ok, offending = verify_no_pairing_credentials_tracked(repo)
            assert ok is False
            assert any("device.mobiledevicepairing" in f for f in offending)


class TestVerifyCodeContracts:
    def test_code_contracts_truthy(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            # Create required swift files
            (repo / "StikDebug" / "Tunnel").mkdir(parents=True)
            (repo / "StikDebug" / "Simulation").mkdir(parents=True)
            (repo / "StikDebug" / "Features" / "Simulate").mkdir(parents=True)

            (repo / "StikDebug" / "Tunnel" / "PairingFileStore.swift").write_text(
                "let bundledURL = Bundle.main.url(forResource: \"DefaultPairing\", withExtension: \"plist\")",
                encoding="utf-8",
            )
            (repo / "StikDebug" / "Simulation" / "LocationSimulator.swift").write_text(
                "private var holdTimer: DispatchSourceTimer?",
                encoding="utf-8",
            )
            (repo / "StikDebug" / "Simulation" / "RoutePlayer.swift").write_text(
                "var isAutoParking: Bool = false",
                encoding="utf-8",
            )
            (repo / "StikDebug" / "Features" / "Simulate" / "GoogleMapView.swift").write_text(
                "class GoogleMapsTileOverlay: MKTileOverlay {}",
                encoding="utf-8",
            )
            (repo / "StikDebug" / "Features" / "Simulate" / "PlaceSearchService.swift").write_text(
                "struct PlaceSearchService {}",
                encoding="utf-8",
            )

            ok, failures = verify_code_contracts(repo)
            assert ok is True
            assert len(failures) == 0

    def test_code_contracts_falsy(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            # Missing files completely
            ok, failures = verify_code_contracts(repo)
            assert ok is False
            assert len(failures) >= 4


class TestVerifyAll:
    def test_verify_all_on_real_repo(self) -> None:
        real_repo = Path(__file__).resolve().parent.parent
        ok, failures = verify_all(real_repo, security_only=False)
        assert ok is True, f"Real repo contract failed: {failures}"


class TestPackagingAndSideload:
    def test_inject_pairing_truthy(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            src_ipa = tmp / "Source.ipa"
            out_ipa = tmp / "Output.ipa"
            pairing_plist = tmp / "MyPairing.plist"

            _create_dummy_source_ipa(src_ipa, "StikDebug")
            pairing_plist.write_text("<plist><dict><key>Secret</key><string>abc</string></dict></plist>", encoding="utf-8")

            success = inject_pairing_into_ipa(str(src_ipa), str(pairing_plist), str(out_ipa))
            assert success is True
            assert out_ipa.is_file()

            # Verify bundle using verify_ipa_bundle
            valid, msg = verify_ipa_bundle(str(out_ipa))
            assert valid is True
            assert "verified successfully" in msg

            # Verify permissions inside zip
            with zipfile.ZipFile(out_ipa, "r") as zf:
                info = zf.getinfo("Payload/StikDebug.app/DefaultPairing.plist")
                # zip permission bits reside in external_attr >> 16
                mode = (info.external_attr >> 16) & 0o777
                assert mode == 0o600

    def test_inject_pairing_falsy_missing_source(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            nonexistent_ipa = tmp / "Missing.ipa"
            plist = tmp / "test.plist"
            plist.write_text("<plist></plist>", encoding="utf-8")
            out = tmp / "out.ipa"

            assert inject_pairing_into_ipa(str(nonexistent_ipa), str(plist), str(out)) is False

    def test_inject_pairing_falsy_missing_plist(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            src_ipa = tmp / "Source.ipa"
            _create_dummy_source_ipa(src_ipa)
            missing_plist = tmp / "nonexistent.plist"
            out = tmp / "out.ipa"

            assert inject_pairing_into_ipa(str(src_ipa), str(missing_plist), str(out)) is False

    def test_inject_pairing_falsy_corrupt_zip(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            corrupt_ipa = tmp / "corrupt.ipa"
            corrupt_ipa.write_bytes(b"not a valid zip archive contents")
            plist = tmp / "test.plist"
            plist.write_text("<plist></plist>", encoding="utf-8")
            out = tmp / "out.ipa"

            assert inject_pairing_into_ipa(str(corrupt_ipa), str(plist), str(out)) is False

    def test_verify_ipa_bundle_falsy_nonexistent(self) -> None:
        valid, msg = verify_ipa_bundle("/tmp/nonexistent_file_path_123.ipa")
        assert valid is False
        assert "does not exist" in msg

    def test_verify_ipa_bundle_falsy_missing_pairing(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            ipa_path = tmp / "NoPairing.ipa"
            _create_dummy_source_ipa(ipa_path, "StikDebug")

            valid, msg = verify_ipa_bundle(str(ipa_path))
            assert valid is False
            assert "DefaultPairing.plist" in msg


class TestCLIExecutions:
    def test_cli_verify_build_contract_security(self) -> None:
        real_repo = Path(__file__).resolve().parent.parent
        script = real_repo / "scripts" / "verify_build_contract.py"
        res = subprocess.run(
            [sys.executable, str(script), "--repo-root", str(real_repo), "--check-security"],
            capture_output=True,
            text=True,
            check=True,
            timeout=30,
        )
        assert res.returncode == 0
        assert "SECURITY_CONTRACT_OK" in res.stdout

    def test_cli_package_and_sideload_flow(self) -> None:
        real_repo = Path(__file__).resolve().parent.parent
        script = real_repo / "scripts" / "package_and_sideload.py"

        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            src_ipa = tmp / "StikDebug-raw.ipa"
            plist = tmp / "device.plist"
            out_ipa = tmp / "Injected.ipa"

            _create_dummy_source_ipa(src_ipa, "StikDebug")
            plist.write_text("<plist></plist>", encoding="utf-8")

            # 1. Inject via CLI
            inject_res = subprocess.run(
                [
                    sys.executable,
                    str(script),
                    "--inject",
                    "--source-ipa",
                    str(src_ipa),
                    "--pairing-plist",
                    str(plist),
                    "--output-ipa",
                    str(out_ipa),
                ],
                capture_output=True,
                text=True,
                check=True,
                timeout=30,
            )
            assert inject_res.returncode == 0
            assert "INJECTION_SUCCESS" in inject_res.stdout

            # 2. Verify via CLI
            verify_res = subprocess.run(
                [sys.executable, str(script), "--verify-ipa", str(out_ipa)],
                capture_output=True,
                text=True,
                check=True,
                timeout=30,
            )
            assert verify_res.returncode == 0
            assert "IPA_VERIFIED_READY" in verify_res.stdout
