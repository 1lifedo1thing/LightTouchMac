#!/usr/bin/env python3
"""The catalog, network, ready-queue and Store-table checks this ran are Swift Testing now (CatalogCopyTests,
CatalogClientTests, InstallationQueueTests, AppsInspectorRowsTests). With --ui it still runs check-files-ui.py, as it
always did; tests/run.py names this file directly, so it stays until run.py stops listing it."""
from pathlib import Path
import subprocess, sys
root = Path(__file__).resolve().parents[2]
if '--ui' in sys.argv or '--ui-only' in sys.argv:
    subprocess.run([sys.executable, str(root / 'tests/offline/check-files-ui.py')], cwd=root, check=True)
