#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

PYODIDE_VERSION="${PYODIDE_VERSION:-0.27.7}"
RUSTUP_TOOLCHAIN="${RUSTUP_TOOLCHAIN:-nightly-2025-08-08}"

pyodide() {
  uvx --from pyodide-cli --with pyodide-build pyodide "$@"
}

build() {
  pyodide xbuildenv install --skip-cross-build-packages "$PYODIDE_VERSION"
  pyodide xbuildenv use "$PYODIDE_VERSION"

  local pyodide_root
  local pyo3_python
  local cflags_value
  local ldflags_value
  local rustflags_value
  local xbuildenv_root
  local pyodide_env_root

  pyodide_root="$(pyodide config get pyodide_root)"
  pyo3_python="$(pyodide config get interpreter)"
  cflags_value="$(pyodide config get cflags)"
  ldflags_value="$(pyodide config get ldflags)"
  rustflags_value="$(pyodide config get rustflags)"

  xbuildenv_root="$(dirname "$pyodide_root")"
  pyodide_env_root="$(dirname "$xbuildenv_root")"
  source "$pyodide_env_root/emsdk/emsdk_env.sh" >/dev/null

  export CFLAGS="$cflags_value"
  export CXXFLAGS='-O2 -g0 -fPIC'
  export LDFLAGS="$ldflags_value"
  export PYO3_BUILD_EXTENSION_MODULE=1
  export PYO3_PYTHON="$pyo3_python"
  export PYTHON_SYS_EXECUTABLE="$pyo3_python"
  export RUSTFLAGS="$rustflags_value"

  cd "$ROOT"
  RUSTUP_TOOLCHAIN="$RUSTUP_TOOLCHAIN" \
    uvx maturin build \
      --release \
      --target wasm32-unknown-emscripten \
      -i "$pyo3_python" \
      --compatibility off \
      -o dist-pyodide
}

verify() {
  local wheel_path
  local tmpdir_path

  wheel_path="$(find "$ROOT/dist-pyodide" -maxdepth 1 -name '*.whl' -print | head -n 1)"
  if [[ -z "$wheel_path" ]]; then
    echo "No Pyodide wheel found in dist-pyodide." >&2
    exit 1
  fi

  tmpdir_path="$(mktemp -d)"
  export TMPDIR_PATH="$tmpdir_path"
  export WHEEL_PATH="$wheel_path"
  trap 'rm -rf "$TMPDIR_PATH"' EXIT

  cd "$TMPDIR_PATH"
  npm init -y >/dev/null
  npm install --silent "pyodide@${PYODIDE_VERSION}" >/dev/null

  node --input-type=module <<'EOF'
import fs from 'node:fs';
import path from 'node:path';
import { pathToFileURL } from 'node:url';

const wheel = process.env.WHEEL_PATH;
const pyodideDir = path.resolve(process.env.TMPDIR_PATH, 'node_modules/pyodide');
const pyodideModule = pathToFileURL(path.join(pyodideDir, 'pyodide.mjs')).href;
const { loadPyodide } = await import(pyodideModule);
const indexURL = `${pyodideDir}${path.sep}`;

const pyodide = await loadPyodide({ indexURL });
await pyodide.loadPackage('micropip');

const wheelName = path.basename(wheel);
const wheelPath = `/tmp/${wheelName}`;
pyodide.FS.writeFile(wheelPath, fs.readFileSync(wheel));

const resultJson = await pyodide.runPythonAsync(`
import json
import micropip

await micropip.install('emfs://${wheelPath}')
import typst

svg = typst.compile(b'= Hello from Pyodide\\nInstalled from CI.', format='svg')
assert isinstance(svg, (bytes, bytearray))
assert b'<svg' in svg

json.dumps({
    "result_type": type(svg).__name__,
    "result_len": len(svg),
})
`);

const result = JSON.parse(resultJson);
console.log(JSON.stringify({ ok: true, wheel, ...result }, null, 2));
EOF
}

case "${1:-}" in
  build)
    build
    ;;
  verify)
    verify
    ;;
  *)
    echo "usage: $0 {build|verify}" >&2
    exit 1
    ;;
esac
