"""Test stand-in for hooks/checks/messages.py: runs the real board_dm.check, but names the session
from KIT_BOARD_NAME so a test can use short names (A, B, LEAD). The real hook ignores that variable;
the tests that prove it run hooks/checks/messages.py itself."""
import json
import os
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[3] / 'plugins/routing-kit/lib'))
import board
import board_dm

if __name__ == '__main__':
    name = os.environ.get('KIT_BOARD_NAME')
    if name:
        board.identity = lambda: (name, os.environ.get('KIT_BOARD_FAMILY', 'claude'))
    board_dm.check(json.load(sys.stdin))
