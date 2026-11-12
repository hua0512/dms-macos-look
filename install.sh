#!/usr/bin/env bash
# macOS look for niri + DankMaterialShell.
#   ./install.sh              apply the look (backs up what it changes first)
#   ./install.sh --uninstall  undo the look, keeping any other changes you've made since
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CFG="${XDG_CONFIG_HOME:-$HOME/.config}"
# DMS 2.1 reads $CFG/dms; older versions used $CFG/DankMaterialShell.
DMS="$CFG/dms"
[ -d "$DMS" ] || DMS="$CFG/DankMaterialShell"
NIRI_CFG="${NIRI_CONFIG:-$CFG/niri/config.kdl}"
NIRI="$(dirname "$NIRI_CFG")"
FONTCONF="$CFG/fontconfig/conf.d/60-macos-fonts.conf"
STATE="${XDG_STATE_HOME:-$HOME/.local/state}/dms-macos-look"
ORIG="$STATE/original"
GLASS_REPO="https://github.com/hua0512/dms-liquid-glass-bar"
INCLUDE_LINE='include "macos.kdl"'

say()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m!!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31mxx\033[0m %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
dms_running() { have dms && dms ipc call theme getMode >/dev/null 2>&1; }

# Replace a file's contents in place: follows symlinks (stow, chezmoi) and keeps the file's mode.
write_file() { # <target> ; content on stdin
    local target tmp
    target="$(readlink -f "$1")"
    tmp="$(mktemp "$target.XXXXXX")"
    cat >"$tmp"
    [ -s "$tmp" ] || { rm -f "$tmp"; die "Refusing to write an empty $1"; }
    if [ -e "$target" ]; then cat "$tmp" >"$target"; rm -f "$tmp"; else mv -f "$tmp" "$target"; fi
}
writable() { local t; t="$(readlink -f "$1")"; [ -w "$t" ] && [ -w "$(dirname "$t")" ]; }

# DMS keeps plugin settings in memory and doesn't reload them from disk, so restart it after editing.
restart_dms() {
    if dms_running; then
        say "Restarting DMS to load the changes"
        dms restart >/dev/null 2>&1 || warn "Couldn't restart DMS; run: dms restart"
    fi
}

uninstall() {
    [ -d "$ORIG" ] || die "Nothing to undo: no backup in $ORIG"
    say "Undoing the macOS look"
    local bs='{}' bp='{}'
    [ -f "$ORIG/settings.json" ] && bs="$(cat "$ORIG/settings.json")"
    [ -f "$ORIG/plugin_settings.json" ] && bp="$(cat "$ORIG/plugin_settings.json")"

    # Put back only the keys the installer set; everything else you've changed since stays.
    if [ -f "$DMS/settings.json" ]; then
        jq --argjson old "$bs" --slurpfile look "$HERE/dms/settings.json" --slurpfile bar "$HERE/dms/bar.json" '
            def revert($old; $keys): reduce $keys[] as $k (.;
                if ($old | has($k)) then .[$k] = $old[$k] else del(.[$k]) end);
            revert($old; $look[0] | keys)
            | if (.barConfigs | length) > 0 then
                ($old.barConfigs[0] // {}) as $ob
                | .barConfigs[0] |= revert($ob; $bar[0] | keys)
                | if any(($ob.rightWidgets // [])[]; . == "hiddenBar" or (type == "object" and .id == "hiddenBar")) then .
                  else .barConfigs[0].rightWidgets |= map(select(. != "hiddenBar" and ((type != "object") or .id != "hiddenBar")))
                  end
              else . end' "$DMS/settings.json" | write_file "$DMS/settings.json"
    fi
    if [ -f "$DMS/plugin_settings.json" ]; then
        jq --argjson old "$bp" '
            reduce ("liquidGlassBar", "hiddenBar") as $k (.;
                if ($old | has($k)) then .[$k] = $old[$k] else del(.[$k]) end)' \
            "$DMS/plugin_settings.json" | write_file "$DMS/plugin_settings.json"
    fi

    if [ -f "$NIRI_CFG" ] && grep -qxF "$INCLUDE_LINE" "$NIRI_CFG"; then
        if writable "$NIRI_CFG"; then
            grep -vxF "$INCLUDE_LINE" "$NIRI_CFG" | write_file "$NIRI_CFG"
            rm -f "$NIRI/macos.kdl"
        else
            warn "$NIRI_CFG is read-only; remove the line '$INCLUDE_LINE' yourself"
        fi
    else
        rm -f "$NIRI/macos.kdl"
    fi
    rm -f "$FONTCONF"

    if [ -f "$ORIG/gsettings" ] && have gsettings; then
        while read -r key val; do
            gsettings set org.gnome.desktop.interface "$key" "$val" 2>/dev/null || true
        done <"$ORIG/gsettings"
    fi
    mv "$ORIG" "$STATE/restored-$(date +%Y%m%d-%H%M%S)"
    restart_dms
    say "Done. The plugins are turned off; delete them with:"
    say "  rm -rf \"$DMS/plugins/liquidGlassBar\" && dms plugins uninstall hiddenBar"
}

[ "${1:-}" = "--uninstall" ] && { uninstall; exit 0; }
[ -n "${1:-}" ] && die "Unknown option: $1 (use --uninstall to undo)"

# ---- checks --------------------------------------------------------------
have jq  || die "jq is required"
have git || die "git is required"
[ -f "$DMS/settings.json" ] || die "DankMaterialShell settings not found in $DMS (start DMS once first)"
writable "$DMS/settings.json" || die "$DMS/settings.json isn't writable"

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
if compgen -G "$DMS/config.d/*.json" >/dev/null; then
    warn "You have overrides in $DMS/config.d/; any setting there wins over this look"
fi

# ---- backup (first install only, so re-running never loses your originals) ----
if [ -d "$ORIG" ]; then
    say "Keeping your original backup in $ORIG"
else
    mkdir -p "$ORIG"
    cp -f "$DMS/settings.json" "$ORIG/"
    [ -f "$DMS/plugin_settings.json" ] && cp -f "$DMS/plugin_settings.json" "$ORIG/"
    if have gsettings; then
        for k in font-name cursor-theme; do
            printf '%s %s\n' "$k" "$(gsettings get org.gnome.desktop.interface "$k" | tr -d "'")"
        done >"$ORIG/gsettings"
    fi
    say "Backed up your current settings to $ORIG"
fi

# ---- plugins -------------------------------------------------------------
mkdir -p "$DMS/plugins"
if [ ! -e "$DMS/plugins/liquidGlassBar" ]; then
    say "Installing the Liquid Glass Bar plugin"
    git clone -q --depth 1 "$GLASS_REPO" "$DMS/plugins/liquidGlassBar" \
        || warn "Couldn't download the Liquid Glass Bar plugin; the rest of the look still applies"
fi
if [ ! -e "$DMS/plugins/hiddenBar" ]; then
    say "Installing the hiddenBar plugin"
    dms plugins install hiddenBar >/dev/null 2>&1 || warn "Couldn't install hiddenBar; install it from Settings → Plugins"
fi

# ---- DMS settings --------------------------------------------------------
say "Applying the DMS look"
jq --slurpfile look "$HERE/dms/settings.json" --slurpfile bar "$HERE/dms/bar.json" '
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
      else . end' "$DMS/settings.json" | write_file "$DMS/settings.json"

ps="$DMS/plugin_settings.json"
[ -f "$ps" ] || echo '{}' >"$ps"
# Your own glass tweaks win over the defaults; the plugins are always switched on.
jq --slurpfile p "$HERE/dms/plugin_settings.json" '
    $p[0] * . | .liquidGlassBar.enabled = true | .hiddenBar.enabled = true' "$ps" | write_file "$ps"

# ---- niri ----------------------------------------------------------------
if [ ! -f "$NIRI_CFG" ]; then
    warn "niri config not found at $NIRI_CFG; skipping the niri part"
elif ! writable "$NIRI_CFG"; then
    warn "$NIRI_CFG is read-only (home-manager?). Copy niri/macos.kdl next to it and add: $INCLUDE_LINE"
else
    say "Adding the niri rules (glass bar, frosted terminals)"
    cp -f "$HERE/niri/macos.kdl" "$NIRI/macos.kdl"
    if ! grep -qxF "$INCLUDE_LINE" "$NIRI_CFG"; then
        before="$(cat "$NIRI_CFG")"
        printf '%s\n%s\n' "$before" "$INCLUDE_LINE" | write_file "$NIRI_CFG"
        if have niri && ! niri validate -c "$NIRI_CFG" >/dev/null 2>&1; then
            warn "niri rejected the rules (niri 26.04 or newer is needed), so the niri part was skipped"
            printf '%s\n' "$before" | write_file "$NIRI_CFG"
            rm -f "$NIRI/macos.kdl"
        fi
    fi
fi

# ---- fonts and GTK -------------------------------------------------------
say "Setting SF Pro as the system font and the macOS cursor for apps"
mkdir -p "$(dirname "$FONTCONF")"
cp -f "$HERE/fontconfig/60-macos-fonts.conf" "$FONTCONF"
if have gsettings; then
    gsettings set org.gnome.desktop.interface font-name 'SF Pro 11' 2>/dev/null || true
    gsettings set org.gnome.desktop.interface cursor-theme 'macOS' 2>/dev/null || true
fi

restart_dms
say "Done! A few apps pick up the new font and cursor only after you restart them."
say "Changed your mind? Run: $0 --uninstall"
