# Agent Framework to Agent 365: notebook walkthroughs

These Python notebooks take you from a basic conversational agent to an agent with its own Microsoft Entra identity, authenticated tools, and Agent 365 activity telemetry.

**Agent Framework runs the agent. Agent 365 adds enterprise identity, registration, governance, and observability.** Creating an Agent Framework `Agent` does not automatically register it with Agent 365 or deploy it to Azure.

## Which notebook should I open?

| Notebook | What it walks you through | What you finish with |
| --- | --- | --- |
| [01 - Create an agent](01_create_agent.ipynb) | Connect to an existing Microsoft Foundry model using your Azure CLI sign-in, create a `LearningAssistant`, send prompts, and keep conversation history in a session. | A locally running agent. Model calls use **your user identity**, not a new agent identity. |
| [02 - Provision an agent identity](02_provision_agent_identity.ipynb) | Use interactive Microsoft Graph sign-in and explicit REST requests to create or reuse an agent identity blueprint, its service principal, and a child agent identity. Read them back to verify their relationships. | Real Entra identity objects and IDs to reuse in later notebooks. No runtime credential or Agent 365 registration yet. |
| [03a - Authenticate locally with a client secret](03a_agent_identity_client_secret.ipynb) | Authenticate the blueprint with a short-lived secret. Configure Graph delegated permissions, consent, and scope inheritance; authorize the notebook's user sign-in client; then give the agent two tools: read your Graph profile on your behalf and read a sample Blob as itself. | A local agent demonstrating **delegated OBO** and **app-only** access with the same child identity. |
| [03b - Authenticate on Azure with managed identity](03b_agent_identity_managed_identity.ipynb) | Run the same two-tool example on an Azure host, replacing the blueprint secret with a user-assigned managed identity and federated trust. | The same agent-identity authorization without a blueprint secret. You supply the Azure host and attached managed identity; the notebook does not deploy them. |
| [04 - Register with Agent 365 and send activity traces](04_agent365_registration_observability.ipynb) | Register the existing child identity, acquire its app-only Observability API token, configure OpenTelemetry, and send a smoke-test activity. Optionally trace a real model call and link the identity as a Foundry External Agent. | An Agent 365 registration and an activity-trace export you can verify. This does not deploy an agent endpoint or publish a Foundry hosted agent. |

## Recommended order

```text
01  Build and call the agent
 |
02  Create its Entra identity
 |
 +-- 03a  Local development: blueprint client secret
 |        OR
 +-- 03b  Azure host: managed identity + federation
 |
04  Agent 365 registration and observability
```

**03a and 03b are alternatives, not consecutive requirements.** Start with 03a if you are working on your laptop. Choose 03b if you already have a suitable Azure host with a user-assigned managed identity attached.

If you only want registration and telemetry, complete 02 and the **blueprint credential setup** in either 03a or 03b, then move to 04. You do not need the Graph OBO, user-login, or Blob tool sections for telemetry. Notebook 04's smoke test also does not need a model call.

## Before you start

- Python 3.10 or later; the environment commands below use Python 3.12.
- VS Code with Python/Jupyter support and a notebook kernel.
- `uv` and the Azure CLI.
- An existing Microsoft Foundry project and a model deployment supporting the Responses API. You need its project endpoint, deployment name, and permission to call it, normally **Azure AI User** at the appropriate scope.
- For 02 onward: a work/school tenant with Entra Agent ID available, a dedicated provisioning app registration, and the required delegated Graph consent and user roles. Notebook 02 explains these and includes a bootstrap-script option.
- For the tools in 03a/03b: a Blob container with a non-sensitive sample guide, permission to assign its Blob reader role, and the Graph setup described in the notebook.
- For 04: Agent 365 tenant eligibility, required licensing/preview access, accepted terms, and the additional provisioning-app permissions documented there.

You do not need to configure every later prerequisite just to try notebook 01.

### Set up your local environment

Run from the repository directory in PowerShell:

```powershell
uv venv .venv --python 3.12
uv pip install --python .venv\Scripts\python.exe --index-url https://packagefeedproxy.microsoft.io/pypi/simple -r requirements.txt
az login
```

The install command uses the Microsoft package proxy for managed devices.

Create a local `.env` file with your initial model configuration:

```dotenv
FOUNDRY_PROJECT_ENDPOINT=https://YOUR-RESOURCE.services.ai.azure.com/api/projects/YOUR-PROJECT
FOUNDRY_MODEL=YOUR-DEPLOYMENT-NAME
```

`FOUNDRY_MODEL` is your **deployment name**, not necessarily the underlying model name. Later notebooks explain the additional `.env` settings they require; reuse the identities from 02 rather than creating replacements for each lesson.

Open [notebook 01](01_create_agent.ipynb), select the repository's `.venv` under **Select Kernel > Python Environments**, and run the cells in order with the repository as the working directory. Restart the kernel after changing dependencies or configuration. Existing environment variables take precedence over `.env`.

**Start notebook 04 with a fresh kernel.** Its OpenTelemetry setup must run before importing Agent Framework or the model SDK.

## Understand the identities

| Identity | Its job |
| --- | --- |
| Your provisioning user and provisioning app | Perform administrative Graph setup. These are not the runtime agent identity. |
| Agent identity blueprint | Defines the agent type and holds its runtime credential or federated trust. Its application/client ID and directory object ID are different values. |
| Blueprint principal | Represents that blueprint in your tenant. Notebook 02 creates or reuses it explicitly. |
| Child agent identity | Represents the individual agent instance and receives its resource access. Use this identity for Blob RBAC and telemetry attribution, not the blueprint. |
| Notebook user sign-in client in 03a/03b | Obtains the incoming user token for OBO. It is an OAuth client, not a separate frontend you need to build or deploy. |
| Azure host managed identity in 03b | Authenticates the blueprint through federation. It does not replace the child agent identity seen by Blob Storage. |

In 03a/03b, **model calls still use your Azure CLI sign-in**. The tools demonstrate the agent identity: Graph `/me` uses the child identity plus your user context (OBO), while Blob reads use the child identity alone (app-only). Graph permissions, Blob RBAC, and Foundry access are separate grants.

## Changes, costs, and sensitive data

These are executable walkthroughs, not simulations. Notebook 02 creates real directory objects; 03a/03b can change directory configuration when you confirm their setup cells; 04 can create a registration and export telemetry. Read each confirmation before proceeding. Closing a notebook's clients does not delete the provisioned objects.

Model calls may incur Azure charges. In 03a/03b, profile details and guide text are sent to your configured model, so use your own profile and a non-sensitive sample guide.

Keep secrets, tokens, and local state out of commits, screenshots, and shared folders. `.env`, `.agent-identity-state.json`, and `.agent365-registration.json` are ignored by Git. Preserve registration state when retrying an ambiguous failure rather than deleting it to force another registration.

Notebook 04 defaults to `A365_CAPTURE_CONTENT=false`; enabling it exports prompt/tool/response content. Its registration step uses an **undocumented preview Graph API**, so tenant access and the API contract can change. Follow the notebook's permission and verification instructions rather than treating an HTTP export success as proof that activity is visible.

## Supporting files

- [requirements.txt](requirements.txt): shared Python dependencies.
- [New-AgentIdentityProvisioningClient.ps1](New-AgentIdentityProvisioningClient.ps1): creates or reuses notebook 02's interactive provisioning app. Admin consent is a separate, explicit step.
- [agent-guide.txt](agent-guide.txt): sample guide content for the Blob tool example.
- [Sandbox agent identity architecture](docs/sandbox-agent-identities.md): a separate design note about identity isolation for Azure Container Apps Sandboxes, not another runnable notebook.
- [my-agent-z689vi](my-agent-z689vi/README.md): a separate agent project with its own README, not a prerequisite for the root notebook sequence.
