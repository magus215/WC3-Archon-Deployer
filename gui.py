#!/usr/bin/env python3
"""Tkinter GUI front-end for the Archon deployer.

Zero extra dependencies — tkinter ships with Python. Just run:  python gui.py
It wraps the same logic as the CLI (src/deployer.py): pick a vanilla melee map,
pick an output folder, set the options, hit Convert. Output is auto-named
<source-name>_archon.w3x in the chosen folder.
"""

import io
import os
import sys
from contextlib import redirect_stderr, redirect_stdout

import tkinter as tk
from tkinter import filedialog, ttk
from tkinter.scrolledtext import ScrolledText

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(HERE, "src"))
sys.dont_write_bytecode = True  # keep the user's folder clean — no __pycache__
import deployer  # noqa: E402


def build_ui(root: "tk.Tk") -> None:
    root.title("Archon Deployer")
    root.geometry("660x540")
    root.minsize(560, 460)

    src_var = tk.StringVar()
    out_var = tk.StringVar()
    show_score = tk.BooleanVar(value=False)   # checked -> --show-support-score
    keep_color = tk.BooleanVar(value=False)   # checked -> --keep-support-color
    timer_var = tk.StringVar(value="0")
    status_var = tk.StringVar(value="Pick a melee map and an output folder.")

    frm = ttk.Frame(root, padding=12)
    frm.pack(fill="both", expand=True)
    frm.columnconfigure(1, weight=1)

    ttk.Label(frm, text="Archon Deployer", font=("", 14, "bold")).grid(
        row=0, column=0, columnspan=3, sticky="w", pady=(0, 2))
    ttk.Label(frm, text="Convert a vanilla 1v1/2v2 melee map into a 4-player Archon map.",
              foreground="#555").grid(row=1, column=0, columnspan=3, sticky="w", pady=(0, 10))

    # source map
    ttk.Label(frm, text="Vanilla map (.w3x):").grid(row=2, column=0, sticky="w")
    ttk.Entry(frm, textvariable=src_var).grid(row=2, column=1, sticky="ew", padx=6)
    ttk.Button(frm, text="Browse…", command=lambda: _pick_file(src_var)).grid(row=2, column=2)

    # output folder
    ttk.Label(frm, text="Output folder:").grid(row=3, column=0, sticky="w", pady=(6, 0))
    ttk.Entry(frm, textvariable=out_var).grid(row=3, column=1, sticky="ew", padx=6, pady=(6, 0))
    ttk.Button(frm, text="Browse…", command=lambda: _pick_dir(out_var)).grid(row=3, column=2, pady=(6, 0))

    # options
    opts = ttk.LabelFrame(frm, text="Options", padding=8)
    opts.grid(row=4, column=0, columnspan=3, sticky="ew", pady=12)
    opts.columnconfigure(1, weight=1)
    ttk.Checkbutton(opts, text="Show supports on the post-game score screen  (default: hidden)",
                    variable=show_score).grid(row=0, column=0, columnspan=2, sticky="w")
    ttk.Checkbutton(opts, text="Keep supports' own color  (default: match the main's)",
                    variable=keep_color).grid(row=1, column=0, columnspan=2, sticky="w", pady=(4, 0))
    ttk.Label(opts, text="Pre-game freeze timer (seconds, 0 = off):").grid(
        row=2, column=0, sticky="w", pady=(8, 0))
    ttk.Spinbox(opts, from_=0, to=600, increment=1, width=8,
                textvariable=timer_var).grid(row=2, column=1, sticky="w", padx=6, pady=(8, 0))

    # convert + status
    convert_btn = ttk.Button(frm, text="Convert")
    convert_btn.grid(row=5, column=0, sticky="w")
    ttk.Label(frm, textvariable=status_var, foreground="#555").grid(
        row=5, column=1, columnspan=2, sticky="w", padx=6)

    # log
    ttk.Label(frm, text="Log:").grid(row=6, column=0, sticky="w", pady=(10, 0))
    log = ScrolledText(frm, height=12, wrap="word", state="disabled", font=("Consolas", 9))
    log.grid(row=7, column=0, columnspan=3, sticky="nsew")
    frm.rowconfigure(7, weight=1)

    def log_write(text: str) -> None:
        log.configure(state="normal")
        log.insert("end", text + "\n")
        log.see("end")
        log.configure(state="disabled")

    def on_convert() -> None:
        src = src_var.get().strip()
        out_dir = out_var.get().strip()
        log.configure(state="normal"); log.delete("1.0", "end"); log.configure(state="disabled")
        if not os.path.isfile(src):
            status_var.set("Pick a valid source .w3x map."); log_write("✗ No valid source map selected."); return
        if not out_dir:
            status_var.set("Pick an output folder."); log_write("✗ No output folder selected."); return
        try:
            timer = max(0, int(timer_var.get() or "0"))
        except ValueError:
            status_var.set("Pre-game timer must be a whole number."); log_write("✗ Pre-game timer must be an integer."); return

        stem = os.path.splitext(os.path.basename(src))[0]
        out_path = os.path.join(out_dir, stem + "_archon.w3x")
        status_var.set("Converting…"); convert_btn.config(state="disabled"); root.update_idletasks()

        buf = io.StringIO()
        try:
            with redirect_stdout(buf), redirect_stderr(buf):
                deployer.convert(src, out_path,
                                 hide_support_score=not show_score.get(),
                                 match_support_color=not keep_color.get(),
                                 pre_game_timer=timer)
            if buf.getvalue().strip():
                log_write(buf.getvalue().rstrip())
            log_write("✓ Done → " + out_path)
            status_var.set("Done.")
        except Exception as exc:  # noqa: BLE001 — surface any failure to the user
            if buf.getvalue().strip():
                log_write(buf.getvalue().rstrip())
            log_write("✗ ERROR: " + str(exc))
            status_var.set("Failed — see log.")
        finally:
            convert_btn.config(state="normal")

    convert_btn.config(command=on_convert)


def _pick_file(var: "tk.StringVar") -> None:
    path = filedialog.askopenfilename(
        title="Select a vanilla melee map",
        filetypes=[("Warcraft III map", "*.w3x *.w3m"), ("All files", "*.*")])
    if path:
        var.set(path)


def _pick_dir(var: "tk.StringVar") -> None:
    path = filedialog.askdirectory(title="Select the output folder")
    if path:
        var.set(path)


def main() -> None:
    root = tk.Tk()
    build_ui(root)
    root.mainloop()


if __name__ == "__main__":
    main()
