WoW Forever Bots for macOS: the server with the bots, ready made for Apple Silicon Macs (macOS 14 or newer, made for macOS 26).
No compiling: download, unpack, run one script. Play with the native macOS game client, no Windows needed.

**Install**

1. Download `WoW-Forever-Bots-macOS-arm64-<version>.tar.gz` below and double-click it (Finder unpacks it into a folder `WoWForeverBots`).
2. Open Terminal and drag the file `WoWForeverBots/macos/install.sh` into the window, press Enter.
   It moves itself to `~/WoWForever/app`, installs MySQL 8.4, tmux and 7-Zip with Homebrew (it installs Homebrew if needed),
   sets up the databases, the login certificate and the hosts line (your Mac password is asked twice), extracts the maps
   from your own game (10 to 20 minutes), installs the add-on, puts a **WoW Forever Bots** icon on the Desktop, starts the
   server and offers to create your account.
3. From then on: the Desktop icon. **1** Start, **2** Shut down, **3** Auto-restart, **4** Update (fetches the newest release,
   keeps your characters), **5** Create account, **6** Discord, **P** Play with the macOS game client.

**The game**

WoW Forever from Battle.net, build 1.60.1.70707. **P** runs a clone of the game app and sets this server's public key in
memory while you connect to the realm, the way advocaite's launcher does on Windows and Linux. The original app, its
settings and its cache stay exactly as they are (see `macos/README.md`, "The game client on a Mac"). Log in with
`name@local`, realm Trinity, and type `/fb` in game.

**First start takes a while.** The server builds the world-bot roster and seeds the auction house the first time (the
console shows `still starting ... AHBot ...`). To start fast, or to look around solo first, turn those off: put
`Playerbot.World.Enable = 0`, `AuctionHouseBot.Seller.Enabled = 0` and `AuctionHouseBot.Buyer.Enabled = 0` in
`~/WoWForever/server/etc/worldserver.conf.d/zz-9-local.conf` and restart. Your own party bots (`/fb`) still work.

**Remove everything:** `~/WoWForever/app/macos/uninstall.sh` (asks before each part; `--yes` skips the questions).

Intel Macs: the download is for Apple Silicon; on an Intel Mac `macos/install.sh` compiles the server instead (1 to 2 hours).

Checksum: `shasum -a 256 -c WoW-Forever-Bots-macOS-arm64-<version>.tar.gz.sha256`. The download contains no Blizzard files;
the maps are made from your own client. Source: this repository (GPL-2.0) and advocaite's TrinityCore `forever` at the
commit in `macos/UPSTREAM`.
