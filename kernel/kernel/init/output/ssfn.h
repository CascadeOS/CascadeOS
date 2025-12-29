// SPDX-License-Identifier: MIT
// SPDX-FileCopyrightText: Copyright (C) 2020 - 2022 bzt

// Trimmed down version of the below file, removing everything except the simple renderer.
// https://gitlab.com/bztsrc/scalable-font2/-/blob/43a5bd18071cec8ddb49e10ed465f6ccb75246ce/ssfn.h

/*
 * ssfn.h
 * https://gitlab.com/bztsrc/scalable-font2
 *
 * Copyright (C) 2020 - 2022 bzt
 *
 * Permission is hereby granted, free of charge, to any person
 * obtaining a copy of this software and associated documentation
 * files (the "Software"), to deal in the Software without
 * restriction, including without limitation the rights to use, copy,
 * modify, merge, publish, distribute, sublicense, and/or sell copies
 * of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be
 * included in all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
 * EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
 * MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
 * NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT
 * HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY,
 * WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 *
 * @brief Scalable Screen Font renderers
 *
 */

#ifndef _SSFN_H_
#define _SSFN_H_

#define SSFN_VERSION 0x0200

/* if stdint.h was not included before us */
#ifndef _STDINT_H
typedef unsigned char       uint8_t;
typedef unsigned short int  uint16_t;
typedef short int           int16_t;
typedef unsigned int        uint32_t;
#ifndef _UINT64_T
typedef unsigned long int   uint64_t;
#endif
#endif

/***** file format *****/

/* magic bytes */
#define SSFN_MAGIC "SFN2"
#define SSFN_COLLECTION "SFNC"
#define SSFN_ENDMAGIC "2NFS"

/* ligatures area */
#define SSFN_LIG_FIRST          0xF000
#define SSFN_LIG_LAST           0xF8FF

/* font family group in font type byte */
#define SSFN_TYPE_FAMILY(x)     ((x)&15)
#define SSFN_FAMILY_SERIF       0
#define SSFN_FAMILY_SANS        1
#define SSFN_FAMILY_DECOR       2
#define SSFN_FAMILY_MONOSPACE   3
#define SSFN_FAMILY_HAND        4

/* font style flags in font type byte */
#define SSFN_TYPE_STYLE(x)      (((x)>>4)&15)
#define SSFN_STYLE_REGULAR      0
#define SSFN_STYLE_BOLD         1
#define SSFN_STYLE_ITALIC       2
#define SSFN_STYLE_USRDEF1      4     /* user defined variant 1 */
#define SSFN_STYLE_USRDEF2      8     /* user defined variant 2 */

/* contour commands */
#define SSFN_CONTOUR_MOVE       0
#define SSFN_CONTOUR_LINE       1
#define SSFN_CONTOUR_QUAD       2
#define SSFN_CONTOUR_CUBIC      3

/* glyph fragments, kerning groups and hinting grid info */
#define SSFN_FRAG_CONTOUR       0
#define SSFN_FRAG_BITMAP        1
#define SSFN_FRAG_PIXMAP        2
#define SSFN_FRAG_KERNING       3
#define SSFN_FRAG_HINTING       4

/* main SSFN header, 32 bytes */
#ifndef _MSC_VER
#define _pack __attribute__((packed))
#else
#define _pack
#pragma pack(push)
#pragma pack(1)
#endif
typedef struct {
    uint8_t     magic[4];             /* SSFN magic bytes */
    uint32_t    size;                 /* total size in bytes */
    uint8_t     type;                 /* font family and style */
    uint8_t     features;             /* format features and revision */
    uint8_t     width;                /* overall width of the font */
    uint8_t     height;               /* overall height of the font */
    uint8_t     baseline;             /* horizontal baseline in grid pixels */
    uint8_t     underline;            /* position of under line in grid pixels */
    uint16_t    fragments_offs;       /* offset of fragments table */
    uint32_t    characters_offs;      /* characters table offset */
    uint32_t    ligature_offs;        /* ligatures table offset */
    uint32_t    kerning_offs;         /* kerning table offset */
    uint32_t    cmap_offs;            /* color map offset */
} _pack ssfn_font_t;
#ifdef _MSC_VER
#pragma pack(pop)
#endif

/***** renderer API *****/
#define SSFN_FAMILY_ANY      0xff     /* select the first loaded font */
#define SSFN_FAMILY_BYNAME   0xfe     /* select font by its unique name */

/* additional styles not stored in fonts */
#define SSFN_STYLE_UNDERLINE   16     /* under line glyph */
#define SSFN_STYLE_STHROUGH    32     /* strike through glyph */
#define SSFN_STYLE_NOAA        64     /* no anti-aliasing */
#define SSFN_STYLE_NOKERN     128     /* no kerning */
#define SSFN_STYLE_NODEFGLYPH 256     /* don't draw default glyph */
#define SSFN_STYLE_NOCACHE    512     /* don't cache rasterized glyph */
#define SSFN_STYLE_NOHINTING 1024     /* no auto hinting grid (not used as of now) */
#define SSFN_STYLE_RTL       2048     /* render right-to-left */
#define SSFN_STYLE_ABS_SIZE  4096     /* scale absoulte height */
#define SSFN_STYLE_NOSMOOTH  8192     /* no edge-smoothing for bitmaps */

/* error codes */
#define SSFN_OK                 0     /* success */
#define SSFN_ERR_ALLOC         -1     /* allocation error */
#define SSFN_ERR_BADFILE       -2     /* bad SSFN file format */
#define SSFN_ERR_NOFACE        -3     /* no font face selected */
#define SSFN_ERR_INVINP        -4     /* invalid input */
#define SSFN_ERR_BADSTYLE      -5     /* bad style */
#define SSFN_ERR_BADSIZE       -6     /* bad size */
#define SSFN_ERR_NOGLYPH       -7     /* glyph (or kerning info) not found */

#define SSFN_SIZE_MAX         192     /* biggest size we can render */
#define SSFN_ITALIC_DIV         4     /* italic angle divisor, glyph top side pushed width / this pixels */
#define SSFN_PREC               4     /* precision in bits */

/* destination frame buffer context */
typedef struct {
    uint8_t *ptr;                     /* pointer to the buffer */
    int w;                            /* width (positive: ARGB, negative: ABGR pixels) */
    int h;                            /* height */
    uint16_t p;                       /* pitch, bytes per line */
    int x;                            /* cursor x */
    int y;                            /* cursor y */
    uint32_t fg;                      /* foreground color */
    uint32_t bg;                      /* background color */
} ssfn_buf_t;

/* cached bitmap struct */
#define SSFN_DATA_MAX       65536
typedef struct {
    uint16_t p;                       /* data buffer pitch, bytes per line */
    uint8_t h;                        /* data buffer height */
    uint8_t o;                        /* overlap of glyph, scaled to size */
    uint8_t x;                        /* advance x, scaled to size */
    uint8_t y;                        /* advance y, scaled to size */
    uint8_t a;                        /* ascender, scaled to size */
    uint8_t d;                        /* descender, scaled to size */
    uint8_t data[SSFN_DATA_MAX];      /* data buffer */
} ssfn_glyph_t;

/* character metrics */
typedef struct {
    uint8_t t;                        /* type and overlap */
    uint8_t n;                        /* number of fragments */
    uint8_t w;                        /* width */
    uint8_t h;                        /* height */
    uint8_t x;                        /* advance x */
    uint8_t y;                        /* advance y */
} ssfn_chr_t;


/* renderer context */
typedef struct {
#ifdef SSFN_MAXLINES
    const ssfn_font_t *fnt[5][16];    /* static font registry */
#else
    const ssfn_font_t **fnt[5];       /* dynamic font registry */
#endif
    const ssfn_font_t *s;             /* explicitly selected font */
    const ssfn_font_t *f;             /* font selected by best match */
    ssfn_glyph_t ga;                  /* glyph sketch area */
    ssfn_glyph_t *g;                  /* current glyph pointer */
#ifdef SSFN_MAXLINES
    uint16_t p[SSFN_MAXLINES*2];
#else
    ssfn_glyph_t ***c[17];            /* glyph cache */
    uint16_t *p;
    char **bufs;                      /* allocated extra buffers */
#endif
    ssfn_chr_t *rc;                   /* pointer to current character */
    int numbuf, lenbuf, np, ap, ox, oy, ax;
    int mx, my, lx, ly;               /* move to coordinates, last coordinates */
    int len[5];                       /* number of fonts in registry */
    int family;                       /* required family */
    int style;                        /* required style */
    int size;                         /* required size */
    int line;                         /* calculate line height */
} ssfn_t;

/***** API function protoypes *****/

/* simple renderer */
extern ssfn_font_t *ssfn_src;                                                     /* font buffer */
extern ssfn_buf_t ssfn_dst;                                                       /* destination frame buffer */
int ssfn_putc(uint32_t unicode);                                                  /* render console bitmap font */

/***** renderer implementations *****/

/*** these go for both renderers ***/
#if (defined(SSFN_CONSOLEBITMAP_PALETTE) || \
    defined(SSFN_CONSOLEBITMAP_HICOLOR) || defined(SSFN_CONSOLEBITMAP_TRUECOLOR)) && !defined(SSFN_COMMON)

#define SSFN_COMMON

/**
 * Error code strings
 */
const char *ssfn_errstr[] = { "",
    "Memory allocation error",
    "Bad file format",
    "No font face found",
    "Invalid input value",
    "Invalid style",
    "Invalid size",
    "Glyph not found"
};
#endif

#if defined(SSFN_CONSOLEBITMAP_PALETTE) || defined(SSFN_CONSOLEBITMAP_HICOLOR) || defined(SSFN_CONSOLEBITMAP_TRUECOLOR)
/*** special console bitmap font renderer (ca. 1.5k, no dependencies, no memory allocation and no error checking) ***/

/**
 * public variables to configure
 */
ssfn_font_t *ssfn_src;          /* font buffer with an inflated bitmap font */
ssfn_buf_t ssfn_dst;            /* destination frame buffer */

/**
 * Minimal OS kernel console renderer
 *
 * @param unicode character
 * @return error code
 */
int ssfn_putc(uint32_t unicode)
{
# ifdef SSFN_CONSOLEBITMAP_PALETTE
#  define SSFN_PIXEL  uint8_t
# else
#  ifdef SSFN_CONSOLEBITMAP_HICOLOR
#   define SSFN_PIXEL uint16_t
#  else
#   define SSFN_PIXEL uint32_t
#  endif
# endif
    register SSFN_PIXEL *o, *p;
    register uint8_t *ptr, *chr = 0, *frg;
    register int i, j, k, l, m, y = 0, w, s = ssfn_dst.p / sizeof(SSFN_PIXEL);

    if(!ssfn_src || ssfn_src->magic[0] != 'S' || ssfn_src->magic[1] != 'F' || ssfn_src->magic[2] != 'N' ||
        ssfn_src->magic[3] != '2' || !ssfn_dst.ptr || !ssfn_dst.p) return SSFN_ERR_INVINP;
    w = ssfn_dst.w < 0 ? -ssfn_dst.w : ssfn_dst.w;
    for(ptr = (uint8_t*)ssfn_src + ssfn_src->characters_offs, i = 0; i < 0x110000; i++) {
        if(ptr[0] == 0xFF) { i += 65535; ptr++; }
        else if((ptr[0] & 0xC0) == 0xC0) { j = (((ptr[0] & 0x3F) << 8) | ptr[1]); i += j; ptr += 2; }
        else if((ptr[0] & 0xC0) == 0x80) { j = (ptr[0] & 0x3F); i += j; ptr++; }
        else { if((uint32_t)i == unicode) { chr = ptr; break; } ptr += 6 + ptr[1] * (ptr[0] & 0x40 ? 6 : 5); }
    }
#ifdef SSFN_CONSOLEBITMAP_CONTROL
    i = ssfn_src->height; j = ssfn_dst.h - i - (ssfn_dst.h % i);
    if(chr && w) {
        if(unicode == '\t') ssfn_dst.x -= ssfn_dst.x % chr[4];
        if(ssfn_dst.x + chr[4] > w) { ssfn_dst.x = 0; ssfn_dst.y += i; }
    }
    if(unicode == '\n') ssfn_dst.y += i;
    if(j > 0 && ssfn_dst.y > j) {
        ssfn_dst.y = j;
        for(k = 0; k < j; k++)
            for(l = 0; l < ssfn_dst.p; l++) ssfn_dst.ptr[k * ssfn_dst.p + l] = ssfn_dst.ptr[(k + i) * ssfn_dst.p + l];
    }
    if(unicode == '\r' || unicode == '\n') { ssfn_dst.x = 0; return SSFN_OK; }
#endif
    if(!chr) return SSFN_ERR_NOGLYPH;
    ptr = chr + 6; o = (SSFN_PIXEL*)(ssfn_dst.ptr + ssfn_dst.y * ssfn_dst.p + ssfn_dst.x * sizeof(SSFN_PIXEL));
    for(i = 0; i < chr[1]; i++, ptr += chr[0] & 0x40 ? 6 : 5) {
        if(ptr[0] == 255 && ptr[1] == 255) continue;
        frg = (uint8_t*)ssfn_src + (chr[0] & 0x40 ? ((ptr[5] << 24) | (ptr[4] << 16) | (ptr[3] << 8) | ptr[2]) :
            ((ptr[4] << 16) | (ptr[3] << 8) | ptr[2]));
        if((frg[0] & 0xE0) != 0x80) continue;
        if(ssfn_dst.bg) {
            for(; y < ptr[1] && (!ssfn_dst.h || ssfn_dst.y + y < ssfn_dst.h); y++, o += s) {
                for(p = o, j = 0; j < chr[2] && (!w || ssfn_dst.x + j < w); j++, p++)
                    *p = ssfn_dst.bg;
            }
        } else { o += (int)(ptr[1] - y) * s; y = ptr[1]; }
        k = ((frg[0] & 0x1F) + 1) << 3; j = frg[1] + 1; frg += 2;
        for(m = 1; j && (!ssfn_dst.h || ssfn_dst.y + y < ssfn_dst.h); j--, y++, o += s)
            for(p = o, l = 0; l < k; l++, p++, m <<= 1) {
                if(m > 0x80) { frg++; m = 1; }
                if(ssfn_dst.x + l >= 0 && (!w || ssfn_dst.x + l < w)) {
                    if(*frg & m) *p = ssfn_dst.fg; else
                    if(ssfn_dst.bg) *p = ssfn_dst.bg;
                }
            }
    }
    if(ssfn_dst.bg)
        for(; y < chr[3] && (!ssfn_dst.h || ssfn_dst.y + y < ssfn_dst.h); y++, o += s) {
            for(p = o, j = 0; j < chr[2] && (!w || ssfn_dst.x + j < w); j++, p++)
                *p = ssfn_dst.bg;
        }
    ssfn_dst.x += chr[4]; ssfn_dst.y += chr[5];
    return SSFN_OK;
}
#endif

#endif /* _SSFN_H_ */
