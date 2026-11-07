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

start() {
    mkdir -p "$STATE"
    chmod 700 "$STATE"
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
