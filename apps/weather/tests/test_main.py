import os
os.environ.setdefault("ALLOWED_ORIGIN", "https://test.example.com")

import respx
import httpx
from fastapi.testclient import TestClient
import importlib

@respx.mock
def test_current_returns_weather():
    respx.get("https://geocoding-api.open-meteo.com/v1/search").mock(
        return_value=httpx.Response(200, json={
            "results": [{"name": "Berlin", "latitude": 52.52, "longitude": 13.41}]
        })
    )
    respx.get("https://api.open-meteo.com/v1/forecast").mock(
        return_value=httpx.Response(200, json={
            "current": {"temperature_2m": 12.3, "wind_speed_10m": 7.5, "weather_code": 3}
        })
    )
    from apps.weather import main
    importlib.reload(main)
    client = TestClient(main.app)
    r = client.get("/current?city=Berlin")
    assert r.status_code == 200
    body = r.json()
    assert body["city"] == "Berlin"
    assert body["temp_c"] == 12.3
    assert body["wind_kph"] == 7.5
    assert body["weather_code"] == 3
    assert "description" in body

@respx.mock
def test_current_404_when_city_unknown():
    respx.get("https://geocoding-api.open-meteo.com/v1/search").mock(
        return_value=httpx.Response(200, json={})  # no "results" key
    )
    from apps.weather import main
    importlib.reload(main)
    client = TestClient(main.app)
    r = client.get("/current?city=Atlantis")
    assert r.status_code == 404

def test_healthz():
    from apps.weather import main
    importlib.reload(main)
    client = TestClient(main.app)
    r = client.get("/healthz")
    assert r.status_code == 200
    assert r.json() == {"ok": True}
