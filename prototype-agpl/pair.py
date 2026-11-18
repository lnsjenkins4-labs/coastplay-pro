#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-AGPL-3.0-only-OpenSSL
# PRIVATE PROTOTYPE. Guided pairing: no values to edit into a command line.
#   1. opens Sony's sign-in page, you paste back the "redirect" address
#   2. asks for the 8-digit number shown on the PS5
#   3. pairs and stores the keys in the macOS Keychain
# The account details Sony returns are not shown and not written anywhere.

import os, re, subprocess, sys

HERE = os.path.dirname(os.path.abspath(__file__))
HOST = sys.argv[1] if len(sys.argv) > 1 else "192.168.1.50"
HARNESS = os.path.join(HERE, "build", "rgp-harness")
SCRIPT = os.path.join(HERE, "chiaki-ng", "scripts", "psn-account-id.py")


def get_account_id():
    print("STEP 1 of 2 — PlayStation sign-in (on Sony's own page)\n")
    child = subprocess.Popen([sys.executable, "-u", SCRIPT], stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    shown, hidden, line, quiet = True, [], b"", False
    while True:
        ch = child.stdout.read(1)
        if not ch:
            break
        line += ch
        if shown:
            sys.stdout.buffer.write(ch)
            sys.stdout.flush()
        if ch == b"\n":
            text = line.decode(errors="replace").strip()
            if shown and text.startswith("https://auth.api."):
                subprocess.run(["open", text])
                print("\n(I opened that page in your browser. Sign in there. When the page just says")
                print(" \"redirect\", copy the whole address from the address bar and paste it below.)")
            if "Requesting OAuth Token" in text:
                shown = False          # everything after this can contain account details
                print("Checking with Sony…")
            if not shown:
                hidden.append(text)
            line = b""
    child.wait()
    ids = [t for t in hidden if re.fullmatch(r"[A-Za-z0-9+/]{11}=", t)]
    if child.returncode == 0 and ids:
        return ids[-1]
    reason = next((t for t in hidden if "failed" in t.lower() or "missing" in t.lower()), "")
    print("\nCould not get the account ID." + (" Sony said: " + reason[:80] if reason else ""))
    print("The usual cause is pasting the wrong address or waiting too long. Run this again and paste")
    print("the address right after the page shows \"redirect\".")
    return None


def main():
    if not os.path.exists(HARNESS):
        print("Harness not built. See README.md in this folder."); return 1
    account_id = get_account_id()
    if not account_id:
        return 1
    print("\nAccount ID received (not shown).\n")
    print("STEP 2 of 2 — on the PS5: Settings > System > Remote Play > Link Device")
    pin = re.sub(r"\D", "", input("Type the 8-digit number it shows, then Enter: "))
    if len(pin) != 8:
        print("That was not 8 digits. Run this again."); return 1
    result = subprocess.run([HARNESS, "register", HOST, account_id, pin])
    if result.returncode == 0:
        print("\nNext, to see and hear the console for a minute:\n  build/rgp-harness stream %s --view --seconds 60" % HOST)
    return result.returncode


if __name__ == "__main__":
    sys.exit(main())
