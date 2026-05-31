import sys
sys.path.insert(0, '/opt/isales/releases/20260517-222944/isales-engine')
from isales_engine.providers.tts_volcengine import VolcengineTTSProvider
p = VolcengineTTSProvider(api_key="test", resource_id="seed-tts-2.0")
print("OK: VolcengineTTSProvider construction works")
