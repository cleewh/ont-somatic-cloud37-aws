"""
Property test for scripts/compatibility_check.sh.

Feature: nextflow-poc-on-aws, Property 1: Compatibility check decision correctness
Validates: Requirements 3.1, 3.2, 3.3, 3.4, 3.5

For any set of BAM headers derived from the two tumor BAMs and one normal BAM,
the compatibility-check function SHALL emit status="pass" if and only if:
  (a) the union of SM tag values across both tumor BAMs is a singleton set, AND
  (b) the basecaller model identifier extracted from each of the three BAM
      headers equals the expected constant
      dna_r10.4.1_e8.2_400bps_sup@v4.2.0

When status="fail", the `mismatches` list SHALL contain at least one tag from
{sample_mismatch, basecaller_mismatch, basecaller_expected, basecaller_unresolved}
that names an actual violation.

Design reference: .kiro/specs/nextflow-poc-on-aws/design.md
  § "Compatibility Check" and § "Correctness Properties" (Property 1).

The test uses a `samtools` shim so real BAMs are not required — synthetic SAM
header text files serve as stand-ins. The `-H` invocation in
compatibility_check.sh just wants the header stream, which the shim reproduces
verbatim from the fixture text.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
import textwrap
from pathlib import Path

import pytest
from hypothesis import HealthCheck, given, settings, strategies as st

REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPT = REPO_ROOT / "scripts" / "compatibility_check.sh"
EXPECTED_BC = "dna_r10.4.1_e8.2_400bps_sup@v4.2.0"

# ------- SAMtools shim ------------------------------------------------------

SAMTOOLS_SHIM = textwrap.dedent(
    """\
    #!/usr/bin/env bash
    # Mock samtools that supports `samtools view -H <file>` and
    # `samtools --version` (compatibility_check.sh doesn't call --version,
    # but PATH probes might). It just emits the raw contents of the file.
    if [[ "$1" == "view" && "$2" == "-H" ]]; then
      cat "$3"
      exit 0
    fi
    if [[ "$1" == "--version" ]]; then
      echo "mock samtools 0.0"
      exit 0
    fi
    echo "mock samtools: unsupported args: $*" >&2
    exit 2
    """
)


@pytest.fixture(scope="session")
def shim_bin_dir(tmp_path_factory):
    """Create a temp dir with a samtools shim and return the dir path."""
    d = tmp_path_factory.mktemp("samtools_shim")
    p = d / "samtools"
    p.write_text(SAMTOOLS_SHIM)
    p.chmod(0o755)
    return str(d)


@pytest.fixture(scope="session")
def env_with_shim(shim_bin_dir):
    """Environment with the shim dir prepended to PATH."""
    env = os.environ.copy()
    env["PATH"] = f"{shim_bin_dir}:{env.get('PATH', '')}"
    return env


# ------- Header synthesis ---------------------------------------------------

BASE_HEADER_HD = "@HD\tVN:1.6\tSO:coordinate\n"
BASE_HEADER_SQ = "@SQ\tSN:chr1\tLN:248956422\n"


def _rg_line(sm: str, basecaller_encoding: str, basecaller: str | None) -> str:
    """
    Build a @RG line whose SM tag is `sm`.

    basecaller_encoding controls how the basecaller model is (or is not)
    embedded in this @RG line. `basecaller` is None means "don't encode".

    Encodings:
      - "rg_ds"   -> @RG DS:basecall_model=<name>
      - "rg_pl"   -> @RG PL:ONT DS:basecall_model=<name>
      - "rg_ds_token" -> @RG DS: contains the bare model token
      - "none"    -> no basecaller in this RG line
    """
    parts = ["@RG", "ID:rg1", f"SM:{sm}"]
    if basecaller_encoding == "rg_ds" and basecaller is not None:
        parts.append(f"DS:basecall_model={basecaller}")
    elif basecaller_encoding == "rg_pl" and basecaller is not None:
        parts.append("PL:ONT")
        parts.append(f"DS:basecall_model={basecaller}")
    elif basecaller_encoding == "rg_ds_token" and basecaller is not None:
        parts.append(f"DS:{basecaller}")
    return "\t".join(parts) + "\n"


def _pg_dorado(basecaller: str) -> str:
    return f"@PG\tID:dorado\tPN:dorado\tCL:dorado basecaller --model {basecaller} in.pod5\n"


def build_header(sm_values: list[str], basecaller: str | None, encoding: str) -> str:
    """
    Build a synthetic SAM header string.

    sm_values: list of SM tag values (one @RG line each, all with the same
      basecaller encoding).
    basecaller: model string, or None for "no basecaller anywhere".
    encoding: one of {"rg_ds", "rg_pl", "rg_ds_token", "pg_dorado", "none"}.
    """
    txt = BASE_HEADER_HD + BASE_HEADER_SQ
    if encoding == "pg_dorado":
        # No basecaller in @RG lines, only in @PG dorado CL.
        for sm in sm_values:
            txt += _rg_line(sm, "none", None)
        if basecaller is not None:
            txt += _pg_dorado(basecaller)
    else:
        for sm in sm_values:
            txt += _rg_line(sm, encoding, basecaller)
    return txt


# ------- Hypothesis strategies ----------------------------------------------

SM_NAMES = st.sampled_from(
    ["COLO829", "COLO829BL", "SAMPLE_A", "SAMPLE_B", "MIX"]
)

# Include the expected basecaller, a matching-family-but-different-version,
# and an entirely unrelated one to cover basecaller_mismatch/expected paths.
BASECALLERS = st.sampled_from(
    [
        EXPECTED_BC,
        "dna_r10.4.1_e8.2_400bps_sup@v4.3.0",
        "dna_r10.4.1_e8.2_400bps_hac@v4.2.0",
    ]
)

# None => triggers basecaller_unresolved
BASECALLER_OR_NONE = st.one_of(st.none(), BASECALLERS)

ENCODINGS = st.sampled_from(
    ["rg_ds", "rg_pl", "rg_ds_token", "pg_dorado"]
)


def _tumor_sm_lists():
    """
    Produce (tumor1_sm_values, tumor2_sm_values) where each is 1–2 SM values.
    """
    return st.tuples(
        st.lists(SM_NAMES, min_size=1, max_size=2),
        st.lists(SM_NAMES, min_size=1, max_size=2),
    )


# ------- Helpers to invoke the script ---------------------------------------


def run_compat_check(
    tumor1_path: Path,
    tumor2_path: Path | None,
    normal_path: Path,
    expected_bc: str,
    env: dict[str, str],
) -> dict:
    """
    Invoke compatibility_check.sh. tumor2_path=None -> pass "NONE" as arg 2.
    Returns the parsed JSON. Non-zero exit is expected on status=fail; the
    parser tolerates it because the script emits JSON on stdout in both cases.
    """
    t2 = "NONE" if tumor2_path is None else str(tumor2_path)
    result = subprocess.run(
        [
            "bash",
            str(SCRIPT),
            str(tumor1_path),
            t2,
            str(normal_path),
            expected_bc,
        ],
        capture_output=True,
        text=True,
        env=env,
    )
    # exit 0 on pass, 1 on fail — both emit JSON on stdout.
    assert result.returncode in (0, 1), (
        f"unexpected exit {result.returncode}; stderr:\n{result.stderr}"
    )
    return json.loads(result.stdout)


def _write_header_files(headers: list[str], workdir: Path) -> list[Path]:
    paths = []
    for i, h in enumerate(headers):
        p = workdir / f"bam_{i}.sam"
        p.write_text(h)
        paths.append(p)
    return paths


# ------- The property test --------------------------------------------------


@settings(
    max_examples=100,
    deadline=None,  # subprocess-heavy; deadline unreliable
    suppress_health_check=[HealthCheck.function_scoped_fixture],
)
@given(
    tumor_sm=_tumor_sm_lists(),
    normal_sm=SM_NAMES,
    tumor1_bc=BASECALLER_OR_NONE,
    tumor2_bc=BASECALLER_OR_NONE,
    normal_bc=BASECALLER_OR_NONE,
    tumor1_enc=ENCODINGS,
    tumor2_enc=ENCODINGS,
    normal_enc=ENCODINGS,
)
def test_property_1_compatibility_check_decision(
    tmp_path_factory,
    env_with_shim,
    tumor_sm,
    normal_sm,
    tumor1_bc,
    tumor2_bc,
    normal_bc,
    tumor1_enc,
    tumor2_enc,
    normal_enc,
):
    """
    Property 1: Compatibility check decision correctness.

    status="pass" IFF:
      (a) union(tumor1.sm_tags, tumor2.sm_tags) is a singleton, AND
      (b) all three basecaller ids equal expected_basecaller.

    When status="fail", `mismatches` must contain at least one tag from
    {sample_mismatch, basecaller_mismatch, basecaller_expected,
     basecaller_unresolved} and every listed tag must correspond to a
     demonstrable inequality in the generated input.
    """
    workdir = tmp_path_factory.mktemp("compat")

    tumor1_sm, tumor2_sm = tumor_sm

    tumor1_hdr = build_header(tumor1_sm, tumor1_bc, tumor1_enc)
    tumor2_hdr = build_header(tumor2_sm, tumor2_bc, tumor2_enc)
    normal_hdr = build_header([normal_sm], normal_bc, normal_enc)

    t1, t2, n = _write_header_files(
        [tumor1_hdr, tumor2_hdr, normal_hdr], workdir
    )

    result = run_compat_check(t1, t2, n, EXPECTED_BC, env_with_shim)

    # Ground-truth oracle (mirrors the intent of Property 1).
    tumor_sm_union = set(tumor1_sm) | set(tumor2_sm)
    is_sample_singleton = len(tumor_sm_union) == 1

    def resolves_to_expected(bc: str | None) -> bool:
        return bc == EXPECTED_BC

    def resolves(bc: str | None) -> bool:
        return bc is not None

    all_resolved = all(resolves(x) for x in (tumor1_bc, tumor2_bc, normal_bc))
    all_expected = all(
        resolves_to_expected(x) for x in (tumor1_bc, tumor2_bc, normal_bc)
    )
    tumors_bc_equal = tumor1_bc == tumor2_bc
    tumor_normal_bc_equal = tumor1_bc == normal_bc and tumor2_bc == normal_bc

    expected_pass = is_sample_singleton and all_expected

    # ---- Property 1 core claim ----
    if expected_pass:
        assert result["status"] == "pass", (
            f"Expected pass but got fail with mismatches={result['mismatches']} "
            f"for tumor_sm={tumor_sm}, bc=({tumor1_bc},{tumor2_bc},{normal_bc})"
        )
        assert result["mismatches"] == [], (
            f"Expected empty mismatches on pass but got {result['mismatches']}"
        )
    else:
        assert result["status"] == "fail", (
            f"Expected fail but got pass for tumor_sm={tumor_sm}, "
            f"bc=({tumor1_bc},{tumor2_bc},{normal_bc})"
        )
        assert len(result["mismatches"]) >= 1, (
            "fail status must have at least one mismatch tag"
        )
        # Every listed tag must correspond to a demonstrable inequality.
        for tag in result["mismatches"]:
            assert tag in {
                "sample_mismatch",
                "basecaller_mismatch",
                "basecaller_expected",
                "basecaller_unresolved",
            }, f"unknown mismatch tag: {tag}"

            if tag == "sample_mismatch":
                assert not is_sample_singleton, (
                    f"sample_mismatch reported but tumor SM union is singleton "
                    f"({tumor_sm_union}); tumor_sm={tumor_sm}"
                )
            elif tag == "basecaller_unresolved":
                # At least one input must have an unresolvable basecaller.
                # We approximate "unresolvable" as "we set the basecaller to
                # None (no encoding)" — the script reports "unknown" in that
                # case, which surfaces here as basecaller_unresolved.
                assert (tumor1_bc is None or tumor2_bc is None or normal_bc is None), (
                    "basecaller_unresolved but all three inputs have a bc set"
                )
            elif tag == "basecaller_mismatch":
                # The three resolved basecallers must not all be equal.
                # (Only reported when all three resolve; the script skips this
                # check if any is "unknown".)
                if all_resolved:
                    assert not (tumors_bc_equal and tumor_normal_bc_equal), (
                        "basecaller_mismatch reported but all three "
                        "basecallers are equal"
                    )
            elif tag == "basecaller_expected":
                # At least one resolved value != expected.
                resolved_pairs = [
                    x
                    for x in (tumor1_bc, tumor2_bc, normal_bc)
                    if x is not None
                ]
                assert any(x != EXPECTED_BC for x in resolved_pairs), (
                    "basecaller_expected reported but every resolved bc "
                    "equals the expected constant"
                )


if __name__ == "__main__":
    pytest.main([__file__, "-v"])
