import json
import os
from dataclasses import dataclass
from typing import List


DEFAULT_CONFIG_PATH = os.path.join(os.getcwd(), "config.json")


@dataclass(frozen=True)
class RouteConfig:
    origin: str
    destination: str
    currency: str
    days_ahead: int
    trip_type: str
    date_from: str | None
    date_to: str | None
    return_days: int | None
    return_date_from: str | None
    return_date_to: str | None
    top_n: int


@dataclass(frozen=True)
class AppConfig:
    provider: str
    routes: List[RouteConfig]


def load_config(path: str | None = None) -> AppConfig:
    config_path = path or os.environ.get("FLIGHTDROP_CONFIG") or DEFAULT_CONFIG_PATH
    with open(config_path, "r", encoding="utf-8") as handle:
        raw = json.load(handle)

    routes = []
    for route in raw.get("routes", []):
        routes.append(
            RouteConfig(
                origin=route["origin"].upper(),
                destination=route["destination"].upper(),
                currency=route.get("currency", "CAD").upper(),
                days_ahead=int(route.get("days_ahead", 120)),
                trip_type=route.get("trip_type", "one_way"),
                date_from=route.get("date_from"),
                date_to=route.get("date_to"),
                return_days=int(route["return_days"]) if "return_days" in route else None,
                return_date_from=route.get("return_date_from"),
                return_date_to=route.get("return_date_to"),
                top_n=int(route.get("top_n", 5)),
            )
        )

    return AppConfig(provider=raw.get("provider", "tequila"), routes=routes)
