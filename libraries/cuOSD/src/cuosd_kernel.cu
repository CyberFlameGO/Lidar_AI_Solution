/*
 * SPDX-FileCopyrightText: Copyright (c) 2023 NVIDIA CORPORATION & AFFILIATES. All rights reserved.
 * SPDX-License-Identifier: MIT
 *
 * Permission is hereby granted, free of charge, to any person obtaining a
 * copy of this software and associated documentation files (the "Software"),
 * to deal in the Software without restriction, including without limitation
 * the rights to use, copy, modify, merge, publish, distribute, sublicense,
 * and/or sell copies of the Software, and to permit persons to whom the
 * Software is furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL
 * THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
 * FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
 * DEALINGS IN THE SOFTWARE.
 */
 
#include <stdio.h>
#include "cuosd_kernel.h"

typedef unsigned char uint8_t;

#define CUOSD_PRINT_E(f_, ...) \
  fprintf(stderr, "[cuOSD Error] at %s:%d : " f_, (const char*)__FILE__, __LINE__, ##__VA_ARGS__)

#define CUOSD_PRINT_W(f_, ...) \
  printf("[cuOSD Warning] at %s:%d : " f_, (const char*)__FILE__, __LINE__, ##__VA_ARGS__)

template<typename _T> _T max(_T a, _T b){return a >= b ? a : b;}
template<typename _T> _T min(_T a, _T b){return a <= b ? a : b;}

template<typename _T>
static __host__ __device__ unsigned char u8cast(_T value) {
    return value < 0 ? 0 : (value > 255 ? 255 : value);
}

static __host__ __device__ unsigned int round_down2(unsigned int num) {
    return num & (~1);
}

template<typename _T>
static __forceinline__ __device__ _T limit(_T value, _T low, _T high){
    return value < low ? low : (value > high ? high : value);
}

#define INTER_RESIZE_COEF_BITS 11
#define INTER_RESIZE_COEF_SCALE (1 << INTER_RESIZE_COEF_BITS)

// inbox_single_pixel:
// check if given coordinate is in box
//      a --- d
//      |     |
//      b --- c
static __device__ __forceinline__ bool inbox_single_pixel(
    float ix, float iy, float ax, float ay, float bx, float by, float cx, float cy, float dx, float dy) {
    return  ((bx-ax) * (iy - ay) - (by-ay) * (ix-ax)) < 0 &&
            ((cx-bx) * (iy - by) - (cy-by) * (ix-bx)) < 0 &&
            ((dx-cx) * (iy - cy) - (dy-cy) * (ix-cx)) < 0 &&
            ((ax-dx) * (iy - dy) - (ay-dy) * (ix-dx)) < 0;
}

static __device__ void blend_single_color(uchar4& color, unsigned char& c0, unsigned char& c1, unsigned char& c2, unsigned char a) {
    int foreground_alpha = a;
    int background_alpha = color.w;
    int blend_alpha      = ((background_alpha * (255 - foreground_alpha))>> 8) + foreground_alpha;
    color.x = u8cast((((color.x * background_alpha * (255 - foreground_alpha))>>8) + (c0 * foreground_alpha)) / blend_alpha);
    color.y = u8cast((((color.y * background_alpha * (255 - foreground_alpha))>>8) + (c1 * foreground_alpha)) / blend_alpha);
    color.z = u8cast((((color.z * background_alpha * (255 - foreground_alpha))>>8) + (c2 * foreground_alpha)) / blend_alpha);
    color.w = blend_alpha;
}

CircleCommand::CircleCommand(int cx, int cy, int radius, int thickness, unsigned char c0, unsigned char c1, unsigned char c2, unsigned char c3) {
    this->type = CommandType::Circle;
    this->cx = cx;
    this->cy = cy;
    this->radius    = radius;
    this->thickness = thickness;
    this->c0 = c0;
    this->c1 = c1;
    this->c2 = c2;
    this->c3 = c3;

    int half_thickness = (thickness + 1) / 2 + 2;
    this->bounding_left  = cx - radius - half_thickness;
    this->bounding_right = cx + radius + half_thickness;
    this->bounding_top   = cy - radius - half_thickness;
    this->bounding_bottom = cy + radius + half_thickness;
}

RectangleCommand::RectangleCommand() {
    this->type = CommandType::Rectangle;
}

BoxBlurCommand::BoxBlurCommand(){
    this->type = CommandType::BoxBlur;
}

TextCommand::TextCommand(int text_line_size, int ilocation, unsigned char c0, unsigned char c1, unsigned char c2, unsigned char c3) {
    this->text_line_size = text_line_size;
    this->ilocation      = ilocation;
    this->type           = CommandType::Text;
    this->c0 = c0;
    this->c1 = c1;
    this->c2 = c2;
    this->c3 = c3;
}

SegmentCommand::SegmentCommand() {
    this->type = CommandType::Segment;
}

RGBASourceCommand::RGBASourceCommand(int cx, int cy, int width, int height, void* d_src) {
    this->cx = cx;
    this->cy = cy;
    this->width = width;
    this->height = height;
    this->type = CommandType::RGBASource;
    this->d_src = d_src;

    this->bounding_left  = cx - (width + 1) / 2;
    this->bounding_right = cx + (width + 1) / 2;
    this->bounding_top   = cy - (height + 1) / 2;
    this->bounding_bottom = cy + (height + 1) / 2;
}

NV12SourceCommand::NV12SourceCommand(int cx, int cy, int width, int height, void* d_src0, void* d_src1, bool block_linear, unsigned char c0, unsigned char c1, unsigned char c2, unsigned char c3) {
    this->cx = cx;
    this->cy = cy;
    this->width = width;
    this->height = height;
    this->type = CommandType::NV12Source;

    this->d_src0 = d_src0;
    this->d_src1 = d_src1;
    this->block_linear = block_linear;

    this->c0 = c0;
    this->c1 = c1;
    this->c2 = c2;
    this->c3 = c3;

    this->bounding_left  = cx - (width + 1) / 2;
    this->bounding_right = cx + (width + 1) / 2;
    this->bounding_top   = cy - (height + 1) / 2;
    this->bounding_bottom = cy + (height + 1) / 2;
}

// interpolation_fn:
// interpolate alpha for border pixels
static __device__ unsigned char interpolation_fn(
    float x, int a, int b, int padding, unsigned char origin_alpha
) {
    int x0 = a - padding < 0 ? 0 : a - padding;
    int x1 = b + padding;
    if (x < x0 || x > x1) return 0;
    if (x >= a && x < b) return origin_alpha;
    if (x >= b && x <= x1) return (x1 - x) / padding * origin_alpha;
    if (x < a && x >= x0) return (x - x0) / padding * origin_alpha;
    return 0;
}

// external_msaa4x:
// check if given coordinate is on border or outside the border, do msaa4x for border pixels
static __device__ __forceinline__ bool external_msaa4x(
    float ix, float iy, float ax, float ay, float bx, float by, float cx, float cy, float dx, float dy,
    unsigned char a, unsigned char& alpha) {
    bool h0 = !inbox_single_pixel(ix-0.25f, iy-0.25f, ax, ay, bx, by, cx, cy, dx, dy);
    bool h1 = !inbox_single_pixel(ix+0.25f, iy-0.25f, ax, ay, bx, by, cx, cy, dx, dy);
    bool h2 = !inbox_single_pixel(ix+0.25f, iy+0.25f, ax, ay, bx, by, cx, cy, dx, dy);
    bool h3 = !inbox_single_pixel(ix-0.25f, iy+0.25f, ax, ay, bx, by, cx, cy, dx, dy);
    if (h0 || h1 || h2 || h3) {
        if (h0 && h1 && h2 && h3) return true;
        alpha = a * (h0 + h1 + h2 + h3) * 0.25f;
        return true;
    }
    return false;
}

// internal_msaa4x:
// check if given coordinate is on border or inside the border, do msaa4x for border pixels
static __device__ __forceinline__ bool internal_msaa4x(
    float ix, float iy, float ax, float ay, float bx, float by, float cx, float cy, float dx, float dy,
    unsigned char a, unsigned char& alpha) {
    bool h0 = inbox_single_pixel(ix-0.25f, iy-0.25f, ax, ay, bx, by, cx, cy, dx, dy);
    bool h1 = inbox_single_pixel(ix+0.25f, iy-0.25f, ax, ay, bx, by, cx, cy, dx, dy);
    bool h2 = inbox_single_pixel(ix+0.25f, iy+0.25f, ax, ay, bx, by, cx, cy, dx, dy);
    bool h3 = inbox_single_pixel(ix-0.25f, iy+0.25f, ax, ay, bx, by, cx, cy, dx, dy);
    if (h0 || h1 || h2 || h3) {
        alpha = a * (h0 + h1 + h2 + h3) * 0.25f;
        return true;
    }
    return false;
}

// render_rectangle_fill_msaa4x:
// render filled rectangle with border msaa4x interpolation on
static __device__ void render_rectangle_fill_msaa4x(int ix, int iy, RectangleCommand* p, uchar4 color[4]) {
    unsigned char alpha;
    if (internal_msaa4x(ix, iy, p->ax1, p->ay1, p->bx1, p->by1, p->cx1, p->cy1, p->dx1, p->dy1, p->c3, alpha)) {
        blend_single_color(color[0], p->c0, p->c1, p->c2, alpha);
    }
    if (internal_msaa4x(ix+1, iy, p->ax1, p->ay1, p->bx1, p->by1, p->cx1, p->cy1, p->dx1, p->dy1, p->c3, alpha)) {
        blend_single_color(color[1], p->c0, p->c1, p->c2, alpha);
    }
    if (internal_msaa4x(ix, iy+1, p->ax1, p->ay1, p->bx1, p->by1, p->cx1, p->cy1, p->dx1, p->dy1, p->c3, alpha)) {
        blend_single_color(color[2], p->c0, p->c1, p->c2, alpha);
    }
    if (internal_msaa4x(ix+1, iy+1, p->ax1, p->ay1, p->bx1, p->by1, p->cx1, p->cy1, p->dx1, p->dy1, p->c3, alpha)) {
        blend_single_color(color[3], p->c0, p->c1, p->c2, alpha);
    }
}

// render_rectangle_fill:
// render filled rectangle with border msaa4x interpolation off
static __device__ void render_rectangle_fill(int ix, int iy, RectangleCommand* p, uchar4 color[4]) {
    if (inbox_single_pixel(ix, iy, p->ax1, p->ay1, p->bx1, p->by1, p->cx1, p->cy1, p->dx1, p->dy1)) {
        blend_single_color(color[0], p->c0, p->c1, p->c2, p->c3);
    }
    if (inbox_single_pixel(ix+1, iy, p->ax1, p->ay1, p->bx1, p->by1, p->cx1, p->cy1, p->dx1, p->dy1)) {
        blend_single_color(color[1], p->c0, p->c1, p->c2, p->c3);
    }
    if (inbox_single_pixel(ix, iy+1, p->ax1, p->ay1, p->bx1, p->by1, p->cx1, p->cy1, p->dx1, p->dy1)) {
        blend_single_color(color[2], p->c0, p->c1, p->c2, p->c3);
    }
    if (inbox_single_pixel(ix+1, iy+1, p->ax1, p->ay1, p->bx1, p->by1, p->cx1, p->cy1, p->dx1, p->dy1)) {
        blend_single_color(color[3], p->c0, p->c1, p->c2, p->c3);
    }
}

// render_rectangle_border_msaa4x:
// render hollow rectangle with border msaa4x interpolation on
static __device__ void render_rectangle_border_msaa4x(int ix, int iy, RectangleCommand* p, uchar4 color[4]) {
    unsigned char alpha;
    if (internal_msaa4x(ix, iy, p->ax1, p->ay1, p->bx1, p->by1, p->cx1, p->cy1, p->dx1, p->dy1, p->c3, alpha) &&
        external_msaa4x(ix, iy, p->ax2, p->ay2, p->bx2, p->by2, p->cx2, p->cy2, p->dx2, p->dy2, p->c3, alpha)
    ) {
        blend_single_color(color[0], p->c0, p->c1, p->c2, alpha);
    }
    if (internal_msaa4x(ix+1, iy, p->ax1, p->ay1, p->bx1, p->by1, p->cx1, p->cy1, p->dx1, p->dy1, p->c3, alpha) &&
        external_msaa4x(ix+1, iy, p->ax2, p->ay2, p->bx2, p->by2, p->cx2, p->cy2, p->dx2, p->dy2, p->c3, alpha)
    ) {
        blend_single_color(color[1], p->c0, p->c1, p->c2, alpha);
    }
    if (internal_msaa4x(ix, iy+1, p->ax1, p->ay1, p->bx1, p->by1, p->cx1, p->cy1, p->dx1, p->dy1, p->c3, alpha) &&
        external_msaa4x(ix, iy+1, p->ax2, p->ay2, p->bx2, p->by2, p->cx2, p->cy2, p->dx2, p->dy2, p->c3, alpha)
    ) {
        blend_single_color(color[2], p->c0, p->c1, p->c2, alpha);
    }
    if (internal_msaa4x(ix+1, iy+1, p->ax1, p->ay1, p->bx1, p->by1, p->cx1, p->cy1, p->dx1, p->dy1, p->c3, alpha) &&
        external_msaa4x(ix+1, iy+1, p->ax2, p->ay2, p->bx2, p->by2, p->cx2, p->cy2, p->dx2, p->dy2, p->c3, alpha)
    ) {
        blend_single_color(color[3], p->c0, p->c1, p->c2, alpha);
    }
}

// render_rectangle_border:
// render hollow rectangle with border msaa4x interpolation off
static __device__ void render_rectangle_border(int ix, int iy, RectangleCommand* p, uchar4 color[4]) {
    if (!inbox_single_pixel(ix, iy, p->ax2, p->ay2, p->bx2, p->by2, p->cx2, p->cy2, p->dx2, p->dy2) &&
        inbox_single_pixel(ix, iy, p->ax1, p->ay1, p->bx1, p->by1, p->cx1, p->cy1, p->dx1, p->dy1)
    ) {
        blend_single_color(color[0], p->c0, p->c1, p->c2, p->c3);
    }
    if (!inbox_single_pixel(ix+1, iy, p->ax2, p->ay2, p->bx2, p->by2, p->cx2, p->cy2, p->dx2, p->dy2) &&
        inbox_single_pixel(ix+1, iy, p->ax1, p->ay1, p->bx1, p->by1, p->cx1, p->cy1, p->dx1, p->dy1)
    ) {
        blend_single_color(color[1], p->c0, p->c1, p->c2, p->c3);
    }
    if (!inbox_single_pixel(ix, iy+1, p->ax2, p->ay2, p->bx2, p->by2, p->cx2, p->cy2, p->dx2, p->dy2) &&
        inbox_single_pixel(ix, iy+1, p->ax1, p->ay1, p->bx1, p->by1, p->cx1, p->cy1, p->dx1, p->dy1)
    ) {
        blend_single_color(color[2], p->c0, p->c1, p->c2, p->c3);
    }
    if (!inbox_single_pixel(ix+1, iy+1, p->ax2, p->ay2, p->bx2, p->by2, p->cx2, p->cy2, p->dx2, p->dy2) &&
        inbox_single_pixel(ix+1, iy+1, p->ax1, p->ay1, p->bx1, p->by1, p->cx1, p->cy1, p->dx1, p->dy1)
    ) {
        blend_single_color(color[3], p->c0, p->c1, p->c2, p->c3);
    }
}

// render_circle_interpolation:
// render cicle with border interpolation
static __device__ void render_circle_interpolation(
    int ix, int iy, CircleCommand* p, uchar4 color[4]
) {
    float tr0 = sqrt((float)(ix - p->cx) * (ix - p->cx) + (iy - p->cy) * (iy - p->cy));
    float tr1 = sqrt((float)(ix + 1 - p->cx) * (ix + 1 - p->cx) + (iy - p->cy) * (iy - p->cy));
    float tr2 = sqrt((float)(ix - p->cx) * (ix - p->cx) + (iy + 1 - p->cy) * (iy + 1 - p->cy));
    float tr3 = sqrt((float)(ix + 1 - p->cx) * (ix + 1 - p->cx) + (iy + 1 - p->cy) * (iy + 1 - p->cy));

    int inner_boundsize = p->radius - p->thickness / 2;
    int external_boundsize = inner_boundsize + p->thickness;

    if (p->thickness < 0) {
        if (p->thickness == -1) {
            external_boundsize = p->radius;
        } else {
            external_boundsize = inner_boundsize;
        }
        inner_boundsize = 0;
    }

    unsigned char alpha0 = interpolation_fn(tr0, inner_boundsize, external_boundsize, 1, p->c3);
    unsigned char alpha1 = interpolation_fn(tr1, inner_boundsize, external_boundsize, 1, p->c3);
    unsigned char alpha2 = interpolation_fn(tr2, inner_boundsize, external_boundsize, 1, p->c3);
    unsigned char alpha3 = interpolation_fn(tr3, inner_boundsize, external_boundsize, 1, p->c3);

    if (alpha0){blend_single_color(color[0], p->c0, p->c1, p->c2, alpha0);}
    if (alpha1){blend_single_color(color[1], p->c0, p->c1, p->c2, alpha1);}
    if (alpha2){blend_single_color(color[2], p->c0, p->c1, p->c2, alpha2);}
    if (alpha3){blend_single_color(color[3], p->c0, p->c1, p->c2, alpha3);}
}

static __device__ void sample_pixel_bilinear(
    float* d_ptr, int x, int y, float sx, float sy, int width, int height, float threshold, unsigned char& a
) {
    float src_x = (x + 0.5f) * sx - 0.5f;
    float src_y = (y + 0.5f) * sy - 0.5f;
    int y_low  = floorf(src_y);
    int x_low  = floorf(src_x);
    int y_high = limit(y_low + 1, 0, height - 1);
    int x_high = limit(x_low + 1, 0, width - 1);
    y_low = limit(y_low, 0, height - 1);
    x_low = limit(x_low, 0, width - 1);

    int ly = rint((src_y - y_low) * INTER_RESIZE_COEF_SCALE);
    int lx = rint((src_x - x_low) * INTER_RESIZE_COEF_SCALE);
    int hy = INTER_RESIZE_COEF_SCALE - ly;
    int hx = INTER_RESIZE_COEF_SCALE - lx;

    uchar4 _scr;

    _scr.x = d_ptr[x_low + y_low * width] > threshold ? 127 : 0;
    _scr.y = d_ptr[x_high + y_low * width] > threshold ? 127 : 0;
    _scr.z = d_ptr[x_low + y_high * width] > threshold ? 127 : 0;
    _scr.w = d_ptr[x_high + y_high * width] > threshold ? 127 : 0;

    a = ( ((hy * ((hx * _scr.x + lx * _scr.y) >> 4)) >> 16) + ((ly * ((hx * _scr.z + lx * _scr.w) >> 4)) >> 16) + 2 )>>2;
}

static __device__ void render_segment_bilinear(
    int ix, int iy, SegmentCommand* p, uchar4 color[4]
) {
    if (ix + 1 < p->bounding_left || iy + 1 < p->bounding_top || ix >= p->bounding_right || iy >= p->bounding_bottom)
        return;

    unsigned char alpha0 = ix   < p->bounding_left || iy < p->bounding_top   || ix >= p->bounding_right   || iy >= p->bounding_bottom ? 0 : 127;
    unsigned char alpha1 = ix+1 < p->bounding_left || iy < p->bounding_top   || ix+1 >= p->bounding_right || iy >= p->bounding_bottom ? 0 : 127;
    unsigned char alpha2 = ix   < p->bounding_left || iy+1 < p->bounding_top || ix >= p->bounding_right   || iy+1 >= p->bounding_bottom ? 0 : 127;
    unsigned char alpha3 = ix+1 < p->bounding_left || iy+1 < p->bounding_top || ix+1 >= p->bounding_right || iy+1 >= p->bounding_bottom ? 0 : 127;

    int fx = ix - p->bounding_left;
    int fy = iy - p->bounding_top;

    if(alpha0) {
        sample_pixel_bilinear(p->d_seg, fx, fy, p->scale_x, p->scale_y, p->seg_width, p->seg_height, p->seg_threshold, alpha0);
        blend_single_color(color[0], p->c0, p->c1, p->c2, alpha0);
    }

    if(alpha1) {
        sample_pixel_bilinear(p->d_seg, fx+1, fy, p->scale_x, p->scale_y, p->seg_width, p->seg_height, p->seg_threshold, alpha1);
        blend_single_color(color[1], p->c0, p->c1, p->c2, alpha1);
    }

    if(alpha2) {
        sample_pixel_bilinear(p->d_seg, fx, fy+1, p->scale_x, p->scale_y, p->seg_width, p->seg_height, p->seg_threshold, alpha2);
        blend_single_color(color[2], p->c0, p->c1, p->c2, alpha2);
    }

    if(alpha3) {
        sample_pixel_bilinear(p->d_seg, fx+1, fy+1, p->scale_x, p->scale_y, p->seg_width, p->seg_height, p->seg_threshold, alpha3);
        blend_single_color(color[3], p->c0, p->c1, p->c2, alpha3);
    }
}

static __device__ bool render_text(
    int ix, int iy, const TextLocation& location, const unsigned char* text_bitmap, int text_bitmap_width,
    uchar4 color[4], unsigned char& c0, unsigned char& c1, unsigned char& c2, unsigned char& a
) {
    if (ix + 1 < location.image_x || iy + 1 < location.image_y || ix >= location.image_x + location.text_w || iy >= location.image_y + location.text_h)
        return false;

    int fx  = ix - location.image_x;
    int fy  = iy - location.image_y;
    int bfx = fx + location.text_x;
    unsigned char alpha0 = fx < 0   || fy < 0   || fx >= location.text_w   || fy >= location.text_h   ? 0 : ((text_bitmap[fy * text_bitmap_width + bfx + 0] * (int)a) >> 8);
    unsigned char alpha1 = fx+1 < 0 || fy < 0   || fx+1 >= location.text_w || fy >= location.text_h   ? 0 : ((text_bitmap[fy * text_bitmap_width + bfx + 1] * (int)a) >> 8);
    unsigned char alpha2 = fx < 0   || fy+1 < 0 || fx >= location.text_w   || fy+1 >= location.text_h ? 0 : ((text_bitmap[(fy + 1) * text_bitmap_width + bfx + 0] * (int)a) >> 8);
    unsigned char alpha3 = fx+1 < 0 || fy+1 < 0 || fx+1 >= location.text_w || fy+1 >= location.text_h ? 0 : ((text_bitmap[(fy + 1) * text_bitmap_width + bfx + 1] * (int)a) >> 8);

    if (alpha0){blend_single_color(color[0], c0, c1, c2, alpha0);}
    if (alpha1){blend_single_color(color[1], c0, c1, c2, alpha1);}
    if (alpha2){blend_single_color(color[2], c0, c1, c2, alpha2);}
    if (alpha3){blend_single_color(color[3], c0, c1, c2, alpha3);}
    return true;
}

// render_bl_nv12_src:
// render color from nv12 bl source image
static __device__ void render_bl_nv12_src(
    int ix, int iy, int left, int top, int right, int bottom, cudaSurfaceObject_t d_src0, cudaSurfaceObject_t d_src1,
    uchar4* color, unsigned char trans_0, unsigned char trans_1, unsigned char trans_2, unsigned char trans_a
) {
    if (ix + 1 < left || iy + 1 < top || ix >= right || iy >= bottom)
        return;

    unsigned char alpha0 = ix   < left || iy < top   || ix >= right   || iy >= bottom ? 0 : 127;
    unsigned char alpha1 = ix+1 < left || iy < top   || ix+1 >= right || iy >= bottom ? 0 : 127;
    unsigned char alpha2 = ix   < left || iy+1 < top || ix >= right   || iy+1 >= bottom ? 0 : 127;
    unsigned char alpha3 = ix+1 < left || iy+1 < top || ix+1 >= right || iy+1 >= bottom ? 0 : 127;

    int fx = ix - left;
    int fy = iy - top;

    uchar4& c0 = color[0];
    uchar4& c1 = color[1];
    uchar4& c2 = color[2];
    uchar4& c3 = color[3];

    if(alpha0){
        c0 = make_uchar4(
            surf2Dread<unsigned char>(d_src0, fx, fy),
            surf2Dread<unsigned char>(d_src1, fx, fy >> 1),
            surf2Dread<unsigned char>(d_src1, fx + 1, fy >> 1), 0
        );
        c0.w = c0.x == trans_0 && c0.y == trans_1 && c0.z == trans_2 ? 0 : trans_a;
    }

    if(alpha1){
        c1 = make_uchar4(surf2Dread<unsigned char>(d_src0, fx + 1, fy),
                                          surf2Dread<unsigned char>(d_src1, fx, fy >> 1),
                                          surf2Dread<unsigned char>(d_src1, fx + 1, fy >> 1), 0);
        c1.w = c1.x == trans_0 && c1.y == trans_1 && c1.z == trans_2 ? 0 : trans_a;
    }

    if(alpha2){
        c2 = make_uchar4(surf2Dread<unsigned char>(d_src0, fx, fy + 1),
                                          surf2Dread<unsigned char>(d_src1, fx, fy >> 1),
                                          surf2Dread<unsigned char>(d_src1, fx + 1, fy >> 1), 0);
        c2.w = c2.x == trans_0 && c2.y == trans_1 && c2.z == trans_2 ? 0 : trans_a;
    }

    if(alpha3){
        c3 = make_uchar4(surf2Dread<unsigned char>(d_src0, fx + 1, fy + 1),
                                          surf2Dread<unsigned char>(d_src1, fx, fy >> 1),
                                          surf2Dread<unsigned char>(d_src1, fx + 1, fy >> 1), 0);
        c3.w = c3.x == trans_0 && c3.y == trans_1 && c3.z == trans_2 ? 0 : trans_a;
    }
}

// render_pl_nv12_src:
// render color from nv12 pl source image
static __device__ void render_pl_nv12_src(
    int ix, int iy, int left, int top, int right, int bottom, const unsigned char* d_src0, const unsigned char* d_src1,
    uchar4* color, unsigned char trans_0, unsigned char trans_1, unsigned char trans_2, unsigned char trans_a
) {
    if (ix + 1 < left || iy + 1 < top || ix >= right || iy >= bottom)
        return;

    unsigned char alpha0 = ix   < left || iy < top   || ix >= right   || iy >= bottom ? 0 : 127;
    unsigned char alpha1 = ix+1 < left || iy < top   || ix+1 >= right || iy >= bottom ? 0 : 127;
    unsigned char alpha2 = ix   < left || iy+1 < top || ix >= right   || iy+1 >= bottom ? 0 : 127;
    unsigned char alpha3 = ix+1 < left || iy+1 < top || ix+1 >= right || iy+1 >= bottom ? 0 : 127;

    int fx = ix - left;
    int fy = iy - top;

    auto width = right - left;
    int offset_0 = fy * width + fx;
    int offset_1 = (fy >> 1)* width + fx;
    int offset_2 = (fy >> 1)* width + fx + 1;

    uchar4& c0 = color[0];
    uchar4& c1 = color[1];
    uchar4& c2 = color[2];
    uchar4& c3 = color[3];

    if (alpha0) {
        c0 = make_uchar4(d_src0[offset_0], d_src1[offset_1], d_src1[offset_2], 0);
        c0.w = c0.x == trans_0 && c0.y == trans_1 && c0.z == trans_2 ? 0 : trans_a;
    }

    if (alpha1) {
        c1 = make_uchar4(d_src0[offset_0 + 1], d_src1[offset_1], d_src1[offset_2], 0);
        c1.w = c1.x == trans_0 && c1.y == trans_1 && c1.z == trans_2 ? 0 : trans_a;
    }

    if (alpha2) {
        c2 = make_uchar4(d_src0[offset_0 + width], d_src1[offset_1], d_src1[offset_2], 0);
        c2.w = c2.x == trans_0 && c2.y == trans_1 && c2.z == trans_2 ? 0 : trans_a;
    }

    if (alpha3) {
        c3 = make_uchar4(d_src0[offset_0 + width + 1], d_src1[offset_1], d_src1[offset_2], 0);
        c3.w = c3.x == trans_0 && c3.y == trans_1 && c3.z == trans_2 ? 0 : trans_a;
    }
}

// render_rgba_src:
// render color from rgba source image
static __device__ void render_rgba_src(
    int ix, int iy, int left, int top, int right, int bottom, const unsigned char* d_src,
    uchar4* color
) {
    if (ix + 1 < left || iy + 1 < top || ix >= right || iy >= bottom)
        return;

    unsigned char alpha0 = ix   < left || iy < top   || ix >= right   || iy >= bottom ? 0 : 127;
    unsigned char alpha1 = ix+1 < left || iy < top   || ix+1 >= right || iy >= bottom ? 0 : 127;
    unsigned char alpha2 = ix   < left || iy+1 < top || ix >= right   || iy+1 >= bottom ? 0 : 127;
    unsigned char alpha3 = ix+1 < left || iy+1 < top || ix+1 >= right || iy+1 >= bottom ? 0 : 127;

    int fx = ix - left;
    int fy = iy - top;

    auto width = right - left;
    int offset_0 = (fy * width + fx) * 4;
    int offset_1 = ((fy + 1) * width + fx) * 4;

    if (alpha0) {
        color[0] = make_uchar4(d_src[offset_0], d_src[offset_0 + 1], d_src[offset_0 + 2], d_src[offset_0 + 3]);
    }

    if (alpha1) {
        color[1] = make_uchar4(d_src[offset_0 + 4], d_src[offset_0 + 5], d_src[offset_0 + 6], d_src[offset_0 + 7]);
    }

    if (alpha2) {
        color[2] = make_uchar4(d_src[offset_1], d_src[offset_1 + 1], d_src[offset_1 + 2], d_src[offset_1 + 3]);
    }

    if (alpha3) {
        color[3] = make_uchar4(d_src[offset_1 + 4], d_src[offset_1 + 5], d_src[offset_1 + 6], d_src[offset_1 + 7]);
    }
}

template<ImageFormat format>
struct BlendingPixel{};

template<>
struct BlendingPixel<ImageFormat::RGBA>{
    static __device__ void call(
        const void* image0, const void* image1,
        int x, int y, int stride, uchar4 plot_colors[4]
    ) {
        for (int i = 0; i < 2; ++i) {
            unsigned char* p = ((unsigned char*)image0 + (y + i) * stride + x * 4);
            for (int j = 0; j < 2; ++j, p += 4) {
                uchar4& rcolor   = plot_colors[i * 2 + j];
                int foreground_alpha = rcolor.w;
                int background_alpha = p[3];
                int blend_alpha      = ((background_alpha * (255 - foreground_alpha)) >> 8) + foreground_alpha;
                p[0] = u8cast((((p[0] * background_alpha * (255 - foreground_alpha))>>8) + (rcolor.x * foreground_alpha)) / blend_alpha);
                p[1] = u8cast((((p[1] * background_alpha * (255 - foreground_alpha))>>8) + (rcolor.y * foreground_alpha)) / blend_alpha);
                p[2] = u8cast((((p[2] * background_alpha * (255 - foreground_alpha))>>8) + (rcolor.z * foreground_alpha)) / blend_alpha);
                p[3] = blend_alpha;
            }
        }
    }
};

template<>
struct BlendingPixel<ImageFormat::RGB>{
    static __device__ void call(
        const void* image0, const void* image1,
        int x, int y, int stride, uchar4 plot_colors[4]
    ) {
        for (int i = 0; i < 2; ++i) {
            unsigned char* p = ((unsigned char*)image0 + (y + i) * stride + x * 3);
            for (int j = 0; j < 2; ++j, p += 3) {
                uchar4& rcolor   = plot_colors[i * 2 + j];
                int foreground_alpha = rcolor.w;
                int background_alpha = 255;
                int blend_alpha      = ((background_alpha * (255 - foreground_alpha)) >> 8) + foreground_alpha;
                p[0] = u8cast((((p[0] * background_alpha * (255 - foreground_alpha))>>8) + (rcolor.x * foreground_alpha)) / blend_alpha);
                p[1] = u8cast((((p[1] * background_alpha * (255 - foreground_alpha))>>8) + (rcolor.y * foreground_alpha)) / blend_alpha);
                p[2] = u8cast((((p[2] * background_alpha * (255 - foreground_alpha))>>8) + (rcolor.z * foreground_alpha)) / blend_alpha);
            }
        }
    }
};

template<>
struct BlendingPixel<ImageFormat::BlockLinearNV12>{
    static __device__ void call(
        const void* image0, const void* image1,
        int x, int y, int stride, uchar4 plot_colors[4]
    ) {
        unsigned char img_y0 = surf2Dread<unsigned char>((cudaSurfaceObject_t)image0, x + 0, y);
        unsigned char img_y1 = surf2Dread<unsigned char>((cudaSurfaceObject_t)image0, x + 1, y);
        unsigned char img_y2 = surf2Dread<unsigned char>((cudaSurfaceObject_t)image0, x + 0, y + 1);
        unsigned char img_y3 = surf2Dread<unsigned char>((cudaSurfaceObject_t)image0, x + 1, y + 1);

        unsigned char img_u = surf2Dread<unsigned char>((cudaSurfaceObject_t)image1, x,     y / 2);
        unsigned char img_v = surf2Dread<unsigned char>((cudaSurfaceObject_t)image1, x + 1, y / 2);

        int alpha = (int)plot_colors[0].w + (int)plot_colors[1].w + (int)plot_colors[2].w + (int)plot_colors[3].w;
        int meanu =
            (
                plot_colors[0].y*(int)plot_colors[0].w +
                plot_colors[1].y*(int)plot_colors[1].w +
                plot_colors[2].y*(int)plot_colors[2].w +
                plot_colors[3].y*(int)plot_colors[3].w
            ) / alpha;
        int meanv =
            (
                plot_colors[0].z*(int)plot_colors[0].w +
                plot_colors[1].z*(int)plot_colors[1].w +
                plot_colors[2].z*(int)plot_colors[2].w +
                plot_colors[3].z*(int)plot_colors[3].w
            ) / alpha;
        alpha >>= 2;

        surf2Dwrite<unsigned char>((plot_colors[0].x * (int)plot_colors[0].w + (255 - plot_colors[0].w) * img_y0) >> 8, (cudaSurfaceObject_t)image0, x + 0, y);
        surf2Dwrite<unsigned char>((plot_colors[1].x * (int)plot_colors[1].w + (255 - plot_colors[1].w) * img_y1) >> 8, (cudaSurfaceObject_t)image0, x + 1, y);
        surf2Dwrite<unsigned char>((plot_colors[2].x * (int)plot_colors[2].w + (255 - plot_colors[2].w) * img_y2) >> 8, (cudaSurfaceObject_t)image0, x + 0, y + 1);
        surf2Dwrite<unsigned char>((plot_colors[3].x * (int)plot_colors[3].w + (255 - plot_colors[3].w) * img_y3) >> 8, (cudaSurfaceObject_t)image0, x + 1, y + 1);

        surf2Dwrite<unsigned char>((alpha * meanu + (255 - alpha) * img_u) >> 8, (cudaSurfaceObject_t)image1, x    , y / 2);
        surf2Dwrite<unsigned char>((alpha * meanv + (255 - alpha) * img_v) >> 8, (cudaSurfaceObject_t)image1, x + 1, y / 2);
    }
};

template<>
struct BlendingPixel<ImageFormat::PitchLinearNV12>{
    static __device__ void call(
        const void* image0, const void* image1,
        int x, int y, int stride, uchar4 plot_colors[4]
    ) {
        unsigned char& img_y0 = *((unsigned char*)image0 + y * stride + x + 0);
        unsigned char& img_y1 = *((unsigned char*)image0 + y * stride + x + 1);
        unsigned char& img_y2 = *((unsigned char*)image0 + (y+1) * stride + x + 0);
        unsigned char& img_y3 = *((unsigned char*)image0 + (y+1) * stride + x + 1);

        unsigned char* img_uv_ptr = (unsigned char*)image1 + (y / 2) * stride + x;
        unsigned char& img_u = img_uv_ptr[0];
        unsigned char& img_v = img_uv_ptr[1];

        int alpha = (int)plot_colors[0].w + (int)plot_colors[1].w + (int)plot_colors[2].w + (int)plot_colors[3].w;
        int meanu =
            (
                plot_colors[0].y*(int)plot_colors[0].w +
                plot_colors[1].y*(int)plot_colors[1].w +
                plot_colors[2].y*(int)plot_colors[2].w +
                plot_colors[3].y*(int)plot_colors[3].w
            ) / alpha;
        int meanv =
            (
                plot_colors[0].z*(int)plot_colors[0].w +
                plot_colors[1].z*(int)plot_colors[1].w +
                plot_colors[2].z*(int)plot_colors[2].w +
                plot_colors[3].z*(int)plot_colors[3].w
            ) / alpha;
        alpha >>= 2;

        img_y0 = (plot_colors[0].x * (int)plot_colors[0].w + (255 - plot_colors[0].w) * img_y0) >> 8;
        img_y1 = (plot_colors[1].x * (int)plot_colors[1].w + (255 - plot_colors[1].w) * img_y1) >> 8;
        img_y2 = (plot_colors[2].x * (int)plot_colors[2].w + (255 - plot_colors[2].w) * img_y2) >> 8;
        img_y3 = (plot_colors[3].x * (int)plot_colors[3].w + (255 - plot_colors[3].w) * img_y3) >> 8;
        img_u = (alpha * meanu + (255 - alpha) * img_u) >> 8;
        img_v = (alpha * meanv + (255 - alpha) * img_v) >> 8;
    }
};

template<bool have_rotate_msaa>
static __device__ void do_rectangle(RectangleCommand* cmd, int ix, int iy, uchar4 context_color[4]);

template<>
__device__ void do_rectangle<true>(RectangleCommand* cmd, int ix, int iy, uchar4 context_color[4]) {
    if (cmd->thickness == -1) {
        if (cmd->interpolation) {
            render_rectangle_fill_msaa4x(ix, iy, cmd, context_color);
        } else {
            render_rectangle_fill(ix, iy, cmd, context_color);
        }
    } else {
        if (cmd->interpolation) {
            render_rectangle_border_msaa4x(ix, iy, cmd, context_color);
        } else {
            render_rectangle_border(ix, iy, cmd, context_color);
        }
    }
}

template<>
__device__ void do_rectangle<false>(RectangleCommand* cmd, int ix, int iy, uchar4 context_color[4]) {
    if (cmd->thickness == -1) {
        render_rectangle_fill(ix, iy, cmd, context_color);
    } else {
        render_rectangle_border(ix, iy, cmd, context_color);
    }
}

// render_elements_kernel:
// main entry for launching render CUDA kernel
template<ImageFormat format, bool have_rotate_msaa>
static __global__ void render_elements_kernel(
    int bx, int by,
    const TextLocation* text_locations, const unsigned char* text_bitmap, int text_bitmap_width, const int* line_location_base,
    const unsigned char* commands, const int* command_offsets, int num_command,
    const void* image0, const void* image1,
    int image_width, int stride, int image_height
) {
    int ix = ((blockDim.x * blockIdx.x + threadIdx.x) << 1) + bx;
    int iy = ((blockDim.y * blockIdx.y + threadIdx.y) << 1) + by;
    if (ix < 0 || iy < 0 || ix >= image_width - 1 || iy >= image_height - 1)
        return;

    int itext_line          = 0;
    uchar4 context_color[4] = {0};
    for (int i = 0; i < num_command; ++i) {
        cuOSDContextCommand* pcommand = (cuOSDContextCommand*)(commands + command_offsets[i]);

        // because there is four pixel to operator
        if (ix + 1 < pcommand->bounding_left || ix > pcommand->bounding_right ||
           iy + 1 < pcommand->bounding_top || iy > pcommand->bounding_bottom) {

            if (pcommand->type == CommandType::Text)
                itext_line++;
            continue;
        }

        switch(pcommand->type) {
            case CommandType::Rectangle:{
                RectangleCommand* rect_cmd = (RectangleCommand*)pcommand;
                do_rectangle<have_rotate_msaa>(rect_cmd, ix, iy, context_color);
                break;
            }
            case CommandType::Text:{
                int ilocation_begin = line_location_base[itext_line];
                int ilocation_end   = line_location_base[itext_line + 1];
                itext_line++;

                for (int j = ilocation_begin; j < ilocation_end; ++j) {
                    bool hit = render_text(
                        ix, iy, text_locations[j], text_bitmap, text_bitmap_width,
                        context_color, pcommand->c0, pcommand->c1, pcommand->c2, pcommand->c3
                    );
                    if (hit) break;
                }
                break;
            }
            case CommandType::Circle:{
                CircleCommand* circle_cmd = (CircleCommand*)pcommand;
                render_circle_interpolation(ix, iy, circle_cmd, context_color);
                break;
            }
            case CommandType::Segment:{
                SegmentCommand* seg_cmd = (SegmentCommand*)pcommand;
                render_segment_bilinear(ix, iy, seg_cmd, context_color);
                break;
            }
            case CommandType::RGBASource:{
                RGBASourceCommand* rgba_src_cmd = (RGBASourceCommand*)pcommand;
                render_rgba_src(
                    ix, iy, rgba_src_cmd->bounding_left, rgba_src_cmd->bounding_top, rgba_src_cmd->bounding_left + rgba_src_cmd->width, rgba_src_cmd->bounding_top + rgba_src_cmd->height,
                    (unsigned char*)rgba_src_cmd->d_src, context_color
                );
                break;
            }
            case CommandType::NV12Source:{
                NV12SourceCommand* nv12_src_cmd = (NV12SourceCommand*)pcommand;
                if (nv12_src_cmd->block_linear) {
                    render_bl_nv12_src(
                        ix, iy, nv12_src_cmd->bounding_left, nv12_src_cmd->bounding_top, nv12_src_cmd->bounding_left + nv12_src_cmd->width, nv12_src_cmd->bounding_top + nv12_src_cmd->height,
                        (cudaSurfaceObject_t)nv12_src_cmd->d_src0, (cudaSurfaceObject_t)nv12_src_cmd->d_src1, context_color,
                        pcommand->c0, pcommand->c1, pcommand->c2, pcommand->c3
                    );
                }
                else {
                    render_pl_nv12_src(
                        ix, iy, nv12_src_cmd->bounding_left, nv12_src_cmd->bounding_top, nv12_src_cmd->bounding_left + nv12_src_cmd->width, nv12_src_cmd->bounding_top + nv12_src_cmd->height,
                        (unsigned char*)nv12_src_cmd->d_src0, (unsigned char*)nv12_src_cmd->d_src1, context_color,
                        pcommand->c0, pcommand->c1, pcommand->c2, pcommand->c3
                    );
                }
                break;
            }
        }
    }

    if (context_color[0].w == 0 && context_color[1].w == 0 && context_color[2].w == 0 && context_color[3].w == 0)
        return;

    BlendingPixel<format>::call(image0, image1, ix, iy, stride, context_color);
}

static __device__ void __forceinline__ yuv2rgb(
    int y, int u, int v, uint8_t& r, uint8_t& g, uint8_t& b
){
    int iyval = 1220542*max(0, y - 16);
    r = u8cast((iyval + 1673527*(v - 128)                      + (1 << 19)) >> 20);
    g = u8cast((iyval - 852492*(v - 128) - 409993*(u - 128)    + (1 << 19)) >> 20);
    b = u8cast((iyval                      + 2116026*(u - 128) + (1 << 19)) >> 20);
}

static __device__ void __forceinline__ rgb2yuv(
    int r, int g, int b, uint8_t& y, uint8_t& u, uint8_t& v
){
    y = ((66 * r + 129 * g + 25 * b + 128) >> 8) + 16;
    u = ((-38 * r - 74 * g + 112 * b + 128) >> 8) + 128;
    v = ((112 * r - 94 * g - 18 * b + 128) >> 8) + 128;
    // y = u8cast(0.299f * r + 0.587f * g + 0.114f * b);
    // u = u8cast(-0.1687f * r - 0.3313 * g + 0.5f * b + 128);
    // v = u8cast(0.5f * r - 0.4187f * g - 0.0813f * b + 128);
}

template<ImageFormat format>
static __device__ void __forceinline__ load_pixel(
    const void* luma, const void* chroma,
    int x, int y, int down_x, int width, int stride, uint8_t& r, uint8_t& g, uint8_t& b
);

// BL sample pixel implmentation
template<>
__device__ void __forceinline__ load_pixel<ImageFormat::BlockLinearNV12>(
    const void* luma, const void* chroma,
    int x, int y, int down_x, int width, int stride, uint8_t& r, uint8_t& g, uint8_t& b
){
    uint8_t yv = surf2Dread<uint8_t>((cudaTextureObject_t)luma,   x,          y    );
    uint8_t uv = surf2Dread<uint8_t>((cudaTextureObject_t)chroma, down_x + 0, y / 2);
    uint8_t vv = surf2Dread<uint8_t>((cudaTextureObject_t)chroma, down_x + 1, y / 2);
    yuv2rgb(yv, uv, vv, r, g, b);
}

// PL sample pixel implmentation
template<>
__device__ void __forceinline__ load_pixel<ImageFormat::PitchLinearNV12>(
    const void* luma, const void* chroma,
    int x, int y, int down_x, int width, int stride, uint8_t& r, uint8_t& g, uint8_t& b
){
    uint8_t yv = *((const unsigned char*)luma + y * stride + x);
    uint8_t uv = *((const unsigned char*)chroma + (y / 2) * stride + down_x + 0);
    uint8_t vv = *((const unsigned char*)chroma + (y / 2) * stride + down_x + 1);
    yuv2rgb(yv, uv, vv, r, g, b);
}

template<>
__device__ void __forceinline__ load_pixel<ImageFormat::RGB>(
    const void* luma, const void* chroma,
    int x, int y, int down_x, int width, int stride, uint8_t& r, uint8_t& g, uint8_t& b
){
    uchar3 pixel = *(uchar3*)((const unsigned char*)luma + y * stride + x * 3);
    r = pixel.x;
    g = pixel.y;
    b = pixel.z;
}

template<>
__device__ void __forceinline__ load_pixel<ImageFormat::RGBA>(
    const void* luma, const void* chroma,
    int x, int y, int down_x, int width, int stride, uint8_t& r, uint8_t& g, uint8_t& b
){
    uchar4 pixel = *(uchar4*)((const unsigned char*)luma + y * stride + x * 4);
    r = pixel.x;
    g = pixel.y;
    b = pixel.z;
}

template<ImageFormat format>
static __device__ void __forceinline__ save_pixel(
    void* luma, void* chroma,
    int x, int y, int down_x, int width, int stride, uint8_t& r, uint8_t& g, uint8_t& b
);

// BL sample pixel implmentation
template<>
__device__ void __forceinline__ save_pixel<ImageFormat::BlockLinearNV12>(
    void* luma, void* chroma,
    int x, int y, int down_x, int width, int stride, uint8_t& r, uint8_t& g, uint8_t& b
){
    uint8_t vy, vu, vv;
    rgb2yuv(r, g, b, vy, vu, vv);
    surf2Dwrite<uint8_t>(vy, (cudaTextureObject_t)luma,   x,          y    );
    surf2Dwrite<uint8_t>(vu, (cudaTextureObject_t)chroma, down_x + 0, y / 2);
    surf2Dwrite<uint8_t>(vv, (cudaTextureObject_t)chroma, down_x + 1, y / 2);
}

// PL sample pixel implmentation
template<>
__device__ void __forceinline__ save_pixel<ImageFormat::PitchLinearNV12>(
    void* luma, void* chroma,
    int x, int y, int down_x, int width, int stride, uint8_t& r, uint8_t& g, uint8_t& b
){
    uint8_t vy, vu, vv;
    rgb2yuv(r, g, b, vy, vu, vv);
    *((unsigned char*)luma + y * stride + x) = vy;
    *((unsigned char*)chroma + (y / 2) * stride + down_x + 0) = vu;
    *((unsigned char*)chroma + (y / 2) * stride + down_x + 1) = vv;
}

template<>
__device__ void __forceinline__ save_pixel<ImageFormat::RGB>(
    void* luma, void* chroma,
    int x, int y, int down_x, int width, int stride, uint8_t& r, uint8_t& g, uint8_t& b
){
    *(uchar3*)((const unsigned char*)luma + y * stride + x * 3) = make_uchar3(r, g, b);
}

template<>
__device__ void __forceinline__ save_pixel<ImageFormat::RGBA>(
    void* luma, void* chroma,
    int x, int y, int down_x, int width, int stride, uint8_t& r, uint8_t& g, uint8_t& b
){
    *(uchar4*)((const unsigned char*)luma + y * stride + x * 4) = make_uchar4(r, g, b, 255);
}

template<ImageFormat format>
static __global__ void render_blur_kernel(
    const BoxBlurCommand* commands, int num_command,
    void* image0, void* image1,
    int image_width, int stride, int image_height
) {
    __shared__ uchar3 crop[32][32];
    int ix = threadIdx.x;
    int iy = threadIdx.y;
    const BoxBlurCommand& box = commands[blockIdx.x];
    
    int boxwidth  = box.bounding_right  - box.bounding_left;
    int boxheight = box.bounding_bottom - box.bounding_top;
    int sx = limit((int)(ix / 32.0f * (float)boxwidth + 0.5f + box.bounding_left), 0, image_width);
    int sy = limit((int)(iy / 32.0f * (float)boxheight + 0.5f + box.bounding_top), 0, image_height);
    auto& pix = crop[iy][ix];
    load_pixel<format>(image0, image1, sx, sy, round_down2(sx), image_width, stride, pix.x, pix.y, pix.z);
    __syncthreads();

    uint3 color = make_uint3(0, 0, 0);
    int n = 0;
    for(int i = -box.kernel_size / 2; i <= box.kernel_size / 2; ++i){
        for(int j = -box.kernel_size / 2; j <= box.kernel_size / 2; ++j){
            int u = i + iy;
            int v = j + ix;
            if(u >= 0 && u < 32 && v >= 0 && v < 32){
                auto& c = crop[u][v];
                color.x += c.x;
                color.y += c.y;
                color.z += c.z;
                n++;
            }
        }
    }
    __syncthreads();
    crop[iy][ix] = make_uchar3(color.x / n, color.y / n, color.z / n);
    __syncthreads();

    int gap_width  = (boxwidth  + 31) / 32;
    int gap_height = (boxheight + 31) / 32;
    for(int i = 0; i < gap_height; ++i){
        for(int j = 0; j < gap_width; ++j){
            int fx = ix * gap_width + j + box.bounding_left;
            int fy = iy * gap_height + i + box.bounding_top;
            if(fx >= 0 && fx < image_width && fy >= 0 && fy < image_height){
                int sx = (ix * gap_width + j) / (float)boxwidth * 32;
                int sy = (iy * gap_height + i) / (float)boxheight * 32;
                if(sx < 32 && sy < 32){
                    auto& pix = crop[sy][sx];
                    // *(uchar3*)((char*)image0 + fy * stride + fx * 3) = crop[sy][sx];
                    save_pixel<format>(image0, image1, fx, fy, round_down2(sx), image_width, stride, pix.x, pix.y, pix.z);
                }
            }
        }
    }
}

typedef void(*cuosd_launch_kernel_impl_fptr)(
    void* image_data0, void* image_data1, int width, int stride, int height,
    const TextLocation* text_location, const unsigned char* text_bitmap, int text_bitmap_width, const int* line_location_base,
    const unsigned char* commands, const int* commands_offset, int num_commands,
    int bounding_left, int bounding_top, int bounding_right, int bounding_bottom,
    void* _stream
);

typedef void(*cuosd_launch_blur_kernel_impl_fptr)(
    void* image_data0, void* image_data1, int width, int stride, int height,
    const BoxBlurCommand* commands, int num_commands,
    void* _stream
);

template<ImageFormat format, bool have_rotate_msaa>
static void cuosd_launch_kernel_impl(
    void* image_data0, void* image_data1, int width, int stride, int height,
    const TextLocation* text_location, const unsigned char* text_bitmap, int text_bitmap_width, const int* line_location_base,
    const unsigned char* commands, const int* commands_offset, int num_commands,
    int bounding_left, int bounding_top, int bounding_right, int bounding_bottom,
    void* _stream
) {
    bounding_left   = max(min(bounding_left, width-1),    0);
    bounding_top    = max(min(bounding_top, height-1),    0);
    bounding_right  = max(min(bounding_right, width-1),   0);
    bounding_bottom = max(min(bounding_bottom, height-1), 0);

    bounding_left = round_down2(bounding_left);
    bounding_top  = round_down2(bounding_top);

    int bounding_width  = bounding_right - bounding_left + 1;
    int bounding_height = bounding_bottom - bounding_top + 1;
    if (bounding_width < 1 || bounding_height < 1) {
        CUOSD_PRINT_W("Please check if there is anything to draw, or cuosd_apply has been called\n");
        return;
    }

    cudaStream_t stream = (cudaStream_t)_stream;
    dim3 block(16, 8);
    dim3 grid(((bounding_width+1) / 2 + block.x - 1) / block.x, ((bounding_height+1) / 2 + block.y - 1) / block.y);
    render_elements_kernel<format, have_rotate_msaa> <<<grid, block, 0, stream>>>(
        bounding_left, bounding_top,
        text_location, text_bitmap, text_bitmap_width, line_location_base,
        commands,  commands_offset, num_commands,
        image_data0, image_data1, width, stride, height
    );
    cudaError_t code = cudaPeekAtLastError();
    if(code != cudaSuccess){
        CUOSD_PRINT_E("Launch kernel (render_elements_kernel) failed, code = %d", static_cast<int>(code));
    }
}

template<ImageFormat format>
static void cuosd_launch_blur_kernel_impl(
    void* image_data0, void* image_data1, int width, int stride, int height,
    const BoxBlurCommand* commands, int num_commands,
    void* _stream
) {
    if (num_commands < 1) {
        CUOSD_PRINT_W("Please check if there is anything to draw, or cuosd_apply has been called\n");
        return;
    }

    cudaStream_t stream = (cudaStream_t)_stream;
    dim3 block(32, 32);
    dim3 grid(num_commands);
    render_blur_kernel<format> <<<grid, block, 0, stream>>>(
        commands, num_commands,
        image_data0, image_data1, width, stride, height
    );

    cudaError_t code = cudaPeekAtLastError();
    if(code != cudaSuccess){
        CUOSD_PRINT_E("Launch kernel (render_blur_kernel) failed, code = %d", static_cast<int>(code));
    }
}

void cuosd_launch_kernel(
    void* image_data0, void* image_data1, int width, int stride, int height, ImageFormat format,
    const TextLocation* text_location, const unsigned char* text_bitmap, int text_bitmap_width, const int* line_location_base,
    const unsigned char* commands, const int* commands_offset, int num_commands,
    int bounding_left, int bounding_top, int bounding_right, int bounding_bottom,
    bool have_rotate_msaa, const unsigned char* blur_commands, int num_blur_commands,
    void* _stream
) { 
    if(num_blur_commands > 0){
        const static cuosd_launch_blur_kernel_impl_fptr func_list[] = {
            cuosd_launch_blur_kernel_impl<ImageFormat::RGB>,
            cuosd_launch_blur_kernel_impl<ImageFormat::RGBA>,
            cuosd_launch_blur_kernel_impl<ImageFormat::BlockLinearNV12>,
            cuosd_launch_blur_kernel_impl<ImageFormat::PitchLinearNV12>
        };

        int index = (int)format - 1;
        if (index < 0 || index >= (int)sizeof(func_list) / (int)sizeof(func_list[0])) {
            CUOSD_PRINT_E("Unsupported configure %d\n", (int)index);
            return;
        }

        func_list[index](
            image_data0, image_data1, width, stride, height, 
            (BoxBlurCommand*)blur_commands, num_blur_commands,
            _stream
        );
    }

    if(num_commands > 0){
        const static cuosd_launch_kernel_impl_fptr func_list[] = {
            cuosd_launch_kernel_impl<ImageFormat::RGB, false>,
            cuosd_launch_kernel_impl<ImageFormat::RGBA, false>,
            cuosd_launch_kernel_impl<ImageFormat::BlockLinearNV12, false>,
            cuosd_launch_kernel_impl<ImageFormat::PitchLinearNV12, false>,

            cuosd_launch_kernel_impl<ImageFormat::RGB, true>,
            cuosd_launch_kernel_impl<ImageFormat::RGBA, true>,
            cuosd_launch_kernel_impl<ImageFormat::BlockLinearNV12, true>,
            cuosd_launch_kernel_impl<ImageFormat::PitchLinearNV12, true>,
        };

        int index = (int)(have_rotate_msaa) * 4 + (int)format - 1;
        if (index < 0 || index >= (int)sizeof(func_list) / (int)sizeof(func_list[0])) {
            CUOSD_PRINT_E("Unsupported configure %d\n", (int)index);
            return;
        }

        func_list[index](
            image_data0, image_data1, width, stride, height, text_location, text_bitmap, text_bitmap_width, line_location_base,
            commands, commands_offset, num_commands,
            bounding_left, bounding_top, bounding_right, bounding_bottom,
            _stream
        );
    }
}