"""MCP server that lets Claude play Factorio through the claude-bridge mod over RCON."""

from __future__ import annotations

import json
import os
import socket
import struct
import threading
import time
from typing import Any

from mcp.server.mcpserver import MCPServer

RCON_HOST = os.environ.get("FACTORIO_RCON_HOST", "127.0.0.1")
RCON_PORT = int(os.environ.get("FACTORIO_RCON_PORT", "27015"))
RCON_PASSWORD = os.environ.get("FACTORIO_RCON_PASSWORD", "")


class RconError(Exception):
    pass


class Rcon:
    """Minimal Source RCON client (the protocol Factorio speaks)."""

    AUTH, EXEC, AUTH_RESPONSE, RESPONSE = 3, 2, 2, 0

    def __init__(self, host: str, port: int, password: str) -> None:
        self.host, self.port, self.password = host, port, password
        self.sock: socket.socket | None = None
        self.next_id = 1
        self.lock = threading.Lock()

    def _send(self, kind: int, body: str) -> int:
        req_id = self.next_id
        self.next_id += 1
        payload = struct.pack("<ii", req_id, kind) + body.encode("utf-8") + b"\x00\x00"
        self.sock.sendall(struct.pack("<i", len(payload)) + payload)
        return req_id

    def _recv_exact(self, n: int) -> bytes:
        buf = b""
        while len(buf) < n:
            chunk = self.sock.recv(n - len(buf))
            if not chunk:
                raise ConnectionError("RCON connection closed")
            buf += chunk
        return buf

    def _recv(self) -> tuple[int, int, str]:
        (size,) = struct.unpack("<i", self._recv_exact(4))
        data = self._recv_exact(size)
        req_id, kind = struct.unpack("<ii", data[:8])
        return req_id, kind, data[8:-2].decode("utf-8", errors="replace")

    def connect(self) -> None:
        self.close()
        try:
            self.sock = socket.create_connection((self.host, self.port), timeout=10)
        except OSError as e:
            raise RconError(
                f"Cannot reach Factorio RCON at {self.host}:{self.port} ({e}). Is the game running with "
                "--rcon-port/--rcon-password and hosting a multiplayer game (Multiplayer -> Host)?"
            ) from e
        req_id = self._send(self.AUTH, self.password)
        while True:
            got_id, kind, _ = self._recv()
            if kind == self.AUTH_RESPONSE:
                if got_id == -1:
                    self.close()
                    raise RconError("RCON authentication failed: wrong FACTORIO_RCON_PASSWORD")
                if got_id == req_id:
                    return

    def close(self) -> None:
        if self.sock:
            try:
                self.sock.close()
            except OSError:
                pass
        self.sock = None

    def command(self, cmd: str) -> str:
        with self.lock:
            for attempt in range(2):
                try:
                    if self.sock is None:
                        self.connect()
                    req_id = self._send(self.EXEC, cmd)
                    while True:
                        got_id, _, body = self._recv()
                        if got_id == req_id:
                            return body
                except (OSError, ConnectionError):
                    self.close()
                    if attempt == 1:
                        raise RconError("Lost RCON connection to Factorio")
        raise RconError("unreachable")


rcon = Rcon(RCON_HOST, RCON_PORT, RCON_PASSWORD)
mcp = MCPServer(
    "factorio",
    instructions=(
        "Tools to play Factorio as the human player's character, following normal game rules. "
        "Coordinates are map tiles (x east, y south). Start with get_state and scan_area/ascii_map to orient. "
        "walk_to and mine are asynchronous: they return an action id; use wait_for_action to block until done. "
        "Building, inserting and taking require being within reach, so walk close first. "
        "Use say to tell the player in game chat what you are doing."
    ),
)


def call(command: str, /, **args: Any) -> dict:
    """Run /cb_<name> with JSON args and return the decoded reply, raising on errors."""
    args = {k: v for k, v in args.items() if v is not None}
    raw = rcon.command(f"/cb_{command} {json.dumps(args)}" if args else f"/cb_{command}")
    if not raw.strip():
        raise RconError(
            f"Empty reply to /cb_{command}. Is the claude-bridge mod enabled in this save?"
        )
    try:
        reply = json.loads(raw)
    except json.JSONDecodeError:
        raise RconError(f"Unexpected reply from Factorio: {raw[:500]}")
    if not reply.pop("ok", False):
        raise RconError(reply.get("error", raw))
    return reply


def out(data: dict) -> str:
    return json.dumps(data, separators=(",", ":"))


# --- Reading -----------------------------------------------------------------


@mcp.tool()
def get_state() -> str:
    """Player position, health, reach, inventory, crafting queue, research and current action."""
    return out(call("state"))


@mcp.tool()
def scan_area(radius: int = 30, x: float | None = None, y: float | None = None, limit: int = 150) -> str:
    """List buildings, resource patches (with bounds and amounts), trees and rocks around the player
    (or around x,y). radius max 200."""
    return out(call("scan", radius=radius, x=x, y=y, limit=limit))


@mcp.tool()
def ascii_map(x: float | None = None, y: float | None = None, width: int = 40, height: int = 30) -> str:
    """Tile-accurate ASCII map centered on the player (or x,y), max 80x80. Useful for planning layouts."""
    data = call("map", x=x, y=y, width=width, height=height)
    legend = ", ".join(f"{k}={v}" for k, v in sorted(data["legend"].items()))
    return f"{data['note']}\nlegend: {legend}\n" + "\n".join(data["rows"])


@mcp.tool()
def find_nearest(name: str | None = None, type: str | None = None, radius: int = 200, count: int = 1) -> str:
    """Find nearest entities by prototype name (e.g. 'iron-ore', 'stone-furnace') or type (e.g. 'tree')."""
    return out(call("find", name=name, type=type, radius=radius, count=count))


@mcp.tool()
def inspect(x: float, y: float, entity: str | None = None) -> str:
    """Details of the entity at x,y: inventories, fuel, recipe, status, progress, belt contents."""
    return out(call("inspect", x=x, y=y, entity=entity))


@mcp.tool()
def recipe(name: str) -> str:
    """Recipes producing an item: ingredients, products, crafting time and how many you can hand-craft now."""
    return out(call("recipe", name=name))


@mcp.tool()
def research_options() -> str:
    """Technologies whose prerequisites are done (trigger techs list what unlocks them)."""
    return out(call("research_options"))


# --- Actions -----------------------------------------------------------------


@mcp.tool()
def walk_to(x: float, y: float, radius: float = 0.5) -> str:
    """Walk the character to x,y with the pathfinder (async). Returns an action; use wait_for_action."""
    return out(call("walk_to", x=x, y=y, radius=radius))


@mcp.tool()
def mine(name: str, count: int = 1, x: float | None = None, y: float | None = None) -> str:
    """Mine by hand at real speed, walking to the nearest target automatically (async).
    name: a resource ('iron-ore', 'copper-ore', 'coal', 'stone'), 'tree', 'rock', or an entity name.
    count: items for resources, number of entities for trees/rocks. Optional x,y picks a specific target first."""
    return out(call("mine", name=name, count=count, x=x, y=y))


@mcp.tool()
def wait_for_action(action_id: int, timeout_seconds: float = 120) -> str:
    """Block until an async action finishes (or timeout) and return its final status."""
    deadline = time.monotonic() + timeout_seconds
    while True:
        action = call("action_status", id=action_id)["action"]
        if action["status"] not in ("queued", "running"):
            return out(action)
        if time.monotonic() > deadline:
            action["note"] = "still running; call wait_for_action again or cancel_actions"
            return out(action)
        time.sleep(0.5)


@mcp.tool()
def action_status(action_id: int) -> str:
    """Current status of an async action without waiting."""
    return out(call("action_status", id=action_id))


@mcp.tool()
def cancel_actions() -> str:
    """Stop the running action and clear queued ones."""
    return out(call("cancel"))


@mcp.tool()
def craft(recipe: str, count: int = 1) -> str:
    """Add a hand-crafting job to the player's crafting queue (uses inventory ingredients)."""
    return out(call("craft", recipe=recipe, count=count))


@mcp.tool()
def place(name: str, x: float, y: float, direction: str = "north", underground_type: str | None = None) -> str:
    """Place a building from inventory at x,y (must be within build distance).
    direction: north/east/south/west (belts/inserters face/move that way). underground_type: input/output."""
    return out(call("place", name=name, x=x, y=y, direction=direction, underground_type=underground_type))


@mcp.tool()
def pickup(x: float, y: float, entity: str | None = None) -> str:
    """Pick a building back up into the inventory (must be in reach)."""
    return out(call("pickup", x=x, y=y, entity=entity))


@mcp.tool()
def insert_items(x: float, y: float, item: str, count: int | None = None, entity: str | None = None) -> str:
    """Put items from inventory into an entity (fuel, ore into furnaces, ingredients, ammo...). Must be in reach."""
    return out(call("insert", x=x, y=y, item=item, count=count, entity=entity))


@mcp.tool()
def take_items(x: float, y: float, item: str | None = None, count: int | None = None, entity: str | None = None) -> str:
    """Take items out of an entity into inventory (all items if item omitted). Must be in reach."""
    return out(call("take", x=x, y=y, item=item, count=count, entity=entity))


@mcp.tool()
def set_recipe(x: float, y: float, recipe: str, entity: str | None = None) -> str:
    """Set the recipe of an assembling machine/chemical plant at x,y."""
    return out(call("set_recipe", x=x, y=y, recipe=recipe, entity=entity))


@mcp.tool()
def rotate(x: float, y: float, reverse: bool = False, entity: str | None = None) -> str:
    """Rotate the entity at x,y clockwise (or counter-clockwise with reverse)."""
    return out(call("rotate", x=x, y=y, reverse=reverse, entity=entity))


@mcp.tool()
def start_research(name: str) -> str:
    """Add a technology to the research queue."""
    return out(call("research", name=name))


@mcp.tool()
def say(message: str) -> str:
    """Print a message in the in-game chat so the player sees what Claude is doing."""
    call("say", message=message)
    return "ok"


if __name__ == "__main__":
    mcp.run()
