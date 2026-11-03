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
static const uint8_t SEED[32] = {
    0x66,0xBE,0x29,0x79,0xEF,0xF2,0xD5,0xB5,0x61,0x53,0xF6,0x5F,0x45,0xAE,0x81,0xCB,
    0x32,0xEC,0x94,0xEC,0x75,0xB3,0x5F,0x44,0x6A,0x63,0x43,0x67,0x17,0x20,0x44,0x34};

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
__attribute__((unused)) static int key_like(const uint8_t *p) {
    int seen[256] = {0}, n = 0;
    for (int i = 0; i < 32; i++) if (!seen[p[i]]++) n++;
    return n >= 24;
}

static void dump(const char *tag, uint64_t va, int len) {
    if (!mapped(va, len)) return;
    const uint8_t *p = (const uint8_t *)va;
    for (int o = 0; o < len; o += 32) {
        char line[160]; int c = 0;
        c += snprintf(line + c, sizeof line - c, "  %s %#llx ", tag, (unsigned long long)(va + o));
        for (int k = 0; k < 32 && o + k < len; k++) c += snprintf(line + c, sizeof line - c, "%02x", p[o + k]);
        lg("%s", line);
    }
}

static uint64_t find_const(const uint8_t *needle, size_t n) {
    const struct load_command *lc = (const void *)(g_hdr + 1);
    for (uint32_t i = 0; i < g_hdr->ncmds; i++) {
        if (lc->cmd == LC_SEGMENT_64) {
            const struct segment_command_64 *sg = (const void *)lc;
            if (sg->filesize) {
                void *hit = memmem((const uint8_t *)(sg->vmaddr + g_slide), sg->filesize, needle, n);
                if (hit) return (uint64_t)hit;
            }
        }
        lc = (const void *)((const char *)lc + lc->cmdsize);
    }
    return 0;
}

// the verify routine: the one code window that forms BOTH the context and the seed address. Dump every other address
// it forms there, and if that address holds a pointer into the image, the 32 bytes it points at (the key, or its home).
static void locate_verify(void) {
    unsigned long sz = 0;
    const uint8_t *t = getsectiondata(g_hdr, "__TEXT", "__text", &sz);
    if (!t) { lg("no __TEXT,__text"); return; }
    uint64_t tv = (uint64_t)t, nwords = sz / 4;
    const uint32_t *w = (const uint32_t *)t;
    uint64_t ctx = find_const(CONTEXT, sizeof CONTEXT), seed = find_const(SEED, sizeof SEED);
    lg("context %#llx  seed %#llx", (unsigned long long)ctx, (unsigned long long)seed);
    if (!ctx || !seed) { lg("context or seed not in memory yet"); return; }

    int found = 0;
    for (uint64_t i = 0; i + 8 < nwords; i++) {
        uint64_t pc = tv + 4 * i;
        uint64_t tg = adrp_target(w + i, pc, 7);
        if (!tg || tg < ctx - CONST_WINDOW || tg > ctx + CONST_WINDOW) continue;   // a use of the context
        // does the same window also form the seed address?
        uint64_t lo = (pc > tv + CODE_WINDOW) ? pc - CODE_WINDOW : tv;
        int has_seed = 0;
        for (uint64_t pc2 = lo; pc2 < pc + CODE_WINDOW && pc2 + 32 < tv + sz; pc2 += 4) {
            uint64_t t2 = adrp_target(w + (pc2 - tv) / 4, pc2, 7);
            if (t2 && t2 >= seed - CONST_WINDOW && t2 <= seed + CONST_WINDOW) { has_seed = 1; break; }
        }
        if (!has_seed) continue;
        found++;
        lg("verify site %#llx (ctx%+lld)", (unsigned long long)pc, (long long)(tg - ctx));
        for (uint64_t pc2 = lo; pc2 < pc + CODE_WINDOW && pc2 + 32 < tv + sz; pc2 += 4) {
            uint64_t t2 = adrp_target(w + (pc2 - tv) / 4, pc2, 7);
            if (!t2) continue;
            if (t2 >= ctx - CONST_WINDOW && t2 <= ctx + CONST_WINDOW) continue;
            if (t2 >= seed - CONST_WINDOW && t2 <= seed + CONST_WINDOW) continue;
            lg("  operand %#llx (pc %#llx)", (unsigned long long)t2, (unsigned long long)pc2);
            dump("    bytes", t2, 64);
            if (mapped(t2, 8)) {                       // maybe a pointer (or array of pointers) to the key
                for (int e = 0; e < 8; e++) {
                    uint64_t ptr = *(const uint64_t *)(t2 + 8 * e);
                    if (mapped(ptr, 32)) { lg("    ptr[%d]=%#llx ->", e, (unsigned long long)ptr); dump("      at", ptr, 64); }
                }
            }
        }
    }
    lg("verify sites: %d", found);
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

// dump a plain vmaddr range (runtime = vmaddr + slide) in full, 32 bytes a line: used to bring a clean window of the
// key-table region out for off-line analysis. Reads only.
static void dump_range(uint64_t vmaddr, uint64_t len) {
    uint64_t va = vmaddr + (uint64_t)g_slide;
    lg("range vmaddr %#llx runtime %#llx len %#llx", (unsigned long long)vmaddr, (unsigned long long)va,
       (unsigned long long)len);
    if (!mapped(va, len)) { lg("range not mapped"); return; }
    const uint8_t *p = (const uint8_t *)va;
    for (uint64_t o = 0; o < len; o += 32) {
        char line[160]; int c = 0;
        c += snprintf(line + c, sizeof line - c, "r %#llx ", (unsigned long long)(vmaddr + o));
        for (int k = 0; k < 32 && o + k < len; k++) c += snprintf(line + c, sizeof line - c, "%02x", p[o + k]);
        lg("%s", line);
    }
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
    const char *dump_spec = getenv("FOREVER_DUMP");   // "0xVMADDR:0xLEN": bring a clean data window out for analysis
    const char *mode = getenv("FOREVER_MODE");
    // the protector decrypts the code during startup; try a few times while it comes up
    for (int attempt = 1; attempt <= 6; attempt++) {
        lg("--- attempt %d (%d s) ---", attempt, attempt * 5);
        sleep(5);
        if (dump_spec) {
            uint64_t vm = 0, len = 0;
            if (sscanf(dump_spec, "%llx:%llx", (unsigned long long *)&vm, (unsigned long long *)&len) == 2 && len) {
                dump_range(vm, len);
                break;
            }
            lg("bad FOREVER_DUMP=%s (want 0xVMADDR:0xLEN)", dump_spec);
            break;
        }
        if (mode && !strcmp(mode, "verify")) locate_verify();
        else locate();
    }
    lg("done");
    if (g_log && g_log != stderr) fclose(g_log);
    return NULL;
}

__attribute__((constructor))
static void start(void) {
    pthread_t th; pthread_create(&th, NULL, worker, NULL); pthread_detach(th);
}
