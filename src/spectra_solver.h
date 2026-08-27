/*     CalculiX - A 3-dimensional finite element program                   */
/*     Spectra C++ Eigenvalue Solver Bridge Header                        */

#ifndef SPECTRA_SOLVER_H
#define SPECTRA_SOLVER_H

#ifdef __cplusplus
extern "C" {
#endif

#include "CalculiX.h"

/**
 * @brief Solves the symmetric generalized eigenvalue problem (K * u = lambda * M * u)
 *        using Spectra in Shift-Invert mode ((K - sigma * M)^{-1} M u = mu * u).
 *
 * @param n             Dimension of the system (neq[1]).
 * @param nev           Number of eigenvalues requested.
 * @param ncv           Number of Lanczos basis vectors (if <= 0, auto-determined).
 * @param sigma         Shift parameter (double).
 * @param tol           Convergence tolerance (0.0 for default machine precision).
 * @param maxiter       Maximum number of Arnoldi/Lanczos iterations.
 * @param isolver       Active linear solver ID (0: SPOOLES, 7: PARDISO, 9: MUMPS, 11: ACCELERATE).
 * @param symmetryflag  Symmetry flag passed to direct solver.
 * @param inputformat   Input format passed to direct solver.
 * @param nrhs          Number of right-hand sides (typically 1).
 * @param adb           Mass matrix main diagonal array.
 * @param aub           Mass matrix upper/off-diagonal array.
 * @param jq            Mass matrix column index array.
 * @param irow          Mass matrix row index array.
 * @param d             Output array for eigenvalues (size nev, double).
 * @param z             Output array for eigenvectors (size n * nev, double column-major).
 * @return ITG          0 on success, non-zero on error.
 */
ITG spectra_solve_freq_sym(
    ITG n,
    ITG nev,
    ITG ncv,
    double sigma,
    double tol,
    ITG maxiter,
    ITG isolver,
    ITG symmetryflag,
    ITG inputformat,
    ITG nrhs,
    double *adb,
    double *aub,
    ITG *jq,
    ITG *irow,
    double *d,
    double *z
);

#ifdef __cplusplus
}
#endif

#endif /* SPECTRA_SOLVER_H */

