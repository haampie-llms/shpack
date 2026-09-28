/* SPDX-License-Identifier: MIT */
#ifndef STAR_LEX_H
#define STAR_LEX_H

typedef struct Token {
    int kind;
    int line, col;
    Str *s;             /* identifier or string value */
    int64_t ival;
} Token;

Token *lex(const char *file, const char *src, int len, int *ntoks, ErrList *errs);

#endif
