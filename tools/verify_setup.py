"""Local tcsh smoke checks. Fake tool output is a fixture, not an EDA install."""
from pathlib import Path
import argparse, json, shutil, subprocess, tempfile

parser = argparse.ArgumentParser(description="Check setup.csh without installing or running a real EDA tool")
parser.add_argument('--tcsh', default=shutil.which('tcsh'))
args = parser.parse_args()
if not args.tcsh:
    parser.error('tcsh is required; install it at your site or pass --tcsh /path/to/tcsh')
stage = Path(__file__).resolve().parents[1]
tcsh = args.tcsh
base = Path(tempfile.mkdtemp(prefix="malu setup ", dir="/tmp"))
project = base / "project with spaces"
project.mkdir()
shutil.copy2(stage / "setup.csh", project / "setup.csh")
binpath = base / "fake eda bin"
binpath.mkdir()
fixture = binpath / "verilator"
fixture.write_text('#!/bin/sh\nprintf "%s\\n" "Verilator TEST_FIXTURE_1.2.3"\n')
fixture.chmod(0o700)
source = f'source "{project}/setup.csh" "{project}"'
results = []

def check(name, command, expected):
    p = subprocess.run([tcsh, "-f", "-c", command], cwd="/tmp", text=True, capture_output=True)
    for marker in expected:
        assert marker in p.stdout, (name, p.returncode, p.stdout, p.stderr)
    assert not p.stderr, (name, p.stderr)
    assert "SENTINEL_LICENSE_VALUE" not in p.stdout
    results.append({"name": name, "passed": True, "stdout": p.stdout.strip()})

result = '; echo RESULT:${status}:${MALU_SETUP_STATUS}'
version_result = result + ':${MALU_EDA_VERSION_STATUS}'
check("explicit root containing spaces; no EDA required", source+result, ["RESULT:0:0"])
check("repeated source preserves original PATH", 'set before = "$PATH"; '+source+'; '+source+'; if ("$PATH" == "$before") echo PATH_SAME', ["PATH_SAME"])
local = project / "setup.local.csh"
local.write_text(f'setenv MALU_SIMULATOR verilator\nsetenv MALU_EDA_BIN "{binpath}"\nsetenv EDA_VERSION TEST_FIXTURE_1.2.3\nsetenv MALU_BUILD_DIR local-build\n')
check("mock version pin; local config; PATH idempotence; license redaction", 'setenv LM_LICENSE_FILE SENTINEL_LICENSE_VALUE; '+source+'; set first = "$PATH"; '+source+version_result+'; if ("$PATH" == "$first") echo PATH_SAME; echo BUILD:$MALU_BUILD_DIR', ["RESULT:0:0:detected", "PATH_SAME", "value hidden", f"BUILD:{project}/local-build"])
local.write_text(f'setenv MALU_SIMULATOR verilator\nsetenv MALU_EDA_BIN "{binpath}"\nsetenv EDA_VERSION WRONG_VERSION\n')
check("wrong version fails and caller survives", source+version_result+'; echo CALLER_ALIVE', ["RESULT:1:1:mismatch", "CALLER_ALIVE"])
local.write_text('setenv MALU_SIMULATOR xrun\n')
check("missing selected commercial tool; no fabricated version", source+version_result+'; echo CALLER_ALIVE', ["RESULT:1:1:missing", "CALLER_ALIVE"])
check("invalid project fails and caller survives", f'source "{project}/setup.csh" /tmp/not-a-malu-project'+result+'; echo CALLER_ALIVE', ["RESULT:1:1", "CALLER_ALIVE"])
local.unlink()
check("root cwd default source", f'cd "{project}"; source ./setup.csh'+result, ["RESULT:0:0"])
report = {"tcsh_version": subprocess.run([tcsh, "--version"],text=True,capture_output=True).stdout.splitlines()[0], "real_eda_used": False, "mock_version_is_test_fixture_only": True, "results": results}
(stage / "build").mkdir(exist_ok=True)
(stage / "build" / "setup_test_results.json").write_text(json.dumps(report, ensure_ascii=False, indent=2)+"\n")
print(f"PASS: {len(results)} tcsh checks; fixture version is not an installed EDA version")
