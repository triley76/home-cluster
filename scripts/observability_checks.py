#!/usr/bin/env python3
"""Helpers for scripts/validate-observability.sh.

Each subcommand exits non-zero with a GitHub Actions ::error:: message when a
required structure cannot be found or is invalid. Requires PyYAML.
"""
import json
import pathlib
import re
import sys

import yaml

CHART = "kube-prometheus-stack"


def error(msg):
    print(f"::error::{msg}")
    sys.exit(1)


class _Loader(yaml.SafeLoader):
    """SafeLoader that reads the YAML 1.1 value indicator `=` as a plain string.

    Rendered Prometheus Operator CRDs contain `=` as a scalar; Kubernetes treats it
    as the string "=", but PyYAML resolves it to tag:yaml.org,2002:value, which
    SafeLoader cannot construct.
    """


_Loader.add_constructor("tag:yaml.org,2002:value", lambda loader, node: loader.construct_scalar(node))


def docs_in(paths):
    """Yield (path, document) for every YAML document in the given files."""
    for p in paths:
        try:
            with open(p, encoding="utf-8") as f:
                for doc in yaml.load_all(f, Loader=_Loader):  # noqa: S506 - SafeLoader subclass
                    if isinstance(doc, dict):
                        yield p, doc
        except yaml.YAMLError as e:
            error(f"{p}: YAML parse error: {e}")


def yaml_files(root):
    return sorted(str(p) for p in pathlib.Path(root).rglob("*") if p.suffix in (".yaml", ".yml") and p.is_file())


def cmd_helmrelease(controllers_dir, values_out):
    """Extract the kube-prometheus-stack HelmRelease: write its values and print release metadata."""
    files = yaml_files(controllers_dir)
    found = [(p, d) for p, d in docs_in(files)
             if d.get("kind") == "HelmRelease"
             and str(d.get("apiVersion", "")).startswith("helm.toolkit.fluxcd.io/")
             and ((d.get("spec") or {}).get("chart") or {}).get("spec", {}).get("chart") == CHART]
    if len(found) != 1:
        error(f"expected exactly one HelmRelease for chart {CHART} under {controllers_dir}, found {len(found)}")
    path, hr = found[0]
    spec = hr.get("spec") or {}
    if spec.get("valuesFrom"):
        error(f"{path}: spec.valuesFrom is not supported by this validator; values must be inline in spec.values")
    if (spec["chart"]["spec"] or {}).get("valuesFiles"):
        error(f"{path}: spec.chart.spec.valuesFiles is not supported by this validator; values must be inline in spec.values")
    if spec.get("postRenderers"):
        error(f"{path}: spec.postRenderers is not supported by this validator; the render would not match Flux")
    if "values" not in spec:
        error(f"{path}: spec.values is missing; the HelmRelease values cannot be extracted")
    values = spec["values"]
    if not isinstance(values, dict):
        error(f"{path}: spec.values must be a mapping, got {type(values).__name__}")
    version = str(spec["chart"]["spec"].get("version", ""))
    if not version:
        error(f"{path}: spec.chart.spec.version must pin an exact chart version")
    meta = hr.get("metadata") or {}
    namespace = spec.get("targetNamespace") or meta.get("namespace") or "default"
    release = spec.get("releaseName") or (
        f"{spec['targetNamespace']}-{meta['name']}" if spec.get("targetNamespace") else meta["name"])
    with open(values_out, "w", encoding="utf-8") as f:
        yaml.safe_dump(values, f, sort_keys=False)
    print(f"file={path}")
    print(f"release={release}")
    print(f"namespace={namespace}")
    print(f"version={version}")


def cmd_rules(out_dir, count_file, *paths):
    """Write the spec of every PrometheusRule found in the given YAML files as a promtool rule file.

    The object count is written to count_file, so diagnostics on stdout are never
    captured by a shell command substitution.
    """
    out = pathlib.Path(out_dir)
    out.mkdir(parents=True, exist_ok=True)
    n = 0
    for p, d in docs_in(paths):
        if d.get("kind") != "PrometheusRule":
            continue
        groups = (d.get("spec") or {}).get("groups")
        name = (d.get("metadata") or {}).get("name", "unnamed")
        if not isinstance(groups, list) or not groups:
            error(f"{p}: PrometheusRule {name} has missing or empty spec.groups")
        n += 1
        with open(out / f"{n:03d}-{name}.rules.yaml", "w", encoding="utf-8") as f:
            yaml.safe_dump({"groups": groups}, f, sort_keys=False)
    with open(count_file, "w", encoding="utf-8") as f:
        f.write(f"{n}\n")


def cmd_dashboards(*paths):
    bad = 0
    for p in paths:
        try:
            with open(p, encoding="utf-8") as f:
                data = json.load(f)
            if not isinstance(data, dict):
                print(f"::error file={p}::dashboard JSON must be an object")
                bad += 1
            else:
                print(f"ok: {p}")
        except (json.JSONDecodeError, UnicodeDecodeError) as e:
            print(f"::error file={p}::invalid dashboard JSON: {e}")
            bad += 1
    sys.exit(1 if bad else 0)


def cmd_no_secrets(*paths):
    bad = [(p, (d.get("metadata") or {}).get("name")) for p, d in docs_in(paths) if d.get("kind") == "Secret"]
    for p, name in bad:
        print(f"::error file={p}::Secret {name} must not be committed; credential Secrets are created out of band")
    sys.exit(1 if bad else 0)


def _images(obj):
    if isinstance(obj, dict):
        for k, v in obj.items():
            if k in ("containers", "initContainers", "ephemeralContainers") and isinstance(v, list):
                for c in v:
                    if isinstance(c, dict) and "image" in c:
                        yield c["image"]
            yield from _images(v)
    elif isinstance(obj, list):
        for v in obj:
            yield from _images(v)


def cmd_images(rendered):
    """Every container image in the rendered output needs an explicit, non-latest tag or a digest."""
    bad, seen = [], set()
    for _, d in docs_in([rendered]):
        imgs = list(_images(d))
        if d.get("kind") in ("Prometheus", "Alertmanager") and (d.get("spec") or {}).get("image"):
            imgs.append(d["spec"]["image"])
        for img in imgs:
            seen.add(img)
            last = str(img).rsplit("/", 1)[-1]
            if "@sha256:" in str(img):
                continue
            if ":" not in last or last.rsplit(":", 1)[1] in ("", "latest"):
                bad.append(f"{d.get('kind')}/{(d.get('metadata') or {}).get('name')}: {img}")
    for img in sorted(seen):
        print(f"image: {img}")
    for b in bad:
        print(f"::error::image without an explicit tag or digest, or tagged latest: {b}")
    sys.exit(1 if bad or not seen else 0)


MISSING = object()


def _get(values, dotted):
    cur = values
    for part in dotted.split("."):
        if not isinstance(cur, dict) or part not in cur:
            return MISSING
        cur = cur[part]
    return cur


def _design_versions_section(design_doc):
    text = open(design_doc, encoding="utf-8").read()
    start = text.find("\n## Versions (candidate)")
    if start < 0:
        error(f"{design_doc}: section '## Versions (candidate)' not found")
    end = text.find("\n## ", start + 1)
    return text[start:end if end > 0 else len(text)].splitlines()


def _load_pins(values_file, pins_file):
    with open(values_file, encoding="utf-8") as f:
        values = yaml.safe_load(f) or {}
    with open(pins_file, encoding="utf-8") as f:
        pins = yaml.safe_load(f)["pins"]
    return values, pins


def _active(values, pin):
    for cond in pin.get("when", []):
        value = _get(values, cond["path"])
        if (cond["default"] if value is MISSING else value) is False:
            return False
    return True


def cmd_image_pins(values_file, pins_file, design_doc):
    """Every enabled image must be pinned explicitly in spec.values, with its full
    reference approved in the design Versions table."""
    values, pins = _load_pins(values_file, pins_file)
    versions = _design_versions_section(design_doc)
    bad = []
    for pin in pins:
        if not _active(values, pin):
            print(f"not enabled, pin not required: {pin['path']}")
            continue
        img = _get(values, pin["path"])
        if not isinstance(img, dict):
            bad.append(f"{pin['path']}: image is not pinned explicitly in spec.values")
            continue
        tag = img.get("tag")
        if tag is None or str(tag).strip() == "":
            bad.append(f"{pin['path']}.tag: missing or empty")
        elif str(tag) == "latest":
            bad.append(f"{pin['path']}.tag: latest is not allowed")
        for key in ("registry", "repository", "tag"):
            if str(img.get(key, "")) != str(pin[key]):
                bad.append(f"{pin['path']}.{key}: expected {pin[key]!r}, found {img.get(key, '<missing>')!r}")
        rows = [line for line in versions if pin["design_row"] in line]
        if not any(f"`{pin['ref']}`" in line for line in rows):
            bad.append(f"{pin['path']}: {pin['ref']} is not approved in the design Versions table row "
                       f"'{pin['design_row']}'")
        if not any(b.startswith(pin["path"]) for b in bad):
            print(f"pinned: {pin['path']} -> {pin['ref']} (approved in design row {pin['design_row']!r})")
    for b in bad:
        print(f"::error::image pin: {b}")
    sys.exit(1 if bad else 0)


def cmd_image_refs(rendered, values_file, pins_file):
    """The rendered chart must contain the approved full reference of every enabled pin."""
    values, pins = _load_pins(values_file, pins_file)
    with open(rendered, encoding="utf-8") as f:
        text = f.read()
    bad = []
    for pin in pins:
        if not _active(values, pin):
            continue
        if re.search(rf"(?<![\w./-]){re.escape(pin['ref'])}(?![\w.-])", text):
            print(f"rendered: {pin['ref']}")
        else:
            bad.append(f"{pin['path']}: rendered chart does not contain the approved reference {pin['ref']}")
    for b in bad:
        print(f"::error::image reference: {b}")
    sys.exit(1 if bad else 0)


# Chart-owned rule lint findings that are known and accepted for the pinned chart.
# Each entry is the exact promtool output block for one rule file. Any other chart
# lint finding fails. Re-review whenever the chart version changes.
KNOWN_CHART_LINT = {
    # kube-prometheus-stack 91.8.2, promtool 3.15.0 --lint=duplicate-rules
    "kube-apiserver-availability.rules.rules.yaml": [
        "FAILED:",
        "lint error 1 duplicate rule(s) found.",
        "Metric: code_verb:apiserver_request_total:increase1h",
        "Label(s):",
        "Might cause inconsistency while recording expressions",
    ],
}


def cmd_chart_lint(promtool_output):
    """Accept only the exact known chart lint findings; fail on anything else."""
    with open(promtool_output, encoding="utf-8") as f:
        lines = [line.rstrip() for line in f]
    blocks, current = [], None
    for line in lines:
        if line.startswith("Checking "):
            current = [line[len("Checking "):].strip(), []]
            blocks.append(current)
        elif current is not None and line.strip():
            current[1].append(line.strip())
    bad = 0
    for path, body in blocks:
        if body and body[0].startswith("SUCCESS:"):
            continue
        known = next((exp for suffix, exp in KNOWN_CHART_LINT.items() if path.endswith(suffix)), None)
        if known is not None and body == known:
            print(f"::warning::known chart lint finding accepted ({pathlib.Path(path).name}): "
                  + " | ".join(body[1:3]))
            continue
        print(f"::error::unexpected chart rule lint finding in {pathlib.Path(path).name}: " + " | ".join(body))
        bad += 1
    sys.exit(1 if bad else 0)


COMMANDS = {
    "helmrelease": cmd_helmrelease,
    "image-pins": cmd_image_pins,
    "image-refs": cmd_image_refs,
    "chart-lint": cmd_chart_lint,
    "rules": cmd_rules,
    "dashboards": cmd_dashboards,
    "no-secrets": cmd_no_secrets,
    "images": cmd_images,
}

if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        error(f"usage: {sys.argv[0]} {{{'|'.join(COMMANDS)}}} ...")
    COMMANDS[sys.argv[1]](*sys.argv[2:])
