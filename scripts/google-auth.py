#!/usr/bin/env python3
"""One-time desktop OAuth login; only the resulting credentials go to the tablet."""
import argparse
import base64
import hashlib
import http.server
import json
import os
import pathlib
import secrets
import time
import urllib.error
import urllib.parse
import urllib.request

SCOPE = 'https://www.googleapis.com/auth/calendar.readonly https://www.googleapis.com/auth/calendar.events'

def authorization_url(client_id, redirect, state, verifier):
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).decode().rstrip('=')
    return 'https://accounts.google.com/o/oauth2/v2/auth?' + urllib.parse.urlencode(dict(
        client_id=client_id, redirect_uri=redirect, response_type='code', scope=SCOPE,
        access_type='offline', prompt='consent', state=state,
        code_challenge=challenge, code_challenge_method='S256'))

def save_credentials(path, data):
    path = pathlib.Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    # Exclusive creation avoids replacing existing credentials or following a symlink.
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
    with os.fdopen(fd, 'w') as stream:
        json.dump(data, stream, indent=2)
        stream.write('\n')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('client', help='Google Desktop app client JSON')
    parser.add_argument('--output', default=str(pathlib.Path.home()/'.config/rmarkable-calendar/google.json'))
    args = parser.parse_args()
    if pathlib.Path(args.output).exists():
        parser.error('output already exists; choose another path or move the old credentials first')
    client = json.loads(pathlib.Path(args.client).read_text()).get('installed', {})
    if not client.get('client_id') or not client.get('client_secret'):
        parser.error('download a Desktop app OAuth client JSON from Google Cloud')
    state, verifier = secrets.token_urlsafe(32), secrets.token_urlsafe(64)
    result = {}
    class Callback(http.server.BaseHTTPRequestHandler):
        def log_message(self, *unused):
            pass  # Callback URLs contain authorization codes.
        def do_GET(self):
            url = urllib.parse.urlsplit(self.path)
            query = urllib.parse.parse_qs(url.query)
            if url.path != '/callback' or not secrets.compare_digest(query.get('state', [''])[0], state):
                self.send_error(400, 'Invalid callback')
                return
            if 'error' in query:
                result['error'] = 'Authorization was denied. Run the login again when ready.'
            elif query.get('code'):
                result['code'] = query['code'][0]
            else:
                self.send_error(400, 'Missing authorization code')
                return
            self.send_response(200)
            self.send_header('Content-Type', 'text/plain; charset=utf-8')
            self.end_headers()
            self.wfile.write(b'You can close this tab and return to reMarkable Calendar setup.')
    with http.server.HTTPServer(('127.0.0.1', 0), Callback) as server:
        server.timeout = 1
        redirect = f'http://127.0.0.1:{server.server_port}/callback'
        print('Open this link in a browser on this computer (Windows browser works with WSL localhost):\n')
        print(authorization_url(client['client_id'], redirect, state, verifier), flush=True)
        deadline = time.monotonic() + 300
        while not result and time.monotonic() < deadline:
            server.handle_request()
    if 'error' in result:
        raise SystemExit(result['error'])
    if 'code' not in result:
        raise SystemExit('Login timed out after five minutes; run again.')
    payload = urllib.parse.urlencode(dict(client_id=client['client_id'], client_secret=client['client_secret'],
        code=result['code'], code_verifier=verifier, redirect_uri=redirect,
        grant_type='authorization_code')).encode()
    try:
        with urllib.request.urlopen('https://oauth2.googleapis.com/token', data=payload, timeout=30) as response:
            token = json.load(response)
    except urllib.error.HTTPError as exc:
        raise SystemExit(f'Token exchange failed (HTTP {exc.code}); run login again.') from None
    if not token.get('refresh_token'):
        raise SystemExit('Google returned no refresh token; repeat login and grant offline access.')
    if not set(SCOPE.split()).issubset(token.get('scope', '').split()):
        raise SystemExit('Calendar reading/editing permission was not granted; repeat login and allow both permissions.')
    save_credentials(args.output, dict(client_id=client['client_id'], client_secret=client['client_secret'],
                                     refresh_token=token['refresh_token']))
    print(f'Credentials saved privately to {args.output}. Do not commit or share this file.')

if __name__ == '__main__':
    main()
