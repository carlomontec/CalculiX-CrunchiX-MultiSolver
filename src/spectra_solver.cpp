/*     CalculiX - A 3-dimensional finite element program                   */
/*     Spectra C++ Eigenvalue Solver Bridge Implementation                */

#include <iostream>
#include <vector>
#include <algorithm>
#include <cmath>

#include <Eigen/Core>
#include <Spectra/SymGEigsShiftSolver.h>

#include "spectra_solver.h"

// Forward declarations of solver interfaces from CalculiX (C linkage)
extern "C" {
#ifdef SPOOLES
#include "spooles.h"
#endif

#ifdef PARDISO
#include "pardiso.h"
#endif

#ifdef MUMPS
#include "mumps.h"
#endif

#ifdef ACCELERATE_SOLVER
#include "accelerate_solver.h"
#endif

#ifdef SGI
#include "sgi.h"
#endif

#ifdef TAUCS
#include "tau.h"
#endif

#ifdef PASTIX
#include "pastix.h"
#endif
} // extern "C"

namespace {

// Shift-Invert Operator: computes y = (K - sigma * M)^{-1} * x
class CCX_ShiftInvertOp {
public:
    using Scalar = double;

private:
    ITG n_;
    ITG isolver_;
    ITG symmetryflag_;
    ITG inputformat_;
    ITG nrhs_;

public:
    CCX_ShiftInvertOp(ITG n, ITG isolver, ITG symmetryflag, ITG inputformat, ITG nrhs)
        : n_(n), isolver_(isolver), symmetryflag_(symmetryflag), inputformat_(inputformat), nrhs_(nrhs) {}

    Eigen::Index rows() const { return static_cast<Eigen::Index>(n_); }
    Eigen::Index cols() const { return static_cast<Eigen::Index>(n_); }

    void set_shift(const Scalar& /*sigma*/) {
        // Shift is pre-applied into K - sigma*M during the factor phase in CalculiX
    }

    void perform_op(const Scalar* x_in, Scalar* y_out) const {
        std::copy(x_in, x_in + n_, y_out);
        ITG n = n_;
        ITG sym = symmetryflag_;
        ITG inp = inputformat_;
        ITG nrhs = nrhs_;

        if (isolver_ == 0) {
#ifdef SPOOLES
            spooles_solve(y_out, &n);
#endif
        } else if (isolver_ == 4) {
#ifdef SGI
            ITG token = 1;
            sgi_solve(y_out, token);
#endif
        } else if (isolver_ == 5) {
#ifdef TAUCS
            tau_solve(y_out, &n);
#endif
        } else if (isolver_ == 7) {
#ifdef PARDISO
            pardiso_solve(y_out, &n, &sym, &inp, &nrhs);
#endif
        } else if (isolver_ == 8) {
#ifdef PASTIX
#ifdef PARDISO
            pardiso_solve(y_out, &n, &sym, &inp, &nrhs);
#else
            if (pastix_solve(y_out, &n, &sym, &nrhs) == -1) {
                std::cerr << " *WARNING in spectra: solving step didn't converge!\n";
            }
#endif
#endif
        } else if (isolver_ == 9) {
#ifdef MUMPS
            mumps_solve(y_out, &n, &sym, &inp, &nrhs);
#endif
        } else if (isolver_ == 11) {
#ifdef ACCELERATE_SOLVER
            accelerate_solve(y_out, &n, &sym, &inp, &nrhs);
#endif
        } else {
            std::cerr << " *ERROR in spectra_solver: unsupported solver id " << isolver_ << std::endl;
        }
    }
};

// Mass Matrix Operator: computes y = M * x
class CCX_MassOp {
public:
    using Scalar = double;

private:
    ITG n_;
    double *adb_;
    double *aub_;
    ITG *jq_;
    ITG *irow_;

public:
    CCX_MassOp(ITG n, double *adb, double *aub, ITG *jq, ITG *irow)
        : n_(n), adb_(adb), aub_(aub), jq_(jq), irow_(irow) {}

    Eigen::Index rows() const { return static_cast<Eigen::Index>(n_); }
    Eigen::Index cols() const { return static_cast<Eigen::Index>(n_); }

    void perform_op(const Scalar* x_in, Scalar* y_out) const {
        ITG n = n_;
        opmain(&n, const_cast<double*>(x_in), y_out, adb_, aub_, jq_, irow_);
    }
};

} // anonymous namespace

extern "C" {

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
) {
    if (n <= 0 || nev <= 0) {
        std::cerr << " *ERROR in spectra_solver: invalid matrix size or requested eigenvalue count\n";
        return -1;
    }

    if (nev >= n) {
        std::cerr << " *ERROR in spectra_solver: too many eigenvalues requested (" << nev << " >= " << n << ")\n";
        nev = n - 1;
        if (nev <= 0) return -1;
    }

    // Determine subspace dimension ncv (Spectra recommendation: 2*nev + 1 <= ncv <= 2*nev + 5)
    if (ncv < 2 * nev + 1) {
        ncv = 2 * nev + 1;
    }
    if (ncv > 2 * nev + 5 && ncv > 25) {
        ncv = 2 * nev + 5;
    }
    if (ncv > n) {
        ncv = n;
    }

    if (maxiter <= 0) {
        maxiter = 1000;
    }
    if (tol <= 0.0) {
        tol = 1e-8;
    }

    // Ensure small dense projections run sequentially to avoid thread oversubscription
    Eigen::setNbThreads(1);

    CCX_ShiftInvertOp shift_op(n, isolver, symmetryflag, inputformat, nrhs);
    CCX_MassOp mass_op(n, adb, aub, jq, irow);

    using SolverType = Spectra::SymGEigsShiftSolver<CCX_ShiftInvertOp, CCX_MassOp, Spectra::GEigsMode::ShiftInvert>;
    SolverType eigs(shift_op, mass_op, nev, ncv, sigma);

    eigs.init();

    int nconv = 0;
    try {
        nconv = eigs.compute(Spectra::SortRule::LargestMagn, maxiter, tol);
    } catch (const std::exception& e) {
        std::cerr << " *ERROR in Spectra::compute exception: " << e.what() << std::endl;
        return -2;
    } catch (...) {
        std::cerr << " *ERROR in Spectra::compute unknown exception" << std::endl;
        return -3;
    }

    printf(" [Spectra] Generalized eigensolver converged: %d/%d modes (iterations = %d, operations = %d)\n\n",
           (int)nconv, (int)nev, (int)eigs.num_iterations(), (int)eigs.num_operations());
    fflush(stdout);

    if (eigs.info() != Spectra::CompInfo::Successful) {
        std::cerr << " *ERROR in spectra_solver: computation did not converge (info = " 
                  << static_cast<int>(eigs.info()) << ", converged = " << nconv << " / " << nev << ")\n";
        return static_cast<ITG>(eigs.info());
    }

    Eigen::VectorXd evals = eigs.eigenvalues();
    Eigen::MatrixXd evecs = eigs.eigenvectors();

    // Sort eigenvalues and corresponding eigenvectors in ascending order (lowest frequency first)
    std::vector<size_t> indices(nev);
    for (size_t i = 0; i < static_cast<size_t>(nev); ++i) {
        indices[i] = i;
    }
    std::sort(indices.begin(), indices.end(), [&](size_t a, size_t b) {
        return evals(a) < evals(b);
    });

    for (ITG j = 0; j < nev; ++j) {
        size_t idx = indices[j];
        double val = evals(idx);
        d[j] = val;
        for (ITG i = 0; i < n; ++i) {
            z[j * n + i] = evecs(i, idx);
        }
    }

    return 0;
}

} // extern "C"


