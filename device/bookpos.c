/* bookpos - map AlReader character positions to CrossPoint XPaths and back.
 *
 * usage:
 *   bookpos table <dir-with-unpacked-epub> [out.txt]
 *   bookpos to-xpath <table.txt> <alreaderPos> <sz>
 *   bookpos to-pos   <table.txt> <xpath> <sz>
 *
 * table.txt:
 *   <offset> <chars> <fragment> <elementPath>     (one line per text node)
 *   TOTAL <chars>                                  (last line)
 * elementPath is empty for text sitting directly in <body>.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <ctype.h>

static long g_total = 0;
static int  g_frag = 0;
static FILE *g_out = NULL;

static char *read_file(const char *path, size_t *len) {
  FILE *f = fopen(path, "rb");
  if (!f) return NULL;
  fseek(f, 0, SEEK_END);
  long n = ftell(f);
  fseek(f, 0, SEEK_SET);
  char *b = (char *)malloc((size_t)n + 1);
  if (!b) { fclose(f); return NULL; }
  size_t got = fread(b, 1, (size_t)n, f);
  fclose(f);
  b[got] = 0;
  if (len) *len = got;
  return b;
}

static int is_space(int c) { return c == ' ' || c == '\t' || c == '\r' || c == '\n'; }

static long utf8_len(const char *s, size_t bytes) {
  long n = 0;
  for (size_t i = 0; i < bytes; i++)
    if (((unsigned char)s[i] & 0xC0) != 0x80) n++;
  return n;
}

static int tag_is(const char *name, const char *want) {
  while (*name && *want) {
    if (tolower((unsigned char)*name) != tolower((unsigned char)*want)) return 0;
    name++; want++;
  }
  return *name == 0 && *want == 0;
}

static int is_block(const char *t) {
  static const char *b[] = {"p","div","h1","h2","h3","h4","h5","h6","li","tr",
                            "blockquote","section","article","td","th",NULL};
  for (int i = 0; b[i]; i++) if (tag_is(t, b[i])) return 1;
  return 0;
}
static int is_skip(const char *t) {
  return tag_is(t,"head") || tag_is(t,"style") || tag_is(t,"script") || tag_is(t,"title");
}
static int is_void(const char *t) {
  static const char *v[] = {"br","img","hr","meta","link","input","area","base","col","embed","source",NULL};
  for (int i = 0; v[i]; i++) if (tag_is(t, v[i])) return 1;
  return 0;
}

/* ---------- element stack with per-parent sibling counters ---------- */
#define MAXD 192
#define MAXN 64

typedef struct { char name[48]; int index; int skip; } Elem;
static Elem st[MAXD];
static int sp = 0;

typedef struct { char name[48]; int count; } Counter;
static Counter cnt[MAXD][MAXN];
static int ncnt[MAXD];

static void push_elem(const char *name, int skip) {
  if (sp >= MAXD) return;
  int parent = sp - 1;
  if (parent < 0) parent = 0;
  int idx = 1;
  int found = 0;
  for (int i = 0; i < ncnt[parent]; i++) {
    if (tag_is(cnt[parent][i].name, name)) { cnt[parent][i].count++; idx = cnt[parent][i].count; found = 1; break; }
  }
  if (!found && ncnt[parent] < MAXN) {
    snprintf(cnt[parent][ncnt[parent]].name, sizeof cnt[0][0].name, "%s", name);
    cnt[parent][ncnt[parent]].count = 1;
    ncnt[parent]++;
  }
  snprintf(st[sp].name, sizeof st[0].name, "%s", name);
  st[sp].index = idx;
  st[sp].skip = skip;
  sp++;
  ncnt[sp < MAXD ? sp : MAXD-1] = 0;
}

static void build_path(char *dst, size_t cap) {
  dst[0] = 0;
  size_t used = 0;
  for (int i = 0; i < sp; i++) {
    if (tag_is(st[i].name, "body") || tag_is(st[i].name, "html")) continue;
    int n = snprintf(dst + used, cap - used, "/%s[%d]", st[i].name, st[i].index);
    if (n < 0 || (size_t)n >= cap - used) break;
    used += (size_t)n;
  }
}

static int in_skip(void) {
  for (int i = 0; i < sp; i++) if (st[i].skip) return 1;
  return 0;
}

/* ---------- entities ---------- */
static size_t decode_entities(const char *src, char *dst, size_t cap) {
  size_t o = 0, i = 0;
  while (src[i] && o + 6 < cap) {
    if (src[i] == '&') {
      if (!strncmp(src+i, "&amp;", 5))  { dst[o++] = '&'; i += 5; continue; }
      if (!strncmp(src+i, "&lt;", 4))   { dst[o++] = '<'; i += 4; continue; }
      if (!strncmp(src+i, "&gt;", 4))   { dst[o++] = '>'; i += 4; continue; }
      if (!strncmp(src+i, "&quot;", 6)) { dst[o++] = '"'; i += 6; continue; }
      if (!strncmp(src+i, "&apos;", 6)) { dst[o++] = '\''; i += 6; continue; }
      if (!strncmp(src+i, "&nbsp;", 6)) { dst[o++] = ' '; i += 6; continue; }
      if (src[i+1] == '#') {
        long code = 0; size_t k = i + 2; int hex = 0;
        if (src[k] == 'x' || src[k] == 'X') { hex = 1; k++; }
        while (src[k] && src[k] != ';') {
          code = code * (hex ? 16 : 10) + (hex ? (isdigit((unsigned char)src[k]) ? src[k]-'0' : (tolower((unsigned char)src[k])-'a'+10)) : (src[k]-'0'));
          k++;
        }
        if (src[k] == ';') {
          if (code < 0x80) dst[o++] = (char)code;
          else if (code < 0x800) { dst[o++] = (char)(0xC0 | (code >> 6)); dst[o++] = (char)(0x80 | (code & 0x3F)); }
          else { dst[o++] = (char)(0xE0 | (code >> 12)); dst[o++] = (char)(0x80 | ((code >> 6) & 0x3F)); dst[o++] = (char)(0x80 | (code & 0x3F)); }
          i = k + 1;
          continue;
        }
      }
    }
    dst[o++] = src[i++];
  }
  dst[o] = 0;
  return o;
}

/* ---------- text ---------- */
static void emit_text(const char *s, size_t len) {
  if (!g_out || len == 0 || in_skip()) return;
  long chars = utf8_len(s, len);
  if (chars == 0) return;
  char path[512];
  build_path(path, sizeof path);
  fprintf(g_out, "%ld %ld %d %s\n", g_total, chars, g_frag, path);
  g_total += chars;
}

/* ---------- xhtml ---------- */
static void parse_xhtml(const char *buf, size_t len) {
  size_t i = 0;
  while (i < len) {
    if (buf[i] == '<') {
      if (i + 3 < len && buf[i+1] == '!' && buf[i+2] == '-' && buf[i+3] == '-') {
        i += 4;
        while (i + 2 < len && !(buf[i] == '-' && buf[i+1] == '-' && buf[i+2] == '>')) i++;
        i = (i + 3 < len) ? i + 3 : len;
        continue;
      }
      if (i + 1 < len && (buf[i+1] == '?' || buf[i+1] == '!')) {
        while (i < len && buf[i] != '>') i++;
        i++;
        continue;
      }
      int closing = (i + 1 < len && buf[i+1] == '/');
      size_t j = i + (closing ? 2 : 1);
      char name[48]; int nl = 0;
      while (j < len && (isalnum((unsigned char)buf[j]) || buf[j]=='-' || buf[j]==':' || buf[j]=='_')) {
        if (nl < (int)sizeof(name) - 1) name[nl++] = buf[j];
        j++;
      }
      name[nl] = 0;

      if (closing) {
        int blk = 0;
        for (int k = sp - 1; k >= 0; k--) {
          int match = tag_is(st[k].name, name);
          int wasblock = is_block(st[k].name) && !st[k].skip;
          if (match) { sp = k; if (wasblock) blk = 1; break; }
        }
        if (blk) g_total += 1;
      } else {
        int selfc = 0;
        size_t t = j;
        int quote = 0;
        while (t < len && buf[t] != '>') {
          if (buf[t] == '"' || buf[t] == '\'') quote = !quote;
          if (!quote && buf[t] == '/' && t + 1 < len && buf[t+1] == '>') selfc = 1;
          t++;
        }
        if (tag_is(name, "br")) { g_total += 1; }
        else if (!selfc && !is_void(name)) push_elem(name, is_skip(name));
      }
      while (i < len && buf[i] != '>') i++;
      i++;
      continue;
    }

    size_t start = i;
    while (i < len && buf[i] != '<') i++;
    if (i > start) {
      size_t a = start, b = i;
      while (a < b && is_space((unsigned char)buf[a])) a++;
      while (b > a && is_space((unsigned char)buf[b-1])) b--;
      if (b > a) {
        static char tmp[1 << 16];
        size_t n = b - a;
        if (n >= sizeof tmp) n = sizeof tmp - 1;
        size_t dn = decode_entities(buf + a, tmp, sizeof tmp);
        emit_text(tmp, dn);
      }
    }
  }
}

/* ---------- opf helpers ---------- */
static char *attr_value(const char *tag, size_t len, const char *name, char *out, size_t cap) {
  size_t nl = strlen(name);
  for (size_t i = 0; i + nl + 3 < len; i++) {
    if ((i == 0 || is_space((unsigned char)tag[i-1])) &&
        strncasecmp(tag + i, name, nl) == 0 && tag[i+nl] == '=') {
      size_t k = i + nl + 1;
      char q = tag[k];
      if (q != '"' && q != '\'') continue;
      k++;
      size_t m = 0;
      while (k < len && tag[k] != q && m + 1 < cap) out[m++] = tag[k++];
      out[m] = 0;
      return out;
    }
  }
  return NULL;
}

static int read_total(FILE *f, long *total) {
  char line[512];
  long t = -1;
  while (fgets(line, sizeof line, f)) {
    if (!strncmp(line, "TOTAL", 5)) { sscanf(line + 6, "%ld", &t); break; }
  }
  rewind(f);
  if (t < 0) return 0;
  *total = t;
  return 1;
}

int main(int argc, char **argv) {
  if (argc < 3) {
    fprintf(stderr, "usage: bookpos table <dir> [out] | to-xpath <table> <pos> <sz> | to-pos <table> <xpath> <sz>\n");
    return 2;
  }

  if (!strcmp(argv[1], "table")) {
    const char *dir = argv[2];
    char path[1200];
    snprintf(path, sizeof path, "%s/META-INF/container.xml", dir);
    char *cont = read_file(path, NULL);
    if (!cont) { fprintf(stderr, "no container.xml in %s\n", dir); return 1; }
    char opfrel[512] = {0};
    if (!attr_value(cont, strlen(cont), "full-path", opfrel, sizeof opfrel)) { fprintf(stderr, "no full-path\n"); return 1; }
    free(cont);

    snprintf(path, sizeof path, "%s/%s", dir, opfrel);
    char *opf = read_file(path, NULL);
    if (!opf) { fprintf(stderr, "no opf %s\n", path); return 1; }

    static char ids[1024][64], hrefs[1024][256];
    int nman = 0;
    for (char *p = opf; (p = strstr(p, "<item")) != NULL; p += 5) {
      if (p[5] != ' ' && p[5] != '>' && p[5] != '\n' && p[5] != '\r' && p[5] != '\t') continue;
      char *end = strchr(p, '>');
      if (!end) break;
      char id[64] = {0}, href[256] = {0};
      if (attr_value(p, (size_t)(end - p), "id", id, sizeof id) &&
          attr_value(p, (size_t)(end - p), "href", href, sizeof href) && nman < 1024) {
        snprintf(ids[nman], 64, "%s", id);
        snprintf(hrefs[nman], 256, "%s", href);
        nman++;
      }
      p = end;
    }

    static int spine[1024]; int nsp = 0;
    for (char *p = opf; (p = strstr(p, "<itemref")) != NULL; p += 8) {
      char *end = strchr(p, '>');
      if (!end) break;
      char idref[64] = {0};
      if (attr_value(p, (size_t)(end - p), "idref", idref, sizeof idref)) {
        for (int i = 0; i < nman; i++) if (!strcmp(ids[i], idref)) { if (nsp < 1024) spine[nsp++] = i; break; }
      }
      p = end;
    }

    char opf_dir[512] = {0};
    { char *slash = strrchr(opfrel, '/'); if (slash) { size_t n = (size_t)(slash - opfrel); memcpy(opf_dir, opfrel, n); opf_dir[n] = 0; } }

    g_out = (argc >= 4) ? fopen(argv[3], "w") : stdout;
    if (!g_out) { fprintf(stderr, "cannot open output\n"); return 1; }

    for (int s = 0; s < nsp; s++) {
      char f[1400];
      if (opf_dir[0]) snprintf(f, sizeof f, "%s/%s/%s", dir, opf_dir, hrefs[spine[s]]);
      else snprintf(f, sizeof f, "%s/%s", dir, hrefs[spine[s]]);
      size_t len = 0;
      char *b = read_file(f, &len);
      if (!b) { fprintf(stderr, "warn: missing %s\n", f); continue; }
      sp = 0; ncnt[0] = 0;
      g_frag = s + 1;
      parse_xhtml(b, len);
      free(b);
    }

    fprintf(g_out, "TOTAL %ld\n", g_total);
    if (g_out != stdout) fclose(g_out);
    free(opf);
    return 0;
  }

  if (!strcmp(argv[1], "to-xpath")) {
    long total = 0, pos = atol(argv[3]), sz = atol(argv[4]);
    FILE *f = fopen(argv[2], "r");
    if (!f) { fprintf(stderr, "no table\n"); return 1; }
    if (!read_total(f, &total) || total <= 0 || sz <= 0) { fprintf(stderr, "bad table\n"); return 1; }
    long want = (long)((double)pos * (double)total / (double)sz);
    char line[1024]; char path[512] = {0}; long off = -1, ln = 0; int fr = 0;
    while (fgets(line, sizeof line, f)) {
      if (!strncmp(line, "TOTAL", 5)) continue;
      long o, l; int k; char pth[512] = {0};
      int n = sscanf(line, "%ld %ld %d %511s", &o, &l, &k, pth);
      if (n < 3) continue;
      if (n == 3) pth[0] = 0;
      if (o <= want && want < o + l) { off = o; ln = l; fr = k; snprintf(path, sizeof path, "%s", pth); break; }
      if (o <= want) { off = o; ln = l; fr = k; snprintf(path, sizeof path, "%s", pth); }
    }
    fclose(f);
    if (off < 0) { fprintf(stderr, "position out of range\n"); return 1; }
    printf("/body/DocFragment[%d]/body%s/text()[1].%ld\n", fr, path, want - off + 1);
    return 0;
  }

  if (!strcmp(argv[1], "to-pos")) {
    long total = 0, sz = atol(argv[4]);
    const char *xp = argv[3];
    int fr = 0; char path[512] = {0}; long k = 1;
    const char *p = strstr(xp, "DocFragment[");
    if (!p || sscanf(p + 12, "%d", &fr) != 1) { fprintf(stderr, "bad xpath\n"); return 1; }
    const char *b = strstr(p, "]/body");
    b = b ? b + 6 : "";
    const char *t = strstr(b, "/text()");
    size_t plen = t ? (size_t)(t - b) : strlen(b);
    if (plen >= sizeof path) plen = sizeof path - 1;
    memcpy(path, b, plen); path[plen] = 0;
    if (t) { const char *d = strrchr(t, '.'); if (d) k = atol(d + 1); }

    FILE *f = fopen(argv[2], "r");
    if (!f) { fprintf(stderr, "no table\n"); return 1; }
    if (!read_total(f, &total) || total <= 0 || sz <= 0) { fprintf(stderr, "bad table\n"); return 1; }

    char line[1024]; long off = -1; long first_frag = -1;
    while (fgets(line, sizeof line, f)) {
      if (!strncmp(line, "TOTAL", 5)) continue;
      long o, l; int fr2; char pth[512] = {0};
      int n = sscanf(line, "%ld %ld %d %511s", &o, &l, &fr2, pth);
      if (n < 3) continue;
      if (n == 3) pth[0] = 0;
      if (fr2 != fr) continue;
      if (first_frag < 0) first_frag = o;
      if (!strcmp(pth, path)) { off = o; break; }
    }
    fclose(f);
    if (off < 0) off = first_frag;
    if (off < 0) { fprintf(stderr, "fragment %d not found\n", fr); return 1; }
    long want = off + (k > 0 ? k - 1 : 0);
    printf("%ld\n", (long)((double)want * (double)sz / (double)total));
    return 0;
  }

  fprintf(stderr, "unknown command\n");
  return 2;
}
