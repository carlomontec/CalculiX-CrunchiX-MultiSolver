/*     CalculiX - A 3-dimensional finite element program                 */
/*              Copyright (C) 1998-2015 Guido Dhondt                          */

/*     This program is free software; you can redistribute it and/or     */
/*     modify it under the terms of the GNU General Public License as    */
/*     published by the Free Software Foundation(version 2);    */
/*                    */

/*     This program is distributed in the hope that it will be useful,   */
/*     but WITHOUT ANY WARRANTY; without even the implied warranty of    */
/*     MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the      */
/*     GNU General Public License for more details.                      */

/*     You should have received a copy of the GNU General Public License */
/*     along with this program; if not, write to the Free Software       */
/*     Foundation, Inc., 675 Mass Ave, Cambridge, MA 02139, USA.         */

#include <unistd.h>
#include <stdio.h>
#include <math.h>
#include <stdlib.h>
#if defined(_OPENMP)
#include <omp.h>
#endif
#include "CalculiX.h"

/*
 * opmain: Matrix-vector multiplication y = A * x for real sparse symmetric matrices
 *
 * Parallelization Note for CalculiX:
 * Because the sparse matrix A is stored in lower-triangular format (ad = diagonal,
 * au = subdiagonal entries), column j accesses row i > j and adds contributions
 * to both y(j) and y(i).
 *
 * To enable thread-safe parallelization across column intervals [na, nb] without
 * atomic locks, each thread computes partial products into a thread-private slice
 * in yy, followed by a fast parallel reduction into the output array y.
 *
 * This implementation uses OpenMP's persistent thread team (#pragma omp parallel)
 * instead of repeated pthread_create / pthread_join calls, eliminating OS thread
 * creation/teardown overhead during iterative eigenvalue extraction.
 */

void opmain(ITG *n, double *x, double *y, double *ad, double *au, ITG *jq, ITG *irow){

  ITG n_val = *n;
  if(n_val <= 0) return;

#if defined(_OPENMP)
  ITG num_threads = 1;
  #pragma omp parallel
  {
    #pragma omp single
    num_threads = omp_get_num_threads();
  }

  if(num_threads > n_val) num_threads = n_val;

  /* Serial path: direct in-place computation with zero allocation overhead */
  if(num_threads <= 1){
    ITG na = 1, nb = n_val;
    FORTRAN(op,(x, y, ad, au, jq, irow, &na, &nb));
    return;
  }

  /* Multithreaded path: persistent OpenMP thread team with parallel reduction */
  double *yy = NULL;
  NNEW(yy, double, (long long)num_threads * n_val);

  #pragma omp parallel
  {
    ITG tid = omp_get_thread_num();
    ITG idelta = (ITG)ceil(n_val / (double)num_threads);
    ITG na = tid * idelta + 1;
    ITG nb = (tid + 1) * idelta;
    if(nb > n_val) nb = n_val;

    if(na <= nb){
      long long indexf = (long long)tid * n_val;
      FORTRAN(op,(x, &yy[indexf], ad, au, jq, irow, &na, &nb));
    }

    #pragma omp barrier

    /* Parallel reduction across thread slices into output vector y */
    ITG r_na = tid * idelta;
    ITG r_nb = (tid + 1) * idelta;
    if(r_nb > n_val) r_nb = n_val;

    for(ITG j = r_na; j < r_nb; j++){
      double sum = yy[j];
      for(ITG k = 1; k < num_threads; k++){
        sum += yy[j + (long long)k * n_val];
      }
      y[j] = sum;
    }
  }

  SFREE(yy);

#else
  /* Serial fallback when OpenMP is not enabled */
  ITG na = 1, nb = n_val;
  FORTRAN(op,(x, y, ad, au, jq, irow, &na, &nb));
#endif

}

