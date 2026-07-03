# Dummy weather MCP tool — group-RBAC demo

A tiny local MCP server exposing one tool, `get_weather(city)`, with canned data.
It exists to demonstrate **per-group tool access** enforced by the Claude Apps
Gateway: the *same* tool is installed on every laptop, but the gateway's
`managed.policies` **deny it to one team and allow it to another**.

## Why the tool is installed locally (not pushed by the gateway)

The gateway can gate **models and tool permissions**, but it **cannot distribute
MCP servers** — `mcpServers` inside a policy is rejected at gateway boot. So each
developer registers this server locally; the gateway then decides, per group,
whether their CLI is allowed to use it.

The tool's permission name (what the policy matches) is:

```
mcp__weather                 # the whole server (all its tools)
mcp__weather__get_weather    # just this one tool
```

## 1. Install the tool locally (both users do this)

```bash
pip install "mcp[cli]>=1.2.0"        # official MCP SDK (once)

# From the repo root, register the server with Claude Code:
claude mcp add weather -- python3 "$PWD/examples/weather-mcp/weather_server.py"
# …or copy the snippet in ./.mcp.json into your project/user MCP config
# (fix the path to be absolute if you run claude from elsewhere).
```

Verify it loaded: in `claude`, run `/mcp` — you should see the `weather` server and
its `get_weather` tool, then try: *"what's the weather in Sydney?"*

## 2. How the gateway gates it (the RBAC part)

The gateway is deployed with a group policy (rendered by `deploy.sh` from
`DENY_TOOL_GROUP` / `DENY_TOOLS`):

```yaml
managed:
  policies:
    - match: {groups: [partners]}                    # the restricted team
      cli: {permissions: {deny: ["mcp__weather"]}}   # tool removed from their CLI
    - match: {}                                      # everyone else (e.g. platform)
                                                     # full access — all models + tools
```

Result in this demo:

| User | Group | Weather tool | Models |
|------|-------|--------------|--------|
| `jiemying` | `platform` | ✅ available (any model) | all |
| `jpiao` | `partners` | ❌ denied (tool absent) | **all — unchanged** |

`partners` keep every model for normal work; only the weather tool is withheld.

## 3. Making a change take effect

- **Policy edit** (e.g. change which group/tool) → **redeploy the gateway** (the
  config lives in the ECS task-def) and it reaches logged-in CLIs on their next
  managed-settings poll (~hourly).
- **Group membership change** (assigning `jpiao` to `partners`) → the user must
  **`/logout` then `/login`** to mint a fresh token carrying the new
  `cognito:groups` claim (this Cognito client issues no refresh token).

See [`../../docs/CONFIG.md`](../../docs/CONFIG.md) → *Group-based policy* for the
full flow, and [`../../idp/README.md`](../../idp/README.md) for creating groups and
assigning users.
