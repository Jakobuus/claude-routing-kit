"""Return unread board messages as common hook context."""
import json
from pathlib import Path
import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / 'lib'))
import board_dm

if __name__ == '__main__':
    board_dm.check(json.load(sys.stdin))
