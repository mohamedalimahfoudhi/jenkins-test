#!/usr/bin/env python3
"""Generate one self-contained HTML report per pipeline tool, for Jenkins.

What this produces
------------------
Every stage writes its evidence into ``reports/`` (txt / json / xml / html).
This script turns that evidence into one standalone page per tool:

    reports/html/index.html                 overview of every tool and its status
    reports/html/<tool>/index.html          that tool's report
    reports/html/<tool>/<raw file>          copy of the raw evidence, downloadable

The Jenkinsfile publishes each ``reports/html/<tool>`` directory with its own
``publishHTML`` call, so the build page grows one link per tool instead of a
single bundle. Nothing here talks to Jenkins: it only reads files and writes
HTML.

Honesty rules
-------------
* A clean scan says so ("0 findings"), it is never left blank and never turned
  into a fake success.
* Statuses come from what the stage actually wrote plus the Jenkins parameter
  that controls the stage. A stage that never ran is SKIPPED or NOT RUN, never
  PASS.
* A tool that failed before writing anything still gets a page that explains
  that, and the page links to the raw file when one exists.
* All tool output is escaped. A report containing ``<script>`` is displayed as
  text.
* The script exits 0 even when everything is missing: report rendering must
  never change a build's result, and must never hide a security failure.

Usage
-----
    python3 scripts/render-reports.py                     # reports -> reports/html
    python3 scripts/render-reports.py reports reports/html
    python3 scripts/render-reports.py --surefire target/surefire-reports
    python3 scripts/render-reports.py --params reports/state/params.txt

Only the Python 3 standard library is used: the VM has python3 for the SBOM
stage, and no network access is needed or attempted.
"""

from __future__ import annotations

import html
import json
import re
import shutil
import sys
import traceback
from datetime import datetime, timezone
from pathlib import Path
from xml.etree import ElementTree

# --------------------------------------------------------------------------
# Tool table: the order is the reading order of the overview and of the
# Jenkinsfile publishHTML calls. `slug` is also the report directory name.
# --------------------------------------------------------------------------
TOOLS = [
    dict(slug="checkout", title="Checkout Report", phase="Phase 1", stage="Checkout",
         kind="plain", bin="git", param=None,
         files=["checkout-report.txt"],
         note="The revision Jenkins compiled: the last five commits of the branch."),
    dict(slug="preflight", title="Preflight Tool Checks Report", phase="Phase 1",
         stage="Preflight (tool checks)", kind="checks", bin=None, param=None,
         files=["preflight-report.txt"],
         note="Every scanner the build needs, checked before any stage depends on it."),
    dict(slug="compile", title="Maven Compile Report", phase="Phase 1", stage="Build",
         kind="maven", bin="maven", param=None,
         files=["maven-compile-report.txt"],
         note="Compilation of the Spring Boot application."),
    dict(slug="unit-tests", title="Maven Tests Report", phase="Phase 1",
         stage="Unit and security tests", kind="surefire", bin="maven", param=None,
         files=["maven-test-report.txt"],
         note="JUnit results from target/surefire-reports, the same files Jenkins "
              "shows under Test Result."),
    dict(slug="gitleaks", title="Gitleaks Report", phase="Phase 1",
         stage="Secrets scan (Gitleaks)", kind="gitleaks", bin="gitleaks", param=None,
         json="gitleaks-report.json", log="gitleaks-log.txt",
         files=["gitleaks-report.json", "gitleaks-log.txt", "gitleaks-summary.txt"],
         note="Whole-history scan with --redact: matches are listed, secret values "
              "are never reproduced."),
    dict(slug="dependency-check", title="Dependency-Check Report", phase="Phase 1",
         stage="Dependency scan (OWASP Dependency-Check)", kind="dependencycheck",
         bin="dependency-check", param="RUN_DEPENDENCY_CHECK",
         xml="dependency-check-report.xml",
         files=["dependency-check-report.xml", "dependency-check-report.html",
                "state/dependency-check-version.txt"],
         note="NVD-backed software composition analysis of the jars Maven resolves "
              "for the runtime. The stage gates on --failOnCVSS 9, so a CRITICAL "
              "(score >= 9.0) finding fails the build."),
    dict(slug="trivy-fs", title="Trivy Filesystem Report", phase="Phase 1",
         stage="Dependency scan (Trivy fs)", kind="trivy", bin="trivy",
         param="RUN_TRIVY_FS",          text="trivy-fs-report.txt",
         json="trivy-fs-report.json",
         also_text=["trivy-fs-resolved-report.txt"],
         also_json=["trivy-fs-resolved-report.json"],
         files=["trivy-fs-report.txt", "trivy-fs-report.json",
                "trivy-fs-resolved-report.txt", "trivy-fs-resolved-report.json",
                "dependencies.txt", "sbom-cyclonedx.json"],
         note="Two scans: the repository itself, then the dependency set Maven "
              "actually resolves, passed to Trivy as a CycloneDX SBOM."),
    dict(slug="sonar", title="SonarQube Report", phase="Phase 1",
         stage="SAST (SonarQube)", kind="sonar", bin="maven", param="RUN_SONAR",
         files=["sonar-report.txt"],
         note="Quality-gate and analysis results live in SonarQube; this page shows "
              "what the scanner run itself reported."),
    dict(slug="image-build", title="Docker Image Build Report", phase="Phase 2",
         stage="Container image (build)", kind="plain", bin="docker",
         param="BUILD_IMAGE", files=["docker-build-report.txt", "image-id.txt"],
         note="Build of the image every container stage runs."),
    dict(slug="hadolint", title="Hadolint Report", phase="Phase 2",
         stage="Dockerfile lint (hadolint)", kind="hadolint", bin="hadolint", param=None,
         files=["hadolint-report.txt"],
         note="Static analysis of the Dockerfile; an empty result means no findings."),
    dict(slug="trivy-image", title="Trivy Image Report", phase="Phase 2",
         stage="Container scan (Trivy)", kind="trivy", bin="trivy",
         param="TRIVY_SCAN", text="trivy-report.txt", json="trivy-report.json",
         files=["trivy-report.txt", "trivy-report.json"],
         note="Operating-system and application packages inside devsecops-demo:ci. "
              "The stage fails the build on CRITICAL."),
    dict(slug="deploy", title="Application Deploy Report", phase="Phase 2",
         stage="Deploy application container", kind="plain", bin="docker",
         param="DEPLOY_CONTAINER", files=["deploy-report.txt"],
         note="The acceptance container the DAST and acceptance stages test."),
    dict(slug="zap", title="OWASP ZAP Report", phase="Phase 2",
         stage="DAST (OWASP ZAP baseline)", kind="zap", bin="docker",
         param="ZAP_SCAN", json="zap-report.json",
         files=["zap-report.json", "zap-report.html"],
         note="Passive baseline scan of the running container's /hello endpoint."),
    dict(slug="acceptance", title="Acceptance Tests Report", phase="Phase 2",
         stage="Security acceptance tests", kind="checks", bin="curl",
         param="ACCEPTANCE_TESTS", files=["acceptance-report.txt"],
         note="Status codes and security headers the application must return."),
    dict(slug="infra", title="Infrastructure Report", phase="Phase 2",
         stage="Infrastructure test (VM)", kind="checks", bin=None,
         param="INFRA_TEST", files=["infra-report.txt"],
         note="CPU, memory, swap, disk, JVM, Maven, Docker and scanner presence on the VM."),
    dict(slug="compliance", title="Compliance Report", phase="Phase 2",
         stage="Compliance check (policy)", kind="checks", bin=None,
         param="COMPLIANCE_CHECK", files=["compliance-report.txt"],
         note="Dockerfile and Jenkinsfile checked against the course policy."),
    dict(slug="sbom", title="SBOM Report", phase="Phase 2",
         stage="Dependency scan (Trivy fs)", kind="sbom", bin="python3", param=None,
         json="sbom-cyclonedx.json", files=["sbom-cyclonedx.json", "dependencies.txt"],
         note="Software bill of materials generated from the resolved runtime "
              "dependency list and consumed by the Trivy SBOM scan."),
    dict(slug="prod-deploy", title="Production Deployment Report", phase="Phase 3",
         stage="Deploy production container", kind="plain", bin="docker",
         param="PROD_DEPLOY", files=["prod-deploy-report.txt"],
         note="Production container started with a runtime secret injected from "
              "Jenkins credentials. The secret value never enters the report."),
    dict(slug="smoke", title="Security Smoke Tests Report", phase="Phase 3",
         stage="Security smoke tests", kind="checks", bin="curl",
         param="SECURITY_SMOKE", files=["smoke-report.txt"],
         note="Post-deployment checks against whichever container is running."),
    dict(slug="config-safety", title="Configuration Safety Report", phase="Phase 3",
         stage="Configuration safety check", kind="checks", bin="docker",
         param="CONFIG_SAFETY", files=["config-safety-report.txt"],
         note="Ports, non-root user and runtime-secret handling of the deployed container."),
    dict(slug="monitoring-stack", title="Monitoring Stack Report", phase="Phase 4",
         stage="Operations: monitoring stack", kind="plain", bin="docker",
         param="MONITORING", files=["monitoring-stack-report.txt"],
         note="Prometheus, Grafana, Alertmanager and node-exporter brought up by "
              "scripts/install-phase4.sh."),
    dict(slug="prometheus", title="Prometheus Report", phase="Phase 4",
         stage="Operations: metrics and alerts check", kind="monitoring",
         component="prometheus", bin="prometheus", param="MONITORING",
         files=["monitoring-report.txt"],
         note="Prometheus readiness, application scrape target, JVM metrics and "
              "alert rules."),
    dict(slug="grafana", title="Grafana Report", phase="Phase 4",
         stage="Operations: metrics and alerts check", kind="monitoring",
         component="grafana", bin="grafana", param="MONITORING",
         files=["monitoring-report.txt"],
         note="Grafana health and the provisioned DevSecOps dashboard."),
    dict(slug="alertmanager", title="Alertmanager Report", phase="Phase 4",
         stage="Operations: metrics and alerts check", kind="monitoring",
         component="alertmanager", bin="alertmanager", param="MONITORING",
         files=["monitoring-report.txt"],
         note="Alertmanager readiness and the alerts Prometheus currently has loaded "
              "and firing."),
    dict(slug="node-exporter", title="Node Exporter Report", phase="Phase 4",
         stage="Operations: metrics and alerts check", kind="monitoring",
         component="node", bin="node-exporter", param="MONITORING",
         files=["monitoring-report.txt"],
         note="Host metrics exporter: loopback-only exposure and the Prometheus "
              "target that scrapes it."),
    dict(slug="monitoring", title="Monitoring Validation Report", phase="Phase 4",
         stage="Operations: metrics and alerts check", kind="monitoring",
         component=None, bin=None, param="MONITORING",
         files=["monitoring-report.txt"],
         note="Every check of the monitoring stage in one page."),
]

# The link text on the Jenkins job page is the report name, so keep these short
# and unambiguous: they are what the sidebar shows.
PHASES = ["Phase 1", "Phase 2", "Phase 3", "Phase 4"]

CSS = """
:root{--bg:#f5f7fa;--panel:#fff;--ink:#1b2430;--muted:#5b6779;--line:#dde3ea;
--accent:#0b63b8;--pass:#12734a;--fail:#b3261e;--warn:#8a5900;--idle:#55617a;}
*{box-sizing:border-box}
body{margin:0;padding:28px 20px 60px;background:var(--bg);color:var(--ink);
font:15.5px/1.55 -apple-system,"Segoe UI",Roboto,Helvetica,Arial,sans-serif}
main{max-width:1120px;margin:0 auto}
a{color:var(--accent);text-decoration:none}
a:hover{text-decoration:underline}
h1{font-size:25px;margin:0 0 2px;letter-spacing:-.01em}
h2{font-size:16px;margin:26px 0 8px;text-transform:uppercase;letter-spacing:.05em;color:var(--muted)}
h3{font-size:15px;margin:20px 0 6px}
.sub{color:var(--muted);font-size:14px;margin:0 0 18px}
table{width:100%;border-collapse:collapse;font-size:14px;background:var(--panel);
border:1px solid var(--line);border-radius:9px;overflow:hidden}
th,td{text-align:left;padding:8px 11px;border-bottom:1px solid var(--line);vertical-align:top}
th{font-size:11.5px;text-transform:uppercase;letter-spacing:.05em;color:var(--muted)}
tr:last-child td{border-bottom:0}
td.num{font-variant-numeric:tabular-nums;white-space:nowrap}
code,pre{font-family:ui-monospace,"SF Mono",Menlo,Consolas,monospace;font-size:12.5px}
code{background:#eef1f6;padding:1px 5px;border-radius:4px}
pre{background:var(--panel);border:1px solid var(--line);border-radius:9px;
padding:12px 14px;overflow-x:auto;margin:0;white-space:pre-wrap;word-break:break-word}
pre .l-pass{color:var(--pass);font-weight:650}
pre .l-fail{color:var(--fail);font-weight:650}
pre .l-warn{color:var(--warn)}
pre .l-info{color:var(--muted)}
.badge{display:inline-block;font-size:12.5px;font-weight:700;letter-spacing:.03em;
padding:2px 10px;border-radius:999px;color:#fff}
.b-pass{background:var(--pass)}.b-fail{background:var(--fail)}
.b-warning{background:var(--warn)}.b-skipped,.b-not-run{background:var(--idle)}
.missing{color:var(--muted);font-style:italic}
.note{background:#fbfcfe;border-left:3px solid var(--accent);padding:10px 14px;
border-radius:0 8px 8px 0;font-size:14px;margin:14px 0}
details{margin-top:8px}
summary{cursor:pointer;font-size:13.5px;color:var(--accent);margin-bottom:8px}
.tiles{display:flex;flex-wrap:wrap;gap:10px;margin:6px 0 4px}
.tile{background:var(--panel);border:1px solid var(--line);border-radius:9px;
padding:10px 16px;min-width:120px}
.tile b{display:block;font-size:22px;line-height:1.2}
.tile span{font-size:12px;color:var(--muted);text-transform:uppercase;letter-spacing:.04em}
.sev-CRITICAL{color:var(--fail);font-weight:700}
.sev-HIGH{color:#c2410c;font-weight:650}
.sev-MEDIUM{color:var(--warn);font-weight:650}
.sev-LOW,.sev-UNKNOWN,.sev-INFO{color:var(--muted)}
footer{color:var(--muted);font-size:12.5px;margin-top:30px}
"""


# --------------------------------------------------------------------------
# small helpers
# --------------------------------------------------------------------------
def esc(value: object) -> str:
    return html.escape(str(value), quote=True)


def read(path: Path) -> str | None:
    try:
        return path.read_text(encoding="utf-8", errors="replace")
    except OSError:
        return None


def page(title: str, body: str, subtitle: str = "", status: str | None = None) -> str:
    badge = ""
    if status:
        css_status = status.lower().replace(" ", "-")
        badge = f'<span class="badge b-{css_status}">{esc(status)}</span> '
    sub = f'<p class="sub">{esc(subtitle)}</p>' if subtitle else ""
    return (
        '<!DOCTYPE html>\n<html lang="en">\n<head>\n<meta charset="utf-8">\n'
        '<meta name="viewport" content="width=device-width, initial-scale=1">\n'
        f"<title>{esc(title)}</title>\n<style>{CSS}</style>\n</head>\n<body>\n<main>\n"
        f"<h1>{badge}{esc(title)}</h1>\n{sub}\n{body}\n"
        '<footer>Generated by scripts/render-reports.py from the files this build '
        "wrote. No result on this page is inferred, defaulted or hardcoded.</footer>\n"
        "</main>\n</body>\n</html>\n"
    )


def table(headers: list[str], rows: list[list[str]], numeric: tuple[int, ...] = ()) -> str:
    head = "".join(f"<th>{esc(h)}</th>" for h in headers)
    body = []
    for row in rows:
        cells = "".join(
            f'<td class="num">{c}</td>' if i in numeric else f"<td>{c}</td>"
            for i, c in enumerate(row)
        )
        body.append(f"<tr>{cells}</tr>")
    return f"<table>\n<tr>{head}</tr>\n" + "\n".join(body) + "\n</table>"


def kv(rows: list[tuple[str, object]]) -> str:
    out = []
    for key, value in rows:
        out.append(f"<tr><th>{esc(key)}</th><td>{value}</td></tr>")
    return "<table>\n" + "\n".join(out) + "\n</table>"


def tiles(items: list[tuple[str, object]]) -> str:
    cells = "".join(
        f'<div class="tile"><b>{esc(value)}</b><span>{esc(label)}</span></div>'
        for label, value in items
    )
    return f'<div class="tiles">{cells}</div>'


def classify(line: str) -> str:
    probe = line.strip().upper()
    if probe.startswith(("PASS", "OK", "SUCCESS")) or "NO LEAKS FOUND" in probe:
        return "l-pass"
    if probe.startswith(("FAIL", "ERROR", "FATAL")) or "CRITICAL" in probe:
        return "l-fail"
    if probe.startswith(("WARN", "SKIP", "INFO", "BLOCKED")):
        return "l-warn"
    return ""


def pre(text: str) -> str:
    if not text:
        return '<p class="missing">This file is empty.</p>'
    lines = []
    for line in text.splitlines():
        cls = classify(line)
        lines.append(f'<span class="{cls}">{esc(line)}</span>' if cls else esc(line))
    return "<pre>" + "\n".join(lines) + "</pre>"


CHECK_RE = re.compile(
    r"^(PASS|OK|FAIL|ERROR|WARN|WARNING|INFO|SKIP|SKIPPED|BLOCKED)\b[ \t]*(.*)$")


def check_lines(text: str) -> list[tuple[str, str]]:
    rows = []
    for raw in text.splitlines():
        line = raw.strip()
        match = CHECK_RE.match(line)
        if not match:
            continue
        word = match.group(1).upper()
        rest = match.group(2).strip() or line
        status = {"OK": "PASS", "WARNING": "WARNING", "ERROR": "FAIL",
                  "SKIP": "SKIPPED", "SKIPPED": "SKIPPED",
                  "BLOCKED": "FAIL"}.get(word, word)
        rows.append((status, rest))
    return rows


def counts(rows: list[tuple[str, str]]) -> dict[str, int]:
    out: dict[str, int] = {}
    for status, _ in rows:
        out[status] = out.get(status, 0) + 1
    return out


def result_line(text: str) -> tuple[int, int] | None:
    match = re.search(r"Result:\s*(\d+)\s+passed,\s*(\d+)\s+failed", text)
    if not match:
        return None
    return int(match.group(1)), int(match.group(2))


def sev_class(severity: str) -> str:
    return f'<span class="sev-{esc(severity or "UNKNOWN").upper()}">{esc(severity or "UNKNOWN")}</span>'


# --------------------------------------------------------------------------
# reporting context
# --------------------------------------------------------------------------
class Context:
    def __init__(self, src: Path, dst: Path, params: dict[str, str],
                 versions: dict[str, str], surefire: Path | None) -> None:
        self.src = src
        self.dst = dst
        self.params = params
        self.versions = versions
        self.surefire = surefire

    def param(self, name: str | None) -> bool | None:
        if not name:
            return None
        value = self.params.get(name, "").strip().lower()
        if value in ("true", "false"):
            return value == "true"
        return None

    def meta(self) -> dict[str, str]:
        return {
            "build": self.params.get("BUILD_NUMBER", "unknown"),
            "url": self.params.get("BUILD_URL", ""),
            "job": self.params.get("JOB_NAME", "devsecops-pipeline"),
            "started": started_text(self.params),
            "result": self.params.get("RESULT", "unknown"),
            "rendered": datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M:%S UTC"),
        }


def load_params(path: Path) -> dict[str, str]:
    out: dict[str, str] = {}
    text = read(path)
    if not text:
        return out
    for line in text.splitlines():
        if "=" in line:
            key, value = line.split("=", 1)
            out[key.strip()] = value.strip()
    return out


def started_text(params: dict[str, str]) -> str:
    """Build start time: epoch milliseconds from Jenkins, formatted locally."""
    raw = (params.get("STARTED_MS") or "").strip()
    if raw.isdigit():
        try:
            stamp = datetime.fromtimestamp(int(raw) / 1000).astimezone()
            return stamp.strftime("%Y-%m-%d %H:%M:%S %Z").strip()
        except (OverflowError, OSError, ValueError):
            pass
    return params.get("STARTED", "") or "unknown"


def load_versions(src: Path) -> dict[str, str]:
    """Tool versions as printed by the preflight stage."""
    text = read(src / "preflight-report.txt") or ""
    versions: dict[str, str] = {}
    for status, rest in check_lines(text):
        if status != "PASS":
            continue
        match = re.match(r"(\S+(?: \([^)]*\))?)\s{2,}(.+)$", rest)
        if not match:
            continue
        label, version = match.group(1).strip(), match.group(2).strip()
        key = label.split(" (")[0].strip()
        if version:
            versions[key] = version
    return versions


# --------------------------------------------------------------------------
# per-kind report builders. Each returns a dict:
#   status, reason, tiles, tables [(heading, html)], notes [str], raw [paths]
# --------------------------------------------------------------------------
def build_checks(tool: dict, ctx: Context, text: str) -> dict:
    rows = check_lines(text)
    tally = counts(rows)
    failed = tally.get("FAIL", 0)
    warned = tally.get("WARNING", 0)
    summary = result_line(text)
    if failed:
        status = "FAIL"
        reason = f"{failed} check(s) failed."
    elif warned:
        status = "WARNING"
        reason = f"No failure, {warned} warning(s)."
    elif rows:
        status = "PASS"
        reason = f"All {tally.get('PASS', 0)} check(s) passed."
    else:
        status = "WARNING"
        reason = "The file was produced but contains no PASS/FAIL lines."
    stats = [("Checks", len(rows)), ("Passed", tally.get("PASS", 0)),
             ("Failed", failed), ("Warnings", warned)]
    if summary:
        stats.append(("Reported result", f"{summary[0]} passed, {summary[1]} failed"))
    detail = ""
    if rows:
        colour = {"PASS": '<span class="sev-LOW">PASS</span>',
                  "FAIL": '<span class="sev-CRITICAL">FAIL</span>',
                  "WARNING": '<span class="sev-MEDIUM">WARNING</span>',
                  "SKIPPED": '<span class="sev-UNKNOWN">SKIPPED</span>',
                  "INFO": '<span class="sev-INFO">INFO</span>'}
        detail = table(["Status", "Check"],
                       [[colour.get(s, esc(s)), esc(t)] for s, t in rows])
    return dict(status=status, reason=reason, tiles=stats,
                tables=[("Checks", detail)] if detail else [],
                notes=[tool["note"]], raw=[tool["files"][0]])


def build_maven(tool: dict, ctx: Context, text: str) -> dict:
    errors = [l.strip() for l in text.splitlines()
              if l.strip().startswith("[ERROR]")]
    success = "BUILD SUCCESS" in text
    compiled = re.search(r"Compiling (\d+) source files?", text)
    if errors:
        status, reason = "FAIL", f"{len(errors)} Maven error line(s)."
    elif success:
        status = "PASS"
        reason = "Compilation finished with BUILD SUCCESS."
    else:
        status = "WARNING"
        reason = "The log does not contain a BUILD SUCCESS line."
    stats = [("Sources compiled", compiled.group(1) if compiled else "-"),
             ("Build result", "SUCCESS" if success else "see log"),
             ("Error lines", len(errors))]
    tables = []
    if errors:
        tables.append(("Errors", table(["Message"], [[esc(e)] for e in errors[:60]])))
    return dict(status=status, reason=reason, tiles=stats, tables=tables,
                notes=[tool["note"]], raw=[tool["files"][0]])


def surefire_totals(directory: Path | None) -> dict:
    result = {"files": 0, "tests": 0, "failures": 0, "errors": 0, "skipped": 0,
              "time": 0.0, "cases": []}
    if not directory or not directory.is_dir():
        return result
    for xml_file in sorted(directory.glob("*.xml")):
        try:
            root = ElementTree.parse(xml_file).getroot()
        except (ElementTree.ParseError, OSError):
            continue
        suites = [root] if root.tag == "testsuite" else root.findall("testsuite")
        for suite in suites:
            result["files"] += 1
            for key in ("tests", "failures", "errors", "skipped"):
                try:
                    result[key] += int(suite.get(key) or 0)
                except ValueError:
                    pass
            try:
                result["time"] += float(suite.get("time") or 0)
            except ValueError:
                pass
            for case in suite.findall("testcase"):
                problem = None
                for child in case:
                    if child.tag in ("failure", "error"):
                        problem = (child.get("message") or child.get("type") or
                                   (child.text or "").strip().splitlines()[:1] or
                                   "failed")
                        if isinstance(problem, list):
                            problem = problem[0] if problem else "failed"
                        break
                result["cases"].append({
                    "name": case.get("name", "?"),
                    "class": case.get("classname", ""),
                    "time": case.get("time", ""),
                    "problem": problem,
                    "skipped": case.find("skipped") is not None,
                })
    return result


def build_surefire(tool: dict, ctx: Context, text: str) -> dict:
    totals = surefire_totals(ctx.surefire)
    bad = totals["failures"] + totals["errors"]
    if totals["tests"] == 0:
        status, reason = "WARNING", ("No JUnit XML was found under "
                                     "target/surefire-reports.")
    elif bad:
        status, reason = "FAIL", f"{bad} of {totals['tests']} test(s) failed."
    else:
        status = "PASS"
        reason = f"All {totals['tests']} test(s) passed."
    stats = [("Tests", totals["tests"]), ("Passed", totals["tests"] - bad - totals["skipped"]),
             ("Failed", totals["failures"]), ("Errors", totals["errors"]),
             ("Skipped", totals["skipped"]),
             ("Time", f"{totals['time']:.2f} s")]
    rows = []
    for case in totals["cases"]:
        state = ("SKIPPED" if case["skipped"]
                 else "FAIL" if case["problem"] else "PASS")
        detail = esc(case["problem"] or "")
        rows.append([f'<span class="sev-{"CRITICAL" if state == "FAIL" else "LOW"}">'
                     f"{state}</span>", esc(case["name"]), esc(case["class"]),
                     esc(case["time"]), detail])
    tables = []
    if rows:
        tables.append(("Test cases", table(
            ["Status", "Test", "Class", "Time", "Message"], rows)))
    return dict(status=status, reason=reason, tiles=stats, tables=tables,
                notes=[tool["note"]], raw=[tool["files"][0]])


def build_gitleaks(tool: dict, ctx: Context, text_json: str) -> dict:
    findings = []
    try:
        parsed = json.loads(text_json) if text_json else []
    except ValueError:
        parsed = None
    if isinstance(parsed, list):
        for item in parsed:
            if not isinstance(item, dict):
                continue
            findings.append({
                "rule": item.get("RuleID") or item.get("rule") or "?",
                "file": item.get("File") or item.get("file") or "?",
                "line": item.get("StartLine") or "",
                "commit": (item.get("Commit") or "")[:12],
                "author": item.get("Author") or "",
                "date": item.get("Date") or "",
                "desc": item.get("Description") or "",
            })
    summary = dict(
        (line.split(":", 1)[0].strip(), line.split(":", 1)[1].strip())
        for line in (read(ctx.src / "gitleaks-summary.txt") or "").splitlines()
        if ":" in line
    )
    if parsed is None:
        status, reason = "FAIL", "gitleaks-report.json is not valid JSON."
    elif findings:
        status = "FAIL"
        reason = f"{len(findings)} secret(s) detected."
    elif text_json is not None:
        status = "PASS"
        reason = "Zero secrets detected: the report contains an empty finding list."
    else:
        status, reason = "WARNING", "No Gitleaks report was produced."
    stats = [("Commits scanned", summary.get("commits", "-")),
             ("Tracked files", summary.get("tracked_files", "-")),
             ("Scanned size", summary.get("worktree_size", "-")),
             ("Secrets detected", len(findings) if parsed is not None else "?"),
             ("Rules hit", len({f['rule'] for f in findings}))]
    tables = []
    if findings:
        tables.append(("Findings (secret values redacted by gitleaks --redact)",
                       table(["Rule", "File", "Line", "Commit", "Author", "Description"],
                             [[esc(f["rule"]), esc(f["file"]), esc(f["line"]),
                               esc(f["commit"]), esc(f["author"]), esc(f["desc"])]
                              for f in findings])))
    elif parsed is not None:
        tables.append(("Findings", '<p class="note">ZERO SECRETS DETECTED &mdash; the '
                                  'scan completed and returned an empty finding list '
                                  '(<code>[]</code>). This is a PASS, not a missing '
                                  'report.</p>'))
    return dict(status=status, reason=reason, tiles=stats, tables=tables,
                notes=[tool["note"]], raw=tool["files"])


def parse_trivy_text(text: str) -> dict:
    totals = []
    rows = []
    header: list[str] | None = None
    target = ""
    for raw in text.splitlines():
        line = raw.strip()
        match = re.match(r"Total:\s*(\d+)\s*\((.*)\)", line)
        if match:
            totals.append((match.group(1), match.group(2)))
            continue
        if not line.startswith(("│", "|")):
            if line and "(" in line and not line.startswith(("┌", "└", "├", "Total")):
                target = line
            continue
        bar = "│" if "│" in line else "|"
        cells = [c.strip() for c in line.strip(bar).split(bar)]
        if not any(cells):
            continue
        if header is None:
            header = cells
            continue
        if all(set(c) <= set("─- ") for c in cells):
            continue
        row = dict(zip(header, cells))
        row["_target"] = target
        rows.append(row)
    return {"totals": totals, "rows": rows}


def build_trivy(tool: dict, ctx: Context,
                pairs: list[tuple[str, str]]) -> dict:
    """Aggregate one or more Trivy runs (repository + resolved SBOM)."""
    severities = {"CRITICAL": 0, "HIGH": 0, "MEDIUM": 0, "LOW": 0, "UNKNOWN": 0}
    vulns: list[dict] = []
    targets: list[str] = []
    table_scans: list[dict] = []
    has_json = False
    any_text = False
    for text, text_json in pairs:
        any_text = any_text or bool((text or "").strip())
        parsed = None
        if text_json:
            try:
                parsed = json.loads(text_json)
            except ValueError:
                parsed = None
        if isinstance(parsed, dict):
            has_json = True
            # The JSON of this run is authoritative for it: counting the same
            # findings again from its table output would double them.
            for result in parsed.get("Results") or []:
                found = result.get("Vulnerabilities") or []
                if not found:
                    continue
                kind = result.get("Class") or result.get("Type") or "unknown"
                targets.append(f"{result.get('Target', '?')} ({kind})")
                for vuln in found:
                    severity = (vuln.get("Severity") or "UNKNOWN").upper()
                    severities[severity] = severities.get(severity, 0) + 1
                    vulns.append({
                        "target": result.get("Target", "?"),
                        "kind": kind,
                        "id": vuln.get("VulnerabilityID", "?"),
                        "pkg": vuln.get("PkgName", "?"),
                        "severity": severity,
                        "installed": vuln.get("InstalledVersion", "-"),
                        "fixed": vuln.get("FixedVersion") or vuln.get("Status") or "-",
                        "title": vuln.get("Title") or vuln.get("Description") or "",
                    })
            continue
        # No JSON for this run: the counts come from the "Total: n (CRITICAL: x,
        # ...)" line Trivy prints per target, or from the table rows themselves.
        scan = parse_trivy_text(text or "")
        if scan["rows"] or scan["totals"]:
            table_scans.append(scan)
            if scan["totals"]:
                for _, summary in scan["totals"]:
                    for part in summary.split(","):
                        key, _, value = part.strip().partition(":")
                        key = key.strip().upper()
                        if key in severities and value.strip().isdigit():
                            severities[key] += int(value.strip())
            else:
                for row in scan["rows"]:
                    sev = (row.get("Severity") or "UNKNOWN").upper()
                    severities[sev] = severities.get(sev, 0) + 1

    critical = severities["CRITICAL"]
    high = severities["HIGH"]
    if not has_json and not table_scans and not any_text:
        status, reason = "WARNING", "No Trivy output was found for this stage."
    elif critical:
        status, reason = "FAIL", f"{critical} CRITICAL finding(s); the gate is CRITICAL."
    elif high:
        status = "WARNING"
        reason = f"{high} HIGH finding(s); the gate only fails on CRITICAL."
    elif severities["MEDIUM"] or severities["LOW"] or severities["UNKNOWN"]:
        status = "WARNING"
        reason = "No CRITICAL or HIGH finding; lower severities are listed."
    else:
        status = "PASS"
        reason = "No vulnerabilities found in the scanned scope."

    stats = [("Critical", severities["CRITICAL"]), ("High", severities["HIGH"]),
             ("Medium", severities["MEDIUM"]), ("Low", severities["LOW"]),
             ("Unknown", severities["UNKNOWN"])]
    tables = []
    if vulns:
        rows = [[esc(v["id"]), sev_class(v["severity"]), esc(v["pkg"]),
                 esc(v["installed"]), esc(v["fixed"]), esc(v["title"][:160]),
                 esc(v["target"])] for v in vulns[:400]]
        tables.append((f"Vulnerabilities ({len(vulns)})",
                       table(["ID", "Severity", "Package", "Installed", "Fixed",
                              "Title", "Target"], rows)))
        if len(vulns) > 400:
            tables.append(("Note", '<p class="note">The table is limited to 400 rows; '
                                   "the JSON copy under Raw evidence holds all "
                                   f"{len(vulns)} findings.</p>"))
    elif table_scans:
        rows = [[esc(target_name), esc(summary)]
                for scan in table_scans for target_name, summary in scan["totals"]]
        tables.append(("Scan totals as printed by Trivy",
                       table(["Target", "Severity totals"], rows)))
    else:
        tables.append(("Findings", '<p class="note">Trivy reported no matching '
                                   "vulnerabilities for this scan. The raw output is "
                                   "below and in the artifacts.</p>"))
    if targets:
        tables.insert(0, ("Scanned targets", table(["Target"], [[esc(t)] for t in targets])))
    return dict(status=status, reason=reason, tiles=stats, tables=tables,
                notes=[tool["note"]], raw=tool["files"])


def build_hadolint(tool: dict, ctx: Context, text: str) -> dict:
    pattern = re.compile(
        r"^(?P<file>[^:]+):(?P<line>\d+)(?::(?P<col>\d+))?\s+"
        r"(?P<rule>[A-Z]+\d+)\s+(?P<level>error|warning|info|style):\s*(?P<msg>.*)$")
    rows = []
    for raw in (text or "").splitlines():
        match = pattern.match(raw.strip())
        if not match:
            continue
        rows.append(match.groupdict())
    errors = [r for r in rows if r["level"] == "error"]
    warnings = [r for r in rows if r["level"] in ("warning", "style")]
    if not text or not text.strip():
        status = "PASS"
        reason = "Hadolint produced no output: no findings in the Dockerfile."
    elif errors:
        status, reason = "FAIL", f"{len(errors)} error(s) in the Dockerfile."
    elif warnings:
        status, reason = "WARNING", f"{len(warnings)} warning(s), no errors."
    else:
        status, reason = "WARNING", "Unparsed hadolint output."
    stats = [("Findings", len(rows)), ("Errors", len(errors)),
             ("Warnings", len(warnings))]
    tables = []
    if rows:
        tables.append(("Findings", table(
            ["File", "Line", "Rule", "Level", "Message"],
            [[esc(r["file"]), esc(r["line"]), esc(r["rule"]),
              f'<span class="sev-{"CRITICAL" if r["level"] == "error" else "MEDIUM"}">'
              f'{esc(r["level"])}</span>', esc(r["msg"])] for r in rows])))
    else:
        tables.append(("Findings", '<p class="note">No hadolint findings. An empty '
                                   "report is the expected clean result for this "
                                   "step.</p>"))
    return dict(status=status, reason=reason, tiles=stats, tables=tables,
                notes=[tool["note"]], raw=tool["files"])


def build_zap(tool: dict, ctx: Context, text_json: str) -> dict:
    try:
        parsed = json.loads(text_json) if text_json else None
    except ValueError:
        parsed = None
    counts_by_risk = {3: 0, 2: 0, 1: 0, 0: 0}
    alerts = []
    target = ""
    version = ""
    if isinstance(parsed, dict):
        version = parsed.get("@version") or ""
        for site in parsed.get("site") or []:
            if not target:
                target = site.get("@name") or ""
            for alert in site.get("alerts") or []:
                try:
                    risk = int(alert.get("riskcode") or 0)
                except (TypeError, ValueError):
                    risk = 0
                counts_by_risk[risk] = counts_by_risk.get(risk, 0) + 1
                alerts.append({
                    "risk": risk,
                    "name": alert.get("name") or alert.get("alert") or "?",
                    "confidence": alert.get("confidence") or "",
                    "count": alert.get("count") or len(alert.get("instances") or []) or 1,
                    "desc": (alert.get("desc") or "").strip(),
                    "solution": (alert.get("solution") or "").strip(),
                    "urls": [i.get("uri") for i in (alert.get("instances") or [])
                             if i.get("uri")][:5],
                })
    risk_name = {3: "High", 2: "Medium", 1: "Low", 0: "Informational"}
    if parsed is None:
        status, reason = "WARNING", "No ZAP JSON report was found."
    elif counts_by_risk[3]:
        status, reason = "FAIL", f"{counts_by_risk[3]} high-risk alert(s)."
    elif counts_by_risk[2]:
        status = "WARNING"
        reason = (f"No high-risk alert, {counts_by_risk[2]} medium-risk "
                  "alert(s) to review.")
    else:
        status = "PASS"
        reason = "No high or medium risk alerts in the baseline scan."
    stats = [("High", counts_by_risk[3]), ("Medium", counts_by_risk[2]),
             ("Low", counts_by_risk[1]), ("Informational", counts_by_risk[0]),
             ("Target", target or "-")]
    order = {3: 0, 2: 1, 1: 2, 0: 3}
    alerts.sort(key=lambda a: (order.get(a["risk"], 9), a["name"]))
    tables = []
    if alerts:
        rows = []
        for alert in alerts:
            detail = esc(alert["desc"][:600])
            if alert["solution"]:
                detail += f'<br><em>Fix:</em> {esc(alert["solution"][:400])}'
            rows.append([sev_class({3: "CRITICAL", 2: "HIGH", 1: "LOW", 0: "INFO"}
                                   .get(alert["risk"], "INFO")),
                         esc(alert["name"]), esc(risk_name.get(alert["risk"], "?")),
                         esc(alert["count"]), detail])
        tables.append(("Alerts", table(
            ["Severity", "Alert", "Risk", "Instances", "Description and remediation"],
            rows)))
    else:
        tables.append(("Alerts", '<p class="note">No alerts were raised by the '
                                 "baseline scan.</p>"))
    if tool["files"] and (ctx.src / "zap-report.html").is_file():
        tables.append(("Original ZAP report",
                       '<p><a href="zap-report.html">Open the HTML report ZAP wrote '
                       "itself &rarr;</a></p>"))
    return dict(status=status, reason=reason, tiles=stats, tables=tables,
                notes=[tool["note"]], raw=tool["files"], version=version or None)


def build_sbom(tool: dict, ctx: Context, text_json: str) -> dict:
    try:
        parsed = json.loads(text_json) if text_json else None
    except ValueError:
        parsed = None
    components = []
    if isinstance(parsed, dict):
        components = [c for c in (parsed.get("components") or []) if isinstance(c, dict)]
    deps_text = read(ctx.src / "dependencies.txt") or ""
    resolved = len([l for l in deps_text.splitlines() if re.search(r":(jar|pom|war):", l)])
    kinds: dict[str, int] = {}
    for component in components:
        kind = component.get("type") or "library"
        kinds[kind] = kinds.get(kind, 0) + 1
    if parsed is None:
        status, reason = "WARNING", "No CycloneDX SBOM was produced."
    elif components:
        status, reason = "PASS", f"{len(components)} component(s) listed in the SBOM."
    else:
        status = "FAIL"
        reason = ("The SBOM exists but lists no component: the dependency scan had "
                  "nothing to scan, which scripts/generate-sbom.py treats as an error.")
    stats = [("Components", len(components)),
             ("Resolved dependencies", resolved or "-"),
             ("Component types", ", ".join(f"{k}={v}" for k, v in sorted(kinds.items())) or "-"),
             ("Spec version", (parsed or {}).get("specVersion", "-") if isinstance(parsed, dict) else "-")]
    tables = []
    if components:
        rows = [[esc(c.get("name", "?")), esc(c.get("version", "-")),
                 esc(c.get("type", "-")), esc(c.get("purl", "-"))]
                for c in components[:400]]
        tables.append((f"Inventory ({len(components)})",
                       table(["Name", "Version", "Type", "PURL"], rows)))
    return dict(status=status, reason=reason, tiles=stats, tables=tables,
                notes=[tool["note"]], raw=tool["files"])


def build_sonar(tool: dict, ctx: Context, text: str) -> dict:
    gate = re.search(r"QUALITY GATE STATUS:\s*(\w+)", text or "")
    url = re.search(r"(https?://\S*sonar\S*)", text or "")
    analysed = "ANALYSIS SUCCESSFUL" in (text or "")
    if gate:
        status = "PASS" if gate.group(1).upper() in ("PASSED", "OK") else "FAIL"
        reason = f"Quality gate {gate.group(1)}."
    elif analysed:
        status, reason = "WARNING", "Analysis finished; the quality gate result is in SonarQube."
    else:
        status = "WARNING"
        reason = "No SonarQube result was produced by this run."
    stats = [("Quality gate", gate.group(1) if gate else "not in this log"),
             ("Analysis", "successful" if analysed else "not in this log")]
    tables = [("Limitation",
               '<p class="note">Bugs, vulnerabilities, code smells, coverage and '
               "duplication are computed by the SonarQube server, not by the "
               "scanner log. They are deliberately not copied or guessed here: "
               "open the project dashboard in SonarQube for those figures.</p>")]
    if url:
        tables.insert(0, ("Dashboard", f'<p><a href="{esc(url.group(1))}">'
                                       f"{esc(url.group(1))}</a></p>"))
    return dict(status=status, reason=reason, tiles=stats, tables=tables,
                notes=[tool["note"]], raw=tool["files"])


def build_plain(tool: dict, ctx: Context, text: str) -> dict:
    if text is None:
        status, reason = "WARNING", "This stage produced no saved output."
    elif not text.strip():
        status, reason = "WARNING", "The stage ran but wrote no output."
    else:
        status, reason = "PASS", "The stage wrote its evidence."
    stats = [("Lines", len((text or "").splitlines()))]
    return dict(status=status, reason=reason, tiles=stats, tables=[],
                notes=[tool["note"]], raw=tool["files"])


MONITORING_KEYS = {
    "grafana": ("grafana",),
    "alertmanager": ("alertmanager",),
    "node": ("node-exporter", "node exporter", "node", "9100", "loopback",
             "published outside the vm"),
    "prometheus": ("prometheus", "alert rule", "up=", "scrape", "jvm metrics",
                   "target", "alerts currently firing"),
}


def monitoring_slice(text: str, component: str | None) -> tuple[list[tuple[str, str]], str]:
    rows = check_lines(text or "")
    header_lines = [l for l in (text or "").splitlines()
                    if l.strip().startswith(("prometheus  :", "grafana     :",
                                             "alertmanager:", "application :"))]
    if component is None:
        return rows, "\n".join(header_lines)
    chosen = []
    for status, line in rows:
        low = line.lower()
        if any(key in low for key in MONITORING_KEYS[component]):
            chosen.append((status, line))
    return chosen, "\n".join(header_lines)


def build_monitoring(tool: dict, ctx: Context, text: str) -> dict:
    rows, endpoint_text = monitoring_slice(text, tool.get("component"))
    tally = counts(rows)
    failed = tally.get("FAIL", 0)
    if not (text or "").strip():
        status, reason = "WARNING", "The operations check produced no output."
    elif failed:
        status, reason = "FAIL", f"{failed} check(s) failed for this component."
    elif rows:
        status = "PASS"
        reason = f"All {tally.get('PASS', 0)} check(s) passed for this component."
    else:
        status = "WARNING"
        reason = "No check in the operations report mentions this component."
    stats = [("Checks", len(rows)), ("Passed", tally.get("PASS", 0)),
             ("Failed", failed), ("Info", tally.get("INFO", 0))]
    over = result_line(text or "")
    if over:
        stats.append(("Whole stage", f"{over[0]} passed, {over[1]} failed"))
    tables = []
    if rows:
        rows_html = [[f'<span class="sev-{"CRITICAL" if s == "FAIL" else "LOW"}">{esc(s)}</span>',
                      esc(t)] for s, t in rows]
        tables.append(("Checks for this component",
                       table(["Status", "Check"], rows_html)))
    if tool.get("component") is None and endpoint_text:
        tables.insert(0, ("Endpoints under test", pre(endpoint_text)))
        tables.append(("Checks not attributed to a single component",
                       "<p class=\"note\">Every PASS/FAIL line of the operations "
                       "stage is listed above.</p>"))
    notes = [tool["note"]]
    if tool.get("component"):
        notes.append("These checks are the subset of scripts/monitoring-check.sh "
                     "that names this component; the same evidence is on the "
                     "Operations check (all) page.")
    return dict(status=status, reason=reason, tiles=stats, tables=tables,
                notes=notes, raw=tool["files"])


def _local(tag: str) -> str:
    return tag.split("}")[-1]


def build_dependency_check(tool: dict, ctx: Context) -> dict:
    """Parse the XML report Dependency-Check writes (namespace agnostic)."""
    xml_text = read(ctx.src / "dependency-check-report.xml")
    version_lines = (read(ctx.src / "state/dependency-check-version.txt") or "").strip()
    dependencies: list[dict] = []
    severities = {"CRITICAL": 0, "HIGH": 0, "MEDIUM": 0, "LOW": 0, "UNKNOWN": 0}
    findings: list[dict] = []
    parsed = False
    if xml_text:
        try:
            root = ElementTree.fromstring(xml_text)
            parsed = True
        except ElementTree.ParseError:
            root = None
        if root is not None:
            for node in root.iter():
                if _local(node.tag) != "dependency":
                    continue
                file_name, vulns = "", []
                for child in node:
                    tag = _local(child.tag)
                    if tag == "fileName":
                        file_name = (child.text or "").strip()
                    elif tag == "vulnerabilities":
                        for vuln in child:
                            if _local(vuln.tag) != "vulnerability":
                                continue
                            entry = {"cve": "", "severity": "UNKNOWN", "score": "",
                                     "source": ""}
                            for part in vuln:
                                ptag = _local(part.tag)
                                if ptag == "name":
                                    entry["cve"] = (part.text or "").strip()
                                elif ptag == "severity":
                                    entry["severity"] = (part.text or "unknown").strip().upper()
                                elif ptag == "source":
                                    entry["source"] = (part.text or "").strip()
                                elif ptag == "cvssv3":
                                    for sub in part:
                                        if _local(sub.tag) == "baseScore":
                                            entry["score"] = (sub.text or "").strip()
                                elif ptag == "cvssv2" and not entry["score"]:
                                    for sub in part:
                                        if _local(sub.tag) == "score":
                                            entry["score"] = (sub.text or "").strip()
                            vulns.append(entry)
                dependencies.append({"file": file_name or "(unnamed)", "vulns": vulns})
                for entry in vulns:
                    sev = entry["severity"] if entry["severity"] in severities else "UNKNOWN"
                    severities[sev] += 1
                    findings.append({**entry, "file": file_name or "(unnamed)"})

    vulnerable = [d for d in dependencies if d["vulns"]]
    try:
        worst = max(float(f["score"]) for f in findings if f["score"])
    except ValueError:
        worst = 0.0

    if not xml_text:
        status, reason = "WARNING", "No Dependency-Check XML report was found."
    elif not parsed:
        status, reason = "FAIL", "dependency-check-report.xml could not be parsed."
    elif not dependencies:
        status = "WARNING"
        reason = ("The report lists no dependency, so nothing was really analysed.")
    elif worst >= 9 or severities["CRITICAL"]:
        status = "FAIL"
        reason = (f"CRITICAL finding (CVSS {worst:g}): the stage gate is "
                  "--failOnCVSS 9.")
    elif findings:
        status = "WARNING"
        reason = (f"{len(findings)} vulnerable dependenc(ies) below the CVSS 9 gate: "
                  "reported, not blocking.")
    else:
        status = "PASS"
        reason = "Zero vulnerable dependencies: the report lists none."

    stats = [("Dependencies analysed", len(dependencies)),
             ("Vulnerable dependencies", len(vulnerable)),
             ("Vulnerabilities", len(findings)),
             ("Highest CVSS", f"{worst:g}" if findings else "-"),
             ("Critical", severities["CRITICAL"]), ("High", severities["HIGH"]),
             ("Medium", severities["MEDIUM"]), ("Low", severities["LOW"])]
    tables = []
    if findings:
        rows = [[esc(f["file"]), esc(f["cve"]), sev_class(f["severity"]),
                 esc(f["score"] or "-"), esc(f["source"])]
                for f in sorted(findings, key=lambda x: -float(x["score"] or 0))[:300]]
        tables.append((f"Vulnerabilities ({len(findings)})",
                       table(["Dependency", "Vulnerability", "Severity", "CVSS",
                              "Source"], rows)))
    elif parsed and dependencies:
        tables.append(("Findings", '<p class="note">ZERO VULNERABILITIES &mdash; the '
                                   f'report lists {len(dependencies)} dependencies and '
                                   "no vulnerability for any of them.</p>"))
    if (ctx.src / "dependency-check-report.html").is_file():
        tables.append(("Original Dependency-Check report",
                       '<p><a href="dependency-check-report.html">Open the HTML report '
                       "Dependency-Check wrote itself &rarr;</a></p>"))
    result = dict(status=status, reason=reason, tiles=stats, tables=tables,
                  notes=[tool["note"]], raw=tool["files"])
    if version_lines:
        result["version"] = version_lines.splitlines()[0].strip()
    return result


def build_static(tool: dict, ctx: Context) -> dict:
    return dict(status="NOT RUN", reason="This stage is not part of the pipeline.",
                tiles=[("Status", "not run")], tables=[],
                notes=[tool["note"]], raw=[])


# --------------------------------------------------------------------------
# one tool page
# --------------------------------------------------------------------------
def render_tool(tool: dict, ctx: Context) -> dict:
    """Render one tool page. Returns the summary row used by the overview."""
    slug = tool["slug"]
    out_dir = ctx.dst / slug
    out_dir.mkdir(parents=True, exist_ok=True)

    evidence: list[Path] = []
    for name in tool["files"]:
        path = ctx.src / name
        if path.is_file():
            evidence.append(path)

    text = read(ctx.src / tool["text"]) if tool.get("text") else None
    json_text = read(ctx.src / tool["json"]) if tool.get("json") else None
    main_text = text
    if main_text is None and tool["files"]:
        main_text = read(ctx.src / tool["files"][0])

    kind = tool["kind"]
    if kind == "checks":
        result = build_checks(tool, ctx, main_text or "")
    elif kind == "maven":
        result = build_maven(tool, ctx, main_text or "")
    elif kind == "surefire":
        result = build_surefire(tool, ctx, main_text or "")
    elif kind == "gitleaks":
        result = build_gitleaks(tool, ctx, json_text)
    elif kind == "trivy":
        pairs = [(text or "", json_text or "")]
        pairs += [(read(ctx.src / name) or "", "")
                  for name in tool.get("also_text", [])]
        pairs += [("", read(ctx.src / name) or "")
                  for name in tool.get("also_json", [])]
        result = build_trivy(tool, ctx, pairs)
    elif kind == "hadolint":
        result = build_hadolint(tool, ctx, main_text or "")
    elif kind == "zap":
        result = build_zap(tool, ctx, json_text)
    elif kind == "sbom":
        result = build_sbom(tool, ctx, json_text)
    elif kind == "sonar":
        result = build_sonar(tool, ctx, main_text or "")
    elif kind == "monitoring":
        result = build_monitoring(tool, ctx, main_text or "")
    elif kind == "dependencycheck":
        result = build_dependency_check(tool, ctx)
    elif kind == "static":
        result = build_static(tool, ctx)
    else:
        result = build_plain(tool, ctx, main_text)

    # ---- status resolution: never claim a stage passed when it never ran ----
    status = result["status"]
    reason = result["reason"]
    param_value = ctx.param(tool["param"])
    if kind != "static":
        if param_value is False:
            status = "SKIPPED"
            reason = (f"Not executed: {tool['param']} is false for this build. "
                      "Nothing was scanned, so no result is claimed.")
        elif not evidence and status in ("PASS", "WARNING"):
            if ctx.meta()["result"].upper() in ("FAILURE", "ABORTED", "UNSTABLE"):
                status = "NOT RUN"
                reason = ("No evidence was written. The build stopped before this "
                          "stage, or the tool failed before it produced output - "
                          "see the console log of the stage.")
            else:
                status = "NOT RUN"
                reason = "No evidence was written by this stage in this build."

    meta = ctx.meta()
    version = result.get("version") or (ctx.versions.get(tool.get("bin") or "")
                                        if tool.get("bin") else "")
    if not version and tool.get("bin"):
        version = ctx.versions.get(tool["bin"], "")

    meta_rows = [
        ("Build", f"#{esc(meta['build'])}" +
                  (f' &middot; <a href="{esc(meta["url"])}">console</a>' if meta["url"] else "")),
        ("Build started", esc(meta["started"] or "unknown")),
        ("Build result", esc(meta["result"])),
        ("Stage", esc(tool["stage"])),
        ("Phase", esc(tool["phase"])),
        ("Status", f'<span class="badge b-{status.lower()}">{esc(status)}</span>'),
        ("Why", esc(reason)),
        ("Controlled by", (f"<code>{esc(tool['param'])}</code> = "
                           f"{'true' if param_value else 'false' if param_value is False else 'not recorded'}")
                          if tool["param"] else "always runs"),
        ("Tool version", esc(version) if version else "not reported by this build"),
    ]

    body = [kv(meta_rows), tiles(result["tiles"])]
    for heading, html_block in result["tables"]:
        body.append(f"<h2>{esc(heading)}</h2>\n{html_block}")
    if result["notes"]:
        note_html = "".join(f'<p class="note">{esc(n)}</p>' for n in result["notes"])
        body.append(f"<h2>About this report</h2>\n{note_html}")

    # ---- evidence: copy raw files next to the page so they download from Jenkins
    raw_rows = []
    for path in evidence:
        size = path.stat().st_size
        try:
            if path.resolve().parent != out_dir.resolve():
                shutil.copyfile(path, out_dir / path.name)
            link = f'<a href="{esc(path.name)}">{esc(path.name)}</a>'
        except OSError as exc:
            link = f"{esc(path.name)} <span class=\"missing\">({esc(exc)})</span>"
        raw_rows.append([link, size])
    if raw_rows:
        body.append("<h2>Raw evidence</h2>\n" +
                    table(["File (downloadable)", "Bytes"], raw_rows, numeric=(1,)))
    else:
        body.append("<h2>Raw evidence</h2>\n<p class=\"missing\">No raw file: this "
                    "stage produced none.</p>")

    # The gitleaks JSON is downloadable evidence but is never dumped into the
    # page: even with --redact the file is the one place a finding detail lives,
    # and a report must not paste secret material into the build page.
    if tool.get("log"):
        log = read(ctx.src / tool["log"])
    else:
        log = main_text or json_text
    if log and log.strip():
        body.append("<h2>Full output</h2>\n<details><summary>Show the raw output"
                    "</summary>\n" + pre(log) + "\n</details>")

    subtitle = (f"{tool['phase']} &middot; stage \"{tool['stage']}\" &middot; "
                f"build #{esc(meta['build'])} &middot; "
                f'<a href="../index.html">all reports</a>')
    (out_dir / "index.html").write_text(
        page(tool["title"], "<h2>Overview</h2>\n" + "\n".join(body), subtitle, status),
        encoding="utf-8")

    return {"tool": tool, "status": status, "reason": reason,
            "href": f"{slug}/index.html", "evidence": len(evidence)}


# --------------------------------------------------------------------------
# overview
# --------------------------------------------------------------------------
def render_overview(summaries: list[dict], ctx: Context) -> None:
    meta = ctx.meta()
    tally: dict[str, int] = {}
    for item in summaries:
        tally[item["status"]] = tally.get(item["status"], 0) + 1
    order = ["PASS", "WARNING", "FAIL", "SKIPPED", "NOT RUN"]
    tiles_html = "".join(
        f'<div class="tile"><b>{tally[status]}</b><span>{status}</span></div>'
        for status in order if tally.get(status)
    )
    body = [
        kv([("Build", f"#{esc(meta['build'])}" + (
            f' &middot; <a href="{esc(meta["url"])}">console</a>' if meta["url"] else "")),
            ("Build started", esc(meta["started"] or "unknown")),
            ("Build result", esc(meta["result"])),
            ("Rendered", esc(meta["rendered"]))]),
        f'<div class="tiles">{tiles_html}</div>',
    ]
    for phase in PHASES:
        group = [s for s in summaries if s["tool"]["phase"] == phase]
        if not group:
            continue
        rows = []
        for item in group:
            rows.append([
                f'<a href="{esc(item["href"])}">{esc(item["tool"]["title"])}</a>',
                esc(item["tool"]["stage"]),
                f'<span class="badge b-{item["status"].lower().replace(" ", "-")}">'
                f'{esc(item["status"])}</span>',
                esc(item["reason"]),
            ])
        body.append(f"<h2>{esc(phase)}</h2>\n" +
                    table(["Report", "Stage", "Status", "Result"], rows))
    body.append('<h2>How to read this</h2>\n'
                '<p class="note">Each tool has its own page, published as its own '
                "entry in this build's menu. A SKIPPED or NOT RUN status means the "
                "tool did not execute in this build; it is never reported as a "
                "pass, and no finding on any page is invented. Raw tool output is "
                "copied next to every report and archived under "
                "<code>reports/</code>.</p>")
    (ctx.dst / "index.html").write_text(
        page("All Reports", "\n".join(body),
             f"Build #{esc(meta['build'])} &middot; one page per tool, generated from "
             "the files this build actually wrote", None),
        encoding="utf-8")


# --------------------------------------------------------------------------
def jenkins_url_name(report_name: str) -> str:
    """The folder/link name HTML Publisher derives from a report name.

    Mirrors sanitizeReportName() in htmlpublisher: every character outside
    [a-zA-Z0-9-] becomes an underscore plus its UTF-8 hex, so a space
    becomes "_20".
    """
    return "".join(ch if (ch.isalnum() and ch.isascii()) or ch == "-"
                   else "_" + ch.encode("utf-8").hex()
                   for ch in report_name)


def run(argv: list[str]) -> int:
    if "--list" in argv:
        for tool in TOOLS:
            print(f"{jenkins_url_name(tool['title'])}\t{tool['title']}")
        print(f"{jenkins_url_name('All Reports')}\tAll Reports")
        return 0
    positional = [a for a in argv[1:] if not a.startswith("--")]
    quiet = "--quiet" in argv
    params_path = Path("reports/state/params.txt")
    surefire = Path("target/surefire-reports")
    for index, arg in enumerate(argv):
        if arg == "--params" and index + 1 < len(argv):
            params_path = Path(argv[index + 1])
        if arg == "--surefire" and index + 1 < len(argv):
            surefire = Path(argv[index + 1])

    src = Path(positional[0] if positional else "reports")
    dst = Path(positional[1] if len(positional) > 1 else str(src / "html"))
    if not src.is_dir():
        print(f"render-reports: no report directory at {src} - nothing to publish")
        return 0

    dst.mkdir(parents=True, exist_ok=True)
    ctx = Context(src=src, dst=dst, params=load_params(params_path),
                  versions=load_versions(src), surefire=surefire)

    summaries = [render_tool(tool, ctx) for tool in TOOLS]
    render_overview(summaries, ctx)

    if not quiet:
        tally: dict[str, int] = {}
        for item in summaries:
            tally[item["status"]] = tally.get(item["status"], 0) + 1
        detail = ", ".join(f"{k}={v}" for k, v in sorted(tally.items()))
        print(f"render-reports: {len(summaries)} tool page(s) written to {dst} "
              f"({detail})")
    return 0


def main(argv: list[str]) -> int:
    try:
        return run(argv)
    except Exception:  # noqa: BLE001 - report rendering must never fail the build
        print("render-reports: unexpected error while rendering reports")
        traceback.print_exc()
        return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
