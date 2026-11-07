"""Comprehensive unit tests for verification and packaging scripts."""

import os
import plistlib
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

from package_and_sideload import (  # noqa: E402
    derive_host_identifier,
    inject_pairing_into_ipa,
    normalize_pairing_bytes,
    verify_ipa_bundle,
)
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


def _write_pmd3_record(path: Path, **overrides: object) -> None:
    """Write a pymobiledevice3-style remote pairing record (no identifier, peer_alt_irk)."""
    record: dict[str, object] = {
        "public_key": bytes(range(32)),
        "private_key": bytes(range(32, 64)),
        "peer_alt_irk": b"\x01" * 16,
        "remote_unlock_host_key": "x" * 44,
    }
    record.update(overrides)
    path.write_bytes(plistlib.dumps(record))


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
            (repo / "StikDebug" / "Features" / "Drive").mkdir(parents=True)
            (repo / "StikDebug" / "Features" / "Teleport").mkdir(parents=True)
            (repo / "StikDebug" / "Services").mkdir(parents=True)
            (repo / "StikDebug" / "App").mkdir(parents=True)

            (repo / "StikDebug" / "Tunnel" / "PairingFileStore.swift").write_text(
                "let bundledURL = Bundle.main.url(forResource: \"DefaultPairing\", withExtension: \"plist\")\n"
                "static func resetToBundledDefault() throws {}",
                encoding="utf-8",
            )
            (repo / "StikDebug" / "Simulation" / "LocationSimulator.swift").write_text(
                "private var holdTimer: DispatchSourceTimer?\n"
                "let holdIntervalSeconds: TimeInterval = 1.0",
                encoding="utf-8",
            )
            (repo / "StikDebug" / "Simulation" / "RoutePlayer.swift").write_text(
                "var isAutoParking: Bool = false\n"
                "private let tickInterval: TimeInterval = 0.20 // 5 Hz",
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
            (repo / "StikDebug" / "App" / "RootView.swift").write_text(
                "TabView {\n"
                "    DriveView(vm: simulateVM)\n"
                "    TeleportView(vm: simulateVM)\n"
                "    RouteSimSettingsView()\n"
                "}",
                encoding="utf-8",
            )
            (repo / "StikDebug" / "Services" / "SpoofKeepAliveManager.swift").write_text(
                "final class SpoofKeepAliveManager {\n"
                "    @Published var isActive: Bool = false\n"
                "}",
                encoding="utf-8",
            )
            (repo / "StikDebug" / "Features" / "Drive" / "DriveView.swift").write_text(
                "struct DriveView: View {}",
                encoding="utf-8",
            )
            (repo / "StikDebug" / "Features" / "Teleport" / "TeleportView.swift").write_text(
                "struct TeleportView: View {}",
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
            assert len(failures) >= 7

    def test_code_contracts_falsy_missing_new_tabs(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            repo = Path(td)
            (repo / "StikDebug" / "Tunnel").mkdir(parents=True)
            (repo / "StikDebug" / "Simulation").mkdir(parents=True)
            (repo / "StikDebug" / "Features" / "Simulate").mkdir(parents=True)
            (repo / "StikDebug" / "Services").mkdir(parents=True)
            (repo / "StikDebug" / "App").mkdir(parents=True)

            (repo / "StikDebug" / "Tunnel" / "PairingFileStore.swift").write_text(
                "DefaultPairing resetToBundledDefault", encoding="utf-8")
            (repo / "StikDebug" / "Simulation" / "LocationSimulator.swift").write_text(
                "DispatchSourceTimer 1.0", encoding="utf-8")
            (repo / "StikDebug" / "Simulation" / "RoutePlayer.swift").write_text(
                "isAutoParking 0.2", encoding="utf-8")
            (repo / "StikDebug" / "Features" / "Simulate" / "GoogleMapView.swift").write_text(
                "MKTileOverlay", encoding="utf-8")
            (repo / "StikDebug" / "Features" / "Simulate" / "PlaceSearchService.swift").write_text(
                "PlaceSearchService", encoding="utf-8")
            (repo / "StikDebug" / "Services" / "SpoofKeepAliveManager.swift").write_text(
                "isActive", encoding="utf-8")
            (repo / "StikDebug" / "App" / "RootView.swift").write_text(
                "OldTabView", encoding="utf-8")

            ok, failures = verify_code_contracts(repo)
            assert ok is False
            assert any("DriveView" in f for f in failures)
            assert any("TeleportView" in f for f in failures)


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
            _write_pmd3_record(pairing_plist)

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


class TestPairingNormalization:
    def test_derive_host_identifier_matches_pmd3_format(self) -> None:
        ident = derive_host_identifier("Vibhavs-MacBook-Air.local")
        assert ident == "E77767E6-350D-3A46-AEC3-35E25C75D6DE"

    def test_normalize_adds_identifier_and_alt_irk(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            src = Path(td) / "rp.plist"
            _write_pmd3_record(src)
            out, detail = normalize_pairing_bytes(src.read_bytes(), "Vibhavs-MacBook-Air.local")
            assert out is not None
            rec = plistlib.loads(out)
            assert rec["identifier"] == "E77767E6-350D-3A46-AEC3-35E25C75D6DE"
            assert rec["alt_irk"] == b"\x01" * 16
            assert rec["public_key"] == bytes(range(32))
            assert "identifier derived" in detail

    def test_normalize_prefers_existing_identifier(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            src = Path(td) / "rp.plist"
            _write_pmd3_record(src, identifier="KEEP-ME", alt_irk=b"\x02" * 16)
            out, detail = normalize_pairing_bytes(src.read_bytes(), "other-host")
            assert out is not None
            rec = plistlib.loads(out)
            assert rec["identifier"] == "KEEP-ME"
            assert rec["alt_irk"] == b"\x02" * 16
            assert detail == "already idevice-compatible"

    def test_normalize_uses_host_identifier(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            src = Path(td) / "rp.plist"
            _write_pmd3_record(src, host_identifier="HOST-ID")
            out, _ = normalize_pairing_bytes(src.read_bytes())
            assert out is not None
            assert plistlib.loads(out)["identifier"] == "HOST-ID"

    def test_normalize_rejects_bad_key_length(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            src = Path(td) / "rp.plist"
            _write_pmd3_record(src, private_key=b"short")
            out, detail = normalize_pairing_bytes(src.read_bytes())
            assert out is None
            assert "private_key" in detail

    def test_normalize_rejects_lockdown_record(self) -> None:
        lockdown = plistlib.dumps({"HostID": "abc", "DeviceCertificate": b"cert"})
        out, detail = normalize_pairing_bytes(lockdown)
        assert out is None
        assert "public_key" in detail

    def test_normalize_rejects_garbage_and_non_dict(self) -> None:
        assert normalize_pairing_bytes(b"not a plist")[0] is None
        out, detail = normalize_pairing_bytes(plistlib.dumps(["a"]))
        assert out is None
        assert "dictionary" in detail

    def test_inject_rejects_invalid_pairing(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            src_ipa = tmp / "Source.ipa"
            _create_dummy_source_ipa(src_ipa)
            bad = tmp / "bad.plist"
            bad.write_text("<plist><dict></dict></plist>", encoding="utf-8")
            out = tmp / "out.ipa"
            assert inject_pairing_into_ipa(str(src_ipa), str(bad), str(out)) is False
            assert not out.exists()

    def test_verify_rejects_bundled_pairing_without_identifier(self) -> None:
        with tempfile.TemporaryDirectory() as td:
            ipa = Path(td) / "Raw.ipa"
            with zipfile.ZipFile(ipa, "w") as zf:
                zf.writestr("Payload/StikDebug.app/StikDebug", b"bin")
                zf.writestr("Payload/StikDebug.app/Info.plist", b"<plist/>")
                zf.writestr(
                    "Payload/StikDebug.app/DefaultPairing.plist",
                    plistlib.dumps({"public_key": bytes(32), "private_key": bytes(32)}),
                )
            valid, msg = verify_ipa_bundle(str(ipa))
            assert valid is False
            assert "identifier" in msg

    def test_cli_normalize_pairing(self) -> None:
        script = Path(__file__).resolve().parent.parent / "scripts" / "package_and_sideload.py"
        with tempfile.TemporaryDirectory() as td:
            src = Path(td) / "rp.plist"
            out = Path(td) / "fixed.plist"
            _write_pmd3_record(src)
            res = subprocess.run(
                [sys.executable, str(script), "--normalize-pairing", str(out), "--pairing-plist", str(src),
                 "--pairing-hostname", "Vibhavs-MacBook-Air.local"],
                capture_output=True, text=True, check=True, timeout=30,
            )
            assert "PAIRING_NORMALIZED" in res.stdout
            assert plistlib.loads(out.read_bytes())["identifier"] == "E77767E6-350D-3A46-AEC3-35E25C75D6DE"
            assert stat.S_IMODE(out.stat().st_mode) == 0o600

    def test_cli_normalize_pairing_failure(self) -> None:
        script = Path(__file__).resolve().parent.parent / "scripts" / "package_and_sideload.py"
        with tempfile.TemporaryDirectory() as td:
            src = Path(td) / "bad.plist"
            src.write_bytes(plistlib.dumps({"HostID": "x"}))
            res = subprocess.run(
                [sys.executable, str(script), "--normalize-pairing", str(Path(td) / "o.plist"), "--pairing-plist", str(src)],
                capture_output=True, text=True, timeout=30,
            )
            assert res.returncode == 1
            assert "NORMALIZE_FAILED" in res.stderr


class TestPairingBoundaries:
    @pytest.mark.parametrize("length", [0, 31, 33, 64])
    def test_rejects_off_by_one_key_lengths(self, length: int) -> None:
        data = plistlib.dumps({"public_key": bytes(length), "private_key": bytes(32)})
        out, detail = normalize_pairing_bytes(data)
        assert out is None
        assert "public_key" in detail

    def test_accepts_exact_32_byte_keys(self) -> None:
        data = plistlib.dumps({"public_key": bytes(32), "private_key": bytes(32)})
        out, _ = normalize_pairing_bytes(data, "h")
        assert out is not None

    def test_empty_identifier_is_replaced(self) -> None:
        data = plistlib.dumps({"public_key": bytes(32), "private_key": bytes(32), "identifier": ""})
        out, _ = normalize_pairing_bytes(data, "h")
        assert out is not None
        assert plistlib.loads(out)["identifier"] == derive_host_identifier("h")

    def test_key_as_string_not_bytes_rejected(self) -> None:
        data = plistlib.dumps({"public_key": "a" * 32, "private_key": bytes(32)})
        assert normalize_pairing_bytes(data)[0] is None

    def test_non_bytes_peer_alt_irk_not_copied(self) -> None:
        data = plistlib.dumps({"public_key": bytes(32), "private_key": bytes(32), "peer_alt_irk": "str"})
        out, _ = normalize_pairing_bytes(data, "h")
        assert out is not None
        assert "alt_irk" not in plistlib.loads(out)

    def test_binary_plist_input_accepted(self) -> None:
        data = plistlib.dumps({"public_key": bytes(32), "private_key": bytes(32)}, fmt=plistlib.FMT_BINARY)
        out, _ = normalize_pairing_bytes(data, "h")
        assert out is not None


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

    def test_cli_verify_build_contract_default_repo_root(self) -> None:
        """Verify CLI uses the resolved repo parent directory by default without --repo-root."""
        real_repo = Path(__file__).resolve().parent.parent
        script = real_repo / "scripts" / "verify_build_contract.py"
        # Run from an unrelated directory (tmpdir) to prove default repo-root resolves correctly
        with tempfile.TemporaryDirectory() as td:
            res = subprocess.run(
                [sys.executable, str(script), "--check-security"],
                cwd=td,
                capture_output=True,
                text=True,
                check=True,
                timeout=30,
            )
            assert res.returncode == 0
            assert "SECURITY_CONTRACT_OK" in res.stdout

    def test_cli_verify_build_contract_all_contracts_success(self) -> None:
        """Verify CLI full verification mode output."""
        real_repo = Path(__file__).resolve().parent.parent
        script = real_repo / "scripts" / "verify_build_contract.py"
        res = subprocess.run(
            [sys.executable, str(script)],
            capture_output=True,
            text=True,
            check=True,
            timeout=30,
        )
        assert res.returncode == 0
        assert "ALL_BUILD_CONTRACTS_OK" in res.stdout

    def test_cli_package_and_sideload_flow(self) -> None:
        real_repo = Path(__file__).resolve().parent.parent
        script = real_repo / "scripts" / "package_and_sideload.py"

        with tempfile.TemporaryDirectory() as td:
            tmp = Path(td)
            src_ipa = tmp / "StikDebug-raw.ipa"
            plist = tmp / "device.plist"
            out_ipa = tmp / "Injected.ipa"

            _create_dummy_source_ipa(src_ipa, "StikDebug")
            _write_pmd3_record(plist)

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

    def test_stikdebug_tests_imports_mapkit(self) -> None:
        """Verify that StikDebugTests imports MapKit for MKTileOverlayPath and tile overlays."""
        repo_root = Path(__file__).resolve().parent.parent
        tests_file = repo_root / "StikDebugTests" / "StikDebugTests.swift"
        assert tests_file.is_file(), f"Missing {tests_file}"
        content = tests_file.read_text(encoding="utf-8")
        assert "import MapKit" in content, "StikDebugTests.swift must import MapKit for MKTileOverlayPath"
        assert "MKTileOverlayPath" in content, "StikDebugTests.swift must test MKTileOverlayPath"
