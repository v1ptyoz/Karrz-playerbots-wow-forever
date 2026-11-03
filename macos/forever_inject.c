// WoW Forever Bots: in-memory key locator (macOS, Apple Silicon).
//
// Loaded into a prepared COPY of the game with DYLD_INSERT_LIBRARIES (the original app is never touched). The 70707
// client keeps its code encrypted on disk and decrypts it into memory at startup, so the key table cannot be found or
// changed in the file. This module runs inside the running copy, where the code is already plain, and:
//   FOREVER_MODE=locate (default) - finds where the code loads the EnableEncryptionContext constant and dumps a few
//                                   small windows of the data loaded right next to it, for off-line analysis. Reads
//                                   only; changes nothing.
//   FOREVER_MODE=patch            - (added once the table is confirmed) overwrites the region-group entry with the
//                                   server key in memory.
// Output goes to the file named by FOREVER_LOG. This is interop with a private server the user runs, not DRM removal:
// it only substitutes the Ed25519 public key the client uses to verify the server's EnterEncryptedMode packet.
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <mach-o/getsect.h>
#include <pthread.h>
#include <stdint.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const uint8_t CONTEXT[16] = {
    0xA7,0x1F,0xB6,0x9B,0xC9,0x7C,0xDD,0x96,0xE9,0xBB,0xB8,0x21,0x39,0x8D,0x5A,0xD4};

#define CONST_WINDOW 0x800     // how far (bytes) a loaded address may be from the context to count as "the same use"
#define CODE_WINDOW  0x800     // how far in the code to look around such a use for other loads
#define REGION_GROUP 8

static FILE *g_log;
static void lg(const char *fmt, ...) {
    if (!g_log) return;
    va_list a; va_start(a, fmt); vfprintf(g_log, fmt, a); va_end(a);
    fputc('\n', g_log); fflush(g_log);
}

// the main executable's __TEXT,__text (decrypted in memory) and the mapped byte range of the image
static const struct mach_header_64 *g_hdr;
static intptr_t g_slide;

static const uint8_t *text_ptr; static uint64_t text_vmaddr, text_size;

// is this runtime address inside a mapped, readable part of the main image? (so we never read an unmapped page)
static int mapped(uint64_t va, uint64_t len) {
    const struct load_command *lc = (const void *)(g_hdr + 1);
    for (uint32_t i = 0; i < g_hdr->ncmds; i++) {
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *sg = (const void *)lc;
            uint64_t lo = sg->vmaddr + g_slide;
            if (sg->filesize && va >= lo && va + len <= lo + sg->filesize) return 1;
        }
        lc = (const void *)((const char *)lc + lc->cmdsize);
    }
    return 0;
}

// decode an ADRP at p (+ a following ADD/LDR on the same register) to the address it forms; 0 if it is not one
static uint64_t adrp_target(const uint32_t *w, uint64_t pc, int n_ahead) {
    uint32_t a = w[0];
    if ((a & 0x9F000000) != 0x90000000) return 0;
    int rd = a & 31;
    int64_t imm = (int64_t)((((a >> 5) & 0x7FFFF) << 2) | ((a >> 29) & 3));
    if (imm & (1 << 20)) imm -= (1 << 21);
    uint64_t page = (pc & ~0xFFFULL) + ((uint64_t)imm << 12);
    for (int j = 1; j <= n_ahead; j++) {
        uint32_t b = w[j];
        if (((b >> 5) & 31) != rd) continue;
        if ((b & 0xFF800000) == 0x91000000)               // ADD Xd,Xn,#imm{,LSL12}
            return page + (((b >> 10) & 0xFFF) << (12 * ((b >> 22) & 1)));
        if ((b & 0xFFC00000) == 0xF9400000)               // LDR Xt,[Xn,#imm]
            return page + ((uint64_t)((b >> 10) & 0xFFF) * 8);
        if ((b & 0xFFC00000) == 0x3DC00000)               // LDR Qt,[Xn,#imm]
            return page + ((uint64_t)((b >> 10) & 0xFFF) * 16);
    }
    return 0;
}

// a 32-byte block that could be an Ed25519 public key has many distinct bytes; code, text and zero padding do not
static int key_like(const uint8_t *p) {
    int seen[256] = {0}, n = 0;
    for (int i = 0; i < 32; i++) if (!seen[p[i]]++) n++;
    return n >= 24;
}

static void dump(const char *tag, uint64_t va, int len) {
    if (!mapped(va, len)) return;                      // only the key-like windows are logged, to keep it small
    const uint8_t *p = (const uint8_t *)va;
    if (!key_like(p)) return;
    for (int o = 0; o < len; o += 32) {
        char line[160]; int c = 0;
        c += snprintf(line + c, sizeof line - c, "  %s %#llx ", tag, (unsigned long long)(va + o));
        for (int k = 0; k < 32 && o + k < len; k++) c += snprintf(line + c, sizeof line - c, "%02x", p[o + k]);
        lg("%s", line);
    }
}

static void locate(void) {
    unsigned long sz = 0;
    const uint8_t *t = getsectiondata(g_hdr, "__TEXT", "__text", &sz);
    if (!t) { lg("no __TEXT,__text in the running image"); return; }
    text_ptr = t; text_size = sz; text_vmaddr = (uint64_t)t;
    lg("__text at %#llx size %#lx (slide %#lx)", (uint64_t)t, sz, (long)g_slide);

    // the context constant's runtime address: search the image's mapped segments
    uint64_t ctx = 0;
    const struct load_command *lc = (const void *)(g_hdr + 1);
    for (uint32_t i = 0; i < g_hdr->ncmds && !ctx; i++) {
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *sg = (const void *)lc;
            if (sg->filesize) {
                const uint8_t *base = (const uint8_t *)(sg->vmaddr + g_slide);
                void *hit = memmem(base, sg->filesize, CONTEXT, sizeof CONTEXT);
                if (hit) ctx = (uint64_t)hit;
            }
        }
        lc = (const void *)((const char *)lc + lc->cmdsize);
    }
    if (!ctx) { lg("context constant not found in memory yet"); return; }
    lg("context at %#llx", ctx);

    // pass 1: code that forms an address within CONST_WINDOW of the context
    const uint32_t *w = (const uint32_t *)text_ptr;
    uint64_t nwords = text_size / 4;
    int sites = 0;
    for (uint64_t i = 0; i + 8 < nwords; i++) {
        uint64_t pc = text_vmaddr + 4 * i;
        uint64_t tgt = adrp_target(w + i, pc, 7);
        if (!tgt || tgt < ctx - CONST_WINDOW || tgt > ctx + CONST_WINDOW) continue;
        sites++;
        lg("site %#llx -> %#llx (ctx%+lld)", pc, tgt, (long long)(tgt - ctx));
        // pass 2: other addresses the code forms within CODE_WINDOW of this site
        uint64_t lo = (pc > text_vmaddr + CODE_WINDOW) ? pc - CODE_WINDOW : text_vmaddr;
        for (uint64_t pc2 = lo; pc2 < pc + CODE_WINDOW && pc2 + 32 < text_vmaddr + text_size; pc2 += 4) {
            uint64_t j = (pc2 - text_vmaddr) / 4;
            uint64_t t2 = adrp_target(w + j, pc2, 7);
            if (!t2 || (t2 >= ctx - CONST_WINDOW && t2 <= ctx + CONST_WINDOW)) continue;
            dump("loads", t2, 384);
        }
    }
    lg("sites: %d", sites);
}

static void *worker(void *arg) {
    (void)arg;
    const char *path = getenv("FOREVER_LOG");
    g_log = path ? fopen(path, "w") : stderr;
    lg("injected into pid %d", getpid());
    // the main executable (MH_EXECUTE); image 0 with our dylib inserted can be this module itself, which also
    // carries the context constant, so pick by file type instead of by index
    uint32_t count = _dyld_image_count();
    g_hdr = NULL;
    for (uint32_t i = 0; i < count; i++) {
        const struct mach_header_64 *h = (const struct mach_header_64 *)_dyld_get_image_header(i);
        if (h && h->filetype == MH_EXECUTE) {
            g_hdr = h;
            g_slide = _dyld_get_image_vmaddr_slide(i);
            lg("main executable: image %u \"%s\" slide %#lx", i, _dyld_get_image_name(i), (long)g_slide);
            break;
        }
    }
    if (!g_hdr) { lg("no MH_EXECUTE image found"); return NULL; }
    // the protector decrypts the code during startup; try a few times while it comes up
    for (int attempt = 1; attempt <= 6; attempt++) {
        lg("--- attempt %d (%d s) ---", attempt, attempt * 5);
        sleep(5);
        locate();
    }
    lg("done");
    if (g_log && g_log != stderr) fclose(g_log);
    return NULL;
}

__attribute__((constructor))
static void start(void) {
    pthread_t th; pthread_create(&th, NULL, worker, NULL); pthread_detach(th);
}
