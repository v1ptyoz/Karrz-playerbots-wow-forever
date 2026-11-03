// WoW Forever Bots: in-memory server-key setter (macOS, Apple Silicon).
//
// Loaded into a prepared COPY of the game with DYLD_INSERT_LIBRARIES (the original app is never touched). It does the
// same, in memory only, as the Forever Launcher does on Windows/Linux: when the client builds its region-key store
// while connecting to a realm, it replaces the key of the server's region group with the server's PUBLIC key, so the
// client trusts this private server's EnterEncryptedMode packet. It never changes code or any file on disk.
//
// The store is an array of 12 entries, 40 bytes each: [u32 id 1..12][32-byte key][u8 flag][3 bytes padding]. It is
// found by the id sequence 1,2,...,12 at stride 40 (unambiguous, no guessing). Entry (region group) gets the new key.
//
// Env: FOREVER_LOG=<file>  FOREVER_MODE=locate|patch  FOREVER_REGION_GROUP=<2..12,!=9>  FOREVER_PUBKEY=<64 hex>
#include <mach/mach.h>
#include <mach/mach_vm.h>
#include <mach/vm_region.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define ENTRY_SIZE 40
#define ENTRY_COUNT 12
#define BLOCK_SIZE (ENTRY_SIZE * ENTRY_COUNT)

// stock TrinityCore EnterEncryptedMode public key (what a server that did not change its key uses)
static const char *DEFAULT_PUBKEY = "02596F0D0C061A8B30745988FD72C59E29EC367FB0F341F28E0F08D037BAFC69";

static uint8_t g_new_key[32];
static int g_group = 8;             // region group -> entry index g_group-1
static int g_patch = 0;             // 0 = locate only (report), 1 = patch and keep watching
static FILE *g_log;

static void lg(const char *fmt, ...) {
    if (!g_log) return;
    va_list a; va_start(a, fmt); vfprintf(g_log, fmt, a); va_end(a);
    fputc('\n', g_log); fflush(g_log);
}

static void hexline(const char *tag, const uint8_t *p, int n) {
    char line[128]; int c = 0;
    c += snprintf(line + c, sizeof line - c, "%s ", tag);
    for (int i = 0; i < n && c < (int)sizeof line - 3; i++) c += snprintf(line + c, sizeof line - c, "%02x", p[i]);
    lg("%s", line);
}

static int hex2bin(const char *h, uint8_t *out, int n) {
    for (int i = 0; i < n; i++) {
        int hi, lo;
        char a = h[2 * i], b = h[2 * i + 1];
        if (!a || !b) return 0;
        hi = (a <= '9') ? a - '0' : (a | 32) - 'a' + 10;
        lo = (b <= '9') ? b - '0' : (b | 32) - 'a' + 10;
        out[i] = (uint8_t)((hi << 4) | lo);
    }
    return 1;
}

// expected per-entry flag (byte at +36): 1 for all, 0 for the 9th (index 8). Same pattern as the Windows/Linux launcher.
static const uint8_t EXPECTED_FLAGS[ENTRY_COUNT] = {1,1,1,1,1,1,1,1,0,1,1,1};

static int key_like(const uint8_t *p) {           // a real 32-byte key has many distinct bytes; ids/padding do not
    int seen[256] = {0}, n = 0;
    for (int i = 0; i < 32; i++) if (!seen[p[i]]++) n++;
    return n >= 24;
}

// A valid store: 12 entries, each [u32 id e+1][32-byte key-like value][flag matching the pattern]. Strong enough to
// write safely (a stray 1..12 integer array elsewhere will not also carry 12 key-like blocks with this flag pattern).
static int is_store(const uint8_t *p) {
    for (int e = 0; e < ENTRY_COUNT; e++) {
        const uint8_t *q = p + e * ENTRY_SIZE;
        if (*(const uint32_t *)q != (uint32_t)(e + 1)) return 0;
        if (q[36] != EXPECTED_FLAGS[e]) return 0;
        if (!key_like(q + 4)) return 0;
    }
    return 1;
}

// Fault-safe access: copy target memory with mach_vm_read_overwrite (returns an error on a freed/unmapped page
// instead of crashing) and write with mach_vm_write. The game frees memory under us while entering the world, so we
// never dereference its memory directly.
static int safe_read(uint64_t addr, void *dst, uint64_t n) {
    mach_vm_size_t got = 0;
    return mach_vm_read_overwrite(mach_task_self(), addr, n, (mach_vm_address_t)dst, &got) == KERN_SUCCESS && got == n;
}

typedef void (*store_cb)(uint64_t addr, const uint8_t *block);

#define SCAN_CHUNK (4 * 1024 * 1024)

static int scan_stores(store_cb cb) {
    uint8_t *buf = malloc(SCAN_CHUNK), sblock[BLOCK_SIZE];
    if (!buf) return 0;
    mach_vm_address_t addr = 0; mach_vm_size_t size = 0;
    natural_t depth = 0; int found = 0;
    while (1) {
        vm_region_submap_info_data_64_t info;
        mach_msg_type_number_t cnt = VM_REGION_SUBMAP_INFO_COUNT_64;
        if (mach_vm_region_recurse(mach_task_self(), &addr, &size, &depth,
                                   (vm_region_recurse_info_t)&info, &cnt) != KERN_SUCCESS) break;
        if (info.is_submap) { depth++; continue; }
        mach_vm_address_t region_end = addr + size;
        int rw = (info.protection & VM_PROT_READ) && (info.protection & VM_PROT_WRITE);
        if (rw && info.share_mode != SM_SHARED) {
            for (mach_vm_address_t base = addr; base < region_end; base += SCAN_CHUNK - BLOCK_SIZE) {
                uint64_t want = region_end - base; if (want > SCAN_CHUNK) want = SCAN_CHUNK;
                if (want < BLOCK_SIZE || !safe_read(base, buf, want)) break;
                for (uint64_t o = 0; o + BLOCK_SIZE <= want; o += 4) {
                    if (*(const uint32_t *)(buf + o) != 1 || *(const uint32_t *)(buf + o + ENTRY_SIZE) != 2) continue;
                    if (!is_store(buf + o)) continue;
                    uint64_t a = base + o;
                    if (safe_read(a, sblock, BLOCK_SIZE) && is_store(sblock)) { cb(a, sblock); found++; }
                }
                if (want < SCAN_CHUNK) break;
            }
        }
        addr = region_end;
    }
    free(buf);
    return found;
}

static int g_seen;
static void on_locate(uint64_t addr, const uint8_t *b) {
    g_seen++;
    const uint8_t *slot = b + (g_group - 1) * ENTRY_SIZE + 4;
    lg("store at %#llx", (unsigned long long)addr);
    for (int e = 0; e < ENTRY_COUNT; e++) {
        const uint8_t *q = b + e * ENTRY_SIZE;
        char tag[40]; snprintf(tag, sizeof tag, "  e%02d id=%u flag=%u key", e + 1, *(const uint32_t *)q, q[36]);
        hexline(tag, q + 4, 32);
    }
    lg("  region group %d current key is server key: %s", g_group,
       memcmp(slot, g_new_key, 32) == 0 ? "yes" : "no");
}

static int g_patched;
static void on_patch(uint64_t addr, const uint8_t *b) {
    uint64_t slot = addr + (uint64_t)(g_group - 1) * ENTRY_SIZE + 4;
    if (memcmp(b + (g_group - 1) * ENTRY_SIZE + 4, g_new_key, 32) == 0) { g_patched++; return; }  // already ours
    if (mach_vm_protect(mach_task_self(), slot, 32, 0, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY) != KERN_SUCCESS) {
        lg("  mach_vm_protect failed at %#llx", (unsigned long long)slot); return;
    }
    if (mach_vm_write(mach_task_self(), slot, (vm_offset_t)g_new_key, 32) != KERN_SUCCESS) {
        lg("  mach_vm_write failed at %#llx", (unsigned long long)slot); return;
    }
    uint8_t check[32];
    if (safe_read(slot, check, 32) && memcmp(check, g_new_key, 32) == 0) {
        lg("  region group %d key set at %#llx", g_group, (unsigned long long)slot);
        g_patched++;
    } else {
        lg("  write-back verify failed at %#llx", (unsigned long long)slot);
    }
}

static void *worker(void *arg) {
    (void)arg;
    const char *path = getenv("FOREVER_LOG");
    g_log = path ? fopen(path, "w") : stderr;
    const char *mode = getenv("FOREVER_MODE");
    g_patch = mode && !strcmp(mode, "patch");
    const char *grp = getenv("FOREVER_REGION_GROUP"); if (grp) g_group = atoi(grp);
    const char *pk = getenv("FOREVER_PUBKEY"); if (!pk) pk = DEFAULT_PUBKEY;
    if (!hex2bin(pk, g_new_key, 32)) { lg("bad FOREVER_PUBKEY"); return NULL; }
    lg("injected pid %d  mode=%s  region_group=%d", getpid(), g_patch ? "patch" : "locate", g_group);
    hexline("server key", g_new_key, 32);

    // the store appears only once the client prepares the realm connection; keep looking, and (in patch mode)
    // re-apply if the client rebuilds it
    int announced = 0;
    for (int i = 0; i < 100000; i++) {
        if (g_patch) {
            g_patched = 0;
            int n = scan_stores(on_patch);
            if (n && !announced) { lg("store found and key applied (stores: %d)", n); announced = 1; }
        } else {
            g_seen = 0;
            int n = scan_stores(on_locate);
            lg("--- pass %d: %d store(s) ---", i + 1, n);
            if (n) break;
            if (i >= 24) { lg("no store after ~2 min (did you reach the realm list?)"); break; }
        }
        sleep(g_patch ? 3 : 5);
    }
    lg("done");
    if (g_log && g_log != stderr) fclose(g_log);
    return NULL;
}

__attribute__((constructor))
static void start(void) {
    pthread_t th; pthread_create(&th, NULL, worker, NULL); pthread_detach(th);
}
