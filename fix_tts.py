"""Patch: add app.appid to Volcengine TTS payload."""
import pathlib

p = pathlib.Path('/opt/isales/releases/20260517-222944/isales-engine/isales_engine/providers/tts_volcengine.py')
t = p.read_text()

old = '        payload = {\n            "audio": {'
new = '        payload = {\n            "app": {\n                "appid": self._app_key,\n            },\n            "audio": {'

if old not in t:
    print("ERROR: target string not found, file may already be patched")
else:
    t = t.replace(old, new, 1)
    p.write_text(t)
    print("OK: patched app.appid into payload")
