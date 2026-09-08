#!/usr/bin/env python3
"""
JSON Verification Engine for CalculiX Multi-Solver Edition.
Performs fast, in-memory array and scalar comparisons between
a generated <jobname>.json and reference <jobname>.json.ref
without requiring Perl or external tools.
"""

import json
import math
from pathlib import Path
from typing import Dict, Any, Tuple, Optional


def is_close(a: Optional[float], b: Optional[float], rel_tol: float = 1e-3, abs_tol: float = 1e-8) -> bool:
    """Check if two floats are within numerical tolerance, handling nulls."""
    if a is None and b is None:
        return True
    if a is None or b is None:
        return False
    if math.isnan(a) and math.isnan(b):
        return True
    if math.isinf(a) and math.isinf(b):
        return (a > 0) == (b > 0)
    
    diff = abs(a - b)
    if diff <= abs_tol:
        return True
    
    max_val = max(abs(a), abs(b))
    if max_val <= abs_tol:
        return True
    
    return (diff / max_val) <= rel_tol


def compare_arrays(arr1, arr2, rel_tol: float = 1e-3, abs_tol: float = 1e-8) -> Tuple[bool, float, str]:
    """Recursively compare nested numeric arrays and compute max relative difference."""
    if len(arr1) != len(arr2):
        return False, 1.0, f"Array length mismatch: {len(arr1)} vs {len(arr2)}"
    
    max_rel_err = 0.0
    for idx, (v1, v2) in enumerate(zip(arr1, arr2)):
        if isinstance(v1, (list, tuple)) and isinstance(v2, (list, tuple)):
            ok, err, msg = compare_arrays(v1, v2, rel_tol, abs_tol)
            if not ok:
                return False, err, f"[{idx}]{msg}"
            if err > max_rel_err:
                max_rel_err = err
        elif isinstance(v1, dict) and isinstance(v2, dict):
            for k in v1:
                if k not in v2:
                    return False, 1.0, f"Key {k} missing in comparison dict"
                val1, val2 = v1[k], v2[k]
                if isinstance(val1, (list, tuple)):
                    ok, err, msg = compare_arrays(val1, val2, rel_tol, abs_tol)
                    if not ok:
                        return False, err, f".{k}{msg}"
                    if err > max_rel_err:
                        max_rel_err = err
                elif isinstance(val1, (int, float)) and isinstance(val2, (int, float)):
                    if not is_close(val1, val2, rel_tol, abs_tol):
                        diff = abs(val1 - val2)
                        max_val = max(abs(val1), abs(val2))
                        rel = diff / max_val if max_val > 0 else 1.0
                        return False, rel, f".{k} diff ({val1} vs {val2}, rel_err: {rel*100:.2f}%)"
        elif isinstance(v1, (int, float)) and isinstance(v2, (int, float)):
            if not is_close(v1, v2, rel_tol, abs_tol):
                diff = abs(v1 - v2)
                max_val = max(abs(v1), abs(v2))
                rel = diff / max_val if max_val > 0 else 1.0
                return False, rel, f"[{idx}] diff ({v1} vs {v2}, rel_err: {rel*100:.2f}%)"
            else:
                max_val = max(abs(v1), abs(v2))
                if max_val > abs_tol:
                    rel = abs(v1 - v2) / max_val
                    if rel > max_rel_err:
                        max_rel_err = rel
    return True, max_rel_err, "OK"


def compare_json(test_data: Dict[str, Any], ref_data: Dict[str, Any],
                 rel_tol: float = 1e-3, abs_tol: float = 1e-8) -> Tuple[str, str, float]:
    """
    Compare test JSON dictionary against reference JSON dictionary.
    Returns (status, detail_message, max_rel_error)
    where status is 'PASS', 'DIFF', or 'FAIL'.
    """
    test_steps = test_data.get("steps", [])
    ref_steps = ref_data.get("steps", [])

    if len(test_steps) != len(ref_steps):
        return "DIFF", f"Step count mismatch ({len(test_steps)} vs {len(ref_steps)})", 1.0

    overall_max_err = 0.0

    for s_idx, (t_step, r_step) in enumerate(zip(test_steps, ref_steps)):
        step_num = t_step.get("step_number", s_idx + 1)
        
        # 1. Compare Modes (Frequency / Eigenvalue analysis)
        if "modes" in r_step:
            if "modes" not in t_step:
                return "DIFF", f"Step {step_num}: missing modes in test output", 1.0
            t_modes = t_step["modes"]
            r_modes = r_step["modes"]
            if len(t_modes) != len(r_modes):
                return "DIFF", f"Step {step_num}: mode count mismatch ({len(t_modes)} vs {len(r_modes)})", 1.0
            for m_idx, (tm, rm) in enumerate(zip(t_modes, r_modes)):
                t_hz = tm.get("frequency_hz", 0.0)
                r_hz = rm.get("frequency_hz", 0.0)
                if not is_close(t_hz, r_hz, rel_tol, abs_tol):
                    rel = abs(t_hz - r_hz) / max(abs(r_hz), 1e-8)
                    return "DIFF", f"Step {step_num} Mode {m_idx+1} Hz diff ({t_hz:.4e} vs {r_hz:.4e}, {rel*100:.2f}%)", rel
                rel = abs(t_hz - r_hz) / max(abs(r_hz), 1e-8) if r_hz != 0 else 0.0
                overall_max_err = max(overall_max_err, rel)

        # 2. Compare Buckling Modes
        if "buckling_modes" in r_step:
            if "buckling_modes" not in t_step:
                return "DIFF", f"Step {step_num}: missing buckling_modes in test output", 1.0
            t_b = t_step["buckling_modes"]
            r_b = r_step["buckling_modes"]
            for b_idx, (tb, rb) in enumerate(zip(t_b, r_b)):
                t_fac = tb.get("buckling_factor", 0.0)
                r_fac = rb.get("buckling_factor", 0.0)
                if not is_close(t_fac, r_fac, rel_tol, abs_tol):
                    rel = abs(t_fac - r_fac) / max(abs(r_fac), 1e-8)
                    return "DIFF", f"Step {step_num} Buckle Mode {b_idx+1} diff ({t_fac:.4e} vs {r_fac:.4e}, {rel*100:.2f}%)", rel

        # 3. Compare Increments
        r_incs = r_step.get("increments", [])
        t_incs = t_step.get("increments", [])
        if len(r_incs) > 0:
            if len(t_incs) != len(r_incs):
                return "DIFF", f"Step {step_num}: increment count mismatch ({len(t_incs)} vs {len(r_incs)})", 1.0
            
            for inc_idx, (t_inc, r_inc) in enumerate(zip(t_incs, r_incs)):
                # Compare Node Sets (Displacements, Reaction Forces)
                r_nsets = r_inc.get("node_sets", {})
                t_nsets = t_inc.get("node_sets", {})
                for set_name, r_set in r_nsets.items():
                    if set_name not in t_nsets:
                        return "DIFF", f"Step {step_num} Inc {inc_idx+1}: missing node set {set_name}", 1.0
                    t_set = t_nsets[set_name]
                    ok, err, msg = compare_arrays(t_set.get("values", []), r_set.get("values", []), rel_tol, abs_tol)
                    if not ok:
                        return "DIFF", f"Step {step_num} Inc {inc_idx+1} {set_name} values {msg}", err
                    overall_max_err = max(overall_max_err, err)

                # Compare Element Sets (Stresses)
                r_esets = r_inc.get("element_sets", {})
                t_esets = t_inc.get("element_sets", {})
                for set_name, r_set in r_esets.items():
                    if set_name not in t_esets:
                        return "DIFF", f"Step {step_num} Inc {inc_idx+1}: missing element set {set_name}", 1.0
                    t_set = t_esets[set_name]
                    ok, err, msg = compare_arrays(t_set.get("values", []), r_set.get("values", []), rel_tol, abs_tol)
                    if not ok:
                        return "DIFF", f"Step {step_num} Inc {inc_idx+1} {set_name} stress {msg}", err
                    overall_max_err = max(overall_max_err, err)

    return "PASS", "OK", overall_max_err


def compare_files(test_file: Path, ref_file: Path, rel_tol: float = 1e-3, abs_tol: float = 1e-8) -> Tuple[str, str, float]:
    """Load and compare two JSON files."""
    try:
        with open(test_file, "r", encoding="utf-8") as f:
            test_data = json.load(f)
    except Exception as e:
        return "FAIL", f"Unable to parse test JSON: {e}", 1.0

    try:
        with open(ref_file, "r", encoding="utf-8") as f:
            ref_data = json.load(f)
    except Exception as e:
        return "FAIL", f"Unable to parse reference JSON: {e}", 1.0

    return compare_json(test_data, ref_data, rel_tol, abs_tol)
