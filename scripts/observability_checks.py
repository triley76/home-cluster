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


# Targeted static Pod Security checks. These cover the Pod Security Standards controls that
# are relevant to this repository's Linux monitoring workloads; they do NOT implement every
# Kubernetes v1.36 Pod Security Admission control, and passing them does not prove Pod
# Security Standards compliance. Live admission and the k3d rehearsal remain authoritative.
#
# Checked (baseline): host namespaces, privileged, Windows hostProcess, added capabilities,
#   hostPath volumes, host ports, host probes/lifecycle hooks (v1.34+), procMount, seccomp
#   Unconfined, sysctls.
# Checked (restricted, in addition): volume types, allowPrivilegeEscalation, runAsNonRoot,
#   runAsUser 0, seccomp RuntimeDefault/Localhost, capabilities drop ALL / add only
#   NET_BIND_SERVICE.
# Not checked: AppArmor and SELinux options; Windows-specific relaxations (spec.os.name);
#   user-namespace relaxations (hostUsers: false), which can only make admission more
#   permissive than this check; containers that the Prometheus Operator generates for
#   Prometheus and Alertmanager (only their pod-level fields are visible statically).
PSA_LABEL = "pod-security.kubernetes.io/enforce"
# Capabilities that the "baseline" level allows to be added.
BASELINE_CAPS = {"AUDIT_WRITE", "CHOWN", "DAC_OVERRIDE", "FOWNER", "FSETID", "KILL", "MKNOD", "NET_BIND_SERVICE",
                 "SETFCAP", "SETGID", "SETPCAP", "SETUID", "SYS_CHROOT"}
SAFE_SYSCTLS = {"kernel.shm_rmid_forced", "net.ipv4.ip_local_port_range", "net.ipv4.ip_unprivileged_port_start",
                "net.ipv4.tcp_syncookies", "net.ipv4.ping_group_range", "net.ipv4.ip_local_reserved_ports",
                "net.ipv4.tcp_keepalive_time", "net.ipv4.tcp_fin_timeout", "net.ipv4.tcp_keepalive_intvl",
                "net.ipv4.tcp_keepalive_probes"}
RESTRICTED_VOLUMES = {"configMap", "csi", "downwardAPI", "emptyDir", "ephemeral", "persistentVolumeClaim",
                      "projected", "secret"}
POD_TEMPLATE_KINDS = {"Deployment", "StatefulSet", "DaemonSet", "ReplicaSet", "ReplicationController", "Job"}


def _pod_spec(d):
    kind, spec = d.get("kind"), d.get("spec") or {}
    if kind == "Pod":
        return spec
    if kind in POD_TEMPLATE_KINDS:
        return (spec.get("template") or {}).get("spec") or {}
    if kind == "CronJob":
        return (((spec.get("jobTemplate") or {}).get("spec") or {}).get("template") or {}).get("spec") or {}
    return None


def _namespace_levels(docs):
    """Pod Security enforce level of every Namespace declared in the validated files."""
    return {(d.get("metadata") or {}).get("name"): ((d.get("metadata") or {}).get("labels") or {}).get(PSA_LABEL)
            for _, d in docs if d.get("kind") == "Namespace"}


def _host_handlers(c):
    """Probe and lifecycle handlers of a container that set the `host` field."""
    out = []
    handlers = [(p, c.get(p)) for p in ("livenessProbe", "readinessProbe", "startupProbe")]
    handlers += [(f"lifecycle.{h}", (c.get("lifecycle") or {}).get(h)) for h in ("postStart", "preStop")]
    for where, h in handlers:
        for action in ("httpGet", "tcpSocket"):
            if ((h or {}).get(action) or {}).get("host"):
                out.append(f"{where}.{action}.host")
    return out


def _pss_violations(spec, level, pod_level_only=False):
    """Targeted static checks for the Pod Security `level` ("baseline" or "restricted").

    Covers only the controls listed at the top of this section; see there for what is
    not checked. pod_level_only checks only pod-level fields (used for Prometheus and
    Alertmanager custom resources, whose containers are generated by the operator)."""
    out = []
    psc = spec.get("securityContext") or {}
    restricted = level == "restricted"
    for f in ("hostNetwork", "hostPID", "hostIPC"):
        if spec.get(f):
            out.append(f"{f} must not be true")
    for v in spec.get("volumes") or []:
        vtype = next((k for k in v if k != "name"), None)
        if vtype == "hostPath":
            out.append(f"volume {v.get('name')}: hostPath is not allowed")
        elif restricted and vtype not in RESTRICTED_VOLUMES:
            out.append(f"volume {v.get('name')}: type {vtype} is not allowed")
    for s in psc.get("sysctls") or []:
        if s.get("name") not in SAFE_SYSCTLS:
            out.append(f"sysctl {s.get('name')} is not allowed")
    if (psc.get("seccompProfile") or {}).get("type") == "Unconfined":
        out.append("pod seccompProfile Unconfined is not allowed")
    if restricted and psc.get("runAsUser") == 0:
        out.append("pod runAsUser must not be 0")
    if pod_level_only:
        if restricted and psc.get("runAsNonRoot") is not True:
            out.append("pod runAsNonRoot must be true")
        if restricted and (psc.get("seccompProfile") or {}).get("type") not in ("RuntimeDefault", "Localhost"):
            out.append("pod seccompProfile must be RuntimeDefault or Localhost")
        return out
    containers = [("initContainer", c) for c in spec.get("initContainers") or []] + \
                 [("container", c) for c in spec.get("containers") or []] + \
                 [("ephemeralContainer", c) for c in spec.get("ephemeralContainers") or []]
    for ctype, c in containers:
        sc = c.get("securityContext") or {}
        where = f"{ctype} {c.get('name')}"
        caps = sc.get("capabilities") or {}
        added = set(caps.get("add") or [])
        if sc.get("privileged"):
            out.append(f"{where}: privileged must not be true")
        if (sc.get("windowsOptions") or {}).get("hostProcess"):
            out.append(f"{where}: windowsOptions.hostProcess must not be true")
        if sc.get("procMount") not in (None, "Default"):
            out.append(f"{where}: procMount must be Default")
        if any(p.get("hostPort") for p in c.get("ports") or []):
            out.append(f"{where}: hostPort is not allowed")
        for field in _host_handlers(c):
            out.append(f"{where}: {field} must not be set")
        if (sc.get("seccompProfile") or {}).get("type") == "Unconfined":
            out.append(f"{where}: seccompProfile Unconfined is not allowed")
        if added - BASELINE_CAPS:
            out.append(f"{where}: capabilities.add {sorted(added - BASELINE_CAPS)} not allowed")
        if not restricted:
            continue
        if sc.get("allowPrivilegeEscalation") is not False:
            out.append(f"{where}: allowPrivilegeEscalation must be false")
        if "ALL" not in (caps.get("drop") or []):
            out.append(f"{where}: capabilities.drop must include ALL")
        if added - {"NET_BIND_SERVICE"}:
            out.append(f"{where}: capabilities.add {sorted(added - {'NET_BIND_SERVICE'})} not allowed")
        if sc.get("runAsNonRoot", psc.get("runAsNonRoot")) is not True:
            out.append(f"{where}: runAsNonRoot must be true")
        if sc.get("runAsUser", psc.get("runAsUser")) == 0:
            out.append(f"{where}: runAsUser must not be 0")
        seccomp = (sc.get("seccompProfile") or psc.get("seccompProfile") or {}).get("type")
        if seccomp not in ("RuntimeDefault", "Localhost"):
            out.append(f"{where}: seccompProfile must be RuntimeDefault or Localhost")
    return out


def cmd_pod_security(release_ns, rendered, *repo_files):
    """Targeted static Pod Security checks for every rendered or committed workload, at the
    level enforced on its namespace. Namespaces are read from the committed Namespace
    manifests; a namespace that is not declared there, or declares no enforce label, is
    checked as "restricted" (fail closed). Not a complete Pod Security Standards
    evaluation: live admission and the k3d rehearsal remain authoritative."""
    print("targeted static checks of the Pod Security controls relevant to these monitoring workloads; "
          "not a complete Pod Security Standards evaluation (live admission and the k3d rehearsal are authoritative)")
    docs = list(docs_in([rendered, *repo_files]))
    levels = _namespace_levels(docs)
    print("namespace enforce levels: " + ", ".join(f"{n}={lvl or 'unset'}" for n, lvl in sorted(levels.items())))
    bad = 0
    for _, d in docs:
        kind = d.get("kind")
        meta = d.get("metadata") or {}
        cr = kind in ("Prometheus", "Alertmanager")
        spec = (d.get("spec") or {}) if cr else _pod_spec(d)
        if spec is None:
            continue
        ns = meta.get("namespace") or release_ns
        declared = levels.get(ns)
        level = declared if declared in ("privileged", "baseline", "restricted") else "restricted"
        ident = f"{kind} {ns}/{meta.get('name')}"
        if level == "privileged":
            print(f"pod security (targeted): {ident}: namespace enforces privileged; not checked")
            continue
        found = _pss_violations(spec, level, pod_level_only=cr)
        note = "" if declared else " (namespace level not declared; checked as restricted)"
        scope = " (pod-level fields only; containers are operator-generated)" if cr else ""
        if found:
            bad += 1
            for v in found:
                print(f"::error::Pod Security targeted check ({level}): {ident}: {v}{note}")
        else:
            print(f"pod security (targeted): {ident}: {level} checks passed{scope}{note}")
    sys.exit(1 if bad else 0)


GRAFANA_ALLOWED_RESOURCES = {"configmaps"}
GRAFANA_ALLOWED_VERBS = {"get", "list", "watch"}


RBAC_KINDS = ("Role", "RoleBinding", "ClusterRole", "ClusterRoleBinding")


def cmd_grafana_rbac(release_ns, rendered, applied, *repo_files):
    """Grafana may read only ConfigMaps in the release namespace: no ClusterRole or
    ClusterRoleBinding, no Secret access, and dashboard/datasource sidecars confined to
    the release namespace and to ConfigMaps.

    RBAC is taken only from what Flux applies: the rendered chart and `applied`, the
    `kustomize build` output of the monitoring/controllers Kustomization. A Grafana RBAC
    object that exists in a file under the monitoring directory but is not part of that
    render (for example, omitted from controllers/kustomization.yaml) is rejected."""
    docs = [d for _, d in docs_in([rendered, applied])]
    bad = []

    def name_of(d):
        return (d.get("metadata") or {}).get("name")

    def ns_of(d):
        return (d.get("metadata") or {}).get("namespace") or release_ns

    def is_grafana(d):
        return ((d.get("metadata") or {}).get("labels") or {}).get("app.kubernetes.io/name") == "grafana"

    deployments = [d for d in docs if d.get("kind") == "Deployment" and is_grafana(d)]
    sas = {(ns_of(d), (_pod_spec(d) or {}).get("serviceAccountName") or "default") for d in deployments}
    if not deployments:
        print("Grafana is not rendered; checking only that no Grafana cluster-wide RBAC exists")
    for ns, sa in sorted(sas):
        print(f"Grafana ServiceAccount: {ns}/{sa}")

    def binds_grafana(b):
        return any(s.get("kind") == "ServiceAccount" and (s.get("namespace") or ns_of(b), s.get("name")) in sas
                   for s in b.get("subjects") or [])

    for d in docs:
        kind = d.get("kind")
        if kind in ("ClusterRole", "ClusterRoleBinding") and is_grafana(d):
            bad.append(f"{kind} {name_of(d)}: Grafana must not have cluster-wide RBAC (set grafana.rbac.create: false)")
        elif kind == "ClusterRoleBinding" and binds_grafana(d):
            bad.append(f"ClusterRoleBinding {name_of(d)}: binds the Grafana ServiceAccount cluster-wide")

    roles = {(ns_of(d), name_of(d)): d for d in docs if d.get("kind") == "Role"}
    configmap_access = set()
    for b in (d for d in docs if d.get("kind") == "RoleBinding" and (binds_grafana(d) or is_grafana(d))):
        ref = b.get("roleRef") or {}
        where = f"RoleBinding {ns_of(b)}/{name_of(b)}"
        if ns_of(b) != release_ns:
            bad.append(f"{where}: Grafana may be granted access only in namespace {release_ns}")
        if ref.get("kind") != "Role":
            bad.append(f"{where}: must reference a namespaced Role, not {ref.get('kind')} {ref.get('name')}")
            continue
        role = roles.get((ns_of(b), ref.get("name")))
        if role is None:
            bad.append(f"{where}: Role {ref.get('name')} is not defined in the validated files")
            continue
        for i, r in enumerate(role.get("rules") or []):
            groups, res, verbs = set(r.get("apiGroups") or []), set(r.get("resources") or []), set(r.get("verbs") or [])
            rw = f"Role {ns_of(role)}/{name_of(role)} rule {i}"
            if "secrets" in res or "*" in res:
                bad.append(f"{rw}: Grafana must not be granted access to Secrets")
            if groups != {""} or not res or res - GRAFANA_ALLOWED_RESOURCES:
                bad.append(f"{rw}: only core-group configmaps are allowed, found apiGroups={sorted(groups)} "
                           f"resources={sorted(res)}")
            if not verbs or verbs - GRAFANA_ALLOWED_VERBS:
                bad.append(f"{rw}: only get, list and watch are allowed, found verbs={sorted(verbs)}")
            if r.get("resourceNames") is None and verbs >= GRAFANA_ALLOWED_VERBS and "configmaps" in res:
                configmap_access.add(ns_of(b))
        print(f"{where} -> Role {ref.get('name')}: {role.get('rules')}")

    sidecars = 0
    for dep in deployments:
        spec = _pod_spec(dep) or {}
        for c in (spec.get("initContainers") or []) + (spec.get("containers") or []):
            if not str(c.get("name", "")).startswith("grafana-sc-"):
                continue
            sidecars += 1
            env = {e.get("name"): e.get("value") for e in c.get("env") or []}
            where = f"Grafana sidecar {c.get('name')}"
            watched = [n.strip() for n in str(env.get("NAMESPACE") or release_ns).split(",")]
            if watched != [release_ns]:
                bad.append(f"{where}: watches namespaces {watched}; only {release_ns} is allowed")
            if env.get("RESOURCE") != "configmap":
                bad.append(f"{where}: RESOURCE={env.get('RESOURCE')}; only configmap is allowed")
            print(f"{where}: namespace={watched} resource={env.get('RESOURCE')}")
    if sidecars and release_ns not in configmap_access:
        bad.append(f"Grafana sidecars need get, list and watch on ConfigMaps in {release_ns}, "
                   "but no Role bound to the Grafana ServiceAccount grants them")

    # Orphaned RBAC: in a file under the monitoring directory, but not applied by Flux.
    def rid(d):
        kind = d.get("kind")
        return kind, "" if kind.startswith("Cluster") else ns_of(d), name_of(d)

    def grafana_related(d):
        return is_grafana(d) or "grafana" in str(name_of(d)) or (d.get("kind", "").endswith("Binding") and binds_grafana(d))

    applied_ids = {rid(d) for _, d in docs_in([applied])}
    disk = [(p, d) for p, d in docs_in(repo_files) if d.get("kind") in RBAC_KINDS]
    bound_roles = {(ns_of(d), (d.get("roleRef") or {}).get("name"))
                   for _, d in disk if d.get("kind") == "RoleBinding" and grafana_related(d)}
    for p, d in disk:
        related = grafana_related(d) or (d.get("kind") == "Role" and (ns_of(d), name_of(d)) in bound_roles)
        if related and rid(d) not in applied_ids:
            kind, ns, name = rid(d)
            bad.append(f"{kind} {ns + '/' if ns else ''}{name} in {p} is not part of the monitoring/controllers "
                       "Kustomization render; add its file to controllers/kustomization.yaml or delete it")
    for b in bad:
        print(f"::error::Grafana RBAC: {b}")
    sys.exit(1 if bad else 0)


COMMANDS = {
    "pod-security": cmd_pod_security,
    "grafana-rbac": cmd_grafana_rbac,
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
