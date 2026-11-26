#!/usr/bin/env python3
"""Monitor Play: layout, resolutions, refresh rates, and a JSON API.

The live default stays the current one until an apply:
  laptop eDP-1 at 0x0, scale 2, preferred mode
  Kogan HDMI-A-1 at 1536x0, 3440x1440@100, scale 1

180 Hz is the panel maximum and is not advertised on this HDMI link.
4K 60 Hz and 1080p 240 Hz are the HDMI cable ratings. Apply tries a mode
and restores the previous layout if the screen does not accept it.
"""

from __future__ import annotations

import json
import re
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]*$")
MODE_RE = re.compile(r"^(?:preferred|\d+x\d+@\d+)$")
EDID_RE = re.compile(r"(\d+)x(\d+)@([0-9.]+)Hz")

# What is on screen right now. Preset "default" restores this and does not
# touch backlight.
# The layout on screen now: Kogan centered, laptop tucked on its left.
DEFAULTS = [
    {
        "match": "eDP",
        "name": "eDP-1",
        "mode": "preferred",
        "x": -1147,
        "y": 480,
        "scale": 2,
        "transform": 0,
        "vrr": False,
    },
    {
        "match": "KAMN34Q18WA",
        "name": "HDMI-A-1",
        "mode": "3440x1440@100",
        "x": 389,
        "y": 270,
        "scale": 1,
        "transform": 0,
        "vrr": False,
    },
]

FIT_NOTES = {
    "sharp": "Sharp. These are the panel's real pixels, so the picture fits exactly.",
    "softer": "Softer. Same shape as the panel, with fewer pixels, so text is a little fuzzy and motion can feel smoother.",
    "stretches": "Stretches. This shape does not match the panel, so the picture is stretched or gets black bars.",
}

RESOLUTION_PRIORITY = [
    "3440x1440",
    "3840x2160",
    "2560x1440",
    "2560x1080",
    "1920x1080",
]

PANEL_180_NOTE = (
    "180 Hz is this panel's maximum. HDMI here only advertises 100 Hz at "
    "3440×1440. DisplayPort is the reliable way to run 180. Apply tries it "
    "and puts the previous layout back if the screen cannot use it."
)
CABLE_4K_NOTE = (
    "4K at 60 Hz is what this HDMI cable is rated for. The Kogan panel is "
    "3440×1440, so it may refuse 3840×2160. Apply puts the previous layout "
    "back if it does not stick."
)
CABLE_240_NOTE = (
    "240 Hz at 1080p is what this HDMI cable is rated for. The monitor "
    "advertises 1920×1080 up to 120 Hz. Apply puts the previous layout back "
    "if 240 does not stick."
)

TOOLS = {
    "name": "monitor-play",
    "description": (
        "Read and set the laptop and external monitor. Current default is "
        "the laptop on the left at scale 2 and the Kogan on the right at "
        "3440x1440@100 scale 1. Modes the screen does not accept are rolled back."
    ),
    "tools": [
        {
            "name": "monitor_play_get",
            "description": "List screens, the confirmed refresh rate, fit of every mode (sharp, softer, stretches), and the saved default profile.",
            "command": ["monitor-play", "api", "get"],
            "input": {"type": "object", "properties": {}},
        },
        {
            "name": "monitor_play_defaults",
            "description": "Return the saved default layout. Does not change the screens.",
            "command": ["monitor-play", "api", "defaults"],
            "input": {"type": "object", "properties": {}},
        },
        {
            "name": "monitor_play_set",
            "description": (
                "Change one or more screen settings and apply them. Omitted fields stay as they are. "
                "Set dryRun true to preview the Hyprland config without changing anything. "
                "refresh 180 at 3440x1440 needs DisplayPort on this Kogan. "
                "3840x2160@60 and 1920x1080@240 are the HDMI cable ratings and may be rejected. "
                "preset default restores the laptop-left 100 Hz layout and leaves backlight alone."
            ),
            "command": ["monitor-play", "api", "set"],
            "destructive": True,
            "input": {
                "type": "object",
                "properties": {
                    "dryRun": {"type": "boolean"},
                    "preset": {
                        "type": "string",
                        "enum": ["default", "laptop-left", "laptop-right", "stacked"],
                    },
                    "seconds": {"type": "integer", "description": "Used by api try. How long to keep the trial before restoring."},
                    "screens": {
                        "type": "array",
                        "items": {
                            "type": "object",
                            "required": ["name"],
                            "properties": {
                                "name": {"type": "string"},
                                "mode": {"type": "string", "description": "WxH@Hz or preferred"},
                                "resolution": {"type": "string", "description": "WxH, for example 1920x1080 or 3840x2160"},
                                "refresh": {"type": "integer", "description": "Hz at that resolution. 60, 100, 120, 144, 180, 240 when offered."},
                                "scale": {"type": "number"},
                                "x": {"type": "integer"},
                                "y": {"type": "integer"},
                                "transform": {"type": "integer", "enum": [0, 1, 2, 3], "description": "0, 90, 180, 270 degrees clockwise"},
                                "vrr": {"type": "boolean", "description": "Adaptive sync / FreeSync"},
                                "bitdepth": {"type": "integer", "enum": [8, 10]},
                                "brightness": {"type": "integer", "description": "Backlight percent, 0 to 100"},
                            },
                        },
                    },
                },
            },
        },
        {
            "name": "monitor_play_save",
            "description": "Save the given layout, or the live layout when screens is omitted, as the default profile and keep it applied.",
            "command": ["monitor-play", "api", "save"],
            "destructive": True,
            "input": {"type": "object", "properties": {"screens": {"type": "array"}}},
        },
        {
            "name": "monitor_play_try",
            "description": "Apply a layout for 10 seconds, then restore the previous one.",
            "command": ["monitor-play", "api", "try"],
            "destructive": True,
            "input": {"type": "object", "properties": {"seconds": {"type": "integer"}, "screens": {"type": "array"}}},
        },
        {
            "name": "monitor_play_brightness",
            "description": "Set backlight percent for one screen without reloading the layout.",
            "command": ["monitor-play", "api", "brightness"],
            "destructive": True,
            "input": {"type": "object", "properties": {"screens": {"type": "array"}}},
        },
    ],
}


def fail(message: str) -> None:
    print(json.dumps({"ok": False, "error": message}))
    print(message, file=sys.stderr)
    raise SystemExit(1)


def lua_string(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def scale_literal(value: float) -> str:
    if abs(value - round(value)) < 1e-6:
        return str(int(round(value)))
    text = f"{value:.2f}".rstrip("0").rstrip(".")
    return text


def run(args: list[str], timeout: float = 8) -> subprocess.CompletedProcess[str]:
    return subprocess.run(args, capture_output=True, text=True, timeout=timeout)


def friendly(mon: dict) -> str:
    name = mon.get("name") or ""
    model = mon.get("model") or ""
    make = mon.get("make") or ""
    if name.startswith("eDP"):
        return "Laptop"
    if "KAMN" in model or "KOGAN" in make.upper():
        return "Kogan"
    if model and not model.startswith("0x"):
        return model
    return name


def resolution_label(key: str) -> str:
    if key == "3840x2160":
        return "4K"
    if key == "1920x1080":
        return "1080p"
    if key == "3440x1440":
        return "3440×1440"
    width, height = key.split("x")
    return f"{width}×{height}"


def sort_resolutions(keys: list[str]) -> list[str]:
    def sort_key(res: str) -> tuple:
        if res in RESOLUTION_PRIORITY:
            return (0, RESOLUTION_PRIORITY.index(res))
        width, height = (int(part) for part in res.split("x"))
        return (1, -(width * height))

    return sorted(set(keys), key=sort_key)


def extras_for(mon: dict) -> list[dict]:
    if str(mon.get("name", "")).startswith("eDP"):
        return []
    model = mon.get("model") or ""
    extras = [
        {
            "width": 3840,
            "height": 2160,
            "refresh": 60,
            "source": "cable",
            "note": CABLE_4K_NOTE,
        },
        {
            "width": 1920,
            "height": 1080,
            "refresh": 240,
            "source": "cable",
            "note": CABLE_240_NOTE,
        },
    ]
    if "KAMN34Q18WA" in model or "KOGAN" in (mon.get("make") or "").upper():
        extras.insert(
            0,
            {
                "width": 3440,
                "height": 1440,
                "refresh": 180,
                "source": "panel",
                "note": PANEL_180_NOTE,
            },
        )
    return extras


def parse_edid_modes(raw_modes: list[str]) -> list[dict]:
    found: dict[tuple[int, int, int], dict] = {}
    for raw in raw_modes or []:
        match = EDID_RE.search(str(raw))
        if not match:
            continue
        width, height, refresh = int(match.group(1)), int(match.group(2)), int(round(float(match.group(3))))
        found[(width, height, refresh)] = {
            "width": width,
            "height": height,
            "refresh": refresh,
            "source": "edid",
            "advertised": True,
            "note": "",
        }
    return list(found.values())


def classify_fit(width: int, height: int, native_w: int, native_h: int) -> str:
    if native_w <= 0 or native_h <= 0 or width <= 0 or height <= 0:
        return "sharp"
    if width == native_w and height == native_h:
        return "sharp"
    native_aspect = native_w / native_h
    aspect = width / height
    if abs(aspect - native_aspect) / native_aspect <= 0.04:
        return "softer"
    return "stretches"


def panel_native(mon: dict, modes: list[dict]) -> tuple[int, int]:
    model = mon.get("model") or ""
    if "KAMN34Q18WA" in model:
        return 3440, 1440
    if modes:
        best = max(modes, key=lambda item: item["width"] * item["height"])
        return best["width"], best["height"]
    return int(mon.get("width") or 0), int(mon.get("height") or 0)


def build_modes(mon: dict) -> list[dict]:
    modes = parse_edid_modes(mon.get("availableModes") or [])
    native_w, native_h = panel_native(mon, modes)
    have = {(item["width"], item["height"], item["refresh"]) for item in modes}
    for extra in extras_for(mon):
        key = (extra["width"], extra["height"], extra["refresh"])
        if key in have:
            continue
        modes.append(
            {
                "width": extra["width"],
                "height": extra["height"],
                "refresh": extra["refresh"],
                "source": extra["source"],
                "advertised": False,
                "note": extra["note"],
            }
        )
    preferred_hz = int(round(float(mon.get("refreshRate") or 0)))
    internal = str(mon.get("name", "")).startswith("eDP")
    catalog = []
    for item in modes:
        mode = f"{item['width']}x{item['height']}@{item['refresh']}"
        preferred = False
        if internal and item["width"] == native_w and item["height"] == native_h and item["refresh"] == max(
            (m["refresh"] for m in modes if m["width"] == native_w and m["height"] == native_h),
            default=preferred_hz,
        ):
            mode = "preferred"
            preferred = True
        fit = classify_fit(item["width"], item["height"], native_w, native_h)
        tag = f"{item['refresh']} {fit}"
        if item["source"] == "panel":
            tag = f"{item['refresh']} DP · {fit}"
        elif item["source"] == "cable":
            tag = f"{item['refresh']} cable · {fit}"
        entry = {
            "mode": mode,
            "width": item["width"],
            "height": item["height"],
            "refresh": item["refresh"],
            "advertised": item["advertised"],
            "source": item["source"],
            "note": item["note"],
            "preferred": preferred,
            "fit": fit,
            "fitNote": FIT_NOTES[fit],
            "label": tag,
        }
        catalog.append(entry)
    catalog.sort(key=lambda item: (item["width"] * item["height"], item["refresh"], item["mode"] != "preferred"))
    return catalog


def resolutions_of(modes: list[dict]) -> list[str]:
    return sort_resolutions([f"{item['width']}x{item['height']}" for item in modes])


def hypr_monitors() -> list[dict]:
    result = run(["hyprctl", "monitors", "-j"], timeout=5)
    if result.returncode != 0:
        fail((result.stderr or result.stdout or "hyprctl monitors failed").strip())
    try:
        data = json.loads(result.stdout or "[]")
    except json.JSONDecodeError as exc:
        fail(f"hyprctl returned invalid json: {exc}")
    if not isinstance(data, list):
        fail("hyprctl monitors did not return a list")
    return [mon for mon in data if not mon.get("disabled")]


def brightness_map() -> dict[str, dict]:
    found: dict[str, dict] = {}
    try:
        detected = run(["ddcutil", "detect", "--brief"], timeout=8)
    except (OSError, subprocess.TimeoutExpired):
        detected = None
    if detected and detected.returncode == 0:
        name = ""
        bus = ""
        usable = True
        for line in detected.stdout.splitlines():
            stripped = line.strip()
            if stripped.startswith("Display "):
                name = ""
                bus = ""
                usable = True
            elif stripped == "Invalid display":
                usable = False
            elif "DRM connector:" in stripped:
                connector = stripped.split(":", 1)[1].strip()
                name = connector.split("-", 1)[-1] if "-" in connector else connector
            elif "I2C bus:" in stripped:
                match = re.search(r"i2c-(\d+)", stripped)
                bus = match.group(1) if match else ""
            elif usable and name and bus and stripped.startswith("Monitor:"):
                try:
                    value = run(["ddcutil", "--bus", bus, "getvcp", "10", "--brief"], timeout=4)
                except (OSError, subprocess.TimeoutExpired):
                    value = None
                if value and value.returncode == 0:
                    parts = value.stdout.split()
                    if len(parts) >= 5 and parts[0] == "VCP":
                        try:
                            found[name] = {
                                "brightness": int(parts[3]),
                                "brightnessMax": int(parts[4]),
                                "brightnessBus": bus,
                                "brightnessKind": "ddc",
                            }
                        except ValueError:
                            pass
                name = ""
                bus = ""
    try:
        current = run(["brightnessctl", "-d", "intel_backlight", "get"], timeout=3)
        maximum = run(["brightnessctl", "-d", "intel_backlight", "max"], timeout=3)
        if current.returncode == 0 and maximum.returncode == 0:
            cur = int(current.stdout.strip())
            max_value = int(maximum.stdout.strip())
            if max_value > 0:
                found["eDP-1"] = {
                    "brightness": int(round(cur * 100 / max_value)),
                    "brightnessMax": 100,
                    "brightnessBus": "intel_backlight",
                    "brightnessKind": "backlight",
                }
    except (OSError, subprocess.TimeoutExpired, ValueError):
        pass
    return found


def current_mode(mon: dict) -> str:
    if str(mon.get("name", "")).startswith("eDP"):
        return "preferred"
    width = int(mon.get("width") or 0)
    height = int(mon.get("height") or 0)
    refresh = int(round(float(mon.get("refreshRate") or 0)))
    return f"{width}x{height}@{refresh}"


def screen_record(mon: dict, lights: dict[str, dict]) -> dict:
    modes = build_modes(mon)
    light = lights.get(mon.get("name") or "", {})
    mode = current_mode(mon)
    if mode != "preferred" and not any(item["mode"] == mode for item in modes):
        modes.append(
            {
                "mode": mode,
                "width": int(mon.get("width") or 0),
                "height": int(mon.get("height") or 0),
                "refresh": int(round(float(mon.get("refreshRate") or 0))),
                "advertised": True,
                "source": "edid",
                "note": "",
                "preferred": False,
                "label": str(int(round(float(mon.get("refreshRate") or 0)))),
                "fit": "sharp",
                "fitNote": "",
            }
        )
    return {
        "name": mon.get("name"),
        "label": friendly(mon),
        "make": mon.get("make") or "",
        "model": mon.get("model") or "",
        "x": int(mon.get("x") or 0),
        "y": int(mon.get("y") or 0),
        "width": int(mon.get("width") or 0),
        "height": int(mon.get("height") or 0),
        "scale": float(mon.get("scale") or 1),
        "refresh": int(round(float(mon.get("refreshRate") or 0))),
        "confirmedHz": round(float(mon.get("refreshRate") or 0), 2),
        "mode": mode,
        "transform": int(mon.get("transform") or 0),
        "vrr": bool(mon.get("vrr")),
        "bitdepth": None,
        "focused": bool(mon.get("focused")),
        "brightness": light.get("brightness"),
        "brightnessMax": light.get("brightnessMax"),
        "brightnessBus": light.get("brightnessBus"),
        "brightnessKind": light.get("brightnessKind"),
        "modes": modes,
        "resolutions": resolutions_of(modes),
    }


def read_state() -> list[dict]:
    lights = brightness_map()
    return [screen_record(mon, lights) for mon in hypr_monitors()]


def catalog_for(screen: dict) -> list[dict]:
    return screen.get("modes") or []


def find_mode(screen: dict, mode: str) -> dict | None:
    for item in catalog_for(screen):
        if item["mode"] == mode:
            return item
    return None


def mode_from_resolution(screen: dict, resolution: str, refresh: int | None) -> str:
    matches = [
        item
        for item in catalog_for(screen)
        if f"{item['width']}x{item['height']}" == resolution
    ]
    if not matches:
        fail(f"{screen['name']} has no {resolution} mode")
    if refresh is None:
        current = screen.get("refresh")
        for item in matches:
            if item["refresh"] == current:
                return item["mode"]
        advertised = [item for item in matches if item["advertised"]]
        pool = advertised or matches
        pool.sort(key=lambda item: item["refresh"])
        return pool[-1]["mode"]
    for item in matches:
        if item["refresh"] == int(refresh):
            return item["mode"]
    fail(f"{screen['name']} has no {resolution} at {refresh} Hz")
    return ""


def logical_size(screen: dict) -> tuple[float, float]:
    width = float(screen["width"])
    height = float(screen["height"])
    if int(screen.get("transform") or 0) in (1, 3):
        width, height = height, width
    scale = float(screen.get("scale") or 1)
    return width / scale, height / scale


def match_default(screen: dict) -> dict | None:
    model = screen.get("model") or ""
    name = screen.get("name") or ""
    for item in saved_defaults():
        if item["name"] == name or item["match"] in model or name.startswith(item["match"]):
            return item
    return None


def apply_patch(screen: dict, patch: dict) -> None:
    if "scale" in patch and patch["scale"] is not None:
        scale = float(patch["scale"])
        if not 0.5 <= scale <= 3:
            fail(f"scale for {screen['name']} must stay between 0.5 and 3")
        screen["scale"] = scale
    if "transform" in patch and patch["transform"] is not None:
        transform = int(patch["transform"])
        if transform not in (0, 1, 2, 3):
            fail(f"transform for {screen['name']} must be 0, 1, 2, or 3")
        screen["transform"] = transform
    if "vrr" in patch and patch["vrr"] is not None:
        screen["vrr"] = bool(patch["vrr"])
    if "bitdepth" in patch:
        if patch["bitdepth"] in (None, 0, "auto"):
            screen["bitdepth"] = None
        else:
            bitdepth = int(patch["bitdepth"])
            if bitdepth not in (8, 10):
                fail(f"bitdepth for {screen['name']} must be 8 or 10")
            screen["bitdepth"] = bitdepth
    if "x" in patch and patch["x"] is not None:
        screen["x"] = int(round(float(patch["x"])))
    if "y" in patch and patch["y"] is not None:
        screen["y"] = int(round(float(patch["y"])))
    if "brightness" in patch and patch["brightness"] is not None:
        level = int(round(float(patch["brightness"])))
        if not 0 <= level <= 100:
            fail(f"brightness for {screen['name']} must be 0 to 100")
        screen["brightness"] = level
    mode = patch.get("mode")
    if patch.get("resolution"):
        mode = mode_from_resolution(screen, str(patch["resolution"]), patch.get("refresh"))
    elif patch.get("refresh") is not None and not mode:
        resolution = f"{screen['width']}x{screen['height']}"
        mode = mode_from_resolution(screen, resolution, int(patch["refresh"]))
    if mode:
        if not MODE_RE.match(str(mode)):
            fail(f"refusing mode for {screen['name']}: {mode!r}")
        chosen = find_mode(screen, str(mode))
        if chosen is None and mode != "preferred":
            fail(f"{screen['name']} cannot use {mode}")
        screen["mode"] = str(mode)
        if chosen and mode != "preferred":
            screen["width"] = chosen["width"]
            screen["height"] = chosen["height"]
            screen["refresh"] = chosen["refresh"]


def profile_path() -> Path:
    return Path.home() / ".config" / "monitor-play" / "default.json"


def profile_entry(screen: dict) -> dict:
    name = str(screen.get("name") or "")
    model = str(screen.get("model") or "")
    match = "eDP" if name.startswith("eDP") else (model or name)
    return {
        "name": name,
        "match": match,
        "mode": screen.get("mode") or "preferred",
        "x": int(screen.get("x") or 0),
        "y": int(screen.get("y") or 0),
        "scale": float(screen.get("scale") or 1),
        "transform": int(screen.get("transform") or 0),
        "vrr": bool(screen.get("vrr")),
    }


def saved_defaults() -> list[dict]:
    path = profile_path()
    if path.exists():
        try:
            data = json.loads(path.read_text())
            screens = data.get("screens") if isinstance(data, dict) else data
            if isinstance(screens, list) and screens:
                return screens
        except json.JSONDecodeError:
            pass
    return DEFAULTS


def save_profile(screens: list[dict]) -> dict:
    path = profile_path()
    path.parent.mkdir(parents=True, exist_ok=True)
    payload = {"name": "default", "screens": [profile_entry(screen) for screen in screens]}
    path.write_text(json.dumps(payload, indent=2) + "\n")
    return payload


def layout_positions(screens: list[dict], preset: str) -> None:
    if preset == "default":
        for screen in screens:
            chosen = match_default(screen)
            if not chosen:
                continue
            apply_patch(
                screen,
                {
                    "mode": chosen["mode"],
                    "scale": chosen["scale"],
                    "transform": chosen["transform"],
                    "vrr": chosen["vrr"],
                    "x": chosen["x"],
                    "y": chosen["y"],
                    "bitdepth": None,
                },
            )
        return
    laptop = 0
    for index, screen in enumerate(screens):
        if str(screen["name"]).startswith("eDP"):
            laptop = index
            break
    others = [index for index in range(len(screens)) if index != laptop]
    if preset == "laptop-right":
        order = others + [laptop]
    else:
        order = [laptop] + others
    if preset == "stacked":
        cursor = 0
        for index in order:
            screens[index]["x"] = 0
            screens[index]["y"] = int(round(cursor))
            cursor += logical_size(screens[index])[1]
        return
    cursor = 0
    for index in order:
        screens[index]["x"] = int(round(cursor))
        screens[index]["y"] = 0
        cursor += logical_size(screens[index])[0]


def public_screen(screen: dict) -> dict:
    hidden = {"brightnessBus", "brightnessKind", "modes"}
    data = {key: value for key, value in screen.items() if key not in hidden}
    data["modes"] = screen.get("modes") or []
    data["resolutions"] = screen.get("resolutions") or resolutions_of(data["modes"])
    return data


def render(screens: list[dict], gdk_scale: str) -> str:
    lines = [
        "-- Monitor layout written by Monitor Play.",
        "-- Default is the laptop on the left (scale 2) and the Kogan at 3440x1440@100 (scale 1).",
        "-- Restore it with: monitor-play api set '{\"preset\":\"default\"}'",
        "",
        f"local omarchy_gdk_scale = {gdk_scale}",
        'hl.env("GDK_SCALE", tostring(omarchy_gdk_scale))',
        "",
    ]
    for screen in screens:
        if not NAME_RE.match(str(screen["name"])):
            fail(f"refusing monitor name: {screen['name']!r}")
        if not MODE_RE.match(str(screen["mode"])):
            fail(f"refusing mode for {screen['name']}: {screen['mode']!r}")
        lines.append("hl.monitor({")
        lines.append(f"  output = {lua_string(str(screen['name']))},")
        lines.append(f"  mode = {lua_string(str(screen['mode']))},")
        lines.append(f"  position = {lua_string(str(int(screen['x'])) + 'x' + str(int(screen['y'])))},")
        lines.append(f"  scale = {scale_literal(float(screen['scale']))},")
        lines.append(f"  transform = {int(screen.get('transform') or 0)},")
        lines.append(f"  vrr = {1 if screen.get('vrr') else 0},")
        if screen.get("bitdepth") in (8, 10):
            lines.append(f"  bitdepth = {int(screen['bitdepth'])},")
        lines.append("})")
        lines.append("")
    return "\n".join(lines)


def existing_gdk(path: Path) -> str:
    if not path.exists():
        return "2"
    match = re.search(r"omarchy_gdk_scale\s*=\s*([0-9]+(?:\.[0-9]+)?)", path.read_text())
    return match.group(1) if match else "2"


def set_brightness(screen: dict, level: int) -> None:
    kind = screen.get("brightnessKind")
    if kind == "ddc":
        bus = str(screen.get("brightnessBus") or "")
        result = run(["ddcutil", "--bus", bus, "setvcp", "10", str(level)], timeout=6)
        if result.returncode != 0:
            fail((result.stderr or result.stdout or "could not set monitor backlight").strip())
        return
    if kind == "backlight":
        result = run(["brightnessctl", "-d", "intel_backlight", "set", f"{level}%"], timeout=4)
        if result.returncode != 0:
            fail((result.stderr or result.stdout or "could not set laptop backlight").strip())
        return
    fail(f"no backlight control for {screen['name']}")


def mode_matches(screen: dict, actual: dict) -> bool:
    if screen["mode"] == "preferred":
        return not actual.get("disabled")
    width = int(actual.get("width") or 0)
    height = int(actual.get("height") or 0)
    refresh = float(actual.get("refreshRate") or 0)
    return width == int(screen["width"]) and height == int(screen["height"]) and abs(refresh - float(screen["refresh"])) <= 1.5


def commit(screens: list[dict], original: list[dict], dry_run: bool) -> dict:
    path = Path.home() / ".config" / "hypr" / "monitors.lua"
    text = render(screens, existing_gdk(path))
    if dry_run:
        return {"ok": True, "dryRun": True, "lua": text, "screens": [public_screen(s) for s in screens]}

    path.parent.mkdir(parents=True, exist_ok=True)
    backup = path.with_name("monitors.lua.bak.monitor-play")
    previous = path.read_text() if path.exists() else ""
    if path.exists():
        shutil.copy2(path, backup)
    path.write_text(text)
    reload = run(["hyprctl", "reload"], timeout=8)
    if reload.returncode != 0:
        if previous:
            path.write_text(previous)
            run(["hyprctl", "reload"], timeout=8)
        fail((reload.stderr or reload.stdout or "hyprctl reload failed").strip())

    actual = {mon.get("name"): mon for mon in hypr_monitors()}
    for screen in screens:
        live = actual.get(screen["name"])
        if live is None or not mode_matches(screen, live):
            if previous:
                path.write_text(previous)
                run(["hyprctl", "reload"], timeout=8)
            note = ""
            chosen = find_mode(screen, screen["mode"])
            if chosen and chosen.get("note"):
                note = " " + chosen["note"]
            fail(f"{screen['name']} did not accept {screen['mode']}.{note} Restored the previous layout.")

    warnings = []
    original_by_name = {item["name"]: item for item in original}
    for screen in screens:
        before = original_by_name.get(screen["name"]) or {}
        if screen.get("brightness") is None or screen.get("brightness") == before.get("brightness"):
            continue
        if not screen.get("brightnessKind"):
            warnings.append(f"No backlight control for {screen['label']}.")
            continue
        set_brightness(screen, int(screen["brightness"]))
    message = "Applied."
    return {"ok": True, "message": message, "warning": " ".join(warnings), "screens": [public_screen(s) for s in screens]}


def load_request(argv: list[str]) -> dict:
    args = [arg for arg in argv if arg not in ("--dry-run",)]
    dry = "--dry-run" in argv
    raw = args[0] if args else sys.stdin.read()
    if not raw.strip():
        fail("missing json body")
    try:
        data = json.loads(raw)
    except json.JSONDecodeError as exc:
        fail(f"json is not valid: {exc}")
    if isinstance(data, list):
        data = {"screens": data}
    if not isinstance(data, dict):
        fail("json must be an object or a list of screens")
    if dry:
        data["dryRun"] = True
    return data


def resolve_request(request: dict) -> tuple[list[dict], list[dict]]:
    original = read_state()
    screens = [json.loads(json.dumps(screen)) for screen in original]
    by_name = {screen["name"]: screen for screen in screens}
    preset = request.get("preset")
    if preset:
        if preset not in ("default", "laptop-left", "laptop-right", "stacked"):
            fail(f"unknown preset: {preset}")
        layout_positions(screens, preset)
    patches = request.get("screens") or []
    if patches and not isinstance(patches, list):
        fail("screens must be a list")
    for patch in patches:
        if not isinstance(patch, dict) or not patch.get("name"):
            fail("each screen needs a name")
        screen = by_name.get(patch["name"])
        if screen is None:
            fail(f"not connected: {patch['name']}")
        apply_patch(screen, patch)
    if preset in ("laptop-left", "laptop-right", "stacked"):
        layout_positions(screens, preset)
    return screens, original


def emit(payload: dict) -> None:
    print(json.dumps(payload, indent=2))


def recommendation_for(screens: list[dict]) -> dict:
    for screen in screens:
        if str(screen.get("name", "")).startswith("eDP"):
            continue
        return {
            "name": screen["name"],
            "mode": "3440x1440@100" if "KAMN" in (screen.get("model") or "") or screen.get("label") == "Kogan" else screen.get("mode"),
            "fit": "sharp",
            "refresh": 100,
            "also": "2560x1080@144",
            "alsoFit": "softer",
            "reason": "3440x1440 at 100 Hz is the sharp default. 2560x1080 at 144 Hz is the smoother, softer ultrawide mode.",
        }
    return {}


def restore_layout(previous: str, original: list[dict]) -> None:
    path = Path.home() / ".config" / "hypr" / "monitors.lua"
    if previous:
        path.write_text(previous)
        run(["hyprctl", "reload"], timeout=8)
    lights = {item["name"]: item for item in original}
    for screen in read_state():
        before = lights.get(screen["name"]) or {}
        previous_level = before.get("brightness")
        if previous_level is None or screen.get("brightness") == previous_level:
            continue
        if screen.get("brightnessKind"):
            set_brightness(screen, int(previous_level))


def api_main(argv: list[str]) -> None:
    command = argv[0] if argv else "tools"
    rest = argv[1:]
    if command in ("tools", "schema", "help"):
        emit(TOOLS)
        return
    if command == "defaults":
        emit({"ok": True, "defaults": saved_defaults(), "note": "This is your saved profile. Applying it does not change backlight."})
        return
    if command == "get":
        screens = read_state()
        emit({
            "ok": True,
            "confirmed": [
                {
                    "name": screen["name"],
                    "label": screen["label"],
                    "mode": screen["mode"],
                    "width": screen["width"],
                    "height": screen["height"],
                    "confirmedHz": screen.get("confirmedHz"),
                    "scale": screen["scale"],
                    "x": screen["x"],
                    "y": screen["y"],
                }
                for screen in screens
            ],
            "recommendation": recommendation_for(screens),
            "defaults": saved_defaults(),
            "profile": saved_defaults(),
            "screens": [public_screen(screen) for screen in screens],
        })
        return
    if command == "save":
        request = load_request(rest) if rest or not sys.stdin.isatty() else {}
        if request.get("screens") or request.get("preset"):
            screens, original = resolve_request(request)
            result = commit(screens, original, bool(request.get("dryRun")))
        else:
            screens = read_state()
            original = screens
            result = commit(screens, original, False)
        if request.get("dryRun"):
            emit(result)
            return
        profile = save_profile(screens)
        result["message"] = "Saved this layout as your default profile."
        result["profile"] = profile["screens"]
        emit(result)
        return
    if command == "try":
        request = load_request(rest)
        seconds = int(request.get("seconds") or 10)
        seconds = max(1, min(seconds, 30))
        path = Path.home() / ".config" / "hypr" / "monitors.lua"
        previous = path.read_text() if path.exists() else ""
        screens, original = resolve_request(request)
        def restore(*_args):
            restore_layout(previous, original)
        signal.signal(signal.SIGTERM, lambda *_args: (restore(), sys.exit(0)))
        try:
            commit(screens, original, False)
            time.sleep(seconds)
        finally:
            restore()
        emit({"ok": True, "message": f"Trial ended after {seconds} seconds. Restored your layout.", "seconds": seconds})
        return
    if command == "brightness":
        request = load_request(rest)
        _screens, original = resolve_request(request)
        by_name = {screen["name"]: screen for screen in original}
        changed = []
        for patch in request.get("screens") or []:
            screen = by_name.get(patch.get("name"))
            if screen is None or patch.get("brightness") is None:
                continue
            level = int(round(float(patch["brightness"])))
            set_brightness(screen, level)
            changed.append({"name": screen["name"], "brightness": level})
        emit({"ok": True, "message": "Backlight updated.", "screens": changed})
        return
    if command in ("set", "apply"):
        request = load_request(rest)
        screens, original = resolve_request(request)
        if command == "apply" and not request.get("screens"):
            fail("apply needs a screens list")
        emit(commit(screens, original, bool(request.get("dryRun"))))
        return
    fail(f"unknown api command: {command}")


def main(argv: list[str] | None = None) -> None:
    args = list(sys.argv[1:] if argv is None else argv)
    if not args or args[0] in ("-h", "--help"):
        emit(TOOLS)
        return
    if args[0] == "api":
        api_main(args[1:])
        return
    fail("use: monitor-play api get|set|apply|defaults|tools")


if __name__ == "__main__":
    main()
