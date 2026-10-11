"""End-to-end test against a headless Factorio server with no players (uses /cb_debug_spawn).

Start the server with auto_pause=false and RCON, then:
  FACTORIO_RCON_PORT=27099 FACTORIO_RCON_PASSWORD=... .venv/bin/python smoke_test.py
"""

import json

import factorio_mcp as m


def step(label, fn, *args, **kwargs):
    result = fn(*args, **kwargs)
    print(f"--- {label}\n{result[:400]}")
    return json.loads(result) if result.startswith("{") else result


def wait(label, queued):
    action = step(label, m.wait_for_action, json.loads(queued)["action"]["id"], 180)
    assert action["status"] == "done", action
    return action


m.call("debug_spawn")
step("state", m.get_state)
step("scan", m.scan_area, radius=60)
wait("mine stone", m.mine("stone", count=10))
wait("mine trees", m.mine("tree", count=2))
step("craft", m.craft, "stone-furnace", 2)
m.call("say", message="smoke test: crafting")
import time; time.sleep(2 * 0.5 / 0.5 + 1)  # stone furnace = 0.5s each

state = step("state", m.get_state)
assert state["inventory"].get("stone-furnace") == 2, state["inventory"]
x, y = round(state["position"]["x"]) + 3.0, round(state["position"]["y"])
step("place", m.place, "stone-furnace", x, y)
try:
    m.place("stone-furnace", x + 40, y)
    raise AssertionError("far placement should fail")
except m.RconError as e:
    print("--- far placement rejected:", e)
step("insert wood", m.insert_items, x, y, "wood", 2)
step("inspect", m.inspect, x, y)
step("pickup", m.pickup, x, y)
print(step("map", m.ascii_map, width=30, height=10))
print("\nALL OK")
