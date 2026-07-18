#!/usr/bin/env bash
# compatibility_check.sh
#
# Verifies pre-staging compatibility of two tumor BAMs and one matched-normal
# BAM against the expected ONT basecaller model, per the wf-somatic-variation
# POC design at .kiro/specs/nextflow-poc-on-aws/design.md § "Compatibility
# Check" and Requirements 3.1 – 3.5.
#
# Inputs:
#   $1  tumor1_bam           path to first tumor BAM (must have @RG lines)
#   $2  tumor2_bam           path to second tumor BAM, OR the literal string
#                            "NONE" if the tumor is delivered as a single BAM.
#                            When "NONE", the tumor-vs-tumor SM comparison is
#                            skipped; a single-value SM tag is still required.
#   $3  normal_bam           path to matched normal BAM
#   $4  expected_basecaller  expected basecaller model string, e.g.
#                            dna_r10.4.1_e8.2_400bps_sup@v4.2.0
#
# Output:
#   compatibility-check.json on stdout, matching the schema in design.md
#   § "Data Models" (fields: status, expected_basecaller, tumor_bams,
#   normal_bam, mismatches).
#
# Exit code:
#   0 on status="pass", 1 on status="fail".
#
# Dependencies: samtools >= 1.17, awk, jq (for portable JSON emission).
#
# The extraction / decision logic is a direct implementation of design.md
# § "Compatibility Check" — DO NOT diverge without updating the design first.

set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo "usage: $0 <tumor1.bam> <tumor2.bam|NONE> <normal.bam> <expected_basecaller>" >&2
  exit 2
fi

TUMOR1="$1"
TUMOR2="$2"
NORMAL="$3"
EXPECTED_BC="$4"

for cmd in samtools awk jq; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "error: required command '$cmd' not found on PATH" >&2
    exit 2
  fi
done

# Extract per-BAM SM tag set (unique @RG SM values) and basecaller model.
# Basecaller resolution order (design § "Compatibility Check"):
#   1. @RG DS: field containing "basecall_model=..." or an ONT model token.
#   2. @PG PN:dorado line with CL: containing "--model <model>".
#   3. @RG PL:ONT combined with a "basecall_model=" token in nearby DS:.
# If none resolve, basecaller_model=unknown.
extract_headers() {
  local bam="$1"
  local out_sm out_bc

  # Emit "SM<tab>value" one line per @RG SM tag (deduped later).
  local hdr
  hdr="$(samtools view -H "$bam")"

  # Collect the unique SM values.
  local sm_json
  sm_json="$(printf '%s\n' "$hdr" | awk '
      /^@RG/ {
        for (i=2; i<=NF; i++) {
          if ($i ~ /^SM:/) { print substr($i, 4) }
        }
      }' | LC_ALL=C sort -u | jq -R . | jq -s .)"

  # Resolve basecaller model.
  # Try @RG DS: fields first — look for a token matching the ONT convention
  # ^dna_r[0-9.]+_e[0-9.]+_[0-9]+bps_[a-z]+@v[0-9.]+$ or the older
  # basecall_model=<name> assignment.
  local bc
  bc="$(printf '%s\n' "$hdr" | awk '
      function extract_model(s,   parts, i, tok) {
        # split on whitespace to find a bare model token or basecall_model=<val>
        n = split(s, parts, /[[:space:],;]+/)
        for (i=1; i<=n; i++) {
          tok = parts[i]
          if (tok ~ /^basecall_model=/) {
            sub(/^basecall_model=/, "", tok)
            return tok
          }
          if (tok ~ /^dna_r[0-9.]+_e[0-9.]+_[0-9]+bps_[a-z]+@v[0-9.]+$/) {
            return tok
          }
        }
        return ""
      }
      # 1) @RG DS: fields
      /^@RG/ {
        for (i=2; i<=NF; i++) {
          if ($i ~ /^DS:/) {
            ds = substr($i, 4)
            m = extract_model(ds)
            if (m != "") { print m; found=1; exit }
          }
        }
      }
      END { if (!found) exit 0 }
  ')"

  if [[ -z "$bc" ]]; then
    # 2) @PG dorado CL: --model <name>
    bc="$(printf '%s\n' "$hdr" | awk '
        /^@PG/ {
          is_dorado = 0
          cl = ""
          for (i=2; i<=NF; i++) {
            if ($i == "PN:dorado" || $i ~ /^PN:dorado/) { is_dorado = 1 }
          }
          if (is_dorado) {
            # rejoin fields to capture CL: which may contain spaces
            line = $0
            if (match(line, /CL:[^\t]*/)) {
              cl = substr(line, RSTART+3, RLENGTH-3)
              # look for --model <token> or --model=<token>
              if (match(cl, /--model[ =]+[^ ]+/)) {
                arg = substr(cl, RSTART, RLENGTH)
                sub(/^--model[ =]+/, "", arg)
                if (arg ~ /^dna_r[0-9.]+_e[0-9.]+_[0-9]+bps_[a-z]+@v[0-9.]+$/) {
                  print arg
                  exit
                }
              }
            }
          }
        }
    ')"
  fi

  if [[ -z "$bc" ]]; then
    # 3) @RG PL:ONT + basecall_model= token anywhere in the same RG line
    bc="$(printf '%s\n' "$hdr" | awk '
        /^@RG/ {
          is_ont = 0
          for (i=2; i<=NF; i++) {
            if ($i == "PL:ONT" || $i ~ /^PL:ONT/) { is_ont = 1 }
          }
          if (is_ont) {
            for (i=2; i<=NF; i++) {
              if ($i ~ /basecall_model=/) {
                val = $i
                sub(/^.*basecall_model=/, "", val)
                if (val ~ /^dna_r[0-9.]+_e[0-9.]+_[0-9]+bps_[a-z]+@v[0-9.]+$/) {
                  print val
                  exit
                }
              }
            }
          }
        }
    ')"
  fi

  if [[ -z "$bc" ]]; then
    bc="unknown"
  fi

  # emit as tab-separated: <sm_json>\t<basecaller>
  printf '%s\t%s\n' "$sm_json" "$bc"
}

extract_and_json() {
  local bam="$1"
  local rec
  rec="$(extract_headers "$bam")"
  local sm_json="${rec%$'\t'*}"
  local bc="${rec##*$'\t'}"
  local base
  base="$(basename "$bam")"
  jq -n --arg path "$base" --arg bc "$bc" --argjson sm "$sm_json" \
    '{path: $path, sm_tags: $sm, basecaller_model: $bc}'
}

TUMOR1_JSON="$(extract_and_json "$TUMOR1")"
if [[ "$TUMOR2" == "NONE" ]]; then
  TUMOR2_JSON=""
else
  TUMOR2_JSON="$(extract_and_json "$TUMOR2")"
fi
NORMAL_JSON="$(extract_and_json "$NORMAL")"

# Union of SM values across the two (or one) tumor BAM(s).
if [[ "$TUMOR2" == "NONE" ]]; then
  TUMOR_SM_UNION="$(echo "$TUMOR1_JSON" | jq -c '.sm_tags | unique')"
  TUMOR_BAMS_JSON="[$TUMOR1_JSON]"
else
  TUMOR_SM_UNION="$(jq -c -s '.[0].sm_tags + .[1].sm_tags | unique' \
                    <(echo "$TUMOR1_JSON") <(echo "$TUMOR2_JSON"))"
  TUMOR_BAMS_JSON="[$TUMOR1_JSON,$TUMOR2_JSON]"
fi

TUMOR1_BC="$(echo "$TUMOR1_JSON" | jq -r '.basecaller_model')"
NORMAL_BC="$(echo "$NORMAL_JSON" | jq -r '.basecaller_model')"
if [[ "$TUMOR2" == "NONE" ]]; then
  TUMOR2_BC="$TUMOR1_BC"
else
  TUMOR2_BC="$(echo "$TUMOR2_JSON" | jq -r '.basecaller_model')"
fi

# Decision function (design § "Compatibility Check").
MISMATCHES=()

# sample_mismatch — SM union across tumor BAMs must be singleton.
if [[ "$(echo "$TUMOR_SM_UNION" | jq 'length')" -ne 1 ]]; then
  MISMATCHES+=("sample_mismatch")
fi

# basecaller_unresolved — any BAM whose basecaller resolved to "unknown".
if [[ "$TUMOR1_BC" == "unknown" || "$TUMOR2_BC" == "unknown" || "$NORMAL_BC" == "unknown" ]]; then
  MISMATCHES+=("basecaller_unresolved")
fi

# basecaller_mismatch — the three (or two) values must all be equal.
if [[ "$TUMOR1_BC" != "unknown" && "$TUMOR2_BC" != "unknown" && "$NORMAL_BC" != "unknown" ]]; then
  if [[ "$TUMOR1_BC" != "$TUMOR2_BC" || "$TUMOR1_BC" != "$NORMAL_BC" ]]; then
    MISMATCHES+=("basecaller_mismatch")
  fi
fi

# basecaller_expected — resolved values must equal the expected constant.
for v in "$TUMOR1_BC" "$TUMOR2_BC" "$NORMAL_BC"; do
  if [[ "$v" != "unknown" && "$v" != "$EXPECTED_BC" ]]; then
    MISMATCHES+=("basecaller_expected")
    break
  fi
done

# Deduplicate MISMATCHES while preserving order.
# NOTE: Uses a linear scan over an ordinary array (bash 3.2 compatible on
# macOS where `declare -A` isn't available).
DEDUPED_MISMATCHES=()
for m in "${MISMATCHES[@]-}"; do
  [[ -z "$m" ]] && continue
  _found=0
  for existing in "${DEDUPED_MISMATCHES[@]-}"; do
    if [[ "$existing" == "$m" ]]; then
      _found=1
      break
    fi
  done
  if [[ "$_found" -eq 0 ]]; then
    DEDUPED_MISMATCHES+=("$m")
  fi
done

if [[ ${#DEDUPED_MISMATCHES[@]} -eq 0 ]]; then
  STATUS="pass"
else
  STATUS="fail"
fi

MISMATCHES_JSON="$(printf '%s\n' "${DEDUPED_MISMATCHES[@]-}" | jq -R . | jq -s 'map(select(. != ""))')"

jq -n \
  --arg status "$STATUS" \
  --arg expected_bc "$EXPECTED_BC" \
  --argjson tumor_bams "$TUMOR_BAMS_JSON" \
  --argjson normal_bam "$NORMAL_JSON" \
  --argjson mismatches "$MISMATCHES_JSON" \
  '{status: $status, expected_basecaller: $expected_bc, tumor_bams: $tumor_bams, normal_bam: $normal_bam, mismatches: $mismatches}'

if [[ "$STATUS" == "pass" ]]; then
  exit 0
else
  exit 1
fi
