import hashlib
import math
from datetime import datetime, timedelta, timezone
from zoneinfo import ZoneInfo

from .questions import CATEGORIES


LOCATION_GRID_DEGREES = 0.05
EARTH_RADIUS_KM = 6371


def score(left, right):
    if set(left) != set(range(1, 65)) or set(right) != set(range(1, 65)):
        raise ValueError("Both questionnaires must be complete")
    if any(type(value) is not int or not 1 <= value <= 5 for value in list(left.values()) + list(right.values())):
        raise ValueError("Answers must be integers between 1 and 5")
    categories = {}
    for index, (name, _) in enumerate(CATEGORIES):
        categories[name] = sum(
            100 - 25 * abs(left[q] - right[q])
            for q in range(index * 8 + 1, index * 8 + 9)
        ) / 8
    return sum(categories.values()) / 8, categories


def distance_km(a, b):
    lat1, lat2 = math.radians(a["latitude"]), math.radians(b["latitude"])
    delta_lat = lat2 - lat1
    delta_lon = math.radians(b["longitude"] - a["longitude"])
    value = math.sin(delta_lat / 2) ** 2 + math.cos(lat1) * math.cos(lat2) * math.sin(delta_lon / 2) ** 2
    return 2 * EARTH_RADIUS_KM * math.asin(min(1, math.sqrt(value)))


def conservative_distance_km(a, b):
    grid = [
        {axis: round(user[axis] / LOCATION_GRID_DEGREES) * LOCATION_GRID_DEGREES for axis in ("latitude", "longitude")}
        for user in (a, b)
    ]
    # Each point may be half a grid cell away in both latitude and longitude.
    uncertainty = 2 * EARTH_RADIUS_KM * math.radians(LOCATION_GRID_DEGREES)
    return distance_km(grid[0], grid[1]) + uncertainty


def accepts(user, candidate):
    p = user["preferences"]
    return (
        p["min_age"] <= candidate["age"] <= p["max_age"]
        and candidate["gender"] in p["genders"]
        and candidate["intention"] in p["intentions"]
        and conservative_distance_km(user, candidate) <= p["distance"]
        and not any(candidate["lifestyle"].get(key) != value for key, value in p["dealbreakers"].items())
    )


def mutually_eligible(a, b):
    return a["id"] != b["id"] and accepts(a, b) and accepts(b, a)


def cycle_start(now, timezone_name):
    zone = ZoneInfo(timezone_name)
    local = now.astimezone(zone)
    monday = local.date() - timedelta(days=local.weekday())
    start = datetime(monday.year, monday.month, monday.day, 9, tzinfo=zone)
    if local < start:
        monday -= timedelta(days=7)
        start = datetime(monday.year, monday.month, monday.day, 9, tzinfo=zone)
    return start.astimezone(timezone.utc)


def tie_key(secret, cycle, user_id, candidate_id):
    return hashlib.sha256(f"{secret}:{cycle}:{user_id}:{candidate_id}".encode()).hexdigest()
