#!/usr/bin/env python3
"""Lumo's sounds, synthesized from scratch: soft bubbles, marimba and glass chimes, like a
jellyfish under water. No samples and no dependencies — Python's standard library only.

    python3 scripts/gen-sounds.py            # writes NotchBuddy/Resources/sounds/*.wav

The Windows / Linux app plays the same files (windows/vite.config.ts copies them).
Format: 48 kHz, 16-bit, stereo. Each sound keeps the name and the level the app expects.

© 2026 Wolfgang Welcomez (rouderz). The sounds are Lumo's and all rights are reserved
(LICENSE-ASSETS.md); this script is MIT like the rest of the code.
"""

import math
import os
import random
import struct
import wave

RATE = 48000
OUT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "NotchBuddy", "Resources", "sounds")
TAU = 2 * math.pi
rnd = random.Random(7)  # same sounds every run


# ── Building blocks ───────────────────────────────────────────────────────────

def silence(sec):
    return [0.0] * int(sec * RATE)


def mix(dst, src, at=0.0, gain=1.0):
    """Adds src into dst starting at `at` seconds, growing dst if needed."""
    i0 = int(at * RATE)
    if len(dst) < i0 + len(src):
        dst.extend([0.0] * (i0 + len(src) - len(dst)))
    for i, v in enumerate(src):
        dst[i0 + i] += v * gain
    return dst


def env(n, attack, decay_sec):
    """Fast attack, exponential decay."""
    a = max(1, int(attack * RATE))
    k = 1.0 / max(1e-4, decay_sec * RATE)
    return [(i / a) if i < a else math.exp(-(i - a) * k) for i in range(n)]


def marimba(freq, dur=0.5, decay=0.18, bright=0.35):
    """A wooden bar: fundamental plus the 4th partial (~3.9×) that dies fast."""
    n = int(dur * RATE)
    e1, e2 = env(n, 0.002, decay), env(n, 0.001, decay * 0.25)
    return [math.sin(TAU * freq * i / RATE) * e1[i] + bright * math.sin(TAU * freq * 3.93 * i / RATE) * e2[i]
            for i in range(n)]


def glass(freq, dur=0.8, decay=0.35, shimmer=0.0):
    """A glass chime: inharmonic partials, a slow shimmer."""
    n = int(dur * RATE)
    e = env(n, 0.003, decay)
    parts = [(1.0, 1.0), (2.76, 0.32), (5.4, 0.12)]
    out = []
    for i in range(n):
        t = i / RATE
        vib = 1 + shimmer * math.sin(TAU * 5.5 * t)
        out.append(sum(a * math.sin(TAU * freq * r * vib * t) for r, a in parts) * e[i])
    return out


def bloop(f0, f1, dur=0.12, decay=None):
    """A bubble: a sine whose pitch glides from f0 to f1 (exponentially)."""
    n = int(dur * RATE)
    e = env(n, 0.004, decay or dur * 0.35)
    ph, out = 0.0, []
    for i in range(n):
        f = f0 * (f1 / f0) ** (i / n)
        ph += TAU * f / RATE
        out.append(math.sin(ph) * e[i])
    return out


def wobble(f0, f1, dur, rate, depth, decay):
    """A sine with vibrato, gliding from f0 to f1."""
    n = int(dur * RATE)
    e = env(n, 0.01, decay)
    ph, out = 0.0, []
    for i in range(n):
        t = i / RATE
        f = (f0 * (f1 / f0) ** (i / n)) * (1 + depth * math.sin(TAU * rate * t))
        ph += TAU * f / RATE
        out.append((math.sin(ph) + 0.25 * math.sin(2 * ph)) * e[i])
    return out


def noise(dur, cutoff_from, cutoff_to, decay, attack=0.004):
    """Low-passed noise whose cutoff sweeps (a whoosh, a splash, a thump's body)."""
    n = int(dur * RATE)
    e = env(n, attack, decay)
    y, out = 0.0, []
    for i in range(n):
        fc = cutoff_from * (cutoff_to / cutoff_from) ** (i / n)
        a = 1 - math.exp(-TAU * fc / RATE)
        y += a * (rnd.uniform(-1, 1) - y)
        out.append(y * e[i])
    return out


def water(sig, wet=0.22):
    """A small watery room: a few feedback echoes, a little different left and right."""
    left, right = list(sig), list(sig)
    for ch, delays in ((left, (0.023, 0.041, 0.067)), (right, (0.029, 0.047, 0.073))):
        for d, g in zip(delays, (0.55, 0.4, 0.3)):
            k = int(d * RATE)
            for i in range(k, len(ch)):
                ch[i] += sig[i - k] * wet * g
    return left, right


def note(name):
    names = {"C": -9, "D": -7, "E": -5, "F": -4, "G": -2, "A": 0, "B": 2}
    step = names[name[0]] + (1 if "#" in name else 0)
    octave = int(name[-1])
    return 440.0 * 2 ** ((step + 12 * (octave - 4)) / 12)


# ── The sounds ────────────────────────────────────────────────────────────────
# (name, length in seconds, target peak — the level the app was tuned for, builder)

def s_hover():
    return bloop(1900, 2700, 0.06)

def s_tick():
    return marimba(2350, 0.06, 0.012, 0.2)

def s_blip():
    return bloop(950, 1500, 0.09)

def s_open():
    s = silence(0.5)
    mix(s, bloop(500, 900, 0.12), 0.0, 0.6)
    mix(s, marimba(note("C6"), 0.3, 0.09), 0.04)
    mix(s, marimba(note("G6"), 0.35, 0.12), 0.12)
    return s

def s_close():
    s = silence(0.43)
    mix(s, marimba(note("G6"), 0.25, 0.08), 0.0)
    mix(s, marimba(note("C6"), 0.3, 0.1), 0.09)
    mix(s, bloop(800, 420, 0.12), 0.1, 0.5)
    return s

def s_peek():
    s = silence(0.45)
    mix(s, bloop(480, 1100, 0.14), 0.0)
    mix(s, glass(note("G6"), 0.3, 0.09), 0.08, 0.5)
    return s

def s_pop():
    s = silence(0.38)
    mix(s, bloop(320, 1400, 0.05, 0.02), 0.0)
    mix(s, noise(0.03, 6000, 2000, 0.008), 0.035, 0.6)
    mix(s, bloop(1300, 1700, 0.08), 0.05, 0.3)
    return s

def s_send():
    s = silence(0.48)
    mix(s, noise(0.3, 400, 5000, 0.09, 0.08), 0.0, 0.8)
    mix(s, bloop(700, 1500, 0.12), 0.2)
    return s

def s_attach():
    s = silence(0.9)
    mix(s, bloop(300, 700, 0.12), 0.0)
    mix(s, bloop(450, 950, 0.12), 0.1)
    for i, n in enumerate(("E6", "G#6", "B6")):
        mix(s, glass(note(n), 0.55, 0.16), 0.22 + 0.05 * i, 0.45)
    return s

def s_gulp():
    s = silence(0.75)
    mix(s, bloop(260, 140, 0.18, 0.08), 0.05)
    mix(s, bloop(230, 110, 0.2, 0.09), 0.3)
    mix(s, noise(0.08, 900, 300, 0.03), 0.3, 0.25)
    return s

def s_greet():
    s = silence(0.75)
    for i, n in enumerate(("C6", "E6", "G6", "C7")):
        mix(s, marimba(note(n), 0.4, 0.13), 0.08 * i)
    mix(s, bloop(600, 1200, 0.1), 0.38, 0.4)
    mix(s, bloop(900, 1700, 0.08), 0.48, 0.3)
    return s

def s_approval():
    s = silence(0.88)
    for k in (0.0, 0.34):
        mix(s, glass(note("A5"), 0.35, 0.1), k)
        mix(s, glass(note("E6"), 0.4, 0.13), k + 0.11)
    return s

def s_approve():
    s = silence(0.6)
    mix(s, marimba(note("E6"), 0.3, 0.09), 0.0)
    mix(s, glass(note("B6"), 0.5, 0.15), 0.08)
    return s

def s_question():
    s = silence(0.7)
    mix(s, bloop(note("G5"), note("D6"), 0.22, 0.12), 0.0)
    mix(s, glass(note("D6"), 0.45, 0.14, 0.004), 0.2, 0.7)
    return s

def s_error():
    s = silence(0.84)
    mix(s, wobble(note("E4"), note("E4") * 0.97, 0.3, 6, 0.01, 0.12), 0.0)
    mix(s, wobble(note("C4"), note("C4") * 0.94, 0.5, 5, 0.012, 0.2), 0.22)
    return s

def s_finish():
    s = silence(1.16)
    for i, n in enumerate(("C6", "E6", "G6", "C7")):
        mix(s, marimba(note(n), 0.5, 0.16), 0.07 * i)
    for i, n in enumerate(("G6", "C7", "E7")):
        mix(s, glass(note(n), 0.7, 0.22, 0.003), 0.32 + 0.06 * i, 0.4)
    return s

def s_proud():
    s = silence(0.86)
    for n in ("C6", "E6", "G6"):
        mix(s, marimba(note(n), 0.5, 0.18), 0.0, 0.7)
    for i, f in enumerate((2600, 3100, 3700)):
        mix(s, glass(f, 0.3, 0.07), 0.25 + 0.07 * i, 0.25)
    return s

def s_love():
    s = silence(0.79)
    mix(s, glass(note("E6"), 0.4, 0.14, 0.006), 0.0)
    mix(s, glass(note("A6"), 0.55, 0.18, 0.006), 0.18)
    return s

def s_wink():
    s = silence(0.21)
    mix(s, marimba(note("B6"), 0.1, 0.03), 0.0, 0.6)
    mix(s, marimba(note("E7"), 0.12, 0.04), 0.05)
    return s

def s_annoyed():
    s = silence(0.59)
    mix(s, wobble(330, 250, 0.22, 14, 0.03, 0.1), 0.0)
    mix(s, wobble(300, 210, 0.3, 12, 0.03, 0.12), 0.2)
    return s

def s_dizzy():
    s = silence(0.98)
    mix(s, wobble(900, 380, 0.95, 7, 0.08, 0.4), 0.0)
    mix(s, bloop(700, 1300, 0.08), 0.1, 0.25)
    mix(s, bloop(650, 1200, 0.08), 0.45, 0.2)
    return s

def s_rate():
    s = silence(0.67)
    mix(s, marimba(note("A5"), 0.3, 0.12), 0.0)
    mix(s, marimba(note("F5"), 0.4, 0.16), 0.18)
    mix(s, bloop(400, 260, 0.15), 0.35, 0.3)
    return s

def s_search():
    s = silence(0.46)
    ping = glass(1320, 0.4, 0.07)
    mix(s, ping, 0.0)
    mix(s, ping, 0.16, 0.35)
    return s

def s_think():
    s = silence(0.44)
    for i, (a, b) in enumerate(((520, 760), (600, 880), (680, 990))):
        mix(s, bloop(a, b, 0.07), 0.11 * i, 0.8 - 0.15 * i)
    return s

def s_work():
    s = silence(0.38)
    mix(s, marimba(1700, 0.08, 0.02, 0.3), 0.0)
    mix(s, marimba(2050, 0.08, 0.02, 0.3), 0.09)
    return s

def s_slap():
    s = silence(0.6)
    mix(s, bloop(190, 60, 0.12, 0.05), 0.0)
    mix(s, noise(0.06, 3000, 600, 0.015), 0.0, 0.7)
    mix(s, wobble(520, 600, 0.4, 16, 0.06, 0.12), 0.08, 0.5)
    return s

def s_sleep():
    s = silence(0.45)
    mix(s, wobble(440, 300, 0.42, 3, 0.01, 0.18), 0.0)
    return s

def s_yawn():
    s = silence(0.73)
    mix(s, wobble(300, 470, 0.32, 4, 0.01, 0.4), 0.0)
    mix(s, wobble(470, 240, 0.4, 4, 0.012, 0.16), 0.3)
    return s


SOUNDS = [
    ("annoyed", 0.27, s_annoyed), ("approval", 0.52, s_approval), ("approve", 0.21, s_approve),
    ("attach", 0.34, s_attach), ("blip", 0.04, s_blip), ("close", 0.07, s_close), ("dizzy", 0.27, s_dizzy),
    ("error", 0.50, s_error), ("finish", 0.63, s_finish), ("greet", 0.47, s_greet), ("gulp", 0.43, s_gulp),
    ("hover", 0.02, s_hover), ("love", 0.26, s_love), ("open", 0.08, s_open), ("peek", 0.15, s_peek),
    ("pop", 0.09, s_pop), ("proud", 0.48, s_proud), ("question", 0.30, s_question), ("rate", 0.24, s_rate),
    ("search", 0.15, s_search), ("send", 0.10, s_send), ("slap", 0.21, s_slap), ("sleep", 0.06, s_sleep),
    ("think", 0.16, s_think), ("tick", 0.02, s_tick), ("wink", 0.05, s_wink), ("work", 0.10, s_work),
    ("yawn", 0.11, s_yawn),
]


def write(name, peak, sig):
    sig = sig + silence(0.08)  # room for the echoes
    left, right = water(sig)
    top = max(1e-9, max(max(abs(v) for v in left), max(abs(v) for v in right)))
    g = peak / top
    fade = int(0.01 * RATE)
    n = len(left)
    frames = bytearray()
    for i in range(n):
        f = min(1.0, (n - 1 - i) / fade)  # no click at the end
        frames += struct.pack("<hh", int(left[i] * g * f * 32767), int(right[i] * g * f * 32767))
    with wave.open(os.path.join(OUT, name + ".wav"), "wb") as w:
        w.setnchannels(2)
        w.setsampwidth(2)
        w.setframerate(RATE)
        w.writeframes(bytes(frames))


if __name__ == "__main__":
    for name, peak, build in SOUNDS:
        write(name, peak, build())
        print("✓", name)
