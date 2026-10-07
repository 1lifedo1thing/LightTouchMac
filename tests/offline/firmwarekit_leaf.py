"""FirmwareKit's FirmwareSchema product: the leaf the GUI links (wire types, StorageCapacity, GuestArchive)."""
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'scripts'))
import host_runtime  # noqa: E402


def capacity_sources(root, tmp):
    return []   # StorageCapacity is in FirmwareSchema: schema_sources() links it


def schema_sources():
    return host_runtime.schema_flags(ROOT)
