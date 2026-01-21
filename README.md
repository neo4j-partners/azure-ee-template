# Neo4j Enterprise Edition - Azure Deployment Template

Azure Bicep templates for deploying Neo4j Enterprise Edition on Azure VM Scale Sets.

## Features

- **Standalone or Cluster**: Deploy 1 node (standalone) or 3-10 nodes (cluster)
- **Neo4j 2025.x**: Latest Neo4j Enterprise (2025.12+) with APOC plugin
- **Load Balancer**: Automatic load balancer for clusters (3+ nodes)
- **Cloud-init**: VM provisioning via cloud-init (no custom script extensions)
- **Security**: NSG with proper port configuration, SSRF protection

## Prerequisites

- Azure CLI installed and logged in (`az login`)
- Bicep CLI (included with Azure CLI 2.20+)
- [uv](https://docs.astral.sh/uv/) package manager
- Python 3.12+

## Quick Start

```bash
# Navigate to deployments directory
cd deployments

# Install dependencies
uv sync

# Run interactive setup wizard
uv run neo4j-deploy setup

# Deploy standalone Neo4j
uv run neo4j-deploy deploy --scenario standalone-v2025

# Deploy 3-node cluster
uv run neo4j-deploy deploy --scenario cluster-v2025

# Check deployment status
uv run neo4j-deploy status

# Test the deployment
uv run neo4j-deploy test

# Clean up resources
uv run neo4j-deploy cleanup --all --force
```

## Commands

| Command | Description |
|---------|-------------|
| `setup` | Interactive setup wizard for configuration |
| `validate` | Validate Bicep templates without deploying |
| `deploy` | Deploy one or more scenarios to Azure |
| `test` | Test deployment connectivity and license |
| `status` | Show deployment status |
| `cleanup` | Delete Azure resources |
| `report` | Generate test report for deployments |

## Configuration

After running `uv run neo4j-deploy setup`, configuration files are created in `deployments/.arm-testing/config/`:

- `settings.yaml` - Main settings (Azure subscription, regions, cleanup modes)
- `scenarios.yaml` - Test scenario definitions

### Default Scenarios

The setup wizard creates two default scenarios:

1. **standalone-v2025** - Single-node Neo4j 2025 deployment
2. **cluster-v2025** - 3-node Neo4j 2025 cluster

You can modify `scenarios.yaml` to add custom scenarios.

## Template Parameters

| Parameter | Description | Default |
|-----------|-------------|---------|
| `adminUsername` | SSH username | `neo4j` |
| `adminPassword` | Neo4j admin password | (required) |
| `vmSize` | Azure VM size | `Standard_D2s_v5` |
| `nodeCount` | Number of nodes (1, 3-10) | `1` |
| `diskSize` | Data disk size in GB | `32` |
| `graphDatabaseVersion` | Neo4j version | `2025` |
| `licenseType` | `Enterprise` or `Evaluation` | `Evaluation` |
| `location` | Azure region | Resource group location |

> **Note:** Neo4j 2025.x requires Java 21 or later. The VM image includes the required Java version.

## Environment Variables

Configure these in your `.env` file:

| Variable | Description | Default |
|----------|-------------|---------|
| `NEO4J_ADMIN_PASSWORD` | Neo4j admin password | Auto-generated |
| `AZURE_LOCATION` | Azure region | `eastus` |
| `NEO4J_NODE_COUNT` | Number of nodes (1, 3-10) | `1` |
| `NEO4J_VM_SIZE` | Azure VM size | `Standard_D2s_v5` |
| `NEO4J_DISK_SIZE` | Data disk size in GB | `32` |
| `NEO4J_VERSION` | Neo4j version | `2025` |
| `NEO4J_LICENSE_TYPE` | `Enterprise` or `Evaluation` | `Evaluation` |

## Cleanup Modes

| Mode | Description |
|------|-------------|
| `immediate` | Delete resources immediately after deployment |
| `on-success` | Delete only if tests pass (keep failures for debugging) |
| `manual` | Never auto-delete (requires explicit cleanup) |
| `scheduled` | Tag resources to expire after N hours |

## Password Management

Three password strategies are available:

1. **Generate** (default) - Random secure password per deployment
2. **Environment** - Read from `NEO4J_ADMIN_PASSWORD` environment variable
3. **Prompt** - Interactive prompt each time

## Ports

| Port | Protocol | Description |
|------|----------|-------------|
| 22 | TCP | SSH |
| 7473 | TCP | HTTPS (Neo4j Browser) |
| 7474 | TCP | HTTP (Neo4j Browser) |
| 7687 | TCP | Bolt (Neo4j Driver) |
| 7688 | TCP | Bolt Routing (Cluster) |
| 6000 | TCP | Cluster Communication |
| 7000 | TCP | Raft Consensus |

## Manual Deployment (Azure CLI)

For deployments without the framework:

### Deploy Standalone (1 node)

```bash
az group create --name neo4j-standalone-rg --location eastus

az deployment group create \
  --resource-group neo4j-standalone-rg \
  --template-file infra/main.bicep \
  --parameters @infra/parameters.json \
  --parameters adminPassword="YourSecurePassword123!"
```

### Deploy Cluster (3+ nodes)

```bash
az group create --name neo4j-cluster-rg --location eastus

az deployment group create \
  --resource-group neo4j-cluster-rg \
  --template-file infra/main.bicep \
  --parameters @infra/parameters.json \
  --parameters nodeCount=3 adminPassword="YourSecurePassword123!" licenseType="Enterprise"
```

### Cleanup

```bash
az group delete --name <resource-group-name> --yes --no-wait
```

## Project Structure

```
azure-ee-template/
├── infra/                  # Azure infrastructure (Bicep templates)
│   ├── main.bicep          # Main orchestrator template
│   ├── modules/
│   │   ├── network.bicep       # VNet, Subnet, NSG
│   │   ├── identity.bicep      # Managed Identity
│   │   ├── loadbalancer.bicep  # Load Balancer (conditional)
│   │   └── vmss.bicep          # VM Scale Set
│   ├── cloud-init/
│   │   ├── standalone.yaml     # Single-node configuration
│   │   └── cluster.yaml        # Multi-node cluster configuration
│   ├── bicepconfig.json    # Bicep linter rules
│   └── parameters.json     # Sample parameters
├── deployments/            # Deployment automation tools
│   ├── neo4j_deploy.py     # Main CLI entry point
│   ├── pyproject.toml      # Package configuration
│   └── src/                # Source modules
├── .env.sample             # Sample environment variables
├── AUTH.md                 # Authentication guide (OIDC, SSO, M2M)
└── FIX.md                  # Implementation notes
```

## Outputs

After deployment, you'll receive:

- `Neo4jBrowserURL`: URL to access Neo4j Browser
- `Neo4jClusterBrowserURL`: Load balancer URL (clusters only)
- `Username`: Default username (`neo4j`)

## Authentication

For advanced authentication options including OIDC, SSO, and machine-to-machine (M2M) bearer tokens, see [AUTH.md](AUTH.md).

### M2M Bearer Token Authentication

The setup wizard includes an optional step to configure M2M (Machine-to-Machine) authentication using Microsoft Entra ID (Azure AD). This allows services, APIs, and automated processes to connect to Neo4j using OAuth 2.0 bearer tokens.

```bash
# Run setup wizard (includes optional M2M configuration)
uv run neo4j-deploy setup
```

During setup, you'll be asked:
1. **Would you like to configure M2M bearer token authentication?** - Choose yes to enable
2. **Automatic or Manual setup?** - Automatic uses Azure CLI to create Entra ID apps

#### What the Automatic Setup Does

The wizard uses Azure CLI (`az`) commands to:

1. **Detect your Azure tenant** - Auto-detects tenant ID from your current `az login` session
2. **Create an API app registration** - Represents Neo4j as an API resource with app roles:
   - `Neo4j.Admin` - Full administrative access
   - `Neo4j.ReadWrite` - Read and write data access
   - `Neo4j.ReadOnly` - Read-only access
3. **Create a client app registration** - For your service to authenticate
4. **Generate a client secret** - For the client app (saved securely, shown once)
5. **Grant API permissions** - Assigns the appropriate role to the client app

#### After Setup

The M2M configuration is automatically included in deployments. Your services can authenticate using:

```python
from msal import ConfidentialClientApplication
from neo4j import GraphDatabase, bearer_auth

# Get token from Entra ID
app = ConfidentialClientApplication(
    CLIENT_ID,
    authority=f"https://login.microsoftonline.com/{TENANT_ID}",
    client_credential=CLIENT_SECRET,
)
result = app.acquire_token_for_client(scopes=["api://neo4j-m2m/.default"])

# Connect to Neo4j with bearer token
driver = GraphDatabase.driver(NEO4J_URI, auth=bearer_auth(result["access_token"]))
```

For detailed M2M configuration guides, see:
- [M2M.md](M2M.md) - Comprehensive M2M setup guide
- [M2M_v2.md](M2M_v2.md) - Quick guide specific to this deployment

#### Validating Bearer Token Authentication

After deployment, validate M2M authentication works:

```bash
# Set your client secret (from setup wizard)
export NEO4J_CLIENT_SECRET="your-client-secret"

# Run validation
cd validate-bearer-token
uv run validate_bearer.py --scenario standalone-v2025
```

The validation script will:
1. Load deployment config from `.deployments/standalone-v2025.json`
2. Acquire a bearer token from Entra ID
3. Test Neo4j connection with the token
4. Display the authenticated user's roles

## License

Neo4j Enterprise Edition requires a valid license. Use `licenseType=Evaluation` for a 30-day trial.
