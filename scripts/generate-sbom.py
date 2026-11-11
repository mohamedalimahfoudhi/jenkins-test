#!/usr/bin/env python3
#
# scripts/generate-sbom.py
# Turns the output of `mvn dependency:list` into a CycloneDX 1.5 SBOM.
#
# Why this exists
# ---------------
# The pipeline scans dependencies without Docker and without the NVD feed, with
# Trivy. But Trivy's fs scanner reads pom.xml only, and this project inherits
# its versions from spring-boot-starter-parent, so pom.xml names almost no
# version: `trivy fs .` reports "pom.xml: 0 vulnerabilities" no matter what is
# actually on the classpath (verified with trivy 0.76.2). Trivy's fs scanner
# does not open the jars either ("language-specific files num=0"). A scan that
# can never fail is not a gate.
#
# Maven already knows the resolved set, so the pipeline asks Maven for it and
# converts it here. Trivy then scans the SBOM with its own database: no API key,
# no quota, and it covers the transitive dependencies that actually ship.
#
# Fails closed: an empty or unreadable dependency list exits 1, because an SBOM
# with no components would make the Trivy scan pass vacuously.
#
# Usage:
#   python3 scripts/generate-sbom.py reports/dependencies.txt reports/sbom-cyclonedx.json

import json
import re
import sys

# "   org.springframework.boot:spring-boot-starter-web:jar:4.1.2:compile -- module ..."
LINE = re.compile(r"^\s+([\w.\-]+):([\w.\-]+):([\w\-]+):([^:\s]+):(\w+)")
ARTIFACT_KINDS = {"jar", "bundle", "ejb"}
NON_RUNTIME_SCOPES = {"test", "provided", "system"}


def main(argv):
    if len(argv) != 3:
        print("usage: generate-sbom.py <mvn dependency:list output> <output sbom>",
              file=sys.stderr)
        return 2

    source, destination = argv[1], argv[2]
    try:
        with open(source, encoding="utf-8", errors="replace") as handle:
            lines = handle.readlines()
    except OSError as exc:
        print("ERROR: cannot read %s: %s" % (source, exc), file=sys.stderr)
        return 1

    components = []
    seen = set()
    for line in lines:
        match = LINE.match(line)
        if not match:
            continue
        group, artifact, kind, version, scope = match.groups()
        if kind not in ARTIFACT_KINDS:
            continue
        if scope in NON_RUNTIME_SCOPES:
            continue
        key = (group, artifact, version)
        if key in seen:
            continue
        seen.add(key)
        components.append({
            "type": "library",
            "group": group,
            "name": artifact,
            "version": version,
            "purl": "pkg:maven/%s/%s@%s" % (group, artifact, version),
        })

    if not components:
        print("ERROR: no dependency parsed from %s - refusing to write an empty SBOM, "
              "because the Trivy scan of it could never fail" % source, file=sys.stderr)
        return 1

    bom = {
        "bomFormat": "CycloneDX",
        "specVersion": "1.5",
        "version": 1,
        "metadata": {
            "component": {
                "type": "application",
                "name": "devops-demo",
                "version": "0.0.1-SNAPSHOT",
            }
        },
        "components": components,
    }

    with open(destination, "w", encoding="utf-8") as handle:
        json.dump(bom, handle, indent=1)
        handle.write("\n")

    print("SBOM written: %s (%d components)" % (destination, len(components)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
