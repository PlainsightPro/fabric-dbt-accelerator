#!/usr/bin/env python3
"""
bootstrap.py - one-shot setup of the Fabric side of the accelerator.

Asks whether to create a new service principal or reuse an existing one, writes
its object id where Terraform reads it, applies infra/, and offers to push the
resulting variables and secrets into GitHub. Running it once takes a client from
"we have a Fabric capacity" to "the pipelines work".

    python infra/scripts/bootstrap.py

Or through the wrappers, which find the venv interpreter for you:

    ./infra/bootstrap.sh          # macOS / Linux
    .\\infra\\bootstrap.ps1        # Windows

Stdlib only, on purpose: this runs before `pip install -r
requirements/requirements-setup.txt` on a fresh machine. It shells out to the
tools the repo already documents - az, terraform and (optionally) gh.

THE IDENTITY RULE
-----------------
Terraform always runs as the signed-in Azure CLI user. The dbt service principal
is only ever a grantee, never the Terraform principal.

Fabric makes the workspace creator an Admin implicitly, and a second role
assignment for that same principal conflicts - which is why granting the dbt SP
a role used to be documented as unsafe. Keeping the two identities apart removes
the conflict entirely, so ci/accept/prod can hold a real Contributor assignment.
This script enforces the rule by refusing to run under a service principal
login, and by scrubbing FABRIC_CLIENT_ID / FABRIC_CLIENT_SECRET from the
environment it hands to Terraform.

WHAT IT WILL NOT DO
-------------------
Store a secret in Terraform state. The client secret lives in memory for the
duration of this run and reaches GitHub over `gh secret set` stdin; only the
service principal's OBJECT id is passed to Terraform.
"""

from __future__ import annotations

import argparse
import getpass
import json
import os
import re
import shutil
import subprocess
import sys
import time
from pathlib import Path
from typing import NoReturn

INFRA_DIR = Path(__file__).resolve().parents[1]
REPO_ROOT = INFRA_DIR.parent

SP_TFVARS = INFRA_DIR / "sp.auto.tfvars"
TFVARS = INFRA_DIR / "terraform.tfvars"
TFVARS_EXAMPLE = INFRA_DIR / "terraform.tfvars.example"
PLAN_FILE = INFRA_DIR / "bootstrap.tfplan"
ENV_FILE = REPO_ROOT / ".env"

DEFAULT_SP_NAME = "sp-dbt-accelerator"
SECRET_YEARS = 1

FABRIC_API = "https://api.fabric.microsoft.com"
ADMIN_PORTAL = "https://app.fabric.microsoft.com/admin-portal/tenantSettings"

# Provider credentials that would silently override `use_cli`, breaking the
# identity rule above. Scrubbed from Terraform's environment, not from ours -
# the sample-data loader is invoked by Terraform and inherits the same scrub.
FABRIC_CREDENTIAL_VARS = (
    "FABRIC_CLIENT_ID",
    "FABRIC_CLIENT_SECRET",
    "FABRIC_CLIENT_CERTIFICATE",
    "FABRIC_CLIENT_CERTIFICATE_FILE_PATH",
)

GUID_RE = re.compile(r"^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$")


# --- output ------------------------------------------------------------------


def step(text: str) -> None:
    print(f"\n\033[1m==> {text}\033[0m" if sys.stdout.isatty() else f"\n==> {text}")


def info(text: str) -> None:
    print(f"    {text}")


def warn(text: str) -> None:
    print(f"    ! {text}")


def fail(text: str) -> NoReturn:
    sys.exit(f"\nbootstrap: {text}")


# --- process plumbing --------------------------------------------------------


class Runner:
    """Runs external commands, with a dry-run that skips only the mutating ones.

    Read-only probes still execute under --dry-run, so the rehearsal reflects the
    real tenant: it resolves the actual service principal and lists the actual
    capacities, then prints what it *would* change instead of guessing.
    """

    def __init__(self, dry_run: bool) -> None:
        self.dry_run = dry_run

    def __call__(
        self,
        cmd: list[str],
        *,
        mutating: bool = False,
        capture: bool = True,
        check: bool = True,
        stdin: str | None = None,
        env: dict[str, str] | None = None,
        cwd: Path | None = None,
    ) -> subprocess.CompletedProcess:
        printable = " ".join(cmd)

        if self.dry_run and mutating:
            info(f"[dry-run] {printable}")
            return subprocess.CompletedProcess(cmd, 0, "", "")

        exe = shutil.which(cmd[0])
        if exe is None:
            fail(f"'{cmd[0]}' is not on PATH.")

        try:
            return subprocess.run(
                [exe, *cmd[1:]],
                input=stdin,
                capture_output=capture,
                text=True,
                check=check,
                env=env,
                cwd=str(cwd) if cwd else None,
            )
        except subprocess.CalledProcessError as exc:
            if not check:
                raise
            detail = (exc.stderr or exc.stdout or "").strip()
            fail(f"`{printable}` failed with exit code {exc.returncode}.\n\n{detail}")


def az_json(run: Runner, args: list[str], *, mutating: bool = False, check: bool = True):
    """Run an `az` command with -o json and parse the result."""
    result = run(["az", *args, "-o", "json"], mutating=mutating, check=check)
    if result.returncode != 0 or not (result.stdout or "").strip():
        return None
    try:
        return json.loads(result.stdout)
    except json.JSONDecodeError:
        fail(f"`az {' '.join(args)}` returned output that is not JSON:\n{result.stdout}")


# --- prompting ---------------------------------------------------------------


class Prompter:
    def __init__(self, interactive: bool) -> None:
        self.interactive = interactive

    def _refuse(self, what: str) -> NoReturn:
        fail(f"--no-input given, but {what} still needs an answer. Pass it as a flag instead.")

    def text(self, question: str, *, default: str | None = None, what: str = "a value") -> str:
        if not self.interactive:
            if default is None:
                self._refuse(what)
            return default
        suffix = f" [{default}]" if default else ""
        while True:
            answer = input(f"{question}{suffix}: ").strip()
            if answer:
                return answer
            if default is not None:
                return default
            print(f"  {what.capitalize()} is required.")

    def choice(self, question: str, options: list[tuple[str, str]], *, default: str, what: str) -> str:
        if not self.interactive:
            return default
        print(f"\n{question}")
        for index, (_key, label) in enumerate(options, start=1):
            print(f"  [{index}] {label}")
        default_index = [key for key, _ in options].index(default) + 1
        while True:
            answer = input(f"Choice [{default_index}]: ").strip() or str(default_index)
            if answer.isdigit() and 1 <= int(answer) <= len(options):
                return options[int(answer) - 1][0]
            print(f"  Enter a number between 1 and {len(options)}.")

    def confirm(self, question: str, *, default: bool = True) -> bool:
        if not self.interactive:
            return default
        suffix = "[Y/n]" if default else "[y/N]"
        while True:
            answer = input(f"{question} {suffix} ").strip().lower()
            if not answer:
                return default
            if answer in ("y", "yes"):
                return True
            if answer in ("n", "no"):
                return False

    def secret(self, question: str) -> str:
        if not self.interactive:
            self._refuse("a client secret")
        return getpass.getpass(f"{question}: ").strip()


# --- service principal -------------------------------------------------------


class ServicePrincipal:
    def __init__(
        self,
        object_id: str,
        client_id: str | None = None,
        tenant_id: str | None = None,
        secret: str | None = None,
        display_name: str | None = None,
    ) -> None:
        self.object_id = object_id
        self.client_id = client_id
        self.tenant_id = tenant_id
        self.secret = secret
        self.display_name = display_name


def resolve_sp(run: Runner, identifier: str) -> ServicePrincipal | None:
    """Look up a service principal by client id, object id or display name."""
    found = az_json(run, ["ad", "sp", "show", "--id", identifier], check=False)
    if found is None and not GUID_RE.match(identifier):
        matches = az_json(run, ["ad", "sp", "list", "--display-name", identifier]) or []
        if len(matches) > 1:
            names = ", ".join(f"{m['appId']} ({m.get('displayName')})" for m in matches)
            fail(f"'{identifier}' matches more than one service principal: {names}")
        found = matches[0] if matches else None
    if found is None:
        return None
    return ServicePrincipal(
        object_id=found["id"],
        client_id=found.get("appId"),
        display_name=found.get("displayName"),
    )


def reset_secret(run: Runner, sp: ServicePrincipal) -> None:
    """Add a new client secret to the app. Existing secrets are left alone."""
    reset = az_json(
        run,
        [
            "ad", "app", "credential", "reset",
            "--id", sp.client_id or sp.object_id,
            "--years", str(SECRET_YEARS),
            "--display-name", "dbt-accelerator-cicd",
            "--append",
        ],
        mutating=True,
    )
    if reset is None:  # dry-run
        sp.secret = None
        return
    sp.secret = reset["password"]
    sp.client_id = sp.client_id or reset.get("appId")
    sp.tenant_id = sp.tenant_id or reset.get("tenant")


def create_sp(run: Runner, prompt: Prompter, name: str | None) -> ServicePrincipal:
    display_name = name or prompt.text("Display name for the new service principal", default=DEFAULT_SP_NAME)

    existing = resolve_sp(run, display_name)
    if existing is not None:
        info(f"A service principal named '{display_name}' already exists ({existing.client_id}).")
        if not prompt.confirm("Reuse it instead of creating a duplicate?", default=True):
            fail("Choose a different name and run again.")
        return use_existing(run, prompt, sp=existing, new_secret=True)

    # `az ad app create` + `az ad sp create` rather than `az ad sp
    # create-for-rbac`, which also grants the principal an Azure RBAC role on the
    # subscription. Fabric workspace roles are a separate system and that RBAC
    # assignment would be permission this principal has no use for.
    app = az_json(
        run,
        ["ad", "app", "create", "--display-name", display_name, "--sign-in-audience", "AzureADMyOrg"],
        mutating=True,
    )
    if app is None:  # dry-run
        info("[dry-run] would then create the service principal and a client secret")
        return ServicePrincipal(object_id="<new SP object id>", client_id="<new appId>", display_name=display_name)

    client_id = app["appId"]
    info(f"Created app registration {client_id}")

    # Entra replicates a new app to the directory a second or two after the
    # create call returns, so the first `sp create` can legitimately 404.
    sp_object = None
    for attempt in range(1, 6):
        sp_object = az_json(run, ["ad", "sp", "create", "--id", client_id], mutating=True, check=False)
        if sp_object is not None:
            break
        info(f"  app not replicated yet (attempt {attempt}/5), retrying in 5s")
        time.sleep(5)

    if sp_object is None:
        fail(
            f"App registration {client_id} was created, but its service principal was not.\n"
            f"Finish it by hand and re-run:\n"
            f"  az ad sp create --id {client_id}\n"
            f"  python infra/scripts/bootstrap.py --sp-mode existing --sp-id {client_id}"
        )

    sp = ServicePrincipal(
        object_id=sp_object["id"],
        client_id=client_id,
        display_name=display_name,
    )
    info(f"Created service principal, object id {sp.object_id}")
    reset_secret(run, sp)
    info("Created a client secret (held in memory, never written to state or disk)")
    return sp


def use_existing(
    run: Runner,
    prompt: Prompter,
    *,
    sp: ServicePrincipal | None = None,
    identifier: str | None = None,
    new_secret: bool = False,
) -> ServicePrincipal:
    if sp is None:
        identifier = identifier or prompt.text(
            "Client (application) id, object id or display name of the existing service principal",
            what="the existing service principal",
        )
        sp = resolve_sp(run, identifier)
        if sp is None:
            fail(
                f"No service principal found for '{identifier}'.\n"
                "Check it with: az ad sp show --id <appId>\n"
                "An app registration without a service principal in this tenant needs: az ad sp create --id <appId>"
            )

    info(f"Using '{sp.display_name}' - client id {sp.client_id}, object id {sp.object_id}")

    # Minting a credential is a real change to a principal someone else may own,
    # so it never happens on a default - only on an explicit answer or --new-secret.
    if not prompt.interactive:
        if new_secret:
            reset_secret(run, sp)
            info("Added a client secret (--new-secret)")
        else:
            info("No secret collected. Pass --new-secret to add one, or set DBT_SP_CLIENT_SECRET by hand.")
        return sp

    if prompt.confirm("Do you already have this principal's client secret to hand?", default=False):
        sp.secret = prompt.secret("Paste the client secret (input hidden)") or None
    elif new_secret or prompt.confirm("Add a new client secret to it? (existing secrets stay valid)", default=True):
        reset_secret(run, sp)
        info("Added a client secret")
    else:
        warn("No secret collected - DBT_SP_CLIENT_SECRET will have to be set in GitHub by hand.")
    return sp


def write_sp_tfvars(run: Runner, sp: ServicePrincipal | None) -> None:
    """Record the principal's object id, or an explicit blank meaning 'none'.

    The blank case matters: dbt_service_principal_object_id has no default, so
    without this file the -input=false Terraform run below would abort on a
    missing required variable rather than reaching a plan.
    """
    header = (
        "# Generated by scripts/bootstrap.py - do not edit by hand.\n"
        "#\n"
        "# Gitignored (*.tfvars). An .auto.tfvars file outranks terraform.tfvars in\n"
        "# Terraform's precedence order, so this is the effective value even if an\n"
        "# older one is still set there.\n"
        "#\n"
    )
    if sp is None:
        content = header + (
            "# No service principal was selected. Blank is a valid answer, but every\n"
            "# environment must then set dbt_sp_role = null or the plan will fail.\n"
            "\n"
            'dbt_service_principal_object_id = ""\n'
        )
    else:
        content = header + (
            f"# Service principal: {sp.display_name or 'unknown'} (client id {sp.client_id or 'unknown'})\n"
            "\n"
            f'dbt_service_principal_object_id = "{sp.object_id}"\n'
        )

    if run.dry_run:
        info(f"[dry-run] would write {SP_TFVARS.name}:\n{content}")
        return
    SP_TFVARS.write_text(content, encoding="utf-8")
    info(f"Wrote {SP_TFVARS.relative_to(REPO_ROOT)}")


# --- capacity / tfvars -------------------------------------------------------


def read_tfvar(text: str, key: str) -> str | None:
    """The quoted value of a top-level `key = "value"` assignment, if present."""
    match = re.search(rf'^\s*{key}\s*=\s*"([^"]*)"', text, re.MULTILINE)
    return match.group(1) if match else None


def ensure_capacity(run: Runner, prompt: Prompter, capacity_arg: str | None) -> None:
    """Ask which Fabric capacity to use and record it in terraform.tfvars."""
    step("Fabric capacity")

    text = TFVARS.read_text(encoding="utf-8") if TFVARS.exists() else ""
    # capacity_id / capacity_name are the pre-rename spellings; reading them
    # means an older terraform.tfvars migrates instead of being asked from scratch.
    current = next((v for v in (read_tfvar(text, k) for k in ("capacity", "capacity_id", "capacity_name")) if v), None)

    if capacity_arg:
        capacity, label = capacity_arg, "--capacity"
    else:
        capacity, label = choose_capacity(run, prompt, current)

    if run.dry_run:
        info(f"[dry-run] would write {TFVARS.name} with capacity = {capacity!r} ({label})")
        return

    if not TFVARS.exists():
        shutil.copyfile(TFVARS_EXAMPLE, TFVARS)
        info(f"Created {TFVARS.name} from {TFVARS_EXAMPLE.name}")
        text = TFVARS.read_text(encoding="utf-8")

    replacement = f'capacity = "{capacity}"'
    if re.search(r"^\s*#?\s*capacity\s*=.*$", text, re.MULTILINE):
        text = re.sub(r"^\s*#?\s*capacity\s*=.*$", replacement, text, count=1, flags=re.MULTILINE)
    else:
        text += f"\n{replacement}\n"

    # The old names are no longer declared variables, so leaving one uncommented
    # fails the next plan with "Value for undeclared variable".
    text = re.sub(r"^(\s*)(capacity_(id|name)\s*=.*)$", r"\1# \2", text, flags=re.MULTILINE)

    TFVARS.write_text(text, encoding="utf-8")
    info(f"Set capacity = {capacity!r} ({label}) in {TFVARS.name}")


def choose_capacity(run: Runner, prompt: Prompter, current: str | None) -> tuple[str, str]:
    """Return the capacity to use, preferring a GUID over a display name.

    A GUID cannot be ambiguous between two capacities sharing a display name and
    it skips the fabric_capacity data source, which has an open crash report
    under service-principal auth. The "is it Active" check that data source
    performs happens here instead, by only offering Active capacities.
    """
    capacities = az_json(
        run,
        ["rest", "--method", "get", "--url", f"{FABRIC_API}/v1/capacities", "--resource", FABRIC_API],
        check=False,
    )
    active = [c for c in (capacities or {}).get("value", []) if c.get("state") == "Active"]

    if not active:
        warn(
            "No Active capacity is visible to you. Being an Azure subscription Owner is not "
            "enough - the capacity's own 'Capacity administrators' list is separate. A paused "
            "capacity will not appear either."
        )
        answer = prompt.text(
            "Fabric capacity GUID (Azure Portal > the capacity > Properties)",
            default=current,
            what="the Fabric capacity",
        )
        return answer, "unverified" if not GUID_RE.match(answer) else "by GUID"

    default_index = 1
    for index, capacity in enumerate(active, start=1):
        if current and current.lower() in (capacity["id"].lower(), capacity["displayName"].lower()):
            default_index = index

    print("\nActive Fabric capacities you administer:")
    for index, capacity in enumerate(active, start=1):
        marker = "  <- currently configured" if index == default_index and current else ""
        print(f"  [{index}] {capacity['displayName']}  (sku {capacity.get('sku')}){marker}")

    answer = prompt.text(
        "Capacity number, or paste a GUID",
        default=str(default_index),
        what="the Fabric capacity",
    )
    if answer.isdigit() and 1 <= int(answer) <= len(active):
        chosen = active[int(answer) - 1]
        return chosen["id"], chosen["displayName"]
    if GUID_RE.match(answer):
        return answer, "by GUID"
    fail(f"'{answer}' is neither a listed number nor a capacity GUID.")


# --- preflight ---------------------------------------------------------------


def preflight(run: Runner, prompt: Prompter, args: argparse.Namespace) -> dict:
    step("Checking prerequisites")

    required = ["az"] + ([] if args.skip_terraform else ["terraform"])
    for tool in required:
        if shutil.which(tool) is None:
            fail(
                f"'{tool}' is not on PATH. See docs/CLIENT_SETUP.md for the tooling list "
                "(Terraform >= 1.9, Azure CLI, Python 3.11, git)."
            )
        info(f"{tool}: {shutil.which(tool)}")

    if not args.skip_github and shutil.which("gh") is None:
        warn("'gh' is not on PATH - the GitHub wiring step will be skipped.")
        args.skip_github = True

    account = az_json(run, ["account", "show"], check=False)
    if account is None:
        info("Not signed in to the Azure CLI.")
        tenant = args.tenant_id or prompt.text("Entra tenant id to sign in to", what="the tenant id")
        run(["az", "login", "--tenant", tenant], mutating=True, capture=False)
        account = az_json(run, ["account", "show"])

    user = (account or {}).get("user", {})
    if user.get("type") == "servicePrincipal":
        fail(
            "The Azure CLI is signed in as a service principal.\n\n"
            "Terraform must run as a human here: Fabric makes the workspace creator an\n"
            "implicit Admin, and the role assignments this sets up for the dbt principal\n"
            "would conflict with that if the two were the same identity.\n\n"
            "Run `az login --tenant <tenant id>` as yourself and try again."
        )

    info(f"Signed in as {user.get('name')} in tenant {account.get('tenantId')}")
    return account


def fabric_gate(prompt: Prompter, sp: ServicePrincipal | None) -> None:
    """The two prerequisites no API sets reliably. Better asked than debugged."""
    step("Fabric tenant prerequisites")
    print(
        "\n  Two settings live in portals rather than APIs, and both fail late and\n"
        "  confusingly when missed:\n\n"
        "  1. 'Service principals can use Fabric APIs' must be On.\n"
        f"     {ADMIN_PORTAL} > Developer settings\n"
        "     Scope it to a security group containing the principal, or tenant-wide.\n"
        "     Without it the pipelines fail authorization no matter which Fabric\n"
        "     roles they hold.\n\n"
        "  2. You must be a capacity administrator on the Fabric capacity.\n"
        "     Azure Portal > the capacity > Capacity administrators\n"
        "     Assigning new workspaces to a capacity needs this; subscription Owner\n"
        "     does not cover it.\n"
    )
    if sp is not None and sp.client_id:
        info(f"The principal to authorize in step 1: {sp.display_name} ({sp.client_id})")

    if not prompt.interactive:
        warn("--no-input: assuming both are done. The apply will fail on the capacity if not.")
        return

    if not prompt.confirm("\nBoth done?", default=False):
        fail("Sort those two out first, then run this again - nothing has been applied yet.")


# --- terraform ---------------------------------------------------------------


def terraform_env() -> dict[str, str]:
    env = dict(os.environ)
    scrubbed = [name for name in FABRIC_CREDENTIAL_VARS if name in env]
    for name in scrubbed:
        env.pop(name)
    if scrubbed:
        warn(
            f"Scrubbed {', '.join(scrubbed)} from Terraform's environment - "
            "the provider must authenticate as you, not as the dbt principal."
        )
    return env


def apply_terraform(run: Runner, prompt: Prompter) -> None:
    step("Applying infra/")
    env = terraform_env()

    if run.dry_run:
        for cmd in ("init -input=false", "plan -input=false -out=bootstrap.tfplan", "apply -input=false bootstrap.tfplan"):
            info(f"[dry-run] terraform -chdir={INFRA_DIR.name} {cmd}")
        return

    run(["terraform", "init", "-input=false"], capture=False, cwd=INFRA_DIR, env=env)
    run(
        ["terraform", "plan", "-input=false", "-out", PLAN_FILE.name],
        capture=False,
        cwd=INFRA_DIR,
        env=env,
    )

    if not prompt.confirm("\nApply this plan?", default=True):
        PLAN_FILE.unlink(missing_ok=True)
        fail("Nothing applied.")

    try:
        # Applying the saved plan, so what was reviewed is exactly what runs.
        run(["terraform", "apply", "-input=false", PLAN_FILE.name], capture=False, cwd=INFRA_DIR, env=env)
    finally:
        PLAN_FILE.unlink(missing_ok=True)


def terraform_output(run: Runner, name: str, *, raw: bool = False):
    flag = "-raw" if raw else "-json"
    result = run(["terraform", "output", flag, name], cwd=INFRA_DIR, check=False)
    if result.returncode != 0:
        return None
    return result.stdout if raw else json.loads(result.stdout or "null")


# --- github ------------------------------------------------------------------


def wire_github(run: Runner, prompt: Prompter, sp: ServicePrincipal | None, tenant_id: str | None) -> bool:
    step("Wiring the results into GitHub")

    status = run(["gh", "auth", "status"], check=False)
    if status.returncode != 0:
        warn("`gh auth status` reports you are not signed in. Run `gh auth login` and re-run with --skip-terraform.")
        return False

    repo = run(["gh", "repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"], check=False)
    repo_name = (repo.stdout or "").strip() if repo.returncode == 0 else None
    if not repo_name:
        warn("Could not determine the GitHub repository from this directory. Skipping.")
        return False

    repo_vars = terraform_output(run, "github_repository_variables") or {}
    env_vars = terraform_output(run, "github_environment_variables") or {}

    if not repo_vars and not env_vars and not run.dry_run:
        warn("No Terraform outputs available yet - apply first. Skipping.")
        return False

    print(f"\n  Repository: {repo_name}")
    print(f"  {len([v for v in repo_vars.values() if v is not None])} repository variable(s)")
    for env_name, values in env_vars.items():
        print(f"  environment '{env_name}': {len(values)} variable(s)")
    secrets = describe_secrets(sp, tenant_id)
    print(f"  {len(secrets)} repository secret(s): {', '.join(secrets)}" if secrets else "  no secrets to set")

    if not prompt.confirm("\nWrite these to the repository?", default=True):
        info("Skipped. `terraform -chdir=infra output -raw gh_commands` prints the equivalent commands.")
        return False

    for name, value in repo_vars.items():
        if value is None:
            continue
        run(["gh", "variable", "set", name, "--body", str(value)], mutating=True)
        info(f"variable {name}")

    for env_name, values in env_vars.items():
        run(["gh", "api", "-X", "PUT", f"repos/{repo_name}/environments/{env_name}", "--silent"], mutating=True)
        info(f"environment {env_name}")
        for name, value in values.items():
            run(["gh", "variable", "set", name, "--env", env_name, "--body", str(value)], mutating=True)
            info(f"  variable {name}")

    for name, value in secrets.items():
        # Over stdin rather than --body, so the secret never lands in a process
        # listing or a shell history.
        run(["gh", "secret", "set", name], mutating=True, stdin=value)
        info(f"secret {name}")

    return "DBT_SP_CLIENT_SECRET" in secrets


def describe_secrets(sp: ServicePrincipal | None, tenant_id: str | None) -> dict[str, str]:
    if sp is None:
        return {}
    secrets: dict[str, str] = {}
    if tenant_id:
        secrets["DBT_SP_TENANT_ID"] = tenant_id
    if sp.client_id:
        secrets["DBT_SP_CLIENT_ID"] = sp.client_id
    if sp.secret:
        secrets["DBT_SP_CLIENT_SECRET"] = sp.secret
    return secrets


# --- local .env --------------------------------------------------------------


def write_dev_env(run: Runner, prompt: Prompter) -> None:
    block = terraform_output(run, "dev_env_file", raw=True)
    if not block:
        return
    step("Local development .env")
    if ENV_FILE.exists() and not prompt.confirm(f"{ENV_FILE.name} exists. Overwrite it?", default=False):
        print(f"\n{block}\n")
        info("Not written - the block above is the content.")
        return
    if run.dry_run:
        info(f"[dry-run] would write {ENV_FILE.name}")
        return
    ENV_FILE.write_text(block + "\n", encoding="utf-8")
    info(f"Wrote {ENV_FILE.name} (gitignored)")


# --- main --------------------------------------------------------------------


def parse_args(argv: list[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Provision the Fabric side of the accelerator, service principal included.",
    )
    parser.add_argument(
        "--sp-mode",
        choices=("create", "existing", "skip"),
        help="Skip the service principal question: create a new one, use an existing one, or leave sp.auto.tfvars alone.",
    )
    parser.add_argument("--sp-name", help="Display name for --sp-mode create (default: %s)." % DEFAULT_SP_NAME)
    parser.add_argument("--sp-id", help="Client id, object id or display name for --sp-mode existing.")
    parser.add_argument(
        "--new-secret",
        action="store_true",
        help="Add a client secret to an existing principal. Existing secrets stay valid.",
    )
    parser.add_argument(
        "--capacity",
        help="Fabric capacity GUID or display name, skipping the capacity question.",
    )
    parser.add_argument("--tenant-id", help="Entra tenant id, used for `az login` and DBT_SP_TENANT_ID.")
    parser.add_argument("--skip-terraform", action="store_true", help="Configure the service principal, apply nothing.")
    parser.add_argument("--skip-github", action="store_true", help="Do not touch the GitHub repository.")
    parser.add_argument("--skip-env-file", action="store_true", help="Do not offer to write the local .env.")
    parser.add_argument(
        "--no-input",
        action="store_true",
        help="Never prompt; fail instead. Every answer must come from a flag.",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print every change without making it. Read-only lookups still run, so the rehearsal is real.",
    )
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(argv)
    run = Runner(args.dry_run)

    if args.no_input and not args.sp_mode:
        fail("--no-input requires --sp-mode.")
    if not args.no_input and not sys.stdin.isatty():
        # Silently defaulting every answer would apply real infrastructure on
        # assumptions nobody made. Make the caller say so.
        fail("stdin is not a terminal, so the questions cannot be asked. Re-run with --no-input and --sp-mode.")

    prompt = Prompter(interactive=not args.no_input)

    account = preflight(run, prompt, args)
    tenant_id = args.tenant_id or (account or {}).get("tenantId")

    step("Service principal for the dbt pipelines")
    mode = args.sp_mode or prompt.choice(
        "This principal is what CI, accept and prod authenticate as. It will be granted\n"
        "Contributor on those three workspaces.",
        [
            ("create", "Create a new one"),
            ("existing", "Use an existing one"),
            ("skip", f"Skip - keep {SP_TFVARS.name} as it is"),
        ],
        default="create",
        what="the service principal mode",
    )

    sp: ServicePrincipal | None = None
    if mode == "create":
        sp = create_sp(run, prompt, args.sp_name)
    elif mode == "existing":
        sp = use_existing(run, prompt, identifier=args.sp_id, new_secret=args.new_secret)

    if sp is not None:
        sp.tenant_id = sp.tenant_id or tenant_id
        write_sp_tfvars(run, sp)
    elif not SP_TFVARS.exists():
        warn(
            f"{SP_TFVARS.name} does not exist, so no role assignments can be planned "
            "and the pipelines will have no access."
        )
        write_sp_tfvars(run, None)

    if not args.skip_terraform:
        ensure_capacity(run, prompt, args.capacity)
        fabric_gate(prompt, sp)
        apply_terraform(run, prompt)

    secret_delivered = False
    if not args.skip_github:
        secret_delivered = wire_github(run, prompt, sp, tenant_id)

    if not args.skip_env_file and not args.skip_terraform:
        write_dev_env(run, prompt)

    summarise(prompt, sp, tenant_id, secret_delivered, args)
    return 0


def summarise(
    prompt: Prompter,
    sp: ServicePrincipal | None,
    tenant_id: str | None,
    secret_delivered: bool,
    args: argparse.Namespace,
) -> None:
    step("Done")

    if sp is not None:
        info(f"Service principal : {sp.display_name} ({sp.client_id})")
        info(f"Object id         : {sp.object_id}")
        info("Role              : Contributor on ci, accept and prod")

    if sp is not None and sp.secret and not secret_delivered:
        # It exists only in this process. Losing it means resetting the
        # credential, so it has to be shown before we exit.
        print(
            "\n  The client secret was not written to GitHub, and this is the only\n"
            "  place it exists. Copy it now - it cannot be retrieved later.\n"
        )
        if prompt.confirm("  Print the client secret?", default=True):
            print(f"\n    DBT_SP_TENANT_ID   = {tenant_id}")
            print(f"    DBT_SP_CLIENT_ID   = {sp.client_id}")
            print(f"    DBT_SP_CLIENT_SECRET = {sp.secret}\n")
        else:
            info("Reset it later with: az ad app credential reset --id %s --append" % (sp.client_id or ""))

    print(
        "\n  Next:\n"
        "    terraform -chdir=infra output lakehouse_sql_endpoints   # wait for Active\n"
        "    dbt debug --target dev\n"
        "\n  SQL analytics endpoints and freshly written lakehouse tables both appear a\n"
        "  minute or two after the apply returns. A first dbt run that fails on missing\n"
        "  sources usually just needs re-running.\n"
    )
    if args.dry_run:
        warn("This was a dry run. Nothing was created, applied or written.")


if __name__ == "__main__":
    raise SystemExit(main())
