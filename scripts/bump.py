#!/usr/bin/env nix
#! nix shell nixpkgs#python3 --command python3 -B
"""Check and bump flake inputs and custom packages in nix-kyaru."""

from __future__ import annotations

import argparse
import concurrent.futures
import datetime as dt
import json
import os
import pathlib
import re
import socket
import subprocess
import sys
import urllib.error
import urllib.request

ROOT = pathlib.Path(__file__).resolve().parent.parent
SECRET_ROOT = ROOT.parent / "nix-kyaru-secret"
LMOD_VER_RE = r'^(  version = )"([^"]+)";'


def detect_proxy() -> str | None:
    for var in ("HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy"):
        if val := os.environ.get(var):
            return val
    try:
        with socket.create_connection(("127.0.0.1", 3090), timeout=0.2):
            return "http://127.0.0.1:3090"
    except OSError:
        return None


def detect_github_token() -> str | None:
    for var in ("GITHUB_TOKEN", "GH_TOKEN"):
        if val := os.environ.get(var):
            return val
    try:
        out = subprocess.check_output(
            ["gh", "auth", "token"], stderr=subprocess.DEVNULL, text=True, timeout=3
        ).strip()
        if out:
            return out
    except Exception:
        pass
    return None


class GitHubClient:
    def __init__(self, proxy: str | None, token: str | None):
        handlers: list[urllib.request.BaseHandler] = []
        if proxy:
            handlers.append(urllib.request.ProxyHandler({"https": proxy, "http": proxy}))
        self.opener = urllib.request.build_opener(*handlers)
        self.token = token

    def get(self, url: str, *, raw: bool = False):
        headers = {"User-Agent": "nix-kyaru-bump"}
        if self.token and "api.github.com" in url:
            headers["Authorization"] = f"Bearer {self.token}"
        req = urllib.request.Request(url, headers=headers)
        with self.opener.open(req, timeout=15) as resp:
            data = resp.read().decode("utf-8")
            return data if raw else json.loads(data)

    def latest_release(self, repo: str, *, include_prerelease: bool = False) -> tuple[str, str]:
        rels = self.get(f"https://api.github.com/repos/{repo}/releases?per_page=15")
        for r in rels:
            if r.get("draft"):
                continue
            if not include_prerelease and r.get("prerelease"):
                continue
            return r["tag_name"], (r.get("published_at") or "")[:10]
        raise RuntimeError(f"No matching release found for {repo}")

    def latest_commit(self, repo: str, ref: str | None = None) -> tuple[str, str, str]:
        q = f"?sha={ref}&per_page=1" if ref else "?per_page=1"
        cms = self.get(f"https://api.github.com/repos/{repo}/commits{q}")
        c = cms[0]
        sha = c["sha"]
        date = c["commit"]["committer"]["date"]
        msg = c["commit"]["message"].splitlines()[0]
        return sha, date, msg

    def latest_semver_tag(self, repo: str) -> str:
        tags = self.get(f"https://api.github.com/repos/{repo}/tags?per_page=30")
        parsed: list[tuple[tuple[int, ...], str]] = []
        for t in tags:
            name = t["name"]
            if m := re.fullmatch(r"v?(\d+(?:\.\d+)+)", name):
                parsed.append((tuple(int(x) for x in m.group(1).split(".")), name))
        if not parsed:
            raise RuntimeError(f"No semver tag found for {repo}")
        parsed.sort(reverse=True)
        return parsed[0][1]

    def compare(self, repo: str, base_head: str) -> tuple[int, int]:
        data = self.get(f"https://api.github.com/repos/{repo}/compare/{base_head}")
        return int(data.get("ahead_by", 0)), int(data.get("behind_by", 0))


def run_nix_prefetch(url: str, *, unpack: bool, env: dict[str, str]) -> str:
    cmd = ["nix-prefetch-url"]
    if unpack:
        cmd.append("--unpack")
    cmd.append(url)
    out = subprocess.check_output(cmd, env=env, stderr=subprocess.DEVNULL, text=True).strip()
    raw_hash = out.splitlines()[-1].strip()
    sri = subprocess.check_output(
        ["nix", "hash", "convert", "--hash-algo", "sha256", "--to", "sri", raw_hash],
        env=env,
        text=True,
    ).strip()
    return sri


def _run_nix_fake_hash(cmd: list[str], env: dict[str, str], label: str) -> str:
    proc = subprocess.run(cmd, cwd=ROOT, env=env, capture_output=True, text=True)
    combined = proc.stdout + "\n" + proc.stderr
    m = re.search(r"got:\s+(sha256-[A-Za-z0-9+/=]+)", combined)
    if not m:
        raise RuntimeError(f"Could not extract got: hash from `{label}`:\n{combined[-1500:]}")
    return m.group(1)


def probe_fake_hash(attr: str, env: dict[str, str]) -> str:
    return _run_nix_fake_hash(["nix", "build", attr, "--no-link"], env, f"nix build {attr}")


def probe_fake_hash_expr(expr: str, env: dict[str, str]) -> str:
    return _run_nix_fake_hash(
        ["nix", "build", "--impure", "--no-link", "--expr", expr],
        env,
        "nix build --expr ...",
    )


def replace_once(text: str, pattern: str, repl: str, desc: str) -> str:
    new_text, count = re.subn(pattern, repl, text, count=1, flags=re.MULTILINE)
    if count != 1:
        raise RuntimeError(f"Expected 1 match for {desc}, got {count}")
    return new_text


def parse_lock_inputs(lock_path: pathlib.Path) -> list[dict]:
    data = json.loads(lock_path.read_text())
    nodes = data["nodes"]
    root_node = nodes[data["root"]]
    out = []
    for name, ref in sorted(root_node.get("inputs", {}).items()):
        if isinstance(ref, list):
            continue  # follows another input
        node = nodes.get(ref, {})
        locked = node.get("locked", {})
        original = node.get("original", {})
        if locked.get("type") != "github":
            continue
        ts = locked.get("lastModified")
        date = dt.datetime.fromtimestamp(ts, dt.timezone.utc).strftime("%Y-%m-%d") if ts else "?"
        out.append(
            {
                "name": name,
                "owner": locked["owner"],
                "repo": locked["repo"],
                "rev": locked["rev"],
                "date": date,
                "ref": original.get("ref"),
            }
        )
    return out


def cmd_check(gh: GitHubClient, *, run_bfr: bool) -> int:
    print("== Flake Inputs ==")
    lock_files = [("nix-kyaru", ROOT / "flake.lock")]
    if (SECRET_ROOT / "flake.lock").exists():
        lock_files.append(("nix-kyaru-secret", SECRET_ROOT / "flake.lock"))

    all_inputs = []
    for label, path in lock_files:
        for item in parse_lock_inputs(path):
            item["flake"] = label
            all_inputs.append(item)

    def check_input(item: dict) -> tuple[dict, str, str]:
        repo = f"{item['owner']}/{item['repo']}"
        try:
            sha, date_iso, _ = gh.latest_commit(repo, item["ref"])
            return item, sha, date_iso[:10]
        except Exception as e:
            return item, f"ERR:{e}", "?"

    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as ex:
        results = list(ex.map(check_input, all_inputs))

    for item, latest_sha, latest_date in results:
        label = f"{item['flake']}:{item['name']}"
        if latest_sha.startswith("ERR:"):
            status = latest_sha
        elif latest_sha == item["rev"]:
            status = f"ok ({item['date']})"
        else:
            status = f"UPDATE {item['date']} ({item['rev'][:8]}) -> {latest_date} ({latest_sha[:8]})"
        print(f"  {label:38s} {status}")

    print("\n== Forks vs Upstream ==")
    forks = [
        ("bifrost", "KiruyaMomochi/bifrost", "dev...maximhq:dev"),
        ("hermes-agent", "KiruyaMomochi/hermes-agent", "local...NousResearch:main"),
    ]
    for name, repo, spec in forks:
        try:
            ahead, behind = gh.compare(repo, spec)
            print(f"  {name:20s} upstream ahead by {ahead}, fork ahead by {behind}")
        except Exception as e:
            print(f"  {name:20s} ERR: {e}")

    print("\n== Custom Packages ==")

    def read_ver(rel: str, regex: str = r'version\s*=\s*"([^"]+)"') -> str:
        m = re.search(regex, (ROOT / rel).read_text(), re.MULTILINE)
        return m.group(m.lastindex) if m and m.lastindex else "?"

    pkg_checks = []

    def check_pkg(name: str, fn):
        try:
            return name, fn()
        except Exception as e:
            return name, f"ERR: {e}"

    def chk_greptime():
        cur = read_ver("packages/greptimedb/default.nix")
        cur_bin = read_ver("packages/greptimedb-bin/default.nix")
        tag, date = gh.latest_release("GreptimeTeam/greptimedb")
        up = tag.lstrip("v")
        note = "" if cur == cur_bin else f" (bin={cur_bin})"
        return f"ok ({cur}{note})" if cur == up and cur_bin == up else f"UPDATE {cur}{note} -> {up} ({date})"

    def chk_grafana():
        cur = read_ver("packages/greptimedb-grafana-datasource/default.nix")
        tag, date = gh.latest_release("GreptimeTeam/greptimedb-grafana-datasource")
        up = tag.lstrip("v")
        return f"ok ({cur})" if cur == up else f"UPDATE {cur} -> {up} ({date})"

    def chk_shadowquic():
        cur = read_ver("packages/shadowquic/default.nix")
        tag, date = gh.latest_release("spongebob888/shadowquic")
        up = tag.lstrip("v")
        return f"ok ({cur})" if cur == up else f"UPDATE {cur} -> {up} ({date})"

    def chk_caddy():
        txt = (ROOT / "packages/caddy-naive/default.nix").read_text()
        m = re.search(r"forwardproxy@(v0\.0\.0-\d{14}-([0-9a-f]+))", txt)
        cur_pseudo = m.group(1) if m else "?"
        cur_sha = m.group(2) if m else ""
        sha, date_iso, _ = gh.latest_commit("klzgrad/forwardproxy")
        if sha.startswith(cur_sha) and cur_sha:
            return f"ok ({cur_pseudo})"
        dt_utc = dt.datetime.fromisoformat(date_iso.replace("Z", "+00:00")).astimezone(dt.timezone.utc)
        up = f"v0.0.0-{dt_utc.strftime('%Y%m%d%H%M%S')}-{sha[:12]}"
        return f"UPDATE {cur_pseudo} -> {up}"

    def chk_lmod():
        cur = read_ver("packages/lmod/default.nix", LMOD_VER_RE)
        up = gh.latest_semver_tag("TACC/Lmod").lstrip("v")
        return f"ok ({cur})" if cur == up else f"UPDATE {cur} -> {up}"

    def chk_maple():
        cur = read_ver("packages/maple-mono-nf-tc/default.nix")
        tag, date = gh.latest_release("subframe7536/maple-font", include_prerelease=True)
        up = tag.lstrip("v")
        return f"ok ({cur})" if cur == up else f"UPDATE {cur} -> {up} ({date})"

    def chk_commit_pkg(rel: str, repo: str):
        cur = read_ver(rel, r'rev\s*=\s*"([0-9a-f]+)"')
        sha, date_iso, _ = gh.latest_commit(repo)
        return f"ok ({cur[:10]})" if sha.startswith(cur) else f"UPDATE {cur[:10]} -> {sha[:10]} ({date_iso[:10]})"

    def chk_ddcci():
        cur = read_ver("packages/ddcci-plasmoid/default.nix", r'rev\s*=\s*"([0-9a-f]+)"')
        tags = gh.get("https://api.github.com/repos/davidhi7/ddcci-plasmoid/tags?per_page=5")
        kf6 = next((t for t in tags if "kf6" in t["name"]), tags[0])
        up = kf6["commit"]["sha"]
        return f"ok ({kf6['name']} {cur[:10]})" if up.startswith(cur) else f"UPDATE {cur[:10]} -> {kf6['name']} {up[:10]}"

    tasks = [
        ("greptimedb", chk_greptime),
        ("greptimedb-grafana", chk_grafana),
        ("shadowquic", chk_shadowquic),
        ("caddy-naive", chk_caddy),
        ("lmod", chk_lmod),
        ("maple-mono-nf-tc", chk_maple),
        ("skvirt", lambda: chk_commit_pkg("packages/skvirt/default.nix", "Vendetta1871/skvirt")),
        ("ftfp-proxy", lambda: chk_commit_pkg("packages/ftfp-proxy/default.nix", "pccr10001/ftfp_proxy")),
        ("ddcci-plasmoid", chk_ddcci),
    ]
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as ex:
        futs = [ex.submit(check_pkg, n, fn) for n, fn in tasks]
        for f in futs:
            pkg_checks.append(f.result())

    for name, msg in pkg_checks:
        print(f"  {name:24s} {msg}")

    if run_bfr and (SECRET_ROOT / "scripts/bfr").exists():
        print("\n== Bifrost Web Config Sync ==")
        try:
            proc = subprocess.run(
                [str(SECRET_ROOT / "scripts/bfr"), "sync"],
                capture_output=True,
                text=True,
                timeout=15,
            )
            if "Everything in sync" in proc.stdout:
                print("  ✓ Everything in sync.")
            else:
                print(proc.stdout.strip() or proc.stderr.strip())
        except Exception as e:
            print(f"  bfr sync skipped/err: {e}")

    return 0


def update_greptimedb_bin(gh: GitHubClient, env: dict[str, str], target_ver: str | None = None) -> bool:
    p = ROOT / "packages/greptimedb-bin/default.nix"
    txt = p.read_text()
    cur = re.search(r'version\s*=\s*"([^"]+)"', txt).group(1)
    if not target_ver:
        tag, _ = gh.latest_release("GreptimeTeam/greptimedb")
        target_ver = tag.lstrip("v")
    if cur == target_ver:
        print(f"greptimedb-bin already at {cur}")
        return False
    url = f"https://github.com/GreptimeTeam/greptimedb/releases/download/v{target_ver}/greptime-linux-amd64-v{target_ver}.tar.gz"
    sri = run_nix_prefetch(url, unpack=False, env=env)
    txt = replace_once(txt, r'version = "[^"]+";', f'version = "{target_ver}";', "greptimedb-bin version")
    txt = replace_once(txt, r'hash = "sha256-[^"]+";', f'hash = "{sri}";', "greptimedb-bin hash")
    p.write_text(txt)
    subprocess.run(["nix", "build", ".#greptimedb-bin", "--no-link"], cwd=ROOT, env=env, check=True)
    print(f"Updated greptimedb-bin: {cur} -> {target_ver}")
    return True


def update_greptimedb(gh: GitHubClient, env: dict[str, str]) -> bool:
    tag, _ = gh.latest_release("GreptimeTeam/greptimedb")
    target_ver = tag.lstrip("v")
    changed_bin = update_greptimedb_bin(gh, env, target_ver=target_ver)

    p = ROOT / "packages/greptimedb/default.nix"
    txt = p.read_text()
    cur = re.search(r'version\s*=\s*"([^"]+)"', txt).group(1)
    if cur == target_ver:
        print(f"greptimedb already at {cur}")
        return changed_bin

    src_hash = run_nix_prefetch(
        f"https://github.com/GreptimeTeam/greptimedb/archive/refs/tags/v{target_ver}.tar.gz",
        unpack=True,
        env=env,
    )
    toolchain_toml = gh.get(
        f"https://raw.githubusercontent.com/GreptimeTeam/greptimedb/v{target_ver}/rust-toolchain.toml",
        raw=True,
    )
    m_tc = re.search(r'channel\s*=\s*"([^"]+)"', toolchain_toml)
    if not m_tc:
        raise RuntimeError("Could not parse rust-toolchain.toml channel")
    new_tc = m_tc.group(1)

    dash_ver = gh.get(
        f"https://raw.githubusercontent.com/GreptimeTeam/greptimedb/v{target_ver}/src/servers/dashboard/VERSION",
        raw=True,
    ).strip()

    cargo_lock = gh.get(
        f"https://raw.githubusercontent.com/GreptimeTeam/greptimedb/v{target_ver}/Cargo.lock",
        raw=True,
    )
    m_oa = re.search(
        r'name = "otel-arrow-rust"\s*\nversion = "[^"]+"\s*\nsource = "git\+https://github\.com/GreptimeTeam/otel-arrow\?rev=([0-9a-f]+)',
        cargo_lock,
    )
    if not m_oa:
        raise RuntimeError("Could not parse otel-arrow-rust rev in Cargo.lock")
    new_oa_rev = m_oa.group(1)

    cur_tc = re.search(r'rustToolchainChannel\s*=\s*"([^"]+)"', txt).group(1)
    cur_dash = re.search(r'dashboardVersion\s*=\s*"([^"]+)"', txt).group(1)
    cur_oa_rev = re.search(r'otelArrowSrc = fetchFromGitHub \{[^}]*rev = "([^"]+)"', txt, re.S).group(1)

    txt = replace_once(txt, r'version = "[^"]+";', f'version = "{target_ver}";', "greptimedb version")
    txt = replace_once(
        txt,
        r'(src = fetchFromGitHub \{[^}]*hash = )"[^"]+";',
        rf'\1"{src_hash}";',
        "greptimedb src.hash",
    )

    if dash_ver != cur_dash:
        dash_hash = run_nix_prefetch(
            f"https://github.com/GreptimeTeam/dashboard/releases/download/{dash_ver}/build.tar.gz",
            unpack=False,
            env=env,
        )
        txt = replace_once(txt, r'dashboardVersion = "[^"]+";', f'dashboardVersion = "{dash_ver}";', "dashboardVersion")
        txt = replace_once(
            txt,
            r'(dashboardAssets = fetchurl \{[^}]*hash = )"[^"]+";',
            rf'\1"{dash_hash}";',
            "dashboardAssets.hash",
        )

    if new_tc != cur_tc:
        txt = replace_once(txt, r'rustToolchainChannel = "[^"]+";', f'rustToolchainChannel = "{new_tc}";', "rustToolchainChannel")
        txt = replace_once(txt, r'toolchainHash = (?:"[^"]+"|lib\.fakeHash);', "toolchainHash = lib.fakeHash;", "toolchainHash fake")
        p.write_text(txt)
        tc_hash = probe_fake_hash(".#greptimedb.cargoDeps", env)
        txt = replace_once(txt, r'toolchainHash = lib\.fakeHash;', f'toolchainHash = "{tc_hash}";', "toolchainHash real")

    if new_oa_rev != cur_oa_rev:
        oa_hash = subprocess.check_output(
            [
                "nix", "shell", "nixpkgs#nix-prefetch-git", "--command",
                "nix-prefetch-git", "--url", "https://github.com/GreptimeTeam/otel-arrow.git",
                "--rev", new_oa_rev, "--fetch-submodules", "--quiet",
            ],
            env=env,
            text=True,
        )
        oa_sri = json.loads(oa_hash)["hash"]
        txt = replace_once(
            txt,
            r'(otelArrowSrc = fetchFromGitHub \{[^}]*rev = )"[^"]+";(\s*fetchSubmodules = true;\s*hash = )"[^"]+";',
            rf'\1"{new_oa_rev}";\2"{oa_sri}";',
            "otelArrowSrc",
        )

    txt = replace_once(txt, r'cargoHash = (?:"[^"]+"|lib\.fakeHash);', "cargoHash = lib.fakeHash;", "cargoHash fake")
    p.write_text(txt)
    cargo_hash = probe_fake_hash(".#greptimedb.cargoDeps", env)
    txt = replace_once(txt, r'cargoHash = lib\.fakeHash;', f'cargoHash = "{cargo_hash}";', "cargoHash real")
    p.write_text(txt)

    subprocess.run(["nix", "build", ".#greptimedb", "--no-link"], cwd=ROOT, env=env, check=True)
    print(f"Updated greptimedb: {cur} -> {target_ver}")
    return True


def update_shadowquic(gh: GitHubClient, env: dict[str, str]) -> bool:
    p = ROOT / "packages/shadowquic/default.nix"
    txt = p.read_text()
    cur = re.search(r'version\s*=\s*"([^"]+)"', txt).group(1)
    tag, _ = gh.latest_release("spongebob888/shadowquic")
    target_ver = tag.lstrip("v")
    if cur == target_ver:
        print(f"shadowquic already at {cur}")
        return False

    src_hash = run_nix_prefetch(
        f"https://github.com/spongebob888/shadowquic/archive/refs/tags/v{target_ver}.tar.gz",
        unpack=True,
        env=env,
    )
    txt = replace_once(txt, r'version = "[^"]+";', f'version = "{target_ver}";', "shadowquic version")
    txt = replace_once(txt, r'(src = fetchFromGitHub \{[^}]*hash = )"[^"]+";', rf'\1"{src_hash}";', "shadowquic src.hash")
    txt = replace_once(txt, r'cargoHash = (?:"[^"]+"|lib\.fakeHash);', "cargoHash = lib.fakeHash;", "shadowquic cargoHash fake")
    p.write_text(txt)

    cargo_hash = probe_fake_hash(".#shadowquic.cargoDeps", env)
    txt = replace_once(txt, r'cargoHash = lib\.fakeHash;', f'cargoHash = "{cargo_hash}";', "shadowquic cargoHash real")
    p.write_text(txt)
    subprocess.run(["nix", "build", ".#shadowquic", "--no-link"], cwd=ROOT, env=env, check=True)
    print(f"Updated shadowquic: {cur} -> {target_ver}")
    return True


def update_caddy_naive(gh: GitHubClient, env: dict[str, str]) -> bool:
    p = ROOT / "packages/caddy-naive/default.nix"
    txt = p.read_text()
    m = re.search(r"forwardproxy@(v0\.0\.0-\d{14}-[0-9a-f]+)", txt)
    cur = m.group(1) if m else "?"
    sha, date_iso, _ = gh.latest_commit("klzgrad/forwardproxy")
    dt_utc = dt.datetime.fromisoformat(date_iso.replace("Z", "+00:00")).astimezone(dt.timezone.utc)
    target = f"v0.0.0-{dt_utc.strftime('%Y%m%d%H%M%S')}-{sha[:12]}"
    if cur != target:
        txt = replace_once(txt, r"forwardproxy@v0\.0\.0-\d{14}-[0-9a-f]+", f"forwardproxy@{target}", "forwardproxy pin")
        p.write_text(txt)

    expr = (
        'let f = builtins.getFlake (toString ./.);'
        ' p = f.packages.${builtins.currentSystem}.caddy-naive;'
        ' in p.src.overrideAttrs (_: {'
        ' outputHash = f.inputs.nixpkgs.lib.fakeHash;'
        ' impureEnvVars = [ "GOPROXY" "https_proxy" "http_proxy" "no_proxy" ];'
        ' })'
    )
    plugin_hash = probe_fake_hash_expr(expr, env)
    txt = replace_once(p.read_text(), r'hash = "sha256-[A-Za-z0-9+/=]+";', f'hash = "{plugin_hash}";', "caddy-naive src.hash")
    p.write_text(txt)
    subprocess.run(["nix", "build", ".#caddy-naive", "--no-link"], cwd=ROOT, env=env, check=True)
    print(f"Updated/verified caddy-naive ({cur} -> {target})")
    return True


def update_lmod(gh: GitHubClient, env: dict[str, str]) -> bool:
    p = ROOT / "packages/lmod/default.nix"
    txt = p.read_text()
    m = re.search(LMOD_VER_RE, txt, re.MULTILINE)
    if not m:
        raise RuntimeError("Could not parse current lmod version")
    cur = m.group(2)
    target_ver = gh.latest_semver_tag("TACC/Lmod").lstrip("v")
    if cur == target_ver:
        print(f"lmod already at {cur}")
        return False

    sri = run_nix_prefetch(f"https://github.com/TACC/Lmod/archive/{target_ver}.tar.gz", unpack=False, env=env)
    txt = replace_once(txt, LMOD_VER_RE, rf'\1"{target_ver}";', "lmod version")
    txt = replace_once(txt, r'hash = "sha256-[^"]+";', f'hash = "{sri}";', "lmod src.hash")
    p.write_text(txt)
    subprocess.run(["nix", "build", ".#lmod", "--no-link"], cwd=ROOT, env=env, check=True)
    print(f"Updated lmod: {cur} -> {target_ver}")
    return True


def update_greptimedb_grafana(gh: GitHubClient, env: dict[str, str]) -> bool:
    p = ROOT / "packages/greptimedb-grafana-datasource/default.nix"
    txt = p.read_text()
    cur = re.search(r'version\s*=\s*"([^"]+)"', txt).group(1)
    tag, _ = gh.latest_release("GreptimeTeam/greptimedb-grafana-datasource")
    target_ver = tag.lstrip("v")
    if cur == target_ver:
        print(f"greptimedb-grafana-datasource already at {cur}")
        return False

    src_hash = run_nix_prefetch(
        f"https://github.com/GreptimeTeam/greptimedb-grafana-datasource/archive/refs/tags/v{target_ver}.tar.gz",
        unpack=True,
        env=env,
    )
    txt = replace_once(txt, r'version = "[^"]+";', f'version = "{target_ver}";', "grafana version")
    txt = replace_once(txt, r'(src = fetchFromGitHub \{[^}]*hash = )"[^"]+";', rf'\1"{src_hash}";', "grafana src.hash")
    txt = replace_once(
        txt,
        r'(yarnOfflineCache = fetchYarnDeps \{[^}]*hash = )(?:"[^"]+"|lib\.fakeHash);',
        r'\1lib.fakeHash;',
        "grafana yarn fake",
    )
    p.write_text(txt)
    yarn_hash = probe_fake_hash(".#greptimedb-grafana-datasource.frontend", env)
    txt = replace_once(
        txt,
        r'(yarnOfflineCache = fetchYarnDeps \{[^}]*hash = )lib\.fakeHash;',
        rf'\1"{yarn_hash}";',
        "grafana yarn real",
    )
    txt = replace_once(txt, r'vendorHash = (?:"[^"]+"|lib\.fakeHash);', "vendorHash = lib.fakeHash;", "grafana vendor fake")
    p.write_text(txt)
    vendor_hash = probe_fake_hash(".#greptimedb-grafana-datasource", env)
    txt = replace_once(txt, r'vendorHash = lib\.fakeHash;', f'vendorHash = "{vendor_hash}";', "grafana vendor real")
    p.write_text(txt)
    subprocess.run(["nix", "build", ".#greptimedb-grafana-datasource", "--no-link"], cwd=ROOT, env=env, check=True)
    print(f"Updated greptimedb-grafana-datasource: {cur} -> {target_ver}")
    return True


UPDATERS = {
    "caddy-naive": update_caddy_naive,
    "shadowquic": update_shadowquic,
    "lmod": update_lmod,
    "greptimedb-grafana-datasource": update_greptimedb_grafana,
    "greptimedb-bin": update_greptimedb_bin,
    "greptimedb": update_greptimedb,
}


def main() -> int:
    parser = argparse.ArgumentParser(description="Check and bump nix-kyaru inputs and packages.")
    sub = parser.add_subparsers(dest="cmd")

    p_check = sub.add_parser("check", help="Check flake inputs, forks, packages, and bifrost sync")
    p_check.add_argument("--no-bfr", action="store_true", help="Skip live bfr sync check")

    p_upd = sub.add_parser("update", help="Update one or more packages (or 'all')")
    p_upd.add_argument("targets", nargs="*", default=["all"], help=f"Packages: {', '.join(UPDATERS)} or all")
    p_upd.add_argument("--include-heavy", action="store_true", help="Include source-built greptimedb in 'all'")

    args = parser.parse_args()
    proxy = detect_proxy()
    token = detect_github_token()
    gh = GitHubClient(proxy, token)

    env = dict(os.environ)
    if proxy:
        env.setdefault("https_proxy", proxy)
        env.setdefault("http_proxy", proxy)
    env.setdefault("GOPROXY", "https://goproxy.cn,direct")

    if args.cmd in (None, "check"):
        return cmd_check(gh, run_bfr=not getattr(args, "no_bfr", False))

    targets = args.targets
    if "all" in targets:
        targets = ["caddy-naive", "shadowquic", "lmod", "greptimedb-grafana-datasource"]
        if args.include_heavy or (os.cpu_count() or 1) >= 32:
            targets.append("greptimedb")
        else:
            targets.append("greptimedb-bin")

    for t in targets:
        if t not in UPDATERS:
            print(f"Unknown package '{t}'. Available: {', '.join(UPDATERS)}", file=sys.stderr)
            return 2

    for t in targets:
        UPDATERS[t](gh, env)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
