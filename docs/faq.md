# FAQ

<details>
<summary><strong>A ring stays empty. What's wrong?</strong></summary>

Run `omega-notch-engine doctor` (on macOS,
`"/Applications/Omega Notch.app/Contents/Helpers/omega-notch-engine" doctor`). It lists every provider, the files it looked for and whether it found
a sign-in. Most often the tool isn't signed in on this computer, or its token has expired; opening the
tool once usually fixes it.
</details>

<details>
<summary><strong>Does it work on GNOME, Sway or X11?</strong></summary>

Not yet. On Linux the notch is a layer-shell surface built and tested on KDE Plasma 6 on Wayland, and
jumping to a chat uses KWin. Other compositors may draw it, but only macOS and Plasma are supported
for now.
</details>

<details>
<summary><strong>I used Mega Notch before. Do I lose my settings?</strong></summary>

No. Mega Notch was this app's earlier name. The installer removes the old binaries and autostart entry,
and the engine moves `~/.config/mega-notch` and `~/.local/share/mega-notch` to their new names on its
first start.
</details>

<details>
<summary><strong>How do I remove it?</strong></summary>

On macOS, run `brew uninstall --cask --zap omega-notch`, which removes its settings too. Without
Homebrew, quit it and move it to the Trash; settings stay in
`~/Library/Application Support/omega-notch`, so delete that folder to remove everything.

On Linux, run `./uninstall.sh` from the release folder, or `make uninstall` from the repository.
Settings stay in `~/.config/omega-notch` and `~/.local/share/omega-notch`; delete those folders to
remove everything.
</details>

<details>
<summary><strong>I found a bug. What should I do?</strong></summary>

[Open an issue](https://github.com/joaomdsferro/omega-notch/issues/new/choose) with what you did, what
happened, your macOS version or Linux distribution and the output of `omega-notch-engine doctor`. Never paste tokens, the
contents of `auth.json` or `.credentials.json`, or your chats.
</details>
