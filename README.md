# Factorio × Claude

Igraj Factorio s prompti. Claude upravlja tvoj lik po pravilih igre: hodi s pathfindingom, rudari s hitrostjo roke, gradi samo iz inventarja in znotraj dosega.

```
Claude Code ──MCP──> server/factorio_mcp.py ──RCON :27015──> Factorio + mod claude-bridge
```

## Zagon
0. `cp .mcp.example.json .mcp.json`, vpiši svoje RCON geslo in namesti odvisnosti:
   `python3 -m venv server/.venv && server/.venv/bin/pip install -r server/requirements.txt`
RCON deluje samo v strežniškem načinu, zato igraš na lokalnem strežniku.
1. V terminalu zaženi `./start-server.sh` (nov zemljevid) ali `./start-server.sh "ime savea"` (kopija tvojega savea).
   Terminal pusti odprt. Ctrl+C ustavi strežnik in shrani igro v `.server/saves/claude.zip`.
2. Zaženi Factorio iz Steama in izberi **Multiplayer → Connect to address → `127.0.0.1:34198`**.
3. Odpri Claude Code v tej mapi (`~/Developer/factorio-claude`) in odobri MCP strežnik `factorio`.
4. Piši npr. *"poglej okolico in nakoplji 20 železa"* ali *"postavi kurilni rudnik na premog in ga napolni"*.

Hiter test v igri (konzola, tipka `~`): `/cb_state`.

## Orodja
`get_state`, `scan_area`, `ascii_map`, `find_nearest`, `inspect`, `recipe`, `research_options`,
`walk_to`*, `mine`*, `wait_for_action`, `action_status`, `cancel_actions`,
`craft`, `place`, `pickup`, `insert_items`, `take_items`, `set_recipe`, `rotate`, `start_research`, `say`.

\* asinhrono: vrne id akcije. Akcije se izvajajo zaporedno.

## Test brez igre
`server/smoke_test.py` preveri celoten tok na headless strežniku brez igralca: hoja, rudarjenje, izdelovanje, gradnja.
Pri tem uporabi ukaz `/cb_debug_spawn`, ki ustvari testni lik.

## Opombe
- Med hojo ne pritiskaj WASD, ker se boš boril s Claudom za lik. `cancel_actions` ustavi vse akcije.
- Z vklopljenim modom Factorio dosežke vodi ločeno (modded) in jih **ne pošlje v Steam**.
- Lua napake najdeš v `~/Library/Application Support/factorio/factorio-current.log`.
- Mod je s symlinkom povezan v `~/Library/Application Support/factorio/mods/claude-bridge`.
