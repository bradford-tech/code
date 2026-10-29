#!/usr/bin/env bash
# Asserts the packaged Node.js compile cache is only generated for builds that
# use Microsoft's Electron (product.electronArtifactFeed set). Stock Electron
# appends `-<uid>` to the cache's version tag, which upstream's validator
# rejects, and ignores the `readOnly` option, so a shipped cache would be
# written into the signed app bundle at runtime. See docs/build-fix.md.
#
# Runs against vscode/build/lib/nodeCompileCache.ts at vscode/'s HEAD with
# patches/00-build-disable-node-compile-cache.patch applied in a temp dir.
#
# Usage: ./dev/test-node-compile-cache-gate.sh

set -eo pipefail

cd "$( dirname "${BASH_SOURCE[0]}" )/.." || exit 1

PATCH="patches/00-build-disable-node-compile-cache.patch"
TMP="$( mktemp -d )"
trap 'rm -rf "${TMP}"' EXIT

mkdir -p "${TMP}/build/lib"
git -C vscode show HEAD:build/lib/nodeCompileCache.ts > "${TMP}/build/lib/nodeCompileCache.ts"
if [[ -f "${PATCH}" ]]; then
  ( cd "${TMP}" && git apply --ignore-whitespace "${OLDPWD}/${PATCH}" )
else
  echo "note - ${PATCH} not found; testing pristine upstream"
fi

node --experimental-strip-types --no-warnings --input-type=module -e "
import { shouldGenerateNodeCompileCache } from '${TMP}/build/lib/nodeCompileCache.ts';
const base = { applicationName: 'code', nameLong: 'BradfordCode', nameShort: 'BradfordCode', quality: 'stable' };
const cases = [
  ['stock Electron (empty feed) skips generation', { ...base, electronArtifactFeed: '' }, false],
  ['stock Electron (no feed) skips generation', base, false],
  ['Microsoft Electron feed still generates', { ...base, electronArtifactFeed: 'feed' }, true],
  ['OSS build (no quality) skips generation', { ...base, quality: undefined, electronArtifactFeed: 'feed' }, false],
];
let failures = 0;
for (const [what, product, expected] of cases) {
  const actual = shouldGenerateNodeCompileCache('darwin', 'arm64', product);
  if (actual === expected) {
    console.log('ok   - ' + what);
  } else {
    console.log('FAIL - ' + what + ' (expected ' + expected + ', got ' + actual + ')');
    failures++;
  }
}
process.exit(failures ? 1 : 0);
"
