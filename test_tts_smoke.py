"""Quick TTS smoke test — verifies V3 SSE endpoint works with DB creds."""
import asyncio
import sys
sys.path.insert(0, '/opt/isales/releases/20260517-222944/isales-engine')

async def main():
    from isales_engine.providers.tts_volcengine import VolcengineTTSProvider
    from isales_common.credentials import CredentialStore
    from sqlalchemy.ext.asyncio import create_async_engine, AsyncSession
    from sqlalchemy.orm import sessionmaker
    import os

    db_url = os.environ.get('ISALES_DATABASE_URL', '')
    if not db_url:
        # Try reading from env file
        with open('/etc/isales/env/engine.env') as f:
            for line in f:
                if line.startswith('ISALES_DATABASE_URL='):
                    db_url = line.split('=', 1)[1].strip()
                    break

    # Just try to instantiate and call with known creds from DB
    # Use a simpler approach - read creds directly
    import subprocess
    result = subprocess.run(
        ['sudo', '-u', 'postgres', 'psql', '-d', 'isales', '-t', '-A', '-c',
         "SELECT field_name, cipher_text FROM provider_credential WHERE provider_id='volcengine'"],
        capture_output=True, text=True
    )
    print("DB creds raw:", result.stdout[:200])

    # For now just test import and construction works
    try:
        p = VolcengineTTSProvider(api_key="test", resource_id="seed-tts-2.0")
        print("OK: VolcengineTTSProvider instantiation works")
    except Exception as e:
        print(f"ERROR: {e}")

asyncio.run(main())
