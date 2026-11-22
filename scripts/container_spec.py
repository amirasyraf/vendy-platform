#!/usr/bin/env python3
"""Validate and normalize a container entity spec (stdin JSON -> stdout JSON).

Mirrors the IDP's normalizeSpec in vendy-idp/plugins/cf-backend/src/containers.ts; see
vendy/CONTRACTS.md §12. Exit status 1 with the reason on stderr when invalid.
"""

import json
import re
import sys

SIZES = ("XS", "S", "M")
IMAGE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._/:@-]{0,254}$")
ENV_KEY = re.compile(r"^[A-Za-z_][A-Za-z0-9_]{0,63}$")
CONTROL = re.compile(r"[\x00-\x1f\x7f]")


def fail(message: str) -> None:
    print(message, file=sys.stderr)
    sys.exit(1)


def text(value, maximum: int, minimum: int = 1) -> bool:
    return isinstance(value, str) and minimum <= len(value) <= maximum and not CONTROL.search(value)


def integer(value) -> bool:
    return isinstance(value, int) and not isinstance(value, bool)


def container(value) -> dict:
    if not isinstance(value, dict):
        fail("spec.container must be an object")
    known = {"platform", "arch", "image", "port", "size", "replicas", "public", "env"}
    unknown = sorted(set(value) - known)
    if unknown:
        fail(f"Unknown container fields: {', '.join(unknown)}")
    if value.get("platform") not in ("aws", "azure"):
        fail("Platform must be aws or azure")
    arch = value.get("arch", "amd64")
    if arch not in ("amd64", "arm64"):
        fail("Architecture must be amd64 or arm64")
    image = value.get("image")
    if not isinstance(image, str) or not IMAGE.match(image) or ".." in image:
        fail("Invalid container image reference")
    port = value.get("port")
    if not integer(port) or not 1 <= port <= 65535:
        fail("Port must be 1-65535")
    size = value.get("size", "XS")
    if size not in SIZES:
        fail("Size must be XS, S or M")
    replicas = value.get("replicas", 1)
    if not integer(replicas) or not 1 <= replicas <= 2:
        fail("Replicas must be 1 or 2")
    public = value.get("public", True)
    if not isinstance(public, bool):
        fail("public must be true or false")
    env = value.get("env", {})
    if not isinstance(env, dict) or len(env) > 20:
        fail("env must be an object with at most 20 entries")
    for key, val in env.items():
        if not ENV_KEY.match(key) or not text(val, 1024, 0):
            fail(f"Invalid environment variable {key}")
    return {"platform": value["platform"], "arch": arch, "image": image, "port": port, "size": size,
            "replicas": replicas, "public": public, "env": env}


def main() -> None:
    try:
        spec = json.load(sys.stdin)
    except ValueError:
        fail("Spec is not JSON")
    if not isinstance(spec, dict):
        fail("Spec must be an object")
    unknown = sorted(set(spec) - {"type", "owner", "lifecycle", "container", "billing", "cloudTags"})
    if unknown:
        fail(f"Unknown spec fields: {', '.join(unknown)}")
    if spec.get("type") != "container":
        fail("spec.type must be container")
    match = re.fullmatch(r"(?:group:(?:default/)?)?([a-z][a-z0-9-]*)", str(spec.get("owner", "")))
    if not match:
        fail("spec.owner must be a team")
    lifecycle = spec.get("lifecycle", "poc")
    if not text(lifecycle, 64):
        fail("Invalid lifecycle")
    billing = spec.get("billing")
    if (not isinstance(billing, dict) or set(billing) != {"costCenter", "projectCode"}
            or not text(billing["costCenter"], 256) or not text(billing["projectCode"], 256)):
        fail("billing needs costCenter and projectCode")
    tags = spec.get("cloudTags", {})
    if not isinstance(tags, dict) or len(tags) > 40:
        fail("cloudTags must be an object with at most 40 entries")
    for key, val in tags.items():
        if not text(key, 128) or not text(val, 256, 0):
            fail(f"Invalid tag {key}")
    json.dump({"type": "container", "owner": f"group:default/{match.group(1)}", "lifecycle": lifecycle,
               "container": container(spec.get("container")), "billing": billing, "cloudTags": tags},
              sys.stdout, separators=(",", ":"))


if __name__ == "__main__":
    main()
