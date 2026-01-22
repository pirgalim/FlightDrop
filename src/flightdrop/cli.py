import argparse
import sys
from datetime import datetime

from flightdrop.config import load_config
from flightdrop.env import load_dotenv
from flightdrop.providers import get_provider
from flightdrop.providers.base import ProviderError
from flightdrop.storage import append_history, get_last_entry


def _format_delta(current: float, previous: float | None) -> str:
    if previous is None:
        return "baseline"
    delta = current - previous
    if delta == 0:
        return "no change"
    direction = "up" if delta > 0 else "down"
    return f"{direction} {abs(delta):.2f}"


def _format_offer(offer) -> str:
    outbound = ""
    inbound = ""
    if offer.outbound_departure and offer.outbound_arrival:
        outbound = f"{offer.outbound_departure} -> {offer.outbound_arrival}"
    if offer.inbound_departure and offer.inbound_arrival:
        inbound = f"{offer.inbound_departure} -> {offer.inbound_arrival}"
    carriers = ", ".join(offer.carriers) if offer.carriers else "n/a"
    parts = [f"{offer.price:.2f} {offer.currency}"]
    if outbound:
        parts.append(outbound)
    if inbound:
        parts.append(inbound)
    parts.append(f"carriers: {carriers}")
    return " | ".join(parts)


def _format_trip_type(trip_type: str) -> str:
    return trip_type.replace("_", " ")


def _extract_date(value: str | None) -> str | None:
    if not value:
        return None
    return value.split("T")[0]


def _format_short_date(value: str | None) -> str | None:
    if not value:
        return None
    try:
        parsed = datetime.strptime(value, "%Y-%m-%d")
    except ValueError:
        return value
    return parsed.strftime("%b %d").replace(" 0", " ")

def run_check(config_path: str | None) -> int:
    config = load_config(config_path)
    provider = get_provider(config.provider)
    exit_code = 0

    for route in config.routes:
        previous = get_last_entry(
            route.origin,
            route.destination,
            route.trip_type,
            route.currency,
        )
        try:
            offers = provider.search_top(
                origin=route.origin,
                destination=route.destination,
                currency=route.currency,
                days_ahead=route.days_ahead,
                trip_type=route.trip_type,
                top_n=route.top_n,
                date_from=route.date_from,
                date_to=route.date_to,
                return_days=route.return_days,
                return_date_from=route.return_date_from,
                return_date_to=route.return_date_to,
            )
            best = min(offers, key=lambda offer: offer.price)
            entry = append_history(
                origin=route.origin,
                destination=route.destination,
                trip_type=route.trip_type,
                currency=route.currency,
                price=best.price,
                provider=provider.name,
                deeplink=best.deeplink,
            )
        except ProviderError as exc:
            print(f"{route.origin}->{route.destination}: error: {exc}")
            exit_code = 1
            continue

        delta = _format_delta(entry.price, previous.price if previous else None)
        trip_label = _format_trip_type(route.trip_type)
        depart_date = _format_short_date(_extract_date(best.outbound_departure))
        return_date = _format_short_date(_extract_date(best.inbound_departure))
        date_range = ""
        if depart_date and return_date:
            date_range = f" {depart_date} - {return_date}"
        elif depart_date:
            date_range = f" {depart_date}"
        print(
            f"{route.origin}->{route.destination}: cheapest {entry.price:.2f} {entry.currency}"
            f" ({delta}) [{trip_label}]{date_range}"
        )
        for offer in offers:
            print(_format_offer(offer))

    return exit_code


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Track flight prices.")
    parser.add_argument(
        "--config",
        dest="config_path",
        help="Path to config.json (default: ./config.json).",
    )
    parser.add_argument(
        "command",
        nargs="?",
        default="check",
        choices=["check"],
        help="Command to run.",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    load_dotenv()
    parser = build_parser()
    args = parser.parse_args(argv)
    if args.command == "check":
        return run_check(args.config_path)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
