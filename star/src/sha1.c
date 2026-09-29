/* SPDX-License-Identifier: MIT
 *
 * sha1.c -- SHA-1 (FIPS 180-4), for Spack's DAG hash: the base32 SHA-1 of a
 * node's JSON (spack.util.hash.b32_hash). Not for integrity; sha256.c is.
 */

typedef struct Sha1 {
    uint32_t h[5];
    unsigned char buf[64];
    int nbuf;
    uint64_t len;
} Sha1;

#define ROL32(x, n) (((x) << (n)) | ((x) >> (32 - (n))))

static void sha1_block(Sha1 *s, const unsigned char *p)
{
    uint32_t w[80], a, b, c, d, e, f, k, t;
    int i;
    for (i = 0; i < 16; i++)
        w[i] = (uint32_t)p[4 * i] << 24 | (uint32_t)p[4 * i + 1] << 16 |
               (uint32_t)p[4 * i + 2] << 8 | (uint32_t)p[4 * i + 3];
    for (i = 16; i < 80; i++)
        w[i] = ROL32(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1);
    a = s->h[0]; b = s->h[1]; c = s->h[2]; d = s->h[3]; e = s->h[4];
    for (i = 0; i < 80; i++) {
        if (i < 20) {
            f = (b & c) | (~b & d);
            k = 0x5a827999;
        } else if (i < 40) {
            f = b ^ c ^ d;
            k = 0x6ed9eba1;
        } else if (i < 60) {
            f = (b & c) | (b & d) | (c & d);
            k = 0x8f1bbcdc;
        } else {
            f = b ^ c ^ d;
            k = 0xca62c1d6;
        }
        t = ROL32(a, 5) + f + e + k + w[i];
        e = d; d = c; c = ROL32(b, 30); b = a; a = t;
    }
    s->h[0] += a; s->h[1] += b; s->h[2] += c; s->h[3] += d; s->h[4] += e;
}

static void sha1_init(Sha1 *s)
{
    s->h[0] = 0x67452301;
    s->h[1] = 0xefcdab89;
    s->h[2] = 0x98badcfe;
    s->h[3] = 0x10325476;
    s->h[4] = 0xc3d2e1f0;
    s->nbuf = 0;
    s->len = 0;
}

static void sha1_update(Sha1 *s, const void *data, size_t n)
{
    const unsigned char *p = data;
    s->len += n;
    while (n) {
        size_t take = 64 - s->nbuf;
        if (take > n)
            take = n;
        memcpy(s->buf + s->nbuf, p, take);
        s->nbuf += (int)take;
        p += take;
        n -= take;
        if (s->nbuf == 64) {
            sha1_block(s, s->buf);
            s->nbuf = 0;
        }
    }
}

static void sha1_hex(Sha1 *s, char out[41])
{
    static const char hexd[] = "0123456789abcdef";
    uint64_t bits = s->len * 8;
    unsigned char pad = 0x80, zero = 0, lenb[8];
    int i;
    sha1_update(s, &pad, 1);
    while (s->nbuf != 56)
        sha1_update(s, &zero, 1);
    for (i = 0; i < 8; i++)
        lenb[i] = (unsigned char)(bits >> (56 - 8 * i));
    sha1_update(s, lenb, 8);
    for (i = 0; i < 20; i++) {
        unsigned char c = (unsigned char)(s->h[i / 4] >> (24 - 8 * (i % 4)));
        out[2 * i] = hexd[c >> 4];
        out[2 * i + 1] = hexd[c & 15];
    }
    out[40] = '\0';
}
