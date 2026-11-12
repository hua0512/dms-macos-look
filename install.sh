#!/usr/bin/env bash
# macOS look for niri + DankMaterialShell.
#   ./install.sh              apply the look (backs up everything it touches first)
#   ./install.sh --uninstall  restore the most recent backup
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="${XDG_CONFIG_HOME:-$HOME/.config}"
DMS="$CFG/DankMaterialShell"
[ -d "$DMS" ] || DMS="$CFG/dms"
NIRI="$CFG/niri"
FONTCONF="$CFG/fontconfig/conf.d/60-macos-fonts.conf"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/dms-macos-look"
GLASS_REPO="https://github.com/hua0512/dms-liquid-glass-bar"
INCLUDE_LINE='include "macos.kdl"'

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
dms_running() { have dms && dms ipc call theme getMode >/dev/null 2>&1; }

# Write JSON atomically so DMS's live reload never sees a half-written file.
write_json() { local tmp; tmp="$(mktemp "$2.XXXXXX")"; printf '%s\n' "$1" >"$tmp"; mv -f "$tmp" "$2"; }

uninstall() {
    local b="$STATE/original"
    [ -d "$b" ] || die "No backup found in $b"
    say "Restoring your settings from before the first install ($b)"
    for f in settings.json plugin_settings.json; do
        [ -f "$b/dms/$f" ] && cp -f "$b/dms/$f" "$DMS/$f"
    done
    [ -f "$b/niri/config.kdl" ] && cp -f "$b/niri/config.kdl" "$NIRI/config.kdl"
    # Never leave niri including a file that is about to be removed.
    if [ -f "$NIRI/config.kdl" ]; then
        local tmp; tmp="$(mktemp "$NIRI/config.kdl.XXXXXX")"
        grep -vxF "$INCLUDE_LINE" "$NIRI/config.kdl" >"$tmp" || true
        mv -f "$tmp" "$NIRI/config.kdl"
    fi
    rm -f "$NIRI/macos.kdl" "$FONTCONF"
    have fc-cache && fc-cache -f >/dev/null 2>&1 || true
    if [ -f "$b/gsettings" ] && have gsettings; then
        while read -r key val; do
            gsettings set org.gnome.desktop.interface "$key" "$val" 2>/dev/null || true
        done <"$b/gsettings"
    fi
    mv "$b" "$STATE/restored-$(date +%Y%m%d-%H%M%S)"
    say "Done. The Liquid Glass Bar and hiddenBar plugins are still installed but now disabled in your restored settings."
    say "Remove them with: rm -rf \"$DMS/plugins/liquidGlassBar\" && dms plugins uninstall hiddenBar"
}

[ "${1:-}" = "--uninstall" ] && { uninstall; exit 0; }
[ -n "${1:-}" ] && die "Unknown option: $1 (use --uninstall to restore)"

# ---- checks --------------------------------------------------------------
have jq  || die "jq is required"
have git || die "git is required"
[ -f "$DMS/settings.json" ] || die "DankMaterialShell settings not found in $DMS (start DMS once first)"
[ -f "$NIRI/config.kdl" ]   || warn "niri config not found; skipping the niri part"

missing=()
fonts="$(fc-list : family 2>/dev/null || true)"
grep -q "SF Pro" <<<"$fonts" || missing+=("SF Pro font (AUR: apple-fonts)")
[ -d /usr/share/icons/WhiteSur-dark ] || [ -d "$HOME/.local/share/icons/WhiteSur-dark" ] \
    || missing+=("WhiteSur icons (whitesur-icon-theme)")
[ -d /usr/share/icons/macOS ] || [ -d "$HOME/.local/share/icons/macOS" ] || [ -d "$HOME/.icons/macOS" ] \
    || missing+=("macOS cursor (AUR: apple_cursor)")
if [ ${#missing[@]} -gt 0 ]; then
    warn "Not installed yet (the look still applies, these just fall back to defaults):"
    for m in "${missing[@]}"; do warn "  - $m"; done
fi

# ---- backup --------------------------------------------------------------
# Only the first install is backed up, so re-running never overwrites your original settings.
B="$STATE/original"
if [ -d "$B" ]; then
    say "Keeping your existing backup in $B"
else
    mkdir -p "$B/dms" "$B/niri"
    cp -f "$DMS/settings.json" "$B/dms/"
    [ -f "$DMS/plugin_settings.json" ] && cp -f "$DMS/plugin_settings.json" "$B/dms/"
    [ -f "$NIRI/config.kdl" ] && cp -f "$NIRI/config.kdl" "$B/niri/"
    if have gsettings; then
        for k in font-name cursor-theme; do
            printf '%s %s\n' "$k" "$(gsettings get org.gnome.desktop.interface "$k" | tr -d "'")"
        done >"$B/gsettings"
    fi
    say "Backed up your current settings to $B"
fi

# ---- plugins -------------------------------------------------------------
mkdir -p "$DMS/plugins"
if [ ! -e "$DMS/plugins/liquidGlassBar" ]; then
    say "Installing the Liquid Glass Bar plugin"
    git clone -q --depth 1 "$GLASS_REPO" "$DMS/plugins/liquidGlassBar"
fi
if [ ! -e "$DMS/plugins/hiddenBar" ]; then
    say "Installing the hiddenBar plugin"
    dms plugins install hiddenBar >/dev/null || warn "Couldn't install hiddenBar; install it from Settings → Plugins"
fi

# ---- DMS settings --------------------------------------------------------
say "Applying the DMS look"
merged="$(jq --slurpfile look "$HERE/dms/settings.json" --slurpfile bar "$HERE/dms/bar.json" '
    . * $look[0]
    | if (.barConfigs | length) > 0 then
        .barConfigs[0] *= $bar[0]
        # Tuck tray icons behind a toggle, like the macOS menu bar.
        | .barConfigs[0].rightWidgets |= (
            (. // []) as $w
            | if any($w[]; . == "hiddenBar" or (type == "object" and .id == "hiddenBar")) then $w
              else ($w | map(if type == "object" then .id else . end) | index("notificationButton")) as $i
                   | if $i == null then $w + ["hiddenBar"] else $w[:$i] + ["hiddenBar"] + $w[$i:] end
              end)
      else . end' "$DMS/settings.json")"
write_json "$merged" "$DMS/settings.json"

ps="$DMS/plugin_settings.json"
[ -f "$ps" ] || echo '{}' >"$ps"
write_json "$(jq --slurpfile p "$HERE/dms/plugin_settings.json" '. * $p[0]' "$ps")" "$ps"

if dms_running; then
    dms ipc call plugins enable hiddenBar >/dev/null 2>&1 || true
    dms ipc call plugins enable liquidGlassBar >/dev/null 2>&1 || true
fi

# ---- niri ----------------------------------------------------------------
if [ -f "$NIRI/config.kdl" ]; then
    say "Adding the niri rules (hot corner, glass bar, frosted terminals)"
    niri_before="$(mktemp)"; cp -f "$NIRI/config.kdl" "$niri_before"
    cp -f "$HERE/niri/macos.kdl" "$NIRI/macos.kdl"
    grep -qxF "$INCLUDE_LINE" "$NIRI/config.kdl" || printf '\n%s\n' "$INCLUDE_LINE" >>"$NIRI/config.kdl"
    if have niri && ! niri validate -c "$NIRI/config.kdl" >/dev/null 2>&1; then
        warn "niri rejected the config, so the niri part was rolled back"
        cp -f "$niri_before" "$NIRI/config.kdl"
        rm -f "$NIRI/macos.kdl"
    fi
    rm -f "$niri_before"
fi

# ---- fonts and GTK -------------------------------------------------------
say "Setting SF Pro as the system font and the macOS cursor for apps"
mkdir -p "$(dirname "$FONTCONF")"
cp -f "$HERE/fontconfig/60-macos-fonts.conf" "$FONTCONF"
have fc-cache && fc-cache -f >/dev/null 2>&1 || true
if have gsettings; then
    gsettings set org.gnome.desktop.interface font-name 'SF Pro 11' 2>/dev/null || true
    gsettings set org.gnome.desktop.interface cursor-theme 'macOS' 2>/dev/null || true
fi

say "Done! A few apps pick up the new font and cursor only after a restart."
say "Changed your mind? Run: $0 --uninstall"
