#!/bin/sh
# Runs a local Factorio server with RCON (RCON only works in server mode).
# Then in the game: Multiplayer > Connect to address > 127.0.0.1:34198
#
#   ./start-server.sh                 # continue (or create) .server/saves/claude.zip
#   ./start-server.sh "My save"       # copy a save from your normal saves folder and play it
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
SRV="$DIR/.server"
FACTORIO="$HOME/Library/Application Support/Steam/steamapps/common/Factorio/factorio.app/Contents/MacOS/factorio"
USER_SAVES="$HOME/Library/Application Support/factorio/saves"
PW=$(python3 -c "import json;print(json.load(open('$DIR/.mcp.json'))['mcpServers']['factorio']['env']['FACTORIO_RCON_PASSWORD'])")
SAVE="$SRV/saves/claude.zip"

# Separate write-data dir so the server doesn't clash with the running game client.
mkdir -p "$SRV/config" "$SRV/mods" "$SRV/saves"
printf '[path]\nread-data=__PATH__executable__/../data\nwrite-data=%s\n' "$SRV" > "$SRV/config/config.ini"
ln -sfn "$DIR/mod/claude-bridge" "$SRV/mods/claude-bridge"
printf '{"mods":[{"name":"base","enabled":true},{"name":"claude-bridge","enabled":true}]}\n' > "$SRV/mods/mod-list.json"
python3 - "$FACTORIO" "$SRV/server-settings.json" <<'PY'
import json, os, sys
example = os.path.join(os.path.dirname(sys.argv[1]), "..", "data", "server-settings.example.json")
s = json.load(open(example))
s.update(name="claude", description="Factorio x Claude", visibility={"public": False, "lan": True},
         require_user_verification=False, auto_pause=True, autosave_interval=5)
json.dump(s, open(sys.argv[2], "w"), indent=2)
PY

if [ -n "$1" ]; then
  SRC="$USER_SAVES/${1%.zip}.zip"
  [ -f "$SRC" ] || { echo "Ni savea: $SRC"; ls "$USER_SAVES"; exit 1; }
  cp "$SRC" "$SAVE"
  echo "Kopiral $SRC"
fi
if [ ! -f "$SAVE" ]; then
  echo "Ustvarjam nov zemljevid..."
  "$FACTORIO" -c "$SRV/config/config.ini" --create "$SAVE" > /dev/null
fi

echo "Strežnik teče. V igri: Multiplayer > Connect to address > 127.0.0.1:34198   (Ctrl+C ustavi in shrani)"
exec "$FACTORIO" -c "$SRV/config/config.ini" --start-server "$SAVE" \
  --server-settings "$SRV/server-settings.json" --port 34198 \
  --rcon-port 27015 --rcon-password "$PW"
