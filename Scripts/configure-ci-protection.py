#!/usr/bin/env python3
"""Inspect or apply CI protection, with a staged required-check migration."""
import argparse
import json
from pathlib import Path
import subprocess
import stat
import re
import shlex
import sys

RELEASE_SECRETS = {"HOMEBREW_TAP_TOKEN", "MACOS_CERT_P12", "MACOS_CERT_PASSWORD", "NOTARY_APPLE_ID", "NOTARY_APP_PASSWORD", "NOTARY_TEAM_ID", "SPARKLE_PRIVATE_ED_KEY", "SPARKLE_PUBLIC_ED_KEY", "VOLVO_CLIENT_ID", "VOLVO_CLIENT_SECRET", "VOLVO_VCC_API_KEY"}
LEGACY_CHECKS = ["lint-workflows-and-scripts", "check-localization", "check-docs", "check-vin-scoping", "check-contrast", "build-and-test (macos-15)"]


def api(repo, path, method="GET", body=None):
    command = ["gh", "api", "--method", method, f"repos/{repo}/{path}"]
    if body is not None:
        command += ["--input", "-"]
    result = subprocess.run(command, input=json.dumps(body) if body is not None else None, capture_output=True, text=True, timeout=60)
    if result.returncode:
        raise RuntimeError(f"GitHub {method} {path} failed: {result.stderr.strip()}")
    return json.loads(result.stdout) if result.stdout.strip() else None


def main_rule(current, aggregate):
    rules = [rule for rule in current.get("rules", []) if rule["type"] != "required_status_checks"]
    for required in ("deletion", "non_fast_forward"):
        if not any(rule["type"] == required for rule in rules):
            rules.append({"type": required})
    if not any(rule["type"] == "pull_request" for rule in rules):
        rules.append({"type": "pull_request", "parameters": {"required_approving_review_count": 0, "dismiss_stale_reviews_on_push": False, "require_code_owner_review": False, "require_last_push_approval": False, "required_review_thread_resolution": True}})
    rules.append({"type": "required_status_checks", "parameters": {"strict_required_status_checks_policy": True, "do_not_enforce_on_create": False, "required_status_checks": [{"context": name, "integration_id": 15368} for name in (["ci-required"] if aggregate else LEGACY_CHECKS)]}})
    return {"name": "protect-main", "target": "branch", "enforcement": "active", "bypass_actors": current.get("bypass_actors", []), "conditions": {"ref_name": {"include": ["refs/heads/main"], "exclude": []}}, "rules": rules}


def read_environment_credentials(filename):
    allowed = RELEASE_SECRETS | {"POLESTAR_IMAGE_API_KEY"}
    values = {}
    for line in Path(filename).read_text().splitlines():
        match = re.match(r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$", line)
        if not match or match[1] not in allowed:
            continue
        tokens = shlex.split(match[2], comments=True, posix=True)
        if len(tokens) != 1 or not tokens[0]:
            raise RuntimeError(f"Expected one literal value for {match[1]}; use --secrets-json for multiline values")
        values[match[1]] = tokens[0]
    if not values:
        raise RuntimeError("No release credential names found in the supplied environment file")
    return values


def write_environment_secrets(repo, values):
    for name in sorted(values):
        result = subprocess.run(["gh", "secret", "set", name, "--repo", repo, "--env", "production-release"], input=values[name], text=True, capture_output=True, timeout=60)
        if result.returncode:
            raise RuntimeError(f"Could not set production-release secret {name}; repository originals were retained")
    scoped = subprocess.run(["gh", "secret", "list", "--repo", repo, "--env", "production-release", "--json", "name"], capture_output=True, text=True, check=True, timeout=60)
    if not set(values) <= {entry["name"] for entry in json.loads(scoped.stdout)}:
        raise RuntimeError("Environment secret verification failed; repository originals were retained")
    repository = subprocess.run(["gh", "secret", "list", "--repo", repo, "--json", "name"], capture_output=True, text=True, check=True, timeout=60)
    existing = {entry["name"] for entry in json.loads(repository.stdout)}
    for name in sorted(set(values) & existing):
        subprocess.run(["gh", "secret", "delete", name, "--repo", repo], check=True, capture_output=True, text=True, timeout=60)
    missing = RELEASE_SECRETS - {entry["name"] for entry in json.loads(scoped.stdout)}
    print(f"release-secrets-scoped: verified {len(values)} environment copies; removed their repository copies")
    if missing:
        print("Original credential material still needed for: " + ", ".join(sorted(missing)))


def migrate_secrets(repo, filename, environment_file=False):
    path = Path(filename)
    metadata = path.stat()
    if stat.S_IMODE(metadata.st_mode) & 0o077:
        raise RuntimeError("Credential source must be private to its owner (chmod 600)")
    if environment_file:
        values = read_environment_credentials(path)
    else:
        values = json.loads(path.read_text())
        if not isinstance(values, dict) or any(not isinstance(values.get(name), str) or not values[name].strip() for name in RELEASE_SECRETS):
            raise RuntimeError("Credential JSON must contain all required release secret names with nonempty string values")
        values = {name: values[name] for name in RELEASE_SECRETS}
    write_environment_secrets(repo, values)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", default="NicolasKheirallah/Hisingen")
    parser.add_argument("--apply", action="store_true")
    parser.add_argument("--aggregate", action="store_true", help="Switch required check after ci-required is deployed and successful on main")
    parser.add_argument("--enable-immutable", action="store_true")
    parser.add_argument("--secrets-env", help="Owner-private env file; migrate only recognized release configuration values without executing it")
    parser.add_argument("--secrets-json", help="Private local JSON containing original release secret values; migrate after applying ref restrictions")
    parser.add_argument("--backup-dir", default=".unlazy/ci-stability-20261031/protection-backup")
    args = parser.parse_args()
    rulesets = api(args.repo, "rulesets?per_page=100")
    found = next((rule for rule in rulesets if rule["name"] == "protect-main"), None)
    current = api(args.repo, f"rulesets/{found['id']}") if found else {}
    existing_names = {env["name"] for env in api(args.repo, "environments?per_page=100")["environments"]}
    environments = {name: api(args.repo, f"environments/{name}") if name in existing_names else {} for name in ["production-release", "github-pages", "live-integration"]}
    immutable = api(args.repo, "immutable-releases")
    desired = main_rule(current, args.aggregate)
    if args.apply:
        if args.aggregate:
            checks = api(args.repo, "commits/main/check-runs?per_page=100")["check_runs"]
            if not any(check["name"] == "ci-required" and check["conclusion"] == "success" and check["app"]["id"] == 15368 for check in checks):
                raise RuntimeError("ci-required must first succeed on deployed main; legacy checks remain required until then")
        backup = Path(args.backup_dir)
        backup.mkdir(parents=True, exist_ok=True)
        snapshot = backup / "before.json"
        if not snapshot.exists():
            snapshot.write_text(json.dumps({"main": current, "environments": environments, "immutable": immutable}, indent=2) + "\n")
        api(args.repo, f"rulesets/{found['id']}" if found else "rulesets", "PUT" if found else "POST", desired)
        for name, existing in environments.items():
            body = {"deployment_branch_policy": {"protected_branches": False, "custom_branch_policies": True}}
            for rule in existing.get("protection_rules", []):
                if rule["type"] == "required_reviewers":
                    body["reviewers"] = [{"type": row["type"], "id": row["reviewer"]["id"]} for row in rule.get("reviewers", [])]
                    body["prevent_self_review"] = rule.get("prevent_self_review", False)
                elif rule["type"] == "wait_timer":
                    body["wait_timer"] = rule["wait_timer"]
            api(args.repo, f"environments/{name}", "PUT", body)
            policies = api(args.repo, f"environments/{name}/deployment-branch-policies?per_page=100")["branch_policies"]
            allowed = {("main", "branch")} | ({("v*", "tag")} if name != "live-integration" else set())
            if name == "github-pages":
                allowed.add(("gh-pages", "branch"))
            for policy in policies:
                if (policy["name"], policy.get("type", "branch")) not in allowed:
                    api(args.repo, f"environments/{name}/deployment-branch-policies/{policy['id']}", "DELETE")
            actual = {(policy["name"], policy.get("type", "branch")) for policy in policies}
            for ref, kind in sorted(allowed - actual):
                api(args.repo, f"environments/{name}/deployment-branch-policies", "POST", {"name": ref, "type": kind})
        if args.secrets_json and args.secrets_env:
            raise RuntimeError("Choose one credential source format")
        if args.secrets_json or args.secrets_env:
            migrate_secrets(args.repo, args.secrets_env or args.secrets_json, environment_file=bool(args.secrets_env))
        if args.enable_immutable and not immutable["enabled"]:
            api(args.repo, "immutable-releases", "PUT")
    actual_main = next((rule for rule in api(args.repo, "rulesets?per_page=100") if rule["name"] == "protect-main"), {})
    actual_main = api(args.repo, f"rulesets/{actual_main['id']}") if actual_main else {}
    if actual_main.get("enforcement") != "active":
        raise RuntimeError("Main protection is not active")
    status_rule = next((rule for rule in actual_main["rules"] if rule["type"] == "required_status_checks"), {})
    contexts = [row["context"] for row in status_rule.get("parameters", {}).get("required_status_checks", [])]
    if set(contexts) != set(["ci-required"] if args.aggregate else LEGACY_CHECKS):
        raise RuntimeError(f"Required checks differ from rollout contract: {contexts}")
    for name in environments:
        env = api(args.repo, f"environments/{name}")
        if not (env.get("deployment_branch_policy") or {}).get("custom_branch_policies"):
            raise RuntimeError(f"{name} has no custom ref restriction")
        actual = {(p["name"], p.get("type", "branch")) for p in api(args.repo, f"environments/{name}/deployment-branch-policies?per_page=100")["branch_policies"]}
        expected = {("main", "branch")} | ({("v*", "tag")} if name != "live-integration" else set()) | ({("gh-pages", "branch")} if name == "github-pages" else set())
        if actual != expected:
            raise RuntimeError(f"Unexpected {name} ref policies: {actual}")
    if args.enable_immutable and not api(args.repo, "immutable-releases")["enabled"]:
        raise RuntimeError("Immutable releases are disabled")
    print("ci-protection-verified: " + ", ".join(contexts))


if __name__ == "__main__":
    try:
        main()
    except (RuntimeError, OSError, ValueError, subprocess.SubprocessError) as error:
        print(str(error), file=sys.stderr)
        sys.exit(1)
