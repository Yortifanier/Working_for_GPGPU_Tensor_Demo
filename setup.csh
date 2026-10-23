#!/bin/tcsh
# Source from the project root, or pass its absolute path as the first argument.
# $_ is only a hint: tcsh does not reliably expose the current sourced filename.
set _malu_source_hint = ( $_ )
setenv MALU_SETUP_STATUS 0
set _malu_root = ""
if ($#argv >= 1) then
    set _malu_root = "$argv[1]"
else if ($#_malu_source_hint >= 2) then
    if ("$_malu_source_hint[1]" == "source") then
        set _malu_hint = "$_malu_source_hint[2]"
        if (-f "$_malu_hint") set _malu_root = "$_malu_hint:h"
    endif
endif
if ("$_malu_root" == "") then
    if (-f "$cwd/setup.csh") then
        set _malu_root = "$cwd"
    else if ($?PROJECT_ROOT) then
        if (-f "$PROJECT_ROOT/setup.csh") set _malu_root = "$PROJECT_ROOT"
    endif
endif
if ("$_malu_root" == "") then
    echo "MALU: cannot locate project. Use: source /abs/project/setup.csh /abs/project"
    setenv MALU_SETUP_STATUS 1
    goto malu_setup_end
endif
if (! -f "$_malu_root/setup.csh") then
    echo "MALU: project root must contain setup.csh."
    setenv MALU_SETUP_STATUS 1
    goto malu_setup_end
endif
set _malu_saved_cwd = "$cwd"
cd "$_malu_root"
if ($status != 0) then
    echo "MALU: cannot enter project directory."
    setenv MALU_SETUP_STATUS 1
    goto malu_setup_end
endif
setenv PROJECT_ROOT "$cwd"
cd "$_malu_saved_cwd"
if (-f "$PROJECT_ROOT/setup.local.csh") source "$PROJECT_ROOT/setup.local.csh"
if (! $?MALU_BUILD_DIR) setenv MALU_BUILD_DIR "$PROJECT_ROOT/build"
if ("$MALU_BUILD_DIR" !~ /*) setenv MALU_BUILD_DIR "$PROJECT_ROOT/$MALU_BUILD_DIR"
if (! $?MALU_SIMULATOR) setenv MALU_SIMULATOR none
if (! $?EDA_VERSION) setenv EDA_VERSION ""
mkdir -p "$MALU_BUILD_DIR"
if ($status != 0) then
    echo "MALU: cannot create build directory."
    setenv MALU_SETUP_STATUS 1
    goto malu_setup_end
endif

# Remove only a directory previously inserted by this script, then reapply it.
if ($?MALU_SETUP_PATH_ADDED) then
    set _malu_new_path = ()
    foreach _malu_item ($path:q)
        if ("$_malu_item" != "$MALU_SETUP_PATH_ADDED") set _malu_new_path = ( $_malu_new_path:q "$_malu_item" )
    end
    set path = ( $_malu_new_path:q )
    unsetenv MALU_SETUP_PATH_ADDED
endif
if ($?MALU_EDA_BIN) then
    if ("$MALU_EDA_BIN" != "") then
        if ("$MALU_EDA_BIN" !~ /*) setenv MALU_EDA_BIN "$PROJECT_ROOT/$MALU_EDA_BIN"
        if (! -d "$MALU_EDA_BIN") then
            echo "MALU: configured MALU_EDA_BIN directory does not exist."
            setenv MALU_SETUP_STATUS 1
            goto malu_setup_end
        endif
        set _malu_seen = 0
        foreach _malu_item ($path:q)
            if ("$_malu_item" == "$MALU_EDA_BIN") set _malu_seen = 1
        end
        if (! $_malu_seen) then
            set path = ( "$MALU_EDA_BIN" $path:q )
            setenv MALU_SETUP_PATH_ADDED "$MALU_EDA_BIN"
        endif
    endif
endif
rehash

setenv MALU_EDA_VERSION_STATUS unchecked
setenv MALU_EDA_VERSION_DETECTED "not detected"
set _malu_probe = ()
switch ("$MALU_SIMULATOR")
case none:
    echo "MALU: no simulator selected; environment initialized only."
    breaksw
case verilator:
    set _malu_probe = ( verilator --version )
    breaksw
case iverilog:
    set _malu_probe = ( iverilog -V )
    breaksw
case vcs:
    set _malu_probe = ( vcs -ID )
    breaksw
case xrun:
    set _malu_probe = ( xrun -version )
    breaksw
case questa:
    set _malu_probe = ( vsim -version )
    breaksw
default:
    echo "MALU: unsupported MALU_SIMULATOR; use none/verilator/iverilog/vcs/xrun/questa."
    setenv MALU_SETUP_STATUS 1
endsw
if ($#_malu_probe > 0) then
    which "$_malu_probe[1]" >& /dev/null
    if ($status != 0) then
        setenv MALU_EDA_VERSION_STATUS missing
        setenv MALU_SETUP_STATUS 1
        echo "MALU: selected simulator is not installed; version not detected."
    else
        set _malu_tmp = "`mktemp /tmp/malu-eda-version.XXXXXX`"
        if ($status != 0) then
            setenv MALU_SETUP_STATUS 1
            goto malu_setup_end
        endif
        $_malu_probe:q >&! "$_malu_tmp"
        set _malu_rc = $status
        if ($_malu_rc == 0) then
            set _malu_line = "`head -n 1 $_malu_tmp:q`"
            if ("$_malu_line" != "") then
                setenv MALU_EDA_VERSION_STATUS detected
                setenv MALU_EDA_VERSION_DETECTED "$_malu_line"
                echo "MALU: detected $MALU_EDA_VERSION_DETECTED"
                if ("$EDA_VERSION" != "") then
                    printf '%s\n' "$_malu_line" | grep -F -- "$EDA_VERSION" >& /dev/null
                    if ($status != 0) then
                        setenv MALU_EDA_VERSION_STATUS mismatch
                        setenv MALU_SETUP_STATUS 1
                        echo "MALU: detected version does not match requested EDA_VERSION."
                    endif
                endif
            else
                setenv MALU_SETUP_STATUS 1
                echo "MALU: version probe produced no version; not detected."
            endif
        else
            setenv MALU_SETUP_STATUS 1
            echo "MALU: version probe failed; version not detected."
        endif
        rm -f "$_malu_tmp"
    endif
endif
# Presence only: never display, persist or alter license values.
if ($?LM_LICENSE_FILE) echo "MALU: LM_LICENSE_FILE is present (value hidden)."
if ($?SNPSLMD_LICENSE_FILE) echo "MALU: SNPSLMD_LICENSE_FILE is present (value hidden)."
if ($?CDS_LIC_FILE) echo "MALU: CDS_LIC_FILE is present (value hidden)."
if ($?MGLS_LICENSE_FILE) echo "MALU: MGLS_LICENSE_FILE is present (value hidden)."
echo "MALU: directory/document scaffold only; no RTL build or simulation was run."

malu_setup_end:
unset _malu_*
# Preserve the caller's shell; return a useful source status without 'exit'.
/bin/sh -c "exit $MALU_SETUP_STATUS"
