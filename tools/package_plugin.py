#!/usr/bin/env python3

import argparse
import base64
import datetime
import gzip
import io
import json
import os
import shutil
import subprocess
import tarfile
import time
from pathlib import Path
from typing import Dict, List


ROOT = Path(__file__).resolve().parent.parent
IGNORED_NAMES = {"__pycache__", ".DS_Store", ".gitkeep"}
IGNORED_SUFFIXES = {".pyc", ".pyo"}
PLUGINS_ROOT = ROOT / "plugins"
SIGNATURE_RAW_NAME = "sign.txt.sha256"
SIGNATURE_ENCODED_NAME = "sign.txt.sha256_encode64.sig"
SIGNING_CERT_EXPORT_NAME = "sign.crt"
REPRODUCIBLE_MTIME = 0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Package ACC custom plugins.")
    parser.add_argument("--plugin", action="append", help="Plugin name to build. May be passed multiple times.")
    parser.add_argument("--output-dir", default="dist", help="Directory for build artifacts.")
    parser.add_argument("--signing-key", help="Optional private key path for openssl signing.")
    parser.add_argument("--signing-cert", help="Optional x509 certificate path for signature verification.")
    parser.add_argument(
        "--create-signing-key",
        action="store_true",
        help="Create a local signing key and self-signed certificate automatically if they do not exist.",
    )
    parser.add_argument("--openssl-bin", default="openssl", help="OpenSSL executable.")
    parser.add_argument("--keep-work", action="store_true", help="Keep intermediate build files.")
    return parser.parse_args()


def load_metadata(path: Path) -> dict:
    with path.open("r", encoding="utf-8") as handle:
        data = json.load(handle)

    plugin_name = data.get("pluginName")
    dirs = data.get("dirs")
    if not plugin_name or not isinstance(plugin_name, str):
        raise ValueError("plugin.json must contain a string pluginName")
    if not isinstance(dirs, dict):
        raise ValueError("plugin.json must contain a dirs object")
    for target_dir, entries in dirs.items():
        if not isinstance(target_dir, str) or not isinstance(entries, list):
            raise ValueError("plugin.json dirs must map target directory names to entry lists")
    return data


def archive_basename(path: Path) -> str:
    name = path.name
    if name.endswith(".tar.gz"):
        return name[:-7]
    return path.stem


def default_signing_key(plugin_name: str) -> Path:
    return ROOT / ".keys" / f"{plugin_name}-signing-key.pem"


def default_signing_cert(plugin_name: str) -> Path:
    return ROOT / ".keys" / f"{plugin_name}-signing-cert.crt"


def local_signing_pairs(plugin_name: str) -> tuple[tuple[str, str], ...]:
    return (
        ("sign.key", "sign.crt"),
        ("signing.key", "signing.crt"),
        (f"{plugin_name}-signing-key.pem", f"{plugin_name}-signing-cert.crt"),
    )


def find_local_signing_pair(plugin_name: str) -> tuple[Path, Path] | tuple[None, None]:
    cwd = Path.cwd()
    for key_name, cert_name in local_signing_pairs(plugin_name):
        key_path = (cwd / key_name).resolve()
        cert_path = (cwd / cert_name).resolve()
        if key_path.exists() and cert_path.exists():
            return key_path, cert_path
    return None, None


def resolve_signing_key(args: argparse.Namespace, plugin_name: str) -> Path | None:
    if args.signing_key:
        return Path(args.signing_key).resolve()
    local_key, _ = find_local_signing_pair(plugin_name)
    if local_key is not None:
        return local_key
    if args.create_signing_key:
        return default_signing_key(plugin_name).resolve()
    return None


def resolve_signing_cert(args: argparse.Namespace, plugin_name: str, signing_key: Path | None) -> Path | None:
    if args.signing_cert:
        return Path(args.signing_cert).resolve()
    local_key, local_cert = find_local_signing_pair(plugin_name)
    if signing_key is not None and local_key is not None and signing_key == local_key:
        return local_cert
    if signing_key is not None:
        if signing_key == default_signing_key(plugin_name).resolve():
            return default_signing_cert(plugin_name).resolve()
        inferred_cert = signing_key.with_suffix(".crt")
        if args.create_signing_key or inferred_cert.exists():
            return inferred_cert.resolve()
    if args.create_signing_key:
        return default_signing_cert(plugin_name).resolve()
    return None


def discover_plugins() -> Dict[str, Path]:
    plugins: Dict[str, Path] = {}
    for metadata_path in sorted(PLUGINS_ROOT.glob("*/plugin.json")):
        metadata = load_metadata(metadata_path)
        plugins[metadata["pluginName"]] = metadata_path
    return plugins


def set_tar_mode(tar_info: tarfile.TarInfo, source: Path) -> tarfile.TarInfo:
    if source.is_dir():
        tar_info.mode = 0o755
    elif "bin" in source.parts:
        tar_info.mode = 0o755
    else:
        tar_info.mode = 0o644
    tar_info.uid = 0
    tar_info.gid = 0
    tar_info.uname = ""
    tar_info.gname = ""
    tar_info.mtime = REPRODUCIBLE_MTIME
    return tar_info


def add_path(tar: tarfile.TarFile, source: Path, arcname: str) -> None:
    if source.name in IGNORED_NAMES or source.suffix in IGNORED_SUFFIXES:
        return

    if source.is_dir():
        info = tarfile.TarInfo(arcname)
        info.type = tarfile.DIRTYPE
        set_tar_mode(info, source)
        tar.addfile(info)
        for child in sorted(source.iterdir(), key=lambda item: item.name):
            add_path(tar, child, f"{arcname}/{child.name}")
        return

    data = source.read_bytes()
    info = tarfile.TarInfo(arcname)
    info.size = len(data)
    set_tar_mode(info, source)
    tar.addfile(info, io.BytesIO(data))


def stage_plugin(plugin_name: str, dirs: Dict[str, List[str]], destination: Path) -> None:
    if destination.exists():
        shutil.rmtree(destination)

    for target_dir, entries in dirs.items():
        stage_dir = destination / target_dir
        stage_dir.mkdir(parents=True, exist_ok=True)

        for entry in entries:
            source = ROOT / entry
            if not source.exists():
                raise FileNotFoundError(f"Missing file listed in {plugin_name} manifest: {entry}")
            target = stage_dir / source.name
            shutil.copy2(source, target)


def write_tar_gz(destination: Path, writer: "callable") -> None:
    with destination.open("wb") as raw_handle:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw_handle, mtime=REPRODUCIBLE_MTIME) as gz_handle:
            with tarfile.open(fileobj=gz_handle, mode="w") as tar:
                writer(tar)


def build_archive(staged_root: Path, destination: Path) -> None:
    def write_members(tar: tarfile.TarFile) -> None:
        for child in sorted(staged_root.iterdir(), key=lambda item: item.name):
            add_path(tar, child, child.name)

    write_tar_gz(destination, write_members)


def sign_archive_with_cryptography(signing_key: Path, archive_path: Path, raw_signature: Path) -> None:
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.hazmat.primitives.asymmetric import dsa, ec, ed25519, ed448, padding, rsa

    private_key = serialization.load_pem_private_key(signing_key.read_bytes(), password=None)
    payload = archive_path.read_bytes()

    if isinstance(private_key, rsa.RSAPrivateKey):
        signature = private_key.sign(payload, padding.PKCS1v15(), hashes.SHA256())
    elif isinstance(private_key, ec.EllipticCurvePrivateKey):
        signature = private_key.sign(payload, ec.ECDSA(hashes.SHA256()))
    elif isinstance(private_key, dsa.DSAPrivateKey):
        signature = private_key.sign(payload, hashes.SHA256())
    elif isinstance(private_key, ed25519.Ed25519PrivateKey):
        signature = private_key.sign(payload)
    elif isinstance(private_key, ed448.Ed448PrivateKey):
        signature = private_key.sign(payload)
    else:
        raise TypeError("Unsupported private key type for signing")

    raw_signature.write_bytes(signature)


def create_signing_key(signing_key: Path) -> None:
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric import rsa

    signing_key.parent.mkdir(parents=True, exist_ok=True)
    private_key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    pem = private_key.private_bytes(
        encoding=serialization.Encoding.PEM,
        format=serialization.PrivateFormat.TraditionalOpenSSL,
        encryption_algorithm=serialization.NoEncryption(),
    )
    signing_key.write_bytes(pem)


def create_signing_cert(plugin_name: str, signing_key: Path, signing_cert: Path) -> None:
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes, serialization
    from cryptography.x509.oid import NameOID

    private_key = serialization.load_pem_private_key(signing_key.read_bytes(), password=None)
    subject = issuer = x509.Name(
        [
            x509.NameAttribute(NameOID.COUNTRY_NAME, "US"),
            x509.NameAttribute(NameOID.ORGANIZATION_NAME, plugin_name),
            x509.NameAttribute(NameOID.ORGANIZATIONAL_UNIT_NAME, "Agent Client Collector"),
            x509.NameAttribute(NameOID.COMMON_NAME, plugin_name),
        ]
    )
    now = datetime.datetime.now(datetime.timezone.utc)
    cert = (
        x509.CertificateBuilder()
        .subject_name(subject)
        .issuer_name(issuer)
        .public_key(private_key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - datetime.timedelta(minutes=5))
        .not_valid_after(now + datetime.timedelta(days=365))
        .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
        .add_extension(x509.SubjectKeyIdentifier.from_public_key(private_key.public_key()), critical=False)
        .sign(private_key, hashes.SHA256())
    )
    signing_cert.parent.mkdir(parents=True, exist_ok=True)
    signing_cert.write_bytes(cert.public_bytes(serialization.Encoding.PEM))


def verify_signature_with_cert(signing_cert: Path, archive_path: Path, raw_signature: Path) -> None:
    from cryptography import x509
    from cryptography.hazmat.primitives import hashes
    from cryptography.hazmat.primitives.asymmetric import dsa, ec, ed25519, ed448, padding, rsa

    cert = x509.load_pem_x509_certificate(signing_cert.read_bytes())
    public_key = cert.public_key()
    payload = archive_path.read_bytes()
    signature = raw_signature.read_bytes()

    if isinstance(public_key, rsa.RSAPublicKey):
        public_key.verify(signature, payload, padding.PKCS1v15(), hashes.SHA256())
    elif isinstance(public_key, ec.EllipticCurvePublicKey):
        public_key.verify(signature, payload, ec.ECDSA(hashes.SHA256()))
    elif isinstance(public_key, dsa.DSAPublicKey):
        public_key.verify(signature, payload, hashes.SHA256())
    elif isinstance(public_key, ed25519.Ed25519PublicKey):
        public_key.verify(signature, payload)
    elif isinstance(public_key, ed448.Ed448PublicKey):
        public_key.verify(signature, payload)
    else:
        raise TypeError("Unsupported public key type for signature verification")


def sign_archive(openssl_bin: str, signing_key: Path, archive_path: Path, output_dir: Path) -> Path:
    raw_signature = output_dir / SIGNATURE_RAW_NAME
    encoded_signature = output_dir / SIGNATURE_ENCODED_NAME

    if not signing_key.exists():
        raise FileNotFoundError(f"Signing key not found: {signing_key}")

    openssl_path = shutil.which(openssl_bin)
    if openssl_path:
        subprocess.run(
            [
                openssl_path,
                "dgst",
                "-sha256",
                "-sign",
                str(signing_key),
                "-out",
                str(raw_signature),
                str(archive_path),
            ],
            check=True,
            capture_output=True,
            text=True,
        )
    else:
        try:
            sign_archive_with_cryptography(signing_key, archive_path, raw_signature)
        except ModuleNotFoundError as exc:
            raise RuntimeError(
                "Signing requires either openssl on PATH or the Python 'cryptography' package."
            ) from exc

    encoded_signature.write_bytes(base64.b64encode(raw_signature.read_bytes()))
    return encoded_signature


def build_signed_bundle(final_bundle: Path, inner_archive: Path, signature_file: Path) -> None:
    def write_members(tar: tarfile.TarFile) -> None:
        add_path(tar, inner_archive, inner_archive.name)
        add_path(tar, signature_file, signature_file.name)

    write_tar_gz(final_bundle, write_members)


def export_signed_artifacts(
    output_dir: Path,
    inner_archive: Path,
    signature_file: Path,
    signing_cert: Path | None,
) -> Path | None:
    inner_export = output_dir / f"{archive_basename(inner_archive)}-inner.tar.gz"
    signature_export = output_dir / signature_file.name
    shutil.copy2(inner_archive, inner_export)
    shutil.copy2(signature_file, signature_export)
    if signing_cert is None:
        return None
    cert_export = output_dir / SIGNING_CERT_EXPORT_NAME
    shutil.copy2(signing_cert, cert_export)
    return cert_export


def describe_bundle(bundle_path: Path) -> List[str]:
    with tarfile.open(bundle_path, "r:gz") as tar:
        return [member.name for member in tar.getmembers()]


def validate_bundle(bundle_path: Path, dirs: Dict[str, List[str]]) -> None:
    names = set(describe_bundle(bundle_path))
    required = set(dirs.keys())
    for target_dir, entries in dirs.items():
        for entry in entries:
            required.add(f"{target_dir}/{Path(entry).name}")
    missing = sorted(required - names)
    if missing:
        raise RuntimeError(f"Bundle is missing expected entries: {', '.join(missing)}")


def validate_signed_bundle(bundle_path: Path, plugin_name: str) -> None:
    names = set(describe_bundle(bundle_path))
    required_outer = {
        f"{plugin_name}.tar.gz",
        SIGNATURE_ENCODED_NAME,
    }
    missing_outer = sorted(required_outer - names)
    if missing_outer:
        raise RuntimeError(f"Signed bundle is missing expected outer entries: {', '.join(missing_outer)}")


def validate_signed_inputs(signing_key: Path | None, signing_cert: Path | None) -> None:
    if signing_key is not None and signing_cert is None:
        raise RuntimeError(
            "Signed builds require a signing certificate so the generated signature can be verified. "
            "Pass --signing-cert or use --create-signing-key."
        )


def remove_work_dir(path: Path) -> None:
    for attempt in range(3):
        try:
            shutil.rmtree(path)
            return
        except PermissionError:
            if attempt == 2:
                print(f"Warning: could not remove temporary work directory: {path}")
                return
            time.sleep(0.2)
        except OSError:
            for child in path.rglob("*"):
                try:
                    os.chmod(child, 0o700)
                except OSError:
                    pass
            time.sleep(0.2)


def remove_file(path: Path) -> None:
    for attempt in range(10):
        try:
            path.unlink()
            return
        except PermissionError:
            if attempt == 9:
                raise
            time.sleep(0.5)


def available_bundle_path(path: Path) -> Path:
    if not path.exists():
        return path
    try:
        remove_file(path)
        return path
    except PermissionError:
        timestamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%d%H%M%S")
        fallback = path.with_name(f"{path.stem}-{timestamp}{path.suffix}")
        print(f"Warning: existing output is locked, writing {fallback.name} instead")
        return fallback


def main() -> int:
    args = parse_args()
    output_dir = (ROOT / args.output_dir).resolve()
    work_root = output_dir / "work"
    work_dir = work_root / f"run-{os.getpid()}-{int(time.time() * 1000)}"
    output_dir.mkdir(parents=True, exist_ok=True)
    work_dir.mkdir(parents=True, exist_ok=True)

    available_plugins = discover_plugins()
    selected = args.plugin or sorted(available_plugins.keys())
    unknown = [name for name in selected if name not in available_plugins]
    if unknown:
        raise ValueError(f"Unknown plugin(s): {', '.join(unknown)}")

    for plugin_name in selected:
        metadata = load_metadata(available_plugins[plugin_name])
        signing_key = resolve_signing_key(args, plugin_name)
        signing_cert = resolve_signing_cert(args, plugin_name, signing_key)
        validate_signed_inputs(signing_key, signing_cert)

        if args.create_signing_key and signing_key is not None and not signing_key.exists():
            create_signing_key(signing_key)
            print(f"Created signing key: {signing_key}")
        if args.create_signing_key and signing_key is not None and signing_cert is not None and not signing_cert.exists():
            create_signing_cert(plugin_name, signing_key, signing_cert)
            print(f"Created signing certificate: {signing_cert}")

        staged_root = work_dir / plugin_name / "stage"
        inner_archive = work_dir / plugin_name / f"{plugin_name}.tar.gz"
        final_bundle = available_bundle_path(output_dir / f"{plugin_name}.tar.gz")
        plugin_work_dir = work_dir / plugin_name
        plugin_work_dir.mkdir(parents=True, exist_ok=True)

        if inner_archive.exists():
            remove_file(inner_archive)

        stage_plugin(plugin_name, metadata["dirs"], staged_root)
        build_archive(staged_root, inner_archive)

        if signing_key is not None:
            signature = sign_archive(
                args.openssl_bin,
                signing_key,
                inner_archive,
                plugin_work_dir,
            )
            raw_signature = plugin_work_dir / SIGNATURE_RAW_NAME
            verify_signature_with_cert(signing_cert, inner_archive, raw_signature)
            print(f"Verified signature for {inner_archive.name} with {signing_cert}")
            build_signed_bundle(final_bundle, inner_archive, signature)
            cert_export = export_signed_artifacts(output_dir, inner_archive, signature, signing_cert)
            validate_signed_bundle(final_bundle, plugin_name)
            validate_bundle(inner_archive, metadata["dirs"])
            mode = "signed"
        else:
            shutil.copy2(inner_archive, final_bundle)
            validate_bundle(final_bundle, metadata["dirs"])
            mode = "unsigned"

        print(f"Built {mode} bundle: {final_bundle}")
        print("Bundle contents:")
        for name in describe_bundle(final_bundle):
            print(f" - {name}")
        if signing_key is not None:
            print(f"Exported inner plugin archive: {output_dir / (archive_basename(inner_archive) + '-inner.tar.gz')}")
            print(f"Exported signature file: {output_dir / signature.name}")
            if cert_export is not None:
                print(f"Exported signing certificate: {cert_export}")
            print(f"ServiceNow upload artifact: {final_bundle}")
        else:
            print("Warning: unsigned bundle is for local inspection only and may not be loadable in ServiceNow environments that require signed plugins.")

    if not args.keep_work and work_dir.exists():
        remove_work_dir(work_dir)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
