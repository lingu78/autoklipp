#!/usr/bin/env python3
"""Generates Autoklipp's built-in music library.

Every track is synthesised from scratch by this script (drums, bass, chords, arpeggios and
melodies built from simple oscillators, FM and plucked-string models), so the music has no
third-party rights attached. The output is dedicated to the public domain (CC0) and documented
in LICENSES/music.md.

Because the script writes every note itself, the exact beat grid, loop region and song sections
are known and stored in tracks.json; the app does not need to detect beats for these tracks.

Usage:
    python3 tools/music/generate_music.py [--only ID ...] [--out DIR]

Requires numpy and ffmpeg (AAC encoder). Output is deterministic for a given numpy version.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import subprocess
import sys
import tempfile
import wave

import numpy as np

SR = 44100
BEATS_PER_BAR = 4

# Song form shared by all tracks: (section, bars, energy 0..1).
FORM = [
    ("intro", 4, 0.25),
    ("verse", 8, 0.5),
    ("chorus", 8, 0.85),
    ("verse", 8, 0.55),
    ("chorus", 8, 0.9),
    ("bridge", 8, 0.4),
    ("chorus", 8, 0.95),
    ("outro", 4, 0.3),
]

MAJOR = [0, 2, 4, 5, 7, 9, 11]
MINOR = [0, 2, 3, 5, 7, 8, 10]

# Each track: tempo, key, progressions (scale degrees, 0-based), arrangement template.
TRACKS = [
    dict(id="morgondimma", title="Morgondimma", bpm=72, root=62, scale="major",
         verse=[0, 5, 3, 4], chorus=[3, 4, 0, 5], template="calm_keys", styles=["calm"]),
    dict(id="stilla-vatten", title="Stilla vatten", bpm=84, root=57, scale="major",
         verse=[0, 3, 5, 4], chorus=[3, 0, 4, 5], template="calm_pluck", styles=["calm"]),
    dict(id="full-fart", title="Full fart", bpm=128, root=57, scale="minor",
         verse=[0, 5, 2, 6], chorus=[5, 6, 0, 0], template="edm", styles=["energetic"]),
    dict(id="ljusar", title="Ljusår", bpm=124, root=60, scale="major",
         verse=[5, 3, 0, 4], chorus=[3, 4, 5, 0], template="house", styles=["energetic"]),
    dict(id="hoppborg", title="Hoppborg", bpm=132, root=65, scale="major",
         verse=[0, 4, 5, 3], chorus=[0, 4, 5, 3], template="pop", styles=["energetic", "travel"]),
    dict(id="gamla-foton", title="Gamla foton", bpm=86, root=63, scale="major",
         verse=[1, 4, 0, 5], chorus=[3, 2, 1, 4], template="lofi", styles=["nostalgic"]),
    dict(id="sommaren-da", title="Sommaren då", bpm=92, root=55, scale="major",
         verse=[0, 3, 0, 4], chorus=[3, 0, 4, 5], template="folk", styles=["nostalgic", "calm"]),
    dict(id="sommarvind", title="Sommarvind", bpm=104, root=55, scale="major",
         verse=[0, 4, 5, 3], chorus=[3, 4, 0, 5], template="folk_pop", styles=["travel"]),
    dict(id="vagen-soderut", title="Vägen söderut", bpm=112, root=62, scale="major",
         verse=[0, 3, 4, 3], chorus=[5, 3, 0, 4], template="drive", styles=["travel", "energetic"]),
    dict(id="horisont", title="Horisont", bpm=98, root=58, scale="major",
         verse=[0, 2, 3, 4], chorus=[3, 4, 2, 5], template="travel_pad", styles=["travel", "cinematic"]),
    dict(id="fjallvidd", title="Fjällvidd", bpm=76, root=50, scale="minor",
         verse=[0, 5, 2, 6], chorus=[5, 2, 6, 4], template="cinematic", styles=["cinematic"]),
    dict(id="ljuset-faller", title="Ljuset faller", bpm=90, root=60, scale="minor",
         verse=[0, 3, 5, 4], chorus=[5, 6, 2, 4], template="cinematic_pulse", styles=["cinematic", "nostalgic"]),
]

# Which parts play, by template; drum pattern names refer to DRUM_PATTERNS.
TEMPLATES = {
    "calm_keys": dict(drums="soft", bass="half", keys="epiano", arp="epiano8", pad=True, lead="bell"),
    "calm_pluck": dict(drums="soft", bass="half", keys=None, arp="pluck8", pad=True, lead="flute"),
    "edm": dict(drums="four", bass="offbeat", keys="stab", arp="saw16", pad=True, lead="saw"),
    "house": dict(drums="four", bass="offbeat", keys="epiano_stab", arp="bell16", pad=True, lead="bell"),
    "pop": dict(drums="pop", bass="eighths", keys=None, arp="pluck16", pad=True, lead="square"),
    "lofi": dict(drums="lofi", bass="half", keys="epiano", arp=None, pad=False, lead="epiano_lead", lofi=True),
    "folk": dict(drums="pop_soft", bass="half", keys=None, arp="pluck8", pad=True, lead="flute"),
    "folk_pop": dict(drums="pop", bass="eighths", keys=None, arp="pluck8", pad=True, lead="flute"),
    "drive": dict(drums="pop", bass="eighths", keys=None, arp="pluck16", pad=True, lead="square"),
    "travel_pad": dict(drums="halftime", bass="half", keys=None, arp="bell8", pad=True, lead="flute"),
    "cinematic": dict(drums="toms", bass="whole", keys=None, arp="pluck8", pad=True, lead="bell", strings=True),
    "cinematic_pulse": dict(drums="toms", bass="pulse", keys=None, arp="bell16", pad=True, lead="flute", strings=True),
}

# 16-step patterns per bar: letters are hits. k=kick s=snare c=clap h=hat o=open hat r=rim
# t=low tom T=high tom x=shaker.
DRUM_PATTERNS = {
    "four": {"k": "x...x...x...x...", "c": "....x.......x...", "h": "..x...x...x...x.", "o": "..x...x...x...x."},
    "pop": {"k": "x.....x.x.......", "s": "....x.......x...", "h": "x.x.x.x.x.x.x.x.", "x": "xxxxxxxxxxxxxxxx"},
    "pop_soft": {"k": "x.......x.......", "r": "....x.......x...", "x": "x.x.x.x.x.x.x.x."},
    "soft": {"k": "x.......x.......", "r": "....x.......x...", "h": "..x...x...x...x."},
    "lofi": {"k": "x......x..x.....", "s": "....x.......x...", "h": "x.x.x.x.x.x.x.x."},
    "halftime": {"k": "x.........x.....", "s": "........x.......", "h": "x.x.x.x.x.x.x.x.", "x": "..x...x...x...x."},
    "toms": {"k": "x.......x.......", "t": "x.....x...x.....", "T": "............x.x."},
}


def hz(midi: float) -> float:
    return 440.0 * 2 ** ((midi - 69) / 12)


def seconds(n: int) -> np.ndarray:
    return np.arange(n) / SR


def fade(sig: np.ndarray, attack: float = 0.005, release: float = 0.03) -> np.ndarray:
    n = len(sig)
    a = min(n, max(1, int(attack * SR)))
    r = min(n, max(1, int(release * SR)))
    env = np.ones(n)
    env[:a] = np.linspace(0, 1, a)
    env[n - r:] *= np.linspace(1, 0, r)
    return sig * env


def fft_filter(sig: np.ndarray, low: float | None = None, high: float | None = None, order: int = 2) -> np.ndarray:
    """Zero-phase Butterworth-shaped filter applied in the frequency domain."""
    n = len(sig)
    if n == 0:
        return sig
    spec = np.fft.rfft(sig)
    freqs = np.fft.rfftfreq(n, 1 / SR)
    resp = np.ones_like(freqs)
    if high:
        resp /= np.sqrt(1 + (freqs / high) ** (2 * order))
    if low:
        resp /= np.sqrt(1 + (low / np.maximum(freqs, 1e-3)) ** (2 * order))
    return np.fft.irfft(spec * resp, n)


# ---------------------------------------------------------------- instruments

class Kit:
    """One-shot drum samples, synthesised once per track."""

    def __init__(self, rng: np.random.Generator, lofi: bool = False):
        self.samples = {}
        n = int(0.5 * SR)
        t = seconds(n)
        freq = 45 + 85 * np.exp(-t / 0.03)
        phase = 2 * np.pi * np.cumsum(freq) / SR
        kick = np.sin(phase) * np.exp(-t / 0.28)
        kick[: int(0.003 * SR)] += rng.uniform(-0.6, 0.6, int(0.003 * SR))
        self.samples["k"] = np.tanh(1.6 * kick)

        n = int(0.35 * SR)
        t = seconds(n)
        noise = fft_filter(rng.uniform(-1, 1, n), low=1200, high=7000) * np.exp(-t / 0.11)
        tone = np.sin(2 * np.pi * 185 * t) * np.exp(-t / 0.07)
        self.samples["s"] = 0.8 * noise / np.max(np.abs(noise)) + 0.5 * tone

        clap = np.zeros(n)
        for offset in (0, 0.011, 0.022):
            start = int(offset * SR)
            burst = rng.uniform(-1, 1, n - start) * np.exp(-seconds(n - start) / (0.012 if offset < 0.02 else 0.16))
            clap[start:] += burst
        clap = fft_filter(clap, low=900, high=4000)
        self.samples["c"] = clap / np.max(np.abs(clap))

        n = int(0.12 * SR)
        hat = fft_filter(rng.uniform(-1, 1, n), low=7000) * np.exp(-seconds(n) / 0.03)
        self.samples["h"] = hat / np.max(np.abs(hat))
        n = int(0.4 * SR)
        open_hat = fft_filter(rng.uniform(-1, 1, n), low=6500) * np.exp(-seconds(n) / 0.16)
        self.samples["o"] = open_hat / np.max(np.abs(open_hat))
        n = int(0.09 * SR)
        shaker = fft_filter(rng.uniform(-1, 1, n), low=5000, high=12000)
        shaker *= np.minimum(1, seconds(n) / 0.012) * np.exp(-seconds(n) / 0.035)
        self.samples["x"] = shaker / np.max(np.abs(shaker))
        n = int(0.1 * SR)
        t = seconds(n)
        rim = np.sin(2 * np.pi * 820 * t) * np.exp(-t / 0.012) + 0.4 * fft_filter(rng.uniform(-1, 1, n), low=2000) * np.exp(-t / 0.01)
        self.samples["r"] = rim / np.max(np.abs(rim))
        for name, base in (("t", 80), ("T", 130)):
            n = int(0.9 * SR)
            t = seconds(n)
            f = base * (1 + 0.5 * np.exp(-t / 0.05))
            tom = np.sin(2 * np.pi * np.cumsum(f) / SR) * np.exp(-t / 0.45)
            tom += 0.15 * fft_filter(rng.uniform(-1, 1, n), high=1500) * np.exp(-t / 0.05)
            self.samples[name] = np.tanh(1.3 * tom)
        if lofi:
            for key in self.samples:
                self.samples[key] = fft_filter(self.samples[key], high=5500)


def pluck(freq: float, dur: float, rng: np.random.Generator, brightness: float = 0.5) -> np.ndarray:
    """Karplus-Strong plucked string, processed one period at a time."""
    n = int(dur * SR)
    period = max(2, int(round(SR / freq)))
    out = np.zeros(n + period)
    excitation = rng.uniform(-1, 1, period)
    if brightness < 1:
        excitation = np.convolve(excitation, np.ones(3) / 3, mode="same") * (1 - brightness) + excitation * brightness
    out[:period] = excitation
    decay = 0.996 if freq < 300 else 0.993
    index = period
    while index < n + period:
        end = min(index + period, n + period)
        current = out[index - period:end - period]
        previous = out[index - period - 1:end - period - 1] if index - period - 1 >= 0 else np.concatenate(([0.0], out[:end - period - 1]))
        out[index:end] = decay * 0.5 * (current + previous)
        index = end
    return fade(out[period:period + n], 0.001, 0.05)


def epiano(freq: float, dur: float) -> np.ndarray:
    n = int(dur * SR)
    t = seconds(n)
    index = 1.6 * np.exp(-t / 0.45) + 0.25
    carrier = np.sin(2 * np.pi * freq * t + index * np.sin(2 * np.pi * freq * t))
    tine = 0.12 * np.sin(2 * np.pi * freq * 7 * t) * np.exp(-t / 0.06)
    return fade((carrier + tine) * np.exp(-t / 1.4), 0.003, 0.08)


def bell(freq: float, dur: float) -> np.ndarray:
    n = int(dur * SR)
    t = seconds(n)
    carrier = np.sin(2 * np.pi * freq * t + 2.2 * np.exp(-t / 0.4) * np.sin(2 * np.pi * freq * 3.5 * t))
    return fade(carrier * np.exp(-t / 0.9), 0.002, 0.08)


def additive(freq: float, n: int, harmonics: int, rolloff: float = 1.0, odd_only: bool = False, detune: float = 0.0) -> np.ndarray:
    t = seconds(n)
    out = np.zeros(n)
    limit = int(min(harmonics, (SR / 2 - 500) / max(freq, 1)))
    for k in range(1, max(1, limit) + 1):
        if odd_only and k % 2 == 0:
            continue
        out += np.sin(2 * np.pi * freq * (1 + detune) * k * t) / (k ** rolloff)
    return out


def saw(freq: float, dur: float, voices: int = 3, cents: float = 8) -> np.ndarray:
    n = int(dur * SR)
    out = np.zeros(n)
    for v in range(voices):
        offset = (v - (voices - 1) / 2) * cents / 1200
        out += additive(freq * 2 ** offset, n, 24)
    return out / voices


def square(freq: float, dur: float) -> np.ndarray:
    return additive(freq, int(dur * SR), 15, odd_only=True)


def flute(freq: float, dur: float) -> np.ndarray:
    n = int(dur * SR)
    t = seconds(n)
    vibrato = 1 + 0.004 * np.sin(2 * np.pi * 5 * t) * np.minimum(1, t / 0.3)
    phase = 2 * np.pi * freq * np.cumsum(vibrato) / SR
    tone = np.sin(phase) + 0.25 * np.sin(2 * phase) + 0.08 * np.sin(3 * phase)
    breath = 0.03 * np.random.default_rng(int(freq)).uniform(-1, 1, n)
    return fade(tone + fft_filter(breath, low=1500, high=6000), 0.04, 0.1)


def pad_chord(freqs: list[float], dur: float, bright: float = 1800) -> np.ndarray:
    n = int(dur * SR)
    out = np.zeros(n)
    for f in freqs:
        out += saw(f, dur, voices=3, cents=10)
    out = fft_filter(out, high=bright, order=2)
    return fade(out / max(1, len(freqs)), 0.35, 0.5)


def strings_chord(freqs: list[float], dur: float) -> np.ndarray:
    n = int(dur * SR)
    t = seconds(n)
    out = np.zeros(n)
    for i, f in enumerate(freqs):
        vibrato = 1 + 0.003 * np.sin(2 * np.pi * (5 + 0.3 * i) * t)
        phase = 2 * np.pi * f * np.cumsum(vibrato) / SR
        out += sum(np.sin(k * phase) / k for k in range(1, 8))
    return fade(fft_filter(out / len(freqs), high=3000), 0.6, 0.8)


def bass_note(freq: float, dur: float, kind: str) -> np.ndarray:
    n = int(dur * SR)
    t = seconds(n)
    if kind == "saw":
        tone = fft_filter(saw(freq, dur, voices=1), high=900)
    else:
        tone = np.sin(2 * np.pi * freq * t) + 0.35 * np.sin(4 * np.pi * freq * t)
    return fade(np.tanh(1.4 * tone), 0.006, 0.05)


# ---------------------------------------------------------------- composition

class Mixer:
    def __init__(self, length: float):
        size = int((length + 4) * SR)
        self.dry = np.zeros((2, size))
        self.wet = np.zeros((2, size))

    def add(self, sig: np.ndarray, time: float, gain: float = 1.0, pan: float = 0.0, send: float = 0.0):
        start = int(round(time * SR))
        if start >= self.dry.shape[1] or len(sig) == 0:
            return
        end = min(self.dry.shape[1], start + len(sig))
        part = sig[: end - start] * gain
        angle = (pan + 1) * math.pi / 4
        left, right = math.cos(angle) * math.sqrt(2), math.sin(angle) * math.sqrt(2)
        self.dry[0, start:end] += part * left
        self.dry[1, start:end] += part * right
        if send:
            self.wet[0, start:end] += part * left * send
            self.wet[1, start:end] += part * right * send


def chord_notes(root: int, scale: list[int], degree: int, octave_shift: int = 0, sevenths: bool = False) -> list[int]:
    notes = []
    count = 4 if sevenths else 3
    for step in range(count):
        index = degree + 2 * step
        octave, position = divmod(index, 7)
        notes.append(root + 12 * (octave + octave_shift) + scale[position])
    return notes


def reverb(signal: np.ndarray, rng: np.random.Generator, seconds_long: float = 2.2, decay: float = 0.45) -> np.ndarray:
    n = int(seconds_long * SR)
    t = seconds(n)
    out = np.zeros_like(signal)
    for channel in range(2):
        ir = rng.uniform(-1, 1, n) * np.exp(-t / decay)
        ir[: int(0.02 * SR)] = 0
        ir = fft_filter(ir, high=5000)
        ir /= np.sqrt(np.sum(ir ** 2))
        size = 1 << int(math.ceil(math.log2(signal.shape[1] + n)))
        conv = np.fft.irfft(np.fft.rfft(signal[channel], size) * np.fft.rfft(ir, size), size)
        out[channel] = conv[: signal.shape[1]]
    return out


def melody_for(progression: list[int], root: int, scale: list[int], rng: np.random.Generator, bars: int) -> list[tuple[float, float, int]]:
    """Two-bar motif, repeated with the notes bent towards each bar's chord."""
    rhythm_options = [
        [(0, 1), (1, 0.5), (1.5, 0.5), (2, 1.5), (3.5, 0.5)],
        [(0, 1.5), (1.5, 0.5), (2, 1), (3, 1)],
        [(0, 0.5), (0.5, 0.5), (1, 1), (2, 0.5), (2.5, 1.5)],
        [(0, 2), (2, 1), (3, 0.5), (3.5, 0.5)],
    ]
    motif = []
    for bar in range(2):
        rhythm = rhythm_options[int(rng.integers(len(rhythm_options)))]
        for start, length in rhythm:
            motif.append((bar * 4 + start, length, int(rng.integers(0, 5))))
    events = []
    for bar in range(0, bars, 2):
        for beat, length, step in motif:
            bar_index = bar + int(beat // 4)
            if bar_index >= bars:
                continue
            chord = chord_notes(root + 12, scale, progression[bar_index % len(progression)])
            pool = chord + [chord[0] + 12, chord[1] + 12]
            note = pool[step % len(pool)]
            events.append((bar * 4 + beat, length, note))
    return events


def render_track(spec: dict) -> tuple[np.ndarray, dict]:
    rng = np.random.default_rng(sum(map(ord, spec["id"])) * 7919)
    template = TEMPLATES[spec["template"]]
    scale = MAJOR if spec["scale"] == "major" else MINOR
    beat = 60.0 / spec["bpm"]
    bar_len = beat * BEATS_PER_BAR
    total_bars = sum(bars for _, bars, _ in FORM)
    length = total_bars * bar_len
    mixer = Mixer(length)
    kit = Kit(rng, lofi=template.get("lofi", False))
    root = spec["root"]

    sections = []
    bar = 0
    for name, bars, energy in FORM:
        start = bar * bar_len
        progression = spec["chorus"] if name == "chorus" else spec["verse"]
        sections.append(dict(name=name, start=round(start, 6), end=round(start + bars * bar_len, 6), energy=energy))
        melody = melody_for(progression, root, scale, rng, bars) if name == "chorus" else []
        for local_bar in range(bars):
            t0 = (bar + local_bar) * bar_len
            degree = progression[local_bar % len(progression)]
            chord = chord_notes(root, scale, degree)
            last_bar_of_song = name == "outro" and local_bar == bars - 1

            # Drums
            pattern = DRUM_PATTERNS[template["drums"]]
            for voice, steps in pattern.items():
                if name in ("intro", "outro") and voice not in ("h", "x", "r"):
                    continue
                if name == "bridge" and voice in ("s", "c", "o"):
                    continue
                if name == "verse" and voice in ("o",) and energy < 0.6:
                    continue
                for step, symbol in enumerate(steps):
                    if symbol == ".":
                        continue
                    swing = 0.0
                    if template.get("lofi") and step % 2 == 1:
                        swing = beat * 0.08
                    time = t0 + step * beat / 4 + swing
                    gain = {"k": 0.95, "s": 0.55, "c": 0.5, "h": 0.18, "o": 0.16, "x": 0.12, "r": 0.35, "t": 0.6, "T": 0.45}[voice]
                    if voice in ("h", "x") and step % 4 != 0:
                        gain *= 0.7
                    pan = {"h": 0.3, "o": 0.3, "x": -0.35, "T": 0.25, "t": -0.15}.get(voice, 0.0)
                    if last_bar_of_song and step > 0:
                        continue
                    mixer.add(kit.samples[voice], time, gain * (0.7 + 0.3 * energy), pan, send=0.12 if voice in ("s", "c", "r", "t", "T") else 0.02)
            # Chorus crash-like open hat at the first bar.
            if name == "chorus" and local_bar == 0:
                mixer.add(kit.samples["o"], t0, 0.35, 0.2, 0.2)

            # Bass
            bass_root = hz(root - 24 + scale[degree % 7] + 12 * (degree // 7))
            style = template["bass"]
            if name != "intro":
                if style == "half":
                    for half in range(2):
                        mixer.add(bass_note(bass_root, beat * 2 * 0.95, "sine"), t0 + half * 2 * beat, 0.55)
                elif style == "whole":
                    mixer.add(bass_note(bass_root, bar_len * 0.98, "sine"), t0, 0.6)
                elif style == "eighths":
                    for e in range(8):
                        mixer.add(bass_note(bass_root, beat * 0.45, "sine"), t0 + e * beat / 2, 0.45 if e % 2 else 0.55)
                elif style == "offbeat":
                    for q in range(4):
                        mixer.add(bass_note(bass_root, beat * 0.4, "saw"), t0 + q * beat + beat / 2, 0.5)
                elif style == "pulse":
                    for s16 in range(16):
                        mixer.add(bass_note(bass_root, beat * 0.2, "saw"), t0 + s16 * beat / 4, 0.3 + 0.1 * (s16 % 4 == 0))

            # Pads and strings
            if template.get("pad"):
                freqs = [hz(n) for n in chord]
                gain = 0.22 if name in ("chorus", "bridge") else 0.16
                mixer.add(pad_chord(freqs, bar_len + 0.4), t0, gain, 0.0, send=0.5)
            if template.get("strings") and name in ("chorus", "bridge", "outro"):
                freqs = [hz(n + 12) for n in chord]
                mixer.add(strings_chord(freqs, bar_len + 0.6), t0, 0.12, 0.0, send=0.6)

            # Keys
            keys = template.get("keys")
            if keys == "epiano":
                for half in range(2):
                    for i, note in enumerate(chord):
                        mixer.add(epiano(hz(note), beat * 2.2), t0 + half * 2 * beat + i * 0.012, 0.16, -0.2 + 0.2 * i, send=0.3)
            elif keys in ("stab", "epiano_stab") and name not in ("intro", "outro"):
                for q in (0.5, 1.5, 2.5, 3.5) if keys == "stab" else (0.5, 1.75, 2.5):
                    for i, note in enumerate(chord):
                        voice = saw(hz(note + 12), beat * 0.35, voices=2) if keys == "stab" else epiano(hz(note + 12), beat * 0.6)
                        mixer.add(fade(voice, 0.002, 0.04), t0 + q * beat, 0.07 if keys == "stab" else 0.12, 0.15 * (i - 1), send=0.25)

            # Arpeggio
            arp = template.get("arp")
            if arp and not (name == "bridge" and energy < 0.45 and arp.endswith("16")):
                per_beat = 4 if arp.endswith("16") else 2
                notes = chord + [chord[0] + 12]
                order = [0, 1, 2, 3, 2, 1, 0, 2]
                for step in range(4 * per_beat):
                    note = notes[order[step % len(order)] % len(notes)] + 12
                    time = t0 + step * beat / per_beat
                    dur = beat / per_beat * 1.8
                    if arp.startswith("pluck"):
                        voice = pluck(hz(note), dur + 0.6, rng)
                        gain = 0.32
                    elif arp.startswith("epiano"):
                        voice = epiano(hz(note), dur + 0.4)
                        gain = 0.14
                    elif arp.startswith("bell"):
                        voice = bell(hz(note + 12), dur + 0.6)
                        gain = 0.1
                    else:
                        voice = fade(fft_filter(saw(hz(note), dur, voices=2), high=2500), 0.003, 0.03)
                        gain = 0.07
                    if name == "intro":
                        gain *= 0.7
                    mixer.add(voice, time, gain, 0.35 if step % 2 else -0.35, send=0.25)

        # Lead melody in choruses
        lead = template.get("lead")
        for beat_pos, dur, note in melody:
            time = bar * bar_len + beat_pos * beat
            d = dur * beat
            if lead == "bell":
                voice, gain = bell(hz(note + 12), d + 0.8), 0.16
            elif lead == "flute":
                voice, gain = flute(hz(note + 12), d * 0.95), 0.16
            elif lead == "square":
                voice, gain = fade(fft_filter(square(hz(note + 12), d * 0.9), high=3500), 0.01, 0.05), 0.07
            elif lead == "saw":
                voice, gain = fade(fft_filter(saw(hz(note + 12), d * 0.9), high=4000), 0.01, 0.05), 0.07
            else:
                voice, gain = epiano(hz(note + 12), d + 0.5), 0.2
            mixer.add(voice, time, gain, 0.1, send=0.35)
        bar += bars

    # Effects and mastering
    wet = reverb(mixer.wet, rng)
    mix = mixer.dry + 0.9 * wet
    if template.get("lofi"):
        mix = np.vstack([fft_filter(mix[0], high=6500), fft_filter(mix[1], high=6500)])
        crackle = np.zeros(mix.shape[1])
        positions = rng.integers(0, mix.shape[1], int(mix.shape[1] / SR * 6))
        crackle[positions] = rng.uniform(-0.25, 0.25, len(positions))
        mix += 0.15 * fft_filter(crackle, low=1500)
        mix += 0.004 * fft_filter(rng.uniform(-1, 1, mix.shape[1]), high=3000)
    # Fade the ending and cut to whole bars plus the reverb tail.
    end = int((length + 2.0) * SR)
    mix = mix[:, :end]
    tail = int(2.0 * SR)
    mix[:, -tail:] *= np.linspace(1, 0, tail) ** 2
    rms = np.sqrt(np.mean(mix ** 2))
    mix *= 10 ** (-16 / 20) / max(rms, 1e-9)
    mix = np.tanh(mix * 1.2) / np.tanh(1.2)
    mix *= 10 ** (-1 / 20) / max(np.max(np.abs(mix)), 1e-9)

    beats = [round(i * beat, 6) for i in range(int(round(length / beat)))]
    loop_start = sections[1]["start"]
    loop_end = sections[-2]["end"]
    info = dict(
        id=spec["id"],
        title=spec["title"],
        file=f"{spec['id']}.m4a",
        bpm=spec["bpm"],
        duration=round(mix.shape[1] / SR, 6),
        firstBeat=0.0,
        beatCount=len(beats),
        loopStart=loop_start,
        loopEnd=loop_end,
        sections=[dict(start=s["start"], end=s["end"], energy=s["energy"]) for s in sections],
        styles=spec["styles"],
    )
    return mix, info


def write_wav(path: str, mix: np.ndarray):
    data = (np.clip(mix.T, -1, 1) * 32767).astype("<i2")
    with wave.open(path, "wb") as handle:
        handle.setnchannels(2)
        handle.setsampwidth(2)
        handle.setframerate(SR)
        handle.writeframes(data.tobytes())


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--only", nargs="*", help="track ids to render")
    parser.add_argument("--out", default=os.path.join(os.path.dirname(__file__), "..", "..", "Autoklipp", "Resources", "Music"))
    parser.add_argument("--bitrate", default="128k")
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)
    catalog_path = os.path.join(args.out, "tracks.json")
    catalog = {"tracks": []}
    if os.path.exists(catalog_path):
        with open(catalog_path) as handle:
            catalog = json.load(handle)
    by_id = {t["id"]: t for t in catalog.get("tracks", [])}
    order = [t["id"] for t in TRACKS]
    for spec in TRACKS:
        if args.only and spec["id"] not in args.only:
            continue
        print(f"rendering {spec['id']} …", file=sys.stderr)
        mix, info = render_track(spec)
        with tempfile.TemporaryDirectory() as tmp:
            wav = os.path.join(tmp, "track.wav")
            write_wav(wav, mix)
            target = os.path.join(args.out, info["file"])
            subprocess.run(
                ["ffmpeg", "-y", "-loglevel", "error", "-i", wav, "-c:a", "aac", "-b:a", args.bitrate,
                 "-movflags", "+faststart", "-map_metadata", "-1", "-fflags", "+bitexact", "-flags:a", "+bitexact", target],
                check=True,
            )
        info["license"] = "CC0-1.0"
        by_id[spec["id"]] = info
    catalog["tracks"] = [by_id[i] for i in order if i in by_id]
    catalog["generator"] = "tools/music/generate_music.py"
    with open(catalog_path, "w") as handle:
        json.dump(catalog, handle, indent=2, ensure_ascii=False)
        handle.write("\n")
    return 0


if __name__ == "__main__":
    sys.exit(main())
