#!/usr/bin/env python3
"""Packaging, pairing injection, and bundle verification pipeline for TeleportDrive."""

import argparse
import os
from pathlib import Path
import platform
import plistlib
import shutil
import stat
import sys
import tempfile
import uuid
import zipfile

ED25519_KEY_LEN = 32


def derive_host_identifier(hostname: str | None = None) -> str:
    """Match pymobiledevice3's generate_host_id(): uppercase uuid3(NAMESPACE_DNS, hostname)."""
    name = platform.node() if hostname is None else hostname
    return str(uuid.uuid3(uuid.NAMESPACE_DNS, name)).upper()


def normalize_pairing_bytes(data: bytes, hostname: str | None = None) -> tuple[bytes | None, str]:
    """Convert a pymobiledevice3 remote pairing record into the format idevice's rp_pairing_file_read accepts.

    idevice requires: public_key (32 bytes), private_key (32 bytes), identifier (string); alt_irk optional.
    pymobiledevice3 omits identifier (derived from hostname at runtime) and names the IRK peer_alt_irk.
    """
    try:
        record = plistlib.loads(data)
    except Exception as exc:
        return None, f"Pairing plist could not be parsed: {exc}"

    if not isinstance(record, dict):
        return None, "Pairing plist top level is not a dictionary"

    for key in ("public_key", "private_key"):
        value = record.get(key)
        if not isinstance(value, bytes) or len(value) != ED25519_KEY_LEN:
            return None, f"Pairing plist is missing a valid 32-byte '{key}' (not an RPPairing record?)"

    notes: list[str] = []
    identifier = record.get("identifier")
    if not isinstance(identifier, str) or not identifier:
        host_identifier = record.get("host_identifier")
        if isinstance(host_identifier, str) and host_identifier:
            record["identifier"] = host_identifier
            notes.append("identifier copied from host_identifier")
        else:
            record["identifier"] = derive_host_identifier(hostname)
            notes.append(f"identifier derived from hostname ({record['identifier']})")

    if "alt_irk" not in record and isinstance(record.get("peer_alt_irk"), bytes):
        record["alt_irk"] = record["peer_alt_irk"]
        notes.append("alt_irk copied from peer_alt_irk")

    summary = "; ".join(notes) if notes else "already idevice-compatible"
    return plistlib.dumps(record, fmt=plistlib.FMT_XML), summary


def inject_pairing_into_ipa(
    source_ipa: str, pairing_plist: str, output_ipa: str, hostname: str | None = None
) -> bool:
    """Inject pairing credentials into an existing IPA bundle as DefaultPairing.plist."""
    src_path = Path(source_ipa).resolve()
    plist_path = Path(pairing_plist).resolve()
    out_path = Path(output_ipa).resolve()

    if not src_path.is_file():
        print(f"Error: Source IPA does not exist: {src_path}", file=sys.stderr)
        return False

    if not plist_path.is_file():
        print(f"Error: Pairing plist does not exist: {plist_path}", file=sys.stderr)
        return False

    if not zipfile.is_zipfile(src_path):
        print(f"Error: Source IPA is not a valid zip archive: {src_path}", file=sys.stderr)
        return False

    normalized, detail = normalize_pairing_bytes(plist_path.read_bytes(), hostname)
    if normalized is None:
        print(f"Error: {detail}", file=sys.stderr)
        return False
    print(f"Pairing normalized: {detail}")

    with tempfile.TemporaryDirectory() as temp_dir:
        temp_dir_path = Path(temp_dir)
        try:
            with zipfile.ZipFile(src_path, "r") as zip_ref:
                if zip_ref.testzip() is not None:
                    print(f"Error: Source IPA zip file testzip failed: {src_path}", file=sys.stderr)
                    return False
                zip_ref.extractall(temp_dir_path)
        except Exception as exc:
            print(f"Error extracting source IPA: {exc}", file=sys.stderr)
            return False

        payload_dir = temp_dir_path / "Payload"
        if not payload_dir.is_dir():
            print(f"Error: No Payload/ directory found in source IPA: {src_path}", file=sys.stderr)
            return False

        app_dirs = [d for d in payload_dir.iterdir() if d.is_dir() and d.name.endswith(".app")]
        if not app_dirs:
            print(f"Error: No .app bundle found inside Payload/: {src_path}", file=sys.stderr)
            return False

        app_bundle = app_dirs[0]
        target_plist = app_bundle / "DefaultPairing.plist"

        try:
            target_plist.write_bytes(normalized)
            os.chmod(target_plist, stat.S_IRUSR | stat.S_IWUSR)  # 0o600
        except Exception as exc:
            print(f"Error copying pairing plist into app bundle: {exc}", file=sys.stderr)
            return False

        out_path.parent.mkdir(parents=True, exist_ok=True)
        temp_output_ipa = temp_dir_path / "output.ipa"

        try:
            with zipfile.ZipFile(temp_output_ipa, "w", compression=zipfile.ZIP_DEFLATED) as zip_out:
                for root, dirs, files in os.walk(payload_dir):
                    dirs.sort()
                    files.sort()
                    rel_dir = os.path.relpath(root, temp_dir_path)
                    for file_name in files:
                        file_path = os.path.join(root, file_name)
                        archive_name = os.path.normpath(os.path.join(rel_dir, file_name))
                        zip_out.write(file_path, arcname=archive_name)

            # Verify integrity of output zip
            with zipfile.ZipFile(temp_output_ipa, "r") as test_zip:
                if test_zip.testzip() is not None:
                    print("Error: Output IPA failed zip integrity verification.", file=sys.stderr)
                    return False

            shutil.move(str(temp_output_ipa), str(out_path))
        except Exception as exc:
            print(f"Error packaging output IPA: {exc}", file=sys.stderr)
            return False

    return True


def _idevice_pairing_problem(record: object) -> str | None:
    """Return why a parsed plist would be rejected by idevice's rp_pairing_file_read, or None if it is accepted."""
    if not isinstance(record, dict):
        return "top level is not a dictionary"
    for key in ("public_key", "private_key"):
        value = record.get(key)
        if not isinstance(value, bytes) or len(value) != ED25519_KEY_LEN:
            return f"missing valid 32-byte '{key}'"
    identifier = record.get("identifier")
    if not isinstance(identifier, str) or not identifier:
        return "missing 'identifier'"
    return None


def verify_ipa_bundle(ipa_path: str) -> tuple[bool, str]:
    """Verify that an IPA bundle contains required binary, Info.plist, and DefaultPairing.plist."""
    path = Path(ipa_path).resolve()
    if not path.is_file():
        return False, f"IPA file does not exist: {path}"

    if not zipfile.is_zipfile(path):
        return False, f"File is not a valid zip archive: {path}"

    try:
        with zipfile.ZipFile(path, "r") as zf:
            if zf.testzip() is not None:
                return False, f"IPA archive failed CRC/integrity test: {path}"

            namelist = zf.namelist()
            app_prefixes: set[str] = set()
            for name in namelist:
                parts = name.split("/")
                if len(parts) >= 2 and parts[0] == "Payload" and parts[1].endswith(".app"):
                    app_prefixes.add(f"{parts[0]}/{parts[1]}")

            if not app_prefixes:
                return False, "Archive does not contain any Payload/*.app bundle"

            # Check app bundle entries
            for app_prefix in sorted(app_prefixes):
                app_name = app_prefix.split("/")[1]
                base_name = app_name[:-4]  # Remove .app

                binary_entry = f"{app_prefix}/{base_name}"
                info_plist_entry = f"{app_prefix}/Info.plist"
                default_pairing_entry = f"{app_prefix}/DefaultPairing.plist"

                missing_entries: list[str] = []
                if binary_entry not in namelist:
                    # Also check for StikDebug as a fallback executable name
                    fallback_binary = f"{app_prefix}/StikDebug"
                    if fallback_binary not in namelist:
                        missing_entries.append(binary_entry)

                if info_plist_entry not in namelist:
                    missing_entries.append(info_plist_entry)

                if default_pairing_entry not in namelist:
                    missing_entries.append(default_pairing_entry)

                if not missing_entries:
                    bundled = plistlib.loads(zf.read(default_pairing_entry))
                    problem = _idevice_pairing_problem(bundled)
                    if problem:
                        return False, f"DefaultPairing.plist in {app_prefix} is not idevice-compatible: {problem}"
                    return True, f"IPA bundle verified successfully ({app_prefix})"
                else:
                    return False, f"Missing required bundle components in {app_prefix}: {missing_entries}"

            return False, f"Missing required bundle components in {app_prefixes}"
    except Exception as exc:
        return False, f"Failed to verify IPA bundle: {exc}"


def main() -> int:
    parser = argparse.ArgumentParser(description="Package, inject pairing, and verify IPA bundles.")
    parser.add_argument("--inject", action="store_true", help="Inject pairing plist into source IPA")
    parser.add_argument("--source-ipa", type=str, help="Path to source unsigned IPA")
    parser.add_argument("--pairing-plist", type=str, help="Path to pairing plist file")
    parser.add_argument("--output-ipa", type=str, help="Path to write modified IPA")
    parser.add_argument("--verify-ipa", type=str, help="Path to IPA bundle to verify")
    parser.add_argument(
        "--normalize-pairing", type=str, metavar="OUT", help="Write an idevice-compatible copy of --pairing-plist to OUT"
    )
    parser.add_argument(
        "--pairing-hostname", type=str, help="Hostname used when pairing (defaults to this machine's hostname)"
    )

    args = parser.parse_args()

    if args.normalize_pairing:
        if not args.pairing_plist:
            print("Error: --normalize-pairing requires --pairing-plist", file=sys.stderr)
            return 1
        normalized, detail = normalize_pairing_bytes(Path(args.pairing_plist).read_bytes(), args.pairing_hostname)
        if normalized is None:
            print(f"NORMALIZE_FAILED: {detail}", file=sys.stderr)
            return 1
        out = Path(args.normalize_pairing)
        out.write_bytes(normalized)
        os.chmod(out, stat.S_IRUSR | stat.S_IWUSR)
        print(f"PAIRING_NORMALIZED: {out} ({detail})")
        return 0

    if args.verify_ipa:
        valid, msg = verify_ipa_bundle(args.verify_ipa)
        if valid:
            print("IPA_VERIFIED_READY")
            print(f"Detail: {msg}")
            return 0
        else:
            print(f"IPA_VERIFICATION_FAILED: {msg}", file=sys.stderr)
            return 1

    if args.inject:
        if not args.source_ipa or not args.pairing_plist or not args.output_ipa:
            print("Error: --inject requires --source-ipa, --pairing-plist, and --output-ipa", file=sys.stderr)
            return 1

        success = inject_pairing_into_ipa(args.source_ipa, args.pairing_plist, args.output_ipa, args.pairing_hostname)
        if success:
            print(f"INJECTION_SUCCESS: {args.output_ipa}")
            return 0
        else:
            print("INJECTION_FAILED", file=sys.stderr)
            return 1

    parser.print_help()
    return 1


if __name__ == "__main__":
    sys.exit(main())
