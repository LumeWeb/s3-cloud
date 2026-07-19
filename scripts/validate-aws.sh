#!/usr/bin/env bash
# scripts/validate-aws.sh: Local static validation for the AWS target.
# Does NOT require AWS credentials.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
AWS_DIR="$ROOT/deploy/aws"
FAILED=0

echo "==> Validating AWS target artifacts..."

# --- Packer ---
if command -v packer >/dev/null 2>&1; then
  echo "--> Packer fmt check"
  if ! packer fmt -check "$AWS_DIR/"; then
    echo "  FAIL: packer fmt check failed"
    FAILED=1
  else
    echo "  PASS: packer fmt check"
  fi

  echo "--> Packer init + validate"
  if (cd "$AWS_DIR" && packer init . && packer validate -syntax-only .); then
    echo "  PASS: packer validate"
  else
    echo "  FAIL: packer validate failed"
    FAILED=1
  fi
else
  echo "WARN: packer not found, skipping HCL validation"
fi

# --- CloudFormation JSON ---
echo "--> CloudFormation JSON parse"
if python3 -c "import json; json.load(open('$AWS_DIR/cloudformation.template.json'))"; then
  echo "  PASS: CloudFormation JSON parses"
else
  echo "  FAIL: CloudFormation JSON parse error"
  FAILED=1
fi

# --- Shell scripts ---
for SH in "$AWS_DIR/scripts/001_provision.sh" "$AWS_DIR/scripts/900-cleanup.sh" "$AWS_DIR/scripts/validate.sh"; do
  echo "--> bash -n: $SH"
  if bash -n "$SH"; then
    echo "  PASS: $SH"
  else
    echo "  FAIL: $SH"
    FAILED=1
  fi
done

# --- Python scripts ---
for PY in "$AWS_DIR/submit.py" "$AWS_DIR/scripts/prune-snapshots.py" "$AWS_DIR/scripts/prune-instances.py"; do
  echo "--> py_compile: $PY"
  if python3 -m py_compile "$PY"; then
    echo "  PASS: $PY"
  else
    echo "  FAIL: $PY"
    FAILED=1
  fi
done

# --- Makefile ---
echo "--> Makefile syntax check"
if make -C "$AWS_DIR" -n all >/dev/null 2>&1; then
  echo "  PASS: Makefile syntax"
else
  echo "  FAIL: Makefile syntax"
  FAILED=1
fi

# --- Markdown frontmatter sanity ---
for MD in "$AWS_DIR/marketplace/USAGE_INSTRUCTIONS.md" "$AWS_DIR/marketplace/SECURITY_GROUPS.md" "$AWS_DIR/marketplace/SUBMISSION_CHECKLIST.md"; do
  echo "--> file exists and non-empty: $MD"
  if [ -s "$MD" ]; then
    echo "  PASS: $MD"
  else
    echo "  FAIL: $MD missing or empty"
    FAILED=1
  fi
done

if [ "$FAILED" -ne 0 ]; then
  echo ""
  echo "Error: AWS validation failed" >&2
  exit 1
fi

echo ""
echo "==> AWS target validation passed"
