#!/usr/bin/env bash
#
# apply-language-config.sh - push the .env language settings into every service.
#
#   ./scripts/apply-language-config.sh           apply / re-apply
#   ./scripts/apply-language-config.sh --check   report only, change nothing
#
# Reads STACKARR_UI_LANGUAGE, STACKARR_CONTENT_LANGUAGE, STACKARR_SUBTITLES and
# STACKARR_AUDIO from .env.
#
# STACKARR_AUDIO=original means "keep the source audio": this script never asks
# any service to prefer a dubbed track, it only sets subtitle preferences and
# interface/metadata language.
#
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$ROOT/.env"
CONFIG_ROOT="$ROOT/.stackarr/config"
MODE=apply

case "${1:-}" in
	--check) MODE=check ;;
	--help | -h)
		sed -n '3,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
		exit 0
		;;
	"") ;;
	*)
		echo "usage: $(basename "$0") [--check]" >&2
		exit 2
		;;
esac

[[ -f $ENV_FILE ]] || { echo "error: $ENV_FILE not found" >&2; exit 1; }

read_env() {
	sed -n "s/^[[:space:]]*$1=\(.*\)$/\1/p" "$ENV_FILE" | tail -n1 | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'\$/\1/"
}

UI_LANG="$(read_env STACKARR_UI_LANGUAGE)"
CONTENT_LANG="$(read_env STACKARR_CONTENT_LANGUAGE)"
SUBS="$(read_env STACKARR_SUBTITLES)"
AUDIO="$(read_env STACKARR_AUDIO)"
AUDIO="${AUDIO:-original}"

if [[ -z $UI_LANG ]]; then
	echo "STACKARR_UI_LANGUAGE is blank in .env - nothing to do."
	exit 0
fi

export UI_LANG CONTENT_LANG SUBS AUDIO MODE CONFIG_ROOT

command -v python3 >/dev/null || { echo "error: python3 is required" >&2; exit 1; }

python3 - <<'PY'
import os
import re
import sqlite3
import subprocess
import sys
import time
import xml.etree.ElementTree as ET

CFG = os.environ["CONFIG_ROOT"]
CHECK = os.environ["MODE"] == "check"
UI = os.environ["UI_LANG"].strip()
CONTENT = os.environ["CONTENT_LANG"].strip() or UI
SUBS = [s.strip() for s in os.environ["SUBS"].split(",") if s.strip()] or [UI]
AUDIO = os.environ["AUDIO"].strip() or "original"
PRIMARY_SUB = SUBS[0]

results = []


def report(name, status, detail=""):
    results.append((name, status, detail))


def docker(*args):
    return subprocess.run(("docker",) + args, capture_output=True, text=True)


def restart(name):
    """Stop -> mutate -> start, so the app never overwrites our edit on exit."""
    if docker("inspect", "--type", "container", name).returncode != 0:
        return False
    running = docker("inspect", "--format", "{{.State.Running}}", name).stdout.strip() == "true"
    if running:
        docker("stop", name)
    return True


def start(name):
    if docker("inspect", "--type", "container", name).returncode == 0:
        docker("start", name)


# --------------------------------------------------------------------------- #
# Radarr / Sonarr / Lidarr / Prowlarr
#
# The storage format is NOT uniform, and the integer value is NOT derivable:
#
#   Radarr / Sonarr / Lidarr - UILanguage is an integer, but it is an index into
#     each app's OWN Language enum, which differs per app. Brazilian Portuguese
#     is index 30 on Radarr and 33 on Sonarr - the same index gives a different
#     language on each build. It is NOT the position of the file in
#     Localization/Core: neither pt (30) nor pt_BR (31) is right everywhere.
#
#   Prowlarr - UILanguage is a STRING culture code ("pt_BR"), read from the
#     Localization/Core file name. Writing an integer is silently ignored and
#     the UI stays English.
#
# The values below were each confirmed by setting the language in that app's
# own web UI and reading back what it wrote - Radarr=30, Sonarr=33, Lidarr=30,
# Prowlarr="pt_BR". Note Radarr and Lidarr both land on 30 while Sonarr needs
# 33, which is why nothing here may be derived.
#
# To add or correct a value: set the language in that app's web UI
# (Settings > General > UI Language), then read it back with
#   SELECT Value FROM Config WHERE Key='uilanguage';
# --------------------------------------------------------------------------- #
SERVARR_CONFIRMED = {
    "radarr": "30",
    "sonarr": "33",
    "lidarr": "30",
    "prowlarr": "pt_BR",  # string, not an index
}
SERVARR = ("radarr", "sonarr", "lidarr", "prowlarr")


def servarr(app):
    db = os.path.join(CFG, app, f"{app}.db")
    if not os.path.exists(db):
        return report(app, "skipped", "no database")
    want = SERVARR_CONFIRMED.get(app)
    if want is None:
        return report(app, "manual", "UI language: set it in the web UI, then add it here")

    was = restart(app)
    try:
        con = sqlite3.connect(db)
        row = con.execute("SELECT Value FROM Config WHERE Key='uilanguage'").fetchone()
        current = row[0] if row else None
        if CHECK:
            con.close()
            if was:
                start(app)
            if current == want:
                return report(app, "ok", f"UI = {UI} ({want})")
            return report(app, "mismatch", f"ui language = {current or 'default'}")

        if current != want:
            con.execute("INSERT OR REPLACE INTO Config (Key,Value) VALUES ('uilanguage',?)", (want,))
            con.commit()
        con.close()
    except sqlite3.Error as e:
        if was:
            start(app)
        return report(app, "error", f"sqlite: {e}")
    if was:
        start(app)
    report(app, "updated", f"UI = {UI} ({want})")


# --------------------------------------------------------------------------- #
# Bazarr - config.yaml
# --------------------------------------------------------------------------- #
def bazarr(path):
    try:
        import yaml
    except ImportError:
        return report("bazarr", "error", "PyYAML is required")

    with open(path) as fh:
        cfg = yaml.safe_load(fh) or {}

    def patch(doc):
        sub = doc.setdefault("subtitle", {})
        sub["language"] = SUBS
        sub["hi_embedded_subtitles"] = sub.get("hi_embedded_subtitles", True)
        es = doc.setdefault("embeddedsubtitles", {})
        es["fallback_lang"] = PRIMARY_SUB
        es["hi_fallback"] = es.get("hi_fallback", False)
        return doc

    def current(doc):
        sub = (doc.get("subtitle") or {}).get("language")
        fb = ((doc.get("embeddedsubtitles") or {}).get("fallback_lang"))
        return sub, fb

    before = current(cfg)
    if CHECK:
        if before[0] == SUBS and before[1] == PRIMARY_SUB:
            return report("bazarr", "ok", f"subtitles {SUBS}, fallback {PRIMARY_SUB}")
        return report("bazarr", "mismatch", f"subtitles={before[0]} fallback={before[1]}")

    if before[0] == SUBS and before[1] == PRIMARY_SUB:
        return report("bazarr", "ok", "already matches")

    was = restart("bazarr")
    patch(cfg)
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        yaml.safe_dump(cfg, fh, sort_keys=False)
    os.replace(tmp, path)
    if was:
        start("bazarr")
    report("bazarr", "updated", f"subtitles {SUBS}, fallback {PRIMARY_SUB}")


# --------------------------------------------------------------------------- #
# Jellyfin - system.xml holds the UI + metadata language.
# Library-level audio/subtitle ranking is owned by the Jellyfin UI/API and is
# deliberately NOT touched, so the original audio is never replaced.
# --------------------------------------------------------------------------- #
def jellyfin(path):
    if not os.path.exists(path):
        return report("jellyfin", "skipped", "no system.xml")
    tree = ET.parse(path)
    root = tree.getroot()
    want = {"PreferredMetadataLanguage": CONTENT}
    have = {c.tag: c.text for c in root if c.tag in want}
    meta_ok = all(have.get(k) == v for k, v in want.items())

    # Jellyfin rewrites system.xml on boot and drops any <Language> element, so
    # the real per-user subtitle/audio preference lives in its SQLite Users
    # table. "Original" is always kept first for audio so the source track wins.
    db = os.path.join(CFG, "jellyfin", "data", "data", "jellyfin.db")
    want_audio = "Original" + ("," + UI if AUDIO == "original" and UI else "")
    users_ok = False
    try:
        con = sqlite3.connect(db)
        rows = con.execute(
            "SELECT Id, AudioLanguagePreference, SubtitleLanguagePreference FROM Users"
        ).fetchall()
        users_ok = bool(rows) and all(
            r[1] == want_audio and r[2] == ",".join(SUBS) for r in rows
        )
        if not CHECK and not users_ok:
            was = restart("jellyfin")
            con.execute(
                "UPDATE Users SET AudioLanguagePreference=?, SubtitleLanguagePreference=?",
                (want_audio, ",".join(SUBS)),
            )
            con.commit()
            users_ok = True
            if was:
                start("jellyfin")
        con.close()
    except sqlite3.Error:
        users_ok = None

    if CHECK:
        if meta_ok and users_ok:
            return report("jellyfin", "ok", f"subs {SUBS}, audio {want_audio}")
        detail = "metadata ok" if meta_ok else f"metadata={have.get('PreferredMetadataLanguage')}"
        if users_ok is False:
            detail += ", user subs/audio differ"
        return report("jellyfin", "mismatch", detail)

    changed = []
    if not meta_ok:
        was = restart("jellyfin")
        for tag, val in want.items():
            el = root.find(tag)
            if el is None:
                el = ET.SubElement(root, tag)
            el.text = val
        tree.write(path, encoding="UTF-8", xml_declaration=True)
        if was:
            start("jellyfin")
        changed.append("metadata")
    if users_ok is not True:
        changed.append("user prefs")
    if not changed:
        return report("jellyfin", "ok", "already matches")
    report("jellyfin", "updated", f"{', '.join(changed)} -> subs {SUBS}, audio {want_audio}")


# --------------------------------------------------------------------------- #
# Recyclarr - declarative; seed a language-aware quality profile.
# --------------------------------------------------------------------------- #
def recyclarr(path):
    try:
        import yaml
    except ImportError:
        return report("recyclarr", "error", "PyYAML is required")
    if not os.path.exists(path):
        return report("recyclarr", "skipped", "no recyclarr.yml")
    with open(path) as fh:
        cfg = yaml.safe_load(fh) or {}
    want = {"preferred": SUBS, "unwanted": ["en"] if "pt-BR" in SUBS else []}
    cur = ((cfg.get("qualityProfiles") or {}).get("language") or {})
    if CHECK:
        if cur == want:
            return report("recyclarr", "ok", f"language {SUBS}")
        return report("recyclarr", "mismatch", f"language = {cur or 'unset'}")
    if cur == want:
        return report("recyclarr", "ok", "already matches")
    cfg.setdefault("qualityProfiles", {})["language"] = want
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        yaml.safe_dump(cfg, fh, sort_keys=False)
    os.replace(tmp, path)
    report("recyclarr", "updated", f"language {SUBS} (audio untouched)")


for app in SERVARR:
    servarr(app)
pass

bz = os.path.join(CFG, "bazarr", "config", "config.yaml")
if os.path.exists(bz):
    try:
        bazarr(bz)
    except Exception as e:  # noqa: BLE001
        report("bazarr", "error", str(e)[:60])
else:
    report("bazarr", "skipped", "no config.yaml")

jellyfin(os.path.join(CFG, "jellyfin", "system.xml"))
recyclarr(os.path.join(CFG, "recyclarr", "recyclarr.yml"))

report("qbittorrent", "n/a", "no language settings")
report("tinymediamanager", "n/a", "no language settings")
report("stackarr", "manual", "UI language comes from the browser locale")
report("audio", "original" if AUDIO == "original" else AUDIO, "left untouched by this script")

width = max(len(n) for n, _, _ in results)
print()
print(f"  {'SERVICE'.ljust(width)}  STATUS      DETAIL")
print(f"  {'-' * width}  ----------  {'-' * 48}")
for name, status, detail in results:
    print(f"  {name.ljust(width)}  {status.ljust(10)}  {detail}")
print()
if CHECK:
    drifted = [n for n, s, _ in results if s in ("mismatch", "error")]
    if drifted:
        print(f"  {len(drifted)} service(s) differ: {', '.join(drifted)}")
        sys.exit(1)
    print("  All supported services already match.")
else:
    done = [n for n, s, _ in results if s == "updated"]
    print(f"  Updated: {', '.join(done) if done else 'nothing (already in sync)'}")
PY
