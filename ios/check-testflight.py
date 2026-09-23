#!/usr/bin/env python3
"""Check resolved Xcode build settings before a staging device archive.

No signing, upload, network call or secret output. This validates configuration,
not Apple account permissions, certificates or backend isolation.
"""
import json
import re
import sys
from urllib.parse import urlsplit


def check(payload):
    targets = [x for x in payload if x.get('target') == 'PiTi']
    if len(targets) != 1:
        return ['PiTi target settings are missing or ambiguous.']
    settings = targets[0].get('buildSettings', {})
    errors = []
    expected = {
        'CONFIGURATION': 'Staging',
        'PRODUCT_BUNDLE_IDENTIFIER': 'online.mypiti.app.staging',
        'PITI_ENVIRONMENT': 'staging',
        'PITI_APNS_ENVIRONMENT': 'production',
        'APS_ENVIRONMENT': 'production',
        'PLATFORM_NAME': 'iphoneos',
    }
    for key, value in expected.items():
        if settings.get(key) != value:
            errors.append(f'{key} must be {value}.')
    if not re.fullmatch(r'[A-Z0-9]{10}', settings.get('DEVELOPMENT_TEAM', '')):
        errors.append('A valid Apple Developer Team ID is required.')
    if settings.get('CODE_SIGNING_ALLOWED') != 'YES':
        errors.append('Device archive signing must be enabled.')
    if not re.fullmatch(r'\d+(?:\.\d+){0,2}', settings.get('CURRENT_PROJECT_VERSION', '')):
        errors.append('A numeric build number is required; also verify it is unused in App Store Connect.')
    raw = settings.get('PITI_BASE_URL', '').strip()
    try:
        url = urlsplit(raw)
        host = (url.hostname or '').lower().rstrip('.')
        forbidden = {'mypiti.online', 'www.mypiti.online', 'piti-online.erkan-yardibi.workers.dev', 'localhost'}
        if (url.scheme != 'https' or not host or host in forbidden or host.endswith('.invalid')
                or url.username is not None or url.password is not None or url.query or url.fragment or '$' in raw):
            raise ValueError()
        _ = url.port
    except (ValueError, TypeError):
        errors.append('A resolved HTTPS staging URL, separate from the live hosts, is required.')
    return errors


if __name__ == '__main__':
    try:
        with open(sys.argv[1], encoding='utf-8') as stream:
            errors = check(json.load(stream))
    except (IndexError, OSError, ValueError, TypeError, AttributeError):
        print('Usage: python3 ios/check-testflight.py resolved-build-settings.json', file=sys.stderr)
        sys.exit(2)
    if errors:
        for error in errors:
            print('BLOCKED: ' + error)
        sys.exit(1)
    print('Configuration checks passed. Apple signing, unique build number and staging backend isolation still require verification.')
