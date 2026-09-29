<p align="center">
  <img src="/logo.jpg" alt="Logo">
</p>

# Migrating Jellyfin from Docker to the Native macOS App - Manual vs Semi-Automatic

With lots of fantastic, cheap, fast, low-power Apple M1 computers coming up for sale on the secondhand market, more and more, they're looking like great mini servers. I picked one up, and wanted to move Jellyfin from my Synology NAS over to it. Running Docker on M1 MacOS is easy; I used OrbStack, which isn't great, but has a reasonable GUI, I guess. Honestly, I am *not* a fan.

Migrating from Docker on one system to another system is super simple. Copy everything over, then update your volumes in the container settings, done. Point your reverse proxy to the new IP/port, smooth as butter.

Main problem is that you lose hardware transcoding because Apple+Docker=no. So, I wanted to go to the native MacOS server app.

Jellyfin team/documentation said it couldn't be done.

I didn't believe them, so I asked some AI. I used Gemini (very poor, but unlimited), ChatGTP (it's okay, good for revision) and Claude (the best of the three, but quickly ran into limits, especially at the end.) It was mostly pretty smooth because there were only a couple areas that needed tweaking.

* paths in the database
* paths in a few XML files: plug-ins (for their cover images), collections, etc.

Anyway, look at step 3, it's all listed.

Everytime I thought I'd fixed all the paths, I'd find another one. I got Claude to compile everything it did into one document, to help other people with the migration.

The only extra software you need is DB Browser for SQLite (https://sqlitebrowser.org/), a free SQL database editor.

Note: I went docker to docker to native. There is no real reason for the middle step, I just wanted to make sure everything worked - and I already had Docker/Orbstack running on the M1 to handle/text a couple of the bigger more complex (poorly written/over-engineered) docker apps I was trying out. So, moving from computer 1 to 2 with docker was just a no brainer for me. Plus, if you're going to migrate more stuff over to your M1, like an 'arr stack, you're probably going to run docker on it anyway, so it's kind of a non-issue.

To be clear, it's just sitting there, taking up space, it isn't actually running once I migrate over to the native app.

**Because it's so straightforward now, this has been converted into a single big script to allow people to run it automatically.**

grab the migrate_jellyfin_12.zsh file, and edit the first section. READ it carefully to make sure your paths are set correctly. Then run. It will only do a dry-run first, no edits.

Step 1: install Jellyfin on your mac
Step 1: shut down your docker stuff
Step 3: copy all the docker files over to your mac
Step 4: edit the script (section 1), then run the script to fix everything
Step 5: run jellyfin, check for anything broken, and do a full library scan

If anything is broken, just delete; your original docker jellyfin information should never be touched, so you can just go again easily.

*This script is entirely AI created (first with ChatGTP, then fixed/updated by Claude), so back up everything first.*

### AI Instructions

Two-phase migration: **Phase 1** moves a Jellyfin Docker container from one host (e.g. a NAS) to a Mac, still in Docker. **Phase 2** moves that Mac from Docker to the native Jellyfin Server app. This guide preserves the full library database, including custom/manually-added metadata that doesn't exist in an external provider (IMDb, TMDb, etc.), and covers every place absolute paths get baked in — not just the obvious ones.

> **Version note:** Verified against Jellyfin 12.1 (September 2026), which stores all library metadata in a single `jellyfin.db`. Older 10.x releases split this across `library.db` and `jellyfin.db` — table/file names below may differ if you're on 10.x.

> **Back up first, and keep the original running until the very end.** Don't decommission or wipe your original (pre-migration) install until Phase 2's final verification passes — one of the repair steps later in this guide specifically needs a copy of that original, untouched database.

---

## 1. Placeholders used in this guide

| Placeholder | Meaning |
| --- | --- |
| `<ORIGINAL_HOST>` | The original Docker host (NAS, or an earlier Docker copy) — kept running/untouched as your rollback |
| `<MAC_HOST>` | The destination Mac |
| `<USER>` | macOS username on the destination Mac |
| `$DATADIR` | The native app's actual data directory (found in Phase 2, step 3) |

## 2. Example volume layout

Substitute your real paths — these are illustrative.

| Container path | Example source host path | Example Mac Docker host path | Example native macOS path |
| --- | --- | --- | --- |
| `/config` | `/volume1/docker/jellyfin/config` | `/Users/<USER>/docker/jellyfin/config` | native data dir (`$DATADIR`) |
| `/cache` | `/volume1/docker/jellyfin/cache` | `/Users/<USER>/docker/jellyfin/cache` | native cache dir (skip migrating — regenerable) |
| `/jellyfin/jellyfin-web/custom` | `/volume1/docker/jellyfin/custom` | `/Users/<USER>/docker/jellyfin/custom` | *(see step 13 — optional, has trade-offs)* |
| `/media` | `/volume1/media/video` | `/Volumes/Video` | `/Volumes/Video` |
| `/music` | `/volume1/media/music` | `/Volumes/Music` | `/Volumes/Music` |
| `/audiobooks` | `/volume1/media/audiobooks` | `/Volumes/Audiobooks` | `/Volumes/Audiobooks` |
| `/books` | `/volume1/media/books` | `/Volumes/Books` | `/Volumes/Books` |
| `/backups` | `/volume1/backups/jellyfin` | `/Volumes/Backups` | `/Volumes/Backups` |

## 3. Everywhere a path gets baked in

This is the full list found by actually performing this migration and chasing down every symptom that showed up afterward. Treat it as the real checklist.

| Location | What it holds | Fixed in |
| --- | --- | --- |
| `jellyfin.db` → `BaseItems.Path` | Every media item's file path, **and** each library's own root folder path (libraries are `CollectionFolder`-type rows in this same table) | Step 8 |
| `jellyfin.db` → `BaseItems.Data` | A JSON blob column that can embed absolute paths (e.g. lyric file references) | Step 8 |
| `jellyfin.db` → `BaseItemImageInfos.Path` | On-disk location of every item's and library's cover/poster/backdrop/logo image | Step 8 |
| `jellyfin.db` → `ImageInfos.Path` | User profile picture locations — fails differently: not a wrong path, but often the wrong file *extension* | Step 11 |
| `jellyfin.db` → `LinkedChildren` | Membership of **manually-built** Collections (BoxSets). Breaks silently if any member item got re-scanned under a new path before you finished fixing paths, since it links by internal `Id`, not path | Step 12 |
| `root/default/<Library>/*.mblink` | Each library's real folder location, as a plain-text file | Step 9 |
| `root/default/<Library>/options.xml` | Per-library settings, can include path-based rules | Step 9 |
| `data/collections/*/collection.xml` | Collection membership as recorded on disk — including a collection referencing *other collections* by path | Step 10 |
| `data/playlists/*/*.xml` | Playlist membership | Step 10 |
| `plugins/configurations/*.xml` | Any plugin storing its own folder path (prerolls/intros plugins, merge-versions exclusion lists, etc.) | Step 10 |
| `plugins/<PluginName>/meta.json` → `"imagePath"` | Each installed plugin's own icon/logo file path — this is why installed plugins can show a broken icon while not-yet-installed ones (fetched live from the catalog) look fine | Step 10 |

⚠️ **`/config/` is the single most pervasive stale prefix.** In Docker, `/config` *was* Jellyfin's own data directory — so it isn't just media paths that need rewriting, but every internal, self-referential path the server wrote for itself. Include `/config/` in every find/replace pass below, not just your media-mount prefixes.

⚠️ **Terminal gotcha (zsh):** never use `path` as a shell variable name in a script. It's a special zsh variable live-linked to `$PATH` — assigning to it silently breaks your shell's ability to find commands until you open a new terminal window. Use `filepath`, `imgpath`, etc. instead.

⚠️ **Mount-collision check:** if you use a bind mount to inject custom web assets (`/jellyfin/jellyfin-web/custom`), give it its **own** host folder, separate from `/config`. Pointing both at the same folder merges your database directory with the folder the web server serves as static assets.

---

## Phase 1: Docker → Docker (new host)

No database editing needed here, provided container-side paths stay identical between the old and new Docker setup — Jellyfin never sees the host-side path, only the container path.

1. On the destination Mac, mount the network storage holding your media at the paths you intend to use permanently (e.g. `/Volumes/Video`, `/Volumes/Music`). Enable **"Reconnect at login"** for each share.
2. Note the exact Docker image tag running on `<ORIGINAL_HOST>` (`docker inspect <container> | grep Image`, or check your compose file). Use the identical tag on the Mac.
3. Stop the Jellyfin container on `<ORIGINAL_HOST>`. **Do not delete or wipe anything there** — leave it fully intact as your rollback and as the source for step 12's collection repair later.
4. Copy the config-related folders to the Mac, preserving structure: `config` (required), `custom` (if used, into its own folder — see mount-collision warning), `cache` (optional, regenerable).
5. Start the Jellyfin container on the Mac with the **same container-side mount paths**, pointed at the copied folders and re-mounted media.
6. Load the web UI and confirm: all libraries show content, custom (non-provider) entries and artwork are intact, watched status is correct, playback works. Don't proceed until this is confirmed.

---

## Phase 2: Docker → Native macOS App

### Tool needed: DB Browser for SQLite

Free, open source. Download: **[https://sqlitebrowser.org/dl/](https://sqlitebrowser.org/dl/)** — get the macOS `.dmg` for your chip, drag to Applications.

### Steps

1. **Install the native app.** Download from **[https://jellyfin.org/downloads/macos](https://jellyfin.org/downloads/macos)** (arm64 build for Apple Silicon). Confirm the version matches Docker. Drag to Applications.
2. **Launch once to create default folders, then quit.** Menu bar icon → Launch, let it fully start, then Quit. Don't run the setup wizard.
3. **Find the real data directory.**

   ```bash
   ls -la ~/.config/jellyfin/data/ 2>/dev/null
   ls -la ~/.local/share/jellyfin/data/ 2>/dev/null
   ls -la ~/Library/Application\ Support/jellyfin/data/ 2>/dev/null
   ls -la ~/Library/Application\ Support/Jellyfin/data/ 2>/dev/null
   ```

   Whichever lists a `jellyfin.db` is it — note the exact casing. Set it for this terminal session (re-run in every new window/tab):

   ```bash
   DATADIR="<the path you found>"
   ```
4. **Stop the Docker container** cleanly (`docker stop <container>`) so its write-ahead log flushes.
5. **Copy the Docker config into the native data directory**, overwriting the fresh placeholders:

   ```
   <docker config>/data/*     → $DATADIR/data/
   <docker config>/config/*   → $DATADIR/config/
   <docker config>/metadata/* → $DATADIR/metadata/
   <docker config>/plugins/*  → $DATADIR/plugins/
   <docker config>/root/*     → $DATADIR/root/
   ```

   Skip `cache`/`transcodes`.
6. **Checkpoint the database:**

   ```bash
   sqlite3 "$DATADIR/data/jellyfin.db" "PRAGMA wal_checkpoint(FULL);"
   ```
7. **Quit the native app if it's running** — the database must be closed before editing.
8. **Fix the core database paths**, all in one DB Browser session. Open `$DATADIR/data/jellyfin.db` → **Execute SQL** tab. Substitute your real `/Volumes/...` names and the literal `$DATADIR` path (SQL doesn't expand shell variables):

   ```sql
   -- 8a. Media item paths AND library folder paths (same table)
   SELECT COUNT(*) FROM BaseItems
   WHERE Path LIKE '/media/%' OR Path LIKE '/audiobooks%' OR Path LIKE '/books%'
      OR Path LIKE '/music%' OR Path LIKE '/backups%' OR Path LIKE '/config/%';

   UPDATE BaseItems SET Path = REPLACE(Path, '/media/', '/Volumes/Video/') WHERE Path LIKE '/media/%';
   UPDATE BaseItems SET Path = REPLACE(Path, '/audiobooks', '/Volumes/Audiobooks') WHERE Path LIKE '/audiobooks%';
   UPDATE BaseItems SET Path = REPLACE(Path, '/books', '/Volumes/Books') WHERE Path LIKE '/books%';
   UPDATE BaseItems SET Path = REPLACE(Path, '/music', '/Volumes/Music') WHERE Path LIKE '/music%';
   UPDATE BaseItems SET Path = REPLACE(Path, '/backups', '/Volumes/Backups') WHERE Path LIKE '/backups%';
   UPDATE BaseItems SET Path = REPLACE(Path, '/config/', '<literal $DATADIR>/') WHERE Path LIKE '/config/%';

   SELECT COUNT(*) FROM BaseItems
   WHERE Path LIKE '/media/%' OR Path LIKE '/audiobooks%' OR Path LIKE '/books%'
      OR Path LIKE '/music%' OR Path LIKE '/backups%' OR Path LIKE '/config/%';  -- expect 0

   -- 8b. JSON blob column on the same table (e.g. embedded lyric file paths)
   SELECT COUNT(*) FROM BaseItems WHERE Data LIKE '%/config/%';
   UPDATE BaseItems SET Data = REPLACE(Data, '/config/', '<literal $DATADIR>/') WHERE Data LIKE '%/config/%';
   SELECT COUNT(*) FROM BaseItems WHERE Data LIKE '%/config/%';  -- expect 0

   -- 8c. Item and library IMAGES (posters, thumbnails, library covers)
   SELECT COUNT(*) FROM BaseItemImageInfos WHERE Path LIKE '/config/%';
   UPDATE BaseItemImageInfos SET Path = REPLACE(Path, '/config/', '<literal $DATADIR>/') WHERE Path LIKE '/config/%';
   SELECT COUNT(*) FROM BaseItemImageInfos WHERE Path LIKE '/config/%';  -- expect 0
   ```

   Also check **Database Structure** for any other `TEXT` column that looks path-like (plugins can add their own tables) and repeat the pattern if found. When all counts read 0, click **Write Changes** — nothing is saved until you do — then close DB Browser.
9. **Fix the on-disk path files**, which live outside the database:

   ```bash
   cd "$DATADIR/root/default"
   find . -type f \( -name '*.mblink' -o -name 'options.xml' \) -print0 | xargs -0 sed -i '' \
     -e 's#/media/#/Volumes/Video/#g' \
     -e 's#/audiobooks#/Volumes/Audiobooks#g' \
     -e 's#/books#/Volumes/Books#g' \
     -e 's#/music#/Volumes/Music#g' \
     -e 's#/backups#/Volumes/Backups#g' \
     -e "s#/config/#${DATADIR}/#g"
   ```

   Spot-check: `for f in "$DATADIR/root/default"/*/*.mblink; do echo "== $f =="; cat "$f"; echo; done`. Delete any duplicate `.mblink` this creates in the same folder.
10. **Fix Collections, Playlists, and plugin configs** — same problem, same fix:

    ```bash
    find "$DATADIR/data/collections" -type f -name '*.xml' -print0 | xargs -0 sed -i '' \
      -e 's#/media/#/Volumes/Video/#g' -e 's#/audiobooks#/Volumes/Audiobooks#g' \
      -e 's#/books#/Volumes/Books#g' -e 's#/music#/Volumes/Music#g' \
      -e 's#/backups#/Volumes/Backups#g' -e "s#/config/#${DATADIR}/#g"

    find "$DATADIR/data/playlists" -type f -name '*.xml' -print0 | xargs -0 sed -i '' \
      -e 's#/media/#/Volumes/Video/#g' -e 's#/audiobooks#/Volumes/Audiobooks#g' \
      -e 's#/books#/Volumes/Books#g' -e 's#/music#/Volumes/Music#g' \
      -e 's#/backups#/Volumes/Backups#g' -e "s#/config/#${DATADIR}/#g"
    ```

    Then sweep plugin configs and fix any real hits by hand (check each — most plugin configs have no paths at all, and a match containing your already-correct `$DATADIR` path is fine, not a bug):

    ```bash
    cd "$DATADIR"
    grep -rIl -e '/media/' -e '/audiobooks' -e '/books' -e '/music' -e '/backups' -e '/config/' plugins/configurations
    ```

    **Plugin icons** are stored separately, in each installed plugin's own `meta.json` (e.g. `plugins/<PluginName>_<version>/meta.json`), as an absolute `"imagePath"` such as `/config/plugins/<PluginName>_<version>/logo.png`. Left unfixed, installed plugins show a broken icon. Fix them all at once:

    ```bash
    find "$DATADIR/plugins" -type f \( -name "*.json" -o -name "*.xml" -o -name "*.conf" -o -name "*.config" \) \
      -exec grep -Il '"imagePath"[[:space:]]*:[[:space:]]*"/config/' {} \; | while IFS= read -r f; do
        echo "Updating: $f"
        sed -i '' "s#\(\"imagePath\"[[:space:]]*:[[:space:]]*\"\)/config/#\1${DATADIR}/#g" "$f"
      done
    ```

    Verify one: `grep imagePath "$DATADIR/plugins/<PluginName>_<version>/meta.json"` should show a `$DATADIR/plugins/...` path, not `/config/...`. Restart the app and refresh the browser (`Cmd+Shift+R`) to see the icons.
11. **Fix user profile image extensions.** This one isn't a wrong path — the database can record the wrong file extension (e.g. expects `.png`, the real file is `.jpg`):

    ```bash
    sqlite3 "$DATADIR/data/jellyfin.db" "SELECT Id, Path FROM ImageInfos;" | while IFS='|' read -r id imgpath; do
      if [ ! -f "$imgpath" ]; then
        base="${imgpath%.*}"
        for ext in png jpg jpeg webp; do
          alt="${base}.${ext}"
          if [ -f "$alt" ]; then
            echo "UPDATE ImageInfos SET Path = '$alt' WHERE Id = $id;"
            break
          fi
        done
      fi
    done > /tmp/fix_avatars.sql

    cat /tmp/fix_avatars.sql   # review before applying
    sqlite3 "$DATADIR/data/jellyfin.db" < /tmp/fix_avatars.sql
    ```
12. **Repair manually-built Collection membership.** Provider-matched ("generated") collections link members by external metadata ID and survive path changes fine. **Manually-built** collections link by internal `Id` — if any member item got re-scanned under a new path before you finished fixing paths, Jellyfin silently generated a new `Id` for it, orphaning the collection's old link. Symptom: generated collections work, your own don't; they appear empty.

    This repair needs a copy of your **original, pre-migration** `jellyfin.db` (from `<ORIGINAL_HOST>`, still untouched from Phase 1) — its `LinkedChildren` table still has the correct old links.

    On `<ORIGINAL_HOST>`, make a safe copy and transfer it to the Mac:

    ```bash
    sqlite3 jellyfin.db ".backup /tmp/jellyfin_original_backup.db"
    scp /tmp/jellyfin_original_backup.db <user>@<MAC_HOST>:/Users/<USER>/Desktop/
    ```

    On the Mac, quit the native app, then in DB Browser's **Execute SQL** tab (same session, run these one block at a time):

    ```sql
    ATTACH DATABASE '/Users/<USER>/Desktop/jellyfin_original_backup.db' AS old;

    -- Preview: how many old links can be translated to a current item?
    SELECT COUNT(*) FROM old.LinkedChildren lc
    JOIN old.BaseItems old_items ON old_items.Id = lc.ChildId
    JOIN BaseItems new_items ON new_items.Path =
      REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(old_items.Path,
        '/media/', '/Volumes/Video/'), '/audiobooks', '/Volumes/Audiobooks'),
        '/books', '/Volumes/Books'), '/music', '/Volumes/Music'),
        '/backups', '/Volumes/Backups');
    ```

    That count should be close to `old.LinkedChildren`'s total row count (check with `SELECT COUNT(*) FROM old.LinkedChildren;`). A big gap means some items were renamed since migration and need separate handling. If it looks right, apply the repair (only adds missing links, never overwrites existing ones):

    ```sql
    INSERT OR IGNORE INTO LinkedChildren (ParentId, SortOrder, ChildId, ChildType)
    SELECT lc.ParentId, lc.SortOrder, new_items.Id, lc.ChildType
    FROM old.LinkedChildren lc
    JOIN old.BaseItems old_items ON old_items.Id = lc.ChildId
    JOIN BaseItems new_items ON new_items.Path =
      REPLACE(REPLACE(REPLACE(REPLACE(REPLACE(old_items.Path,
        '/media/', '/Volumes/Video/'), '/audiobooks', '/Volumes/Audiobooks'),
        '/books', '/Volumes/Books'), '/music', '/Volumes/Music'),
        '/backups', '/Volumes/Backups')
    WHERE NOT EXISTS (
      SELECT 1 FROM LinkedChildren cur WHERE cur.ParentId = lc.ParentId AND cur.SortOrder = lc.SortOrder
    );
    ```

    Verify total row count increased sensibly, then **Write Changes** and close DB Browser.
13. **Custom web assets (optional).** Editing files inside `Jellyfin.app` gets wiped on every app update, so this is a genuine trade-off, not just a nice-to-have to skip lightly. If you want it anyway: copy your `custom` folder into `/Applications/Jellyfin.app/Contents/Resources/jellyfin-web/custom`, then reapply whatever `index.html` edit originally referenced those files. If you'd rather not touch the app bundle at all, skip this — the web client works fine without it; you'll just need another way to reapply branding later (a browser userstyle, or a reverse proxy that injects the CSS).
14. **Launch and verify:**
    - Each library's path (Dashboard → Libraries) matches its new native location.
    - Custom (non-provider) entries still show correct metadata and artwork.
    - Library cover images load, both on the home page and the Libraries page.
    - User avatars load for every user, not just one.
    - **Manually-built** collections show their correct members, including any nested collection-of-collections. Provider-generated collections should have worked all along.
    - Watched status and playback position are correct on a few items; playback starts.

    A first library scan may re-check artwork timestamps and take longer than usual — expected, not data loss, as long as item counts and watch data match.
15. Once confirmed, stop/remove the Docker container, and set the native app to launch at login (menu bar icon → Preferences).

---

## If something is still broken after all of the above

Search the *entire* database at once rather than guessing table/column names — this is how `BaseItemImageInfos`, `BaseItems.Data`, and the `LinkedChildren` problem were actually found:

```bash
sqlite3 "$DATADIR/data/jellyfin.db" ".dump" | grep -c '/config/'
sqlite3 "$DATADIR/data/jellyfin.db" ".dump" | grep -c '/media/'   # repeat per prefix
```

If non-zero, find which table:

```bash
sqlite3 "$DATADIR/data/jellyfin.db" ".dump" | grep '/config/' \
  | sed -E 's/^INSERT INTO "?([A-Za-z0-9_]+)"?.*/\1/' | sort | uniq -c | sort -rn
```

A general catch-all for a completely unexpected leftover prefix:

```bash
sqlite3 "$DATADIR/data/jellyfin.db" ".dump" | grep -oE "/[A-Za-z0-9_.-]+/[A-Za-z0-9_./ -]*" \
  | grep -v "^/Volumes" | grep -v "^$DATADIR" | sort -u | head -50
```

### Known open issues not resolved by this guide

- **A stray/duplicate library with the same display name** (from an old rename that changed the display name but not the underlying folder) is a library-management cleanup, not a path bug — handle via Dashboard → Libraries in the UI, not by editing the database directly.

---

## Enabling Hardware Transcoding (Apple Silicon / VideoToolbox)

Docker Desktop on Mac runs containers inside a Linux VM with **no access** to Apple's VideoToolbox — inside Docker, `ffmpeg` falls back to slow software encoding. The native app runs directly on macOS and can use VideoToolbox for real hardware-accelerated transcoding — one of the main reasons to make this move at all.

1. **Dashboard → Playback** → set **Hardware acceleration** to **VideoToolbox**.
2. Deselect any codecs your Mac/chip doesn't support.
3. Optionally enable **VideoToolbox Tone mapping** (HDR/Dolby Vision via VideoToolbox) or **Tone mapping** (Metal-based alternative).
4. Optionally set an **Encoding Preset** — `veryslow`–`medium` favors quality, `fast`–`ultrafast` favors speed, `Auto` favors speed.
5. Save, then test: force a transcode by playing at a lower resolution/bitrate than the source. Check **Dashboard → Activity** for `Transcoding (HW)`, or open Activity Monitor and check `ffmpeg` CPU — low usage while still playing means hardware acceleration is active; a few hundred percent means it's still software.

**Running headless (no monitor, lid closed):** some Macs throttle the GPU without an active display. If transcoding underperforms, connect a monitor or an HDMI dummy plug to keep the GPU at full power.
