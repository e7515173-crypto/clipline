#!/bin/bash
# Run every regression entry point and retain complete per-check diagnostics.
set -uo pipefail
cd "$(dirname "$0")/.."
python3 - <<'PY'
import datetime
import json
import os
from pathlib import Path
import subprocess
import time

root = Path.cwd()
stamp = datetime.datetime.now().strftime('%Y%m%d-%H%M%S')
output = root / 'build' / 'test-results' / stamp
output.mkdir(parents=True, exist_ok=True)
checks = sorted(path for path in (root / 'scripts').glob('test-*.sh') if path.name != 'test-all.sh')
results = []
for index, path in enumerate(checks, 1):
    start = time.monotonic()
    logfile = output / (path.stem + '.log')
    with logfile.open('w') as log:
        try:
            run = subprocess.run(['bash', str(path)], cwd=root, stdout=log, stderr=subprocess.STDOUT, timeout=240)
            code = run.returncode
        except subprocess.TimeoutExpired:
            code = 124
    elapsed = round(time.monotonic() - start, 2)
    item = dict(name=path.name, exit_code=code, seconds=elapsed, log=str(logfile))
    results.append(item)
    print(f'[{index}/{len(checks)}] {"PASS" if code == 0 else "FAIL"} {path.name} ({elapsed}s)', flush=True)
    if code != 0:
        print(logfile.read_text(errors='replace')[-3500:], flush=True)
report = dict(total=len(results), passed=sum(item['exit_code'] == 0 for item in results), results=results)
(output / 'summary.json').write_text(json.dumps(report, ensure_ascii=False, indent=2))
(root / 'build' / 'test-results' / 'latest.txt').write_text(str(output) + '\n')
print(f'RESULT: {report["passed"]}/{report["total"]} passed; logs: {output}', flush=True)
raise SystemExit(0 if report['passed'] == report['total'] else 1)
PY
