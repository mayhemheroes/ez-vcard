#!/usr/bin/env bash
#
# mayhem/build.sh — build ez-vcard (Maven) + Jazzer fuzz-vcard harness + test oracle wrapper.
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC MAYHEM_JOBS
echo "SANITIZER_FLAGS=${SANITIZER_FLAGS} (JVM fuzzing via Jazzer; applied to ELF launcher shims only)"

SRC="${SRC:-/mayhem}"
OUT="/mayhem"
JAVA_HOME="${JAVA_HOME:-/opt/toolchains/jdk17}"
MAVEN_HOME="${MAVEN_HOME:-/opt/toolchains/maven}"
MVN="${MAVEN_HOME}/bin/mvn"
JAZZER_HOME="${JAZZER_HOME:-/opt/toolchains/jazzer}"
JAZZER_DRIVER="${JAZZER_HOME}/jazzer"
JAZZER_STANDALONE="${JAZZER_HOME}/jazzer_standalone.jar"
JAZZER_API="${JAZZER_API_PATH:-/opt/toolchains/jazzer/jazzer-api.jar}"
MAVEN_REPO="${MAVEN_REPO:-/opt/toolchains/maven-repo}"
JVM_LD="${JVM_LD_LIBRARY_PATH:-/opt/toolchains/jdk17/lib/server}"

export JAVA_HOME PATH="$JAVA_HOME/bin:$MAVEN_HOME/bin:$PATH"
export MAVEN_OPTS="-Dmaven.repo.local=$MAVEN_REPO"

cd "$SRC"
mkdir -p "$MAVEN_REPO"

MVN_COMMON=(-B -Dmaven.repo.local="$MAVEN_REPO" -Dgpg.skip=true -Danimal.sniffer.skip=true)
MAVEN_OFFLINE=()
if [ -d "$MAVEN_REPO/org" ] && [ -n "$(ls -A "$MAVEN_REPO/org" 2>/dev/null || true)" ]; then
  MAVEN_OFFLINE=(-o)
fi

echo "=== mvn package (ezvcard.jar) ==="
"$MVN" "${MVN_COMMON[@]}" "${MAVEN_OFFLINE[@]}" -Dmaven.test.skip=true -Dmaven.javadoc.skip=true package \
  || "$MVN" "${MVN_COMMON[@]}" -Dmaven.test.skip=true -Dmaven.javadoc.skip=true package

jar="$(find "$SRC/target" -maxdepth 1 -name 'ez-vcard-*.jar' ! -name '*-javadoc.jar' ! -name '*-sources.jar' -print -quit)"
[ -n "$jar" ] || { echo "missing ez-vcard-*.jar under $SRC/target" >&2; exit 1; }
cp "$jar" "$OUT/ezvcard.jar"
[ -f "$OUT/ezvcard.jar" ] || { echo "missing $OUT/ezvcard.jar" >&2; exit 1; }

echo "=== copy runtime dependencies ==="
"$MVN" "${MVN_COMMON[@]}" "${MAVEN_OFFLINE[@]}" -DincludeScope=runtime -DoutputDirectory="$OUT/deps" dependency:copy-dependencies \
  || "$MVN" "${MVN_COMMON[@]}" -DincludeScope=runtime -DoutputDirectory="$OUT/deps" dependency:copy-dependencies

DEPS_CP="$(find "$OUT/deps" -name '*.jar' | paste -sd: -)"
[ -n "$DEPS_CP" ] || { echo "missing runtime dependency jars under $OUT/deps" >&2; exit 1; }

echo "=== compile VCardFuzz harness ==="
javac -cp "$OUT/ezvcard.jar:$DEPS_CP:$JAZZER_API" "$SRC/mayhem/VCardFuzz.java" -d "$OUT"

install -m 644 "$JAZZER_STANDALONE" "$OUT/jazzer_standalone.jar"

compile_launcher() {
  local out="$1" mode="$2"
  "$CC" $DEBUG_FLAGS -O1 \
    -DJAZZER_DRIVER="\"$JAZZER_DRIVER\"" \
    -DJVM_LD_LIBRARY_PATH="\"$JVM_LD\"" \
    -DFUZZ_CP="\"$OUT/ezvcard.jar:$DEPS_CP:$OUT\"" \
    -DFUZZ_TARGET="\"VCardFuzz\"" \
    -DLAUNCHER_MODE="$mode" \
    -o "$OUT/$out" mayhem/jazzer_launcher.c
  chmod +x "$OUT/$out"
}

compile_launcher fuzz-vcard 0
compile_launcher fuzz-vcard-standalone 2

echo "=== compiling /mayhem/ez-vcard-tests ==="
"$CC" $DEBUG_FLAGS -O1 \
  -DMVN="\"$MVN\"" \
  -o "$OUT/ez-vcard-tests" mayhem/run_tests.c
chmod +x "$OUT/ez-vcard-tests"

echo "=== mvn test-compile (oracle inputs for test.sh) ==="
env -u SANITIZER_FLAGS -u ASAN_OPTIONS -u UBSAN_OPTIONS -u LD_PRELOAD \
  "$MVN" "${MVN_COMMON[@]}" "${MAVEN_OFFLINE[@]}" -Djacoco.skip=true test-compile \
  || env -u SANITIZER_FLAGS -u ASAN_OPTIONS -u UBSAN_OPTIONS -u LD_PRELOAD \
     "$MVN" "${MVN_COMMON[@]}" -Djacoco.skip=true test-compile

echo "build.sh complete"
