import os
import httpx
from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware

ALLOWED_ORIGIN = os.environ["ALLOWED_ORIGIN"]
GEOCODE_URL = "https://geocoding-api.open-meteo.com/v1/search"
FORECAST_URL = "https://api.open-meteo.com/v1/forecast"

WEATHER_CODES = {
    0: "Clear sky", 1: "Mainly clear", 2: "Partly cloudy", 3: "Overcast",
    45: "Fog", 48: "Rime fog", 51: "Light drizzle", 53: "Drizzle",
    55: "Dense drizzle", 61: "Light rain", 63: "Rain", 65: "Heavy rain",
    71: "Light snow", 73: "Snow", 75: "Heavy snow", 80: "Rain showers",
    81: "Heavy rain showers", 95: "Thunderstorm", 96: "Thunderstorm w/ hail",
}

app = FastAPI()

app.add_middleware(
    CORSMiddleware,
    allow_origins=[ALLOWED_ORIGIN],
    allow_methods=["GET", "OPTIONS"],
    allow_headers=["Authorization", "Content-Type"],
)

@app.get("/healthz")
async def healthz():
    return {"ok": True}

@app.get("/current")
async def current(city: str):
    async with httpx.AsyncClient(timeout=10.0) as http:
        geo_r = await http.get(GEOCODE_URL, params={"name": city, "count": 1})
        geo_r.raise_for_status()
        geo = geo_r.json()
        results = geo.get("results") or []
        if not results:
            raise HTTPException(status_code=404, detail=f"unknown city: {city}")
        place = results[0]
        forecast_r = await http.get(FORECAST_URL, params={
            "latitude": place["latitude"],
            "longitude": place["longitude"],
            "current": "temperature_2m,wind_speed_10m,weather_code",
        })
        forecast_r.raise_for_status()
        cur = forecast_r.json().get("current", {})
        code = cur.get("weather_code", 0)
        return {
            "city": place["name"],
            "temp_c": cur.get("temperature_2m"),
            "wind_kph": cur.get("wind_speed_10m"),
            "weather_code": code,
            "description": WEATHER_CODES.get(code, "Unknown"),
        }
