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


if __name__ == '__main__':
    count, locales = check()
    print(f'{count} messages in {locales} locales; no missing, stale, or unused entries')
