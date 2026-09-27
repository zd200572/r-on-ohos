/* zdot_compat.c —— f2c 调用约定的复数点积
 * OpenBLAS(NOFOORTAN 构建) 的 zdotu/zdotc 按寄存器返回复数结构体（C 返回值约定），
 * 与 f2c/gfortran 的隐藏首参内存返回约定不兼容（R configure 的复数 BLAS 测试会崩）。
 * 本文件提供 f2c 约定的四个入口，链接顺序在 -lopenblas 之前即可遮蔽。
 * 类型定义取自 f2c.h：integer=int，complex={float r,i}，doublecomplex={double r,i}。
 */
#include "f2c.h"

void zdotu_(doublecomplex *ret, integer *n, doublecomplex *zx, integer *incx,
            doublecomplex *zy, integer *incy)
{
    integer i, ix = 0, iy = 0;
    double dr = 0.0, di = 0.0;
    for (i = 0; i < *n; i++) {
        dr += zx[ix].r * zy[iy].r - zx[ix].i * zy[iy].i;
        di += zx[ix].r * zy[iy].i + zx[ix].i * zy[iy].r;
        ix += *incx; iy += *incy;
    }
    ret->r = dr; ret->i = di;
}

void zdotc_(doublecomplex *ret, integer *n, doublecomplex *zx, integer *incx,
            doublecomplex *zy, integer *incy)
{
    integer i, ix = 0, iy = 0;
    double dr = 0.0, di = 0.0;
    for (i = 0; i < *n; i++) {
        dr += zx[ix].r * zy[iy].r + zx[ix].i * zy[iy].i;
        di += zx[ix].r * zy[iy].i - zx[ix].i * zy[iy].r;
        ix += *incx; iy += *incy;
    }
    ret->r = dr; ret->i = di;
}

void cdotu_(complex *ret, integer *n, complex *cx, integer *incx,
            complex *cy, integer *incy)
{
    integer i, ix = 0, iy = 0;
    float fr = 0.0f, fi = 0.0f;
    for (i = 0; i < *n; i++) {
        fr += cx[ix].r * cy[iy].r - cx[ix].i * cy[iy].i;
        fi += cx[ix].r * cy[iy].i + cx[ix].i * cy[iy].r;
        ix += *incx; iy += *incy;
    }
    ret->r = fr; ret->i = fi;
}

void cdotc_(complex *ret, integer *n, complex *cx, integer *incx,
            complex *cy, integer *incy)
{
    integer i, ix = 0, iy = 0;
    float fr = 0.0f, fi = 0.0f;
    for (i = 0; i < *n; i++) {
        fr += cx[ix].r * cy[iy].r + cx[ix].i * cy[iy].i;
        fi += cx[ix].r * cy[iy].i - cx[ix].i * cy[iy].r;
        ix += *incx; iy += *incy;
    }
    ret->r = fr; ret->i = fi;
}
