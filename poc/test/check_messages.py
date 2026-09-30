#!/usr/bin/env python3
# LICENSEURI https://yuruna.link/license
# Copyright (c) 2026 by Alisson Sol et al.
"""Reject missing, unused, or stale problem translations before building."""
import hashlib
import json
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
LOCALES = ROOT / 'components/lib/amisad-common/locales'


def check():
    catalogs = {locale: json.loads((LOCALES / f'{locale}.json').read_text(encoding='utf-8'))
                for locale in ['en-US', 'pt-BR', 'zh-CN', 'he-IL']}
    source = catalogs['en-US']['messages']
    used = set()
    for path in (ROOT / 'components').rglob('*.rs'):
        used.update(re.findall(r'Response::problem\(\s*\d+,\s*"([^"]+)"', path.read_text(encoding='utf-8')))
    if set(source) != used:
        raise ValueError(f'Catalog keys differ from code: missing={used - set(source)}, unused={set(source) - used}')
    for locale, catalog in catalogs.items():
        if catalog['locale'] != locale or set(catalog['messages']) != used:
            raise ValueError(f'{locale}: missing or unused entries')
        for key, entry in catalog['messages'].items():
            if not entry['text'].strip() or not entry['description'].strip():
                raise ValueError(f'{locale}/{key}: empty text or description')
            expected = hashlib.sha256(source[key]['text'].encode()).hexdigest()
            if entry['sourceHash'] != expected:
                raise ValueError(f'{locale}/{key}: stale translation; regenerate for changed English text')
            if entry['origin'] != ('source' if locale == 'en-US' else 'machine'):
                raise ValueError(f'{locale}/{key}: missing source provenance')
    return len(used), len(catalogs)


def check_web_messages():
    directory = ROOT / 'components/apps/web-spa/src'
    source = (directory / 'messages.ts').read_text(encoding='utf-8')
    rows = dict(re.findall(r'(en|pt|zh|he): \{ (.*?) \}', source))
    if set(rows) != {'en', 'pt', 'zh', 'he'}:
        raise ValueError('Incomplete web locales')
    for locale, body in rows.items():
        entries = dict(re.findall(r'(title|description|home): "([^"]+)"', body))
        if set(entries) != {'title', 'description', 'home'}:
            raise ValueError(f'{locale}: incomplete web recovery messages')
    used = set(re.findall(r'text\.(\w+)', (directory / 'App.tsx').read_text()))
    if used != {'title', 'description', 'home'}:
        raise ValueError('Unused or missing web message keys')
    digest = hashlib.sha256(rows['en'].encode()).hexdigest()
    provenance = json.loads((directory / 'messages.provenance.json').read_text())
    if provenance['sourceSha256'] != digest or set(provenance['translations']) != {'pt-BR', 'zh-CN', 'he-IL'}:
        raise ValueError('Stale web source or incomplete provenance')
    for entry in provenance['translations'].values():
        if entry != {'origin': 'machine', 'sourceSha256': digest}:
            raise ValueError('Stale web translation provenance')


if __name__ == '__main__':
    count, locales = check()
    print(f'{count} messages in {locales} locales; no missing, stale, or unused entries')

    check_web_messages()
    print('3 web recovery messages in 4 locales; current machine provenance and no unused keys')
