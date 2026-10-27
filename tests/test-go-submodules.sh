#!/usr/bin/bash
# SPDX-FileCopyrightText: (C) 2026 Institute of Software, Chinese Academy of Sciences (ISCAS)
# SPDX-FileCopyrightText: (C) 2026 openRuyi Project Contributors
#
# SPDX-License-Identifier: MIT

set -euo pipefail

repository=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
system_rpmconfig=$(rpm --eval '%{_rpmconfigdir}')
system_fileattrs=$(rpm --eval '%{_fileattrsdir}')
[[ -d $system_rpmconfig ]]
[[ -d $system_fileattrs ]]
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail() {
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

write_source() {
    local path=$1
    local package=$2
    mkdir -p "$(dirname -- "$path")"
    printf 'package %s\n' "$package" >"$path"
}

# Nested go.mod files must not hide installed packages from GOPATH discovery.
# child/leaf exercise inherited versions; submarine detects raw-prefix matching.
# A nested module intentionally has no package at its root: its child package
# must inherit the module version without creating a root capability.
# Commands, examples and test-only directories are negative marker controls.
fixture="$work/fixture"
mkdir -p "$fixture"
printf 'module example.test/project\n\ngo 1.18\n' >"$fixture/go.mod"
write_source "$fixture/root.go" project
write_source "$fixture/plain/plain.go" plain
mkdir -p "$fixture/sub/nested"
printf 'module example.test/project/sub\n\ngo 1.18\n' >"$fixture/sub/go.mod"
write_source "$fixture/sub/sub.go" sub
write_source "$fixture/sub/child/child.go" child
printf 'module example.test/project/sub/nested\n\ngo 1.18\n' >"$fixture/sub/nested/go.mod"
write_source "$fixture/sub/nested/leaf/leaf.go" leaf
write_source "$fixture/submarine/submarine.go" submarine
mkdir -p "$fixture/cmd/tool" "$fixture/onlytest"
printf 'package main\n\nfunc main() {}\n' >"$fixture/cmd/tool/main.go"
write_source "$fixture/examples/demo/demo.go" demo
write_source "$fixture/onlytest/only_test.go" onlytest

case_dir=
spec=
declare -a rpm_args

prepare_case() {
    local name=$1
    local table=$2
    local define_table=${3:-0}
    local entry entry_name macrofiles

    # Retain the host RPM platform and non-Go file attributes: an empty RPM
    # configuration can fail for unrelated missing helpers, hiding regressions.
    # Each case gets fresh paths so an earlier build cannot supply its markers.
    case_dir="$work/$name"
    mkdir -p "$case_dir"/{home,tmp,gocache,modcache,rpmconfig/macros.d,rpmconfig/fileattrs}
    for entry in "$system_rpmconfig"/*; do
        entry_name=${entry##*/}
        case $entry_name in
            go-rpm-integration|macros.d|fileattrs) continue ;;
        esac
        ln -s "$entry" "$case_dir/rpmconfig/$entry_name"
    done
    for entry in "$system_fileattrs"/*.attr; do
        [[ -e $entry ]] || continue
        entry_name=${entry##*/}
        [[ $entry_name == go.attr ]] && continue
        ln -s "$entry" "$case_dir/rpmconfig/fileattrs/$entry_name"
    done
    # Exercise the source-tree implementation without loading host Go macros.
    # This does not replace integration testing of an installed macro RPM.
    install -m 0755 "$repository/go-rpm-integration" "$case_dir/rpmconfig/go-rpm-integration"
    install -m 0644 "$repository/go.attr" "$case_dir/rpmconfig/fileattrs/go.attr"
    install -m 0644 "$repository"/macros.* "$case_dir/rpmconfig/macros.d/"
    mkdir -p "$case_dir/rpmbuild"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}
    spec="$case_dir/test.spec"

    {
        if [[ -n $table || $define_table -eq 1 ]]; then
            printf '%%global go_submodules %%{expand:\n%s\n}\n\n' "$table"
        fi
        cat <<'SPEC'
%global go_import_path example.test/project

Name:           go-submodules-functional-test
Version:        1.2.3
Release:        1
Summary:        Functional test fixture
License:        MIT
BuildArch:      noarch

%description
Functional test fixture.

%install
cd "%{fixture_root}"
%buildsystem_golangmodules_install

%files
%{go_sys_gopath}/%{go_import_path}
SPEC
    } >"$spec"

    # RPM 6 reloads configuration when BuildArch requests a noarch reparse.
    # --load is transient; use a persistent macro path containing only the
    # base RPM configuration and our staged macros/attributes, never host Go macros.
    macrofiles="$case_dir/rpmconfig/macros:$case_dir/rpmconfig/platform/%{_target}/macros"
    macrofiles+=":$case_dir/rpmconfig/macros.d/macros.*:$case_dir/rpmconfig/fileattrs/*.attr"
    rpm_args=(
        --macros "$macrofiles"
        --define "_fileattrsdir $case_dir/rpmconfig/fileattrs"
        --define "_rpmconfigdir $case_dir/rpmconfig"
        --define "_topdir $case_dir/rpmbuild"
        --define "fixture_root $fixture"
        --define "__spec_install_post %{nil}"
    )
}

run_build() {
    # The fixture is self-contained: user Go settings, cached modules and network
    # access must not make a broken case pass or download a different toolchain.
    # RPM 6 replaces a buildroot macro definition; --buildroot is the override.
    env -i \
        PATH=/usr/bin:/bin \
        HOME="$case_dir/home" \
        TMPDIR="$case_dir/tmp" \
        LC_ALL=C \
        TZ=UTC \
        GOENV=off \
        GOTOOLCHAIN=local \
        GOPROXY=off \
        GOSUMDB=off \
        GOCACHE="$case_dir/gocache" \
        GOMODCACHE="$case_dir/modcache" \
        rpmbuild -bb --nodeps --noclean --buildroot "$case_dir/buildroot" "${rpm_args[@]}" "$spec" \
        >"$case_dir/rpmbuild.stdout" 2>"$case_dir/rpmbuild.stderr"
}

# Check each boundary independently: installed marker set/bytes, helper output,
# and final RPM Provides. A working helper alone cannot prove go.attr was loaded
# or that the marker files actually reached the package payload.
assert_outputs() {
    local root="$case_dir/buildroot/usr/share/gocode/src/example.test/project"

    find "$root" -type f -name .goipath -printf '%P\n' | LC_ALL=C sort >"$case_dir/markers.actual"
    cat >"$case_dir/markers.expected" <<'EOF'
.goipath
plain/.goipath
sub/.goipath
sub/child/.goipath
sub/nested/leaf/.goipath
submarine/.goipath
EOF
    cmp "$case_dir/markers.expected" "$case_dir/markers.actual" || fail "unexpected marker set"

    while read -r marker version; do
        printf 'version:%s\n' "$version" >"$case_dir/marker.expected"
        cmp "$case_dir/marker.expected" "$root/$marker" || fail "wrong version in $marker"
    done <<'EOF'
.goipath 1.2.3
plain/.goipath 1.2.3
sub/.goipath 2.3.4
sub/child/.goipath 2.3.4
sub/nested/leaf/.goipath 3.4.5
submarine/.goipath 1.2.3
EOF

    find "$root" -type f -name .goipath -print | LC_ALL=C sort |
        "$repository/go-rpm-integration" \
            provides \
            --prefix "$case_dir/buildroot" \
            --go-path /usr/share/gocode \
            >"$case_dir/provides.actual" 2>"$case_dir/integration.stderr"
    [[ ! -s $case_dir/integration.stderr ]] || fail "integration helper wrote diagnostics"
    cat >"$case_dir/provides.expected" <<'EOF'
go(example.test/project) = 1.2.3
go(example.test/project/plain) = 1.2.3
go(example.test/project/sub) = 2.3.4
go(example.test/project/sub/child) = 2.3.4
go(example.test/project/sub/nested/leaf) = 3.4.5
go(example.test/project/submarine) = 1.2.3
EOF
    cmp "$case_dir/provides.expected" "$case_dir/provides.actual" || fail "unexpected generated Provides"

    rpm_file=$(find "$case_dir/rpmbuild/RPMS" -type f -name '*.rpm' -print -quit)
    [[ -n $rpm_file ]] || fail "rpmbuild did not create an RPM"
    rpm -qp --provides "$rpm_file" | grep '^go(' | LC_ALL=C sort >"$case_dir/rpm-provides.actual"
    cmp "$case_dir/provides.expected" "$case_dir/rpm-provides.actual" || fail "RPM file attributes generated unexpected Provides"

    grep -Fxq \
        'go-provides: packages=7 markers=6 skipped-main=1 skipped-no-source=1 skipped-examples=1 errors=0' \
        "$case_dir/rpmbuild.stderr" || fail "missing package summary"
}

run_success_case() {
    local name=$1
    local table=$2

    prepare_case "$name" "$table"
    rpmspec -P "${rpm_args[@]}" "$spec" >"$case_dir/expanded.spec"
    ! grep -Fq '%go_generate_provides' "$case_dir/expanded.spec" || fail "unexpanded generator macro"
    ! grep -Fq '%buildsystem_golangmodules_install' "$case_dir/expanded.spec" || fail "unexpanded build-system macro"
    run_build || {
        cat "$case_dir/rpmbuild.stderr" >&2
        fail "$name should succeed"
    }
    ! grep -Fq "Couldn't exec" "$case_dir/rpmbuild.stderr" || fail "$name used an incomplete RPM configuration"
}

run_failure_case() {
    local name=$1
    local table=$2
    local diagnostic=$3
    local define_table=${4:-0}

    prepare_case "$name" "$table" "$define_table"
    if run_build; then
        fail "$name should fail"
    fi
    # A nonzero exit alone could be an unrelated build-environment failure.
    # Require the intended rejection and no markers from a partly accepted table.
    grep -Fq "$diagnostic" "$case_dir/rpmbuild.stderr" || {
        cat "$case_dir/rpmbuild.stderr" >&2
        fail "$name emitted the wrong diagnostic"
    }
    if find "$case_dir/buildroot" -type f -name .goipath -print -quit 2>/dev/null | grep -q .; then
        fail "$name left partial markers"
    fi
}

# Both row orders must produce identical markers and capabilities; otherwise
# selection could accidentally depend on the first or last matching row.
primary_table=$'example.test/project/sub/nested 3.4.5\nexample.test/project/sub 2.3.4'
run_success_case primary "$primary_table"
assert_outputs

reverse_table=$'example.test/project/sub 2.3.4\nexample.test/project/sub/nested 3.4.5'
run_success_case reverse "$reverse_table"
assert_outputs

# Ignored comments still cross the RPM-to-shell boundary. Neither the apostrophe
# nor the command substitution may escape the quoted table assignment.
safe_sentinel="$work/comment-command-ran"
safe_table="# project's \$(touch $safe_sentinel)"$'\n\n  example.test/project/sub\t2.3.4  \n\texample.test/project/sub/nested  3.4.5'
run_success_case whitespace-and-comment "$safe_table"
assert_outputs
[[ ! -e $safe_sentinel ]] || fail "table comment executed shell syntax"

run_failure_case missing-version \
    'example.test/project/sub' \
    'go-provides: invalid go_submodules entry:'
run_failure_case extra-field \
    'example.test/project/sub 2.3.4 extra' \
    'go-provides: invalid go_submodules entry:'
run_failure_case duplicate \
    $'example.test/project/sub 2.3.4\nexample.test/project/sub 2.3.4' \
    'go-provides: duplicate go_submodules entry: example.test/project/sub'
run_failure_case conflicting-duplicate \
    $'example.test/project/sub 2.3.4\nexample.test/project/sub 9.9.9' \
    'go-provides: duplicate go_submodules entry: example.test/project/sub'
run_failure_case trailing-slash \
    'example.test/project/sub/ 2.3.4' \
    'go-provides: invalid go_submodules path: example.test/project/sub/'
run_failure_case unresolved-path \
    'example.test/project/%{undefined_submodule_path} 2.3.4' \
    'go-provides: invalid go_submodules path: example.test/project/%{undefined_submodule_path}'
run_failure_case wildcard-path \
    'example.test/project/sub* 2.3.4' \
    'go-provides: invalid go_submodules path: example.test/project/sub*'
run_failure_case unresolved-version \
    'example.test/project/sub %{undefined_submodule_version}' \
    'go-provides: invalid go_submodules version: %{undefined_submodule_version}'
run_failure_case invalid-version \
    'example.test/project/sub 2.3.4-5' \
    'go-provides: invalid go_submodules version: 2.3.4-5'

# A defined table is an explicit version contract. A parent row must not hide
# an independently versioned nested module, and an empty contract is not a
# request to use the parent fallback.
run_failure_case unmapped-nested \
    'example.test/project/sub 2.3.4' \
    'go-provides: unmapped nested module: example.test/project/sub/nested'
run_failure_case unmapped-parent \
    'example.test/project/sub/nested 3.4.5' \
    'go-provides: unmapped nested module: example.test/project/sub'
run_failure_case empty-defined-table \
    '' \
    'go-provides: unmapped nested module: example.test/project/sub' \
    1

# An undefined table retains the legacy top-level fallback for compatibility.
# This is intentionally distinct from the defined-but-empty contract above.
prepare_case no-table ''
run_build || {
    cat "$case_dir/rpmbuild.stderr" >&2
    fail "empty table should preserve the top-level version"
}
root="$case_dir/buildroot/usr/share/gocode/src/example.test/project"
mapfile -t no_table_markers < <(find "$root" -type f -name .goipath -print | LC_ALL=C sort)
[[ ${#no_table_markers[@]} -eq 6 ]] || fail "empty table generated the wrong marker count"
for marker in "${no_table_markers[@]}"; do
    printf 'version:1.2.3\n' >"$case_dir/marker.expected"
    cmp "$case_dir/marker.expected" "$marker" || fail "empty table changed a marker version"
done

printf 'All go_submodules tests passed.\n'
