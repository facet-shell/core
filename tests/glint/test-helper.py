#!/usr/bin/env python3
"""Check migration, daemon reuse and local file listing without a desktop."""
import json
import os
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='facet-glint-helper-') as directory:
    task_root = pathlib.Path(directory)
    state = task_root / 'state'
    (state / 'facet').mkdir(parents=True)
    old = {'fps': 144, 'volume': 25, 'scaling': 'fit', 'backend': 'image',
           'screens': {'*': {'path': '/test/a b', 'kind': 'scene'}, 'DP-2': {'path': '/test/video', 'kind': 'video'}}}
    legacy = state / 'facet/wallpaper.json'
    legacy.write_text(json.dumps(old))
    original = legacy.read_bytes()
    executable = task_root / 'glint'
    executable.write_text('''#!/bin/sh
printf '%s\\n' "$*" >>"$FACET_TEST_GLINT_LOG"
if [ "$1" = outputs ]; then [ "${FACET_TEST_RUNNING:-0}" = 1 ] || [ -f "$FACET_TEST_GLINT_LOG.started" ]; exit $?; fi
[ "$1" = --daemon ] && touch "$FACET_TEST_GLINT_LOG.started"
''')
    executable.chmod(0o755)
    helper = task_root / 'start'
    helper.write_text((root / 'wallpaper/.local/bin/facet-glint-start').read_text().replace('glint="$HOME/.local/bin/glint"', 'glint="' + str(executable) + '"'))
    env = dict(os.environ, XDG_STATE_HOME=str(state), WAYLAND_DISPLAY='/tmp/wayland-9', FACET_TEST_GLINT_LOG=str(task_root / 'calls'))
    subprocess.run(['bash', str(helper)], env=env, check=True)
    new = state / 'glint/state-wayland-9.json'
    imported = json.loads(new.read_text())
    assert imported['all']['path'] == '/test/a b' and imported['all']['options']['volume'] == 0.25
    assert imported['outputs']['DP-2']['path'] == '/test/video'
    assert legacy.read_bytes() == original
    new.write_text('{"already": "configured"}')
    subprocess.run(['bash', str(helper)], env=env, check=True)
    assert json.loads(new.read_text()) == {'already': 'configured'}
    (task_root / 'calls').write_text('')
    subprocess.run(['bash', str(helper)], env=dict(env, FACET_TEST_RUNNING='1'), check=True)
    assert (task_root / 'calls').read_text().splitlines() == ['outputs --json']
    pictures = task_root / 'pictures'
    pictures.mkdir()
    (pictures / 'image.png').touch()
    (pictures / 'video.mp4').touch()
    tools = task_root / 'bin'
    tools.mkdir()
    (tools / 'ffmpeg').write_text('#!/bin/sh\nexit 1\n')
    (tools / 'ffmpeg').chmod(0o755)
    env.update(WALLPAPER_DIR=str(pictures), XDG_DATA_HOME=str(task_root / 'data'), XDG_CACHE_HOME=str(task_root / 'cache'), PATH=str(tools) + ':' + os.environ['PATH'])
    result = subprocess.run(['bash', str(root / 'wallpaper/.local/bin/facet-wallpaper'), 'list-local'], env=env, check=True, capture_output=True, text=True)
    items = json.loads(result.stdout)
    assert {item['kind'] for item in items} == {'image', 'video'}, items
    (tools / 'pkill').write_text('#!/bin/sh\nrm -f "$FACET_TEST_GLINT_LOG.started"\n')
    (tools / 'pgrep').write_text('#!/bin/sh\nexit 1\n')
    for tool in ('pkill', 'pgrep'): (tools / tool).chmod(0o755)
    assignment = {'all': {'path': '/test/a b', 'options': {'volume': 0.8, 'fps': 144}},
                  'settings': {'fps': 144, 'volume': 0.8, 'mute': True},
                  'outputs': {'DP-2': {'path': '/test/video', 'options': {'volume': 0.3, 'scaling': 'fit'}}},
                  'properties': {'/test/a b': {'clock': True}}}
    new.write_text(json.dumps(assignment))
    subprocess.run(['bash', str(helper), '--restart', '--silent'], env=env, check=True, timeout=8)
    saved = json.loads(new.read_text())
    assert saved['all']['path'] == '/test/a b' and saved['all']['options']['volume'] == 0
    assert saved['outputs']['DP-2']['path'] == '/test/video' and saved['outputs']['DP-2']['options']['volume'] == 0
    assert saved['all']['options']['fps'] == 144 and saved['properties'] == assignment['properties']
    assert saved['settings'] == {'fps': 144, 'volume': 0, 'mute': False}
    print('Glint migration, daemon reuse, silent restart and local-file listing passed')

# A detached daemon must survive its launcher and terminal hangup.
with tempfile.TemporaryDirectory(prefix='facet-glint-detached-') as directory:
    import signal
    import time
    task_root = pathlib.Path(directory)
    executable = task_root / 'glint'
    executable.write_text('''#!/usr/bin/env python3
import os, pathlib, signal, sys, time
pidfile = pathlib.Path(os.environ['FACET_TEST_PID'])
if sys.argv[1] == 'outputs':
    try: os.kill(int(pidfile.read_text()), 0)
    except (OSError, ValueError): sys.exit(1)
    sys.exit(0)
signal.signal(signal.SIGTERM, lambda *_: sys.exit(0))
pidfile.write_text(str(os.getpid()))
while True:
    pidfile.with_suffix('.tick').write_text(str(time.monotonic()))
    time.sleep(0.05)
''')
    executable.chmod(0o755)
    helper = task_root / 'start'
    helper.write_text((root / 'wallpaper/.local/bin/facet-glint-start').read_text().replace('glint="$HOME/.local/bin/glint"', 'glint="' + str(executable) + '"'))
    env = dict(os.environ, XDG_STATE_HOME=str(task_root / 'state'), WAYLAND_DISPLAY='wayland-test', FACET_TEST_PID=str(task_root / 'pid'))
    pid = None
    try:
        subprocess.run(['bash', str(helper)], env=env, check=True, timeout=8)
        pid = int((task_root / 'pid').read_text())
        assert os.getsid(pid) == pid, 'daemon still shares the terminal session'
        tick = task_root / 'pid.tick'
        before = float(tick.read_text())
        os.kill(pid, signal.SIGHUP)
        time.sleep(0.15)
        assert float(tick.read_text()) > before, 'daemon stopped after hangup'
        os.kill(pid, 0)
        subprocess.run(['bash', str(helper)], env=env, check=True, timeout=2)
        assert int((task_root / 'pid').read_text()) == pid, 'second daemon was started'
    finally:
        if pid is not None:
            try: os.kill(pid, signal.SIGTERM)
            except ProcessLookupError: pass
    print('Glint daemon survives launcher exit and hangup, and a second launch reuses it')
