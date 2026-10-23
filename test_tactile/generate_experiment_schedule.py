#!/usr/bin/env python
from pathlib import Path
import sys
SCRIPT_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(SCRIPT_DIR.parent / 'scripts'))
from schedule_core import main
if __name__ == '__main__':
    main('tactile', SCRIPT_DIR, dataset='test')
