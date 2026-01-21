import json
import os
from dataclasses import asdict, dataclass
from datetime import datetime, timezone
from typing import Dict, List


DEFAULT_HISTORY_PATH = os.path.join(os.getcwd(), "data", "price_history.json")


@dataclass(frozen=True)
class HistoryEntry:
    checked_at: str
    price: float
    currency: str
    provider: str
    deeplink: str | None


def _load_history(path: str) -> Dict[str, List[dict]]:
    if not os.path.exists(path):
        return {}
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def _save_history(path: str, payload: Dict[str, List[dict]]) -> None:
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, indent=2, sort_keys=True)


def route_key(origin: str, destination: str, trip_type: str, currency: str) -> str:
    return f"{origin}-{destination}-{trip_type}-{currency}"


def append_history(
    origin: str,
    destination: str,
    trip_type: str,
    currency: str,
    price: float,
    provider: str,
    deeplink: str | None,
    path: str = DEFAULT_HISTORY_PATH,
) -> HistoryEntry:
    payload = _load_history(path)
    key = route_key(origin, destination, trip_type, currency)
    entry = HistoryEntry(
        checked_at=datetime.now(timezone.utc).isoformat(),
        price=price,
        currency=currency,
        provider=provider,
        deeplink=deeplink,
    )
    payload.setdefault(key, []).append(asdict(entry))
    _save_history(path, payload)
    return entry


def get_last_entry(
    origin: str,
    destination: str,
    trip_type: str,
    currency: str,
    path: str = DEFAULT_HISTORY_PATH,
) -> HistoryEntry | None:
    payload = _load_history(path)
    key = route_key(origin, destination, trip_type, currency)
    entries = payload.get(key, [])
    if not entries:
        return None
    latest = entries[-1]
    return HistoryEntry(
        checked_at=latest["checked_at"],
        price=float(latest["price"]),
        currency=latest["currency"],
        provider=latest["provider"],
        deeplink=latest.get("deeplink"),
    )
