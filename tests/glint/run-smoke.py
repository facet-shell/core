#!/usr/bin/env python3
"""Run the Quickshell wallpaper controller against an asynchronous fake transport."""
import os
import argparse
import pathlib
import shutil
import subprocess
import tempfile

parser = argparse.ArgumentParser()
styles = parser.add_mutually_exclusive_group()
styles.add_argument('--bloom', type=pathlib.Path)
styles.add_argument('--tui', type=pathlib.Path)
parser.add_argument("--installed-root", type=pathlib.Path, default=pathlib.Path.home() / ".local/share/facet/modules")
args = parser.parse_args()
root = pathlib.Path(__file__).resolve().parents[2]
with tempfile.TemporaryDirectory(prefix='facet-glint-') as directory:
    config = pathlib.Path(directory)
    style = args.bloom or args.tui
    if style:
        name = 'bloom' if args.bloom else 'tui'
        bloom = style / name / '.config/quickshell'
        for module in ('components', 'launcher', 'wallpapers', 'settings'):
            if (bloom / module).exists(): shutil.copytree(bloom / module, config / module)
        (config / 'config').mkdir()
        shutil.copy(root / 'quickshell/.config/quickshell/config/Config.qml', config / 'config/Config.qml')
        shutil.copy(args.installed_root / ('style-' + name) / name / '.config/quickshell/config/Theme.qml', config / 'config/Theme.qml')
    (config / 'services').mkdir()
    for name in ('Wallpapers.qml', 'WallpaperState.js'):
        shutil.copy(root / 'quickshell/.config/quickshell/services' / name, config / 'services' / name)
    shutil.copy(root / 'tests/glint/FakeClient.qml', config / 'services/GlintClient.qml')
    shutil.copy(style / 'tests/GlintViewsSmoke.qml' if style else root / 'tests/glint/ServiceSmoke.qml', config / 'shell.qml')
    helper = config / 'facet-wallpaper'
    helper.write_text('#!/bin/sh\nprintf \'%s\\n\' "$*" >>"$FACET_TEST_COMMANDS"\nprintf \'%s\\n\' \'[{"id":"local","title":"Local video","kind":"video","source":"file","path":"/test/local.mp4","preview":""}]\'\n')
    helper.chmod(0o755)
    service = config / 'services/Wallpapers.qml'
    service.write_text(service.read_text().replace('`${Quickshell.env("HOME")}/.local/bin/facet-wallpaper`', '"' + str(helper) + '"'))
    runtime = config / 'runtime'
    runtime.mkdir(mode=0o700)
    env = dict(os.environ, FACET_GLINT='1', FACET_TEST_COMMANDS=str(config / 'commands'), XDG_RUNTIME_DIR=str(runtime), XDG_STATE_HOME=str(config / 'state'), XDG_CONFIG_HOME=str(config / 'app-config'), XDG_CACHE_HOME=str(config / 'cache'), QT_QPA_PLATFORM='offscreen', QT_QPA_PLATFORMTHEME='', QT_QUICK_BACKEND='software')
    env.pop('DISPLAY', None)
    env.pop('WAYLAND_DISPLAY', None)
    result = subprocess.run(['qs', '-p', str(config / 'shell.qml')], env=env, capture_output=True, text=True, timeout=12)
    errors = any(word in result.stdout + result.stderr for word in ("TypeError:", "ReferenceError:", "Binding loop", "Unable to assign", "Cannot assign"))
    if result.returncode or errors:
        print((result.stdout + result.stderr)[-12000:])
    assert result.returncode == 0, result.returncode
    assert ('Glint views smoke passed' if style else 'Glint service smoke passed') in result.stdout + result.stderr
    assert not errors
    commands = (config / 'commands').read_text().splitlines()
    assert commands and all(command == 'list-local' for command in commands), commands
    print('Glint native views passed' if style else 'Glint controller passed')
