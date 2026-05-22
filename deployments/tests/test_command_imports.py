"""
Smoke-tests that every bicep-deploy command can be loaded without ImportError.

The original motivation: `bicep-deploy verify` shipped with
`from src.validate_deploy import ...` but the module lives at top-level
`validate_deploy`, so the very first customer run raised ModuleNotFoundError.

These tests reproduce the import paths exercised by each Typer command's
function body so a broken import surfaces in CI rather than at customer
runtime. They are pure import checks; no Azure CLI is invoked.
"""

import importlib


def test_bicep_deploy_module_loads():
    importlib.import_module("bicep_deploy")


def test_deploy_command_imports_resolve():
    # Mirrors the function-body imports in bicep_deploy.deploy()
    importlib.import_module("src.cleanup")
    importlib.import_module("src.cloud_init")
    importlib.import_module("src.deployment")
    importlib.import_module("src.monitor")
    importlib.import_module("src.orchestrator")
    importlib.import_module("src.resource_groups")
    importlib.import_module("src.utils")


def test_verify_command_imports_resolve():
    # Mirrors the function-body imports in bicep_deploy.verify()
    importlib.import_module("src.resource_groups")
    validate = importlib.import_module("validate_deploy")
    assert hasattr(validate, "validate_deployment")
    assert hasattr(validate, "load_connection_info_from_scenario")


def test_cleanup_command_imports_resolve():
    importlib.import_module("src.cleanup")
    importlib.import_module("src.resource_groups")


def test_cloud_init_module_surface():
    cloud_init = importlib.import_module("src.cloud_init")
    assert hasattr(cloud_init, "wait_for_cloud_init")
    assert hasattr(cloud_init, "wait_for_cloud_init_on_vmss")
    assert hasattr(cloud_init, "find_vmss_in_resource_group")
