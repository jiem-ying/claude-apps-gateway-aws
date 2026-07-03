#!/usr/bin/env python3
"""Dummy weather MCP server — a demo tool for the Claude Apps Gateway RBAC example.

Exposes ONE tool, ``get_weather(city)``, returning canned, deterministic data (no
network calls) so a demo is reproducible. The point of this server is not the
weather — it's to have a real, named MCP tool (``mcp__weather__get_weather``) that
the gateway's group policy can allow for one team and deny for another.

Run it as a stdio MCP server. Register it locally on each laptop (see .mcp.json /
README.md); the gateway does NOT distribute MCP servers — it only gates access to
them per group.

Requires the official MCP SDK:  pip install "mcp[cli]>=1.2.0"
"""

from mcp.server.fastmcp import FastMCP

mcp = FastMCP("weather")

# Canned "forecasts" so the tool is deterministic for a demo. Any unknown city
# falls back to a fixed default rather than calling out to the network.
_CANNED = {
    "sydney": {"tempC": 22, "summary": "Sunny", "humidity": 55},
    "seattle": {"tempC": 12, "summary": "Rain", "humidity": 88},
    "singapore": {"tempC": 31, "summary": "Thunderstorms", "humidity": 80},
    "london": {"tempC": 9, "summary": "Overcast", "humidity": 77},
}
_DEFAULT = {"tempC": 20, "summary": "Clear", "humidity": 60}


@mcp.tool()
def get_weather(city: str) -> dict:
    """Return the (dummy) current weather for a city.

    Args:
        city: City name, e.g. "Sydney". Case-insensitive.

    Returns:
        A dict with city, tempC, summary, humidity. Deterministic canned data.
    """
    data = _CANNED.get(city.strip().lower(), _DEFAULT)
    return {"city": city, **data, "source": "dummy-weather-mcp"}


if __name__ == "__main__":
    # Default stdio transport — what Claude Code launches via the .mcp.json command.
    mcp.run()
