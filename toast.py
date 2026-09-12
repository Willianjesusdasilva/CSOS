# toast.py

import argparse
import re
from pathlib import Path

import httpx


def build_status_summary(content: str) -> str:
    """Build a compact progress message from STATUS.md."""
    checkboxes = re.findall(r"- \[([ xX])\]", content)
    completed = sum(mark.lower() == "x" for mark in checkboxes)
    total = len(checkboxes)
    percentage = round(completed * 100 / total) if total else 0
    phase_marks = [
        mark for mark, _ in re.findall(r"- \[([ xX])\] (Fase .+)", content)
    ]
    phase_done = sum(mark.lower() == "x" for mark in phase_marks)
    phase_total = len(phase_marks)
    phase_percentage = round(phase_done * 100 / phase_total) if phase_total else 0

    phases = []
    pending = []
    for line in content.splitlines():
        match = re.match(r"- \[([ xX])\] (Fase .+)", line)
        if not match:
            continue
        marker, phase = match.groups()
        state = "concluida" if marker.lower() == "x" else "pendente"
        phases.append(f"- {phase}: {state}")
        if state == "pendente":
            pending.append(phase)

    current = next(
        (line.strip(" -*") for line in content.splitlines()
         if "**Fase " in line and "Status" not in line),
        "Fase em andamento",
    )
    tests = re.search(r"\*\*Testes\*\*: ([^\n]+)", content)
    test_text = tests.group(1).strip() if tests else "nao informado"

    return "\n".join([
        "Resumo da migracao MuEmu 0.97k",
        f"Fases concluidas: {phase_percentage}% ({phase_done}/{phase_total})",
        f"Tarefas marcadas: {percentage}% ({completed}/{total})",
        f"Ainda falta: {100 - phase_percentage}% das fases",
        f"{current}",
        f"Testes: {test_text}",
        "Fases:",
        *phases,
        "Proximas pendencias:",
        *(f"- {item}" for item in pending[:4]),
    ])


def main():
    parser = argparse.ArgumentParser()

    parser.add_argument("file", nargs="?")
    parser.add_argument("--title")
    parser.add_argument(
        "--message",
        help="send this message directly instead of reading a file",
    )
    parser.add_argument("--preview", action="store_true")
    parser.add_argument(
        "--summary",
        action="store_true",
        help="send a compact phase and percentage summary",
    )
    parser.add_argument(
        "--topic",
        default="willian-toast-7f29d1"
    )

    args = parser.parse_args()

    path = Path(args.file) if args.file else None

    if args.message is not None:
        content = args.message
    else:
        if path is None or not path.exists():
            raise SystemExit(f"Arquivo não encontrado: {path}")
        content = path.read_text(encoding="utf-8")

    title = args.title or (path.stem if path else "CSOS")
    title = title.encode("ascii", errors="ignore").decode("ascii")

    if args.summary:
        if path is None:
            raise SystemExit("--summary requer um arquivo")
        content = build_status_summary(content)
    elif args.preview:
        original_content = content
        content = content[:800]

        if len(original_content) > 800:
            content += "\n\n..."

    response = httpx.post(
        f"https://ntfy.sh/{args.topic}",
        content=content.encode(),
        headers={
            "Title": title,
            "Markdown": "yes",
        },
    )

    response.raise_for_status()

    print("Toast enviado")


if __name__ == "__main__":
    main()
