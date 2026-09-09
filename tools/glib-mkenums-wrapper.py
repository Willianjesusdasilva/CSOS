from pathlib import Path
import sys

template = Path(__file__).resolve().parents[1] / ".tools" / "glib-src" / "gobject" / "glib-mkenums.in"
source = template.read_text(encoding="utf-8")
source = source.replace("#!@PYTHON@\n", "", 1).replace("@VERSION@", "2.82.0")
namespace = {"__name__": "__main__", "__file__": str(template)}
exec(compile(source, str(template), "exec"), namespace)
