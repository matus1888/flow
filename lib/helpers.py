#!/usr/bin/env python3
"""Служебные операции opncdjob: правка Clash-конфига, разбор подписки, JSON.

Запускается из bash-скриптов, внешних зависимостей не требует (только stdlib).
"""

from __future__ import annotations

import base64
import json
import re
import shlex
import sys

TOP_LEVEL = re.compile(r'^([A-Za-z][A-Za-z0-9_-]*):')

OVERRIDES_ORDER = (
    'mixed-port',
    'socks-port',
    'allow-lan',
    'bind-address',
    'mode',
    'log-level',
    'external-controller',
    'secret',
)

DROP_KEYS = {'redir-port', 'tproxy-port'}


def split_top_level(text: str):
    """Разбивает YAML на префикс и блоки верхнего уровня (key, lines)."""
    prefix: list[str] = []
    blocks: list[tuple[str, list[str]]] = []
    for line in text.splitlines():
        match = TOP_LEVEL.match(line)
        if match:
            blocks.append((match.group(1), [line]))
        elif blocks:
            blocks[-1][1].append(line)
        else:
            prefix.append(line)
    return prefix, blocks


def count_entries(lines: list[str]) -> int:
    """Считает элементы списка на минимальном отступе (вложенные списки не в счёт)."""
    items = [line for line in lines[1:] if line.strip().startswith('- ')]
    if not items:
        return 0
    indent = min(len(line) - len(line.lstrip()) for line in items)
    return sum(1 for line in items if len(line) - len(line.lstrip()) == indent)


def cmd_patch_config(args: list[str]) -> None:
    if len(args) < 6:
        sys.exit('usage: patch-config IN OUT MIXED_PORT SOCKS_PORT CONTROLLER_PORT SECRET')
    src, dst, mixed, socks, ctrl, secret = args[:6]

    with open(src, encoding='utf-8') as handle:
        text = handle.read()

    prefix, blocks = split_top_level(text)
    kept = [(key, lines) for key, lines in blocks if key not in DROP_KEYS]

    proxies = next((lines for key, lines in kept if key == 'proxies'), [])
    if count_entries(proxies) == 0:
        sys.exit('в ответе подписки нет прокси (proxies)')

    if not any(key == 'rules' for key, _ in kept):
        sys.exit('в ответе подписки нет правил (rules)')

    overrides = {
        'mixed-port': f'mixed-port: {mixed}',
        'socks-port': f'socks-port: {socks}',
        'allow-lan': 'allow-lan: false',
        'bind-address': 'bind-address: 127.0.0.1',
        'mode': 'mode: global',
        'log-level': 'log-level: warning',
        'external-controller': f'external-controller: 127.0.0.1:{ctrl}',
        'secret': f'secret: {json.dumps(secret)}',
    }

    out: list[str] = list(prefix)
    for key in OVERRIDES_ORDER:
        out.append(overrides[key])
    for key, lines in kept:
        if key in overrides:
            continue
        out.extend(lines)

    with open(dst, 'w', encoding='utf-8') as handle:
        handle.write('\n'.join(out).rstrip('\n') + '\n')


def decode_header_value(value: str) -> str:
    if not value.startswith('base64:'):
        return value
    payload = value[len('base64:'):].strip()
    payload += '=' * (-len(payload) % 4)
    try:
        return base64.b64decode(payload).decode('utf-8', 'replace')
    except Exception:
        return ''


def cmd_sub_info(args: list[str]) -> None:
    if len(args) < 2:
        sys.exit('usage: sub-info HEADERS YAML')

    headers_path, yaml_path = args[:2]
    headers: dict[str, str] = {}
    try:
        with open(headers_path, encoding='utf-8', errors='replace') as handle:
            lines = handle.readlines()
    except OSError:
        lines = []

    for line in lines:
        if ':' not in line:
            continue
        key, value = line.split(':', 1)
        key = key.strip().lower()
        if key in ('profile-title', 'subscription-userinfo', 'profile-web-page-url'):
            headers[key] = decode_header_value(value.strip())

    userinfo: dict[str, str] = {}
    for key, value in re.findall(r'(\w+)=([^;]*)', headers.get('subscription-userinfo', '')):
        userinfo[key] = value.strip()

    with open(yaml_path, encoding='utf-8') as handle:
        _, blocks = split_top_level(handle.read())

    nodes = count_entries(next((lines for key, lines in blocks if key == 'proxies'), []))
    groups = count_entries(next((lines for key, lines in blocks if key == 'proxy-groups'), []))

    values = {
        'SUB_TITLE': headers.get('profile-title', ''),
        'SUB_WEB': headers.get('profile-web-page-url', ''),
        'SUB_NODES': str(nodes),
        'SUB_GROUPS': str(groups),
        'SUB_UPLOAD': userinfo.get('upload', '0'),
        'SUB_DOWNLOAD': userinfo.get('download', '0'),
        'SUB_TOTAL': userinfo.get('total', '0'),
        'SUB_EXPIRE': userinfo.get('expire', '0'),
    }
    for key, value in values.items():
        print(f'{key}={shlex.quote(value)}')


def cmd_json_get(args: list[str]) -> None:
    if not args:
        sys.exit('usage: json-get KEY [FILE]')
    key = args[0]
    if len(args) > 1:
        with open(args[1], encoding='utf-8') as handle:
            data = json.load(handle)
    else:
        data = json.load(sys.stdin)
    value = data.get(key, '')
    if isinstance(value, str):
        sys.stdout.write(value)
    elif value is None:
        sys.stdout.write('')
    else:
        sys.stdout.write(json.dumps(value))


def cmd_json_entries(args: list[str]) -> None:
    if args:
        with open(args[0], encoding='utf-8') as handle:
            data = json.load(handle)
    else:
        data = json.load(sys.stdin)
    for key, value in data.items():
        if isinstance(value, str) and value:
            print(f'{key}\t{value}')


def cmd_first_group(args: list[str]) -> None:
    """Печатает имя первой группы прокси из конфига (для выбора в GLOBAL)."""
    if not args:
        sys.exit('usage: first-group CONFIG')
    with open(args[0], encoding='utf-8') as handle:
        _, blocks = split_top_level(handle.read())
    lines = next((lines for key, lines in blocks if key == 'proxy-groups'), [])
    for line in lines[1:]:
        item = line.strip()
        if not item.startswith('- name:'):
            continue
        value = item[len('- name:'):].strip()
        if len(value) > 1 and value[0] in ('"', "'") and value[-1] == value[0]:
            value = value[1:-1]
        if value:
            print(value)
            return


COMMANDS = {
    'patch-config': cmd_patch_config,
    'sub-info': cmd_sub_info,
    'first-group': cmd_first_group,
    'json-get': cmd_json_get,
    'json-entries': cmd_json_entries,
}


def main() -> None:
    if len(sys.argv) < 2 or sys.argv[1] not in COMMANDS:
        sys.exit('usage: helpers.py {' + ','.join(COMMANDS) + '} ...')
    COMMANDS[sys.argv[1]](sys.argv[2:])


if __name__ == '__main__':
    main()
