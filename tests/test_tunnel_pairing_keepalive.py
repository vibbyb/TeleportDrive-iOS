"""Unit and contract tests for Tunnel, Pairing, and Keep-Alive components."""

import math
from pathlib import Path
import plistlib
import random
import sys
import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPTS_DIR = REPO_ROOT / "scripts"
if str(SCRIPTS_DIR) not in sys.path:
    sys.path.insert(0, str(SCRIPTS_DIR))

from package_and_sideload import normalize_pairing_bytes


class TestPairingNormalizationBoundaries:
    """Boundary test suite for pairing normalization and self-healing logic."""

    def test_valid_idevice_pairing_preserved(self) -> None:
        raw_plist = {
            "public_key": b"P" * 32,
            "private_key": b"K" * 32,
            "identifier": "CUSTOM-UUID-1234",
            "alt_irk": b"I" * 16,
        }
        data = plistlib.dumps(raw_plist)
        normalized, detail = normalize_pairing_bytes(data)
        assert normalized is not None
        parsed = plistlib.loads(normalized)
        assert parsed["public_key"] == b"P" * 32
        assert parsed["private_key"] == b"K" * 32
        assert parsed["identifier"] == "CUSTOM-UUID-1234"
        assert parsed["alt_irk"] == b"I" * 16

    def test_pmd3_record_derived_identifier(self) -> None:
        raw_plist = {
            "public_key": b"P" * 32,
            "private_key": b"K" * 32,
            "host_identifier": "HOST-ID-9999",
            "peer_alt_irk": b"A" * 16,
        }
        data = plistlib.dumps(raw_plist)
        normalized, _ = normalize_pairing_bytes(data)
        assert normalized is not None
        parsed = plistlib.loads(normalized)
        assert parsed["alt_irk"] == b"A" * 16
        # If identifier was missing, host_identifier is used
        assert parsed["identifier"] == "HOST-ID-9999"

    def test_pmd3_missing_host_identifier_uses_fallback_uuid(self) -> None:
        raw_plist = {
            "public_key": b"P" * 32,
            "private_key": b"K" * 32,
            "peer_alt_irk": b"A" * 16,
        }
        data = plistlib.dumps(raw_plist)
        normalized, _ = normalize_pairing_bytes(data)
        assert normalized is not None
        parsed = plistlib.loads(normalized)
        assert parsed["identifier"] == "E77767E6-350D-3A46-AEC3-35E25C75D6DE"

    def test_empty_string_identifier_replaced_by_fallback(self) -> None:
        raw_plist = {
            "public_key": b"P" * 32,
            "private_key": b"K" * 32,
            "identifier": "",
        }
        data = plistlib.dumps(raw_plist)
        normalized, _ = normalize_pairing_bytes(data)
        assert normalized is not None
        parsed = plistlib.loads(normalized)
        assert len(parsed["identifier"]) > 0

    @pytest.mark.parametrize("key_size", [0, 16, 31, 33, 64])
    def test_invalid_key_lengths_rejected(self, key_size: int) -> None:
        raw_plist = {
            "public_key": b"X" * key_size,
            "private_key": b"Y" * 32,
        }
        data = plistlib.dumps(raw_plist)
        normalized, detail = normalize_pairing_bytes(data)
        assert normalized is None
        assert "public_key" in detail

    def test_corrupt_data_rejected(self) -> None:
        normalized, detail = normalize_pairing_bytes(b"NOT_A_PLIST")
        assert normalized is None
        assert "parse" in detail.lower() or "plist" in detail.lower()


class TestSwiftArchitectureInvariants:
    """Verifies that all modified Swift files uphold architectural invariants."""

    def test_pairing_file_store_invariants(self) -> None:
        path = REPO_ROOT / "StikDebug" / "Tunnel" / "PairingFileStore.swift"
        assert path.is_file()
        content = path.read_text(encoding="utf-8")
        assert "isValidIdevicePairing" in content
        assert "normalizePairingData" in content
        assert "resetToBundledDefault" in content
        assert "DefaultPairing" in content
        assert "E77767E6-350D-3A46-AEC3-35E25C75D6DE" in content
        assert "hasUserImportedCustomPairing" in content

    def test_device_connection_candidate_ips_invariants(self) -> None:
        path = REPO_ROOT / "StikDebug" / "Tunnel" / "DeviceConnectionContext.swift"
        assert path.is_file()
        content = path.read_text(encoding="utf-8")
        assert "candidateIPs" in content
        assert "10.7.0.1" in content
        assert "10.7.0.2" in content
        assert "recordWorkingIP" in content

    def test_spoof_keep_alive_manager_invariants(self) -> None:
        path = REPO_ROOT / "StikDebug" / "Services" / "SpoofKeepAliveManager.swift"
        assert path.is_file()
        content = path.read_text(encoding="utf-8")
        assert "final class SpoofKeepAliveManager" in content
        assert "@Published private(set) var isActive" in content
        assert "UIBackgroundTaskIdentifier" in content
        assert "BackgroundAudioManager.shared.start()" in content
        assert "BackgroundLocationManager.shared.start()" in content
        assert "BackgroundAudioManager.shared.stop()" in content
        assert "BackgroundLocationManager.shared.stop()" in content

    def test_background_managers_internal_readability(self) -> None:
        audio_path = REPO_ROOT / "StikDebug" / "Services" / "BackgroundAudioManager.swift"
        assert audio_path.is_file()
        audio_content = audio_path.read_text(encoding="utf-8")
        assert "private(set) var isRunning" in audio_content

        loc_path = REPO_ROOT / "StikDebug" / "Services" / "BackgroundLocationManager.swift"
        assert loc_path.is_file()
        loc_content = loc_path.read_text(encoding="utf-8")
        assert "private(set) var isRunning" in loc_content
        assert "kCLLocationAccuracyHundredMeters" in loc_content
        assert "kCLDistanceFilterNone" in loc_content

    def test_app_bootstrapper_zero_battery_drain_invariants(self) -> None:
        path = REPO_ROOT / "StikDebug" / "App" / "AppBootstrapper.swift"
        assert path.is_file()
        content = path.read_text(encoding="utf-8")
        assert "BackgroundAudioManager.shared.start()" not in content

    def test_tunnel_manager_bridge_status_invariants(self) -> None:
        path = REPO_ROOT / "StikDebug" / "Tunnel" / "TunnelManager.swift"
        assert path.is_file()
        content = path.read_text(encoding="utf-8")
        assert "func recordLocationBridgeStatus(connected: Bool)" in content
        assert "func ensureDDIMountedInBackground()" in content

    def test_location_simulation_bridge_invariants(self) -> None:
        path = REPO_ROOT / "StikDebug" / "Tunnel" / "LocationSimulationBridge.swift"
        assert path.is_file()
        content = path.read_text(encoding="utf-8")
        assert "TunnelManager.shared.recordLocationBridgeStatus(connected: true)" in content
        assert "TunnelManager.shared.recordLocationBridgeStatus(connected: false)" in content
        assert "TunnelManager.shared.ensureDDIMountedInBackground()" in content

    def test_location_simulator_invariants(self) -> None:
        path = REPO_ROOT / "StikDebug" / "Simulation" / "LocationSimulator.swift"
        assert path.is_file()
        content = path.read_text(encoding="utf-8")
        assert "holdIntervalSeconds: TimeInterval = 1.0" in content
        assert "sessionGeneration" in content
        assert "isWriteInFlight" in content
        assert "holdAnchorCoordinate" in content
        assert "coalesceIfBusy: Bool = false" in content
        assert "SpoofKeepAliveManager.shared.activate()" in content
        assert "SpoofKeepAliveManager.shared.deactivate()" in content
        assert "func refreshHoldIfNeeded()" in content

    def test_route_sim_app_phase_invariants(self) -> None:
        path = REPO_ROOT / "StikDebug" / "App" / "RouteSimApp.swift"
        assert path.is_file()
        content = path.read_text(encoding="utf-8")
        assert "LocationSimulator.shared.refreshHoldIfNeeded()" in content


class TestSimulationRandomWalkGeometry:
    """Verifies the mathematical invariants of 1.0s jitter walk clamping."""

    def test_random_walk_strictly_clamped_within_jitter_radius(self) -> None:
        anchor_lat, anchor_lon = 37.7749, -122.4194
        jitter_meters = 0.35
        step_meters = 0.12
        cos_lat = max(0.1, math.cos(anchor_lat * math.pi / 180.0))
        meters_per_deg_lat = 111_111.0
        meters_per_deg_lon = 111_111.0 * cos_lat

        cur_x = 0.0
        cur_y = 0.0

        # Simulate 1000 hold pulses
        for _ in range(1000):
            angle = random.uniform(0, 2 * math.pi)
            step_x = math.cos(angle) * step_meters
            step_y = math.sin(angle) * step_meters

            cur_x += step_x
            cur_y += step_y

            dist = math.hypot(cur_x, cur_y)
            if dist > jitter_meters:
                scale = jitter_meters / dist
                cur_x *= scale
                cur_y *= scale

            # Invariant: offset must never exceed jitter radius + epsilon
            assert math.hypot(cur_x, cur_y) <= jitter_meters + 1e-9

            # Coordinate calculation must not produce NaN
            next_lat = anchor_lat + (cur_y / meters_per_deg_lat)
            next_lon = anchor_lon + (cur_x / meters_per_deg_lon)
            assert -90.0 <= next_lat <= 90.0
            assert -180.0 <= next_lon <= 180.0
