#!/usr/bin/env python3
"""Build a minimal OCI archive of the static enrolld binary for k3s ctr import."""
import hashlib
import io
import json
import sys
import tarfile
from pathlib import Path


def blob(obj):
    return json.dumps(obj, separators=(",", ":"), sort_keys=True).encode()


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main(binary, output):
    binary_data = Path(binary).read_bytes()
    layer_io = io.BytesIO()
    with tarfile.open(fileobj=layer_io, mode="w") as tar:
        info = tarfile.TarInfo("enrolld")
        info.size = len(binary_data)
        info.mode = 0o755
        info.mtime = 0
        tar.addfile(info, io.BytesIO(binary_data))
    layer = layer_io.getvalue()
    config = blob({
        "architecture": "amd64", "os": "linux",
        "config": {"Entrypoint": ["/enrolld"]},
        "rootfs": {"type": "layers", "diff_ids": ["sha256:" + digest(layer)]},
        "history": [{"created_by": "o4-build-image.py"}],
    })
    manifest = blob({
        "schemaVersion": 2,
        "mediaType": "application/vnd.oci.image.manifest.v1+json",
        "config": {"mediaType": "application/vnd.oci.image.config.v1+json", "digest": "sha256:" + digest(config), "size": len(config)},
        "layers": [{"mediaType": "application/vnd.oci.image.layer.v1.tar", "digest": "sha256:" + digest(layer), "size": len(layer)}],
    })
    index = blob({
        "schemaVersion": 2,
        "manifests": [{"mediaType": "application/vnd.oci.image.manifest.v1+json", "digest": "sha256:" + digest(manifest), "size": len(manifest), "annotations": {"org.opencontainers.image.ref.name": "localhost/enrolld:o4"}}],
    })
    with tarfile.open(output, "w") as tar:
        for name, data in [
            ("oci-layout", b'{"imageLayoutVersion":"1.0.0"}'),
            ("index.json", index),
            (f"blobs/sha256/{digest(config)}", config),
            (f"blobs/sha256/{digest(manifest)}", manifest),
            (f"blobs/sha256/{digest(layer)}", layer),
        ]:
            info = tarfile.TarInfo(name)
            info.size = len(data)
            info.mode = 0o644
            info.mtime = 0
            tar.addfile(info, io.BytesIO(data))
    print(f"{output}: image localhost/enrolld:o4, {len(binary_data)} binary bytes")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: o4-build-image.py bin/enrolld image.tar")
    main(sys.argv[1], sys.argv[2])
