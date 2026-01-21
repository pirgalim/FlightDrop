from dataclasses import dataclass


@dataclass(frozen=True)
class FlightDeal:
    price: float
    currency: str
    deeplink: str | None


@dataclass(frozen=True)
class FlightOffer:
    price: float
    currency: str
    deeplink: str | None
    outbound_departure: str | None
    outbound_arrival: str | None
    inbound_departure: str | None
    inbound_arrival: str | None
    carriers: tuple[str, ...]


class ProviderError(RuntimeError):
    pass


class BaseProvider:
    name = "base"

    def search_top(
        self,
        origin: str,
        destination: str,
        currency: str,
        days_ahead: int,
        trip_type: str,
        top_n: int,
        date_from: str | None,
        date_to: str | None,
        return_days: int | None,
        return_date_from: str | None,
        return_date_to: str | None,
    ) -> list[FlightOffer]:
        raise NotImplementedError

    def search_cheapest(
        self, origin: str, destination: str, currency: str, days_ahead: int, trip_type: str
    ) -> FlightDeal:
        offers = self.search_top(
            origin=origin,
            destination=destination,
            currency=currency,
            days_ahead=days_ahead,
            trip_type=trip_type,
            top_n=1,
            date_from=None,
            date_to=None,
            return_days=None,
            return_date_from=None,
            return_date_to=None,
        )
        if not offers:
            raise ProviderError("No flights returned by provider.")
        best = offers[0]
        return FlightDeal(price=best.price, currency=best.currency, deeplink=best.deeplink)
