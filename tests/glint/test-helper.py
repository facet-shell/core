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
if [ "$1" = outputs ]; then [ "${FACET_TEST_RUNNING:-0}" = 1 ]; exit $?; fi
[ "$1" = --daemon ]
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
    print('Glint migration, existing-daemon reuse and local-file listing passed')
