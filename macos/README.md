# WoW Forever Bots on macOS

Everything the Windows repack does, as Terminal scripts for macOS 26 (Tahoe) and newer, Apple Silicon or Intel:
build the server, set up MySQL and the databases, extract the maps from your own client, the login certificate,
the add-on, and a menu with Start, Shut down, Auto-restart, Update, Create account and Discord.

## What you need

- macOS 26 or newer (14 or newer works too), 16 GB RAM or more (8 GB runs with fewer world bots), about 60 GB free disk
  while the maps are extracted (about 15 GB stay: source, build, server, maps).
- The WoW Forever game client, build **70450** (the folder that holds `.build.info` and `_classic_beta_`), and advocaite's
  [ForeverLauncher](https://github.com/advocaite/foreverlauncher). See [The game client on a Mac](#the-game-client-on-a-mac).
- An internet connection for the first install (Homebrew packages, the core source, the world database).

Nothing else: the scripts install the Xcode Command Line Tools and Homebrew if they are missing, and then
`cmake ninja ccache boost openssl@3 mysql readline bzip2 zlib tmux sevenzip` with Homebrew.

## Install

```bash
git clone https://github.com/Karrz1/Karrz-playerbots-wow-forever.git ~/Karrz-playerbots-wow-forever
```

```bash
~/Karrz-playerbots-wow-forever/macos/install.sh
```

It asks for your Mac password twice (to trust the login certificate and to add the hosts line) and otherwise runs by itself:

1. **Build** (`macos/build.sh`): fetches advocaite's TrinityCore `forever` at the tested commit (`macos/UPSTREAM`), copies this
   repository over it and compiles worldserver, bnetserver and the map tools with the bots (`-DBUILD_PLAYERBOT_V2=1`).
   The first build takes about 1 to 2 hours on Apple Silicon; later builds reuse ccache and are much faster.
2. **Game folder**: finds it (also inside CrossOver and Whisky bottles) or lets you pick it in a Finder window.
3. **MySQL**: starts Homebrew's MySQL, makes the user `trinity` with a random password (kept in `~/WoWForever/wowforever.env`),
   the databases `auth`, `characters`, `world`, `hotfixes` and the bot database `playerbot`, and downloads the Forever world
   database release (about 150 MB) that worldserver imports on its first start.
4. **Configs** in `~/WoWForever/server/etc`: the Classic client settings (realm 70, `trinity.actual.battle.net`), local only
   (`127.0.0.1`), `playerbot.conf`, and `worldserver.conf.d/zz-9-local.conf` for your own changes (fewer world bots on a Mac
   with less than 16 GB).
5. **Login certificate**: a root CA for this Mac only (limited to `*.actual.battle.net`, its key is deleted right away)
   and the server certificate; the CA is trusted in the System keychain. **Hosts line**: `127.0.0.1 trinity.actual.battle.net`.
6. **Maps**: dbc, maps, vmaps and the bot pathing (mmaps) from your own client (`tools/extract_client_data.sh`), 10 to 20 minutes.
   If it is interrupted, run `install.sh` again: it continues where it stopped.
7. **Add-on**: copies ForeverBots into `_classic_beta_/Interface/AddOns`.
8. A **WoW Forever Bots** icon on the Desktop, then it starts the server and offers to create your account.

Options: `--client "/path/to/game folder"`, `--vanilla-dump world_full_14_june_2021.sql` (also builds the vanilla 1.12
numbers, see [`tools/classic_spell_values/README.md`](../tools/classic_spell_values/README.md)), `--no-start`.
Put everything somewhere else than `~/WoWForever` with `WOWF_HOME=/path/without/spaces macos/install.sh`.

## The menu

Double-click **WoW Forever Bots** on the Desktop, or:

```bash
~/Karrz-playerbots-wow-forever/macos/wowforever.sh
```

| | |
|---|---|
| **1** Start server | bnetserver and worldserver in the background (tmux session `wowforever`); the Mac stays awake while it runs |
| **2** Shut down server | `server shutdown`, saves every character |
| **3** Auto-restart | starts the server; worldserver and bnetserver come back by themselves if they crash (Shut down turns it off) |
| **4** Update | backs up `auth`, `characters` and `playerbot`, pulls the newest version, rebuilds, keeps your characters |
| **5** Create account | your login is `name@local`, realm Trinity; the first account is always a game master |
| **6** Join our Discord | |
| **7** Console | the worldserver console (leave with Ctrl+B, then D; the server keeps running) |
| **8** Logs, **9** Status, **A** add-on, **B** backup | |

Each item also works as a command: `wowforever.sh start|stop|autorestart|update|account|status|console|logs|addon|backup|discord`.
Backups go to `~/WoWForever/backups/<date>/`.

## The game client on a Mac

The WoW Forever client (`_classic_beta_/WowB.exe`) and advocaite's ForeverLauncher are Windows programs. Either:

- **On this Mac**: run them with CrossOver, Whisky or another Wine. `install.sh` finds a game folder inside a bottle,
  installs the add-on there and sets everything the client needs (the hosts line and the certificate are shared with
  Wine). If the launcher reports a certificate error, also import `~/WoWForever/server/certs/forever_root_ca.crt` into
  the bottle's Windows certificate store (Trusted Root Certification Authorities).
- **On a Windows PC in your network**: make the server reachable from it (below) and start the game there as usual.

Then start the game from the ForeverLauncher, log in with `name@local` and your password, realm Trinity, and type `/fb`.

## Playing from another computer

Out of the box the server only accepts this Mac (`BindIP = "127.0.0.1"`), like the repack. For other PCs, the same list as
advocaite's README "Hosting for other players": `BindIP = "0.0.0.0"` in `bnetserver.conf` and `worldserver.conf`,
`UPDATE auth.realmlist SET address='<this Mac's IP>' WHERE id=70;`, the hosts line `<this Mac's IP> trinity.actual.battle.net`
on this Mac and on every player PC, every player trusts `server/certs/forever_root_ca.crt` (never give out a key), and
allow incoming connections for worldserver and bnetserver when macOS asks (TCP 1119, 8081, 8085).

## Where things are

| | |
|---|---|
| `~/WoWForever/source` | advocaite's core with this repository copied over it (made fresh by every build) |
| `~/WoWForever/build` | the build folder |
| `~/WoWForever/server/bin` | worldserver, bnetserver, the map tools, the world database release |
| `~/WoWForever/server/etc` | `worldserver.conf`, `bnetserver.conf`, `worldserver.conf.d/` (put your changes in `zz-9-local.conf`) |
| `~/WoWForever/server/data` | dbc, maps, vmaps, mmaps |
| `~/WoWForever/server/logs` | `Server.log`, `Playerbot.log`, `DBErrors.log`, `restarts.log` |
| `~/WoWForever/wowforever.env` | the database password, the game folder |

## Problems

- **bnetserver stops at once**: "Could not resolve LoginREST.ExternalAddress" means the hosts line is missing
  (`grep actual.battle.net /etc/hosts`); a certificate error means `server/certs` is incomplete: delete that folder and run
  `macos/install.sh --no-start`.
- **The bots do not walk**, `Could not load MMAP ... result: 2`: the mmaps are missing; run `macos/install.sh` again.
- **The first start takes long**: worldserver imports the world database and then makes the bot roster (a few thousand
  characters). `wowforever.sh logs` shows what it does.
- **Lots of DB warnings**: they go to `DBErrors.log` only (retail rows the Classic data does not have); harmless.
- Report problems on our Discord with `Playerbot.log`, `Server.log` and the time it happened.

## Remove

`wowforever.sh stop`, then delete `~/WoWForever`, the line with `trinity.actual.battle.net` in `/etc/hosts`
(`sudo nano /etc/hosts`), the "WoW Forever Bots local CA" in Keychain Access (System keychain), and, if you like, the
databases (`mysql -uroot -e "DROP DATABASE auth; DROP DATABASE characters; DROP DATABASE world; DROP DATABASE hotfixes; DROP DATABASE playerbot;"`).
