"""Patch: update factory.py build_tts to match V3 VolcengineTTSProvider."""
import pathlib

p = pathlib.Path('/opt/isales/releases/20260517-222944/isales-engine/isales_engine/providers/factory.py')
t = p.read_text()

old = '''    if name == "volcengine":
        app_key = _require_field(s, "volcengine", "app_key")
        app_token = _require_field(s, "volcengine", "app_token")
        from isales_engine.providers.tts_volcengine import VolcengineTTSProvider

        return VolcengineTTSProvider(
            endpoint=s.get("volcengine", "tts_endpoint") or _DEFAULT_ENDPOINT["volcengine_tts"],
            app_key=app_key,
            app_token=app_token,
        )'''

new = '''    if name == "volcengine":
        api_key = s.get("volcengine", "api_key") or None
        app_id = s.get("volcengine", "app_key") or None
        access_key = s.get("volcengine", "app_token") or None
        resource_id = s.get("volcengine", "tts_resource_id") or "seed-tts-2.0"
        from isales_engine.providers.tts_volcengine import VolcengineTTSProvider

        return VolcengineTTSProvider(
            api_key=api_key,
            app_id=app_id,
            access_key=access_key,
            resource_id=resource_id,
        )'''

if old not in t:
    print("ERROR: target block not found in factory.py")
    # Show context around build_tts for debugging
    lines = t.splitlines()
    for i, line in enumerate(lines):
        if 'volcengine' in line.lower() and 'tts' in line.lower():
            print(f"  L{i+1}: {line}")
else:
    t = t.replace(old, new, 1)
    p.write_text(t)
    print("OK: factory.py patched for V3 TTS provider")
