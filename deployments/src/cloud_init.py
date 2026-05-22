"""
Poll cloud-init status on a freshly-provisioned VMSS instance.

The Bicep `deploy` command reports Succeeded the moment ARM finishes — but
ARM only tracks Azure resource provisioning, not the cloud-init script that
installs and starts Neo4j. Without the wait below, the CLI declared success
and wrote connection info while Neo4j was still being installed, which masked
real failures (e.g. transient Azure RHUI errors that left Neo4j uninstalled).
"""

import json
import subprocess
import time
from typing import Optional

from pydantic import BaseModel, Field
from rich.console import Console

from .constants import (
    CLOUD_INIT_POLL_INTERVAL_SECONDS,
    CLOUD_INIT_RUN_COMMAND_TIMEOUT_SECONDS,
    CLOUD_INIT_TIMEOUT_SECONDS,
)
from .utils import run_command

console = Console()


class CloudInitResult(BaseModel):
    """Outcome of waiting for cloud-init on a VMSS instance or scale set."""

    success: bool = Field(..., description="True iff cloud-init reported done with no failure markers")
    message: str = Field(..., description="Human-readable summary of the outcome")


def wait_for_cloud_init(
    resource_group: str,
    vmss_name: str,
    instance_id: str = "0",
    timeout_seconds: int = CLOUD_INIT_TIMEOUT_SECONDS,
) -> CloudInitResult:
    """Poll cloud-init on one VMSS instance until it reports done or fails.

    Detects:
      - cloud-init `status: done`              → success
      - /var/log/neo4j-install-failed marker   → dnf install gave up
      - /var/log/neo4j-not-ready marker        → service never opened a port
      - cloud-init `status: error`             → generic cloud-init failure
      - exceeds timeout_seconds                → timeout
    """
    deadline = time.time() + timeout_seconds
    probe_script = (
        "cloud-init status 2>&1 || true; "
        "echo '---markers---'; "
        "ls /var/log/neo4j-install-failed /var/log/neo4j-not-ready 2>/dev/null || true"
    )

    while time.time() < deadline:
        try:
            result = run_command(
                [
                    "az", "vmss", "run-command", "invoke",
                    "--resource-group", resource_group,
                    "--name", vmss_name,
                    "--instance-id", instance_id,
                    "--command-id", "RunShellScript",
                    "--scripts", probe_script,
                    "--query", "value[0].message",
                    "-o", "tsv",
                ],
                check=False,
                timeout=CLOUD_INIT_RUN_COMMAND_TIMEOUT_SECONDS,
            )
        except subprocess.TimeoutExpired:
            console.print("[yellow]  run-command timed out; retrying...[/yellow]")
            time.sleep(CLOUD_INIT_POLL_INTERVAL_SECONDS)
            continue

        if result.returncode != 0:
            console.print(
                f"[yellow]  run-command failed (exit {result.returncode}); "
                f"retrying...[/yellow]"
            )
            time.sleep(CLOUD_INIT_POLL_INTERVAL_SECONDS)
            continue

        output = result.stdout

        if "neo4j-install-failed" in output:
            return CloudInitResult(
                success=False,
                message=(
                    "cloud-init reported install failure "
                    "(see /var/log/neo4j-install-failed on the VM)"
                ),
            )
        if "neo4j-not-ready" in output:
            return CloudInitResult(
                success=False,
                message=(
                    "Neo4j did not become ready within the in-VM wait window "
                    "(see /var/log/neo4j-not-ready on the VM)"
                ),
            )
        if "status: done" in output:
            return CloudInitResult(success=True, message="cloud-init done")
        if "status: error" in output:
            return CloudInitResult(
                success=False,
                message=f"cloud-init reported error: {output.strip()}",
            )

        # status: running / not started yet — keep polling
        time.sleep(CLOUD_INIT_POLL_INTERVAL_SECONDS)

    return CloudInitResult(
        success=False,
        message=f"cloud-init did not finish within {timeout_seconds}s",
    )


def wait_for_cloud_init_on_vmss(
    resource_group: str,
    vmss_name: str,
    instance_count: int,
    timeout_seconds: int = CLOUD_INIT_TIMEOUT_SECONDS,
) -> CloudInitResult:
    """Wait for cloud-init on every instance in a VMSS.

    Instances boot in parallel, so once instance 0 is done the others are
    usually close behind. We still poll each one so a failure on any node
    surfaces — a 3-node cluster where node 2 silently failed install would
    otherwise look healthy.
    """
    for i in range(instance_count):
        console.print(f"[dim]  polling cloud-init on instance {i}/{instance_count - 1}...[/dim]")
        result = wait_for_cloud_init(
            resource_group, vmss_name, str(i), timeout_seconds=timeout_seconds
        )
        if not result.success:
            return CloudInitResult(
                success=False,
                message=f"instance {i}: {result.message}",
            )
    return CloudInitResult(
        success=True,
        message=f"cloud-init done on all {instance_count} instance(s)",
    )


def find_vmss_in_resource_group(resource_group: str) -> Optional[tuple[str, int]]:
    """Locate the single VMSS in a deployment's resource group and its capacity.

    Returns (vmss_name, capacity) or None if no VMSS is found.
    """
    try:
        result = run_command(
            [
                "az", "vmss", "list",
                "--resource-group", resource_group,
                "--query", "[0].{name:name, capacity:sku.capacity}",
                "-o", "json",
            ],
            check=False,
            timeout=60,
        )
    except subprocess.TimeoutExpired:
        return None
    if result.returncode != 0 or not result.stdout.strip():
        return None
    try:
        data = json.loads(result.stdout)
    except json.JSONDecodeError:
        return None
    if not data or not data.get("name"):
        return None
    return data["name"], int(data.get("capacity") or 1)
