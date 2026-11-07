#!/usr/bin/env bash
#
# coden v GitHub Codespace — instalace a spuštění Serveru.
#
# Volá ho `.devcontainer/coden/devcontainer.json`, který do repozitáře zapsala aplikace
# coden, když uživatel z telefonu zakládal Codespace:
#
#     postCreateCommand:  curl -fsSL https://coden-app.com/codespace.sh | bash -s install
#     postStartCommand:   curl -fsSL https://coden-app.com/codespace.sh | bash -s start
#
# Logika je tady, ne v repozitáři, aby šla opravit bez nového commitu u každého uživatele.
#
# **Identitu a párování přináší telefon** v tajemství Codespaces `CODEN_SEED_<id repa>`
# (každé omezené na svůj repozitář, takže tu je vidět jen to jedno). Server ho převezme
# při prvním startu a telefon se při prvním spojení spáruje sám.
set -euo pipefail

VERSION="${CODEN_VERSION:-1.4.0}"
STATE="$HOME/.coden-server"
LOG="$STATE/server.log"
PIDFILE="$STATE/server.pid"

install() {
    arch="$(dpkg --print-architecture)"
    deb="$(mktemp --suffix=.deb)"
    echo "coden: stahuji Server $VERSION ($arch)"
    curl -fsSL -o "$deb" "https://coden-app.com/ke-stazeni/coden-server_${VERSION}_${arch}.deb"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "$deb" >/dev/null
    rm -f "$deb"
    if ! command -v claude >/dev/null 2>&1; then
        echo "coden: instaluji Claude Code"
        npm install -g --silent @anthropic-ai/claude-code
    fi
    echo "coden: nainstalováno — $(coden-server --version 2>/dev/null || echo coden-server)"
}

# Hlídač nečinnosti: Codespace bez telefonu a bez práce Agenta po 4 minutách uspí.
#
# Codespace se účtuje za celou dobu běhu a GitHub ho sám uspí až po 4 hodinách bez práce
# v editoru — do té doby by ubíral z kvóty i ve chvíli, kdy ho nikdo nepotřebuje. Server
# se ptá přes svůj místní ovládací port (`control.json`); dokud je připojený telefon nebo
# Agent pracuje či čeká na svolení, nečinnost se nepočítá vůbec. Uspává tokenem z tajemství
# `CODEN_GITHUB_TOKEN_…` — ten, který GitHub do Codespace dává sám, to neumí. Bez tokenu
# hlídač jen zapíše, proč nic nedělá. Probouzí aplikace, když se chce připojit.
watchdog() {
    local pidfile="$STATE/watchdog.pid"
    if [[ -f "$pidfile" ]] && kill -0 "$(cat "$pidfile")" 2>/dev/null; then
        return
    fi
    cat >"$STATE/watchdog.py" <<'EOF'
import json, os, socket, sys, time, urllib.request

STATE = sys.argv[1]
IDLE_S = int(os.environ.get("CODEN_IDLE_S", "240"))
SHARED = "/workspaces/.codespaces/shared/.env"

def log(text):
    print(time.strftime("%Y-%m-%dT%H:%M:%S"), "hlídač:", text, flush=True)

def shared_env():
    values = {}
    try:
        for line in open(SHARED):
            key, _, value = line.rstrip("\n").partition("=")
            values[key] = value.strip('"')
    except OSError:
        pass
    return values

def lookup(prefix, exact=False):
    for source in (os.environ, shared_env()):
        for key, value in source.items():
            if (key == prefix if exact else key.startswith(prefix)) and value:
                return value
    return None

def busy():
    """Je připojený telefon, nebo Agent pracuje? Neodpovídající Server je nečinný."""
    try:
        access = json.load(open(os.path.join(STATE, "control.json")))
        with socket.create_connection(("127.0.0.1", access["port"]), timeout=5) as c:
            c.sendall((access["token"] + "\n" + json.dumps({"command": "status"}) + "\n").encode())
            data = b""
            while not data.endswith(b"\n"):
                chunk = c.recv(65536)
                if not chunk:
                    break
                data += chunk
        status = json.loads(data)
    except Exception as e:
        log(f"Server neodpovídá ({e})")
        return False
    return bool(status.get("sessions")) or status.get("agent_state") in ("Working", "WaitingForApproval")

def stop(token, name):
    request = urllib.request.Request(
        f"https://api.github.com/user/codespaces/{name}/stop",
        method="POST",
        headers={
            "Accept": "application/vnd.github+json",
            "Authorization": f"Bearer {token}",
            "X-GitHub-Api-Version": "2022-11-28",
        },
    )
    urllib.request.urlopen(request, timeout=30).read()

idle_since = time.monotonic()
reported = False
while True:
    time.sleep(20)
    if busy():
        idle_since = time.monotonic()
        continue
    if time.monotonic() - idle_since < IDLE_S:
        continue
    token = lookup("CODEN_GITHUB_TOKEN_")
    name = lookup("CODESPACE_NAME", exact=True)
    if not token or not name:
        if not reported:
            log("chybí tajemství CODEN_GITHUB_TOKEN_… nebo jméno Codespace — uspat ho neumím")
            reported = True
        continue
    log(f"{IDLE_S} s bez telefonu a bez práce Agenta — uspávám Codespace {name}")
    try:
        stop(token, name)
        break
    except Exception as e:
        log(f"uspání selhalo: {e}")
        idle_since = time.monotonic()
EOF
    setsid nohup python3 "$STATE/watchdog.py" "$STATE" </dev/null >>"$STATE/watchdog.log" 2>&1 &
    echo $! >"$pidfile"
}

start() {
    mkdir -p "$STATE"
    chmod 700 "$STATE"
    watchdog
    # Jen proces z vlastního pidfilu — ne podle jména, v Codespace může běžet i jiný.
    if [[ -f "$PIDFILE" ]] && kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        echo "coden: Server už běží"
        return
    fi
    seed="$(env | sed -n 's/^CODEN_SEED_[A-Za-z0-9_]*=//p' | head -1)"
    # Příkazy `postStartCommand` tajemství Codespaces v prostředí nemají — leží jen
    # v souboru, ze kterého je Codespace dává terminálům. Bez tohohle se Server
    # spustil bez identity od telefonu a telefon ho nenašel.
    if [[ -z "$seed" && -f /workspaces/.codespaces/shared/.env ]]; then
        seed="$(sed -n 's/^CODEN_SEED_[A-Za-z0-9_]*=//p' /workspaces/.codespaces/shared/.env | head -1)"
        seed="${seed%\"}"; seed="${seed#\"}"
    fi
    [[ -n "$seed" ]] || echo "coden: chybí tajemství CODEN_SEED_… — Server poběží, ale telefon se s ním sám nespáruje"
    workspace="${CODESPACE_VSCODE_FOLDER:-$PWD}"
    # Log se připisuje — čekání níž se smí dívat jen na to, co přibude.
    before="$(wc -l <"$LOG" 2>/dev/null || echo 0)"
    CODEN_SEED="$seed" setsid nohup coden-server --state-dir "$STATE" start \
        --dir "$workspace" --no-upnp --no-update-check \
        </dev/null >>"$LOG" 2>&1 &
    echo $! >"$PIDFILE"
    # **Počkat, až se Server opravdu rozběhne.** Po skončení `postStartCommand` uklidí
    # Codespace všechno, co z něj zůstalo viset — Server, který se nestihl odpojit,
    # zmizel dřív, než založil i svůj log (nahlášeno: „Server není registrován").
    for _ in $(seq 1 30); do
        tail -n +"$((before + 1))" "$LOG" 2>/dev/null | grep -q "listening on" && break
        sleep 1
    done
    if kill -0 "$(cat "$PIDFILE")" 2>/dev/null; then
        echo "coden: Server spuštěn (log: $LOG)"
    else
        echo "coden: Server se nespustil — viz $LOG" >&2
        exit 1
    fi
}

case "${1:-start}" in
    install) install ;;
    start) start ;;
    *) echo "použití: codespace.sh install|start" >&2; exit 2 ;;
esac
