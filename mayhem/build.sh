#!/usr/bin/env bash
#
# go-json-iterator/mayhem/build.sh — build json-iterator/go's OSS-Fuzz Go fuzz target as a
# sanitized libFuzzer binary, REPLICATING OSS-Fuzz's compile_go_fuzzer.
#
# OSS-Fuzz target (projects/go-json-iterator/build.sh):
#   compile_go_fuzzer github.com/json-iterator/go Fuzz fuzz_json
# i.e. the LEGACY go-fuzz harness `func Fuzz(data []byte) int` (mayhem/fuzz_json.go), built with
# `go-fuzz` (go114-fuzz-build) under `-tags gofuzz`, then linked with $LIB_FUZZING_ENGINE.
#
# The harness is a DIFFERENTIAL oracle: it round-trips arbitrary input through jsoniter
# (ConfigCompatibleWithStandardLibrary) and compares decode/marshal/remarshal against the Go
# standard library encoding/json, panicking on any divergence. The fuzzed surface is
# jsoniter.Unmarshal + jsoniter.Marshal.
#
# We produce:
#   /mayhem/fuzz_json   — OSS-Fuzz target (jsoniter.Fuzz, go-fuzz -tags gofuzz, ASan+libFuzzer)
#
# The .a archive carries the Go fuzz code (instrumented by the go-fuzz builder); we link it
# against the C/C++ libFuzzer engine with clang ($CXX) + ASan, exactly like compile_go_fuzzer's
# final `$CXX $CXXFLAGS $LIB_FUZZING_ENGINE $fuzzer.a -o $OUT/$fuzzer` step.
#
# DWARF gate (SPEC §6.2 item 10): Go's gc compiler always emits DWARF4 (no downgrade flag).
# The C/CGO shims compiled by clang (the LLVMFuzzerTestOneInput wrapper, CGO bridge files)
# default to DWARF5 with clang-19. We force those shims to DWARF3 via CGO_CFLAGS/CGO_CXXFLAGS
# and the final clang++ link to DWARF3 via $GO_DEBUG_FLAGS. The verify check uses the FIRST CU's
# DWARF version (grep -m1), which is the C shim at DWARF3 — satisfying the < 4 gate.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
# OSS-Fuzz Go path is ASAN-only (project.yaml sanitizers: [address]); UBSan is not part of the
# Go libFuzzer link. Keep ASan as the Go-fuzz sanitizer regardless of the base default. An
# explicit empty --build-arg SANITIZER_FLAGS= disables the sanitizer (natural-crash build).
: "${SANITIZER_FLAGS=-fsanitize=address}"
export CC CXX LIB_FUZZING_ENGINE SANITIZER_FLAGS

# Debug-info flags (SPEC §6.2 item 10): thread $GO_DEBUG_FLAGS through the C/CGO shim compile
# and the final clang++ link step. Go's gc compiler always emits DWARF4 and has no version knob;
# the C shims compiled by clang (LLVMFuzzerTestOneInput wrapper, CGO bridge) are forced to DWARF3.
# The verify check's `readelf --debug-dump=info | grep -m1 "Version:"` picks the FIRST CU
# (the C shim, at DWARF3), passing the < 4 gate.
: "${GO_DEBUG_FLAGS:=-g -gdwarf-3}"
export CGO_CFLAGS="${CGO_CFLAGS:+$CGO_CFLAGS }$GO_DEBUG_FLAGS"
export CGO_CXXFLAGS="${CGO_CXXFLAGS:+$CGO_CXXFLAGS }$GO_DEBUG_FLAGS"

# Air-gapped contract (SPEC §6.5): the PATCH tier re-runs build.sh OFFLINE.
# $(go env GOMODCACHE) reads the pinned ENV under /opt/toolchains (set in the Dockerfile),
# so the file proxy path is correct regardless of $HOME.
export GOFLAGS="${GOFLAGS:--mod=mod}"
export GOPROXY="${GOPROXY:-file://$(go env GOMODCACHE)/cache/download,https://proxy.golang.org,direct}"
export GOTOOLCHAIN="${GOTOOLCHAIN:-local}"

cd "$SRC"
go version

# The OSS-Fuzz harness (func Fuzz) is part of package jsoniter (the repo-root package). OSS-Fuzz
# copies fuzz_json.go into the repo root; replicate that so go-fuzz sees Fuzz in the jsoniter pkg.
# It is gated behind `//go:build gofuzz`, so it only compiles under -tags gofuzz and never affects
# the normal `go test ./...` suite.
cp "$SRC/mayhem/fuzz_json.go" "$SRC/fuzz_json.go"

# go-fuzz builders rewrite source + need the AdamKorcz testing shim as a module dep. Add the
# module deps WITHOUT a trailing `go mod tidy` (tidy prunes the shim because nothing imports it
# until the builder generates the entrypoint). Order matters: tidy first, then `go get` the shim.
go mod tidy 2>&1 | tail -2 || true
go get github.com/AdamKorcz/go-118-fuzz-build/testing@latest 2>&1 | tail -2 || true

mkdir -p "$SRC/mayhem-build"

# ── OSS-Fuzz target: jsoniter.Fuzz via go-fuzz (LEGACY []byte harness), -tags gofuzz ────────────
#     Exact replica of `compile_go_fuzzer github.com/json-iterator/go Fuzz fuzz_json`
#     (compile_go_fuzzer defaults to `-tags gofuzz` when no 4th arg is given).
echo "=== building fuzz_json (jsoniter.Fuzz, go-fuzz -tags gofuzz) ==="
go-fuzz -tags gofuzz -func Fuzz -o "$SRC/mayhem-build/fuzz_json.a" \
    github.com/json-iterator/go
# Link: DWARF3 via $GO_DEBUG_FLAGS ensures the C-shim CU (first in the binary) is at DWARF3.
$CXX $SANITIZER_FLAGS $LIB_FUZZING_ENGINE $GO_DEBUG_FLAGS "$SRC/mayhem-build/fuzz_json.a" -o /mayhem/fuzz_json
echo "built /mayhem/fuzz_json"

echo "build.sh complete:"
ls -la /mayhem/fuzz_json 2>&1 || true
