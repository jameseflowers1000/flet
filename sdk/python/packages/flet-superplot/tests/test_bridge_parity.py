"""
Bridge parity test — ensures Python BRIDGE_SOURCE and Dart _bridgeSource stay in sync.

Fast (< 1 second), no container needed. Catches bridge drift before it reaches the app.

Tests:
1. Both sources parse as valid Python AST
2. Identical method signatures (names, params, defaults)
3. All 15 gallery plot_code strings produce valid output via evaluate_plot_code()
"""

import ast
import json
import re
from pathlib import Path

import pytest

# Paths
SUPERPLOT_PKG = Path(__file__).parent.parent
BRIDGE_PY = SUPERPLOT_PKG / "src" / "flet_superplot" / "bridge.py"
DART_FILE = (
    SUPERPLOT_PKG / "src" / "flutter" / "flet_superplot" / "lib" / "src"
    / "superplot_control.dart"
)
GALLERY_JSON = SUPERPLOT_PKG.parent.parent.parent.parent.parent.parent / "docs" / "gallery" / ".meta" / "document.json"


def _extract_python_bridge_source():
    """Extract BRIDGE_SOURCE string from bridge.py."""
    import importlib.util
    spec = importlib.util.spec_from_file_location("bridge", BRIDGE_PY)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.BRIDGE_SOURCE


def _extract_dart_bridge_source():
    """Extract _bridgeSource Python code from superplot_control.dart."""
    dart_content = DART_FILE.read_text()
    # Find: const String _bridgeSource = '''...''';
    match = re.search(
        r"const\s+String\s+_bridgeSource\s*=\s*'''(.*?)'''",
        dart_content,
        re.DOTALL,
    )
    assert match, f"Could not find _bridgeSource in {DART_FILE}"
    return match.group(1)


def _extract_methods(source: str) -> dict:
    """Parse Python source and extract method signatures from ChartBridge class.

    Returns:
        {method_name: {"params": [name, ...], "defaults": {name: repr(value), ...}}}
    """
    tree = ast.parse(source)
    methods = {}
    for node in ast.walk(tree):
        if isinstance(node, ast.ClassDef) and node.name == "ChartBridge":
            for item in node.body:
                if isinstance(item, ast.FunctionDef):
                    name = item.name
                    args = item.args

                    # Parameter names (skip 'self')
                    param_names = [a.arg for a in args.args[1:]]

                    # Defaults — ast puts them right-aligned to params
                    defaults = {}
                    num_defaults = len(args.defaults)
                    if num_defaults:
                        default_params = param_names[-num_defaults:]
                        for pname, dval in zip(default_params, args.defaults):
                            defaults[pname] = ast.dump(dval)

                    methods[name] = {
                        "params": param_names,
                        "defaults": defaults,
                    }
    return methods


def _extract_method_bodies(source: str) -> dict:
    """Extract normalized method body text for each ChartBridge method.

    Compares the actual code inside each method, not just the signature.
    Returns {method_name: normalized_body_text}.
    """
    tree = ast.parse(source)
    bodies = {}
    for node in ast.walk(tree):
        if isinstance(node, ast.ClassDef) and node.name == "ChartBridge":
            for item in node.body:
                if isinstance(item, ast.FunctionDef):
                    bodies[item.name] = ast.dump(item)
    return bodies


def _evaluate_plot_code_standalone(plot_code: str) -> str:
    """Evaluate plot_code using BRIDGE_SOURCE directly (no flet dependency)."""
    bridge_source = _extract_python_bridge_source()
    namespace = {}
    exec(bridge_source, namespace)  # noqa: S102
    exec(plot_code, namespace)  # noqa: S102
    return json.dumps(namespace['chart']._to_config())


def _load_gallery_plot_codes() -> list:
    """Load all plot_code strings from the gallery doclet."""
    if not GALLERY_JSON.exists():
        pytest.skip(f"Gallery doclet not found: {GALLERY_JSON}")
    doc = json.loads(GALLERY_JSON.read_text())
    rows = doc["pr"]["GALtab3C4D5E"]["value"]
    return [(row["chart_type"], row["plot_code"]) for row in rows]


# ── Tests ─────────────────────────────────────────────────────────────


class TestBridgeParity:
    """Verify Python and Dart bridge sources are identical."""

    @pytest.fixture(scope="class")
    def python_source(self):
        return _extract_python_bridge_source()

    @pytest.fixture(scope="class")
    def dart_source(self):
        return _extract_dart_bridge_source()

    @pytest.fixture(scope="class")
    def python_methods(self, python_source):
        return _extract_methods(python_source)

    @pytest.fixture(scope="class")
    def dart_methods(self, dart_source):
        return _extract_methods(dart_source)

    def test_both_parse(self, python_source, dart_source):
        """Both sources parse as valid Python."""
        ast.parse(python_source)
        ast.parse(dart_source)

    def test_same_method_names(self, python_methods, dart_methods):
        """Both sources define the same methods."""
        py_names = set(python_methods.keys())
        dart_names = set(dart_methods.keys())
        assert py_names == dart_names, (
            f"Method mismatch:\n"
            f"  Python only: {py_names - dart_names}\n"
            f"  Dart only:   {dart_names - py_names}"
        )

    def test_same_signatures(self, python_methods, dart_methods):
        """Every method has identical params and defaults."""
        mismatches = []
        for name in python_methods:
            if name not in dart_methods:
                continue
            py = python_methods[name]
            dt = dart_methods[name]
            if py["params"] != dt["params"]:
                mismatches.append(
                    f"{name}: params differ\n"
                    f"  Python: {py['params']}\n"
                    f"  Dart:   {dt['params']}"
                )
            if py["defaults"] != dt["defaults"]:
                mismatches.append(
                    f"{name}: defaults differ\n"
                    f"  Python: {py['defaults']}\n"
                    f"  Dart:   {dt['defaults']}"
                )
        assert not mismatches, "Signature mismatches:\n" + "\n".join(mismatches)

    def test_method_body_parity(self, python_source, dart_source):
        """Each method's body (append dict keys) is identical between sources."""
        py_methods = _extract_method_bodies(python_source)
        dt_methods = _extract_method_bodies(dart_source)
        mismatches = []
        for name in py_methods:
            if name not in dt_methods:
                continue
            if py_methods[name] != dt_methods[name]:
                mismatches.append(
                    f"{name}:\n  Python: {py_methods[name]!r}\n  Dart:   {dt_methods[name]!r}"
                )
        assert not mismatches, "Method body mismatches:\n" + "\n".join(mismatches)


class TestPlotCodeExecution:
    """Verify all gallery plot_code strings execute correctly via evaluate_plot_code."""

    @pytest.fixture(scope="class")
    def plot_codes(self):
        return _load_gallery_plot_codes()

    @pytest.mark.parametrize(
        "chart_type,plot_code",
        _load_gallery_plot_codes(),
        ids=[ct for ct, _ in _load_gallery_plot_codes()],
    )
    def test_plot_code_produces_valid_config(self, chart_type, plot_code):
        """Each plot_code produces valid JSON with series/axes/annotations."""
        config_json = _evaluate_plot_code_standalone(plot_code)
        config = json.loads(config_json)

        assert "series" in config, f"{chart_type}: missing 'series' key"
        assert "axes" in config, f"{chart_type}: missing 'axes' key"
        assert "annotations" in config, f"{chart_type}: missing 'annotations' key"
        assert len(config["series"]) > 0, f"{chart_type}: no series defined"

        # Verify each series has a type
        for i, s in enumerate(config["series"]):
            assert "type" in s, f"{chart_type}: series[{i}] missing 'type'"
