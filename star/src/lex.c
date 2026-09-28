/* SPDX-License-Identifier: MIT
 * lex.c -- the Starlark scanner: indentation-aware, whole file up front. */

#include <stdio.h>
#include <string.h>
#include "star.h"
#include "lex.h"

static const struct { const char *s; int tok; } keywords[] = {
    {"and", T_AND}, {"break", T_BREAK}, {"continue", T_CONTINUE},
    {"def", T_DEF}, {"elif", T_ELIF}, {"else", T_ELSE}, {"for", T_FOR},
    {"if", T_IF}, {"in", T_IN}, {"lambda", T_LAMBDA}, {"load", T_LOAD},
    {"not", T_NOT}, {"or", T_OR}, {"pass", T_PASS}, {"return", T_RETURN},
    {"while", T_WHILE}, {NULL, 0}
};

/* Python keywords Starlark reserves: using one is a syntax error. */
static const char *reserved[] = {
    "as", "async", "await", "class", "del", "except", "finally",
    "from", "global", "import", "is", "nonlocal", "raise", "try", "with",
    "yield", NULL
};

const char *token_str(int tok)
{
    static const char *names[] = {
        "end of file", "newline", "indent", "outdent", "identifier",
        "int literal", "string literal",
        "+", "-", "*", "/", "//", "%", "**", "&", "|", "^", "~", "<<", ">>",
        ".", ",", "=", ";", ":", "(", ")", "[", "]", "{", "}",
        "<", ">", ">=", "<=", "==", "!=",
        "+=", "-=", "*=", "/=", "//=", "%=", "&=", "|=", "^=", "<<=", ">>=",
        "and", "break", "continue", "def", "elif", "else", "for", "if", "in",
        "lambda", "load", "not", "not in", "or", "pass", "return", "while"
    };
    if (tok >= T_EOF && tok <= T_WHILE)
        return names[tok - T_EOF];
    return "?";
}

typedef struct Lexer {
    const char *file;
    const char *src;
    int len;
    int pos;
    int line, col;
    int depth;              /* bracket nesting */
    int indents[128];
    int nindent;
    Token *toks;
    int ntoks, cap;
    ErrList *errs;
    int failed;
} Lexer;

static void lex_err(Lexer *lx, int line, int col, const char *fmt, ...)
{
    va_list ap;
    Buf b;
    if (lx->failed)
        return;
    lx->failed = 1;
    buf_init(&b);
    {
        char tmp[512];
        va_start(ap, fmt);
        vsnprintf(tmp, sizeof tmp, fmt, ap);
        va_end(ap);
        buf_puts(&b, tmp);
    }
    lx->errs->pos = arena_grow(lx->errs->pos, sizeof(Pos) * lx->errs->n, sizeof(Pos) * (lx->errs->n + 1));
    lx->errs->msg = arena_grow(lx->errs->msg, sizeof(char *) * lx->errs->n, sizeof(char *) * (lx->errs->n + 1));
    lx->errs->pos[lx->errs->n].file = lx->file;
    lx->errs->pos[lx->errs->n].line = line;
    lx->errs->pos[lx->errs->n].col = col;
    lx->errs->msg[lx->errs->n] = buf_cstr(&b);
    lx->errs->n++;
}

static Token *emit(Lexer *lx, int kind, int line, int col)
{
    Token *t;
    if (lx->ntoks == lx->cap) {
        int ncap = lx->cap ? lx->cap * 2 : 256;
        lx->toks = arena_grow(lx->toks, sizeof(Token) * lx->cap, sizeof(Token) * ncap);
        lx->cap = ncap;
    }
    t = &lx->toks[lx->ntoks++];
    memset(t, 0, sizeof *t);
    t->kind = kind;
    t->line = line;
    t->col = col;
    return t;
}

static int peekc(Lexer *lx, int off)
{
    int p = lx->pos + off;
    return p < lx->len ? (unsigned char)lx->src[p] : -1;
}

static int nextc(Lexer *lx)
{
    int c;
    if (lx->pos >= lx->len)
        return -1;
    c = (unsigned char)lx->src[lx->pos++];
    if (c == '\n') {
        lx->line++;
        lx->col = 1;
    } else {
        lx->col++;
    }
    return c;
}

static int is_ident_start(int c)
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || c >= 0x80;
}

static int is_ident_char(int c)
{
    return is_ident_start(c) || (c >= '0' && c <= '9');
}

static int hexval(int c)
{
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

static void scan_string(Lexer *lx, int raw, int line, int col)
{
    int q = nextc(lx);
    int triple = 0;
    Buf b;
    Token *t;
    buf_init(&b);
    if (peekc(lx, 0) == q && peekc(lx, 1) == q) {
        nextc(lx);
        nextc(lx);
        triple = 1;
    }
    for (;;) {
        int c = peekc(lx, 0);
        if (c < 0) {
            lex_err(lx, line, col, "unexpected EOF in string");
            return;
        }
        if (c == '\n' && !triple) {
            lex_err(lx, line, col, "unexpected newline in string");
            return;
        }
        if (c == q) {
            if (!triple) {
                nextc(lx);
                break;
            }
            if (peekc(lx, 1) == q && peekc(lx, 2) == q) {
                nextc(lx);
                nextc(lx);
                nextc(lx);
                break;
            }
            buf_putc(&b, nextc(lx));
            continue;
        }
        if (c != '\\') {
            buf_putc(&b, nextc(lx));
            continue;
        }
        /* backslash */
        nextc(lx);
        c = peekc(lx, 0);
        if (c < 0) {
            lex_err(lx, line, col, "unexpected EOF in string");
            return;
        }
        if (raw) {
            /* raw: \<newline> is a continuation; the backslash stays otherwise */
            if (c == '\n') {
                nextc(lx);
                continue;
            }
            buf_putc(&b, '\\');
            buf_putc(&b, nextc(lx));
            continue;
        }
        nextc(lx);
        switch (c) {
        case '\n': break;
        case 'a': buf_putc(&b, 7); break;
        case 'b': buf_putc(&b, 8); break;
        case 'f': buf_putc(&b, 12); break;
        case 'n': buf_putc(&b, 10); break;
        case 'r': buf_putc(&b, 13); break;
        case 't': buf_putc(&b, 9); break;
        case 'v': buf_putc(&b, 11); break;
        case '\\': buf_putc(&b, '\\'); break;
        case '\'': buf_putc(&b, '\''); break;
        case '"': buf_putc(&b, '"'); break;
        case '0': case '1': case '2': case '3': case '4': case '5': case '6': case '7': {
            int v = c - '0', k;
            for (k = 0; k < 2 && peekc(lx, 0) >= '0' && peekc(lx, 0) <= '7'; k++)
                v = v * 8 + (nextc(lx) - '0');
            if (v > 255) {
                lex_err(lx, lx->line, lx->col, "octal escape value > 255: %d", v);
                return;
            }
            buf_putc(&b, v);
            break;
        }
        case 'x': {
            int h1 = hexval(peekc(lx, 0)), h2 = hexval(peekc(lx, 1));
            if (h1 < 0 || h2 < 0) {
                lex_err(lx, lx->line, lx->col, "truncated escape sequence \\x");
                return;
            }
            nextc(lx);
            nextc(lx);
            if (h1 * 16 + h2 > 127) {
                lex_err(lx, lx->line, lx->col,
                        "non-ASCII hex escape \\x%c%c (use \\u%04X)",
                        lx->src[lx->pos - 2], lx->src[lx->pos - 1], h1 * 16 + h2);
                return;
            }
            buf_putc(&b, h1 * 16 + h2);
            break;
        }
        case 'u': case 'U': {
            int n = c == 'u' ? 4 : 8, k, v = 0;
            char enc[4];
            for (k = 0; k < n; k++) {
                int h = hexval(peekc(lx, 0));
                if (h < 0) {
                    lex_err(lx, lx->line, lx->col, "truncated escape sequence \\%c", c);
                    return;
                }
                nextc(lx);
                v = v * 16 + h;
            }
            if (v > 0x10FFFF || (v >= 0xD800 && v < 0xE000)) {
                lex_err(lx, lx->line, lx->col, "invalid Unicode code point U+%04X", v);
                return;
            }
            buf_put(&b, enc, utf8_encode(enc, v));
            break;
        }
        default:
            lex_err(lx, lx->line, lx->col - 2, "invalid escape sequence \\%c", c);
            return;
        }
    }
    t = emit(lx, T_STRLIT, line, col);
    t->s = (Str *)mk_str(b.p ? b.p : "", (int)b.len);
}

static void scan_number(Lexer *lx, int line, int col)
{
    int start = lx->pos;
    int base = 10;
    int64_t v = 0;
    int ndig = 0, overflow = 0;
    Token *t;
    if (peekc(lx, 0) == '0' && (peekc(lx, 1) == 'x' || peekc(lx, 1) == 'X')) {
        base = 16;
        nextc(lx); nextc(lx);
    } else if (peekc(lx, 0) == '0' && (peekc(lx, 1) == 'o' || peekc(lx, 1) == 'O')) {
        base = 8;
        nextc(lx); nextc(lx);
    } else if (peekc(lx, 0) == '0' && (peekc(lx, 1) == 'b' || peekc(lx, 1) == 'B')) {
        base = 2;
        nextc(lx); nextc(lx);
    }
    for (;;) {
        int c = peekc(lx, 0), d;
        if (c == '_') {
            nextc(lx);
            continue;
        }
        d = hexval(c);
        if (d < 0 || d >= base) {
            if (base == 10 && c >= 0 && ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')) && c != 'e' && c != 'E')
                break;
            break;
        }
        nextc(lx);
        ndig++;
        if (v > (INT64_MAX - d) / base)
            overflow = 1;
        else
            v = v * base + d;
    }
    if (base == 10) {
        int c = peekc(lx, 0);
        if (c == '.' || c == 'e' || c == 'E') {
            lex_err(lx, line, col, "floating-point numbers are not supported");
            return;
        }
        if (lx->pos - start > 1 && lx->src[start] == '0') {
            int k, allzero = 1;
            for (k = start; k < lx->pos; k++)
                if (lx->src[k] != '0' && lx->src[k] != '_')
                    allzero = 0;
            if (!allzero) {
                lex_err(lx, line, col, "obsolete form of octal literal; use 0o%.*s",
                        lx->pos - start - 1, lx->src + start + 1);
                return;
            }
        }
    } else if (ndig == 0) {
        lex_err(lx, line, col, "invalid %s literal", base == 16 ? "hex" : base == 8 ? "octal" : "binary");
        return;
    }
    if (is_ident_char(peekc(lx, 0))) {
        lex_err(lx, line, col, "invalid int literal");
        return;
    }
    if (overflow) {
        lex_err(lx, line, col, "int literal %.*s out of range (ints are 64-bit)",
                lx->pos - start, lx->src + start);
        return;
    }
    t = emit(lx, T_INTLIT, line, col);
    t->ival = v;
}

Token *lex(const char *file, const char *src, int len, int *ntoks, ErrList *errs)
{
    Lexer L, *lx = &L;
    int bol = 1;            /* at beginning of a logical line */
    memset(lx, 0, sizeof L);
    lx->file = file;
    lx->src = src;
    lx->len = len;
    lx->line = 1;
    lx->col = 1;
    lx->errs = errs;
    lx->indents[0] = 0;
    lx->nindent = 1;

    while (!lx->failed) {
        int c, line, col;
        if (bol && lx->depth == 0) {
            /* measure indentation; skip blank and comment-only lines */
            int ind = 0;
            for (;;) {
                c = peekc(lx, 0);
                if (c == ' ') {
                    ind++;
                    nextc(lx);
                } else if (c == '\t') {
                    ind += 8 - ind % 8;
                    nextc(lx);
                } else if (c == '\r') {
                    nextc(lx);
                } else
                    break;
            }
            c = peekc(lx, 0);
            if (c == '#') {
                while (peekc(lx, 0) >= 0 && peekc(lx, 0) != '\n')
                    nextc(lx);
                c = peekc(lx, 0);
            }
            if (c == '\n') {
                nextc(lx);
                continue;
            }
            if (c == '\\' && peekc(lx, 1) == '\n') {
                nextc(lx);
                nextc(lx);
                continue;
            }
            if (c < 0)
                break;
            bol = 0;
            if (ind > lx->indents[lx->nindent - 1]) {
                if (lx->nindent == 128) {
                    lex_err(lx, lx->line, lx->col, "too many indentation levels");
                    break;
                }
                lx->indents[lx->nindent++] = ind;
                emit(lx, T_INDENT, lx->line, lx->col);
            } else {
                while (ind < lx->indents[lx->nindent - 1]) {
                    lx->nindent--;
                    emit(lx, T_OUTDENT, lx->line, lx->col);
                }
                if (ind != lx->indents[lx->nindent - 1]) {
                    lex_err(lx, lx->line, lx->col, "unindent does not match any outer indentation level");
                    break;
                }
            }
        }
        c = peekc(lx, 0);
        line = lx->line;
        col = lx->col;
        if (c < 0)
            break;
        if (c == ' ' || c == '\t' || c == '\r') {
            nextc(lx);
            continue;
        }
        if (c == '#') {
            while (peekc(lx, 0) >= 0 && peekc(lx, 0) != '\n')
                nextc(lx);
            continue;
        }
        if (c == '\\') {
            if (peekc(lx, 1) == '\n') {
                nextc(lx);
                nextc(lx);
                continue;
            }
            if (peekc(lx, 1) == '\r' && peekc(lx, 2) == '\n') {
                nextc(lx);
                nextc(lx);
                nextc(lx);
                continue;
            }
            lex_err(lx, line, col, "stray backslash in program");
            break;
        }
        if (c == '\n') {
            nextc(lx);
            if (lx->depth == 0) {
                emit(lx, T_NEWLINE, line, col);
                bol = 1;
            }
            continue;
        }
        if (c == '"' || c == '\'') {
            scan_string(lx, 0, line, col);
            continue;
        }
        if ((c == 'r' || c == 'R') && (peekc(lx, 1) == '"' || peekc(lx, 1) == '\'')) {
            nextc(lx);
            scan_string(lx, 1, line, col);
            continue;
        }
        if ((c == 'b' || c == 'B') && (peekc(lx, 1) == '"' || peekc(lx, 1) == '\'' ||
            ((peekc(lx, 1) == 'r' || peekc(lx, 1) == 'R') && (peekc(lx, 2) == '"' || peekc(lx, 2) == '\'')))) {
            lex_err(lx, line, col, "bytes literals are not supported");
            break;
        }
        if (c >= '0' && c <= '9') {
            scan_number(lx, line, col);
            continue;
        }
        if (c == '.' && peekc(lx, 1) >= '0' && peekc(lx, 1) <= '9') {
            lex_err(lx, line, col, "floating-point numbers are not supported");
            break;
        }
        if (is_ident_start(c)) {
            int start = lx->pos, k;
            Token *t;
            while (is_ident_char(peekc(lx, 0)))
                nextc(lx);
            for (k = 0; keywords[k].s; k++) {
                if ((int)strlen(keywords[k].s) == lx->pos - start &&
                    memcmp(keywords[k].s, src + start, lx->pos - start) == 0)
                    break;
            }
            if (keywords[k].s) {
                emit(lx, keywords[k].tok, line, col);
                continue;
            }
            for (k = 0; reserved[k]; k++) {
                if ((int)strlen(reserved[k]) == lx->pos - start &&
                    memcmp(reserved[k], src + start, lx->pos - start) == 0) {
                    lex_err(lx, line, col, "keyword %s is reserved", reserved[k]);
                    break;
                }
            }
            if (reserved[k])
                break;
            t = emit(lx, T_IDENT, line, col);
            t->s = intern_n(src + start, lx->pos - start);
            continue;
        }
        /* punctuation */
        {
            int tok = -1, n = 1;
            int c1 = peekc(lx, 1), c2 = peekc(lx, 2);
            switch (c) {
            case '+': tok = c1 == '=' ? (n = 2, T_PLUS_EQ) : T_PLUS; break;
            case '-': tok = c1 == '=' ? (n = 2, T_MINUS_EQ) : T_MINUS; break;
            case '*':
                if (c1 == '*') tok = (n = 2, T_STARSTAR);
                else if (c1 == '=') tok = (n = 2, T_STAR_EQ);
                else tok = T_STAR;
                break;
            case '/':
                if (c1 == '/') tok = c2 == '=' ? (n = 3, T_SLASHSLASH_EQ) : (n = 2, T_SLASHSLASH);
                else if (c1 == '=') tok = (n = 2, T_SLASH_EQ);
                else tok = T_SLASH;
                break;
            case '%': tok = c1 == '=' ? (n = 2, T_PERCENT_EQ) : T_PERCENT; break;
            case '&': tok = c1 == '=' ? (n = 2, T_AMP_EQ) : T_AMP; break;
            case '|': tok = c1 == '=' ? (n = 2, T_PIPE_EQ) : T_PIPE; break;
            case '^': tok = c1 == '=' ? (n = 2, T_CIRCUMFLEX_EQ) : T_CIRCUMFLEX; break;
            case '~': tok = T_TILDE; break;
            case '<':
                if (c1 == '<') tok = c2 == '=' ? (n = 3, T_LTLT_EQ) : (n = 2, T_LTLT);
                else if (c1 == '=') tok = (n = 2, T_LE);
                else tok = T_LT;
                break;
            case '>':
                if (c1 == '>') tok = c2 == '=' ? (n = 3, T_GTGT_EQ) : (n = 2, T_GTGT);
                else if (c1 == '=') tok = (n = 2, T_GE);
                else tok = T_GT;
                break;
            case '=': tok = c1 == '=' ? (n = 2, T_EQL) : T_EQ; break;
            case '!': if (c1 == '=') tok = (n = 2, T_NEQ); break;
            case '.': tok = T_DOT; break;
            case ',': tok = T_COMMA; break;
            case ';': tok = T_SEMI; break;
            case ':': tok = T_COLON; break;
            case '(': tok = T_LPAREN; lx->depth++; break;
            case '[': tok = T_LBRACK; lx->depth++; break;
            case '{': tok = T_LBRACE; lx->depth++; break;
            case ')': tok = T_RPAREN; if (lx->depth) lx->depth--; break;
            case ']': tok = T_RBRACK; if (lx->depth) lx->depth--; break;
            case '}': tok = T_RBRACE; if (lx->depth) lx->depth--; break;
            }
            if (tok < 0) {
                lex_err(lx, line, col, "unexpected input character %s%c%s",
                        c >= 32 && c < 127 ? "'" : "", c >= 32 && c < 127 ? c : '?',
                        c >= 32 && c < 127 ? "'" : "");
                break;
            }
            while (n--)
                nextc(lx);
            emit(lx, tok, line, col);
        }
    }
    if (!lx->failed) {
        if (!bol)
            emit(lx, T_NEWLINE, lx->line, lx->col);
        while (lx->nindent > 1) {
            lx->nindent--;
            emit(lx, T_OUTDENT, lx->line, lx->col);
        }
        emit(lx, T_EOF, lx->line, lx->col);
    }
    *ntoks = lx->ntoks;
    return lx->failed ? NULL : lx->toks;
}
