Antenna @VERSION@ (@COMMIT@): command line and daemon only, for macOS (Apple Silicon)

Inside: bin/antennad (the daemon: keys, links, encryption, permissions) and bin/antenna (owner and agent commands,
MCP server `antenna mcp`). No app window; the visual version is Antenna-…-macos-arm64.dmg (it contains the same
antenna and antennad).

Install (no administrator rights needed):

    xattr -dr com.apple.quarantine .       # remove the "downloaded from the internet" flag from the unpacked folder
    mkdir -p ~/.local/bin && cp bin/antenna bin/antennad ~/.local/bin/
    echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zprofile   # if ~/.local/bin is not in PATH yet; open a new Terminal

Run:

    antennad &                 # the daemon; data in ~/.local/share/antenna
    antenna init               # first time: owner password (cannot be recovered)
    antenna unlock             # after every reboot
    antenna --help

The Antenna app installs a LaunchAgent that starts the daemon at login; without the app, start antennad yourself
(or with your own LaunchAgent).
Guide: https://github.com/Danta-Nort/antenna/blob/main/docs/USER-GUIDE.md
