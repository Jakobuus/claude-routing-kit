"""kit-board entry point: the store plus every module that adds subcommands."""
import sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
import board
import board_claims  # noqa: F401  (registers claims, tidy)
import board_dm  # noqa: F401  (registers who, send, sent)

if __name__ == '__main__':
    raise SystemExit(board.main())
