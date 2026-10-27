#!/usr/bin/env python3
"""Exercise the real QML theme with isolated settings and embedded resources."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


def main():
    root = Path(__file__).resolve().parents[1]
    binary = Path(sys.argv[1]).resolve() if len(sys.argv) > 1 else root / "target/debug/loaf"
    cases = [(None, 1), ("0.78", 0.78), ("garbage", 1), ("", 1),
             ("   ", 1), ("NaN", 1), ("Infinity", 1), ("-1", 0.5), ("2", 1)]
    for value, expected in cases:
        with tempfile.TemporaryDirectory(prefix="loaf-opacity-") as directory:
            config = Path(directory) / "loaf/config.json"
            config.parent.mkdir()
            settings = {"testExpectedOpacity": str(expected)}
            if value is not None:
                settings["backgroundOpacity"] = value
            config.write_text(json.dumps(settings))
            env = os.environ.copy()
            env.update(XDG_CONFIG_HOME=directory, QT_QPA_PLATFORM="offscreen",
                       QT_FORCE_STDERR_LOGGING="1", LOAF_QML=str(root / "tests/background-opacity.qml"))
            for launch in range(2):
                result = subprocess.run([str(binary), "--new-window"], env=env,
                                        capture_output=True, text=True, timeout=15)
                output = result.stdout + result.stderr
                # The current entrypoint does not propagate Qt's exit code.
                # Require the explicit completion marker as well as process success.
                if result.returncode or "BACKGROUND_OPACITY_TEST_PASS" not in output:
                    raise AssertionError(f"opacity={value!r}, launch={launch}:\n{output}")
                saved = json.loads(config.read_text())
                assert saved["backgroundOpacity"] == "0.78", saved
                saved["testExpectedOpacity"] = "0.78"
                config.write_text(json.dumps(saved))
    print(f"Background opacity: {len(cases)} cases passed, including persistence across launches")


if __name__ == "__main__":
    main()
